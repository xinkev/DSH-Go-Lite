// Explains the required mobile capability and offers the authenticated Web UI
// when the host has no usable mobile API. Missing plugins can also be installed.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/bots_state.dart';
import '../common/empty_view.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../common/brief_notice.dart';
import '../web/dsh_web_launcher.dart';
import '../web/web_target.dart';

/// Uses the existing authenticated DSH Web launcher. Tests replace only this edge.
final dsBotWebOpenerProvider = Provider<void Function(BuildContext context, WidgetRef ref)>(
  (ref) =>
      (context, ref) => openDshWeb(context, ref, target: const DshWebTarget(sidebar: true)),
);

class DsBotInstallCard extends ConsumerWidget {
  const DsBotInstallCard({super.key, required this.status});

  final DsBotStatus status;

  bool get _update => status.availability == DsBotAvailability.outdated;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final title = _update ? l10n.botsMobileUnsupportedTitle : l10n.botsInstall;
    final message = _update ? l10n.botsMobileApiRequired : l10n.botsMobileApiMissing;
    return EmptyView(
      icon: AppIcons.bot,
      title: title,
      message: message,
      padding: const EdgeInsets.fromLTRB(32, 40, 32, 24),
      action: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton.icon(
            key: const ValueKey('dsbot-open-web'),
            onPressed: () => ref.read(dsBotWebOpenerProvider)(context, ref),
            icon: const Icon(AppIcons.webApp, size: 18),
            label: Text(l10n.commonOpenInWeb),
          ),
          const SizedBox(height: 8),
          if (_update)
            TextButton(
              key: const ValueKey('dsbot-recheck-mobile'),
              onPressed: () => ref.read(dsBotProvider.notifier).retry(),
              child: Text(l10n.commonRetry),
            )
        ],
      ),
    );
  }
}
