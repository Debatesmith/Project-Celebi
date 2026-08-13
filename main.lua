-- Project Celebi v0.1.31
--
-- CELEBI SILVER CONTINUITY + BETA DIAGNOSTICS
-- -------------------------------------------
-- Restores Silver's Johto campaign after the Project Celebi New Bark introduction,
-- while continuing to skip the rookie Cherrygrove rival battle. Burned Tower,
-- Goldenrod Underground and the Johto endgame now hand back to Gold's native
-- rival scripts at the correct campaign milestones.
--
-- CELEBI JOHTO BALANCE PASS v2
-- -----------------------------
-- Trainer parties stay centered on the immutable Project Celebi Difficulty Rating,
-- with later trainers and bosses allowed to edge above it.
--
-- Ordinary Johto wild encounters use Gold's supported encounter hooks and are
-- pulled into a catch-up band roughly 10-15 levels below that same rating.
-- Vanilla encounter species/tables remain authoritative; only level changes.
--
-- Bug-Catching Contest, roaming beasts and authored static/scripted encounters
-- remain vanilla so their special mechanics are not distorted.

local SCREEN_SOURCES = "ProjectCelebiSources"

return function(mod)
    local SaveData = require("src.core.SaveData")
    local SaveSerializer = require("src.core.SaveSerializer")
    local GoldSave = require("src.core.gen2.Save")
    local Gen2Map = require("src.world.gen2.Map")
    local Gen2FieldMoves = require("src.world.gen2.FieldMoves")
    local Gen2Events = require("src.world.gen2.Events")
    local Mon = require("src.battle.gen2.Mon")

    local SOURCE_VERSIONS = { "red", "blue", "yellow" }
    local selectedSource = nil
    local selectedSave = nil
    local selectedRecoveredFrom = nil
    local liveGame = nil

    -- Forward declaration: the START-menu hook is registered earlier in this
    -- entry chunk than the canonical-world-state implementation below.
    -- Without this declaration Lua resolves the callback name as a GLOBAL,
    -- and the live START hook later calls nil.
    local ensureLegacyCanonicalWorldState

    local function logInfo(msg)
        if mod.log and mod.log.info then mod.log:info(msg) end
    end

    local function logWarn(msg)
        if mod.log and mod.log.warn then mod.log:warn(msg) end
    end

    -- Read the ACTIVE Gen 1 slot WITHOUT calling SaveData.load(version).
    --
    -- Important v0.1.78 distinction:
    --   SaveData.load(version) = read + parse + runMigrations + options merge
    --   SaveData.listSlots()   = raw SaveSerializer decode only
    --
    -- Cross-generation inspection should be data-only. The save editor already
    -- uses SaveData.slotDiskPath(version, slotId) specifically for raw io.*
    -- access, so Project Celebi follows that engine-owned path resolution.
    local function readFile(path)
        local f, err = io.open(path, "rb")
        if not f then return nil, err end
        local body = f:read("*a")
        f:close()
        return body
    end

    local function decodePath(path)
        local body, readErr = readFile(path)
        if not body then return nil, readErr end

        local ok, saveOrErr, decodeErr = pcall(SaveSerializer.decode, body)
        if not ok then
            return nil, tostring(saveOrErr)
        end
        if type(saveOrErr) ~= "table" then
            return nil, tostring(decodeErr or "decode returned no table")
        end
        return saveOrErr
    end

    local function readActiveSlot(version)
        local active = SaveData.activeSlot(version)
        if not active then
            return nil, nil, ("no active %s slot"):format(tostring(version))
        end

        local path = SaveData.slotDiskPath(version, active)
        if not path then
            return nil, active, "slotDiskPath returned nil"
        end

        local candidates = {
            { path = path,          source = "main" },
            { path = path .. ".tmp", source = "tmp" },
            { path = path .. ".bak", source = "bak" },
        }

        local lastErr = nil
        for _, candidate in ipairs(candidates) do
            local save, err = decodePath(candidate.path)
            if save then
                return save, active, candidate.source
            end
            lastErr = err
        end

        return nil, active, lastErr or "no readable source copy"
    end

    local function detectSources()
        local found = {}

        for _, version in ipairs(SOURCE_VERSIONS) do
            local activeId = SaveData.activeSlot(version)
            if activeId then
                local ok, slotsOrErr = pcall(SaveData.listSlots, version)
                if ok and type(slotsOrErr) == "table" then
                    for _, slot in ipairs(slotsOrErr) do
                        if slot.exists and slot.id == activeId then
                            local meta = slot.meta or {}
                            found[#found + 1] = {
                                version = version,
                                slotId = activeId,
                                name = slot.name or slot.label or activeId,
                                label = slot.label or slot.name or activeId,
                                badges = tonumber(meta.badges) or 0,
                                timeText = meta.timeText or "",
                                dexCount = tonumber(meta.dexCount) or 0,
                                active = true,
                            }
                            break
                        end
                    end
                else
                    logWarn(("Project Celebi: listSlots(%s) failed: %s")
                        :format(version, tostring(slotsOrErr)))
                end
            end
        end

        return found
    end

    local function sourceLabel(source)
        return ("%s  %s"):format(string.upper(source.version or "?"),
                                 source.name or source.slotId or "?")
    end

    local function sourceRight(source)
        local pieces = {}
        if source.active then pieces[#pieces + 1] = "ACTIVE" end
        pieces[#pieces + 1] = ("%dB"):format(source.badges or 0)
        if source.timeText and source.timeText ~= "" then
            pieces[#pieces + 1] = source.timeText
        end
        return table.concat(pieces, " ")
    end

    local function clamp(n, lo, hi)
        n = tonumber(n) or lo
        if n < lo then return lo end
        if n > hi then return hi end
        return n
    end

    local function copyDVs(dvs)
        dvs = dvs or {}
        return {
            attack = clamp(dvs.attack, 0, 15),
            defense = clamp(dvs.defense, 0, 15),
            speed = clamp(dvs.speed, 0, 15),
            special = clamp(dvs.special, 0, 15),
            -- HP is intentionally not copied; Mon.new derives it from the four
            -- stored DVs exactly as both cartridges do.
        }
    end

    local function copyStatExp(statExp)
        statExp = statExp or {}
        return {
            hp = clamp(statExp.hp, 0, Mon.MAX_STAT_EXP),
            attack = clamp(statExp.attack, 0, Mon.MAX_STAT_EXP),
            defense = clamp(statExp.defense, 0, Mon.MAX_STAT_EXP),
            speed = clamp(statExp.speed, 0, Mon.MAX_STAT_EXP),
            special = clamp(statExp.special, 0, Mon.MAX_STAT_EXP),
        }
    end

    local function convertMoves(game, sourceMon)
        local out = {}
        for _, mv in ipairs(sourceMon.moves or {}) do
            local def = game.data and game.data.moves and game.data.moves[mv.id]
            if not def then
                return nil, "Gold has no move definition for " .. tostring(mv.id)
            end

            local basePp = tonumber(def.pp) or 0
            local ppUps = clamp(mv.ppUps or 0, 0, 3)
            local maxPp = basePp + ppUps * math.floor(basePp / 5)
            local currentPp = clamp(mv.pp or maxPp, 0, maxPp)

            out[#out + 1] = {
                id = mv.id,
                pp = currentPp,
                maxPp = maxPp,
                -- Gold v0.1.78's live battle code keys off maxPp, but retaining
                -- the source count as harmless provenance means a later engine
                -- PP-Up implementation can consume it without information loss.
                ppUps = ppUps,
            }
        end
        return out
    end

    -- Gen 1 and Gen 2 use slightly different symbolic IDs for a couple of
    -- otherwise identical Kanto species.  Gen1Recomp saves store the symbolic
    -- ID, while Gold's Mon.new performs an exact data.pokemon[id] lookup.
    -- Translate only the known canonical RBY -> Gold spelling changes here;
    -- unsupported/fakemon IDs must still fail rather than being guessed.
    local GEN1_TO_GOLD_SPECIES = {
        FARFETCHD = "FARFETCH_D",
        MR_MIME = "MR__MIME",
    }

    local function canonicalGoldSpecies(game, sourceSpecies)
        if not sourceSpecies then return nil end
        local pokemon = game and game.data and game.data.pokemon
        if type(pokemon) ~= "table" then return nil end

        -- Most of the original 151 already share exactly the same key.
        if pokemon[sourceSpecies] then return sourceSpecies end

        local alias = GEN1_TO_GOLD_SPECIES[sourceSpecies]
        if alias and pokemon[alias] then return alias end
        return nil
    end

    local function convertMon(game, sourceSave, sourceMon)
        if type(sourceMon) ~= "table" then return nil, "invalid Pokemon record" end
        if not sourceMon.species then return nil, "Pokemon has no species" end

        local goldSpecies = canonicalGoldSpecies(game, sourceMon.species)
        if not goldSpecies then
            return nil, "Gold has no species definition for " .. tostring(sourceMon.species)
        end

        local moves, moveErr = convertMoves(game, sourceMon)
        if not moves then return nil, moveErr end

        local dvs = copyDVs(sourceMon.dvs)
        local statExp = copyStatExp(sourceMon.statExp)
        local level = clamp(sourceMon.level or 1, 1, Mon.MAX_LEVEL)

        local goldMon = Mon.new(game.data, goldSpecies, level, {
            dvs = dvs,
            statExp = statExp,
            nickname = sourceMon.nickname,
            moves = moves,
            happiness = 70,
            pokerus = 0,
        })

        if not goldMon then
            return nil, "Gold failed to construct species " .. tostring(goldSpecies)
        end

        -- Mon.new deliberately seeds the level's normal threshold. Project Celebi
        -- restores the exact accumulated total from Gen 1.
        goldMon.experience = tonumber(sourceMon.exp)
            or tonumber(sourceMon.experience)
            or goldMon.experience

        -- Import healed for the first continuity spawn. The genetic/training
        -- state is exact; temporary HP/status are not generation history.
        goldMon.hp = goldMon.maxHp
        goldMon.status = nil
        goldMon.item = nil

        local sourcePlayer = sourceSave.player or {}
        goldMon.ot = sourceMon.ot or sourcePlayer.name
        goldMon.otName = sourceMon.otName or sourceMon.ot or sourcePlayer.name
        goldMon.otId = sourceMon.otId
        if goldMon.otId == nil then goldMon.otId = sourcePlayer.id end

        return goldMon
    end

    local function convertParty(game, sourceSave)
        local party = {}
        for i, sourceMon in ipairs(sourceSave.party or {}) do
            if i > Mon.PARTY_SIZE then break end
            local mon, err = convertMon(game, sourceSave, sourceMon)
            if not mon then
                return nil, ("Party slot %d: %s"):format(i, tostring(err))
            end
            party[#party + 1] = mon
        end
        return party
    end

    local function convertBoxes(game, sourceSave)
        -- Gen 1: 12 boxes x 20.
        -- Gold:  14 boxes x 20.
        --
        -- Keep box numbering stable so "Box 4" in Blue is still Box 4 in Gold.
        -- The two extra Gold boxes start empty.
        local boxes = {}
        local transferred = 0

        for boxNo = 1, GoldSave.NUM_BOXES do
            boxes[boxNo] = {}
        end

        for boxNo = 1, math.min(12, GoldSave.NUM_BOXES) do
            local sourceBox = (sourceSave.boxes and sourceSave.boxes[boxNo]) or {}
            local destBox = boxes[boxNo]

            for monNo, sourceMon in ipairs(sourceBox) do
                if monNo > GoldSave.MONS_PER_BOX then break end

                local mon, err = convertMon(game, sourceSave, sourceMon)
                if not mon then
                    return nil, nil,
                        ("Box %d slot %d: %s")
                        :format(boxNo, monNo, tostring(err))
                end

                destBox[#destBox + 1] = mon
                transferred = transferred + 1
            end
        end

        return boxes, transferred
    end

    local function convertPlayTime(sourceSave)
        -- Gen 1 Recomp stores playTime as seconds (possibly with a 1/60
        -- fractional frame). Gold stores the cart-native H/M/S/frame fields.
        local seconds = tonumber(sourceSave.playTime) or 0
        if seconds < 0 then seconds = 0 end

        local totalFrames = math.floor(seconds * 60 + 0.5)
        local framesPerHour = 60 * 60 * 60

        local hours = math.floor(totalFrames / framesPerHour)
        if hours > 255 then
            -- Match Gen 1's saturated play clock instead of wrapping.
            return { hours = 255, minutes = 59, seconds = 59, frames = 59 }
        end

        totalFrames = totalFrames - hours * framesPerHour
        local minutes = math.floor(totalFrames / (60 * 60))
        totalFrames = totalFrames - minutes * 60 * 60
        local wholeSeconds = math.floor(totalFrames / 60)
        local frames = totalFrames - wholeSeconds * 60

        return {
            hours = hours,
            minutes = minutes,
            seconds = wholeSeconds,
            frames = frames,
        }
    end

    -- ---------------------------------------------------------------------
    -- Gen 1 -> Gold item economy
    --
    -- Both engines store the live bag as a flat semantic item-id -> quantity
    -- table. Gold's PackMenu then divides that flat map into ITEM / KEY_ITEM /
    -- BALL / TM_HM using the Gold item definition's `pocket`.
    --
    -- Therefore item migration is semantic, NOT raw-number based:
    --   HM_FLY in Red/Blue -> HM_FLY in Gold
    --   TM_REST in Red/Blue -> TM_REST in Gold
    --
    -- This is especially important for TMs because the TM *numbers* changed
    -- between generations. A Gen 1 TM whose move does not exist as a Gold TM
    -- is retained only as Project Celebi audit metadata, never silently changed into a
    -- different move.
    local LEGACY_BADGE_IDS = {
        BOULDERBADGE = true,
        CASCADEBADGE = true,
        THUNDERBADGE = true,
        RAINBOWBADGE = true,
        SOULBADGE = true,
        MARSHBADGE = true,
        VOLCANOBADGE = true,
        EARTHBADGE = true,
    }

    -- Same spelling, different Gold storyline payload. Importing these into the
    -- live Gold bag would accidentally satisfy unrelated Gen 2 quest checks.
    -- Preserve them in audit metadata instead.
    local GOLD_STORY_COLLISION_ITEMS = {
        CARD_KEY = true,       -- Gen 1 Silph Co. vs Gen 2 Radio Tower
        S_S_TICKET = true,     -- S.S. Anne vs S.S. Aqua
    }

    -- Genuine cross-generation successor names.
    local ITEM_ALIASES = {
        THUNDER_STONE = "THUNDERSTONE",
        EXP_ALL = "EXP_SHARE",
    }

    local function itemDef(game, id)
        local items = game and game.data and game.data.items
        local def = items and items[id]
        return type(def) == "table" and def or nil
    end

    local function resolveLegacyItem(game, sourceId)
        if LEGACY_BADGE_IDS[sourceId] then
            return nil, "legacy_badge"
        end
        if GOLD_STORY_COLLISION_ITEMS[sourceId] then
            return nil, "gold_story_collision"
        end

        if itemDef(game, sourceId) then
            return sourceId, "exact"
        end

        local alias = ITEM_ALIASES[sourceId]
        if alias and itemDef(game, alias) then
            return alias, "alias"
        end

        return nil, "no_gold_equivalent"
    end

    local function transferItemTable(game, sourceItems, sourceOrder)
        local out = {}
        local report = {
            transferred = 0,
            transferredUnits = 0,
            aliases = {},
            skipped = {},
            sourceOrder = {},
        }

        for _, id in ipairs(sourceOrder or {}) do
            report.sourceOrder[#report.sourceOrder + 1] = id
        end

        local function importOne(sourceId, qty)
            qty = math.max(0, math.min(99, math.floor(tonumber(qty) or 0)))
            if qty <= 0 then return end

            local goldId, method = resolveLegacyItem(game, sourceId)
            if goldId then
                out[goldId] = math.min(99, (out[goldId] or 0) + qty)
                report.transferred = report.transferred + 1
                report.transferredUnits = report.transferredUnits + qty
                if method == "alias" then
                    report.aliases[#report.aliases + 1] = {
                        source = sourceId,
                        destination = goldId,
                    }
                end
            else
                report.skipped[#report.skipped + 1] = {
                    id = sourceId,
                    quantity = qty,
                    reason = method,
                }
            end
        end

        -- Preserve source menu order for audit, but the destination Pack itself
        -- is intentionally the Gold-native flat inventory table.
        local seen = {}
        for _, sourceId in ipairs(sourceOrder or {}) do
            if sourceItems and sourceItems[sourceId] ~= nil then
                seen[sourceId] = true
                importOne(sourceId, sourceItems[sourceId])
            end
        end

        -- Gen1Recomp native saves can be edited and may contain items not listed
        -- in bagOrder/pcOrder. Do not lose them.
        for sourceId, qty in pairs(sourceItems or {}) do
            if not seen[sourceId] then
                importOne(sourceId, qty)
            end
        end

        return out, report
    end

    local function copyVisited(sourceSave)
        local visited = {}
        local n = 0
        for mapId, value in pairs(sourceSave.visited or {}) do
            if value then
                visited[mapId] = true
                n = n + 1
            end
        end
        return visited, n
    end

    -- ---------------------------------------------------------------------
    -- Project Celebi Kanto canonical state
    --
    -- The Gen 1 trainer is not starting Kanto over. Their historical badges
    -- become Gold's KANTO badge store, and Gold's Kanto Gym Leader trainer
    -- event flags are marked beaten. Ordinary route/gym trainers are NOT
    -- blanket-completed; they remain available as fun rematches/new fights.
    local KANTO_GYM_BADGE_BY_CLASS = {
        BROCK = "BOULDERBADGE",
        MISTY = "CASCADEBADGE",
        LT_SURGE = "THUNDERBADGE",
        ERIKA = "RAINBOWBADGE",
        JANINE = "SOULBADGE",
        SABRINA = "MARSHBADGE",
        BLAINE = "VOLCANOBADGE",
        BLUE = "EARTHBADGE",
    }

    local KANTO_BADGES = {
        "BOULDERBADGE",
        "CASCADEBADGE",
        "THUNDERBADGE",
        "RAINBOWBADGE",
        "SOULBADGE",
        "MARSHBADGE",
        "VOLCANOBADGE",
        "EARTHBADGE",
    }


    local function badgeToken(name)
        local token = tostring(name or ""):upper():gsub("[^A-Z0-9]", "")
        token = token:gsub("BADGE$", "")
        return token
    end

    local function historicalBadgeTokens(badges)
        local out = {}
        for name, owned in pairs(badges or {}) do
            if owned then out[badgeToken(name)] = true end
        end
        return out
    end

    -- Seed Gold's *actual* Kanto badge keys.
    --
    -- World:engineFlag(flag) does:
    --   badge = FieldMoves.BADGE_FLAG[flag]
    --   owned = save.player[badge.store]
    --   return owned[badge.name] == true
    --
    -- So never guess the internal badge.name spelling. Iterate the exact table
    -- the engine itself uses and populate those keys.
    local function seedGoldKantoBadgeStore(save, historicalBadges, champion)
        save.player = save.player or {}
        save.player.kantoBadges = save.player.kantoBadges or {}

        local wanted = historicalBadgeTokens(historicalBadges)
        local seeded = {}
        local numericFlags = {}

        for flagId, badge in pairs(Gen2FieldMoves.BADGE_FLAG or {}) do
            if type(badge) == "table"
                and badge.store == "kantoBadges"
                and badge.name then

                local owned = champion == true
                    or wanted[badgeToken(badge.name)] == true

                if owned then
                    save.player.kantoBadges[badge.name] = true
                    seeded[badge.name] = true
                    numericFlags[flagId] = true
                end
            end
        end

        return seeded, numericFlags
    end

    local function scriptCommandArg(cmd, named)
        if type(cmd) ~= "table" then return nil end
        if cmd[named] ~= nil then return cmd[named] end
        local args = cmd.args
        return type(args) == "table" and args[1] or nil
    end

    -- Find Kanto leader completion directly from Gold's extracted scripts.
    --
    -- A leader such as Lt. Surge is OBJECTTYPE_SCRIPT, not OBJECTTYPE_TRAINER:
    -- his script contains `setevent EVENT_BEAT_LTSURGE` and later
    -- `setflag ENGINE_THUNDERBADGE`. Find scripts that set one of the exact
    -- Kanto badge numeric ids, then mark every setevent in that same victory
    -- script. This also catches Surge's three gym-trainer completion events,
    -- which is desirable for a gym that is canonically already complete.
    local function seedKantoGymScriptEvents(scripts, events, ownedBadgeFlags)
        local report = {}
        if type(scripts) ~= "table" or not events then return report end

        for scriptKey, rows in pairs(scripts) do
            if type(rows) == "table" then
                local ownsThisLeaderBadge = false

                for _, cmd in ipairs(rows) do
                    if cmd.op == "setflag" then
                        local flag = scriptCommandArg(cmd, "flag")
                        if flag ~= nil and ownedBadgeFlags[flag] then
                            ownsThisLeaderBadge = true
                            break
                        end
                    end
                end

                if ownsThisLeaderBadge then
                    local setEvents = {}
                    for _, cmd in ipairs(rows) do
                        if cmd.op == "setevent" then
                            local event = scriptCommandArg(cmd, "event")
                            if event ~= nil then
                                events:set(event, true)
                                setEvents[#setEvents + 1] = event
                            end
                        end
                    end

                    report[scriptKey] = {
                        events = setEvents,
                    }
                end
            end
        end

        return report
    end


    -- Before the Johto introduction, these vanilla Gold rival encounters are
    -- chronology violations for a Project Celebi trainer. Both maps use scene 0 for
    -- the rival battle and scene 1 as their vanilla NOOP scene.
    local PRE_JOHTO_RIVAL_NOOP_SCENES = {
        MOUNT_MOON = 1,
        VICTORY_ROAD = 1,
    }

    local function historicalKantoBadges(sourceSave, isChampion)
        local sourceInventory = sourceSave.inventory or {}
        local badges = {}
        for _, badge in ipairs(KANTO_BADGES) do
            badges[badge] = sourceInventory[badge] and true or false
        end

        -- A verified Hall-of-Fame Champion necessarily had all eight Gen 1
        -- badges, even if an old imported/native save shape omitted the badge
        -- pseudo-items from `inventory`.
        if isChampion then
            for _, badge in ipairs(KANTO_BADGES) do
                badges[badge] = true
            end
        end
        return badges
    end

    local function goldConstants(game)
        if game and game.world and game.world.constants then
            return game.world.constants
        end
        return game
            and game.data
            and game.data.gen2Constants
            or nil
    end

    local function trainerClassName(game, trainer)
        if not (trainer and trainer.class) then return nil end
        local constants = goldConstants(game)
        local order = constants and constants.trainerClassOrder
        if not order then return nil end
        -- Trainer class ids are zero-based; Lua arrays are one-based.
        return order[trainer.class + 1]
    end

    local function eventsFromSave(save)
        local events = Gen2Events.new()
        if type(save.events) == "table" then
            events:restore(save.events)
        end
        return events
    end

    local function seedKantoGymCompletion(game, save, badges, champion)
        local seededBadges, ownedBadgeFlags =
            seedGoldKantoBadgeStore(save, badges, champion)

        local events = eventsFromSave(save)
        local scripts = game
            and game.data
            and game.data.gen2Scripts
            or {}

        local completedScripts =
            seedKantoGymScriptEvents(scripts, events, ownedBadgeFlags)

        save.events = events:serialize()

        return {
            badges = seededBadges,
            scripts = completedScripts,
        }
    end

    local function seedRivalLock(game, save)
        local maps = game
            and game.data
            and game.data.gen2Maps
            or {}
        local events = eventsFromSave(save)
        local hidden = 0

        -- Only lock the two LATE-KANTO rival encounters that a Gen 1 Champion
        -- can physically reach before starting Johto. Older builds hid EVERY
        -- extracted SPRITE_RIVAL object, which poisoned pre-visible Johto
        -- scenes such as Sprout Tower and Burned Tower.
        for mapId in pairs(PRE_JOHTO_RIVAL_NOOP_SCENES) do
            local def = maps[mapId]
            for _, obj in ipairs((def and def.objects) or {}) do
                if obj.sprite == "SPRITE_RIVAL" and obj.eventFlag then
                    events:set(obj.eventFlag, true)
                    hidden = hidden + 1
                end
            end
        end

        save.events = events:serialize()
        save.mapScenes = save.mapScenes or {}
        for mapId, scene in pairs(PRE_JOHTO_RIVAL_NOOP_SCENES) do
            save.mapScenes[mapId] = scene
        end

        return hidden
    end

    -- ---------------------------------------------------------------------
    -- Gen 1 money resolver
    --
    -- Native / converted Gen1Recomp saves have existed in more than one shape
    -- during development. Prefer semantic Lua fields, but fall back to the
    -- preserved original 32 KiB SRAM template if needed.
    --
    -- Red/Blue wPlayerMoney = SRAM offset $25F3, three packed-BCD bytes.
    local GEN1_RAW_MONEY_OFFSET = 0x25F3

    local function bcdByte(value)
        if type(value) ~= "number" then return nil end
        local hi = math.floor(value / 16)
        local lo = value % 16
        if hi > 9 or lo > 9 then return nil end
        return hi * 10 + lo
    end

    local function rawByte(raw, index)
        if type(raw) == "string" then
            return raw:byte(index)
        end
        if type(raw) == "table" then
            if type(raw.bytes) == "table" then return raw.bytes[index] end
            if type(raw.data) == "table" then return raw.data[index] end
            if type(raw.data) == "string" then return raw.data:byte(index) end
            return raw[index]
        end
        return nil
    end

    local function moneyFromRawImport(raw)
        local i = GEN1_RAW_MONEY_OFFSET + 1 -- Lua/string index is one-based.
        local a = bcdByte(rawByte(raw, i))
        local b = bcdByte(rawByte(raw, i + 1))
        local c = bcdByte(rawByte(raw, i + 2))
        if a == nil or b == nil or c == nil then return nil end
        return a * 10000 + b * 100 + c
    end

    local function resolveSourceMoney(sourceSave)
        local candidates = {
            { value = sourceSave.money, source = "save.money" },
            { value = sourceSave.player and sourceSave.player.money,
              source = "save.player.money" },
            { value = sourceSave.playerMoney, source = "save.playerMoney" },
        }

        for _, row in ipairs(candidates) do
            local value = tonumber(row.value)
            if value ~= nil then
                return clamp(value, 0, GoldSave.MAX_MONEY), row.source
            end
        end

        local raw = moneyFromRawImport(sourceSave.rawImport)
        if raw ~= nil then
            return clamp(raw, 0, GoldSave.MAX_MONEY), "rawImport:$25F3"
        end

        return 0, "unavailable"
    end

    -- ---------------------------------------------------------------------
    -- Native Gold Pokegear / Fly state
    --
    -- Gold stores the Pokegear cards in save.engineFlags, not save.flags:
    --   0 ENGINE_RADIO_CARD
    --   1 ENGINE_MAP_CARD
    --   2 ENGINE_PHONE_CARD
    --   3 ENGINE_EXPN_CARD
    --   4 ENGINE_POKEGEAR
    --
    -- Native Fly destinations are also engine flags.  FieldMoves.FLYPOINTS is
    -- the authoritative table and includes each destination's spawn + flag id.
    local ENGINE_RADIO_CARD = 0
    local ENGINE_MAP_CARD = 1
    local ENGINE_PHONE_CARD = 2
    local ENGINE_EXPN_CARD = 3
    local ENGINE_POKEGEAR = 4

    local function unlockFullPokegear(save)
        save.engineFlags = save.engineFlags or {}
        save.engineFlags[ENGINE_RADIO_CARD] = true
        save.engineFlags[ENGINE_MAP_CARD] = true
        save.engineFlags[ENGINE_PHONE_CARD] = true
        save.engineFlags[ENGINE_EXPN_CARD] = true
        save.engineFlags[ENGINE_POKEGEAR] = true

        -- Pokegear.lua intentionally accepts this overlay for tests/older
        -- saves as well, so seed both representations for beta compatibility.
        save.pokegearFlags = save.pokegearFlags or {}
        save.pokegearFlags.radio = true
        save.pokegearFlags.map = true
        save.pokegearFlags.phone = true
        save.pokegearFlags.expn = true
        save.pokegearReceived = true
    end

    local function landmarkSourceKey(landmark)
        return tostring(landmark or ''):gsub('^LANDMARK_', '')
    end

    local function sourceVisitedMatches(save, row)
        local visited = save.visited or {}
        local key = landmarkSourceKey(row.landmark)
        if visited[key] then return true end

        -- Gen 1's Rock Tunnel fly-equivalent is represented by the Route 10
        -- Pokemon Center / Rock Tunnel family rather than Gold's landmark key.
        if key == 'ROCK_TUNNEL' then
            for mapId, yes in pairs(visited) do
                if yes and tostring(mapId):find('ROCK_TUNNEL', 1, true) then
                    return true
                end
            end
        end

        -- Indigo has existed under both the outdoor and lobby-style ids in the
        -- source/import pipeline.
        if key == 'INDIGO_PLATEAU' then
            for mapId, yes in pairs(visited) do
                if yes and tostring(mapId):find('INDIGO_PLATEAU', 1, true) then
                    return true
                end
            end
        end

        return false
    end

    local function currentMapUnlocksFlypoint(save, row)
        local current = save.position and save.position.map
        if not current then return false end
        local key = landmarkSourceKey(row.landmark)
        return current == key
            or tostring(current):sub(1, #key) == key
    end

    local function seedNativeFlypoints(save, champion)
        save.engineFlags = save.engineFlags or {}
        save.visitedSpawns = save.visitedSpawns or {}

        local kanto, johto = 0, 0
        local split = tonumber(Gen2FieldMoves.KANTO_FLYPOINT) or 13

        for index, row in ipairs(Gen2FieldMoves.FLYPOINTS or {}) do
            local isKanto = index >= split
            local unlock = false

            if isKanto then
                -- A verified Gen 1 Champion already knows Kanto.  This also
                -- guarantees SPAWN_INDIGO is set, which is the native Gold gate
                -- that tells FlyMap to open the Kanto half instead of Johto.
                unlock = champion == true or sourceVisitedMatches(save, row)
            else
                -- Johto remains genuine progression.  Native map callbacks set
                -- these flags normally; this current-map fallback makes Legacy
                -- cross-region relocations discover the city too.
                unlock = save.engineFlags[row.flag] == true
                    or save.visitedSpawns[row.spawn] == true
                    or currentMapUnlocksFlypoint(save, row)
            end

            if unlock then
                save.engineFlags[row.flag] = true
                save.visitedSpawns[row.spawn] = true
                if isKanto then kanto = kanto + 1 else johto = johto + 1 end
            end
        end

        return kanto, johto
    end

    local function seedLegacyNavigationState(save, champion)
        unlockFullPokegear(save)
        return seedNativeFlypoints(save, champion)
    end

    local function mergePokedex(game, goldSave, sourceSave)
        goldSave.pokedex = goldSave.pokedex or { seen = {}, caught = {} }
        goldSave.pokedex.seen = goldSave.pokedex.seen or {}
        goldSave.pokedex.caught = goldSave.pokedex.caught or {}

        -- Use the same species canonicalization as party/box conversion.
        -- This prevents RBY-only symbolic spellings such as FARFETCHD and
        -- MR_MIME from leaking into Gold's Pokédex tables. Unknown modded
        -- species are ignored here; if one is physically in party/boxes, the
        -- normal importer error still tells the player which slot cannot move.
        for species, has in pairs((sourceSave.pokedex and sourceSave.pokedex.seen) or {}) do
            if has then
                local goldSpecies = canonicalGoldSpecies(game, species)
                if goldSpecies then goldSave.pokedex.seen[goldSpecies] = true end
            end
        end
        for species, has in pairs((sourceSave.pokedex and sourceSave.pokedex.owned) or {}) do
            if has then
                local goldSpecies = canonicalGoldSpecies(game, species)
                if goldSpecies then
                    goldSave.pokedex.seen[goldSpecies] = true
                    goldSave.pokedex.caught[goldSpecies] = true
                end
            end
        end
    end

    -- Kanto position crosswalk
    -- ------------------------
    -- Most outdoor Kanto map IDs survive unchanged between RBY and Gold.
    -- Interiors and several dungeons did not.  An entry here means:
    --
    --   "This Gen 1 place's best Gold-era physical successor is TARGET."
    --
    -- mode = "local" tries to preserve the source X/Y before safety correction.
    -- mode = "entry" intentionally starts near a Gold warp/entrance because
    -- the geometry changed too much for coordinates to mean the same thing.
    local KANTO_CROSSWALK = {
        -- Straightforward renamed interiors.
        PEWTER_POKECENTER = { map = "PEWTER_POKECENTER_1F", mode = "local" },
        CERULEAN_POKECENTER = { map = "CERULEAN_POKECENTER_1F", mode = "local" },
        VERMILION_POKECENTER = { map = "VERMILION_POKECENTER_1F", mode = "local" },
        LAVENDER_POKECENTER = { map = "LAVENDER_POKECENTER_1F", mode = "local" },
        CELADON_POKECENTER = { map = "CELADON_POKECENTER_1F", mode = "local" },
        FUCHSIA_POKECENTER = { map = "FUCHSIA_POKECENTER_1F", mode = "local" },
        SAFFRON_POKECENTER = { map = "SAFFRON_POKECENTER_1F", mode = "local" },
        CINNABAR_POKECENTER = { map = "CINNABAR_POKECENTER_1F", mode = "local" },
        VIRIDIAN_POKECENTER = { map = "VIRIDIAN_POKECENTER_1F", mode = "local" },
        ROCK_TUNNEL_POKECENTER = { map = "ROUTE_10_POKECENTER_1F", mode = "entry" },
        MT_MOON_POKECENTER = { map = "MOUNT_MOON_GIFT_SHOP", mode = "entry" },

        NAME_RATERS_HOUSE = { map = "LAVENDER_NAME_RATER", mode = "local" },
        DAYCARE = { map = "DAY_CARE", mode = "local" },
        GAME_CORNER = { map = "CELADON_GAME_CORNER", mode = "local" },
        GAME_CORNER_PRIZE_ROOM = { map = "CELADON_GAME_CORNER_PRIZE_ROOM", mode = "local" },

        CELADON_MART_1F = { map = "CELADON_DEPT_STORE_1F", mode = "local" },
        CELADON_MART_2F = { map = "CELADON_DEPT_STORE_2F", mode = "local" },
        CELADON_MART_3F = { map = "CELADON_DEPT_STORE_3F", mode = "local" },
        CELADON_MART_4F = { map = "CELADON_DEPT_STORE_4F", mode = "local" },
        CELADON_MART_5F = { map = "CELADON_DEPT_STORE_5F", mode = "local" },
        CELADON_MART_ROOF = { map = "CELADON_DEPT_STORE_6F", mode = "entry" },
        CELADON_MART_ELEVATOR = { map = "CELADON_DEPT_STORE_ELEVATOR", mode = "local" },

        -- Collapsed dungeons / route pieces.
        MT_MOON_1F = { map = "MOUNT_MOON", mode = "entry" },
        MT_MOON_B1F = { map = "MOUNT_MOON", mode = "entry" },
        MT_MOON_B2F = { map = "MOUNT_MOON", mode = "entry" },
        DIGLETTS_CAVE_ROUTE_2 = { map = "DIGLETTS_CAVE", mode = "entry" },
        DIGLETTS_CAVE_ROUTE_11 = { map = "DIGLETTS_CAVE", mode = "entry" },
        VICTORY_ROAD_1F = { map = "VICTORY_ROAD", mode = "entry" },
        VICTORY_ROAD_2F = { map = "VICTORY_ROAD", mode = "entry" },
        VICTORY_ROAD_3F = { map = "VICTORY_ROAD", mode = "entry" },
        ROUTE_10 = { map = "ROUTE_10_NORTH", mode = "local" },

        -- Places whose Gen 1 building/area was removed or radically changed.
        VIRIDIAN_FOREST = { map = "ROUTE_2", mode = "entry" },
        VIRIDIAN_FOREST_NORTH_GATE = { map = "ROUTE_2_GATE", mode = "entry" },
        VIRIDIAN_FOREST_SOUTH_GATE = { map = "ROUTE_2_GATE", mode = "entry" },

        POKEMON_TOWER_1F = { map = "LAV_RADIO_TOWER_1F", mode = "entry" },
        POKEMON_TOWER_2F = { map = "LAV_RADIO_TOWER_1F", mode = "entry" },
        POKEMON_TOWER_3F = { map = "LAV_RADIO_TOWER_1F", mode = "entry" },
        POKEMON_TOWER_4F = { map = "LAV_RADIO_TOWER_1F", mode = "entry" },
        POKEMON_TOWER_5F = { map = "LAV_RADIO_TOWER_1F", mode = "entry" },
        POKEMON_TOWER_6F = { map = "LAV_RADIO_TOWER_1F", mode = "entry" },
        POKEMON_TOWER_7F = { map = "LAV_RADIO_TOWER_1F", mode = "entry" },

        CINNABAR_GYM = { map = "SEAFOAM_GYM", mode = "entry" },
        CINNABAR_MART = { map = "CINNABAR_ISLAND", mode = "entry" },
        CINNABAR_MART_COPY = { map = "CINNABAR_ISLAND", mode = "entry" },
        CINNABAR_LAB = { map = "CINNABAR_ISLAND", mode = "entry" },
        CINNABAR_LAB_FOSSIL_ROOM = { map = "CINNABAR_ISLAND", mode = "entry" },
        CINNABAR_LAB_METRONOME_ROOM = { map = "CINNABAR_ISLAND", mode = "entry" },
        CINNABAR_LAB_TRADE_ROOM = { map = "CINNABAR_ISLAND", mode = "entry" },
        POKEMON_MANSION_1F = { map = "CINNABAR_ISLAND", mode = "entry" },
        POKEMON_MANSION_2F = { map = "CINNABAR_ISLAND", mode = "entry" },
        POKEMON_MANSION_3F = { map = "CINNABAR_ISLAND", mode = "entry" },
        POKEMON_MANSION_B1F = { map = "CINNABAR_ISLAND", mode = "entry" },

        SAFARI_ZONE_GATE = { map = "FUCHSIA_CITY", mode = "entry" },
        SAFARI_ZONE_CENTER = { map = "FUCHSIA_CITY", mode = "entry" },
        SAFARI_ZONE_EAST = { map = "FUCHSIA_CITY", mode = "entry" },
        SAFARI_ZONE_NORTH = { map = "FUCHSIA_CITY", mode = "entry" },
        SAFARI_ZONE_WEST = { map = "FUCHSIA_CITY", mode = "entry" },
        SAFARI_ZONE_SECRET_HOUSE = { map = "FUCHSIA_CITY", mode = "entry" },
        SAFARI_ZONE_CENTER_REST_HOUSE = { map = "FUCHSIA_CITY", mode = "entry" },
        SAFARI_ZONE_EAST_REST_HOUSE = { map = "FUCHSIA_CITY", mode = "entry" },
        SAFARI_ZONE_NORTH_REST_HOUSE = { map = "FUCHSIA_CITY", mode = "entry" },
        SAFARI_ZONE_WEST_REST_HOUSE = { map = "FUCHSIA_CITY", mode = "entry" },

        INDIGO_PLATEAU = { map = "INDIGO_PLATEAU_POKECENTER_1F", mode = "entry" },
        INDIGO_PLATEAU_LOBBY = { map = "INDIGO_PLATEAU_POKECENTER_1F", mode = "entry" },
        LORELEIS_ROOM = { map = "INDIGO_PLATEAU_POKECENTER_1F", mode = "entry" },
        BRUNOS_ROOM = { map = "INDIGO_PLATEAU_POKECENTER_1F", mode = "entry" },
        AGATHAS_ROOM = { map = "INDIGO_PLATEAU_POKECENTER_1F", mode = "entry" },
        LANCES_ROOM = { map = "INDIGO_PLATEAU_POKECENTER_1F", mode = "entry" },
        CHAMPIONS_ROOM = { map = "INDIGO_PLATEAU_POKECENTER_1F", mode = "entry" },
    }

    local function objectOccupies(def, x, y)
        for _, obj in ipairs((def and def.objects) or {}) do
            if obj.x == x and obj.y == y then
                return true
            end
        end
        return false
    end

    local function warpOccupies(def, x, y)
        for _, warp in ipairs((def and def.warps) or {}) do
            if warp.x == x and warp.y == y then
                return true
            end
        end
        return false
    end

    local function walkableAndClear(game, mapId, x, y, allowWarp)
        local maps = game.data and game.data.gen2Maps
        local tilesets = game.data and game.data.gen2Tilesets
        local def = maps and maps[mapId]
        local tileset = def and tilesets and tilesets[def.tileset]
        if not (def and tileset) then return false end

        if not Gen2Map.defIsWalkableCell(def, tileset, x, y) then
            return false
        end

        -- Starting ON an object is an avoidable soft-lock/visual-overlap risk.
        if objectOccupies(def, x, y) then return false end

        -- Starting directly on a warp can immediately hand control to map setup
        -- on the first directional input. Prefer normal floor unless the whole
        -- destination has no other reasonable landing.
        if not allowWarp and warpOccupies(def, x, y) then return false end

        return true
    end

    local function nearestSafeCell(game, mapId, wantX, wantY)
        local maps = game.data and game.data.gen2Maps
        local def = maps and maps[mapId]
        if not def then return nil end

        local width = (def.width or 0) * 2
        local height = (def.height or 0) * 2
        if width <= 0 or height <= 0 then return nil end

        wantX = math.max(0, math.min(width - 1, math.floor(tonumber(wantX) or 0)))
        wantY = math.max(0, math.min(height - 1, math.floor(tonumber(wantY) or 0)))

        if walkableAndClear(game, mapId, wantX, wantY, false) then
            return wantX, wantY, 0, false
        end

        -- Manhattan rings give deterministic "nearest tile" behavior. Search
        -- the entire map; even a wildly different legacy coordinate resolves
        -- rather than producing a dead save.
        local maxRadius = width + height
        for radius = 1, maxRadius do
            for dx = -radius, radius do
                local dy = radius - math.abs(dx)
                local candidates
                if dy == 0 then
                    candidates = { { wantX + dx, wantY } }
                else
                    candidates = {
                        { wantX + dx, wantY - dy },
                        { wantX + dx, wantY + dy },
                    }
                end

                for _, p in ipairs(candidates) do
                    local x, y = p[1], p[2]
                    if x >= 0 and y >= 0 and x < width and y < height
                        and walkableAndClear(game, mapId, x, y, false) then
                        return x, y, radius, true
                    end
                end
            end
        end

        -- Last resort: permit a walkable warp tile rather than fail a save
        -- whose tiny destination interior consists almost entirely of warps.
        for y = 0, height - 1 do
            for x = 0, width - 1 do
                if walkableAndClear(game, mapId, x, y, true) then
                    return x, y, math.abs(x - wantX) + math.abs(y - wantY), true
                end
            end
        end

        return nil
    end

    local function entrySeed(game, mapId)
        local maps = game.data and game.data.gen2Maps
        local def = maps and maps[mapId]
        if not def then return 0, 0 end

        -- A map's first warp is normally an entrance/exit. Start the safety
        -- search next to it instead of on it.
        local warp = def.warps and def.warps[1]
        if warp then
            local candidates = {
                { warp.x, warp.y - 1 },
                { warp.x, warp.y + 1 },
                { warp.x - 1, warp.y },
                { warp.x + 1, warp.y },
            }
            for _, p in ipairs(candidates) do
                if walkableAndClear(game, mapId, p[1], p[2], false) then
                    return p[1], p[2]
                end
            end
            return warp.x, warp.y
        end

        return math.floor((def.width or 1)), math.floor((def.height or 1))
    end

    local function resolvePosition(game, sourceSave)
        local p = sourceSave.player or {}
        local sourceMap = p.map
        if type(sourceMap) ~= "string" or sourceMap == "" then
            return nil, "Gen 1 save has no current map"
        end

        local maps = game.data and game.data.gen2Maps
        if not maps then return nil, "Gold map data unavailable" end

        local targetMap = sourceMap
        local mode = "direct"
        local crosswalk = nil

        if not maps[targetMap] then
            crosswalk = KANTO_CROSSWALK[sourceMap]
            if not crosswalk or not maps[crosswalk.map] then
                return nil, ("No Project Celebi Kanto crosswalk for %s"):format(sourceMap)
            end
            targetMap = crosswalk.map
            mode = crosswalk.mode or "entry"
        end

        local wantX, wantY
        if mode == "entry" then
            wantX, wantY = entrySeed(game, targetMap)
        else
            wantX = tonumber(p.x) or 0
            wantY = tonumber(p.y) or 0
        end

        local x, y, distance, adjusted =
            nearestSafeCell(game, targetMap, wantX, wantY)

        if x == nil then
            return nil, ("No safe Project Celebi landing found on %s"):format(targetMap)
        end

        local facing = p.facing
        if facing ~= "up" and facing ~= "down"
            and facing ~= "left" and facing ~= "right" then
            facing = "down"
        end

        return {
            map = targetMap,
            x = x,
            y = y,
            facing = facing,

            -- Temporary metadata fields consumed by buildLegacySave and then
            -- stripped before Gold treats this as its native position record.
            _legacy = {
                sourceMap = sourceMap,
                sourceX = tonumber(p.x) or 0,
                sourceY = tonumber(p.y) or 0,
                requestedX = wantX,
                requestedY = wantY,
                targetMap = targetMap,
                mode = mode,
                crosswalk = crosswalk ~= nil,
                adjusted = adjusted and true or false,
                correctionDistance = distance or 0,
            },
        }
    end

    -- Gen 1 Champion detection
    -- ------------------------
    -- Keep Gen 1 history separate from Gold's native Elite Four / Hall of Fame
    -- state. Project Celebi only records historical proof under modData.
    --
    -- Evidence order:
    --   1. Native Gen1Recomp Hall of Fame records.
    --   2. Gen1Recomp's post-credits home marker.
    --   3. Original cartridge SRAM Hall of Fame bytes retained in rawImport.
    --
    -- The raw SRAM fallback matters for an already-completed cartridge/emulator
    -- .sav imported into Gen1Recomp: v0.1.78 intentionally does not model bank
    -- 0 Hall of Fame records, but preserves the original 32 KiB bytes in
    -- save.rawImport for lossless re-export.
    local RAW_SRAM_SIZE = 32768
    local RAW_HOF_OFFSET = 0x598       -- bank 0, zero-based
    local RAW_HOF_TEAM_SIZE = 0x60     -- 6 * 0x10-byte HOF_MON
    local RAW_HOF_TEAM_CAPACITY = 50

    local function rawHallOfFameCount(raw)
        if type(raw) ~= "string" or #raw < RAW_SRAM_SIZE then
            return 0
        end

        local count = 0
        for teamIndex = 0, RAW_HOF_TEAM_CAPACITY - 1 do
            local first = RAW_HOF_OFFSET + teamIndex * RAW_HOF_TEAM_SIZE
            local allZero = true
            local allFF = true

            for offset = 0, RAW_HOF_TEAM_SIZE - 1 do
                local b = raw:byte(first + offset + 1)
                if b == nil then
                    return count
                end
                if b ~= 0x00 then allZero = false end
                if b ~= 0xFF then allFF = false end
            end

            -- A cleared Hall of Fame region is either zero-filled (a
            -- template-less Recomp export) or $FF-filled (cartridge clear-save
            -- behavior). A written team necessarily differs from both.
            if not allZero and not allFF then
                count = count + 1
            end
        end

        return count
    end

    local function detectChampion(sourceSave, source)
        local nativeHof = sourceSave.hallOfFame
        if type(nativeHof) == "table" and #nativeHof > 0 then
            return true, "native_hall_of_fame", #nativeHof
        end

        if sourceSave.postGameHomeOk == true then
            return true, "native_postgame_home", 1
        end

        -- Raw SRAM is only accepted as Champion evidence alongside all eight
        -- Gen 1 badges. That prevents stale/raw bank bytes from promoting an
        -- unfinished playthrough by themselves.
        local badgeCount = tonumber(source and source.badges) or 0
        if badgeCount >= 8 then
            local rawCount = rawHallOfFameCount(sourceSave.rawImport)
            if rawCount > 0 then
                return true, "raw_sram_hall_of_fame", rawCount
            end
        end

        return false, "not_detected", 0
    end

    local function buildLegacySave(game, source, sourceSave)
        local sourcePlayer = sourceSave.player or {}

        -- v0.0.8's key change: construct a real, independent Gold NEW GAME
        -- skeleton instead of cloning whichever Gold playthrough happens to
        -- be running when the user invokes Project Celebi.
        --
        -- GoldSave.newGame is Gold's canonical format-7 constructor. It seeds
        -- the empty party/boxes, money, event/map-scene tables, RTC bookkeeping,
        -- phone state, Hall of Fame state, Mom state, inventory and every other
        -- generation-2-only field.
        local legacySave = GoldSave.newGame({
            playerName = sourcePlayer.name or "GOLD",
            trainerId = sourcePlayer.id,
            gender = "male",
            rivalName = "???",
        })

        if type(legacySave) ~= "table" then
            return nil, "Gold Save.newGame() failed"
        end

        -- A normal Game2:newGame anchors the clock before Oak's intro. Legacy
        -- starts skip Oak, so run the exact same exposed helper here.
        if game and game.anchorNewGameClock then
            pcall(game.anchorNewGameClock, legacySave)
        end

        local party, partyErr = convertParty(game, sourceSave)
        if not party then return nil, partyErr end

        local boxes, boxedCount, boxErr = convertBoxes(game, sourceSave)
        if not boxes then return nil, boxErr end

        local position, positionErr = resolvePosition(game, sourceSave)
        if not position then return nil, positionErr end
        local positionMeta = position._legacy or {}
        position._legacy = nil

        local bag, bagReport = transferItemTable(
            game,
            sourceSave.inventory or {},
            sourceSave.bagOrder or {}
        )
        local pcItems, pcReport = transferItemTable(
            game,
            sourceSave.pcItems or {},
            sourceSave.pcOrder or {}
        )
        local visited, visitedCount = copyVisited(sourceSave)

        local isChampion, championMethod, hallOfFameEntries =
            detectChampion(sourceSave, source)
        local kantoBadges = historicalKantoBadges(sourceSave, isChampion)
        local sourceMoney, moneySource = resolveSourceMoney(sourceSave)

        legacySave.party = party
        legacySave.boxes = boxes
        legacySave.currentBox = math.max(1, math.min(
            tonumber(sourceSave.currentBox) or 1,
            math.min(12, GoldSave.NUM_BOXES)
        ))
        legacySave.playTime = convertPlayTime(sourceSave)
        legacySave.position = position
        legacySave.playerState = GoldSave.PLAYER_NORMAL or "normal"

        -- Economy / possessions live in Gold's native fields.
        legacySave.player.money = sourceMoney
        legacySave.player.coins = math.max(0, math.min(
            tonumber(sourceSave.coins) or 0,
            GoldSave.MAX_COINS
        ))
        legacySave.inventory = bag
        legacySave.pcItems = pcItems

        -- Gen 1's decoder explicitly preserves its FLY destination set as
        -- save.visited[mapId]. Gold v0.1.78 does not initialize this field in
        -- Save.newGame, but keeping the same semantic set on a Project Celebi save is
        -- harmless and gives shared/ported Fly UIs the historical Kanto towns.
        legacySave.visited = visited

        -- Native Gold navigation state.  Unlike the earlier prototype string
        -- flags, these are the exact engineFlags consumed by StartMenu,
        -- Pokegear and FieldMoves.flyPoints.
        local nativeKantoFlypoints, nativeJohtoFlypoints =
            seedLegacyNavigationState(legacySave, isChampion)

        -- A Project Celebi trainer is not a literal fresh ten-year-old starting Gold:
        -- they already own a map-capable field device. Gold's Fly UI is routed
        -- through the Pokegear/Town Map stack, so the native Project Celebi skeleton
        -- needs the two utility engine flags that a normal Gold playthrough
        -- would acquire from Mom + the Cherrygrove guide.
        --
        -- We intentionally DO NOT grant PHONE/RADIO/EXPN cards here.
        -- Gold-native story state remains genuinely fresh:
        --   badges / kantoBadges empty
        --   events / flags / mapScenes empty
        --   Hall of Fame empty
        --   boxes empty
        --   inventory empty
        -- This is intentional. Gen 1 history is represented separately instead
        -- of poisoning Gold's own story flags.
        mergePokedex(game, legacySave, sourceSave)

        -- Seed canonical Kanto history BEFORE Gold loads the new world.
        -- This prevents a Mt. Moon / Victory Road rival scene from firing on
        -- the very first frame of a freshly imported Project Celebi save.
        local completedGymLeaders =
            seedKantoGymCompletion(game, legacySave, kantoBadges, isChampion)
        local hiddenRivals = seedRivalLock(game, legacySave)

        legacySave.modData = legacySave.modData or {}
        legacySave.modData.legacy_bridge = {
            schema = 11,
            imported = true,
            importedAt = os.time(),
            bridgeVersion = "0.1.31",
            startMode = "native_gold_new_game",
            source = {
                game = source.version,
                slot = source.slotId,
                trainer = sourcePlayer.name,
                trainerId = sourcePlayer.id,
                map = positionMeta.sourceMap or position.map,
                x = positionMeta.sourceX or position.x,
                y = positionMeta.sourceY or position.y,
                resolvedMap = position.map,
                resolvedX = position.x,
                resolvedY = position.y,
            },
            kanto = {
                badgeCount = source.badges or 0,
                eightBadges = (source.badges or 0) >= 8,
                badges = kantoBadges,
                gymsComplete = isChampion and true or false,
                completedGymLeaders = completedGymLeaders,
                champion = isChampion,
                championDetection = championMethod,
                hallOfFameEntries = hallOfFameEntries,
            },
            campaign = {
                state = "KANTO_FREE_ROAM",
                johtoUnlocked = false,
            },
            rival = {
                state = "LOCKED",
                introduced = false,
                hiddenObjects = hiddenRivals,
                unlockAt = "JOHTO_BORDER",
                firstMeetingMap = "NEW_BARK_TOWN",
            },
            difficulty = {
                locked = false,
                rating = nil,
                source = nil,
            },
            johto = {
                started = false,
                borderUnlocked = isChampion and true or false,
                borderReason = isChampion
                    and "gen1_champion"
                    or "gen1_champion_required",
            },
            transfer = {
                party = #party,
                boxes = true,
                boxedPokemon = boxedCount,
                sourceBoxes = 12,
                destinationBoxes = GoldSave.NUM_BOXES,
                pokedex = true,
                playTime = true,
                money = legacySave.player.money,
                moneySource = moneySource,
                coins = legacySave.player.coins,
                bag = {
                    transferred = bagReport.transferred,
                    transferredUnits = bagReport.transferredUnits,
                    aliases = bagReport.aliases,
                    skipped = bagReport.skipped,
                },
                pcItems = {
                    transferred = pcReport.transferred,
                    transferredUnits = pcReport.transferredUnits,
                    aliases = pcReport.aliases,
                    skipped = pcReport.skipped,
                },
                visitedKantoFlypoints = visitedCount,
                nativeKantoFlypoints = nativeKantoFlypoints,
                nativeJohtoFlypoints = nativeJohtoFlypoints,
                pokegear = {
                    device = true,
                    map = true,
                    phone = true,
                    radio = true,
                    expn = true,
                },
                positionMode = positionMeta.mode or "direct",
                positionCrosswalk = positionMeta.crosswalk or false,
                positionAdjusted = positionMeta.adjusted or false,
                positionCorrectionDistance = positionMeta.correctionDistance or 0,
                requestedX = positionMeta.requestedX,
                requestedY = positionMeta.requestedY,
            },
        }

        -- Normalize through Gold's own save layer before writing. This fills any
        -- new native fields added by the format, clamps legal ranges, derives
        -- missing defaults and stamps only OT fields that are absent.
        GoldSave.normalize(legacySave)

        return legacySave
    end

    local function importJourney(game, source, sourceSave)
        local legacySave, buildErr = buildLegacySave(game, source, sourceSave)
        if not legacySave then
            return false, buildErr
        end

        -- Never overwrite either side. Allocate a brand-new Gold slot.
        local slotId = SaveData.createSlot("gold")
        if not slotId then return false, "could not allocate a Gold save slot" end

        local ok, writeErr = SaveData.writeSlot("gold", slotId, legacySave)
        if not ok then
            pcall(SaveData.deleteSlot, "gold", slotId)
            return false, "could not write Project Celebi slot: " .. tostring(writeErr)
        end

        local trainer = legacySave.player and legacySave.player.name or "GEN1"
        pcall(SaveData.renameSlot, "gold", slotId, "CELEBI " .. tostring(trainer))
        SaveData.setActiveSlot("gold", slotId)

        local legacyMeta = legacySave.modData
            and legacySave.modData.legacy_bridge
        local kantoMeta = legacyMeta and legacyMeta.kanto or {}

        logInfo(("Project Celebi: imported %s/%s -> gold/%s at %s (%d,%d); champion=%s via %s")
            :format(source.version, source.slotId, slotId,
                    legacySave.position.map,
                    legacySave.position.x, legacySave.position.y,
                    tostring(kantoMeta.champion),
                    tostring(kantoMeta.championDetection)))

        -- Reload the live Gold runtime from the table we just wrote. This clears
        -- the menu stack, rebuilds World, and places the player at the imported
        -- Kanto position. Future normal SAVE/F1 writes follow the new active slot.
        game:continueGame(legacySave)
        return true, slotId
    end

    mod.content.screens:register(SCREEN_SOURCES, {
        new = function(game)
            local sources = detectSources()
            local items = {}

            if #sources == 0 then
                items[#items + 1] = {
                    label = "NO GEN 1 SAVES FOUND",
                    value = false,
                }
            else
                for _, source in ipairs(sources) do
                    items[#items + 1] = {
                        label = sourceLabel(source),
                        right = sourceRight(source),
                        value = source,
                    }
                end
            end

            return mod.ui.ListMenu.new(
                game,
                "PROJECT CELEBI",
                items,
                {
                    -- ListMenu passes the WHOLE menu item. The authored payload
                    -- lives under item.value. v0.0.6 proved this raw-reader path
                    -- works on the live Windows v0.1.78 build.
                    onChoose = function(item, menu)
                        local source = item and item.value
                        if type(source) ~= "table" then
                            return
                        end

                        local save, activeId, recoveredFrom =
                            readActiveSlot(source.version)

                        if not save then
                            logWarn("Project Celebi raw source read failed: "
                                .. tostring(recoveredFrom))
                            game:say("GEN 1 SAVE READ\nFAILED:\f"
                                .. tostring(recoveredFrom))
                            return
                        end

                        -- Re-stamp the authoritative source slot from the engine
                        -- registry rather than trusting UI-carried metadata.
                        source.slotId = activeId

                        logInfo(("Project Celebi source ready: %s/%s trainer=%s")
                            :format(
                                tostring(source.version),
                                tostring(activeId),
                                tostring(save.player and save.player.name)
                            ))

                        local ok, result = importJourney(game, source, save)
                        if not ok then
                            logWarn("Project Celebi import failed: " .. tostring(result))
                            game:say("CELEBI IMPORT\nFAILED:\f" .. tostring(result))
                            return
                        end

                        -- Success path: importJourney switches the active Gold
                        -- slot and calls game:continueGame(legacySave), which
                        -- clears this menu and rebuilds the Gold world.
                    end,
                }
            )
        end,
    })

    -- ---------------------------------------------------------------------
    -- Project Celebi Kanto travel / Pokegear bridge
    local legacyTravelStateReady = false

    local LEGACY_KANTO_FLY_ORDER = {
        "PALLET_TOWN",
        "VIRIDIAN_CITY",
        "PEWTER_CITY",
        "CERULEAN_CITY",
        "LAVENDER_TOWN",
        "VERMILION_CITY",
        "CELADON_CITY",
        "FUCHSIA_CITY",
        "SAFFRON_CITY",
        "CINNABAR_ISLAND",
        "INDIGO_PLATEAU",
    }

    local LEGACY_KANTO_FLY_TARGET = {
        PALLET_TOWN = "PALLET_TOWN",
        VIRIDIAN_CITY = "VIRIDIAN_CITY",
        PEWTER_CITY = "PEWTER_CITY",
        CERULEAN_CITY = "CERULEAN_CITY",
        LAVENDER_TOWN = "LAVENDER_TOWN",
        VERMILION_CITY = "VERMILION_CITY",
        CELADON_CITY = "CELADON_CITY",
        FUCHSIA_CITY = "FUCHSIA_CITY",
        SAFFRON_CITY = "SAFFRON_CITY",
        CINNABAR_ISLAND = "CINNABAR_ISLAND",
        INDIGO_PLATEAU = "INDIGO_PLATEAU_POKECENTER_1F",
    }

    local function tableHasAnyTruthy(t)
        for _, value in pairs(t or {}) do
            if value then return true end
        end
        return false
    end

    local function isLegacySave(save)
        local meta = save
            and save.modData
            and save.modData.legacy_bridge
        return meta and meta.imported and meta or nil
    end

    local function ensureLegacyTravelState(game)
        if not game then return end
        liveGame = game

        local save = game.save
        local meta = isLegacySave(save)
        if not meta then return end

        meta.travel = meta.travel or {}

        -- Restore Gen 1 visited-town history if this slot predates the import
        -- migration that started serializing it.
        if not tableHasAnyTruthy(save.visited) then
            local sourceGame = meta.source and meta.source.game
            if sourceGame then
                local sourceSave = select(1, readActiveSlot(sourceGame))
                if sourceSave and tableHasAnyTruthy(sourceSave.visited) then
                    local copied, count = copyVisited(sourceSave)
                    save.visited = copied
                    meta.travel.flypointsRecovered = count
                    meta.travel.flypointsSource = 'active_gen1_save'
                end
            end
        end

        local kantoCount, johtoCount = seedLegacyNavigationState(
            save,
            meta.kanto and meta.kanto.champion == true
        )

        meta.travel.pokegear = true
        meta.travel.mapCard = true
        meta.travel.phoneCard = true
        meta.travel.radioCard = true
        meta.travel.expnCard = true
        meta.travel.nativeKantoFlypoints = kantoCount
        meta.travel.nativeJohtoFlypoints = johtoCount

        if not legacyTravelStateReady and mod.log and mod.log.info then
            mod.log:info((
                'Project Celebi native navigation ready: Pokegear all cards, Kanto=%d Johto=%d'
            ):format(kantoCount, johtoCount))
        end
        legacyTravelStateReady = true
    end

    local function legacyFlyVisited(game)
        ensureLegacyTravelState(game)
        local save = game and game.save
        local meta = isLegacySave(save)
        if not meta then return {} end

        local visited = save.visited or {}
        if not tableHasAnyTruthy(visited)
            and meta.kanto
            and meta.kanto.champion then
            visited = {}
            for _, id in ipairs(LEGACY_KANTO_FLY_ORDER) do
                visited[id] = true
            end
        end
        return visited
    end

    -- Fold the currently-running Gold World back into its save before a
    -- Project Celebi relocation. Gold's own SAVE command calls this exact method.
    --
    -- This is critical for trainer battles: the trainer-defeated bit is set in
    -- world.events during play and does not reach save.events until snapshot.
    local function snapshotBeforeLegacyRelocation(game)
        if not game then return nil end

        if type(game.snapshotSave) == "function" then
            local ok, saveOrErr = pcall(game.snapshotSave, game)
            if ok and type(saveOrErr) == "table" then
                return saveOrErr
            end

            if not ok and mod.log and mod.log.warn then
                mod.log:warn("Project Celebi snapshotSave failed: "
                    .. tostring(saveOrErr))
            end
        end

        return game.save
    end

    local function doLegacyFly(game, sourceMap)
        local targetMap = LEGACY_KANTO_FLY_TARGET[sourceMap]
        local maps = game.data and game.data.gen2Maps

        if not targetMap or not (maps and maps[targetMap]) then
            game:say("That destination is\nnot available yet.")
            return false
        end

        -- v0.1.8 tried world:flyTo() first. In the Gold beta that function can
        -- return without throwing while also not performing a transition, so
        -- pcall success is not evidence of a successful Fly.
        --
        -- Use the Project Celebi relocation path that has already been proven for:
        --   * initial Kanto spawn
        --   * changed-map crosswalks
        --   * Tohjo passage
        --
        -- This gives us deterministic Kanto travel while Gold's graphical Fly
        -- path continues to mature.
        local seedX, seedY = entrySeed(game, targetMap)
        local x, y = nearestSafeCell(game, targetMap, seedX, seedY)
        if x == nil then
            game:say("No safe FLY landing\nwas found.")
            return false
        end

        local liveSave = snapshotBeforeLegacyRelocation(game)
        if not liveSave then
            game:say("Could not preserve\nworld progress.")
            return false
        end

        local meta = isLegacySave(liveSave)
        if meta then
            meta.travel = meta.travel or {}
            meta.travel.lastFly = {
                sourceFlypoint = sourceMap,
                targetMap = targetMap,
                x = x,
                y = y,
                method = "legacy_safe_landing",
                usedAt = os.time(),
            }
        end

        liveSave.position = {
            map = targetMap,
            x = x,
            y = y,
            facing = "down",
        }

        if mod.log and mod.log.info then
            mod.log:info(("Project Celebi FLY: %s -> %s (%d,%d)")
                :format(
                    tostring(sourceMap),
                    tostring(targetMap),
                    x,
                    y
                ))
        end

        -- continueGame() clears the active UI stack and rebuilds the world, so
        -- the FLY menu does not need to close itself before the transition.
        game:continueGame(liveSave)
        return true
    end

    -- FLY no longer has a Project Celebi UI implementation.  After the Project Celebi badge
    -- bridge succeeds, Gold's native queued field-move pipeline owns the rest:
    -- World:runFieldMove -> World:openFlyMap -> Gen2 Pokegear FLY_MAP.

    local function popTopScreen(game)
        if game
            and game.stack
            and type(game.stack.pop) == "function" then
            game.stack:pop()
            return true
        end

        -- Defensive fallback. This should not normally be needed, but it is
        -- preferable to trapping a player inside a utility screen.
        if game and game.save and game.continueGame then
            game:continueGame(game.save)
            return true
        end

        return false
    end

    local function openLegacyPokegear(game)
        ensureLegacyTravelState(game)

        local ok, Pokegear = pcall(require, 'src.ui.gen2.Pokegear')
        if not (ok and type(Pokegear) == 'table'
            and type(Pokegear.new) == 'function') then
            game:say('POKéGEAR UI\nis unavailable.')
            return
        end

        local world = game.world
        local currentLandmark = world
            and type(world.currentLandmarkId) == 'function'
            and world:currentLandmarkId()
            or nil

        local screen = Pokegear.new(game, {
            save = game.save,
            currentLandmark = currentLandmark,
            onClose = function()
                game.stack:pop()
            end,
        })

        game.stack:push(screen)
    end

    mod.hooks:wrap("ui.start_menu.items", function(nextFn, game, items)
        liveGame = game
        ensureLegacyTravelState(game)
        ensureLegacyCanonicalWorldState(game)

        local out = nextFn(game, items)
        local meta = isLegacySave(game.save)

        if meta then
            local hasNativePokegear = false
            for _, item in ipairs(out or {}) do
                if item.value == "pokegear"
                    or item.id == "pokegear"
                    or item.label == "<PO><KE>GEAR" then
                    hasNativePokegear = true
                    break
                end
            end

            if not hasNativePokegear then
                out = mod.ui.insertBefore(out, "SAVE", {
                    label = "POKéGEAR",
                    onSelect = function()
                        liveGame = game
                        openLegacyPokegear(game)
                    end,
                })
            end
        end

        return mod.ui.insertBefore(out, "SAVE", {
            label = "CELEBI",
            onSelect = function()
                liveGame = game
                mod.ui.push(game, SCREEN_SOURCES)
            end,
        })
    end)

    mod.events:on("map.entered", function(payload)
        ensureLegacyTravelState(liveGame)
    end)

    mod.events:on("world.stepped", function(payload)
        ensureLegacyTravelState(liveGame)
    end)

    -- ---------------------------------------------------------------------
    -- Project Celebi Johto campaign bootstrap / difficulty lock
    --
    -- The campaign is completely dormant while the continuing trainer remains
    -- in Kanto. The first physical step into Johto is the one-way chronology
    -- hinge that arms New Bark and freezes the campaign's difficulty baseline.
    local function sortedPartyLevels(save)
        local levels = {}
        for _, mon in ipairs((save and save.party) or {}) do
            local level = math.floor(tonumber(mon.level) or 0)
            if level > 0 then
                levels[#levels + 1] = level
            end
        end
        table.sort(levels, function(a, b) return a > b end)
        return levels
    end

    local function calculateLegacyDifficulty(save)
        local levels = sortedPartyLevels(save)
        if #levels == 0 then
            return 1, {}, "empty_party_fallback"
        end

        local top = {}
        for i = 1, math.min(3, #levels) do
            top[#top + 1] = levels[i]
        end

        local rating
        if #top == 1 then
            rating = top[1]
        elseif #top == 2 then
            rating = math.floor((top[1] + top[2]) / 2 + 0.5)
        else
            -- Median of the strongest three: robust against one absurdly
            -- over-levelled carry while still representing the veteran core.
            rating = top[2]
        end

        return rating, top, "median_top_three"
    end

    local function ensureCampaignSchema(meta)
        local previousSchema = tonumber(meta.schema) or 0
        meta.schema = math.max(previousSchema, 11)
        meta.bridgeVersion = "0.1.31"

        meta.campaign = meta.campaign or {
            state = (meta.johto and meta.johto.started)
                and "JOHTO_INTRO"
                or "KANTO_FREE_ROAM",
            johtoUnlocked = meta.johto
                and meta.johto.started == true
                or false,
        }

        meta.rival = meta.rival or {}
        if not meta.rival.state then
            meta.rival.state = meta.campaign.johtoUnlocked
                and "ARMED_NEW_BARK"
                or "LOCKED"
        end
        meta.rival.firstMeetingMap =
            meta.rival.firstMeetingMap or "NEW_BARK_TOWN"

        -- v0.1.12-v0.1.25 used a global rival visibility lock. That was useful
        -- before Johto existed, but after New Bark it kept re-hiding Burned
        -- Tower Silver forever. Schema 7 converts already-started campaigns to
        -- the native-continuity phase and schedules one targeted repair pass.
        if previousSchema < 7 then
            meta.rival.continuityMigratedFrom = previousSchema
            meta.rival.continuityMigratedAt = os.time()
            meta.rival.needsContinuityRepair = true
            if meta.campaign.johtoUnlocked == true then
                meta.rival.state = "JOHTO_ACTIVE"
                meta.rival.introduced = true
            end
        end

        -- Schema 8 fixes the last Burned Tower visual edge case. v0.1.26
        -- cleared Silver's event bit after LoadObjectMasks had already built
        -- the map, so the script could address an NPC that was still absent
        -- from the live people list. Schedule a one-shot mask refresh for
        -- already-started Project Celebi campaigns.
        if previousSchema < 8 and meta.campaign.johtoUnlocked == true then
            meta.rival.needsBurnedTowerVisualRepair = true
        end

        -- Schema 9 replaces the mask-refresh workaround with Gold's own
        -- Script_appear implementation.  A live Burned Tower scene needs an
        -- actual object struct, not merely a clear event bit / unmasked row.
        -- Existing v0.1.27 campaigns receive one native-respawn repair pass.
        if previousSchema < 9 and meta.campaign.johtoUnlocked == true then
            meta.rival.needsBurnedTowerNativeRepair = true
        end

        -- Schema 10 fixes the ROOT rival-lock bug. v0.1.12-v0.1.28 imported
        -- saves globally set every SPRITE_RIVAL event bit, including the
        -- Sprout Tower scenery Silver that its coord-event expects to already
        -- exist. Existing campaigns get a one-shot Sprout Tower repair/replay.
        --
        -- Schema 10 also repairs a separate v0.1.28-era HM menu shim bug:
        -- Lua cannot retain `nil` values in a restore table, so temporarily
        -- granting all Johto badges for a legacy-authorized HM could leak the
        -- previously-absent badge keys into the persistent save.
        if previousSchema < 10 and meta.campaign.johtoUnlocked == true then
            meta.rival.needsSproutTowerNativeRepair = true
            meta.rival.needsSproutTowerSceneReplay = true
            meta.needsJohtoBadgeLeakRepair = true
        end

        -- Schema 11 is a world-access QoL revision only. It does not forge
        -- EVENT_FOUGHT_SNORLAX: on each Victory Road Gate visit the Legacy
        -- runtime masks only the Route 22/Viridian Black Belt object, leaving
        -- both Gold's Vermilion Snorlax and the Mt. Silver guard progression
        -- fully native. No one-shot save migration is required.

        meta.rival.diagnostics = meta.rival.diagnostics or {
            version = 2,
            mapEntries = 0,
            repairs = 0,
        }
        meta.rival.diagnostics.version = math.max(
            tonumber(meta.rival.diagnostics.version) or 1, 2)

        meta.diagnostics = meta.diagnostics or {}
        meta.diagnostics.loadedBuild = "0.1.31"

        meta.difficulty = meta.difficulty or {
            locked = false,
            rating = nil,
            source = nil,
        }

        -- Older experimental Project Celebi slots may already have crossed the border
        -- before the difficulty system existed. Lock their baseline on first
        -- v0.1.21 load rather than silently leaving it undefined.
        if meta.campaign.johtoUnlocked == true
            and meta.difficulty.locked ~= true then
            -- The caller may supply the live save later; this marker tells the
            -- runtime bootstrap to fill it once.
            meta.difficulty.needsMigrationLock = true
        end

        meta.johto = meta.johto or {
            started = false,
        }
    end

    local function setMapSceneBoth(game, mapId, scene)
        if not (game and game.save) then return end

        game.save.mapScenes = game.save.mapScenes or {}
        game.save.mapScenes[mapId] = scene

        if game.world then
            game.world.mapScenes = game.world.mapScenes or {}
            game.world.mapScenes[mapId] = scene
        end
    end

    -- Serialized save.position is not rewritten on every walking step.
    -- Chronology/border checks must use the live Gold World player coordinates.
    local function liveWorldPosition(game)
        local world = game and game.world
        local player = world and world.player
        local mapId = world and world.map and world.map.id

        if mapId and player then
            return {
                map = mapId,
                x = player.cellX,
                y = player.cellY,
                source = "world.player",
            }
        end

        local pos = game and game.save and game.save.position
        if pos then
            return {
                map = pos.map,
                x = pos.x,
                y = pos.y,
                source = "save.position_fallback",
            }
        end

        return nil
    end

    local JOHTO_ENTRY_PREFIXES = {
        "NEW_BARK_TOWN",
        "CHERRYGROVE_CITY",
        "VIOLET_CITY",
        "AZALEA_TOWN",
        "GOLDENROD_CITY",
        "ECRUTEAK_CITY",
        "OLIVINE_CITY",
        "CIANWOOD_CITY",
        "MAHOGANY_TOWN",
        "BLACKTHORN_CITY",
        "LAKE_OF_RAGE",
        "SPROUT_TOWER",
        "RUINS_OF_ALPH",
        "ILEX_FOREST",
        "NATIONAL_PARK",
        "BURNED_TOWER",
        "TIN_TOWER",
        "LIGHTHOUSE",
        "WHIRL_ISLAND",
    }

    local function isUnambiguousJohtoMap(mapId)
        mapId = tostring(mapId or "")

        local route = tonumber(mapId:match("^ROUTE_(%d+)"))
        if route and route >= 29 and route <= 46 then
            return true
        end

        for _, prefix in ipairs(JOHTO_ENTRY_PREFIXES) do
            if mapId:sub(1, #prefix) == prefix then
                return true
            end
        end

        return false
    end

    local function armJohtoIntroState(game, meta, entry)
        ensureCampaignSchema(meta)

        if meta.campaign.johtoUnlocked == true then
            return false
        end

        local save = game and game.save
        if not save then return false end

        local rating, topLevels, method =
            calculateLegacyDifficulty(save)

        meta.campaign.state = "JOHTO_INTRO"
        meta.campaign.johtoUnlocked = true
        meta.campaign.johtoUnlockedAt = os.time()
        meta.campaign.entry = entry

        meta.johto.started = true
        meta.johto.startedAt = meta.campaign.johtoUnlockedAt
        meta.johto.entry = entry

        -- Silver is now allowed to exist. New Bark remains the Project Celebi first
        -- sighting; after that single introduction we hand his Johto campaign
        -- back to Gold's native scripts (while Cherrygrove stays skipped).
        meta.rival.state = "ARMED_NEW_BARK"
        meta.rival.armedAt = meta.campaign.johtoUnlockedAt
        meta.rival.introduced = false

        -- Bonus next syllabus step: freeze the power baseline now, before the
        -- player can manipulate it by depositing the veteran team.
        meta.difficulty.locked = true
        meta.difficulty.rating = rating
        meta.difficulty.source = method
        meta.difficulty.topPartyLevels = topLevels
        meta.difficulty.lockedAt = meta.campaign.johtoUnlockedAt
        meta.difficulty.lockedMap = entry and entry.map
        meta.difficulty.applied = false

        -- Project Celebi arrives in New Bark WITH Pokemon. Disable the vanilla scene
        -- that has the teacher physically drag a rookie back for trying to
        -- leave town without a starter.
        --
        -- New Bark scene index:
        --   0 = TEACHER_STOPS_YOU
        --   1 = NOOP
        setMapSceneBoth(game, "NEW_BARK_TOWN", 1)

        if mod.log and mod.log.info then
            mod.log:info(
                "Project Celebi New Bark bootstrap: scene=1 (teacher exit-block disabled)"
            )
        end

        -- Keep Cherrygrove's first-rival battle dormant. Its scene index 0 is
        -- the vanilla NOOP; a later Project Celebi Silver bootstrap will deliberately
        -- arm scene 1 when chronology says the first battle should happen.
        setMapSceneBoth(game, "CHERRYGROVE_CITY", 0)

        if mod.log and mod.log.info then
            mod.log:info((
                "Project Celebi JOHTO armed at %s (%s,%s); difficulty=%d top=[%s]"
            ):format(
                tostring(entry and entry.map),
                tostring(entry and entry.x),
                tostring(entry and entry.y),
                rating,
                table.concat(topLevels, ",")
            ))
        end

        return true
    end

    -- ---------------------------------------------------------------------
    -- Project Celebi campaign world-state repair
    --
    -- New imports already contain this state before their World is built.
    -- This runtime arm also upgrades existing Project Celebi slots and enforces the
    -- rival lock after every map transition.
    local function legacyMetaFromSave(save)
        local meta = save
            and save.modData
            and save.modData.legacy_bridge
        return meta and meta.imported and meta or nil
    end

    local function currentMapId(game)
        return game
            and game.world
            and game.world.map
            and game.world.map.id
            or (game and game.save and game.save.position
                and game.save.position.map)
    end

    local function applyKantoGymRuntimeState(game, meta)
        local save = game and game.save
        local world = game and game.world
        if not (save and world and world.events) then return end

        meta.kanto = meta.kanto or {}
        local historical = meta.kanto.badges or {}

        -- A verified Champion necessarily had all eight Gen 1 badges.
        if meta.kanto.champion then
            for _, badge in ipairs(KANTO_BADGES) do
                historical[badge] = true
            end
        end
        meta.kanto.badges = historical

        local seededBadges, ownedBadgeFlags =
            seedGoldKantoBadgeStore(
                save,
                historical,
                meta.kanto.champion == true
            )

        local scripts = world.scripts
            or (game.data and game.data.gen2Scripts)
            or {}

        local completedScripts =
            seedKantoGymScriptEvents(
                scripts,
                world.events,
                ownedBadgeFlags
            )

        meta.kanto.goldBadgeKeys = seededBadges
        meta.kanto.completedGymLeaderScripts = completedScripts
        meta.kanto.gymsComplete =
            meta.kanto.champion and true or false
    end

    local function setRivalObjectHidden(world, def, hidden, exceptNewBark)
        if not (world and world.events and def) then return false end
        local changed = false
        for _, obj in ipairs(def.objects or {}) do
            if obj.sprite == "SPRITE_RIVAL" and obj.eventFlag then
                if not (exceptNewBark and def.id == "NEW_BARK_TOWN") then
                    world.events:set(obj.eventFlag, hidden and true or false)
                    changed = true
                end
            end
        end
        return changed
    end

    -- ---------------------------------------------------------------------
    -- Project Celebi Johto tutorial invariant bridge
    --
    -- Our campaign intentionally suppresses/reorders pieces of the rookie
    -- Silver/Elm chronology. Do not assume every incidental vanilla event side
    -- effect still fires in exactly the original order.
    --
    -- The important invariant after reporting back to Elm is:
    --   EVENT_ROUTE_30_BATTLE = SET   -> battling kids/Rattata disappear
    --   EVENT_ROUTE_30_YOUNGSTER_JOEY = CLEAR -> Joey becomes his trainer NPC
    --
    -- Discover those event ids from Elm's own extracted script rather than
    -- binding this mod to retail numeric constants.
    local elmRoute30Progression = nil
    local elmRoute30ProgressionScanned = false

    local function discoverElmRoute30Progression(game)
        if elmRoute30ProgressionScanned then
            return elmRoute30Progression
        end
        elmRoute30ProgressionScanned = true

        local world = game and game.world
        local scripts = (world and world.scripts)
            or (game and game.data and game.data.gen2Scripts)
            or {}

        for scriptKey, rows in pairs(scripts) do
            if type(rows) == "table" then
                for i = 1, #rows - 3 do
                    local a, b, c, d =
                        rows[i], rows[i + 1], rows[i + 2], rows[i + 3]

                    if type(a) == "table"
                        and type(b) == "table"
                        and type(c) == "table"
                        and type(d) == "table"
                        and a.op == "setevent"
                        and b.op == "setmapscene"
                        and c.op == "clearevent"
                        and d.op == "setevent" then

                        local gaveEgg = scriptCommandArg(a, "event")
                        local joey = scriptCommandArg(c, "event")
                        local route30 = scriptCommandArg(d, "event")

                        if gaveEgg ~= nil
                            and joey ~= nil
                            and route30 ~= nil then
                            elmRoute30Progression = {
                                scriptKey = scriptKey,
                                gaveEggEvent = gaveEgg,
                                joeyEvent = joey,
                                route30BattleEvent = route30,
                            }

                            if mod.log and mod.log.info then
                                mod.log:info((
                                    "Project Celebi Elm progression discovered: "
                                    .. "gaveEgg=%s joey=%s route30Battle=%s"
                                ):format(
                                    tostring(gaveEgg),
                                    tostring(joey),
                                    tostring(route30)
                                ))
                            end

                            return elmRoute30Progression
                        end
                    end
                end
            end
        end

        if mod.log and mod.log.warn then
            mod.log:warn(
                "Project Celebi Elm progression: could not discover Route 30 events"
            )
        end
        return nil
    end

    local function applyRoute30PostElmState(game, meta, reason)
        local world = game and game.world
        if not (world and world.events) then return false end

        local ids = discoverElmRoute30Progression(game)
        if not ids then return false end

        local changed = false

        if not world.events:get(ids.route30BattleEvent) then
            world.events:set(ids.route30BattleEvent, true)
            changed = true
        end

        if world.events:get(ids.joeyEvent) then
            world.events:set(ids.joeyEvent, false)
            changed = true
        end

        meta.johto = meta.johto or {}
        meta.johto.route30Unlocked = true
        meta.johto.route30UnlockedAt =
            meta.johto.route30UnlockedAt or os.time()
        meta.johto.route30UnlockReason =
            meta.johto.route30UnlockReason or reason

        -- If the player is already staring at the blockade, refresh the actual
        -- current-map object masks immediately. A bare event write only affects
        -- object visibility on the next LoadObjectMasks.
        if currentMapId(game) == "ROUTE_30"
            and type(world.loadObjectMasks) == "function"
            and type(world.rebuildPeople) == "function"
            and not (type(world.scriptRunning) == "function"
                and world:scriptRunning()) then
            world:loadObjectMasks()
            world:rebuildPeople({ seamless = true })
        end

        if changed and mod.log and mod.log.info then
            mod.log:info(
                "Project Celebi Johto tutorial: Route 30 blockade cleared (" ..
                tostring(reason) .. ")"
            )
        end

        return true
    end

    local function repairLegacyJohtoTutorial(game, meta)
        if not (game and game.world and meta) then return end
        ensureCampaignSchema(meta)

        if not (meta.campaign and meta.campaign.johtoUnlocked == true) then
            return
        end

        meta.johto = meta.johto or {}
        local mapId = currentMapId(game)
        local ids = discoverElmRoute30Progression(game)

        -- First, mirror vanilla directly whenever Elm's own completion event
        -- exists. This repairs existing Project Celebi saves without replaying anything.
        if ids
            and game.world.events:get(ids.gaveEggEvent) then
            applyRoute30PostElmState(
                game, meta, "vanilla_elm_gave_mystery_egg_event")
            return
        end

        -- Project Celebi chronology fallback:
        -- visiting Mr. Pokemon's house and THEN returning to Elm's Lab is the
        -- campaign milestone that should have opened Route 30. This avoids
        -- depending on the suppressed first-rival/starter sequence merely to
        -- obtain an unrelated overworld visibility side effect.
        if mapId == "MR_POKEMONS_HOUSE" then
            meta.johto.mrPokemonVisited = true
            meta.johto.mrPokemonVisitedAt =
                meta.johto.mrPokemonVisitedAt or os.time()
        elseif mapId == "ELMS_LAB"
            and meta.johto.mrPokemonVisited == true then
            meta.johto.returnedToElm = true
            meta.johto.returnedToElmAt =
                meta.johto.returnedToElmAt or os.time()

            applyRoute30PostElmState(
                game, meta, "legacy_mr_pokemon_to_elm_roundtrip")
        end
    end

    local function johtoBadgeCount(save)
        local count = 0
        local badges = save
            and save.player
            and save.player.badges
            or {}

        -- Count only Gold's eight canonical Johto badge slots. This ignores
        -- unrelated table keys and supports both modern name-keyed saves and
        -- older numeric-keyed shapes accepted by FieldMoves.hasBadge().
        for index, name in ipairs(Gen2FieldMoves.JOHTO_BADGES or {}) do
            if badges[name] == true or badges[index] == true then
                count = count + 1
            end
        end
        return count
    end

    local function hasGoldHallOfFame(save)
        local hof = save and save.hallOfFame
        if type(hof) == "table" then
            -- Gold v0.1.78 always has { count = 0, teams = {} } even before
            -- induction, so `next(hof) ~= nil` is NOT a Hall-of-Fame test.
            local count = tonumber(hof.count)
            if count ~= nil then return count > 0 end
            return type(hof.teams) == "table" and #hof.teams > 0
        end
        if type(hof) == "number" then return hof > 0 end
        return hof == true
    end

    local function inferJohtoBadgesFromVictoryEvents(game, save)
        local scripts = game
            and game.data
            and game.data.gen2Scripts
            or {}
        local events = game
            and game.world
            and game.world.events
            or eventsFromSave(save)

        local earned = {}
        local evidence = {}
        local discovered = {}

        for scriptKey, rows in pairs(scripts) do
            if type(rows) == "table" then
                local badgeNames = {}
                for _, cmd in ipairs(rows) do
                    if cmd.op == "setflag" then
                        local flag = scriptCommandArg(cmd, "flag")
                        local badge = flag ~= nil
                            and (Gen2FieldMoves.BADGE_FLAG or {})[flag]
                            or nil
                        if type(badge) == "table"
                            and badge.store == "badges"
                            and badge.name then
                            badgeNames[badge.name] = true
                            discovered[badge.name] = true
                        end
                    end
                end

                if next(badgeNames) ~= nil then
                    local setEvents = {}
                    local completed = false
                    for _, cmd in ipairs(rows) do
                        if cmd.op == "setevent" then
                            local event = scriptCommandArg(cmd, "event")
                            if event ~= nil then
                                setEvents[#setEvents + 1] = event
                                if events and events:get(event) then
                                    completed = true
                                end
                            end
                        end
                    end

                    if completed then
                        for badgeName in pairs(badgeNames) do
                            earned[badgeName] = true
                            evidence[badgeName] = evidence[badgeName] or {}
                            evidence[badgeName][#evidence[badgeName] + 1] = {
                                script = scriptKey,
                                events = setEvents,
                            }
                        end
                    end
                end
            end
        end

        local discoveredCount = 0
        for _ in pairs(discovered) do discoveredCount = discoveredCount + 1 end
        return earned, evidence, discoveredCount
    end

    local function repairLeakedJohtoBadges(game, meta)
        if not (meta and meta.needsJohtoBadgeLeakRepair) then return false end
        local save = game and game.save
        if not (save and save.player) then return false end

        local before = johtoBadgeCount(save)
        local earned, evidence, discoveredCount =
            inferJohtoBadgesFromVictoryEvents(game, save)

        -- Only mutate when the extracted script cache exposed all eight badge
        -- award paths. If a future engine changes that cache shape, fail safe
        -- and leave the player's badge state untouched.
        if discoveredCount < 8 then
            meta.diagnostics = meta.diagnostics or {}
            meta.diagnostics.johtoBadgeLeakRepair = {
                ok = false,
                reason = "incomplete_badge_script_discovery",
                discovered = discoveredCount,
                before = before,
                at = os.time(),
            }
            return false
        end

        local rebuilt = {}
        for _, name in ipairs(Gen2FieldMoves.JOHTO_BADGES or {}) do
            if earned[name] == true then rebuilt[name] = true end
        end
        save.player.badges = rebuilt

        local after = johtoBadgeCount(save)
        meta.diagnostics = meta.diagnostics or {}
        meta.diagnostics.johtoBadgeLeakRepair = {
            ok = true,
            before = before,
            after = after,
            evidence = evidence,
            at = os.time(),
        }
        meta.needsJohtoBadgeLeakRepair = nil

        if mod.log and mod.log.info then
            mod.log:info(("Project Celebi Johto badge leak repair: %d -> %d")
                :format(before, after))
        end
        return true
    end

    local function rivalObjectRows(maps, mapId)
        local rows = {}
        local def = maps and maps[mapId]
        for _, obj in ipairs((def and def.objects) or {}) do
            if obj.sprite == "SPRITE_RIVAL" then
                rows[#rows + 1] = obj
            end
        end
        return rows
    end

    local function setRivalObjectsHidden(world, maps, mapId, hidden)
        local changed = 0
        for _, obj in ipairs(rivalObjectRows(maps, mapId)) do
            if obj.eventFlag then
                local before = world.events:get(obj.eventFlag)
                world.events:set(obj.eventFlag, hidden == true)
                if before ~= (hidden == true) then changed = changed + 1 end
            end
        end
        return changed
    end

    -- Pre-visible Silver scenes (Sprout Tower, Burned Tower, Mt. Moon)
    -- assume Silver already owns a live object struct. Merely clearing the
    -- object's event flag (or even re-running the object
    -- mask loader) is weaker than the cartridge's Script_appear path.  Gold's
    -- native World:appearObject does the complete operation atomically:
    --   1. clear this object's event flag,
    --   2. clear this object's individual live mask,
    --   3. discard any stale pooled object struct,
    --   4. rebuild the live people list from the map definition.
    --
    -- Use the CURRENT map definition here.  Object constants are extracted as
    -- obj.index + 1, exactly the mapping World:appearObject/objectEntity use.
    local function activeRivalObject(world, mapId)
        if not (world and world.map and world.map.id == mapId) then return nil end
        local objects = world.map.def and world.map.def.objects or {}
        for listIndex, obj in ipairs(objects) do
            if obj.sprite == "SPRITE_RIVAL" then
                local index = tonumber(obj.index) or listIndex
                return obj, index, index + 1, listIndex
            end
        end
        return nil
    end

    local function forceCurrentRivalVisibleNative(game, mapId)
        local world = game and game.world
        local obj, index, objectId, listIndex = activeRivalObject(world, mapId)
        if not obj then
            return false, {
                ok = false,
                reason = "active_rival_object_not_found",
                map = mapId,
            }
        end

        local flagBefore = obj.eventFlag and world.events:get(obj.eventFlag) or nil
        local maskKey = type(world.objectMaskKey) == "function"
            and world:objectMaskKey(obj, index) or nil
        local maskBefore = nil
        if maskKey and world.objectMasks then
            maskBefore = world.objectMasks[maskKey]
        end
        local entityBefore = type(world.objectEntity) == "function"
            and world:objectEntity(objectId) or nil

        local nativeCalled, nativeError = false, nil
        if type(world.appearObject) == "function" then
            local ok, err = pcall(world.appearObject, world, objectId)
            nativeCalled = ok
            if not ok then nativeError = tostring(err) end
        end

        -- Defensive engine-internals fallback.  This mirrors appearObject's
        -- observable state changes and also makes the repair useful if a build
        -- exposes the map internals but not the helper method itself.
        local entityAfterNative = type(world.objectEntity) == "function"
            and world:objectEntity(objectId) or nil
        if not entityAfterNative then
            if obj.eventFlag and obj.eventFlag ~= 0xFFFF then
                world.events:set(obj.eventFlag, false)
            end
            if type(world.setObjectMask) == "function" then
                world:setObjectMask(obj, index, false)
            elseif maskKey then
                world.objectMasks = world.objectMasks or {}
                world.objectMasks[maskKey] = false
            end
            if world.npcPool then
                world.npcPool[string.format(
                    "%s_obj_%d", tostring(mapId), tonumber(obj.index) or 0)] = nil
            end
            if type(world.rebuildPeople) == "function" then
                world:rebuildPeople({ seamless = true })
            end
        end

        local entityAfter = type(world.objectEntity) == "function"
            and world:objectEntity(objectId) or nil
        local flagAfter = obj.eventFlag and world.events:get(obj.eventFlag) or nil
        local maskAfter = nil
        if maskKey and world.objectMasks then
            maskAfter = world.objectMasks[maskKey]
        end

        local info = {
            ok = entityAfter ~= nil,
            map = mapId,
            objectId = objectId,
            objectIndex = index,
            listIndex = listIndex,
            eventFlag = obj.eventFlag,
            x = obj.x,
            y = obj.y,
            flagBefore = flagBefore,
            flagAfter = flagAfter,
            maskKey = maskKey,
            maskBefore = maskBefore,
            maskAfter = maskAfter,
            entityBefore = entityBefore ~= nil,
            entityAfter = entityAfter ~= nil,
            nativeAppearCalled = nativeCalled,
            nativeAppearError = nativeError,
            at = os.time(),
        }
        return entityAfter ~= nil, info
    end

    local function recordRivalRepair(meta, mapId, reason, changed, sceneBefore, sceneAfter)
        local d = meta.rival.diagnostics
        d.repairs = (tonumber(d.repairs) or 0) + 1
        d.lastRepair = {
            map = mapId,
            reason = reason,
            changedObjects = changed or 0,
            sceneBefore = sceneBefore,
            sceneAfter = sceneAfter,
            at = os.time(),
        }
        if mod.log and mod.log.info then
            mod.log:info((
                "Project Celebi rival repair %s: %s objects=%d scene=%s->%s"
            ):format(
                tostring(mapId), tostring(reason), tonumber(changed) or 0,
                tostring(sceneBefore), tostring(sceneAfter)
            ))
        end
    end

    local function applyRivalRuntimeState(game, meta)
        local world = game and game.world
        local save = game and game.save
        if not (world and world.events and save) then return end

        ensureCampaignSchema(meta)

        local mapId = currentMapId(game)
        local state = meta.rival.state or "LOCKED"
        local maps = (game.data and game.data.gen2Maps) or world.maps or {}

        world.mapScenes = world.mapScenes or {}
        save.mapScenes = save.mapScenes or {}

        local diag = meta.rival.diagnostics
        diag.mapEntries = (tonumber(diag.mapEntries) or 0) + 1
        diag.lastMap = mapId
        diag.lastState = state
        diag.johtoBadges = johtoBadgeCount(save)
        diag.goldHallOfFame = hasGoldHallOfFame(save)
        diag.at = os.time()

        if state == "LOCKED" then
            -- Before Johto, keep the global lock from the import bootstrap.
            -- This prevents late-game Kanto Silver scenes from firing while the
            -- player is still using Gold as a continuation of Gen 1 Kanto.
            for rivalMap, scene in pairs(PRE_JOHTO_RIVAL_NOOP_SCENES) do
                world.mapScenes[rivalMap] = scene
                save.mapScenes[rivalMap] = scene
            end

            if mapId then
                setRivalObjectsHidden(world, maps, mapId, true)
            end

        elseif state == "ARMED_NEW_BARK" then
            -- The only authored pre-battle Project Celebi introduction is the New Bark
            -- peeking Silver. Do NOT poison every future rival event flag here.
            if mapId == "NEW_BARK_TOWN" then
                local changed = setRivalObjectsHidden(
                    world, maps, "NEW_BARK_TOWN", false)

                meta.rival.state = "JOHTO_ACTIVE"
                meta.rival.introduced = true
                meta.rival.firstSeenAt = meta.rival.firstSeenAt or os.time()
                recordRivalRepair(
                    meta, mapId, "new_bark_intro_to_native_continuity",
                    changed, world.mapScenes[mapId], world.mapScenes[mapId])
            end

        else
            -- JOHTO_ACTIVE: stop globally hiding Silver. Gold's own scripts now
            -- own his chronology. We only repair the event/scene values that
            -- older Project Celebi builds intentionally poisoned.
            meta.rival.state = "JOHTO_ACTIVE"

            -- We explicitly skip Gold's rookie Cherrygrove battle. The Legacy
            -- trainer already arrived with a veteran team.
            world.mapScenes.CHERRYGROVE_CITY = 0
            save.mapScenes.CHERRYGROVE_CITY = 0

            -- Once the New Bark sighting is over, retire that scenery object.
            if mapId ~= "NEW_BARK_TOWN" then
                setRivalObjectsHidden(world, maps, "NEW_BARK_TOWN", true)
            end

            -- Sprout Tower 3F is the FIRST native Johto scene poisoned by
            -- the old global lock. Its coord-event does NOT call `appear`;
            -- it immediately applies movement to SPROUTTOWER3F_RIVAL. Restore
            -- scene 0 for schema-9-and-earlier saves that already watched the
            -- dialogue run against an invisible object, then invoke Gold's
            -- native live-object appear path before the coord-event can fire.
            local sproutScene = world.mapScenes.SPROUT_TOWER_3F
            if sproutScene == nil then
                sproutScene = save.mapScenes.SPROUT_TOWER_3F
            end
            if sproutScene == nil then sproutScene = 0 end

            if meta.rival.needsSproutTowerSceneReplay then
                local sceneBefore = sproutScene
                if tonumber(sproutScene) ~= 0 then
                    setMapSceneBoth(game, "SPROUT_TOWER_3F", 0)
                    sproutScene = 0
                    recordRivalRepair(
                        meta, mapId or "UNKNOWN",
                        "rearm_sprout_tower_rival_scene",
                        0, sceneBefore, 0)
                end
                meta.rival.needsSproutTowerSceneReplay = nil
            end

            if tonumber(sproutScene) == 0 then
                local changed = setRivalObjectsHidden(
                    world, maps, "SPROUT_TOWER_3F", false)
                local liveVisible, liveInfo = false, nil
                if mapId == "SPROUT_TOWER_3F" then
                    liveVisible, liveInfo = forceCurrentRivalVisibleNative(
                        game, "SPROUT_TOWER_3F")
                    meta.rival.diagnostics.sproutTowerNativeRepair = liveInfo
                end

                if changed > 0 or liveInfo
                    or meta.rival.needsSproutTowerNativeRepair then
                    recordRivalRepair(
                        meta, mapId or "UNKNOWN",
                        liveInfo and (liveVisible
                            and "restore_sprout_tower_silver_native_appear"
                            or "sprout_tower_native_appear_failed")
                            or "prearm_sprout_tower_silver",
                        changed, sproutScene, sproutScene)
                    local d = meta.rival.diagnostics
                    d.sproutTowerEventCleared = true
                    d.sproutTowerLiveObjectVerified =
                        liveVisible and true or false
                end
                meta.rival.needsSproutTowerNativeRepair = nil
            end

            -- Burned Tower scene 0 is unusual: Silver is expected to ALREADY
            -- exist when the deferred scene starts.  Pre-arm the persistent
            -- event flag while off-map, but on the active map use Gold's own
            -- Script_appear implementation so the live object struct itself is
            -- guaranteed to exist before turnobject/applymovement address it.
            local burnedScene = world.mapScenes.BURNED_TOWER_1F
            if burnedScene == nil then burnedScene = save.mapScenes.BURNED_TOWER_1F end
            if burnedScene == nil then burnedScene = 0 end
            if tonumber(burnedScene) == 0 then
                local changed = setRivalObjectsHidden(
                    world, maps, "BURNED_TOWER_1F", false)
                local liveVisible, liveInfo = false, nil
                if mapId == "BURNED_TOWER_1F" then
                    liveVisible, liveInfo = forceCurrentRivalVisibleNative(
                        game, "BURNED_TOWER_1F")
                    meta.rival.diagnostics.burnedTowerNativeRepair = liveInfo
                end

                if changed > 0 or liveInfo
                    or meta.rival.needsContinuityRepair
                    or meta.rival.needsBurnedTowerVisualRepair
                    or meta.rival.needsBurnedTowerNativeRepair then
                    recordRivalRepair(
                        meta, mapId or "UNKNOWN",
                        liveInfo and (liveVisible
                            and "restore_burned_tower_silver_native_appear"
                            or "burned_tower_native_appear_failed")
                            or "prearm_burned_tower_silver",
                        changed, burnedScene, burnedScene)
                    local d = meta.rival.diagnostics
                    d.burnedTowerEventCleared = true
                    d.burnedTowerLiveObjectVerified = liveVisible and true or false
                end
                meta.rival.needsBurnedTowerVisualRepair = nil
                meta.rival.needsBurnedTowerNativeRepair = nil
            end

            if mapId == "VICTORY_ROAD" then
                -- v0.1.12-v0.1.25 permanently forced Victory Road to scene 1.
                -- Re-arm its native rival coord-event only after all eight
                -- Johto badges are genuinely owned. The script itself calls
                -- `appear`, so its rival object should stay hidden beforehand.
                if johtoBadgeCount(save) >= 8 then
                    local sceneBefore = world.mapScenes.VICTORY_ROAD
                    if sceneBefore == nil then sceneBefore = save.mapScenes.VICTORY_ROAD end
                    if tonumber(sceneBefore) ~= 0 then
                        setMapSceneBoth(game, "VICTORY_ROAD", 0)
                        recordRivalRepair(
                            meta, mapId, "rearm_victory_road_rival",
                            0, sceneBefore, 0)
                    end
                end
            elseif mapId == "MOUNT_MOON" then
                -- Mt. Moon is the post-League Silver battle. It also expects
                -- Silver to exist before its deferred scene runs, so restore
                -- both scene and object only after Gold has its own HOF entry.
                if hasGoldHallOfFame(save) then
                    local sceneBefore = world.mapScenes.MOUNT_MOON
                    if sceneBefore == nil then sceneBefore = save.mapScenes.MOUNT_MOON end
                    if tonumber(sceneBefore) ~= 0 then
                        setMapSceneBoth(game, "MOUNT_MOON", 0)
                    end
                    local changed = setRivalObjectsHidden(
                        world, maps, "MOUNT_MOON", false)
                    if tonumber(sceneBefore) ~= 0 or changed > 0 then
                        recordRivalRepair(
                            meta, mapId, "rearm_mount_moon_rival",
                            changed, sceneBefore, 0)
                    end
                end
            end

            meta.rival.needsContinuityRepair = nil
        end

        -- Lightweight beta trace: enough to diagnose chronology from a save
        -- without flooding the log on every walking step.
        diag.lastScene = mapId and world.mapScenes[mapId] or nil
        diag.lastRivalObjects = {}
        for _, obj in ipairs(rivalObjectRows(maps, mapId)) do
            diag.lastRivalObjects[#diag.lastRivalObjects + 1] = {
                eventFlag = obj.eventFlag,
                hidden = obj.eventFlag and world.events:get(obj.eventFlag) or nil,
                x = obj.x,
                y = obj.y,
            }
        end

        meta.diagnostics.lastMapEntered = mapId
        meta.diagnostics.lastMapEnteredAt = os.time()
        meta.diagnostics.rivalState = meta.rival.state
        meta.diagnostics.johtoBadges = diag.johtoBadges

        world.peopleDirty = true
    end

    ensureLegacyCanonicalWorldState = function(game)
        if not (game and game.save) then return end
        liveGame = game
        local meta = legacyMetaFromSave(game.save)
        if not meta then return end

        ensureCampaignSchema(meta)

        if meta.campaign and meta.campaign.johtoUnlocked == true then
            -- The Project Celebi trainer already owns Pokemon. Keep the vanilla rookie
            -- west-exit guard disabled permanently after the Johto campaign starts.
            setMapSceneBoth(game, "NEW_BARK_TOWN", 1)

            -- The rookie Cherrygrove rival battle is deliberately absent from
            -- the Project Celebi expansion chronology.
            setMapSceneBoth(game, "CHERRYGROVE_CITY", 0)
        end

        if meta.difficulty
            and meta.difficulty.needsMigrationLock == true
            and meta.difficulty.locked ~= true then
            local rating, topLevels, method =
                calculateLegacyDifficulty(game.save)
            meta.difficulty.locked = true
            meta.difficulty.rating = rating
            meta.difficulty.source = method .. "_migration"
            meta.difficulty.topPartyLevels = topLevels
            meta.difficulty.lockedAt = os.time()
            meta.difficulty.lockedMap = currentMapId(game)
            meta.difficulty.applied = false
            meta.difficulty.needsMigrationLock = nil
        end

        applyKantoGymRuntimeState(game, meta)
        repairLeakedJohtoBadges(game, meta)
        applyRivalRuntimeState(game, meta)
        repairLegacyJohtoTutorial(game, meta)
    end

    mod.events:on("map.entered", function(payload)
        local game = liveGame
        if not game then return end

        local meta = legacyMetaFromSave(game.save)
        if meta then
            ensureCampaignSchema(meta)

            local mapId = liveMapId(game, payload)
            if meta.campaign.johtoUnlocked ~= true
                and meta.kanto
                and meta.kanto.champion == true
                and isUnambiguousJohtoMap(mapId) then

                local pos = liveWorldPosition(game)
                armJohtoIntroState(game, meta, {
                    map = mapId,
                    x = pos and pos.x,
                    y = pos and pos.y,
                    method = "first_unambiguous_johto_map",
                })
            end
        end

        ensureLegacyCanonicalWorldState(game)
    end)

    mod.events:on("world.stepped", function(payload)
        local game = liveGame
        if not game then return end
        local meta = legacyMetaFromSave(game.save)
        if meta then
            repairLegacyJohtoTutorial(game, meta)
        end
    end)

    -- ---------------------------------------------------------------------
    -- Project Celebi Johto Trainer Scaling v2 + Wild Catch-Up v1
    --
    -- Gold raises `trainer.party` after constructing the actual enemy Mon
    -- array. Hook signature:
    --   trainer.party(classId, memberId, party) -> party
    --
    -- The immutable Project Celebi Difficulty Rating was locked at Johto entry.  For
    -- each vanilla trainer level L, v2 maps to:
    --
    --   target = rating - 3 + round(L * 0.25) + bossBonus
    --
    -- This intentionally puts early ordinary trainers near the imported team,
    -- bosses a little above it, and lets vanilla progression keep climbing.
    -- Example for rating 79:
    --   vanilla  4 ordinary -> 77
    --   vanilla  9 Falkner  -> 81
    --   vanilla 16 Bugsy    -> 83
    --   vanilla 20 Whitney  -> 84
    --   vanilla 25 Morty    -> 85
    --   vanilla 40 Clair    -> 89
    --   vanilla 50 League   -> 93
    --
    -- Never downscale: max(vanillaLevel, target).
    --
    -- Species get at most ONE ordinary level-evolution promotion. This keeps
    -- the authored roster's shape while avoiding absurd high-level base forms.
    --
    -- Wild encounters use a separate catch-up curve.  Their target band is
    -- rating-15 through rating-10.  The vanilla level chooses a position in
    -- that six-level band, retaining a small amount of area progression while
    -- making newly caught Johto Pokemon immediately trainable.
    local JOHTO_GYM_CLASSES = {
        FALKNER = true,
        BUGSY = true,
        WHITNEY = true,
        MORTY = true,
        CHUCK = true,
        JASMINE = true,
        PRYCE = true,
        CLAIR = true,
    }

    local JOHTO_LEAGUE_CLASSES = {
        WILL = true,
        KOGA = true,
        BRUNO = true,
        KAREN = true,
        CHAMPION = true,
    }

    local KANTO_BATTLE_PREFIXES = {
        "PALLET",
        "VIRIDIAN",
        "PEWTER",
        "CERULEAN",
        "VERMILION",
        "LAVENDER",
        "CELADON",
        "FUCHSIA",
        "SAFFRON",
        "CINNABAR",
        "MOUNT_MOON",
        "ROCK_TUNNEL",
        "POWER_PLANT",
        "DIGLETTS_CAVE",
        "SILVER_CAVE",
    }

    local function classNameFromHook(game, classId)
        if type(classId) == "string" then
            return classId
        end

        local constants = goldConstants(game)
        local order = constants and constants.trainerClassOrder
        if type(classId) == "number" and type(order) == "table" then
            return order[classId + 1] or tostring(classId)
        end

        return tostring(classId or "UNKNOWN")
    end

    local function isRivalClass(className)
        className = tostring(className or "")
        return className:match("^RIVAL") ~= nil
    end

    local function legacyTrainerBossBonus(className)
        if JOHTO_LEAGUE_CLASSES[className] then
            return 4
        end
        if JOHTO_GYM_CLASSES[className] then
            return 3
        end
        if isRivalClass(className) then
            return 2
        end
        return 0
    end

    local function isKantoMapName(mapId)
        mapId = tostring(mapId or "")

        local route = tonumber(mapId:match("^ROUTE_(%d+)"))
        if route then
            return route <= 28
        end

        for _, prefix in ipairs(KANTO_BATTLE_PREFIXES) do
            if mapId:sub(1, #prefix) == prefix then
                return true
            end
        end

        return false
    end

    local function isLegacyJohtoCampaignMap(meta, mapId)
        if not (meta and meta.campaign
            and meta.campaign.johtoUnlocked == true) then
            return false
        end
        if not mapId then return false end

        -- Indigo Plateau / Victory Road / Routes 26-27 become the end of the
        -- Johto campaign once Johto has actually begun. Before the border
        -- crossing, all balance hooks are inactive entirely.
        if tostring(mapId):sub(1, #"INDIGO_PLATEAU") == "INDIGO_PLATEAU"
            or tostring(mapId):sub(1, #"VICTORY_ROAD") == "VICTORY_ROAD" then
            return true
        end

        local route = tonumber(tostring(mapId):match("^ROUTE_(%d+)"))
        if route then
            if route >= 29 and route <= 46 then return true end
            if route == 26 then return true end
            if route == 27 then return true end
            return false
        end

        -- Explicitly-known Kanto places remain untouched. Everything else
        -- encountered after the Johto campaign has started is treated as
        -- Johto campaign space; this naturally covers VIOLET_GYM,
        -- SLOWPOKE_WELL, UNION_CAVE, RADIO_TOWER, ICE_PATH, DRAGONS_DEN, etc.
        if isKantoMapName(mapId) then return false end
        return true
    end

    local function isLegacyJohtoTrainerBattle(game, meta)
        if not game then return false end
        local pos = liveWorldPosition(game)
        local mapId = pos and pos.map or currentMapId(game)
        return isLegacyJohtoCampaignMap(meta, mapId)
    end

    local function legacyTargetTrainerLevel(rating, vanillaLevel, className)
        rating = tonumber(rating) or vanillaLevel or 1
        vanillaLevel = tonumber(vanillaLevel) or 1

        local base = rating - 3
        local progression = math.floor(vanillaLevel * 0.25 + 0.5)
        local target = base + progression
            + legacyTrainerBossBonus(className)

        target = math.max(vanillaLevel, target)
        target = math.max(1, math.min(Mon.MAX_LEVEL or 100, target))
        return target
    end

    local function oneLevelEvolution(data, species, targetLevel)
        local def = data
            and data.pokemon
            and data.pokemon[species]
        if not def then return species, false end

        local row = Mon.evolutionAtLevel(def, targetLevel)
        if row and row.into
            and data.pokemon[row.into] then
            return row.into, true
        end

        return species, false
    end

    local function copyMoves(moves)
        local out = {}
        for _, move in ipairs(moves or {}) do
            out[#out + 1] = {
                id = move.id,
                pp = move.pp,
                maxPp = move.maxPp,
            }
        end
        return out
    end

    local function scaledTrainerMon(game, mon, targetLevel)
        if type(mon) ~= "table" or not mon.species then return mon, false end
        local data = game and game.data
        if not (data and data.pokemon and data.pokemon[mon.species]) then
            return mon, false
        end

        local species, evolved =
            oneLevelEvolution(data, mon.species, targetLevel)

        local rebuilt = Mon.new(data, species, targetLevel, {
            -- Preserve the actual trainer roll / authored characteristics.
            dvs = mon.dvs,
            statExp = mon.statExp,
            item = mon.item,
            happiness = mon.happiness,
            -- Preserve authored trainer moves, including signature Gym TMs.
            moves = copyMoves(mon.moves),
            shiny = mon.shiny,
        })

        if not rebuilt then return mon, false end

        -- Any incidental trainer-facing fields the builder does not own.
        rebuilt.gender = mon.gender or rebuilt.gender
        rebuilt.unownLetter = mon.unownLetter or rebuilt.unownLetter
        rebuilt.name = rebuilt.name or mon.name
        rebuilt.nickname = mon.nickname

        return rebuilt, evolved
    end

    local function ensureLegacyDifficultyRating(game, meta, fallbackKind)
        local difficulty = meta.difficulty or {}
        local rating = tonumber(difficulty.rating)
        if difficulty.locked == true and rating then
            return difficulty, rating
        end

        -- Defensive migration for a Project Celebi save that somehow reached a scaled
        -- encounter without passing through the v0.1.21 border lock.
        local computed, topLevels, method =
            calculateLegacyDifficulty(game.save)
        difficulty.locked = true
        difficulty.rating = computed
        difficulty.source = method .. "_" .. tostring(fallbackKind or "balance")
            .. "_fallback"
        difficulty.topPartyLevels = topLevels
        difficulty.lockedAt = os.time()
        difficulty.lockedMap = currentMapId(game)
        difficulty.applied = false
        meta.difficulty = difficulty
        return difficulty, computed
    end

    mod.hooks:wrap("trainer.party", function(nextFn, classId, memberId, party)
        local vanilla = nextFn(classId, memberId, party)
        local game = liveGame
        if not game then return vanilla end

        local meta = isLegacySave(game.save)
        if not meta then return vanilla end
        ensureCampaignSchema(meta)

        if not isLegacyJohtoTrainerBattle(game, meta) then
            return vanilla
        end

        local difficulty, rating =
            ensureLegacyDifficultyRating(game, meta, "trainer_hook")

        local className = classNameFromHook(game, classId)
        local scaled = {}
        local beforeLevels, afterLevels = {}, {}
        local beforeSpecies, afterSpecies = {}, {}
        local evolvedCount = 0

        for _, mon in ipairs(vanilla or {}) do
            local vanillaLevel = tonumber(mon and mon.level) or 1
            local target =
                legacyTargetTrainerLevel(rating, vanillaLevel, className)
            local rebuilt, evolved =
                scaledTrainerMon(game, mon, target)

            scaled[#scaled + 1] = rebuilt
            beforeLevels[#beforeLevels + 1] = vanillaLevel
            afterLevels[#afterLevels + 1] =
                tonumber(rebuilt and rebuilt.level) or vanillaLevel
            beforeSpecies[#beforeSpecies + 1] =
                tostring(mon and mon.species or "?")
            afterSpecies[#afterSpecies + 1] =
                tostring(rebuilt and rebuilt.species or "?")
            if evolved then evolvedCount = evolvedCount + 1 end
        end

        difficulty.applied = true
        difficulty.trainerBattlesScaled =
            (tonumber(difficulty.trainerBattlesScaled) or 0) + 1
        difficulty.lastTrainerScale = {
            map = currentMapId(game),
            class = className,
            classId = classId,
            memberId = memberId,
            rating = rating,
            beforeLevels = beforeLevels,
            afterLevels = afterLevels,
            beforeSpecies = beforeSpecies,
            afterSpecies = afterSpecies,
            evolved = evolvedCount,
            at = os.time(),
        }

        if isRivalClass(className) then
            meta.rival = meta.rival or {}
            meta.rival.lastBattleScale = {
                map = currentMapId(game),
                class = className,
                memberId = memberId,
                rating = rating,
                beforeLevels = beforeLevels,
                afterLevels = afterLevels,
                beforeSpecies = beforeSpecies,
                afterSpecies = afterSpecies,
                at = os.time(),
            }
        end

        if mod.log and mod.log.info then
            mod.log:info((
                "Project Celebi trainer scale %s[%s] rating=%d levels %s -> %s species %s -> %s"
            ):format(
                tostring(className),
                tostring(memberId),
                rating,
                table.concat(beforeLevels, ","),
                table.concat(afterLevels, ","),
                table.concat(beforeSpecies, ","),
                table.concat(afterSpecies, ",")
            ))
        end

        return scaled
    end)

    -- ---------------------------------------------------------------------
    -- Project Celebi Johto Wild Catch-Up v1
    --
    -- Gold v0.1.78 exposes ordinary grass/water/script/Sweet Scent rolls via
    -- `encounter.species`, and rod encounters via `encounter.fishing`.
    -- Species and encounter tables remain vanilla; we only lift the resulting
    -- level into the catch-up band.  Contest encounters are intentionally
    -- excluded. Roaming beasts and authored `loadwildmon` statics bypass these
    -- hooks in Gold and therefore remain vanilla as desired.

    local function legacyTargetWildLevel(rating, vanillaLevel)
        rating = tonumber(rating) or vanillaLevel or 1
        vanillaLevel = tonumber(vanillaLevel) or 1

        local lower = math.max(1, rating - 15)
        local upper = math.max(lower, rating - 10)
        local span = math.max(0, upper - lower)

        -- Retain a little of the map's authored progression inside the narrow
        -- catch-up band: roughly one extra target level per seven vanilla
        -- levels, capped at the top of the band.
        local progression = math.floor(math.max(0, vanillaLevel - 1) / 7)
        progression = math.max(0, math.min(span, progression))
        local target = lower + progression

        -- Never make a naturally stronger encounter weaker.
        target = math.max(vanillaLevel, target)
        target = math.max(1, math.min(Mon.MAX_LEVEL or 100, target))
        return target, lower, upper
    end

    local function scaleLegacyWildRoll(game, meta, roll, mapId, kind)
        if type(roll) ~= "table" or not roll.species then return roll end
        if kind == "contest" then return roll end
        if not isLegacyJohtoCampaignMap(meta, mapId) then return roll end

        local difficulty, rating =
            ensureLegacyDifficultyRating(game, meta, "wild_hook")
        local vanillaLevel = tonumber(roll.level) or 1
        local target, lower, upper =
            legacyTargetWildLevel(rating, vanillaLevel)

        local scaled = {}
        for k, v in pairs(roll) do scaled[k] = v end
        scaled.level = target

        difficulty.applied = true
        difficulty.wildEncountersScaled =
            (tonumber(difficulty.wildEncountersScaled) or 0) + 1
        difficulty.lastWildScale = {
            map = mapId,
            kind = kind,
            rating = rating,
            species = tostring(roll.species),
            beforeLevel = vanillaLevel,
            afterLevel = target,
            bandLow = lower,
            bandHigh = upper,
            at = os.time(),
        }

        if mod.log and mod.log.info then
            mod.log:info((
                "Project Celebi wild scale %s %s rating=%d level %d -> %d band=%d-%d"
            ):format(
                tostring(mapId or "?"),
                tostring(roll.species),
                rating,
                vanillaLevel,
                target,
                lower,
                upper
            ))
        end

        return scaled
    end

    mod.hooks:wrap("encounter.species", function(nextFn, encounter, ctx)
        local vanilla = nextFn(encounter, ctx)
        local game = liveGame
        if not game then return vanilla end

        local meta = isLegacySave(game.save)
        if not meta then return vanilla end
        ensureCampaignSchema(meta)

        local kind = ctx and ctx.kind or "wild"
        if kind ~= "wild" and kind ~= "script"
            and kind ~= "sweet_scent" then
            return vanilla
        end

        local mapId = ctx and ctx.mapId or currentMapId(game)
        return scaleLegacyWildRoll(game, meta, vanilla, mapId, kind)
    end)

    mod.hooks:wrap("encounter.fishing", function(nextFn, rod, mapId, candidates, ctx)
        local vanilla = nextFn(rod, mapId, candidates, ctx)
        local game = liveGame
        if not game then return vanilla end

        local meta = isLegacySave(game.save)
        if not meta then return vanilla end
        ensureCampaignSchema(meta)

        return scaleLegacyWildRoll(
            game, meta, vanilla, mapId or currentMapId(game), "fishing")
    end)

    -- ---------------------------------------------------------------------
    -- Project Celebi Gen 1 HM authorization
    --
    -- Gold exposes `fieldmove.eligibility` through the same mod hook chain as
    -- Gen 1. The vanilla answer remains authoritative whenever it succeeds.
    -- If vanilla refuses because Gold sees no Johto badge, a Project Celebi save may
    -- supply the corresponding *historical Gen 1* badge instead.
    --
    -- RBY field-move badge mapping:
    --   CUT      -> Cascade Badge
    --   FLY      -> Thunder Badge
    --   SURF     -> Soul Badge
    --   STRENGTH -> Rainbow Badge
    --   FLASH    -> Boulder Badge
    --
    -- Deliberately NOT authorized here:
    --   WATERFALL, WHIRLPOOL, ROCK_SMASH, HEADBUTT, etc.
    -- Those are Gen 2-native mechanics and must follow Gold progression.
    local LEGACY_HM_BADGE = {
        CUT = "CASCADEBADGE",
        FLY = "THUNDERBADGE",
        SURF = "SOULBADGE",
        STRENGTH = "RAINBOWBADGE",
        FLASH = "BOULDERBADGE",
    }

    local function monKnowsMove(mon, moveId)
        if type(mon) ~= "table" then return false end
        for _, move in ipairs(mon.moves or {}) do
            if move and move.id == moveId then
                return true
            end
        end
        return false
    end

    local function legacyFieldMoveUser(save, moveId, ctx)
        if type(save) ~= "table" then return nil end

        local meta = save.modData and save.modData.legacy_bridge
        if not (meta and meta.imported) then return nil end

        local requiredBadge = LEGACY_HM_BADGE[moveId]
        if not requiredBadge then return nil end

        local kanto = meta.kanto or {}
        local historicalBadges = kanto.badges or {}
        if historicalBadges[requiredBadge] ~= true then
            return nil
        end

        -- Gold's party menu already has a selected mon in some field-move
        -- contexts. Prefer it when supplied; otherwise reproduce the cart's
        -- first-party-member-that-knows-the-move rule.
        local selected = ctx and (ctx.mon or ctx.selectedMon)
        if selected and monKnowsMove(selected, moveId) then
            return selected
        end

        for _, mon in ipairs(save.party or {}) do
            if monKnowsMove(mon, moveId) then
                return mon
            end
        end

        return nil
    end

    mod.hooks:wrap("fieldmove.eligibility", function(nextFn, moveId, ctx)
        -- Never weaken ordinary Gold rules when Gold already permits the move.
        local vanilla = nextFn(moveId, ctx)
        if vanilla then return vanilla end

        local save = (ctx and ctx.save)
            or (liveGame and liveGame.save)
        local mon = legacyFieldMoveUser(save, moveId, ctx)
        if not mon then return nil end

        local meta = save.modData.legacy_bridge
        meta.kanto = meta.kanto or {}
        meta.kanto.hmAuthorization = meta.kanto.hmAuthorization or {}

        local badge = LEGACY_HM_BADGE[moveId]
        meta.kanto.hmAuthorization[moveId] = {
            badge = badge,
            source = "gen1_badge",
            authorizedAt = os.time(),
        }

        if mod.log and mod.log.info then
            mod.log:info(("Project Celebi HM authorization: %s via %s")
                :format(tostring(moveId), tostring(badge)))
        end

        return mon
    end)


    -- ---------------------------------------------------------------------
    -- Gold party-menu badge bridge
    --
    -- Important engine detail in v0.1.78:
    --
    --   Overworld party-move lookup
    --       -> FieldMoves.partyMoveUser
    --       -> fieldmove.eligibility hook
    --
    --   Pokemon menu -> FLY/CUT/SURF/etc.
    --       -> World:useFieldMove
    --       -> FieldMoves.fromMenu
    --       -> CheckBadge directly
    --
    -- Therefore the supported hook above cannot affect the exact "A new BADGE
    -- is required." path the player sees after choosing FLY from a mon's menu.
    --
    -- For ONLY the five Gen 1 HM moves, and ONLY when the imported historical
    -- Gen 1 badge authorizes that move, temporarily present Gold's own badge
    -- checker with a complete Johto-badge table for the duration of the pure
    -- fromMenu() decision. Restore the table immediately afterward.
    --
    -- Nothing persistent is granted:
    --   * Trainer Card still has zero Johto badges.
    --   * VAR_BADGES is unchanged outside this single function call.
    --   * map scripts / gyms never see these temporary bits.
    --   * Gen 2-only field moves never enter this shim.
    local originalFromMenu = Gen2FieldMoves.fromMenu

    local function withTemporaryGoldBadges(save, fn)
        if type(save) ~= "table" then return fn() end
        save.player = save.player or {}
        save.player.badges = save.player.badges or {}

        local badges = save.player.badges
        local restore = {}

        -- FieldMoves.BADGE_FLAG is Gold's authoritative engine-flag -> badge
        -- descriptor map. Using it means this bridge does not hard-code the
        -- internal save-key spelling for Zephyr/Hive/Plain/Fog/Storm/etc.
        --
        -- IMPORTANT: a plain `restore[name] = badges[name]` cannot remember an
        -- absent Lua key because assigning nil removes the restore entry. Keep
        -- an explicit presence bit so temporary badge grants never persist.
        for _, badge in pairs(Gen2FieldMoves.BADGE_FLAG or {}) do
            if type(badge) == "table"
                and badge.store == "badges"
                and badge.name then
                local previous = badges[badge.name]
                restore[badge.name] = {
                    present = previous ~= nil,
                    value = previous,
                }
                badges[badge.name] = true
            end
        end

        local ok, a, b, c = pcall(fn)

        for name, previous in pairs(restore) do
            if previous.present then
                badges[name] = previous.value
            else
                badges[name] = nil
            end
        end

        if not ok then error(a) end
        return a, b, c
    end

    if not Gen2FieldMoves._legacyBridgeFromMenuWrapped then
        Gen2FieldMoves._legacyBridgeFromMenuWrapped = true

        Gen2FieldMoves.fromMenu = function(moveId, ctx)
            local save = ctx and ctx.save
            local meta = save
                and save.modData
                and save.modData.legacy_bridge
            local requiredLegacyBadge = LEGACY_HM_BADGE[moveId]

            if not (meta and meta.imported and requiredLegacyBadge) then
                return originalFromMenu(moveId, ctx)
            end

            local historical = meta.kanto
                and meta.kanto.badges
            if not (historical and historical[requiredLegacyBadge] == true) then
                return originalFromMenu(moveId, ctx)
            end

            -- Let Gold make EVERY other decision itself: map legality, tile
            -- legality, mon selection, already-surfing state, darkness, etc.
            -- We change only the badge answer during that one decision.
            local result = withTemporaryGoldBadges(save, function()
                return originalFromMenu(moveId, ctx)
            end)

            if result and result.ok then
                meta.kanto.hmAuthorization = meta.kanto.hmAuthorization or {}
                meta.kanto.hmAuthorization[moveId] = {
                    badge = requiredLegacyBadge,
                    source = "gen1_badge_menu_bridge",
                    authorizedAt = os.time(),
                }

                if mod.log and mod.log.info then
                    mod.log:info(("Project Celebi menu HM authorization: %s via %s")
                        :format(tostring(moveId), tostring(requiredLegacyBadge)))
                end

                -- FLY intentionally falls through here.  Gold now receives
                -- the normal { ok=true, action="fly" } result and opens its
                -- native Gen2 Pokegear FlyMap after the party menu closes.
            end

            return result
        end
    end

    -- ---------------------------------------------------------------------
    -- Project Celebi Kanto -> Johto border
    --
    -- Gold's Route 27 contains two doors into TOHJO_FALLS. The original cart
    -- expects WATERFALL inside the cave. A genuine Gen 1 trainer can never
    -- arrive with that field move because it did not exist in RBY.
    --
    -- For a proven Gen 1 Champion, entering TOHJO_FALLS before Johto has
    -- started therefore behaves as a League-recognized through-passage:
    --
    --   Kanto-side Route 27 door
    --       -> TOHJO_FALLS loads normally
    --       -> next world step
    --       -> emerge outside the WESTERN Route 27 door
    --
    -- We deliberately let the cave load for one step rather than changing the
    -- source warp. That keeps the vanilla map transition/audio semantics and
    -- avoids depending on the exact private shape of warp.destination.
    local pendingTohjoBypass = false
    local performingLegacyWarp = false

    local function legacyMeta(game)
        local save = game and game.save
        local data = save and save.modData
        local meta = data and data.legacy_bridge
        if not (meta and meta.imported) then return nil end
        return meta
    end

    local function liveMapId(game, payload)
        if payload then
            if payload.mapId then return payload.mapId end
            if payload.map and payload.map.id then return payload.map.id end
            if payload.id then return payload.id end
        end
        return game
            and game.save
            and game.save.position
            and game.save.position.map
            or nil
    end

    local function tohjoRoute27Warps(game)
        local maps = game and game.data and game.data.gen2Maps
        local route = maps and maps.ROUTE_27
        if not route then return nil end

        local result = {}
        for i, warp in ipairs(route.warps or {}) do
            if warp.destMap == "TOHJO_FALLS" then
                result[#result + 1] = {
                    index = i,
                    x = warp.x,
                    y = warp.y,
                    warp = warp,
                }
            end
        end

        table.sort(result, function(a, b)
            if a.x == b.x then return a.y < b.y end
            return a.x < b.x
        end)

        return result
    end

    local function safeOutsideDoor(game, door)
        if not door then return nil end

        -- Try the four cells immediately around the cave door first so the
        -- transition looks like a normal exit. nearestSafeCell() rejects the
        -- warp tile itself, NPCs and blocked terrain.
        local candidates = {
            { door.x,     door.y + 1 },
            { door.x - 1, door.y     },
            { door.x + 1, door.y     },
            { door.x,     door.y - 1 },
        }

        for _, p in ipairs(candidates) do
            if walkableAndClear(game, "ROUTE_27", p[1], p[2], false) then
                return p[1], p[2]
            end
        end

        local x, y = nearestSafeCell(game, "ROUTE_27", door.x, door.y)
        return x, y
    end

    local function performTohjoBypass(game)
        if performingLegacyWarp then return end

        local meta = legacyMeta(game)
        local kanto = meta and meta.kanto
        local johto = meta and meta.johto
        if not (kanto and kanto.champion and johto and not johto.started) then
            pendingTohjoBypass = false
            return
        end

        local doors = tohjoRoute27Warps(game)
        -- Route 27's western Tohjo door is the one with the smaller X.
        local westDoor = doors and doors[1]
        if not westDoor then
            pendingTohjoBypass = false
            if mod.log and mod.log.warn then
                mod.log:warn("Project Celebi Tohjo bypass could not find Route 27's "
                    .. "western TOHJO_FALLS entrance")
            end
            return
        end

        local x, y = safeOutsideDoor(game, westDoor)
        if x == nil then
            pendingTohjoBypass = false
            if mod.log and mod.log.warn then
                mod.log:warn("Project Celebi Tohjo bypass found no safe cell outside "
                    .. "Route 27's western entrance")
            end
            return
        end

        performingLegacyWarp = true
        pendingTohjoBypass = false

        johto.borderUnlocked = true
        johto.borderReason = "gen1_champion"
        johto.tohjoBypassUsed = (tonumber(johto.tohjoBypassUsed) or 0) + 1
        johto.lastTohjoBypass = {
            targetMap = "ROUTE_27",
            x = x,
            y = y,
        }

        -- continueGame() is the same proven transition Project Celebi already
        -- uses after import. We change only the live Project Celebi save's position,
        -- then let Gold rebuild its world normally at the safe west-side cell.
        local liveSave = snapshotBeforeLegacyRelocation(game)
        if not liveSave then
            performingLegacyWarp = false
            return
        end

        liveSave.position = {
            map = "ROUTE_27",
            x = x,
            y = y,
            facing = "left",
        }

        if mod.log and mod.log.info then
            mod.log:info(("Project Celebi Champion passed Tohjo Falls -> ROUTE_27 (%d,%d)")
                :format(x, y))
        end

        game:continueGame(liveSave)
        performingLegacyWarp = false
    end

    -- World:setMap emits map.entered after the Gold map exists. The mod API
    -- explicitly guarantees map.entered on Gold, so this works on an existing
    -- v0.1.1 Project Celebi save as soon as the player reaches Tohjo Falls.
    mod.events:on("map.entered", function(payload)
        local game = liveGame
        local meta = legacyMeta(game)
        if not meta then return end

        local mapId = liveMapId(game, payload)
        local kanto = meta.kanto or {}
        local johto = meta.johto or {}

        -- Victory Road Gate (Viridian group map 13) normally keeps scene 0
        -- active until VAR_BADGES reports all eight JOHTO badges. Its coord
        -- event at (10,11) runs the officer check and pushes the player back
        -- down one cell when that test fails.
        --
        -- A Project Celebi Gen 1 Champion has already "proven themselves" to this same
        -- League, but must NOT be awarded fake Johto badges. Scene 1 is the
        -- map's vanilla NOOP/post-check scene, so authorizing that scene skips
        -- only this receptionist check and leaves every native badge/event flag
        -- untouched.
        if mapId == "VICTORY_ROAD_GATE"
            and kanto.champion == true then

            if game.world and game.world.mapScenes then
                game.world.mapScenes.VICTORY_ROAD_GATE = 1
            end

            game.save.mapScenes = game.save.mapScenes or {}
            game.save.mapScenes.VICTORY_ROAD_GATE = 1

            kanto.receptionGateAuthorized = true
            kanto.receptionGateAuthorization = "gen1_champion"

            -- Gold's east/Route 22 Black Belt is a DIFFERENT gatekeeper from
            -- the west/Mt. Silver Black Belt. Retail Gold hides the east guard
            -- only after EVENT_FOUGHT_SNORLAX, but setting that global event
            -- here would also erase Gold's actual Vermilion Snorlax encounter.
            --
            -- Project Celebi therefore masks only this one live map object: the
            -- SPRITE_BLACK_BELT at (12,5). The opposite guard at (7,5), whose
            -- visibility is governed by EVENT_OPENED_MT_SILVER, is untouched
            -- and continues to enforce Gold's native Mt. Silver progression.
            local world = game.world
            local def = world and world.map and world.map.def
            local removedRoute22Guard = false
            local guardIndex, guardEventFlag

            if world and def and def.objects
                and world.setObjectMask and world.rebuildPeople then
                for index, obj in ipairs(def.objects) do
                    if obj.sprite == "SPRITE_BLACK_BELT"
                        and tonumber(obj.x) == 12
                        and tonumber(obj.y) == 5 then
                        world:setObjectMask(obj, index, true)
                        guardIndex = index
                        guardEventFlag = obj.eventFlag
                        removedRoute22Guard = true
                        break
                    end
                end

                if removedRoute22Guard then
                    world:rebuildPeople({ seamless = true })
                end
            end

            kanto.route22GateGuardRemoved = removedRoute22Guard
            kanto.route22GateGuardRemoval = removedRoute22Guard
                and "legacy_object_mask" or "object_not_found"

            meta.diagnostics = meta.diagnostics or {}
            meta.diagnostics.victoryRoadGate = {
                authorized = true,
                route22GuardRemoved = removedRoute22Guard,
                route22GuardIndex = guardIndex,
                route22GuardEventFlag = guardEventFlag,
                mtSilverGuardPreserved = true,
                at = os.time(),
            }

            if mod.log and mod.log.info then
                mod.log:info((
                    "Project Celebi Champion VICTORY_ROAD_GATE: badge check bypassed; "
                    .. "Route22 guard removed=%s index=%s event=%s; "
                    .. "MtSilver guard preserved"
                ):format(
                    tostring(removedRoute22Guard),
                    tostring(guardIndex),
                    tostring(guardEventFlag)
                ))
            end
        end

        if mapId == "TOHJO_FALLS"
            and kanto.champion == true
            and johto.started ~= true then
            pendingTohjoBypass = true
        end
    end)

    -- Do the actual cross on the following logic step, not from inside
    -- World:setMap's map.entered emission. That avoids rebuilding the world
    -- recursively while it is still finishing the first map transition.
    mod.events:on("world.stepped", function(payload)
        local game = liveGame
        local meta = legacyMeta(game)
        if not meta then return end

        if pendingTohjoBypass then
            performTohjoBypass(game)
            return
        end

        local pos = liveWorldPosition(game)
        if not pos then return end

        local johto = meta.johto or {}
        meta.johto = johto

        -- Route 27's vanilla event at x=18/19 is explicitly the first step
        -- INTO KANTO when travelling east. Therefore the first LIVE World cell
        -- at x<=18 while travelling west is the Project Celebi trainer's first step
        -- INTO JOHTO.
        if pos.map == "ROUTE_27"
            and tonumber(pos.x)
            and tonumber(pos.x) <= 18
            and johto.started ~= true then

            local kanto = meta.kanto or {}
            if kanto.champion ~= true then return end

            armJohtoIntroState(game, meta, {
                map = pos.map,
                x = pos.x,
                y = pos.y,
                method = "route27_live_world_border",
                positionSource = pos.source,
            })

            -- Silver changes from globally LOCKED to ARMED_NEW_BARK here.
            applyRivalRuntimeState(game, meta)
        end
    end)

    mod.exports.detectSources = detectSources
    mod.exports.readSource = readActiveSlot
    mod.exports.convertMon = convertMon
    mod.exports.buildLegacySave = buildLegacySave

    logInfo("Project Celebi v0.1.31 loaded (Gen 1 species-ID compatibility hotfix)")
end
