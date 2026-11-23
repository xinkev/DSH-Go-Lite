// About DSH Go Lite: the installed version, the licence page, and what this
// build is made of — the engine it runs, the app it comes from, and the
// runtime it ships. The original author's personal profiles are not here:
// this build is not their app.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/app_info.dart';
import '../../state/star_prompt.dart' show starLinkOpenerProvider;
import '../../state/update_state.dart';
import '../shell/brand_mark.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'settings_widgets.dart';

/// The installed version as the app shows it: `1.3.0 (11231420)`.
String installedVersionLabel(WidgetRef ref) {
  // What Android reports as installed (the compiled-in constant until it does).
  final installed = ref.watch(appUpdateProvider.select((s) => s.current));
  return installed.build == null ? installed.name : '${installed.name} (${installed.build})';
}

class AboutPage extends ConsumerWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final version = installedVersionLabel(ref);
    return AppPage.list(
      title: l10n.hubAbout,
      children: [
        SettingsSection(
          children: [
            SettingsTile(
              spot: Spots.version,
              value: Text(version, style: AppType.tabular(theme.textTheme.bodyMedium!)),
            ),
            SettingsTile(
              spot: Spots.licenses,
              onTap: () => showLicensePage(
                context: context,
                applicationName: AppInfo.name,
                applicationVersion: version,
                applicationIcon: const Padding(padding: EdgeInsets.all(12), child: BrandMark(size: 56, tile: true)),
                applicationLegalese: AppInfo.disclaimer,
              ),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.hubAboutBuiltOn,
          children: [
            _link(
              context,
              ref,
              'about-harness',
              l10n.hubAboutHarness,
              l10n.hubAboutHarnessNote,
              AppInfo.harnessUrl,
            ),
            _link(
              context,
              ref,
              'about-original',
              l10n.hubAboutOriginal,
              l10n.hubAboutOriginalNote,
              AppInfo.authorGithubUrl,
            ),
            _link(
              context,
              ref,
              'about-runtime',
              l10n.hubAboutRuntime,
              l10n.hubAboutRuntimeNote,
              AppInfo.runtimeUrl,
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
          child: Column(
            children: [
              BrandMark(size: 18, color: colors.textDisabled),
              const SizedBox(height: 10),
              Text(
                AppInfo.slogan,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(color: colors.textTertiary),
              ),
              const SizedBox(height: 8),
              Text(
                AppInfo.disclaimer,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(color: colors.textTertiary),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _link(
    BuildContext context,
    WidgetRef ref,
    String key,
    String title,
    String note,
    String url,
  ) => Semantics(
    link: true,
    child: SettingsTile(
      key: ValueKey(key),
      title: title,
      subtitle: note,
      trailing: Icon(AppIcons.openExternal, size: 18, color: DshColors.of(context).textTertiary),
      onTap: () => unawaited(_open(context, ref, Uri.parse(url))),
    ),
  );

  Future<void> _open(BuildContext context, WidgetRef ref, Uri url) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      if (await ref.read(starLinkOpenerProvider)(url)) return;
    } catch (_) {
      // No browser: fall back to copying the address.
    }
    var copied = true;
    try {
      await Clipboard.setData(ClipboardData(text: url.toString()));
    } catch (_) {
      copied = false;
    }
    if (messenger?.mounted ?? false) {
      messenger!.showSnackBar(
        SnackBar(content: Text(copied ? l10n.shellBrowserUrlCopied : l10n.stateBrowserOpenFailed)),
      );
    }
  }
}
