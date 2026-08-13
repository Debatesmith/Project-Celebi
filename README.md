# Project Celebi v0.1.31

> **v0.1.31 public-beta hotfix:** Gen 1 `FARFETCHD` and `MR_MIME` are now translated to Gold's canonical `FARFETCH_D` and `MR__MIME` species IDs during party, box, and Pokédex import.

## Release-candidate Kanto -> Johto access

Imported Gen 1 Champions can now walk from Viridian/Route 22 through the
Victory Road Gate instead of being forced to Fly to Indigo Plateau first.

Gold places two separate Black Belt gatekeepers in that intersection:

    east / Route 22 guard   (12,5)  -> EVENT_FOUGHT_SNORLAX
    west / Mt. Silver guard (7,5)   -> EVENT_OPENED_MT_SILVER

v0.1.30 masks only the east/Route 22 guard while a Project Celebi Champion is in the
gate. It deliberately does NOT set EVENT_FOUGHT_SNORLAX, because that event
also controls Gold's real Vermilion Snorlax encounter. The Mt. Silver guard is
left untouched and disappears only when Gold's normal Mt. Silver progression
opens it.

The existing Project Celebi Champion badge-check bypass remains unchanged, so the
player can walk Route 22 -> Victory Road Gate -> Route 26/27 -> Johto without
being granted fake Johto badges.

`modData.legacy_bridge.diagnostics.victoryRoadGate` records whether the exact
Route 22 guard object was found and masked.


## Silver Continuity v2

No new import is required. Existing Project Celebi saves are migrated in place.

The Project Celebi rival chronology is:

    New Bark sighting
    Cherrygrove rookie battle SKIPPED
    Sprout Tower native Elder scene
    Azalea native encounter
    Burned Tower native encounter
    Goldenrod Underground native encounter
    Victory Road native encounter after 8 real Johto badges
    Mt. Moon native encounter after Gold Hall of Fame

v0.1.29 fixes the root of the invisible-Silver bug. Older imports globally hid
every extracted `SPRITE_RIVAL`, including Sprout Tower's scenery Silver. The
Sprout Tower coord-event never calls `appear`; it immediately moves and talks
through that already-existing object. The result was exactly what beta testing
showed: Silver's dialogue and scripted movement ran while his sprite remained
absent.

Fresh imports now lock only the two late-Kanto rival maps that truly need a
pre-Johto chronology guard (Victory Road and Mt. Moon). Existing schema-9 saves
receive a one-shot Sprout Tower scene re-arm plus Gold-native
`World:appearObject()` repair. Burned Tower keeps the same native pre-visible
repair because its deferred scene has the same live-object requirement.

### Johto badge-state repair

v0.1.29 also fixes an HM menu compatibility bug discovered in the beta save.
The Project Celebi badge shim temporarily supplies Gold's Johto badge checks while
authorizing a Gen 1 HM. Previous code tried to remember absent Lua keys by
writing `nil` into a restore table; Lua removes nil-valued keys, so an HM use
could accidentally leave all eight temporary Johto badges in the save.

The shim now stores an explicit presence bit and restores absent badge keys
correctly. Existing schema-9 saves rebuild their genuine Johto badges from the
native gym-victory events before continuing. Gold Hall-of-Fame detection now
checks `hallOfFame.count > 0`; the normal `{ count = 0, teams = {} }` skeleton
is no longer mistaken for post-League completion.

### Beta diagnostics

`modData.legacy_bridge.rival.diagnostics` records the latest rival map/state,
real Johto badge count, Gold HOF status, rival-object event visibility and the
most recent continuity repair. Sprout Tower records `sproutTowerNativeRepair`;
Burned Tower records `burnedTowerNativeRepair`. Both include the resolved object
id/index, event flag, mask state and before/after live-entity verification.

`modData.legacy_bridge.diagnostics.johtoBadgeLeakRepair` records the pre/post
badge counts and the native gym-victory evidence used during migration.
Rival battles also copy their scaled-party snapshot to
`modData.legacy_bridge.rival.lastBattleScale`.

## Project Celebi Johto Balance Pass v2

No new import required. Existing Project Celebi saves can load this build directly.

This build is the beta-candidate balance pass: Johto trainers now meet the
imported veteran team near its own strength, and ordinary Johto wild Pokemon
become practical catches instead of being dozens of levels behind.

### Difficulty source

The border bootstrap permanently freezes:

    modData.legacy_bridge.difficulty.rating

from the median of the strongest three Pokemon brought into Johto.

The campaign does not rubber-band to the currently equipped party afterward.
That frozen number remains the common baseline for both trainer and wild
scaling.

## Trainer scaling v2

Gold's supported:

    trainer.party

hook is used after the real enemy party has been built.

For each original trainer Pokemon:

    target =
        Project Celebi Rating
        - 3
        + round(vanilla level * 0.25)
        + boss bonus

The target can never be below the original vanilla level.

Boss bonus:

    ordinary trainer       +0
    Silver / Rival         +2
    Johto Gym Leader       +3
    Elite Four / Champion  +4

Example with Project Celebi Rating 79:

    vanilla Lv 4  trainer  -> Lv77
    Falkner Lv 9 ace       -> Lv81
    Bugsy Lv 16 ace        -> Lv83
    Whitney Lv 20 ace      -> Lv84
    Morty Lv 25 ace        -> Lv85
    Clair Lv 40 ace        -> Lv89
    Lv 50 League opponent  -> Lv93

This gives early Johto trainers immediate parity with a veteran import while
allowing the authored vanilla progression coordinate to pull later bosses above
the frozen starting rating.

### Trainer evolution promotion

Each enemy Pokemon may advance ONE normal level-evolution stage if its scaled
level qualifies.

Item/trade/friendship evolutions are not forced.

The rebuild preserves:

    trainer DVs
    stat EXP
    held item
    happiness
    shiny state
    exact authored move list

## Wild catch-up v1

Ordinary Johto wild encounters are raised into a target band:

    Project Celebi Rating - 15  through  Project Celebi Rating - 10

Vanilla level still nudges the result upward inside that six-level band, at
roughly one target level for every seven vanilla levels. A naturally stronger
vanilla encounter is never downscaled.

Example with Project Celebi Rating 79:

    low-level early wilds  -> about Lv64
    mid-level Johto wilds  -> about Lv65-L67
    later Johto wilds      -> about Lv68-L69

Species, encounter rates, time-of-day tables, swarm choices and encounter-table
identity remain vanilla. Only the resulting level is changed.

Catch-up scaling covers ordinary grass/cave/surf encounters, random scripted
map-table rolls such as `randomwildmon`, Sweet Scent, and fishing.

Intentionally excluded:

    Bug-Catching Contest encounters
    roaming legendary beasts
    authored static/scripted wild encounters

Those special encounters have mechanics/state that should stay authored rather
than being treated as ordinary catch-up fodder.

## Scope

Balance scaling activates only after the Project Celebi Johto campaign has begun.

Johto routes 29-46 and Johto cities/dungeons are scaled. Routes 26/27, Victory
Road and Indigo Plateau count as Johto endgame territory once Johto is active.

Kanto trainers and Kanto wild encounters remain untouched.

## Recommended public-beta test

No re-import is required for existing Project Celebi saves. For the new-player access
check, use any imported Gen 1 Champion save that is still in Kanto:

1. Walk from Viridian City west onto Route 22 and enter Victory Road Gate.
2. The Black Belt on the Route 22/east side should be absent immediately.
3. The Black Belt across the hall toward Mt. Silver should still be present
   unless Gold's native Mt. Silver unlock has legitimately fired.
4. Walk south through the gate to Route 26/27. The central Johto-badge officer
   should not reject the imported Champion and no fake Johto badges should be
   awarded.
5. Continue west across Route 27; the existing Project Celebi Johto bootstrap should
   take over normally.

Existing schema-10 saves simply adopt schema 11 on load; the guard change is a
per-map runtime mask and requires no destructive save migration.

Diagnostics are stored under:

    modData.legacy_bridge.difficulty.lastTrainerScale
    modData.legacy_bridge.difficulty.lastWildScale

The mod log also records each transformation as:

    Project Celebi trainer scale ...
    Project Celebi wild scale ...
