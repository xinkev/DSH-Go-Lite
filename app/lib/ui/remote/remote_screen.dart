import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../remote/relay/relay_backend.dart';
import '../../runtime/local_footprint.dart';
import '../../runtime/runtime_state.dart';
import '../../state/app_info.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../common/app_dialog.dart';
import '../common/ask_ai.dart';
import '../common/overview_card.dart';
import '../common/status_chip.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../web/web_view_page.dart';
import 'host_key_dialog.dart';
import 'host_status.dart';
import 'link_progress.dart';
import 'network_details_sheet.dart';
import 'relay_login_sheet.dart';
import 'ssh_host_form.dart';
import 'url_host_form.dart';
import 'url_scan_page.dart';
import 'session_backup_page.dart';
import 'remote_web/remote_web_entry.dart';

/// 远程主机 (a list page): the computers this phone can drive.
///
/// Two ways in: a direct URL (a `dsh web` behind a tunnel, optionally with
/// dsh-pocket's access PIN) and SSH hosts (dsh-app starts `dsh web` over SSH
/// and tunnels to it). Picking a host makes it the active one; the chat and
/// the session list follow. No account and no relay sign-in.
class RemoteScreen extends ConsumerWidget {
  const RemoteScreen({super.key});

  void _openConsole(BuildContext context) {
    final l10n = context.l10n;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WebViewPage(
          url: Uri.parse(AppInfo.remoteConsole),
          title: l10n.remoteConsole,
          subtitle: 'dsh.r2049.cn',
          allowOpenExternal: true,
          // Android suspends the page in the background and its connection drops.
          reloadAfterBackground: const Duration(seconds: 60),
        ),
      ),
    );
  }

  Future<void> _use(BuildContext context, WidgetRef ref, HostRef host) async {
    final navigator = Navigator.of(context);
    if (ref.read(activeHostProvider) == host) {
      // Tapping the active host after a failure: confirm trust if that was
      // the problem, then connect again.
      final failed = ref.read(hostLinkStatusProvider(host)).value?.phase == HostLinkPhase.failed;
      if (!failed) {
        navigator.maybePop();
        return;
      }
      if (await activateHost(context, ref, host)) {
        ref.read(remoteConnectionProvider(host).notifier).retry();
      }
      return;
    }
    final ok = await activateHost(context, ref, host);
    if (ok && navigator.mounted) navigator.maybePop();
  }

  /// A host added while this phone has nothing to run on (no runtime, first
  /// run) is the one to use: take it at once instead of a second tap.
  Future<void> _addSsh(BuildContext context, WidgetRef ref) async {
    final saved = await Navigator.of(context)
        .push<SshHostConfig>(MaterialPageRoute(builder: (_) => const SshHostFormPage()));
    if (saved == null || !context.mounted) return;
    final nothingHere = ref.read(localRuntimeProvider).status.runtimeMissing;
    if (nothingHere && ref.read(activeHostProvider).isLocal) await _use(context, ref, HostRef.ssh(saved.id));
  }

  Future<void> _addUrl(BuildContext context, WidgetRef ref) async {
    final saved = await Navigator.of(context)
        .push<UrlHostConfig>(MaterialPageRoute(builder: (_) => const UrlHostFormPage()));
    if (saved == null || !context.mounted) return;
    final nothingHere = ref.read(localRuntimeProvider).status.runtimeMissing;
    if (nothingHere && ref.read(activeHostProvider).isLocal) await _use(context, ref, HostRef.url(saved.id));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final ssh = ref.watch(hostsProvider.select((s) => s.ssh));
    final urls = ref.watch(hostsProvider.select((s) => s.url));
    final active = ref.watch(activeHostProvider);
    final signedIn = ref.watch(relayAccountProvider.select((a) => a.value?.signedIn ?? false));
    void push(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    return AppPage.list(
      title: l10n.commonRemoteHost,
      subtitle: Text(l10n.remoteHostsIntro),
      actions: const [AskAiButton(AskAiTopic.remote)],
      children: [
        _ActiveCard(active: active),
        SettingsSection(
          title: l10n.remoteTransferSettings,
          children: [
            SettingsSwitchTile(
              key: const ValueKey('remote-compact-history'),
              spot: Spots.remoteCompactHistory,
              subtitle: l10n.remoteCompactHistoryHint,
              value: ref.watch(remoteCompactHistoryProvider),
              onChanged: (value) => unawaited(ref.read(remoteCompactHistoryProvider.notifier).set(value)),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.remoteSshHosts,
          footer: Text(l10n.remoteSshRequirements),
          children: [
            for (final h in ssh)
              _SshRow(
                config: h,
                active: active == HostRef.ssh(h.id),
                onTap: () => _use(context, ref, HostRef.ssh(h.id)),
                onEdit: () => push(SshHostFormPage(existing: h)),
              ),
            SettingsTile(
              icon: AppIcons.add,
              tinted: false,
              spot: Spots.addSshHost,
              subtitle: ssh.isEmpty ? l10n.remoteSshDirect : null,
              onTap: () => unawaited(_addSsh(context, ref)),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.remoteUrlHosts,
          footer: Text(l10n.remoteUrlRequirements),
          children: [
            for (final h in urls)
              _UrlRow(
                config: h,
                active: active == HostRef.url(h.id),
                onTap: () => _use(context, ref, HostRef.url(h.id)),
                onEdit: () => push(UrlHostFormPage(existing: h)),
              ),
            SettingsTile(
              icon: AppIcons.add,
              tinted: false,
              title: l10n.remoteAddUrlHost,
              subtitle: urls.isEmpty ? l10n.remoteUrlDirect : null,
              onTap: () => unawaited(_addUrl(context, ref)),
            ),
            SettingsTile(
              icon: AppIcons.qrCode,
              tinted: false,
              title: l10n.remoteScanQr,
              subtitle: l10n.remoteScanQrHint,
              onTap: () async {
                final config = await Navigator.of(context).push(UrlScanPage.route());
                if (config != null && context.mounted) await _use(context, ref, HostRef.url(config.id));
              },
            ),
          ],
        ),
        SettingsSection(
          title: l10n.remoteOtherMethods,
          children: [
            SettingsTile(
              icon: AppIcons.webConsole,
              tinted: false,
              title: l10n.remoteWebConsole,
              subtitle: l10n.remoteWebConsoleProvider,
              onTap: () => _openConsole(context),
            ),
          ],
        ),
        // Only meaningful once there is a host to come back to.
        if (ssh.isNotEmpty || urls.isNotEmpty || signedIn)
          SettingsSection(
            title: l10n.remoteStartupSection,
            children: [
              SettingsSwitchTile(
                key: const ValueKey('remote-auto-connect'),
                spot: Spots.remoteAutoConnect,
                subtitle: l10n.remoteAutoConnectOnStartupHint,
                value: ref.watch(remoteAutoConnectProvider),
                onChanged: (value) => unawaited(ref.read(remoteAutoConnectProvider.notifier).set(value)),
              ),
            ],
          ),
        SettingsSection(
          children: [
            SettingsTile(
              icon: AppIcons.save,
              spot: Spots.remoteSessionBackup,
              onTap: () => push(const SessionBackupPage()),
            ),
          ],
        ),
        const RemoteWebEntry(),
      ],
    );
  }
}

/// What the chat is talking to right now (only for a remote host), with live
/// state, the way back to 本机, and the failure with its one fix.
class _ActiveCard extends ConsumerWidget {
  const _ActiveCard({required this.active});

  final HostRef active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    if (active.isLocal) return const SizedBox.shrink();
    final status = ref.watch(hostLinkStatusProvider(active)).value ?? HostLinkStatus.idle;
    final view = HostStatusView.ofLink(status);
    final name = ref.watch(hostNameProvider(active)) ?? l10n.commonRemoteHost;
    final ssh = active.kind == HostKind.ssh ? ref.watch(hostsProvider).sshById(active.id) : null;
    final url = active.kind == HostKind.url ? ref.watch(hostsProvider).urlById(active.id) : null;
    final error = status.error;
    // Errors a retry can't fix go to the host's settings (SSH / URL) or the
    // trust check (relay) instead.
    final needsLogin = active.kind == HostKind.relay && error?.kind == HostLinkErrorKind.notLoggedIn;
    final needsSettings = (ssh != null || url != null) && error != null && !error.retryable;
    final needsTrust =
        active.kind == HostKind.relay &&
        (error?.kind == HostLinkErrorKind.hostKeyMismatch || error?.kind == HostLinkErrorKind.hostKeyUnverified);
    void reconnect() => ref.read(remoteConnectionProvider(active).notifier).retry();
    final failed = status.phase == HostLinkPhase.failed && error != null;
    // No runtime on this phone: 本机 is nowhere to go back to.
    final canGoLocal = ref.watch(localRuntimeProvider.select((s) => !s.status.runtimeMissing));
    return OverviewCard(
      leading: OverviewGlyph(hostKindIcon(active.kind), tint: hostKindTint(active.kind)),
      title: Text(l10n.remoteActiveHost(name)),
      subtitle: InkWell(
        onTap: active.kind == HostKind.relay && status.isConnected
            ? () => showRemoteNetworkDetails(context, active)
            : null,
        child: Row(
          children: [
            AnimatedStatusDot(tone: view.tone, size: 7),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                _statusLine(
                  status,
                  view,
                  ssh != null
                      ? l10n.remoteConnectedSsh(ssh.address)
                      : url != null
                      ? l10n.remoteConnectedUrl(url.address)
                      : null,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (active.kind == HostKind.relay && status.isConnected) ...[
              const SizedBox(width: 6),
              Tooltip(message: l10n.remoteNetworkDetails, child: const Icon(AppIcons.info, size: 16)),
            ],
          ],
        ),
      ),
      trailing: canGoLocal
          ? _EdgeTextButton(
              label: l10n.remoteSwitchToPhone,
              onPressed: () => ref.read(activeHostProvider.notifier).select(HostRef.local),
            )
          : null,
      footer: failed
          ? Padding(
              padding: const EdgeInsets.only(left: OverviewCard.inset, right: OverviewCard.inset - 12),
              child: LinkErrorBox(
                error: error,
                action: needsLogin
                    ? (
                        l10n.remoteSignInAgain,
                        () async {
                          if (ref.read(relayAccountProvider).value?.user?.provider == 'password') {
                            final backend = ref.read(relayBackendProvider);
                            final signedIn = await showSelfHostedLogin(
                              context,
                              initialServer: ref.read(relayServerProvider) ?? defaultRelayServer,
                            );
                            if (signedIn == true &&
                                context.mounted &&
                                ref.read(activeHostProvider) == active &&
                                identical(backend, ref.read(relayBackendProvider))) {
                              reconnect();
                            }
                            return;
                          }
                          await ref.read(relayAccountProvider.notifier).login();
                          if (context.mounted && (ref.read(relayAccountProvider).value?.signedIn ?? false)) reconnect();
                        },
                      )
                    : needsSettings
                    ? (
                        l10n.remoteHostSettings,
                        () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                ssh != null ? SshHostFormPage(existing: ssh) : UrlHostFormPage(existing: url),
                          ),
                        ),
                      )
                    : needsTrust
                    ? (
                        l10n.remoteHostKeyTrustAgain,
                        () async {
                          if (await activateHost(context, ref, active)) {
                            reconnect();
                          }
                        },
                      )
                    : (active.kind == HostKind.relay ? l10n.remoteReconnect : l10n.commonRetry, reconnect),
              ),
            )
          : null,
    );
  }

  static String _statusLine(HostLinkStatus status, HostStatusView view, String? connected) {
    if (status.phase == HostLinkPhase.reconnecting) {
      final why = status.error?.message;
      return why == null ? appL10n.remoteReconnectingEllipsis : appL10n.remoteReconnectReason(why);
    }
    if (status.phase == HostLinkPhase.connected) {
      if (connected != null) return connected;
      final path = status.network?.path ?? status.path;
      return path == null ? appL10n.remoteConnectedEncrypted : appL10n.remoteConnectedVia(path.label);
    }
    return view.label;
  }
}

/// Dot + word on the right of a host row.
class _HostState extends StatelessWidget {
  const _HostState(this.view);

  final HostStatusView view;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedStatusDot(tone: view.tone, size: 7),
        const SizedBox(width: 6),
        Text(view.label),
      ],
    );
  }
}

/// A trailing text button whose label ends exactly at the row's 16dp edge.
class _EdgeTextButton extends StatelessWidget {
  const _EdgeTextButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  /// Horizontal padding inside the button.
  static const _pad = 8.0;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      // Row padding (12) + button padding (8) − nudge (4) = 16 to the label.
      offset: const Offset(SettingsMetrics.trailingPad + _pad - SettingsMetrics.inset, 0),
      child: TextButton(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: _pad),
          minimumSize: const Size(0, 40),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: onPressed,
        child: Text(label),
      ),
    );
  }
}

/// A trailing 20dp icon button whose glyph ends at the row's 16dp edge.
class _EdgeIconButton extends StatelessWidget {
  const _EdgeIconButton({required this.icon, required this.tooltip, required this.onPressed, this.nudge = true});

  final Widget icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// False when another trailing button follows it.
  final bool nudge;

  @override
  Widget build(BuildContext context) {
    final button = IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      color: DshColors.of(context).textTertiary,
      icon: icon,
      onPressed: onPressed,
    );
    if (!nudge) return button;
    // Compact box 40, glyph 20: 10 of air; row padding 12 → nudge 6.
    return Transform.translate(
      offset: const Offset(SettingsMetrics.trailingPad + 10 - SettingsMetrics.inset, 0),
      child: button,
    );
  }
}

class _SshRow extends ConsumerWidget {
  const _SshRow({required this.config, required this.active, required this.onTap, required this.onEdit});

  final SshHostConfig config;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final view = active ? watchHostStatus(ref, HostRef.ssh(config.id)) : null;
    return Semantics(
      selected: active,
      inMutuallyExclusiveGroup: true,
      child: SettingsTile(
        icon: hostKindIcon(HostKind.ssh),
        tinted: false,
        title: config.name,
        subtitle: config.address,
        onTap: onTap,
        value: view == null ? null : _HostState(view),
        trailing: _EdgeIconButton(
          icon: const Icon(AppIcons.configure, size: 20),
          tooltip: l10n.commonEdit,
          onPressed: onEdit,
        ),
      ),
    );
  }
}

class _UrlRow extends ConsumerWidget {
  const _UrlRow({required this.config, required this.active, required this.onTap, required this.onEdit});

  final UrlHostConfig config;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final view = active ? watchHostStatus(ref, HostRef.url(config.id)) : null;
    return Semantics(
      selected: active,
      inMutuallyExclusiveGroup: true,
      child: SettingsTile(
        icon: hostKindIcon(HostKind.url),
        tinted: false,
        title: config.name,
        subtitle: config.address,
        onTap: onTap,
        value: view == null ? null : _HostState(view),
        trailing: _EdgeIconButton(
          icon: const Icon(AppIcons.configure, size: 20),
          tooltip: l10n.commonEdit,
          onPressed: onEdit,
        ),
      ),
    );
  }
}

// ── DSH Remote account ───────────────────────────────────────────────────────
