# Changelog

## 0.1.31

- Fixes legitimate Gen 1 Farfetch'd imports failing because RBY uses the symbolic ID `FARFETCHD` while Gold uses `FARFETCH_D`.
- Adds the equivalent Gen 1 -> Gold compatibility mapping for Mr. Mime: `MR_MIME` -> `MR__MIME`.
- Applies the same canonical species mapping to imported Pokédex seen/caught state so Gen 1-only spellings do not leak into Gold saves.
- Keeps unsupported/fakemon species as explicit import failures when they are physically present in the party or PC boxes.
- Existing successfully imported Project Celebi saves do not need to re-import; affected players should retry their original Gen 1 save with v0.1.31.
- Retains v0.1.30 Victory Road Gate QoL, rival continuity, Johto badge repair, trainer parity scaling, and wild catch-up scaling.
- Save metadata schema remains 11; this is an importer compatibility hotfix, not a save-format migration.

## 0.1.30

- Opens the Viridian/Route 22 side of Victory Road Gate for imported Gen 1 Champions, allowing a fully walkable Kanto -> Johto route without first Flying to Indigo Plateau.
- Targets only the east Black Belt at `(12,5)` using a per-map live object mask.
- Does **not** set `EVENT_FOUGHT_SNORLAX`, preserving Gold's real Vermilion Snorlax encounter and all unrelated event state.
- Leaves the west Black Belt at `(7,5)` untouched so native `EVENT_OPENED_MT_SILVER` progression continues to protect Mt. Silver.
- Retains the existing Project Celebi Champion scene-1 bypass for the central eight-Johto-badges officer check without granting fake Johto badges.
- Adds `diagnostics.victoryRoadGate` with guard resolution/removal state.
- Bumps Project Celebi metadata schema to 11; no re-import or one-shot migration is required.
- Retains v0.1.29 Silver continuity, Johto badge repair, trainer scaling and wild catch-up scaling.

## 0.1.29

- Fixes the root invisible-Silver bug revealed by the uploaded beta save: the failing scene was Sprout Tower 3F, not Burned Tower.
- Fresh imports no longer hide every `SPRITE_RIVAL`; the pre-Johto bootstrap now locks only Victory Road and Mt. Moon.
- Adds a schema-10 one-shot Sprout Tower repair for existing saves: re-arms scene 0, clears the exact rival event, and invokes Gold's native `World:appearObject()` before the coord-event can address Silver.
- Retains the native Burned Tower live-object repair for its pre-visible deferred scene.
- Fixes the Project Celebi HM menu badge shim leaking all eight temporary Johto badges when the original badge keys were absent.
- Schema-10 migration reconstructs genuine Johto badge ownership from native gym-victory script events, with fail-safe diagnostics if all eight badge award paths cannot be discovered.
- Corrects Johto badge counting to Gold's canonical eight badge slots.
- Corrects Gold Hall-of-Fame detection to use `hallOfFame.count > 0` instead of treating the always-present HOF table as completion.
- Adds Sprout Tower and Johto badge-repair diagnostics.
- Retains trainer parity scaling, wild catch-up scaling, imported Gen 1 history, and all earlier Project Celebi world-state fixes.

## 0.1.28

- Replaces the Burned Tower mask-refresh workaround with Gold's native live-object `World:appearObject()` path.
- Resolves Silver from the active Burned Tower map definition and uses his extracted object constant (`obj.index + 1`).
- Native repair clears Silver's exact event flag, clears his individual object mask, discards any stale pooled NPC, and rebuilds the live people list before scene 0 starts.
- Adds a defensive engine-internals fallback that directly unmasks/rebuilds the same exact rival object if the native helper is unavailable or does not produce a live entity.
- Adds schema-9 migration for existing v0.1.27 Project Celebi saves; no re-import required.
- Adds `burnedTowerNativeRepair` diagnostics with object id/index, event flag, mask state, native-call result, and before/after live-entity verification.
- Retains Silver chronology, trainer parity scaling, wild catch-up scaling, and all earlier Project Celebi world-state fixes.

## 0.1.27

- Fixes Burned Tower Silver being invisible while his native dialogue/movement scene still executes.
- Targets the native `EVENT_RIVAL_BURNED_TOWER` object flag through the extracted `SPRITE_RIVAL` row.
- Proactively clears the Burned Tower rival flag while its scene is still pending.
- On Burned Tower entry/continue, immediately reruns `loadObjectMasks()` and `rebuildPeople()` in the `map.entered` pre-scene window so Silver exists in the live people list before the deferred scene starts.
- Adds schema-8 migration for existing v0.1.26 Project Celebi saves; no re-import required.
- Adds Burned Tower mask-refresh/event-clear diagnostics.
- Retains v0.1.26 Silver chronology, metadata fixes, trainer parity scaling and wild catch-up scaling.

## 0.1.26

- Restored Silver continuity after the Project Celebi New Bark introduction.
- Permanently skips the rookie Cherrygrove rival battle.
- Removes the v0.1.25 runtime bug that re-hid every `SPRITE_RIVAL` object after every map transition.
- Repairs Burned Tower Silver when its native rival scene is still pending.
- Leaves Azalea and Goldenrod Underground to Gold's native `appear`-driven rival scripts.
- Re-arms Victory Road's native Silver scene only after eight genuine Johto badges.
- Re-arms Mt. Moon's post-League Silver scene/object only after Gold has its own Hall of Fame entry.
- Adds schema-7 migration for existing Project Celebi saves; no new import required.
- Corrects fresh-import `schema` / `bridgeVersion` metadata to 7 / 0.1.26.
- Adds rival chronology diagnostics, repair tracing, build/map diagnostics and rival battle scaling snapshots.
- Retains v0.1.25 trainer parity scaling and Johto wild catch-up scaling unchanged.

## 0.1.25

- Rebalanced Project Celebi Johto Trainer Scaling around direct parity with the frozen Project Celebi Difficulty Rating.
- New trainer curve: `rating - 3 + round(vanilla * 0.25) + boss bonus`.
- Retains +2 Rival, +3 Gym Leader and +4 League/Champion bonuses.
- Retains one-stage level-evolution promotion and preservation of authored trainer moves/items/DVs/stat EXP.
- Added Johto Wild Catch-Up v1 using Gold's supported `encounter.species` and `encounter.fishing` hooks.
- Ordinary Johto wild encounters target a `rating - 15` through `rating - 10` catch-up band while retaining a small amount of vanilla area progression.
- Never downscales a naturally stronger vanilla wild encounter.
- Covers normal grass/cave/surf rolls, `randomwildmon` map-table rolls, Sweet Scent and fishing.
- Leaves Bug-Catching Contest encounters, roaming beasts and authored static wild encounters untouched.
- Keeps Kanto trainer and wild scaling disabled.
- Adds `lastWildScale` and wild encounter counters to Project Celebi difficulty diagnostics.
- Bumps Project Celebi campaign metadata schema to 6; no re-import required.

## 0.1.24

- Added Project Celebi Johto Trainer Scaling v1 using Gold's supported `trainer.party` hook.
- Uses the immutable Project Celebi Difficulty Rating frozen at Johto entry.
- Preserves the relative progression encoded by vanilla trainer levels.
- Adds +3 Gym Leader, +2 Rival and +4 League/Champion level bonuses.
- Never downscales a vanilla trainer Pokemon.
- Promotes each enemy by at most one ordinary level-evolution stage.
- Preserves trainer DVs, stat EXP, held items and authored moves.
- Restricts scaling to the active Johto campaign / Johto endgame territory.
- Leaves Kanto trainers and wild Pokemon unchanged.
- Adds detailed last-battle scaling diagnostics to Project Celebi difficulty metadata.
- Retains all v0.1.23 tutorial/world-state fixes.

## 0.1.23

- Added a Project Celebi Johto tutorial-invariant layer.
- Dynamically discovers Elm's post-Mystery-Egg event ids from extracted scripts.
- Mirrors vanilla `EVENT_ROUTE_30_BATTLE` completion when Elm's own completion
  event is present.
- Adds Project Celebi fallback: Mr. Pokemon's House -> Elm's Lab opens Route 30.
- Clears Joey's pre-battle visibility event exactly as vanilla Elm does.
- Refreshes Route 30 object masks immediately if the player is already there.
- Adds schema 4 campaign metadata for the opening research-loop milestone.
- Retains Johto border bootstrap, Silver chronology, Difficulty Rating,
  native Pokegear/Fly, HM permissions, Kanto gym completion, money transfer
  and trainer-event persistence.

## 0.1.22

- Fixed Route 27 Johto activation using stale serialized `save.position`.
- Border detection now uses live `world.player.cellX/cellY`.
- Added first-unambiguous-Johto-map activation fallback.
- Permanently enforces New Bark scene 1 after Johto activation.
- Permanently keeps Cherrygrove rival scene 0 until later Silver progression.
- Added explicit New Bark scene diagnostic logging.
- Retains v0.1.21 Difficulty Rating and rival chronology.
- Retains v0.1.20 native Pokegear/Fly and all earlier continuity fixes.

## 0.1.21

- Added formal `campaign.state` with `KANTO_FREE_ROAM` and `JOHTO_INTRO`.
- Johto campaign remains locked until the physical Route 27 regional boundary.
- Silver remains globally hidden while the campaign is `KANTO_FREE_ROAM`.
- Border crossing changes Silver to `ARMED_NEW_BARK`.
- New Bark becomes Silver's first and only active appearance at this stage.
- Forces New Bark's rookie "don't leave without a Pokemon" scene to NOOP.
- Forces Cherrygrove's premature rival battle scene to NOOP.
- Added immutable Project Celebi Difficulty Rating at first Johto entry.
- Difficulty uses the median of the strongest three active party levels.
- Added schema 3 migration for older Project Celebi saves.
- Does not yet apply trainer/wild/gym scaling.
- Retains native Pokegear/Fly, HM permissions, Kanto gym state, money transfer,
  trainer-event persistence and all v0.1.20 behavior.

## 0.1.20

- Rebuilt Fly/Pokegear work from known-good v0.1.15.
- Seeds native Gold `engineFlags[0..4]` for Radio, Map, Phone, EXPN and Pokegear.
- Seeds compatibility `pokegearFlags` overlay as well.
- Seeds native `ENGINE_FLYPOINT_*` state from `Gen2FieldMoves.FLYPOINTS`.
- Verified Gen 1 Champions receive Gold's Kanto Fly destinations, including Indigo.
- Johto Fly destinations remain genuine progression/discovery state.
- Removed Project Celebi's custom Fly UI interception entirely.
- FLY now returns Gold's normal `{ok=true, action="fly"}` result.
- Gold's own `World:openFlyMap()` now constructs the dedicated Gen2 Pokegear FlyMap.
- Native Pokegear is opened with a real `onClose` callback to prevent the old softlock.
- Avoids duplicate Pokegear START rows once Gold's native row is visible.
- Retains all v0.1.15 money, Kanto gym, Silver chronology, HM and trainer-state fixes.

## 0.1.15

- Corrected Kanto badge storage against Gold v0.1.78's actual
  `World:engineFlag` implementation.
- Removed dead string-key ENGINE_*BADGE writes.
- Uses `FieldMoves.BADGE_FLAG` dynamically to populate the exact
  `player.kantoBadges` keys Gold checks.
- Recognizes Kanto Gym Leaders as script NPCs rather than OBJECTTYPE_TRAINER.
- Derives completed gym events from extracted scripts that set an owned Kanto
  badge, then applies their victory `setevent` rows.
- Repairs existing Project Celebi saves at runtime.
- Retains Silver chronology, money transfer, HM authorization, Fly and trainer
  state persistence.

## 0.1.14

- Fixed Kanto Gym Leaders still offering first-time battles.
- Added explicit imported-badge -> Gold ENGINE_*BADGE mapping.
- Seeds ENGINE_BOULDERBADGE, ENGINE_CASCADEBADGE, ENGINE_THUNDERBADGE,
  ENGINE_RAINBOWBADGE, ENGINE_SOULBADGE, ENGINE_MARSHBADGE,
  ENGINE_VOLCANOBADGE and ENGINE_EARTHBADGE.
- Keeps `player.kantoBadges` populated as well.
- Repairs existing Project Celebi saves at runtime; no re-import required.
- Does not set any Johto Gym badge flags.

## 0.1.13

- Fixed v0.1.12 START-menu regression caused by a Lua local being referenced
  before its lexical declaration.
- Forward-declares `ensureLegacyCanonicalWorldState` before START-hook registration.
- Uses Gold's normal `peopleDirty` refresh path after rival visibility changes.
- Retains v0.1.12 rival chronology, Kanto gym completion and money import changes.
- Retains v0.1.11 trainer/event snapshot preservation across Project Celebi Fly.

## 0.1.12

- Added a formal `rival.state = LOCKED` Project Celebi campaign state.
- Hides all extracted SPRITE_RIVAL objects before New Bark.
- Forces Mt. Moon and Victory Road rival scenes to their vanilla NOOP scene.
- Reveals only New Bark's rival at the first New Bark entry.
- Copies historical Gen 1 badges into Gold's native Kanto badge store.
- Dynamically finds the eight Gold Kanto Gym Leader trainer event ids from
  extracted trainer class metadata and marks those leaders defeated.
- Leaves ordinary Kanto trainers battleable.
- Reworked source-money resolution across native save shapes.
- Added fallback decoding of Gen 1's three-byte BCD money field at SRAM $25F3.
- Records the selected money source in Project Celebi transfer metadata.
- Retains v0.1.11 world snapshotting so trainer/event state survives Project Celebi Fly.

## 0.1.11

- Rebuilt from known-good v0.1.9.
- Removes the v0.1.10 Lua syntax regression that prevented the mod from loading.
- Calls Gold Game2:snapshotSave() before every Project Celebi Fly relocation.
- Calls Game2:snapshotSave() before the Tohjo forced relocation.
- Preserves live trainer-defeat events, map scenes, script memory, player state,
  variable sprites and backup-warp state before rebuilding the World.
- Keeps v0.1.9's working Project Celebi Fly and safe POKéGEAR UI.

## 0.1.9

- Removed the ambiguous Gold beta `world:flyTo()` attempt from Project Celebi Fly.
- Project Celebi Fly now always uses the proven collision-safe relocation path.
- Removed direct instantiation of Gold's native beta Pokegear screen because it
  could not exit cleanly when opened outside its expected story/UI path.
- Added an ordinary Project Celebi POKéGEAR ListMenu with MAP and CANCEL.
- MAP opens the Project Celebi Kanto Fly list.
- CANCEL explicitly pops the utility screen.
- Fly destination selection no longer attempts to close the list before
  `continueGame`; the world reload clears the UI stack itself.

## 0.1.8

- Fixed runtime reliance on nonexistent/unreliable `mod.game`.
- Captures the live Gold Game through the START menu hook.
- Inserts a Project Celebi POKéGEAR row directly.
- Attempts Gold's native Pokegear constructor with a safe fallback.
- Adds a functional FLY TO? picker from Blue's visited-town history.
- Prefers Gold's `world:flyTo`, with collision-safe Project Celebi relocation fallback.
- Routes HM, Victory Road, and Tohjo runtime code through the captured Game.

## 0.1.7

- Enables `ENGINE_POKEGEAR` for Project Celebi trainers.
- Enables `ENGINE_MAP_CARD` for Project Celebi trainers.
- Does not grant Phone, Radio, or EXPN cards.
- Applies the two utility flags to both new imports and existing Project Celebi slots.
- Recovers Gen 1 `visited` Fly history from the active source save when an
  existing Project Celebi save predates visited-town transfer.
- Records travel-device/flypoint diagnostics under Project Celebi metadata.

## 0.1.6

- Identified that Gold's Pokemon-action field-move path bypasses
  `fieldmove.eligibility` and calls `FieldMoves.fromMenu` directly.
- Added a Project Celebi-only wrapper around that exact pure decision function.
- Temporarily supplies Gold's own CheckBadge implementation with its expected
  Johto badge bits for the duration of the call.
- Uses `FieldMoves.BADGE_FLAG` dynamically instead of hard-coding internal Gold
  badge save-key names.
- Restores every temporary badge bit immediately.
- Applies only to the five Gen 1 HM moves with matching imported Gen 1 badges.
- Leaves WATERFALL / WHIRLPOOL and all persistent Gold progression untouched.

## 0.1.5

- Added `fieldmove.eligibility` hook for Project Celebi saves.
- Imported Cascade Badge authorizes CUT.
- Imported Thunder Badge authorizes FLY.
- Imported Soul Badge authorizes SURF.
- Imported Rainbow Badge authorizes STRENGTH.
- Imported Boulder Badge authorizes FLASH.
- Vanilla Gold eligibility always wins first.
- Requires a party Pokemon that actually knows the requested move.
- Does not modify Gold's native Johto/Kanto badge stores.
- Does not authorize Gen 2-only field moves.

## 0.1.4

- Transfers Gen 1 money and Game Corner coins.
- Transfers compatible Gen 1 bag items into Gold's native flat inventory.
- Transfers compatible Gen 1 PC item storage.
- Matches items semantically by constant id rather than raw item/TM number.
- Preserves HM_CUT / HM_FLY / HM_SURF / HM_STRENGTH / HM_FLASH where owned.
- Maps THUNDER_STONE -> THUNDERSTONE and EXP_ALL -> EXP_SHARE.
- Filters Gen 1 badge pseudo-items out of the live Gold Pack.
- Filters CARD_KEY and S_S_TICKET to prevent unrelated Gold story unlocks.
- Carries Gen 1 visited-town history as `save.visited`.
- Records exact transferred/skipped/aliased item audit data.

## 0.1.3

- Recognizes the vanilla Victory Road Gate receptionist as a separate Legacy
  progression barrier.
- For proven Gen 1 Champions, sets only `VICTORY_ROAD_GATE`'s scene to the
  vanilla post-badge-check NOOP scene.
- Persists the scene in both the live World and save `mapScenes`.
- Does not award Johto badges or alter Gold Elite Four progression.
- Records the authorization under Project Celebi Kanto metadata.

## 0.1.2

- Added a Project Celebi Champion passage through Tohjo Falls without granting Waterfall.
- Uses Gold's actual Route 27 Tohjo warp definitions to find the western exit.
- Uses the existing collision resolver to select a safe outside landing cell.
- Defers the world rebuild until `world.stepped` to avoid recursive map entry.
- Marks `johto.started` only when the player physically walks west across
  Route 27's canonical Kanto/Johto boundary at x <= 18.
- Leaves all Gold-native story and Elite Four state untouched.

## 0.1.1

- Added Gold COLL_*-based destination validation via Gen2 Map predicates.
- Added nearest-safe-cell correction for invalid/blocked exact coordinates.
- Avoids spawning directly on NPC/object cells and warp cells where possible.
- Added the first explicit Gen 1 -> Gold Kanto map crosswalk.
- Added entry-seeded placement for collapsed/removed maps whose source X/Y no
  longer describe the same physical geometry.
- Records requested/resolved position and correction metadata for auditing.

## 0.1.0

- Added layered Gen 1 Champion detection.
- Uses native Gen1Recomp Hall of Fame records when present.
- Recognizes Gen1Recomp's post-credits `postGameHomeOk` marker.
- Adds an eight-badge-gated raw SRAM Hall of Fame fallback for imported
  cartridge/emulator saves whose bank-0 HOF bytes survive in `rawImport`.
- Records detection method and Hall of Fame entry count in Project Celebi metadata.
- Does not touch Gold-native Hall of Fame or story progression.

## 0.0.9

- Transfers all Pokemon from Gen 1 boxes 1-12 into Gold boxes 1-12.
- Creates Gold boxes 13-14 empty.
- Preserves the active/current box number.
- Uses the same Gold `Mon.new()` conversion path for party and boxed Pokemon.
- Carries the Gen 1 play clock into Gold's H/M/S/frame save format.
- Records transferred box/Pokemon counts in `modData.legacy_bridge.transfer`.

## 0.0.8

- Replaced `deepCopy(game.save)` with Gold's native `Save.newGame()` constructor.
- Project Celebi destinations no longer inherit the invoking Gold playthrough's starter,
  events, map scenes, inventory, badges, phone state, or other progression.
- Anchors the new Gold clock using Game2's own exposed new-game helper.
- Normalizes the generated destination through Gold's native save layer.
- Keeps the proven single-screen raw Gen 1 source reader and one-click importer.

## 0.0.7

- First end-to-end installed-mod Project Celebi import.
- Keeps v0.0.6's proven raw source reader.
- Keeps the single custom-screen UI and correct `item.value` callback.
- Re-enables trainer / party / Pokedex / direct-position conversion.
- Uses Gold's own Gen 2 `Mon.new` for destination Pokemon.
- Allocates a brand-new Gold slot and never overwrites either source save.
- Makes the new Gold slot active and reloads directly into the imported Kanto position.
- Still uses the current clean Gold save as a temporary story-state skeleton.

## 0.0.6

- Diagnosed repeated crashes from `lua-error.log`: missing second custom UI screen.
- Removed nested custom-screen navigation.
- Fixed `ListMenu.onChoose` handling to use `item.value`.
- Successful source reads now report through `game:say`.
- Still read-only: no slot creation, writes, or world reload.

## 0.0.5

- Removed `SaveData.load(version)` from cross-generation source reads.
- Reads the engine-resolved absolute slot path through raw `io.open`.
- Decodes source data directly with `SaveSerializer.decode`, matching the launcher's non-migrating inspection behavior.
- Read-only diagnostic: no Gold slot creation, no save writes, no `continueGame`.

## 0.0.4

- Fixed the active-slot/menu-id mismatch seen on the live Windows v0.1.78 build.
- Source identity now comes directly from `SaveData.activeSlot(version)` after selection.
- Only each Gen 1 game's active slot is listed in this prototype.
- Source loading remains entirely on `SaveData.load(version)`.

## 0.0.3

- Fixed selected-source reads by using `SaveData.load(version)` instead of reconstructing the persistence path.
- Requires the selected Gen 1 source slot to be that game's active slot in this prototype.
- Marks active source slots in the CELEBI list.
- Shows the exact source-read failure text in-game for debugging.

## 0.0.2

- Added the first one-click Project Celebi import.
- Creates a brand-new Gold slot; does not overwrite the source or current Gold slot.
- Transfers Gen 1 trainer name and trainer ID.
- Converts the complete six-member party using Gold v0.1.78's own `Mon.new`.
- Preserves exact EXP, DVs, Stat EXP, nicknames, OT/ID, moves, PP and PP Ups.
- Merges Gen 1 Pokedex seen/owned into Gold seen/caught.
- Transfers exact map/X/Y when Gold contains the same map id.
- Reloads immediately into the new Project Celebi slot.
- Adds provenance/progression state under `modData.legacy_bridge`.

## 0.0.1

- First installable Project Celebi prototype.
- Added START -> CELEBI in Pokemon Gold.
- Detected native Red/Blue/Yellow Gen1Recomp slots.
- Read source slots without modifying them.
