# Plugin removal plan (goal: remove plugins)

## Delivered (all green, `flutter analyze` 0 errors, top commit c8d6684)

36 plugin surfaces retired: market, plugin docs, plugin screens/settings entries,
feature-catalog plugin + CoT entries, engine-settings plugin section and its dead
wiring, config fallback + plugin search entries, every chat plugin rendering path
(notes, plus-tools, menus, strip, capsules, tool cards, tool views, overlay layer,
composer scope), the composer chain, the native plugin section, seam controls,
web places, reload action, capability scope, micro caption, tone, message menu,
overlay layer, settings tiles, seat probe, pet adapter, cordis island seat.

## The keystone

All three remaining clusters hang off **`lib/ui/plugins/plugin_detail_sheet.dart`**:

- its config block uses `state/plugin_config/*` + `config/plugin_config_entries`
  (deleting the config cluster gives 523 errors, nearly all in this sheet and in
  plugin tests importing `state/plugin_config`)
- it is imported by `media_settings_page`, three `ui/workshop` sheets,
  `market_tab`, `installed_tab`, `plugin_inventory_page`, `community_widgets`,
  `share_card`, `links/plugin_links`, plus 8 tests

The “core dependency” claim was wrong: `state/engine_settings_state.dart` only
mentions plugin_config in a comment. Nothing in core settings needs it.

## Order that will work (one pass, fresh context)

1. **Rewrite/delete `plugin_detail_sheet.dart`** together with its 8 importers:
   remove the sheet call sites from media settings, the three workshop sheets,
   market/installed tabs, inventory page, community widgets, share card and
   plugin links; then delete the sheet.
2. Delete `market_tab`, `installed_tab`, `plugin_inventory_page`,
   `lib/ui/plugins/config/`, `lib/state/plugin_config/` and their tests.
3. Media: chat generate mode + `ui/chat/media/generate_sheet.dart` + media cards,
   then `ui/settings/media_settings_page.dart`, `SettingsPageId.media`, spots.
4. `ui/workshop/` + its state providers.
5. `plugins/seams/`, `plugins/native/` leftovers (`native_taps`, `native_panel`,
   `native_model`, `native_state`), `state/plugins_state`, capability runtime.
6. `sdk/plugin-kit`, plugin tests, pubspec.

## Rules that held

- Run `cd app && flutter analyze --no-pub` after every step; 0 errors before commit.
- Relative imports hide usage: count importers by basename before deleting.
- `git rm` stages deletions: undo with `git reset HEAD <path> && git checkout -- <path>`.
- Keep `test/plugins/support/` until its non-plugin consumers move.
