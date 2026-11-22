# Plugin removal plan (goal: remove plugins)

State at plan time: branch `strip-cosmetics`, `flutter analyze` 0 errors,
plugin market/docs/screens already deleted (`e033155`, `a32ebf6`).

Delivered so far: `market/`, `docs/plugins/`, `plugins_screen.dart`,
`plugin_inventory_page.dart`, their settings ids/rows/spots.

## Rule

One slice per commit; `cd app && flutter analyze --no-pub` must print 0 errors
before committing. Never delete a file before its last import is gone — relative
imports hide usage from path-based greps.

## Slices, in order

1. **Feature catalog** — `app/lib/ui/features/feature_catalog.dart`
   - drop the 插件 section (`catalogPlugins`) and its items
   - drop the plugin-bundle loader helper and imports of `../plugins/*`
2. **Chat surface** — `chat_screen.dart`, `composer.dart`, `plus_panel.dart`,
   `tool_row.dart`, `assistant_message.dart`, `turn_footnote.dart`
   - remove `NativeComposerScope`, composer strips/capsules, plugin tool cards,
     plugin turn notes, plugin plus-panel tools; then delete `ui/plugins/native/*`
3. **Engine settings hub** — `engine_settings_hub.dart`: plugin settings section
   (already missing its inventory row), then `plugins/plugin_*_state`
4. **Seats/config** — `ui/plugins/seats/`, `ui/plugins/config/`, `ui/plugins/view/`
5. **State/runtime** — `state/plugins_state.dart`, `app/lib/plugins/`
   (capability runtime, seams), `installedPluginsProvider` users
6. **Media generation** — `state/media_*.dart`, `ui/settings/media_settings_page.dart`,
   `ui/chat/media/*` (drops image/video generation, per instruction)
7. **SDK + tests** — `sdk/plugin-kit/`, plugin tests under `app/test/`, docs leftovers
8. **Pubspec** — drop `dsh_client` plugin-facing fields only if unused afterwards

## Known traps

- `plugins_screen.dart` / `plugin_inventory_page.dart` exist in **both**
  `lib/plugins` and `lib/ui/plugins`; check which one is imported.
- `git rm` stages deletions: restore with `git reset HEAD <path> && git checkout -- <path>`.
- `pluginSettingsTiles`, `installedPluginsProvider`, `market` providers are used by
  settings, chat and feature catalog — remove consumers first.
