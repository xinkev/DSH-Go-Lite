// The first-run summary names where things live in 设置; the names must be
// the way there as the settings hub has it (系统权限 and 语音 sit under
// 通用), in both languages (0.9.8 smoke 02w).

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/settings/index/spots.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final locale in [AppLocale.zhCN, AppLocale.en]) {
    test('summary paths follow the settings hub: ${locale.languageCode}', () {
      final l10n = lookupL10n(locale);
      String way(SettingsPageId id) => SettingsIndex.path(SettingsIndex.entry(id), l10n).join(' › ');
      final access = way(SettingsPageId.systemAccess);
      expect(access, locale == AppLocale.en ? 'Settings › General › System permissions' : '设置 › 通用 › 系统权限');
      expect(l10n.accessSummaryMessage, contains(access));
    });
  }
}
