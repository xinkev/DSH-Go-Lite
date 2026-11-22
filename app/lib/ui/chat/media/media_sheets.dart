// The two prompt sheets the composer shows when 生成 is pressed: the media
// plugin is missing (install), or its catalogue is unreadable (explain).

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../settings/media_settings_page.dart' show MediaInstallPrompt;
import '../../common/app_sheet.dart';
import '../../common/empty_view.dart';
import '../../theme/app_icons.dart';

/// The plugin market used to open here; it is retired.
Future<void> openMediaPluginMarket(BuildContext context, {Object? tab}) async {}

/// 生成 where the plugin runs but its catalogue is missing, damaged or of a
/// version this app doesn't know: no generation mode, chat works as usual.
Future<void> showMediaUnavailableSheet(BuildContext context) => showAppSheet<void>(
  context,
  builder: (sheet) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: EmptyView(
        icon: AppIcons.generateMedia,
        compact: true,
        title: context.l10n.mediaUnavailableTitle,
        message: context.l10n.mediaUnavailableBody,
        actionLabel: context.l10n.mediaUnavailableAction,
        onAction: () => Navigator.of(sheet).pop(),
      ),
    ),
  ),
);

/// 生成 on a host without the plugin: the same prompt as a sheet.
Future<void> showMediaInstallSheet(BuildContext context) => showAppSheet<void>(
  context,
  builder: (sheet) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: MediaInstallPrompt(compact: true, onInstalled: () => Navigator.of(sheet).pop()),
    ),
  ),
);
