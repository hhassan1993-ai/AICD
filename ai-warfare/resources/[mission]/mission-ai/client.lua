--[[===========================================================================
  mission-ai/client.lua — ENGINE-SPEC v0.1 §5

  Owner-side tasking. Task natives only affect the ped whose ownership this
  client currently holds, so every client runs the same loop and only acts on
  the peds it owns (NetworkHasControlOfEntity). Orders arrive through the ped's
  state bag (`mo`), identity through `mu`. Re-application after an ownership
  migration is automatic: the new owner has no `applied[netId]` entry for the
  current `seq`, so it re-applies. See §1.

  Also hosts the client half of the /coords dumper (§4): it fires
  TriggerServerEvent('mission:coords', label, x, y, z, h) and mission-core
  persists it. Coordinate capture MUST be client-side — there is no server-side
  "where is this player standing" native that returns heading reliably for a
  free-roaming ped, and §3.5 requires real in-game values.
===========================================================================]]

local TAG = '[mission-ai]'

local function log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print(('%s %s'):format(TAG, ok and msg or tostring(fmt)))
end

local function warn(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print(('%s WARN %s'):format(TAG, ok and msg or tostring(fmt)))
end

-- ---------------------------------------------------------------------------
-- Per-client bookkeeping, keyed by network id (stable across migration)
-- ---------------------------------------------------------------------------

local applied   = {} -- [netId] = seq of the order last applied by THIS client
local inited    = {} -- [netId] = true once initPed has run here
local mode      = {} -- [netId] = 'moving' | 'fighting' | 'holding' | 'retreating'
local combatOff = {} -- [netId] = true while combat attribute 5 is suppressed (retreat)
local target    = {} -- [netId] = ped handle currently engaged via TaskCombatPed (amove)
local seen      = {} -- [netId] = true, refreshed each sweep, used to GC the tables above

local groupHash = {} -- ['A'|'B'] = relationship group hash
local groupsReady = false

-- ---------------------------------------------------------------------------
-- Entity guards
-- ---------------------------------------------------------------------------

local function validPed(ped)
    return type(ped) == 'number' and ped ~= 0 and DoesEntityExist(ped)
end

local function pedAlive(ped)
    if not validPed(ped) then return false end
    return not IsPedDeadOrDying(ped, true)
end

-- ---------------------------------------------------------------------------
-- 1. Relationship groups (once)
-- ---------------------------------------------------------------------------

local REL_RESPECT = 1
local REL_HATE    = 5

local function ensureRelationshipGroups()
    if groupsReady then return true end
    if type(Config) ~= 'table' or type(Config.Factions) ~= 'table' then
        warn('Config is not loaded — is mission-shared started before mission-ai?')
        return false
    end

    for key, fac in pairs(Config.Factions) do
        local name = fac.group
        if type(name) ~= 'string' or name == '' then
            warn('faction %s has no relationship group name', tostring(key))
            return false
        end
        -- ADD_RELATIONSHIP_GROUP(name, Hash* out). The produced hash is the
        -- joaat of the name, so GetHashKey(name) is the portable way to read
        -- it back without depending on the Lua out-param binding.
        AddRelationshipGroup(name)
        groupHash[key] = GetHashKey(name)
    end

    local a, b = groupHash.A, groupHash.B
    if not a or not b then
        warn('missing relationship group hash (A=%s B=%s)', tostring(a), tostring(b))
        return false
    end

    local playerGroup = GetHashKey('PLAYER')

    SetRelationshipBetweenGroups(REL_HATE, a, b)
    SetRelationshipBetweenGroups(REL_HATE, b, a)

    -- Commanders / caster in console mode must never be targets.
    SetRelationshipBetweenGroups(REL_RESPECT, a, playerGroup)
    SetRelationshipBetweenGroups(REL_RESPECT, playerGroup, a)
    SetRelationshipBetweenGroups(REL_RESPECT, b, playerGroup)
    SetRelationshipBetweenGroups(REL_RESPECT, playerGroup, b)

    groupsReady = true
    log('relationship groups ready: A=%s B=%s (hate both ways, respect towards PLAYER)', a, b)
    return true
end

-- ---------------------------------------------------------------------------
-- 3. initPed — once per netId on this client
-- ---------------------------------------------------------------------------

local function initPed(ped, netId, faction)
    if not validPed(ped) then return false end

    local hash = groupHash[faction]
    if hash then
        SetPedRelationshipGroupHash(ped, hash)
    else
        warn('initPed: no relationship group for faction %s (netId %s)', tostring(faction), tostring(netId))
    end

    local combat = (type(Config) == 'table' and type(Config.Combat) == 'table') and Config.Combat or {}

    SetPedAccuracy(ped, math.floor(tonumber(combat.accuracy) or 35))
    SetPedSeeingRange(ped, (tonumber(combat.seeRange) or 120.0) + 0.0)
    SetPedHearingRange(ped, (tonumber(combat.hearRange) or 120.0) + 0.0)

    SetPedCombatAbility(ped, 1)   -- VERIFY: 0 poor / 1 average / 2 professional (in-game)
    SetPedCombatRange(ped, 1)     -- VERIFY: 0 near / 1 medium / 2 far (in-game)
    SetPedCombatMovement(ped, 2)  -- VERIFY: 0 stationary / 1 defensive / 2 offensive (in-game)

    SetPedCombatAttributes(ped, 0,  true)  -- VERIFY: BF_CanUseCover (in-game)
    SetPedCombatAttributes(ped, 5,  true)  -- VERIFY: BF_AlwaysFight (in-game)
    SetPedCombatAttributes(ped, 46, true)  -- VERIFY: BF_CanFightArmedPedsWhenNotArmed (in-game)
    SetPedCombatAttributes(ped, 58, true)  -- VERIFY: BF_DisableFleeFromCombat (in-game)

    SetPedFleeAttributes(ped, 0, false)
    SetBlockingOfNonTemporaryEvents(ped, false)
    SetPedDropsWeaponsWhenDead(ped, false)
    SetPedCanRagdoll(ped, true) -- default behaviour, stated explicitly

    -- Ground snap: correct peds spawned at a placeholder Z.
    local c = GetEntityCoords(ped)
    local found, groundZ = GetGroundZFor_3dCoord(c.x, c.y, c.z + 1.0, false)
    if found and type(groundZ) == 'number' and math.abs(groundZ - c.z) > 1.5 then
        SetEntityCoords(ped, c.x, c.y, groundZ, false, false, false, false)
        log('ground snap netId %s: z %.2f -> %.2f', tostring(netId), c.z, groundZ)
    end

    combatOff[netId] = nil
    return true
end

-- ---------------------------------------------------------------------------
-- Hostile scan (amove supervision)
-- ---------------------------------------------------------------------------

--- Per-tick cache of living mission peds by faction: cache[f] = { {ped=, pos=}, ... }.
--- Built once per sweep in the main loop so the hostile scan is O(enemies) per
--- owned ped instead of O(pool) — matters at T2 scales (hundreds of peds).
local hostileCache = { A = {}, B = {} }

local function rebuildHostileCache(pool)
    for f in pairs(hostileCache) do
        local list = hostileCache[f]
        for i = #list, 1, -1 do list[i] = nil end
    end
    for i = 1, #pool do
        local other = pool[i]
        if validPed(other) and pedAlive(other) then
            local okBag, mu = pcall(function() return Entity(other).state.mu end)
            if okBag and type(mu) == 'table' and mu.f and hostileCache[mu.f] then
                local list = hostileCache[mu.f]
                list[#list + 1] = { ped = other, pos = GetEntityCoords(other) }
            end
        end
    end
end

local function closestHostile(ped, myFaction, radius)
    if not validPed(ped) then return nil end
    local origin = GetEntityCoords(ped)
    local best, bestDist = nil, radius
    for f, list in pairs(hostileCache) do
        if f ~= myFaction then
            for i = 1, #list do
                local e = list[i]
                if e.ped ~= ped then
                    local d = #(origin - e.pos)
                    if d < bestDist then
                        best, bestDist = e.ped, d
                    end
                end
            end
        end
    end
    -- The cache is one tick old; re-check the winner before tasking against it.
    if best and not pedAlive(best) then return nil end
    return best
end

-- ---------------------------------------------------------------------------
-- 4. apply(ped, st)
-- ---------------------------------------------------------------------------

local DEFAULT_ENGAGE = 80.0

local function engageRadius()
    return (type(Config) == 'table' and type(Config.Combat) == 'table'
        and tonumber(Config.Combat.engageRadius) or DEFAULT_ENGAGE) + 0.0
end

--- Restore combat attribute 5 if a previous retreat suppressed it.
local function restoreCombat(ped, netId)
    if combatOff[netId] and validPed(ped) then
        SetPedCombatAttributes(ped, 5, true) -- VERIFY: BF_AlwaysFight enum (in-game)
        combatOff[netId] = nil
    end
end

--- Issue a formation-aware goto towards st.x/y/z.
local function taskGotoFormation(ped, st)
    if not validPed(ped) then return false end
    local gx, gy, gz = tonumber(st.x), tonumber(st.y), tonumber(st.z)
    if not gx or not gy or not gz then
        warn('goto order without usable coordinates (t=%s)', tostring(st.t))
        return false
    end

    local c = GetEntityCoords(ped)
    -- Line abreast is perpendicular to the DIRECTION OF TRAVEL, so the heading
    -- comes from the ped -> goal vector, not from the ped's current heading.
    local hdg = Config.HeadingFromVector(gx - c.x, gy - c.y)
    local ox, oy = Config.FormationSlotOffset(st.slot or 0, hdg)

    TaskGoToCoordAnyMeans(ped, gx + ox, gy + oy, gz, 2.0, 0, false, 786603, 0.0)
    return true
end

local function goalDistance(ped, st)
    if not validPed(ped) then return math.huge end
    local gx, gy, gz = tonumber(st.x), tonumber(st.y), tonumber(st.z)
    if not gx or not gy or not gz then return math.huge end
    return #(GetEntityCoords(ped) - vector3(gx, gy, gz))
end

local function apply(ped, netId, st)
    if not validPed(ped) or type(st) ~= 'table' then return false end
    local t = st.t

    if t == 'hold' then
        restoreCombat(ped, netId)
        ClearPedTasks(ped)
        -- ENGINE-SPEC §5.4 hold: engage anything already hated inside the
        -- engagement radius, THEN stand guard.
        TaskCombatHatedTargetsAroundPed(ped, engageRadius(), 0)
        -- Guard with scanForNewEvents=true: the ped engages hated groups that
        -- enter its awareness on its own (relationship HATE + BF_AlwaysFight).
        TaskGuardCurrentPosition(ped, 15.0, 15.0, true)
        mode[netId] = 'holding'
        target[netId] = nil
        return true

    elseif t == 'move' then
        restoreCombat(ped, netId)
        ClearPedTasks(ped)
        if not taskGotoFormation(ped, st) then return false end
        mode[netId] = 'moving'
        return true

    elseif t == 'amove' then
        restoreCombat(ped, netId)
        ClearPedTasks(ped)
        if not taskGotoFormation(ped, st) then return false end
        mode[netId] = 'moving'
        return true

    elseif t == 'retreat' then
        -- Suppress "always fight" for the duration of the withdrawal; the next
        -- order restores it via restoreCombat().
        SetPedCombatAttributes(ped, 5, false) -- VERIFY: BF_AlwaysFight enum (in-game)
        combatOff[netId] = true
        ClearPedTasks(ped)
        if not taskGotoFormation(ped, st) then return false end
        mode[netId] = 'retreating'
        return true
    end

    warn('unknown order type %s for netId %s', tostring(t), tostring(netId))
    return false
end

-- ---------------------------------------------------------------------------
-- supervise() — amove only, per §5.4
-- ---------------------------------------------------------------------------

local function supervise(ped, netId, st, faction)
    if not validPed(ped) or type(st) ~= 'table' then return end
    if st.t ~= 'amove' then return end

    local radius = engageRadius()
    local hostile = closestHostile(ped, faction, radius)

    if hostile then
        if mode[netId] ~= 'fighting' or target[netId] ~= hostile then
            -- TASK_COMBAT_PED(ped, targetPed, p2, combatFlags)
            TaskCombatPed(ped, hostile, 0, 16)
            mode[netId] = 'fighting'
            target[netId] = hostile
        end
        return
    end
    target[netId] = nil

    -- No hostile in radius: resume the advance once actually out of combat.
    if not IsPedInCombat(ped, 0) then
        if goalDistance(ped, st) > 3.0 then
            if mode[netId] ~= 'moving' then
                if taskGotoFormation(ped, st) then
                    mode[netId] = 'moving'
                end
            end
        else
            mode[netId] = 'arrived'
        end
    end
end

-- ---------------------------------------------------------------------------
-- 2. Main loop — every Config.Tick.clientMs
-- ---------------------------------------------------------------------------

Citizen.CreateThread(function()
    local interval = (type(Config) == 'table' and type(Config.Tick) == 'table'
        and tonumber(Config.Tick.clientMs)) or 500
    if interval < 50 then interval = 50 end

    log('owner-side tasking loop starting (%d ms)', interval)

    while true do
        Citizen.Wait(interval)

        if ensureRelationshipGroups() then
            local pool = GetGamePool('CPed')
            if type(pool) == 'table' then
                for k in pairs(seen) do seen[k] = nil end
                rebuildHostileCache(pool)

                for i = 1, #pool do
                    local ped = pool[i]
                    if validPed(ped) then
                        local okBag, mu = pcall(function() return Entity(ped).state.mu end)
                        if okBag and type(mu) == 'table' and mu.f then
                            if NetworkHasControlOfEntity(ped) then
                                local netId = NetworkGetNetworkIdFromEntity(ped)
                                if type(netId) == 'number' and netId ~= 0 then
                                    seen[netId] = true

                                    if pedAlive(ped) then
                                        if not inited[netId] then
                                            if initPed(ped, netId, mu.f) then
                                                inited[netId] = true
                                            end
                                        end

                                        local okOrder, st = pcall(function() return Entity(ped).state.mo end)
                                        if okOrder and type(st) == 'table' then
                                            local seq = tonumber(st.seq)
                                            if seq and applied[netId] ~= seq then
                                                if apply(ped, netId, st) then
                                                    applied[netId] = seq
                                                    log('applied order %s seq=%s to netId %s (%s/%s slot %s)',
                                                        tostring(st.t), tostring(seq), netId,
                                                        tostring(mu.f), tostring(mu.sq), tostring(mu.slot))
                                                end
                                            end
                                            supervise(ped, netId, st, mu.f)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end

                -- GC bookkeeping for peds this client no longer owns / that died.
                for netId in pairs(applied) do
                    if not seen[netId] then
                        applied[netId]   = nil
                        inited[netId]    = nil
                        mode[netId]      = nil
                        combatOff[netId] = nil
                        target[netId]    = nil
                    end
                end
                for netId in pairs(inited) do
                    if not seen[netId] then
                        inited[netId]    = nil
                        mode[netId]      = nil
                        combatOff[netId] = nil
                        target[netId]    = nil
                    end
                end
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- /coords dumper — client half (§4, §3.5)
-- ---------------------------------------------------------------------------

RegisterCommand('coords', function(_, args)
    args = args or {}
    local label = table.concat(args, ' ')
    label = label:gsub('[%c]', ' ')
    if label:gsub('%s', '') == '' then
        label = 'unlabelled'
    end
    label = label:sub(1, 96)

    local ped = PlayerPedId()
    if not validPed(ped) then
        warn('/coords: no valid player ped')
        return
    end

    local c = GetEntityCoords(ped)
    local h = GetEntityHeading(ped)
    if type(h) ~= 'number' then h = 0.0 end

    TriggerServerEvent('mission:coords', label, c.x + 0.0, c.y + 0.0, c.z + 0.0, h + 0.0)
    log('/coords sent: "%s" vector4(%.4f, %.4f, %.4f, %.4f)', label, c.x, c.y, c.z, h)
end, false)

TriggerEvent('chat:addSuggestion', '/coords', 'Dump your current position+heading to mission-core/coords_dump.json', {
    { name = 'label', help = 'name for this point, e.g. spawn_A' },
})

-- ---------------------------------------------------------------------------

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    applied, inited, mode, combatOff, seen, target = {}, {}, {}, {}, {}, {}
end)

log('loaded')
