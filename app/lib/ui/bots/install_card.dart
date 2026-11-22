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

/// The command that adds DS Bot to a `dsh web` profile on a computer.
const dsBotInstallCommand = 'dsh plugin --profile web add ds-bot';

/// Uses the existing authenticated DSH Web launcher. Tests replace only this edge.
final dsBotWebOpenerProvider = Provider<void Function(BuildContext context, WidgetRef ref)>(
  (ref) =>
      (context, ref) => openDshWeb(context, ref, target: const DshWebTarget(sidebar: true)),
);

class DsBotInstallCard extends ConsumerWidget {
  const DsBotInstallCard({super.key, required this.status});

  final DsBotStatus status;

  bool get _update => status.availability == DsBotAvailability.outdated;

  Future<void> _install(BuildContext context, WidgetRef ref) async {
    // Plugin installs are retired: there is nothing to install.
  }

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

/// A monospace command with a copy key, as the plugin page shows it.
class _CommandWell extends StatelessWidget {
  const _CommandWell({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final dsh = DshColors.of(context);
    return GlassSurface(
      tier: GlassTier.card,
      borderRadius: AppShape.radiusMd,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: SelectableText(command, maxLines: 1, style: AppType.monoSmall(color: dsh.codeWellFg)),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: l10n.commonCopy,
              icon: const Icon(AppIcons.copy, size: 18),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: command));
                showBriefNotice(context, l10n.commonCopied);
              },
            ),
          ],
        ),
      ),
    );
  }
}
