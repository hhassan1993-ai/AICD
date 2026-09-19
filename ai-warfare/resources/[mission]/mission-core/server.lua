--[[===========================================================================
  mission-core/server.lua — ENGINE-SPEC v0.1 §4
  Server authority: unit registry, squad spawn, order publication via entity
  state bags, ownership audit (risk T1), /coords dumper.

  Orders are NEVER sent by RPC. The server writes them to the ped's state bag
  and the *owning* client (mission-ai) applies them. That is what makes
  OneSync ownership migration a non-event: the new owner sees an unapplied
  `seq` and re-applies. See §1.

  ---------------------------------------------------------------------------
  INFRA: copy these into server.cfg (ENGINE-SPEC §4 "add_ace group.admin
  command.mo_* allow"). Listed individually as well as by wildcard so the
  wildcard can be dropped if a narrower policy is wanted.

    add_ace group.admin command.mo_spawn   allow
    add_ace group.admin command.mo_engage  allow
    add_ace group.admin command.mo_move    allow
    add_ace group.admin command.mo_amove   allow
    add_ace group.admin command.mo_hold    allow
    add_ace group.admin command.mo_retreat allow
    add_ace group.admin command.mo_status  allow
    add_ace group.admin command.mo_clear   allow
    add_ace group.admin command.test_m1    allow
    add_ace group.admin command.test_pool  allow

    # wildcard equivalent for the mo_* family
    add_ace group.admin command.mo_spawn   allow
    add_ace group.admin "command.mo_*"     allow

    # grant the group to a principal, e.g.
    add_principal identifier.fivem:1 group.admin

  NOTE: /coords is intentionally NOT aced — it is a plain client command in
  mission-ai that fires the `mission:coords` net event handled below.
===========================================================================]]

local TAG = '[mission-core]'

local function log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print(('%s %s'):format(TAG, ok and msg or tostring(fmt)))
end

local function warn(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print(('%s WARN %s'):format(TAG, ok and msg or tostring(fmt)))
end

-- ---------------------------------------------------------------------------
-- Registry
-- ---------------------------------------------------------------------------

--- units[netId] = { ped=entity, f='A'|'B', sq=int, slot=int, order=table, seq=int, owner=int }
local units = {}

--- squads[f][sq] = { netId, netId, ... }
local squads = { A = {}, B = {} }

local nextSquadId = { A = 1, B = 1 }
local seqCounter  = 0

--- Peds created by /test_pool (outside the squad registry); cleared by clearAll().
local poolPeds = {}

--- Bodies of units the audit has evicted from `units`, awaiting deletion:
--- { { ped = entity, ticks = <audit passes remaining> }, ... }
--- Without this a killed ped is unreachable by every code path here — it is
--- gone from `units`, so neither the audit nor clearAll() can ever delete it,
--- and it holds a ped-pool slot until the server restarts.
local corpses = {}

-- ---------------------------------------------------------------------------
-- Argument validation
-- ---------------------------------------------------------------------------

--- @return string|nil 'A' | 'B'
local function argFaction(raw)
    return Config.ValidFaction(raw)
end

--- Strict integer parse. @return integer|nil
local function argInt(raw, minV, maxV)
    if raw == nil then return nil end
    local n = tonumber(raw)
    if type(n) ~= 'number' then return nil end
    if n ~= n or n == math.huge or n == -math.huge then return nil end -- NaN / inf
    if n ~= math.floor(n) then return nil end
    n = math.tointeger(n)
    if n == nil then return nil end
    if minV and n < minV then return nil end
    if maxV and n > maxV then return nil end
    return n
end

--- Strict finite-number parse (world coordinate). @return number|nil
local function argNum(raw)
    if raw == nil then return nil end
    local n = tonumber(raw)
    if type(n) ~= 'number' then return nil end
    if n ~= n or n == math.huge or n == -math.huge then return nil end
    return n + 0.0
end

-- ---------------------------------------------------------------------------
-- Entity helpers (every native call is guarded by DoesEntityExist)
-- ---------------------------------------------------------------------------

--- "Alive" here means POSITIVELY alive: the entity is queryable AND reports
--- health. A freshly created server-side ped reports neither until a client
--- instantiates it, so `not entityAlive(ped)` does NOT mean "dead" — see
--- observeAlive / u.seenAlive below. Never cull on this alone.
local function entityAlive(ped)
    if type(ped) ~= 'number' or ped == 0 then return false end
    if not DoesEntityExist(ped) then return false end
    return GetEntityHealth(ped) > 0
end

--- Latch: a unit is only ever treated as *dead* once it has been seen alive.
--- @return boolean alive right now
local function observeAlive(u)
    if type(u) ~= 'table' then return false end
    if entityAlive(u.ped) then
        u.seenAlive = true
        return true
    end
    return false
end

local function auditInterval()
    local interval = tonumber(Config.Tick and Config.Tick.serverAuditMs) or 1000
    if interval < 100 then interval = 100 end
    return interval
end

--- Audit passes a body waits before deletion, from Config.CorpseLingerMs.
local function corpseTicks()
    local linger = tonumber(Config.CorpseLingerMs) or 0
    if linger <= 0 then return 0 end
    return math.ceil(linger / auditInterval())
end

--- Audit passes a unit may stay "not alive yet", from Config.SpawnGraceMs.
local function spawnGraceTicks()
    local grace = tonumber(Config.SpawnGraceMs) or 15000
    if grace <= 0 then return 0 end
    return math.ceil(grace / auditInterval())
end

local function forgetUnit(netId, reason)
    local u = units[netId]
    if not u then return end
    units[netId] = nil
    -- Keep the body reachable so it is still deleted later (or by /mo_clear).
    -- A unit that was never seen alive may also never have been queryable, so
    -- its handle is kept with force=true: the reaper must delete it regardless
    -- of what DoesEntityExist says, or the ped-pool slot leaks for the session.
    if type(u.ped) == 'number' and u.ped ~= 0 then
        local force = not u.seenAlive
        if force or DoesEntityExist(u.ped) then
            corpses[#corpses + 1] = { ped = u.ped, ticks = corpseTicks(), force = force }
        end
    end
    local bucket = squads[u.f] and squads[u.f][u.sq]
    if bucket then
        for i = #bucket, 1, -1 do
            if bucket[i] == netId then table.remove(bucket, i) end
        end
    end
    log('unit %s (%s/%s slot %s) removed from registry: %s', netId, u.f, u.sq, u.slot, reason or 'unspecified')
end

-- ---------------------------------------------------------------------------
-- Orders — published to the ped's state bag, replicated to all clients
-- ---------------------------------------------------------------------------

local VALID_ORDERS = { hold = true, move = true, amove = true, retreat = true }

--- Write one order onto one unit WITHOUT any liveness gate. `order` is copied
--- per-unit so `slot` differs.
---
--- The gate deliberately lives in setUnitOrder, not here: the initial `hold` is
--- issued in the ped's creation frame, when the ped is not yet instantiated by
--- any client and therefore reads as health 0 / possibly non-existent. Routing
--- that first order through the gate culled every unit the instant it was
--- registered (build 35245). Publishing is safe regardless: the order lives in
--- the state bag and the owning client applies it when it does instantiate.
--- @return boolean published
local function publishOrder(netId, t, x, y, z)
    local u = units[netId]
    if not u then return false end
    if not VALID_ORDERS[t] then
        warn('publishOrder: unknown order type %s', tostring(t))
        return false
    end

    seqCounter = seqCounter + 1
    local order = {
        seq  = seqCounter,
        t    = t,
        x    = x and (x + 0.0) or nil,
        y    = y and (y + 0.0) or nil,
        z    = z and (z + 0.0) or nil,
        sq   = u.sq,
        f    = u.f,
        slot = u.slot,
    }

    local ok, err = pcall(function()
        Entity(u.ped).state:set('mo', order, true)
    end)
    if not ok then
        warn('state bag write failed for unit %s: %s', netId, tostring(err))
        return false
    end

    u.order = order
    u.seq   = seqCounter
    return true
end

--- Order one unit, culling it if it is KNOWN to be dead: known means it was
--- seen alive at some point and is not alive now. A unit that has never been
--- seen alive is still waiting to be instantiated, which is not death.
local function setUnitOrder(netId, t, x, y, z)
    local u = units[netId]
    if not u then return false end
    if not VALID_ORDERS[t] then
        warn('setUnitOrder: unknown order type %s', tostring(t))
        return false
    end
    if not observeAlive(u) and u.seenAlive then
        forgetUnit(netId, 'dead or missing at order time')
        return false
    end
    return publishOrder(netId, t, x, y, z)
end

--- Order a whole squad. @return integer applied, integer total
local function setSquadOrder(f, sq, t, x, y, z)
    local bucket = squads[f] and squads[f][sq]
    if not bucket then return 0, 0 end
    local total, applied = 0, 0
    -- iterate a copy: setUnitOrder may forget dead units mid-loop
    local snapshot = {}
    for i = 1, #bucket do snapshot[i] = bucket[i] end
    for i = 1, #snapshot do
        total = total + 1
        if setUnitOrder(snapshot[i], t, x, y, z) then applied = applied + 1 end
    end
    return applied, total
end

--- Visit every squad bucket. Empty buckets are skipped unless `includeEmpty` is
--- true: ordering commands have nothing to say to an empty squad, but reporting
--- commands must still say "this squad exists and has nothing left in it" —
--- otherwise a wiped-out (or never-registered) squad is indistinguishable from
--- no squad at all, which is how the spawn bug hid for a whole test session.
local function forEachSquad(fn, includeEmpty)
    for _, f in ipairs({ 'A', 'B' }) do
        local ids = {}
        for sq in pairs(squads[f]) do ids[#ids + 1] = sq end
        table.sort(ids)
        for i = 1, #ids do
            local bucket = squads[f][ids[i]]
            if includeEmpty or #bucket > 0 then fn(f, ids[i], bucket) end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Spawning
-- ---------------------------------------------------------------------------

--- @return integer|nil squadId, integer spawned
local function spawnSquad(faction, count)
    local fac = Config.Factions[faction]
    if not fac then
        warn('spawnSquad: no such faction %s', tostring(faction))
        return nil, 0
    end
    local spawn = Config.Spawns[faction]
    if not spawn then
        warn('spawnSquad: no spawn point configured for faction %s', faction)
        return nil, 0
    end
    if type(fac.models) ~= 'table' or #fac.models == 0 then
        warn('spawnSquad: faction %s has no models configured', faction)
        return nil, 0
    end

    local sq = nextSquadId[faction]
    nextSquadId[faction] = sq + 1
    squads[faction][sq] = {}

    local created = 0
    for slot = 0, count - 1 do
        local modelName = fac.models[(slot % #fac.models) + 1]
        local ox, oy = Config.FormationSlotOffset(slot, spawn.w)

        -- CONFIRMED on FXServer build 35245 (2026-09-19, docs/T1-BLOCKER-mission-core.md):
        -- server-side CREATE_PED does take a leading pedType and this call is
        -- correct. 10/10 peds created. 4 = PED_TYPE_CIVMALE.
        local ped = CreatePed(4, GetHashKey(modelName), spawn.x + ox, spawn.y + oy, spawn.z, spawn.w + 0.0, true, true)

        if type(ped) ~= 'number' or ped == 0 then
            warn('CreatePed failed for %s (faction %s, slot %d)', tostring(modelName), faction, slot)
        else
            -- A non-zero handle means the ped was created. It is NOT necessarily
            -- queryable in this frame — an entity no client has instantiated can
            -- read back as non-existent — so a false DoesEntityExist here is
            -- reported and ignored, not treated as a failed spawn. If the ped
            -- really never comes up, the spawn grace window reaps it.
            if not DoesEntityExist(ped) then
                log('ped %s (faction %s slot %d) is not queryable in its creation frame — registering anyway',
                    tostring(ped), faction, slot)
            end
            created = created + 1

            local weaponName = (type(fac.weapons) == 'table' and #fac.weapons > 0)
                and fac.weapons[(slot % #fac.weapons) + 1] or nil
            if weaponName then
                GiveWeaponToPed(ped, GetHashKey(weaponName), 250, false, true)
            end
            SetPedArmour(ped, 100)

            local netId = NetworkGetNetworkIdFromEntity(ped)
            if type(netId) ~= 'number' or netId == 0 then
                warn('no network id for freshly created ped (faction %s slot %d) — deleting', faction, slot)
                if DoesEntityExist(ped) then DeleteEntity(ped) end
            else
                local okBag, bagErr = pcall(function()
                    Entity(ped).state:set('mu', { f = faction, sq = sq, slot = slot }, true)
                end)
                if not okBag then
                    warn('mu state bag write failed for netId %s: %s', netId, tostring(bagErr))
                end

                units[netId] = {
                    ped        = ped,
                    f          = faction,
                    sq         = sq,
                    slot       = slot,
                    order      = nil,
                    seq        = 0,
                    owner      = NetworkGetEntityOwner(ped),
                    seenAlive  = false,
                    graceTicks = spawnGraceTicks(),
                }
                squads[faction][sq][#squads[faction][sq] + 1] = netId
                -- Publish directly: the aliveness gate must never see this one.
                if not publishOrder(netId, 'hold') then
                    warn('initial hold not published for netId %s — the audit will retry', netId)
                end
            end
        end
    end

    -- Report what actually survived, not what was attempted: a unit only counts
    -- when it is still in the registry AND carries an order. `alive` is separate
    -- because peds normally instantiate a frame or more after they are created,
    -- so 0 alive right here is expected, not a failure.
    local bucket = squads[faction][sq]
    local registered, ordered, alive = #bucket, 0, 0
    for i = 1, #bucket do
        local u = units[bucket[i]]
        if u then
            if u.order then ordered = ordered + 1 end
            if observeAlive(u) then alive = alive + 1 end
        end
    end

    log('spawned squad %s/%d — %d/%d peds created, %d registered, %d ordered, %d alive so far at (%.2f, %.2f, %.2f h=%.1f)',
        faction, sq, created, count, registered, ordered, alive, spawn.x, spawn.y, spawn.z, spawn.w)
    if ordered < registered then
        warn('squad %s/%d: %d registered unit(s) have no order yet', faction, sq, registered - ordered)
    end
    return sq, ordered
end

local function clearAll()
    local removed = 0
    for netId, u in pairs(units) do
        -- A unit that was never seen alive may not be queryable yet; delete it
        -- anyway rather than leave a ped-pool slot behind.
        if type(u.ped) == 'number' and u.ped ~= 0 and (DoesEntityExist(u.ped) or not u.seenAlive) then
            DeleteEntity(u.ped)
            removed = removed + 1
        end
        units[netId] = nil
    end
    for i = #corpses, 1, -1 do
        local ped = corpses[i].ped
        if type(ped) == 'number' and ped ~= 0 and (DoesEntityExist(ped) or corpses[i].force) then
            DeleteEntity(ped)
            removed = removed + 1
        end
        corpses[i] = nil
    end
    for i = #poolPeds, 1, -1 do
        local ped = poolPeds[i]
        if type(ped) == 'number' and ped ~= 0 and DoesEntityExist(ped) then
            DeleteEntity(ped)
            removed = removed + 1
        end
        poolPeds[i] = nil
    end
    squads = { A = {}, B = {} }
    nextSquadId = { A = 1, B = 1 }
    log('cleared %d mission entities', removed)
    return removed
end

-- ---------------------------------------------------------------------------
-- Commands (§4). All restricted (`RegisterCommand(name, fn, true)`).
-- ---------------------------------------------------------------------------

local function usage(line)
    print(('%s usage: %s'):format(TAG, line))
end

RegisterCommand('mo_spawn', function(_, args)
    args = args or {}
    local f = argFaction(args[1])
    if not f then
        usage('/mo_spawn <A|B> [count]')
        return
    end
    local count = Config.SquadSize
    if args[2] ~= nil then
        count = argInt(args[2], 1, 64)
        if not count then
            usage('/mo_spawn <A|B> [count]  — count must be an integer 1..64')
            return
        end
    end
    spawnSquad(f, count)
end, true)

RegisterCommand('mo_engage', function()
    local squadCount, unitCount = 0, 0
    forEachSquad(function(f, sq)
        local other = Config.OtherFaction(f)
        local goal = other and Config.Spawns[other]
        if not goal then
            warn('mo_engage: no enemy spawn for faction %s', f)
            return
        end
        local applied = setSquadOrder(f, sq, 'amove', goal.x, goal.y, goal.z)
        squadCount = squadCount + 1
        unitCount  = unitCount + applied
    end)
    log('mo_engage: attack-move issued to %d squad(s), %d unit(s)', squadCount, unitCount)
end, true)

local function moveLike(orderType)
    return function(_, args)
        args = args or {}
        local f  = argFaction(args[1])
        local sq = argInt(args[2], 1)
        local x  = argNum(args[3])
        local y  = argNum(args[4])
        local z  = argNum(args[5])
        if not f or not sq or not x or not y or not z then
            usage(('/mo_%s <A|B> <squadId:int> <x> <y> <z>'):format(orderType))
            return
        end
        if not (squads[f] and squads[f][sq]) then
            warn('no squad %s/%s', f, sq)
            return
        end
        local applied, total = setSquadOrder(f, sq, orderType, x, y, z)
        log('mo_%s %s/%d -> (%.2f, %.2f, %.2f): %d/%d unit(s)', orderType, f, sq, x, y, z, applied, total)
    end
end

RegisterCommand('mo_move',  moveLike('move'),  true)
RegisterCommand('mo_amove', moveLike('amove'), true)

RegisterCommand('mo_hold', function(_, args)
    args = args or {}
    local f  = argFaction(args[1])
    local sq = argInt(args[2], 1)
    if not f or not sq then
        usage('/mo_hold <A|B> <squadId:int>')
        return
    end
    if not (squads[f] and squads[f][sq]) then
        warn('no squad %s/%s', f, sq)
        return
    end
    local applied, total = setSquadOrder(f, sq, 'hold')
    log('mo_hold %s/%d: %d/%d unit(s)', f, sq, applied, total)
end, true)

RegisterCommand('mo_retreat', function(_, args)
    args = args or {}
    local f  = argFaction(args[1])
    local sq = argInt(args[2], 1)
    if not f or not sq then
        usage('/mo_retreat <A|B> <squadId:int>')
        return
    end
    if not (squads[f] and squads[f][sq]) then
        warn('no squad %s/%s', f, sq)
        return
    end
    local home = Config.Spawns[f]
    if not home then
        warn('mo_retreat: no spawn configured for faction %s', f)
        return
    end
    local applied, total = setSquadOrder(f, sq, 'retreat', home.x, home.y, home.z)
    log('mo_retreat %s/%d -> own spawn: %d/%d unit(s)', f, sq, applied, total)
end, true)

RegisterCommand('mo_status', function()
    log('--- status ---------------------------------------------------------')
    -- includeEmpty: a squad whose units were all culled must still be listed,
    -- otherwise "everything died" and "nothing was ever spawned" print the same
    -- line and the operator cannot tell them apart.
    local squadCount, registeredTotal, aliveTotal, waitingTotal = 0, 0, 0, 0
    forEachSquad(function(f, sq, bucket)
        squadCount = squadCount + 1
        local alive, waiting, lines = 0, 0, {}
        for i = 1, #bucket do
            local netId = bucket[i]
            local u = units[netId]
            if u then
                registeredTotal = registeredTotal + 1
                if observeAlive(u) then
                    alive = alive + 1
                    local owner = NetworkGetEntityOwner(u.ped)
                    local hp    = GetEntityHealth(u.ped)
                    local c     = GetEntityCoords(u.ped)
                    lines[#lines + 1] = ('    netId=%s slot=%s hp=%s owner=%s pos=(%.1f, %.1f, %.1f)')
                        :format(netId, u.slot, hp, tostring(owner), c.x, c.y, c.z)
                else
                    waiting = waiting + 1
                    lines[#lines + 1] = ('    netId=%s slot=%s not alive yet (seenAlive=%s, order=%s) — waiting for a client to instantiate it')
                        :format(netId, u.slot, tostring(u.seenAlive == true), u.order and u.order.t or 'none')
                end
            end
        end
        aliveTotal   = aliveTotal + alive
        waitingTotal = waitingTotal + waiting
        local order = 'none'
        for i = 1, #bucket do
            local u = units[bucket[i]]
            if u and u.order then order = ('%s seq=%d'):format(u.order.t, u.order.seq) break end
        end
        log('squad %s/%d  alive=%d/%d  order=%s', f, sq, alive, #bucket, order)
        for i = 1, #lines do print(lines[i]) end
    end, true)
    if squadCount == 0 then
        log('no squads registered')
    else
        log('totals: %d squad(s), %d unit(s) registered, %d alive, %d awaiting instantiation',
            squadCount, registeredTotal, aliveTotal, waitingTotal)
    end
    log('--------------------------------------------------------------------')
end, true)

RegisterCommand('mo_clear', function()
    clearAll()
end, true)

-- ---------------------------------------------------------------------------
-- Test commands (§7)
-- ---------------------------------------------------------------------------

local testM1Running = false

RegisterCommand('test_m1', function()
    if testM1Running then
        warn('test_m1 already running')
        return
    end
    testM1Running = true
    Citizen.CreateThread(function()
        log('[test_m1] clearing')
        clearAll()
        Citizen.Wait(500)
        log('[test_m1] spawning A and B')
        spawnSquad('A', Config.SquadSize)
        spawnSquad('B', Config.SquadSize)
        Citizen.Wait(2000)
        log('[test_m1] engage')
        ExecuteCommand('mo_engage')
        log('[test_m1] running for 90 s — walk the caster >300 m away to force ownership migration')
        Citizen.Wait(90000)
        log('[test_m1] 90 s elapsed, dumping status')
        ExecuteCommand('mo_status')
        log('[test_m1] exit criterion: both sides took losses AND units are still fighting after migration')
        testM1Running = false
    end)
end, true)

RegisterCommand('test_pool', function(_, args)
    args = args or {}
    local n = argInt(args[1], 1, 512)
    if not n then
        usage('/test_pool <n:int 1..512>')
        return
    end
    local spawn = Config.Spawns.A
    local fac   = Config.Factions.A
    if not spawn or not fac or type(fac.models) ~= 'table' or #fac.models == 0 then
        warn('test_pool: faction A is not configured')
        return
    end

    local created = {}
    local perRow  = math.ceil(math.sqrt(n))
    local step    = tonumber(Config.FormationOffset) or 2.5
    for i = 0, n - 1 do
        local row, col = math.floor(i / perRow), i % perRow
        local modelName = fac.models[(i % #fac.models) + 1]
        -- pedType argument, as in spawnSquad above (confirmed on build 35245).
        local ped = CreatePed(4, GetHashKey(modelName),
            spawn.x + (col * step), spawn.y + (row * step), spawn.z, spawn.w + 0.0, true, true)
        if type(ped) == 'number' and ped ~= 0 and DoesEntityExist(ped) then
            created[#created + 1] = ped
            poolPeds[#poolPeds + 1] = ped
        end
    end
    log('[test_pool] requested %d, created %d peds in a %d-wide grid (use /mo_clear to delete)', n, #created, perRow)

    Citizen.CreateThread(function()
        while #created > 0 do
            Citizen.Wait(10000)
            local alive = 0
            for i = #created, 1, -1 do
                local ped = created[i]
                if DoesEntityExist(ped) then
                    alive = alive + 1
                else
                    table.remove(created, i)
                end
            end
            if alive == 0 then break end
            log('[test_pool] server-side alive count: %d', alive)
        end
        log('[test_pool] pool empty, measurement thread stopping')
    end)
end, true)

-- ---------------------------------------------------------------------------
-- Ownership audit (§4) — every Config.Tick.serverAuditMs
-- ---------------------------------------------------------------------------

Citizen.CreateThread(function()
    local interval = auditInterval()
    while true do
        Citizen.Wait(interval)

        local stale = {}
        for netId, u in pairs(units) do
            local exists = type(u.ped) == 'number' and u.ped ~= 0 and DoesEntityExist(u.ped)
            local hp     = exists and GetEntityHealth(u.ped) or 0
            if hp > 0 then u.seenAlive = true end

            -- Grace window: counted down from registration, and only ever used
            -- to decide when a unit that is NOT positively alive may be culled.
            if (u.graceTicks or 0) > 0 then u.graceTicks = u.graceTicks - 1 end
            local pastGrace = (u.graceTicks or 0) <= 0

            if exists and hp > 0 then
                local owner = NetworkGetEntityOwner(u.ped)
                if owner ~= u.owner then
                    print(('%s [T1] unit %s owner %s -> %s'):format(TAG, netId, tostring(u.owner), tostring(owner)))
                    u.owner = owner
                end
                -- Self-heal: the initial hold is published inside a pcall and can
                -- fail against an entity no client has instantiated yet. A unit
                -- with no order would otherwise stand around forever.
                if u.order == nil then
                    if setUnitOrder(netId, 'hold') then
                        log('unit %s (%s/%s slot %s) had no order — re-applied hold', netId, u.f, u.sq, u.slot)
                    else
                        warn('unit %s (%s/%s slot %s) still has no order after a retry', netId, u.f, u.sq, u.slot)
                    end
                end
            elseif u.seenAlive and exists then
                -- Seen alive before, queryable, no health left: genuinely dead.
                stale[#stale + 1] = { netId, 'health <= 0' }
            elseif pastGrace then
                if not u.seenAlive then
                    stale[#stale + 1] = { netId, ('never became alive within %d ms of spawn — most likely no client ever instantiated it (nobody in scope of the spawn point)')
                        :format(tonumber(Config.SpawnGraceMs) or 15000) }
                else
                    stale[#stale + 1] = { netId, 'entity no longer exists' }
                end
            end
            -- Otherwise: not alive yet, still inside the grace window. Leave it
            -- alone — "not instantiated" is not "dead".
        end

        for i = 1, #stale do
            forgetUnit(stale[i][1], stale[i][2])
        end

        -- Reap bodies whose linger time has elapsed.
        for i = #corpses, 1, -1 do
            local c = corpses[i]
            if type(c.ped) ~= 'number' or c.ped == 0 then
                table.remove(corpses, i)
            elseif c.ticks <= 0 then
                -- force: the ped never instantiated, so DoesEntityExist cannot be
                -- trusted to say whether there is still something to delete.
                if c.force or DoesEntityExist(c.ped) then DeleteEntity(c.ped) end
                table.remove(corpses, i)
            elseif not c.force and not DoesEntityExist(c.ped) then
                table.remove(corpses, i)
            else
                c.ticks = c.ticks - 1
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- /coords dumper (§4, §3.5) — client sends, server appends to JSON
-- ---------------------------------------------------------------------------

local COORDS_FILE = 'coords_dump.json'

--- Read the dump. Never throws; returns an array table (possibly empty).
local function readCoordsDump()
    local resName = GetCurrentResourceName()
    local okLoad, raw = pcall(LoadResourceFile, resName, COORDS_FILE)
    if not okLoad then
        warn('LoadResourceFile(%s) failed: %s', COORDS_FILE, tostring(raw))
        return {}
    end
    if type(raw) ~= 'string' or #raw == 0 then
        return {}
    end
    local okDec, decoded = pcall(json.decode, raw)
    if not okDec or type(decoded) ~= 'table' then
        warn('%s is not valid JSON — starting a fresh list (old content will be overwritten)', COORDS_FILE)
        return {}
    end
    return decoded
end

--- Append one record. @return boolean ok
local function appendCoordsDump(record)
    local list = readCoordsDump()
    list[#list + 1] = record

    local okEnc, encoded = pcall(json.encode, list)
    if not okEnc or type(encoded) ~= 'string' then
        warn('json.encode failed: %s', tostring(encoded))
        return false
    end

    -- SaveResourceFile(resourceName, fileName, data, dataLength) — -1 = use #data
    local okSave, saved = pcall(SaveResourceFile, GetCurrentResourceName(), COORDS_FILE, encoded, -1)
    if not okSave then
        warn('SaveResourceFile(%s) failed: %s', COORDS_FILE, tostring(saved))
        return false
    end
    if saved == false then
        warn('SaveResourceFile(%s) returned false — check resource folder write permissions', COORDS_FILE)
        return false
    end
    return true
end

RegisterNetEvent('mission:coords')
AddEventHandler('mission:coords', function(label, x, y, z, h)
    local src = source
    if type(src) ~= 'number' or src <= 0 then
        warn('mission:coords from an invalid source (%s) — ignored', tostring(src))
        return
    end

    -- Never trust the client: validate and clamp everything.
    if type(label) ~= 'string' then label = tostring(label) end
    label = label:gsub('[%c]', ' '):sub(1, 96)
    if label:gsub('%s', '') == '' then label = 'unlabelled' end

    local nx, ny, nz, nh = argNum(x), argNum(y), argNum(z), argNum(h)
    if not nx or not ny or not nz or not nh then
        warn('mission:coords from %s had non-numeric coordinates — ignored', src)
        return
    end
    nh = nh % 360.0

    local record = {
        label  = label,
        x      = nx,
        y      = ny,
        z      = nz,
        h      = nh,
        player = src,                       -- invoking player's server id
        name   = GetPlayerName(src) or '?',
        at     = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    }

    if appendCoordsDump(record) then
        log('/coords "%s" from player %s (%s): vector4(%.4f, %.4f, %.4f, %.4f)',
            label, src, record.name, nx, ny, nz, nh)
    else
        warn('/coords "%s" from player %s was NOT persisted', label, src)
    end
end)

-- ---------------------------------------------------------------------------

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    clearAll()
end)

log('loaded — commands: mo_spawn mo_engage mo_move mo_amove mo_hold mo_retreat mo_status mo_clear test_m1 test_pool')
