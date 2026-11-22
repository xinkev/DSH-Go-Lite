# Plugin removal plan (goal: remove plugins)

## Delivered (all green, `flutter analyze` 0 errors)

- `market/`, `docs/plugins/` deleted
- plugin screens/settings ids/rows/spots; feature-catalog plugin + CoT entries
- engine-settings plugin section; plugin config fallback + plugin search entries
- chat: turn notes, plus-panel plugin tools, message-menu groups, composer strip,
  capsule bar, tool cards, tool views, overlay layer, `NativeComposerScope` lookups
- composer chain deleted (`native_composer_bar`, `composer_strip`, `composer_capsules`,
  `chat_plugins_sheet`) with their panes and tests
- `rise_reveal`, `message_plugin_menu`, `native_tone`, `native_capability_scope`,
  `native_micro_caption`, `plugin_overlay_layer`, `plugin_settings_tiles`,
  `seat_probe`, `plugin_reload_action` deleted with their tests
- turn footnote rewritten without plugin notes

31 surfaces retired. Single-file deletions are now exhausted; everything left is
in three coupled clusters.

## Remaining clusters (delete as a unit, not file by file)

1. **Media generation** — `ui/settings/media_settings_page.dart` is also the chat's
   “install media plugin” prompt (`showMediaInstallSheet`, `showMediaUnavailableSheet`).
   Order: composer 生成 mode + `ui/chat/media/generate_sheet.dart` + media cards →
   `state/media_*.dart` → the settings page + `SettingsPageId.media` + spots row.
   Touches `chat_screen` (import + two calls), `settings_pages`, `spots`,
   `settings_screen`, tests under `test/media`.
2. **plugin_detail_sheet cluster** — imported by `media_settings_page` (see 1),
   three workshop sheets, `market_tab`/`installed_tab`/`plugin_inventory_page`,
   `feature_catalog`, `community_widgets`, `share_card`, `links/plugin_links`,
   plus 8 tests. Falls after media and workshop.
3. **Runtime/seams** — `plugins/seams/*`, `plugins/native/*` (`native_taps`,
   `native_panel`, `native_model`, `native_state`), `state/plugins_state.dart`,
   capability runtime, `sdk/plugin-kit`, plugin tests, pubspec.

## Rules that held

- One unit per commit; `cd app && flutter analyze --no-pub` must print 0.
- Never delete before the last import is gone; relative imports hide usage.
- `git rm` stages deletions: undo with `git reset HEAD <path> && git checkout -- <path>`.
- Shared test harness `test/plugins/support/` stays until its non-plugin consumers move.
