# Plugin removal — state and the pets dependency

Top commit at this writing: `ca069df`, `flutter analyze` 0 errors, 50 plugin surfaces removed.

## Newly established dependency (rounds 85-86)

`lib/pets/pet_library.dart` imports `lib/workshop/workshop_models.dart`,
`workshop_receipt.dart` and `workshop_export.dart` (`WorkshopReceipt`, pet-pack
publishing). Deleting the workshop feature therefore produced **1,943 errors** and
was reverted.

So the workshop (plugin/pet publishing) cannot be removed while pets exist, and
pets cannot be removed yet: their engine (`pets/pet_state.dart`, `pet_signals.dart`,
`overlay_channel.dart`) still feeds live activity and the accessibility "overlay"
checklist item.

## Current dependency order

1. **pets teardown** (own objective, not started to completion): live-activity and
   access-overlay coupling first, then `lib/pets`, `lib/ui/pets`, assets.
2. **workshop** — `lib/ui/workshop`, `lib/workshop`, `lib/state/workshop_*`,
   `test/ui/workshop`; only `settings_search_page` + `Spots.workshop` reference it.
3. **plugin_detail_sheet** — now config-free, seat-free, action-free; its remaining
   importers are media settings, 3 workshop sheets, market/installed tabs,
   community widgets, share card, 4 tests.
4. market/installed tabs + `plugin_actions` + `market_widgets`.
5. media generation, then seats/islands/seams, `state/plugins_state`, capability
   runtime, `sdk/plugin-kit`, plugin tests, pubspec.

## What is safely done

Import sweep (27 dead imports), sheet config/seat/action detach, load-status,
reload action, overlay layer, settings tiles, seat probe, pet adapter, cordis seat,
message menu, tone, capability scope, micro caption, native plugin section, seam
controls, web places, plugin links, media install prompt, team enable, tabs'
call sites, config cluster and inventory page, plugin market/docs.
