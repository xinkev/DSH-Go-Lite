// 本地引擎: the runtime this APK does not carry. It is downloaded from the runtime
// release repository on first use, verified, and installed into app storage; this
// section shows what that costs and lets the person install, update, retry or delete it.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../common/app_dialog.dart';
import '../onboarding/setup_progress.dart' show runtimeInstallProvider;
import '../settings/settings_widgets.dart';
import '../theme/theme.dart';
import 'engine_screen.dart' show shortRuntimeVersion;

/// Visible on builds that install the runtime on demand, and while one is downloading.
class LocalEngineSection extends ConsumerStatefulWidget {
  const LocalEngineSection({super.key});

  @override
  ConsumerState<LocalEngineSection> createState() => _LocalEngineSectionState();
}

class _LocalEngineSectionState extends ConsumerState<LocalEngineSection> {
  @override
  void initState() {
    super.initState();
    // The manifest is small; reading it tells the section the size and version. It is
    // never read on launch, so remote hosts never touch the network for the runtime.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Modules the agent installed live in the rootfs; re-read so this section shows them.
      unawaited(ref.read(localRuntimeProvider.notifier).refreshStatus());
      final status = ref.read(localRuntimeProvider).status;
      if (status.releaseVersion != null ||
          status.phase == RuntimePhase.downloading ||
          status.phase == RuntimePhase.installing) {
        return;
      }
      unawaited(ref.read(localRuntimeProvider.notifier).checkRelease());
    });
  }

  Future<void> _install() => ref.read(runtimeInstallProvider.notifier).install();

  Future<void> _toggle(RuntimeOptionalLayer layer, bool install) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final failed = context.l10n.localEngineOptionalFailed;
    try {
      final runtime = ref.read(localRuntimeProvider.notifier);
      if (install) {
        await runtime.installOptionalLayer(layer.name);
      } else {
        await runtime.removeOptionalLayer(layer.name);
      }
    } catch (_) {
      messenger?.showSnackBar(SnackBar(content: Text(failed)));
    }
  }

  /// 文档转换 for office; a release that adds another layer shows its own name.
  String _layerLabel(BuildContext context, String name) => switch (name) {
    'office' => context.l10n.localEngineOffice,
    _ => name,
  };

  Future<void> _delete() async {
    final l10n = context.l10n;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.localEngineDeleteTitle),
        content: Text(l10n.localEngineDeleteBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final failed = l10n.phoneEngineResetFailed;
    try {
      await ref.read(localRuntimeProvider.notifier).resetKeeping(const ResetKeep());
      navigator.popUntil((route) => route.isFirst);
    } catch (_) {
      messenger?.showSnackBar(SnackBar(content: Text(failed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(localRuntimeProvider);
    final status = state.status;
    final colors = DshColors.of(context);
    final downloading = status.phase == RuntimePhase.downloading;
    final installing = status.phase == RuntimePhase.installing;
    final busy = downloading || installing;
    final installed = status.installedVersion;
    final sizeMb = status.downloadBytes == null ? null : (status.downloadBytes! / (1024 * 1024)).ceil();
    final progress = state.progress;
    final failure = status.phase == RuntimePhase.error && status.error != null;
    final engineStopped =
        status.installedVersion != null &&
        !status.phase.isBusy &&
        status.phase != RuntimePhase.running &&
        status.optionalBusy == null;

    return SettingsSection(
      title: l10n.localEngineTitle,
      children: [
        InfoRow(
          label: l10n.commonVersion,
          value: shortRuntimeVersion(installed ?? status.releaseVersion),
          mono: true,
        ),
        InfoRow(
          label: l10n.localEngineSizeLabel,
          value: sizeMb == null ? l10n.localEngineDownloadSizeUnknown : l10n.localEngineDownloadSize(sizeMb),
        ),
        if (busy)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(value: progress?.fraction),
                const SizedBox(height: 8),
                Text(
                  downloading ? l10n.localEngineDownloading : l10n.localEngineInstalling,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                ),
              ],
            ),
          ),
        if (status.releaseError != null && !busy)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              l10n.localEngineReleaseFailed,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.danger),
            ),
          ),
        if (failure)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              humanizeLocalEngineError(status.error) ?? l10n.localEngineDownloadFailed,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.danger),
            ),
          ),
        for (final layer in status.optionalLayers)
          SettingsSwitchTile(
            title: _layerLabel(context, layer.name),
            subtitle: status.optionalBusy == layer.name
                ? l10n.localEngineInstalling
                : layer.installed
                ? l10n.localEngineOptionalInstalled
                : status.installedVersion == null
                ? l10n.localEngineOptionalNeedsRuntime
                : layer.bytes == null
                ? l10n.localEngineDownloadSizeUnknown
                : l10n.localEngineDownloadSize((layer.bytes! / (1024 * 1024)).ceil()),
            value: layer.installed,
            onChanged: engineStopped ? (install) => unawaited(_toggle(layer, install)) : null,
          ),
        if (status.optionalBusy != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
            child: LinearProgressIndicator(value: progress?.fraction),
          ),
        if (status.runtimeManifestUrl case final url?)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.localEngineSource,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  url,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.textTertiary, height: 1.5),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (downloading)
                TextButton(
                  onPressed: () => unawaited(ref.read(localRuntimeProvider.notifier).cancelInstall()),
                  child: Text(l10n.localEngineCancel),
                )
              else if (!installing)
                FilledButton(
                  onPressed: _install,
                  child: Text(
                    installed == null
                        ? l10n.localEngineInstall
                        : status.updateAvailable
                        ? l10n.localEngineUpdate
                        : l10n.localEngineRetry,
                  ),
                ),
              if (!busy && installed != null)
                TextButton(
                  onPressed: _delete,
                  child: Text(l10n.localEngineDelete),
                ),
              if (!busy && status.releaseError != null)
                TextButton(
                  onPressed: () => unawaited(ref.read(localRuntimeProvider.notifier).checkRelease()),
                  child: Text(l10n.localEngineRetry),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Native install failures that have a sentence of their own; anything else is generic.
String? humanizeLocalEngineError(String? raw) {
  final text = raw?.trim();
  if (text == null || text.isEmpty) return null;
  if (text.contains('sha256')) return appL10n.localEngineChecksumFailed;
  if (text.contains('could not reach the runtime release') ||
      text.contains('invalid runtime release URL') ||
      text.contains('runtime release returned HTTP')) {
    return appL10n.localEngineReleaseFailed;
  }
  if (text.contains('cannot run the') && text.contains('runtime')) return appL10n.localEngineUnsupported;
  if (text.contains('runtime layer')) return appL10n.localEngineDownloadFailed;
  if (text.contains('runtime release manifest') || text.contains('runtime release has no')) {
    return appL10n.localEngineReleaseFailed;
  }
  return null;
}
