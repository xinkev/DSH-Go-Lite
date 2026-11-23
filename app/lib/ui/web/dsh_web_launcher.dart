import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../l10n/l10n.dart';
import '../../remote/ssh/ssh_link.dart';
import '../../remote/url/url_link.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../../state/settings_state.dart';
import '../../state/ui_mode_state.dart';
import 'local_web_screen.dart';
import 'web_target.dart';
import 'web_view_page.dart';

/// Where the active host's DSH Web can be opened from.
sealed class DshWebAccess {
  const DshWebAccess();
}

/// 本机: the on-device engine's `dsh web` ([LocalWebScreen] handles a
/// stopped engine itself).
final class LocalDshWeb extends DshWebAccess {
  const LocalDshWeb();
}

/// An SSH host: the remote `dsh web` through the app's local forward.
///
/// DSH's browser fence accepts any loopback Host, so the WebView can talk to
/// `127.0.0.1:<forward port>` directly; the launch token logs it in.
final class SshDshWeb extends DshWebAccess {
  const SshDshWeb(this.url, this.hostName);
  final Uri url;
  final String hostName;
}

/// A direct URL host: the same public origin, signed in with the engine's
/// launch token when there is one, else with the cookies the app already holds
/// (dsh-pocket's LAN mode hands out no token).
final class UrlDshWeb extends DshWebAccess {
  const UrlDshWeb(this.url, this.hostName, {this.cookies = const []});
  final Uri url;
  final String hostName;
  final List<WebViewCookie> cookies;
}

/// A plain-http host (dsh-pocket on the LAN): its page opens in the phone's
/// browser instead. Android lets the app's own WebView load cleartext from
/// loopback only, and the browser signs in through the gate itself.
final class ExternalDshWeb extends DshWebAccess {
  const ExternalDshWeb(this.url, this.hostName);
  final Uri url;
  final String hostName;
}

/// No web page for this host right now; [reason] says why.
final class NoDshWeb extends DshWebAccess {
  const NoDshWeb(this.reason);
  final String reason;
}

/// The active host's DSH Web, if it has one the app can reach.
final dshWebAccessProvider = Provider.autoDispose<DshWebAccess>((ref) {
  final host = ref.watch(activeHostProvider);
  switch (host.kind) {
    case HostKind.local:
      return const LocalDshWeb();
    case HostKind.ssh:
      // Rebuild once the link connects (or reconnects to a new process).
      ref.watch(hostLinkStatusProvider(host));
      final link = ref.watch(hostLinkProvider(host));
      final name = ref.watch(hostNameProvider(host)) ?? appL10n.webSshHost;
      final port = link is SshHostLink ? link.localPort : null;
      final token = link is SshHostLink ? link.endpoint?.token : null;
      if (port == null || token == null) {
        return NoDshWeb(appL10n.webConnectHostFirst(name));
      }
      return SshDshWeb(localWebUri('http://127.0.0.1:$port', token), name);
    case HostKind.url:
      ref.watch(hostLinkStatusProvider(host));
      final link = ref.watch(hostLinkProvider(host));
      final name = ref.watch(hostNameProvider(host)) ?? host.id;
      final config = ref.watch(hostsProvider).urlById(host.id);
      if (config == null) return NoDshWeb(appL10n.webConnectHostFirst(name));
      final base = config.baseUri.replace(
        path: config.baseUri.path.isEmpty ? '/' : '${config.baseUri.path}/',
      );
      // The app's WebView is not allowed to load plain http off loopback, and a
      // LAN page needs no token of ours: the browser signs in through the gate.
      if (base.scheme == 'http') {
        final token = link is UrlHostLink ? link.launchToken : null;
        return ExternalDshWeb(
          token == null ? base : base.replace(queryParameters: {'token': token}),
          name,
        );
      }
      if (link is UrlHostLink) {
        // The live connection's cookies are what the engine just accepted.
        final cookies = [
          for (final pair in link.heldCookies) ?webViewCookie(base, pair.name, pair.value),
        ];
        if (cookies.isNotEmpty) return UrlDshWeb(base, name, cookies: cookies);
        if (link.launchToken case final token?) {
          return UrlDshWeb(base.replace(queryParameters: {'token': token}), name);
        }
      }
      return NoDshWeb(appL10n.webConnectHostFirst(name));
  }
});

/// Opens [url] in the phone's browser; says so when it could not.
Future<void> openInBrowser(BuildContext context, Uri url) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  var opened = false;
  try {
    opened = await launchUrl(url, mode: LaunchMode.externalApplication);
  } on Object {
    opened = false;
  }
  if (!opened) messenger?.showSnackBar(SnackBar(content: Text(appL10n.webBrowserUnavailable)));
}

/// A page that decides how it is left for DSH Web: [openDshWeb] from inside
/// it (its rows that say 「在网页版编辑此项」) hands the target to [onOpen]
/// instead, which lands it and goes there when the page can be left — a page
/// whose own edits DSH Web would otherwise race (plugin_config_page.dart).
class DshWebOpenScope extends InheritedWidget {
  const DshWebOpenScope({super.key, required this.onOpen, required super.child});

  final void Function(DshWebTarget target) onOpen;

  static DshWebOpenScope? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<DshWebOpenScope>();

  @override
  bool updateShouldNotify(DshWebOpenScope oldWidget) => false;
}

/// Opens the active host's official DSH Web, landing on [target]. In
/// 网页模式 the home page itself goes there (no second page on top). Inside
/// a [DshWebOpenScope] the page around decides.
void openDshWeb(BuildContext context, WidgetRef ref, {DshWebTarget target = const DshWebTarget()}) {
  if (DshWebOpenScope.maybeOf(context) case final scope?) {
    scope.onOpen(target);
    return;
  }
  // A plugin's entry id is no name its card has: name its bundle.
  if (ref.read(uiModeProvider).web) {
    ref.read(webOpenProvider.notifier).request(target);
    return;
  }
  final Widget page;
  switch (ref.read(dshWebAccessProvider)) {
    case LocalDshWeb():
      page = LocalWebScreen(target: target);
    case SshDshWeb(:final url, :final hostName):
      page = WebViewPage(
        url: url,
        title: context.l10n.webTitle,
        subtitle: hostName,
        externalDisabledReason: context.l10n.webSshAppOnly,
        // Android suspends the page in the background and its socket drops.
        reloadAfterBackground: const Duration(seconds: 60),
        dshWeb: true,
        phoneLayout: ref.read(settingsProvider).webPhoneLayout,
        openTarget: target,
      );
    case UrlDshWeb(:final url, :final hostName, :final cookies):
      page = WebViewPage(
        url: url,
        title: context.l10n.webTitle,
        subtitle: hostName,
        externalDisabledReason: context.l10n.webSshAppOnly,
        reloadAfterBackground: const Duration(seconds: 60),
        dshWeb: true,
        phoneLayout: ref.read(settingsProvider).webPhoneLayout,
        openTarget: target,
        cookies: cookies,
      );
    case ExternalDshWeb(:final url):
      unawaited(openInBrowser(context, url));
      return;
    case NoDshWeb(:final reason):
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(reason)));
      return;
  }
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
}
