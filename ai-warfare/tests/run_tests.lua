--[[===========================================================================
  tests/run_tests.lua — behaviour tests for the mission engine, executed against
  tests/fivem_mock.lua (no FXServer, no game client).

  Topology built here:
      sharedEnv  — config.lua only (pure data + helpers), Config injected everywhere
      server     — mission-core/server.lua
      client1    — mission-ai/client.lua   (player/server id 1)
      client2    — mission-ai/client.lua   (player/server id 2)   <- ownership migration
      popctl     — population-ctl/client.lua (created lazily in the last test)

  All five talk to ONE world, ONE state-bag store and ONE virtual clock.
===========================================================================]]

-- --------------------------------------------------------------------------
-- Locate the repository root from this script's own path
-- --------------------------------------------------------------------------

local scriptPath = arg and arg[0] or 'tests/run_tests.lua'
local testsDir   = scriptPath:match('^(.*)[/\\][^/\\]+$') or '.'
local ROOT       = testsDir .. '/..'
local MISSION    = ROOT .. '/resources/[mission]'

local Mock = dofile(testsDir .. '/fivem_mock.lua')

-- --------------------------------------------------------------------------
-- Assertion framework
-- --------------------------------------------------------------------------

local tests   = {}
local pendings = {}

local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function pending(name, why) pendings[#pendings + 1] = { name = name, why = why } end

local function fail(msg, ...)
    if select('#', ...) > 0 then msg = msg:format(...) end
    error(msg, 3)
end

local function ok(cond, msg, ...)
    if not cond then fail(msg or 'assertion failed', ...) end
end

local function eq(actual, expected, what)
    if actual ~= expected then
        fail('%s: expected %s, got %s', what or 'value', tostring(expected), tostring(actual))
    end
end

local function near(actual, expected, what, tol)
    tol = tol or 1e-6
    if type(actual) ~= 'number' then
        fail('%s: expected a number near %s, got %s', what or 'value', tostring(expected), tostring(actual))
    end
    if math.abs(actual - expected) > tol then
        fail('%s: expected %.6f +- %g, got %.6f', what or 'value', expected, tol, actual)
    end
end

local function notNil(v, what)
    if v == nil then fail('%s: expected a value, got nil', what or 'value') end
    return v
end

local function outputHas(pattern, what)
    local found, line = Mock.outputMatches(pattern)
    if not found then
        fail('%s: no console line matched %q\n--- output ---\n%s\n--------------',
            what or 'output', pattern, Mock.outputText())
    end
    return line
end

local function noErrors(what)
    if #Mock.errors > 0 then
        local parts = {}
        for i = 1, #Mock.errors do
            parts[#parts + 1] = ('[%s] %s'):format(Mock.errors[i].ctx, Mock.errors[i].message)
        end
        fail('%s: %d runtime error(s):\n%s', what or 'runtime', #Mock.errors, table.concat(parts, '\n'))
    end
end

-- --------------------------------------------------------------------------
-- Build the world
-- --------------------------------------------------------------------------

local sharedEnv = Mock.makeEnv('shared', { resource = 'mission-shared', side = 'shared' })
Mock.loadInto(sharedEnv, MISSION .. '/mission-shared/config.lua')
local Config = assert(sharedEnv.Config, 'config.lua did not define Config')

local server  = Mock.makeEnv('server',  { resource = 'mission-core', side = 'server', player = 0 })
local client1 = Mock.makeEnv('client1', { resource = 'mission-ai',   side = 'client', player = 1 })
local client2 = Mock.makeEnv('client2', { resource = 'mission-ai',   side = 'client', player = 2 })

server.Config, client1.Config, client2.Config = Config, Config, Config

Mock.loadInto(server,  MISSION .. '/mission-core/server.lua')
Mock.loadInto(client1, MISSION .. '/mission-ai/client.lua')
Mock.loadInto(client2, MISSION .. '/mission-ai/client.lua')

-- Materialise each client's own player ped up front so the pool is realistic
-- (peds with no `mu` bag that mission-ai must ignore).
local player1Ped = client1.PlayerPedId()
local player2Ped = client2.PlayerPedId()

-- --------------------------------------------------------------------------
-- Helpers
-- --------------------------------------------------------------------------

local CLIENT_TICK = tonumber(Config.Tick.clientMs) or 500
local AUDIT_TICK  = tonumber(Config.Tick.serverAuditMs) or 1000

local function tickClients(n)
    Mock.advance(CLIENT_TICK * (n or 1) + 10)
end

--- Give the server audit one pass in which the units are alive.
--- The server only treats a unit as dead once it has SEEN it alive: a ped no
--- client has instantiated yet reads health 0 as well, and culling on that is
--- the production blocker. So a test that kills a ped must first let the audit
--- latch seenAlive — which any real match does long before its first casualty.
local function auditSeesAlive()
    Mock.advance(AUDIT_TICK + 100)
end

local function reset()
    -- Restore the instantiation knobs before clearing, so a test that left peds
    -- un-instantiated (or unqueryable) cannot block /mo_clear.
    Mock.autoInstantiate           = true
    Mock.existsBeforeInstantiation = true
    Mock.bagWriteBlocked           = nil
    Mock.runCommand(server, 'mo_clear')
    -- /mo_clear must leave nothing behind, corpses included. Asserting it here
    -- means any future regression of the corpse leak fails the whole suite
    -- rather than quietly contaminating the next test.
    local leaked = Mock.livePedsCreatedBy('server')
    if #leaked > 0 then
        for _, p in ipairs(leaked) do Mock.destroyPed(p.handle) end
        fail('/mo_clear left %d server-created ped(s) in the world', #leaked)
    end
    Mock.advance(AUDIT_TICK + CLIENT_TICK * 2)   -- let clients GC their bookkeeping
    Mock.clearLog()
    Mock.clearOutput()
    Mock.clearErrors()
end

--- Mission peds created by the server resource (excludes the two player peds).
local function missionPeds()
    return Mock.livePedsCreatedBy('server')
end

local function pedBySlot(peds, slot)
    for _, p in ipairs(peds) do
        local mu = Mock.getState(p.handle, 'mu')
        if mu and mu.slot == slot then return p end
    end
    return nil
end

local function firstPedOfFaction(f)
    for _, p in ipairs(missionPeds()) do
        local mu = Mock.getState(p.handle, 'mu')
        if mu and mu.f == f then return p end
    end
    return nil
end

local function callsFor(ctx, nativeName, handle)
    return Mock.calls({ ctx = ctx, name = nativeName, arg1 = handle })
end

local function countFor(ctx, nativeName, handle)
    return #callsFor(ctx, nativeName, handle)
end

--- Every logged call this ctx made whose first argument is `handle`.
local function anyCallsTouching(ctx, handle)
    local out = {}
    for _, c in ipairs(Mock.callLog) do
        if c.ctx == ctx and c.args[1] == handle then out[#out + 1] = c end
    end
    return out
end

local SPAWN_A = Config.Spawns.A
local SPAWN_B = Config.Spawns.B

-- Test-only fixture coordinates (allowed inside tests/ only; real coordinates
-- come from the in-game /coords dumper).
local GOAL = { x = SPAWN_A.x + 50.0, y = SPAWN_A.y + 50.0, z = SPAWN_A.z }
local FAR  = { x = SPAWN_B.x, y = SPAWN_B.y, z = SPAWN_B.z }

-- Prime the scheduler: resource start threads (audit loop, client loops).
Mock.advance(0)

-- ===========================================================================
-- 1. /mo_spawn A 5 — registry, mu bag, initial hold order
-- ===========================================================================

test('01 /mo_spawn A 5 creates 5 peds with mu identity and an initial hold order', function()
    reset()
    Mock.runCommand(server, 'mo_spawn A 5')
    noErrors('mo_spawn')

    local peds = missionPeds()
    eq(#peds, 5, 'ped count')

    local slotsSeen = {}
    for _, p in ipairs(peds) do
        local mu = notNil(Mock.getState(p.handle, 'mu'), 'mu bag for ped ' .. p.handle)
        eq(mu.f, 'A', 'mu.f')
        eq(mu.sq, 1, 'mu.sq')
        ok(type(mu.slot) == 'number', 'mu.slot must be a number, got %s', tostring(mu.slot))
        ok(mu.slot >= 0 and mu.slot <= 4, 'mu.slot out of range: %s', tostring(mu.slot))
        ok(not slotsSeen[mu.slot], 'duplicate slot %s', tostring(mu.slot))
        slotsSeen[mu.slot] = true
        ok(Mock.isReplicated(p.handle, 'mu'), 'mu must be written replicated=true')

        local mo = notNil(Mock.getState(p.handle, 'mo'), 'mo bag for ped ' .. p.handle)
        eq(mo.t, 'hold', 'initial order type')
        ok(type(mo.seq) == 'number' and mo.seq > 0, 'initial seq must be nonzero, got %s', tostring(mo.seq))
        eq(mo.f, 'A', 'order faction')
        eq(mo.sq, 1, 'order squad')
        ok(Mock.isReplicated(p.handle, 'mo'), 'mo must be written replicated=true')
    end

    -- The owning client must turn that hold order into the §5.4 hold task pair.
    tickClients(1)
    for _, p in ipairs(peds) do
        eq(countFor('client1', 'TaskGuardCurrentPosition', p.handle), 1,
            'TaskGuardCurrentPosition for ped ' .. p.handle)
        eq(countFor('client1', 'TaskCombatHatedTargetsAroundPed', p.handle), 1,
            'TaskCombatHatedTargetsAroundPed for ped ' .. p.handle .. ' (ENGINE-SPEC §5.4 hold)')
    end
    noErrors('hold apply')
end)

-- ===========================================================================
-- 2. Formation offsets
-- ===========================================================================

test('02 spawn formation offsets are distinct per slot, slot 0 on the centre line', function()
    reset()
    Mock.runCommand(server, 'mo_spawn A 5')
    local peds = missionPeds()
    eq(#peds, 5, 'ped count')

    local centre = notNil(pedBySlot(peds, 0), 'slot 0 ped')
    near(centre.coords.x, SPAWN_A.x, 'slot 0 x is on the spawn centre line')
    near(centre.coords.y, SPAWN_A.y, 'slot 0 y is on the spawn centre line')

    local seenXY = {}
    for _, p in ipairs(peds) do
        local key = ('%.4f|%.4f'):format(p.coords.x, p.coords.y)
        ok(not seenXY[key], 'two peds share the spawn position %s', key)
        seenXY[key] = true
    end

    -- Spacing must follow Config.FormationOffset, perpendicular to spawn heading.
    for slot = 1, 4 do
        local p = notNil(pedBySlot(peds, slot), 'slot ' .. slot .. ' ped')
        local d = math.sqrt((p.coords.x - SPAWN_A.x) ^ 2 + (p.coords.y - SPAWN_A.y) ^ 2)
        local rank = math.ceil(slot / 2)
        near(d, rank * Config.FormationOffset, 'slot ' .. slot .. ' offset distance', 1e-4)
    end
end)

-- ===========================================================================
-- 3. /mo_amove raises seq and the owner tasks each ped once, with slot offsets
-- ===========================================================================

test('03 /mo_amove raises seq on all 5 and the owner issues one offset goto per ped', function()
    reset()
    Mock.runCommand(server, 'mo_spawn A 5')
    tickClients(1)                      -- hold applied
    Mock.clearLog()

    local peds = missionPeds()
    local before = {}
    for _, p in ipairs(peds) do before[p.handle] = Mock.getState(p.handle, 'mo').seq end

    Mock.runCommand(server, ('mo_amove A 1 %.1f %.1f %.1f'):format(GOAL.x, GOAL.y, GOAL.z))
    noErrors('mo_amove')

    for _, p in ipairs(peds) do
        local mo = Mock.getState(p.handle, 'mo')
        eq(mo.t, 'amove', 'order type for ped ' .. p.handle)
        ok(mo.seq > before[p.handle], 'seq must rise for ped %s (%s -> %s)',
            p.handle, tostring(before[p.handle]), tostring(mo.seq))
    end

    tickClients(1)

    local targets = {}
    for _, p in ipairs(peds) do
        local calls = callsFor('client1', 'TaskGoToCoordAnyMeans', p.handle)
        eq(#calls, 1, 'goto count for ped ' .. p.handle)
        eq(countFor('client2', 'TaskGoToCoordAnyMeans', p.handle), 0,
            'a non-owning client must not task ped ' .. p.handle)
        local c = calls[1]
        local mu = Mock.getState(p.handle, 'mu')
        local key = ('%.4f|%.4f'):format(c.args[2], c.args[3])
        ok(not targets[key], 'slots %s and %s were sent to the same point', tostring(targets[key]), tostring(mu.slot))
        targets[key] = mu.slot
        near(c.args[4], GOAL.z, 'goto z for slot ' .. mu.slot)

        local dist = math.sqrt((c.args[2] - GOAL.x) ^ 2 + (c.args[3] - GOAL.y) ^ 2)
        if mu.slot == 0 then
            near(dist, 0.0, 'slot 0 must be sent to the goal itself', 1e-4)
        else
            near(dist, math.ceil(mu.slot / 2) * Config.FormationOffset,
                'slot ' .. mu.slot .. ' formation offset at the goal', 1e-4)
        end
    end
    noErrors('amove apply')
end)

-- ===========================================================================
-- 4. T1 ownership migration — the core design claim
-- ===========================================================================

test('04 T1: ownership migration re-applies the order on the new owner with no server order', function()
    reset()
    Mock.runCommand(server, 'mo_spawn A 1')
    tickClients(1)
    Mock.runCommand(server, ('mo_amove A 1 %.1f %.1f %.1f'):format(FAR.x, FAR.y, FAR.z))
    tickClients(1)

    local ped = notNil(missionPeds()[1], 'the spawned ped')
    eq(countFor('client1', 'TaskGoToCoordAnyMeans', ped.handle), 1, 'client1 tasked the ped it owns')
    eq(countFor('client2', 'TaskGoToCoordAnyMeans', ped.handle), 0, 'client2 must not task a ped it does not own')

    local seqBefore = Mock.getState(ped.handle, 'mo').seq
    local orderBefore = Mock.getState(ped.handle, 'mo')

    Mock.clearLog()
    Mock.clearOutput()

    -- OneSync hands the ped to client 2. No server round-trip happens.
    Mock.setOwner(ped.handle, 2)
    Mock.advance(AUDIT_TICK + CLIENT_TICK * 2)

    local orderAfter = Mock.getState(ped.handle, 'mo')
    eq(orderAfter.seq, seqBefore, 'the server must NOT publish a new order on migration')
    eq(orderAfter.t, orderBefore.t, 'order type must be unchanged')

    ok(countFor('client2', 'TaskGoToCoordAnyMeans', ped.handle) >= 1,
        'the NEW owner must re-apply the current order (got %d goto calls)',
        countFor('client2', 'TaskGoToCoordAnyMeans', ped.handle))
    eq(countFor('client2', 'ClearPedTasks', ped.handle), 1, 'new owner re-applies exactly once')

    local stale = anyCallsTouching('client1', ped.handle)
    if #stale > 0 then
        local names = {}
        for _, c in ipairs(stale) do names[#names + 1] = c.name end
        fail('the OLD owner must stop touching the ped, but called: %s', table.concat(names, ', '))
    end

    -- The server audit is the T1 evidence line required by ENGINE-SPEC §4.
    outputHas('%[T1%] unit %d+ owner 1 %-> 2', 'ownership audit log')

    -- And a further tick must not produce a second re-application.
    Mock.clearLog()
    tickClients(2)
    eq(countFor('client2', 'ClearPedTasks', ped.handle), 0,
        'the new owner must not re-apply the same seq every tick')
    noErrors('migration')
end)

-- ===========================================================================
-- 5. Re-issuing the same order type
-- ===========================================================================

test('05 re-issuing the same order type produces a new seq and a fresh re-apply', function()
    reset()
    Mock.runCommand(server, 'mo_spawn A 1')
    tickClients(1)
    local ped = notNil(missionPeds()[1], 'the spawned ped')

    local cmd = ('mo_amove A 1 %.1f %.1f %.1f'):format(FAR.x, FAR.y, FAR.z)
    Mock.runCommand(server, cmd)
    tickClients(1)
    local seq1 = Mock.getState(ped.handle, 'mo').seq

    Mock.clearLog()
    Mock.runCommand(server, cmd)             -- identical order, issued again
    local seq2 = Mock.getState(ped.handle, 'mo').seq
    ok(seq2 > seq1, 'a repeated order must bump seq (%s -> %s)', tostring(seq1), tostring(seq2))

    tickClients(1)
    eq(countFor('client1', 'TaskGoToCoordAnyMeans', ped.handle), 1, 'fresh re-apply after the new seq')
    eq(countFor('client1', 'ClearPedTasks', ped.handle), 1, 'fresh re-apply clears tasks first')
    noErrors('re-issue')
end)

-- ===========================================================================
-- 6. Death → registry + squad bucket eviction
-- ===========================================================================

test('06 a dead ped leaves the registry and the squad bucket; /mo_status still runs', function()
    reset()
    Mock.runCommand(server, 'mo_spawn A 5')
    tickClients(1)

    local peds = missionPeds()
    local victim = notNil(pedBySlot(peds, 2), 'slot 2 ped')
    local netId = victim.netId
    auditSeesAlive()

    Mock.clearOutput()
    Mock.setHealth(victim.handle, 0)
    Mock.advance(AUDIT_TICK + 100)

    outputHas(('unit %d %%(A/1 slot 2%%) removed from registry'):format(netId), 'audit eviction log')

    Mock.clearOutput()
    Mock.runCommand(server, 'mo_status')
    noErrors('mo_status after a death')
    outputHas('squad A/1  alive=4/4', 'mo_status squad line')

    -- A second audit pass must not re-report or crash on the evicted unit.
    Mock.clearOutput()
    Mock.advance(AUDIT_TICK + 100)
    local again = Mock.outputMatches(('unit %d %%('):format(netId))
    ok(not again, 'the evicted unit must not be reported twice')
    noErrors('second audit pass')
end)

-- ===========================================================================
-- 7. /mo_clear
-- ===========================================================================

test('07 /mo_clear deletes squad peds and /test_pool peds', function()
    reset()
    Mock.runCommand(server, 'mo_spawn A 5')
    Mock.runCommand(server, 'test_pool 4')
    noErrors('test_pool')
    eq(#missionPeds(), 9, 'squad peds + pool peds alive before clear')

    Mock.runCommand(server, 'mo_clear')
    eq(#missionPeds(), 0, 'every mission entity must be gone after /mo_clear')
    outputHas('cleared 9 mission entities', 'mo_clear log')

    -- A second spawn must start from squad 1 again (nextSquadId reset).
    Mock.runCommand(server, 'mo_spawn B 2')
    local mu = Mock.getState(missionPeds()[1].handle, 'mu')
    eq(mu.sq, 1, 'squad numbering restarts after /mo_clear')
    noErrors('post-clear spawn')
end)

-- ===========================================================================
-- 8. mission:coords dumper
-- ===========================================================================

test('08 mission:coords appends a validated record and rejects/sanitises bad input', function()
    reset()
    Mock.clearResourceFiles()

    local function dump()
        local raw = Mock.readResourceFile('mission-core', 'coords_dump.json')
        if not raw then return {} end
        return Mock.json.decode(raw)
    end

    -- (a) the happy path, through the real client command
    Mock.setCoords(player1Ped, 12.5, -34.25, 7.0)
    Mock.world.peds[player1Ped].heading = 200.5
    Mock.runCommand(client1, 'coords spawn_A')
    noErrors('/coords')

    local list = dump()
    eq(#list, 1, 'record count after one /coords')
    local r = list[1]
    eq(r.label, 'spawn_A', 'label')
    near(r.x, 12.5, 'x'); near(r.y, -34.25, 'y'); near(r.z, 7.0, 'z')
    near(r.h, 200.5, 'h')
    eq(r.player, 1, 'invoking player server id')
    eq(r.name, 'MockPlayer1', 'player name')
    ok(type(r.at) == 'string' and r.at:match('^%d%d%d%d%-%d%d%-%d%dT'), 'timestamp, got %s', tostring(r.at))

    -- (b) non-numeric coordinates are rejected outright
    Mock.clearOutput()
    client1.TriggerServerEvent('mission:coords', 'bad_coords', 'abc', 2.0, 3.0, 4.0)
    eq(#dump(), 1, 'a non-numeric coordinate must not be persisted')
    outputHas('non%-numeric coordinates', 'rejection warning')
    noErrors('non-numeric coords')

    -- (c) control characters in the label are sanitised, heading is wrapped
    client1.TriggerServerEvent('mission:coords', 'a\nb\tc', 1.0, 2.0, 3.0, 400.0)
    local list3 = dump()
    eq(#list3, 2, 'a sanitised label is still persisted')
    eq(list3[2].label, 'a b c', 'control characters must be replaced')
    ok(not list3[2].label:find('%c'), 'no control character may survive')
    near(list3[2].h, 40.0, 'heading wrapped into 0..360')

    -- (d) an empty label becomes "unlabelled"
    client1.TriggerServerEvent('mission:coords', '   ', 1.0, 2.0, 3.0, 0.0)
    local list4 = dump()
    eq(#list4, 3, 'record count')
    eq(list4[3].label, 'unlabelled', 'empty label fallback')
    noErrors('coords sanitising')
end)

-- ===========================================================================
-- 9. Argument validation — nothing may error
-- ===========================================================================

test('09 bad command arguments print usage/warnings and never raise', function()
    reset()
    Mock.runCommand(server, 'mo_spawn A 5')     -- so squad A/1 exists for mo_move
    tickClients(1)

    local cases = {
        'mo_spawn Z',
        'mo_spawn A 0',
        'mo_spawn A 999',
        'mo_move A 1 abc 2 3',
        'mo_hold A 99',
    }

    for _, line in ipairs(cases) do
        Mock.clearOutput()
        Mock.clearErrors()
        local okRun = Mock.runCommand(server, line)
        ok(okRun, '/%s raised a Lua error', line)
        noErrors('/' .. line)
        local sawUsage = Mock.outputMatches('usage:')
        local sawWarn  = Mock.outputMatches('WARN')
        ok(sawUsage or sawWarn,
            '/%s produced neither a usage line nor a warning\n--- output ---\n%s', line, Mock.outputText())
    end

    -- and none of them may have spawned or disturbed anything
    eq(#missionPeds(), 5, 'ped count unchanged by invalid commands')
end)

-- ===========================================================================
-- 10. attack-move supervision
-- ===========================================================================

test('10 amove supervision engages once, does not re-task, and resumes the goto', function()
    reset()
    Mock.runCommand(server, 'mo_spawn A 1')
    Mock.runCommand(server, 'mo_spawn B 1')
    tickClients(1)

    local pedA = notNil(firstPedOfFaction('A'), 'faction A ped')
    local pedB = notNil(firstPedOfFaction('B'), 'faction B ped')

    -- Put the enemy well inside Config.Combat.engageRadius (80 m).
    Mock.setCoords(pedB.handle, pedA.coords.x + 10.0, pedA.coords.y, pedA.coords.z)
    ok(Config.Combat.engageRadius > 10.0, 'fixture assumes engageRadius > 10 m')

    Mock.runCommand(server, ('mo_amove A 1 %.1f %.1f %.1f'):format(FAR.x, FAR.y, FAR.z))
    Mock.clearLog()
    tickClients(1)

    eq(countFor('client1', 'TaskCombatPed', pedA.handle), 1, 'engaged the hostile once')
    eq(Mock.calls({ ctx = 'client1', name = 'TaskCombatPed', arg1 = pedA.handle })[1].args[2], pedB.handle,
        'engaged the right target')

    -- Several more ticks with the same target must NOT re-task.
    tickClients(4)
    eq(countFor('client1', 'TaskCombatPed', pedA.handle), 1,
        'TaskCombatPed must not be re-issued every tick while the target is unchanged')

    -- Remove the enemy: the ped must resume its advance.
    Mock.clearLog()
    Mock.destroyPed(pedB.handle)
    tickClients(1)
    ok(countFor('client1', 'TaskGoToCoordAnyMeans', pedA.handle) >= 1,
        'the ped must resume its goto once no hostile is in radius')

    -- ...and then settle: no re-task storm on subsequent ticks.
    Mock.clearLog()
    tickClients(3)
    eq(countFor('client1', 'TaskGoToCoordAnyMeans', pedA.handle), 0,
        'the resumed goto must not be re-issued every tick')
    noErrors('supervision')
end)

-- ===========================================================================
-- 11. retreat suppresses combat attribute 5, the next order restores it
-- ===========================================================================

test('11 retreat clears combat attribute 5 and a following order restores it', function()
    reset()
    Mock.runCommand(server, 'mo_spawn A 1')
    tickClients(1)
    local ped = notNil(missionPeds()[1], 'the spawned ped')

    Mock.clearLog()
    Mock.runCommand(server, 'mo_retreat A 1')
    tickClients(1)
    eq(Mock.getState(ped.handle, 'mo').t, 'retreat', 'order type')

    local function attrCall(value)
        for _, c in ipairs(callsFor('client1', 'SetPedCombatAttributes', ped.handle)) do
            if c.args[2] == 5 and c.args[3] == value then return c end
        end
        return nil
    end

    notNil(attrCall(false), 'retreat must call SetPedCombatAttributes(ped, 5, false)')
    ok(attrCall(true) == nil, 'retreat must not restore attribute 5 in the same breath')

    Mock.clearLog()
    Mock.runCommand(server, 'mo_hold A 1')
    tickClients(1)
    notNil(attrCall(true), 'the following order must restore SetPedCombatAttributes(ped, 5, true)')

    -- A second non-retreat order must not keep re-setting it (combatOff cleared).
    Mock.clearLog()
    Mock.runCommand(server, 'mo_hold A 1')
    tickClients(1)
    ok(attrCall(true) == nil, 'attribute 5 must only be restored once after a retreat')
    noErrors('retreat/restore')
end)

-- ===========================================================================
-- 12. population-ctl
-- ===========================================================================

test('12 population-ctl suppresses density every frame and restores defaults on stop', function()
    reset()
    local popctl = Mock.makeEnv('popctl', { resource = 'population-ctl', side = 'client', player = 3 })
    popctl.Config = Config
    Mock.loadInto(popctl, MISSION .. '/population-ctl/client.lua')

    Mock.clearLog()
    Mock.advance(0)                              -- run the one-shot start thread

    local function once(nativeName, value)
        for _, c in ipairs(Mock.calls({ ctx = 'popctl', name = nativeName })) do
            if c.args[1] == value then return c end
        end
        return nil
    end

    notNil(once('SetCreateRandomCops', false), 'SetCreateRandomCops(false) at start')
    notNil(once('SetGarbageTrucks', false), 'SetGarbageTrucks(false) at start')
    notNil(once('SetRandomBoats', false), 'SetRandomBoats(false) at start')
    notNil(once('SetMaxWantedLevel', 0), 'SetMaxWantedLevel(0) at start')
    notNil(once('SetUserRadioControlEnabled', false), 'SetUserRadioControlEnabled(false) at start')
    eq(#Mock.calls({ ctx = 'popctl', name = 'EnableDispatchService' }), 15, 'dispatch services 1..15 disabled')
    for _, c in ipairs(Mock.calls({ ctx = 'popctl', name = 'EnableDispatchService' })) do
        eq(c.args[2], false, 'dispatch service ' .. tostring(c.args[1]) .. ' must be disabled')
    end

    -- Per-frame family
    Mock.clearLog()
    Mock.advance(160)                            -- ~10 simulated frames
    local frames = #Mock.calls({ ctx = 'popctl', name = 'SetPedDensityMultiplierThisFrame' })
    ok(frames >= 5, 'expected the per-frame loop to run repeatedly, got %d frames', frames)
    for _, nativeName in ipairs({
        'SetVehicleDensityMultiplierThisFrame',
        'SetRandomVehicleDensityMultiplierThisFrame',
        'SetParkedVehicleDensityMultiplierThisFrame',
        'SetScenarioPedDensityMultiplierThisFrame',
    }) do
        eq(#Mock.calls({ ctx = 'popctl', name = nativeName }), frames, nativeName .. ' call count')
    end
    for _, c in ipairs(Mock.calls({ ctx = 'popctl', name = 'SetPedDensityMultiplierThisFrame' })) do
        near(c.args[1], 0.0, 'ped density multiplier')
    end

    -- Restore on resource stop
    Mock.clearLog()
    popctl.TriggerEvent('onClientResourceStop', 'population-ctl')
    notNil(once('SetCreateRandomCops', true), 'SetCreateRandomCops(true) on stop')
    notNil(once('SetGarbageTrucks', true), 'SetGarbageTrucks(true) on stop')
    notNil(once('SetRandomBoats', true), 'SetRandomBoats(true) on stop')
    notNil(once('SetMaxWantedLevel', 5), 'SetMaxWantedLevel(5) on stop')
    notNil(once('SetUserRadioControlEnabled', true), 'SetUserRadioControlEnabled(true) on stop')
    eq(#Mock.calls({ ctx = 'popctl', name = 'EnableDispatchService' }), 15, 'dispatch services re-enabled')
    for _, c in ipairs(Mock.calls({ ctx = 'popctl', name = 'EnableDispatchService' })) do
        eq(c.args[2], true, 'dispatch service ' .. tostring(c.args[1]) .. ' must be re-enabled')
    end

    -- A stop event for a different resource must be ignored.
    Mock.clearLog()
    popctl.TriggerEvent('onClientResourceStop', 'some-other-resource')
    eq(#Mock.calls({ ctx = 'popctl', name = 'SetMaxWantedLevel' }), 0,
        'onClientResourceStop for another resource must be ignored')
    noErrors('population-ctl')
end)

-- ===========================================================================
-- Pending / not modelled
-- ===========================================================================

-- Corpse leak. The ownership audit (mission-core/server.lua:520-533) evicts a
-- ped with health <= 0 from `units`, but never deletes the entity; clearAll()
-- (server.lua:266-287) only walks `units` and `poolPeds`. A ped that dies is
-- therefore unreachable by /mo_clear and its body stays in the world for the
-- rest of the session. ENGINE-SPEC §4 says the audit must "remove from registry,
-- log" (it does) and that /mo_clear must "delete all mission entities" (it
-- cannot). The spec does not say which side should own the corpse, so the code
-- is left alone and this is reported instead of fixed.
test('13 a corpse evicted by the audit is still deleted by /mo_clear', function()
    reset()
    Mock.runCommand(server, 'mo_spawn A 5')
    tickClients(1)

    auditSeesAlive()

    local victim = notNil(pedBySlot(missionPeds(), 2), 'slot 2 ped')
    Mock.setHealth(victim.handle, 0)
    Mock.advance(AUDIT_TICK + 100)   -- audit evicts it from the registry

    ok(Mock.pedExists(victim.handle),
        'the body must still exist right after eviction (it lingers for the camera)')

    Mock.runCommand(server, 'mo_clear')
    ok(not Mock.pedExists(victim.handle),
        '/mo_clear must delete the evicted corpse, not only registered units')
    eq(#Mock.livePedsCreatedBy('server'), 0, 'server-created peds left after /mo_clear')
end)

test('14 a corpse is reaped automatically once Config.CorpseLingerMs elapses', function()
    reset()
    Mock.runCommand(server, 'mo_spawn A 5')
    tickClients(1)

    auditSeesAlive()

    local victim = notNil(pedBySlot(missionPeds(), 2), 'slot 2 ped')
    Mock.setHealth(victim.handle, 0)
    Mock.advance(AUDIT_TICK + 100)

    local linger = tonumber(Config.CorpseLingerMs) or 0
    ok(linger > 0, 'Config.CorpseLingerMs must be a positive duration')
    ok(Mock.pedExists(victim.handle), 'the body must survive the audit pass that evicts it')

    -- Halfway through the linger window the body is still there.
    Mock.advance(linger / 2)
    ok(Mock.pedExists(victim.handle), 'the body must still exist mid-linger')

    -- Past the window, the audit reaps it without any operator command.
    Mock.advance(linger / 2 + AUDIT_TICK * 2)
    ok(not Mock.pedExists(victim.handle),
        'the audit must delete the body once the linger window has passed')
    noErrors('corpse reaping')
end)

-- ===========================================================================
-- 15. Spawn with nobody in scope — the production blocker (build 35245, OneSync)
-- ===========================================================================

-- On the real server every unit of /test_m1 was culled in its own creation
-- frame ("dead or missing at order time") and /mo_engage then reported
-- "0 squad(s), 0 unit(s)". A server-created ped is not instantiated until a
-- client pulls it in, so it reads health 0 (and possibly non-existent) first.
test('15 spawn with no client in scope registers and orders every unit anyway', function()
    reset()
    Mock.autoInstantiate = false                 -- no client ever comes into scope
    Mock.runCommand(server, 'mo_spawn A 5')
    noErrors('mo_spawn with no client in scope')

    local peds = missionPeds()
    eq(#peds, 5, 'ped count')
    for _, p in ipairs(peds) do
        ok(not Mock.isInstantiated(p.handle), 'fixture: ped %s must still be un-instantiated', p.handle)
        eq(server.GetEntityHealth(p.handle), 0, 'fixture: an un-instantiated ped reads health 0')
    end

    -- The production signature: the registry entry deleted in the creation frame.
    ok(not Mock.outputMatches('removed from registry'),
        'no unit may be culled in its own creation frame\n--- output ---\n%s', Mock.outputText())

    for _, p in ipairs(peds) do
        local mo = notNil(Mock.getState(p.handle, 'mo'), 'mo bag for ped ' .. p.handle)
        eq(mo.t, 'hold', 'initial order type')
        ok(Mock.isReplicated(p.handle, 'mo'), 'mo must be written replicated=true')
    end

    Mock.clearOutput()
    Mock.runCommand(server, 'mo_status')
    outputHas('squad A/1  alive=0/5', 'mo_status must show 5 registered, none alive yet')

    Mock.clearOutput()
    Mock.runCommand(server, 'mo_engage')
    outputHas('attack%-move issued to 1 squad%(s%), 5 unit%(s%)',
        'mo_engage must still find the squad (production reported 0 squad(s), 0 unit(s))')
    noErrors('mo_engage')
end)

-- ===========================================================================
-- 16. ...and they start acting the moment a client instantiates them
-- ===========================================================================

test('16 units spawned with nobody in scope start acting once a client instantiates them', function()
    reset()
    Mock.autoInstantiate = false
    Mock.runCommand(server, 'mo_spawn A 5')
    local peds = missionPeds()
    eq(#peds, 5, 'ped count')

    -- Nothing can be tasked while no client holds the ped.
    tickClients(2)
    for _, p in ipairs(peds) do
        eq(countFor('client1', 'TaskGuardCurrentPosition', p.handle), 0,
            'an un-instantiated ped must not be tasked')
    end
    ok(not Mock.outputMatches('removed from registry'),
        'no unit may be culled while it is merely waiting to be instantiated\n%s', Mock.outputText())

    -- A client comes into scope.
    Mock.instantiateAll()
    Mock.clearOutput()
    tickClients(1)

    for _, p in ipairs(peds) do
        eq(countFor('client1', 'TaskGuardCurrentPosition', p.handle), 1,
            'hold applied for ped ' .. p.handle .. ' once instantiated')
        eq(countFor('client1', 'TaskCombatHatedTargetsAroundPed', p.handle), 1,
            'hold pair applied for ped ' .. p.handle)
    end

    Mock.advance(AUDIT_TICK + 100)
    Mock.clearOutput()
    Mock.runCommand(server, 'mo_status')
    outputHas('squad A/1  alive=5/5', 'all five must now be alive')
    noErrors('late instantiation')
end)

-- ===========================================================================
-- 17. A ped nobody ever instantiates is reaped, not leaked
-- ===========================================================================

test('17 a unit that never instantiates is culled after Config.SpawnGraceMs and its entity deleted', function()
    reset()
    local grace = tonumber(Config.SpawnGraceMs) or 0
    ok(grace > 0, 'Config.SpawnGraceMs must be a positive duration')

    Mock.autoInstantiate = false
    Mock.runCommand(server, 'mo_spawn A 3')
    local peds = missionPeds()
    eq(#peds, 3, 'ped count')

    -- Still registered halfway through the window.
    Mock.advance(grace / 2)
    ok(not Mock.outputMatches('removed from registry'),
        'a unit inside its grace window must not be culled\n%s', Mock.outputText())

    Mock.clearOutput()
    Mock.advance(grace / 2 + AUDIT_TICK * 2)
    outputHas('no client ever instantiated it', 'the cull must name the likely cause')
    Mock.runCommand(server, 'mo_status')
    outputHas('squad A/1  alive=0/0', 'the squad must now be empty, not missing')

    -- ...and the bodies go through the corpse path rather than leaking.
    for _, p in ipairs(peds) do
        ok(Mock.pedExists(p.handle), 'the entity is reaped by the corpse path, not dropped on the floor')
    end
    Mock.advance((tonumber(Config.CorpseLingerMs) or 0) + AUDIT_TICK * 2)
    for _, p in ipairs(peds) do
        ok(not Mock.pedExists(p.handle), 'ped %s leaked: never instantiated and never deleted', p.handle)
    end
    eq(#missionPeds(), 0, 'no server-created ped may survive the grace cull')
    noErrors('grace reaping')
end)

-- ===========================================================================
-- 18. The other pre-instantiation variant: DoesEntityExist reads false
-- ===========================================================================

-- The production report could not tell whether the fresh ped reads health 0 or
-- non-existent, so both variants must behave.
test('18 a ped that is not even queryable before instantiation is still registered and ordered', function()
    reset()
    Mock.autoInstantiate           = false
    Mock.existsBeforeInstantiation = false
    Mock.runCommand(server, 'mo_spawn A 5')
    noErrors('mo_spawn with unqueryable peds')

    local peds = missionPeds()
    eq(#peds, 5, 'CreatePed must not be treated as failed')
    outputHas('not queryable in its creation frame', 'the condition must be reported, not silently swallowed')
    ok(not Mock.outputMatches('removed from registry'), 'no cull in the creation frame\n%s', Mock.outputText())

    for _, p in ipairs(peds) do
        local mo = notNil(Mock.getState(p.handle, 'mo'), 'mo bag for ped ' .. p.handle)
        eq(mo.t, 'hold', 'initial order type')
    end

    Mock.clearOutput()
    Mock.runCommand(server, 'mo_engage')
    outputHas('attack%-move issued to 1 squad%(s%), 5 unit%(s%)', 'mo_engage must find the squad')

    -- A client arrives: the units become alive and are never culled.
    Mock.existsBeforeInstantiation = true
    Mock.instantiateAll()
    Mock.advance(AUDIT_TICK + 100)
    Mock.clearOutput()
    Mock.runCommand(server, 'mo_status')
    outputHas('squad A/1  alive=5/5', 'all five alive after instantiation')
    noErrors('unqueryable variant')
end)

-- ===========================================================================
-- 19. /mo_status tells "no squads" apart from "squads with nothing left alive"
-- ===========================================================================

test('19 /mo_status distinguishes no squads from a squad whose units were all culled', function()
    reset()
    Mock.runCommand(server, 'mo_status')
    outputHas('no squads registered', 'an empty registry must say so')

    Mock.clearOutput()
    Mock.runCommand(server, 'mo_spawn A 3')
    tickClients(1)
    auditSeesAlive()
    for _, p in ipairs(missionPeds()) do Mock.setHealth(p.handle, 0) end
    Mock.advance(AUDIT_TICK + 100)

    Mock.clearOutput()
    Mock.runCommand(server, 'mo_status')
    outputHas('squad A/1  alive=0/0', 'a wiped-out squad must still be listed')
    outputHas('totals: 1 squad%(s%), 0 unit%(s%) registered, 0 alive', 'totals line')
    ok(not Mock.outputMatches('no squads registered'),
        '"no squads registered" must not be printed while squad A/1 exists\n%s', Mock.outputText())

    -- mo_engage keeps the skip-empty behaviour: there is nothing to order.
    Mock.clearOutput()
    Mock.runCommand(server, 'mo_engage')
    outputHas('issued to 0 squad%(s%), 0 unit%(s%)', 'mo_engage must skip the empty bucket')
    noErrors('status reporting')
end)

-- ===========================================================================
-- 20. Self-heal: a unit left without an order gets one from the audit
-- ===========================================================================

test('20 the audit re-applies hold to a unit whose initial state-bag write failed', function()
    reset()
    -- The `mo` write is the one that can fail against a not-yet-instantiated
    -- entity; `mu` is left alone so the unit is still identifiable.
    Mock.bagWriteBlocked = function(_, key) return key == 'mo' end
    Mock.runCommand(server, 'mo_spawn A 2')
    noErrors('mo_spawn with a failing state bag')

    local peds = missionPeds()
    eq(#peds, 2, 'ped count')
    for _, p in ipairs(peds) do
        ok(Mock.getState(p.handle, 'mo') == nil, 'fixture: the mo write must have failed')
    end
    outputHas('state bag write failed', 'the failed write must be reported')
    outputHas('initial hold not published', 'the spawn report must admit the unit has no order')
    outputHas('registered unit%(s%) have no order yet', 'the spawn summary must not claim success')

    Mock.bagWriteBlocked = nil
    Mock.clearOutput()
    -- Clear the call log BEFORE the window, never inside it: the audit pass that
    -- re-applies the order and the client tick that acts on it can land in the
    -- same window, and mission-ai deliberately applies a given seq only once
    -- (tests 04/05), so a log cleared in between would erase the only evidence
    -- and the next tick would legitimately show nothing.
    Mock.clearLog()
    -- Peds instantiate, the audit notices the missing order and retries it, and
    -- the owning client applies what the audit published.
    Mock.advance(AUDIT_TICK * 2 + CLIENT_TICK * 2)
    outputHas('re%-applied hold', 'the audit must retry the missing order')

    for _, p in ipairs(peds) do
        local mo = notNil(Mock.getState(p.handle, 'mo'), 'mo bag for ped ' .. p.handle)
        eq(mo.t, 'hold', 'self-healed order type')
    end

    for _, p in ipairs(peds) do
        eq(countFor('client1', 'TaskGuardCurrentPosition', p.handle), 1,
            'the self-healed hold must reach the owning client exactly once')
    end
    noErrors('self-heal')
end)

-- Real-server-only behaviour this harness deliberately cannot model:
--   * whether the native enum values marked "VERIFY in-game" are correct
--     (combat attributes 0/5/46/58, combat ability/range/movement, dispatch
--     service ids, the 'DisableFlightMusic' audio flag string)
--   * whether server-side CREATE_PED really takes a leading pedType
--   * actual OneSync migration timing, ped pathing, ground geometry and
--     GetGroundZFor_3dCoord results, and real combat outcomes
--   * ACE permission enforcement on the restricted commands
--   * T2 performance (FPS / resmon) under /test_pool load

-- ===========================================================================
-- Runner
-- ===========================================================================

local passed, failed = 0, 0
local failures = {}

io.write('mission-engine offline runtime suite (lua ', _VERSION, ')\n')
io.write(('%s\n'):format(string.rep('-', 78)))

for _, t in ipairs(tests) do
    Mock.clearErrors()
    local okRun, err = xpcall(t.fn, function(e)
        return tostring(e) .. '\n' .. debug.traceback('', 3)
    end)
    if okRun then
        passed = passed + 1
        io.write(('PASS  %s\n'):format(t.name))
    else
        failed = failed + 1
        failures[#failures + 1] = { name = t.name, err = err }
        io.write(('FAIL  %s\n'):format(t.name))
        for line in tostring(err):gmatch('[^\n]+') do
            io.write(('        %s\n'):format(line))
        end
    end
end

for _, p in ipairs(pendings) do
    io.write(('PEND  %s  (%s)\n'):format(p.name, p.why))
end

io.write(('%s\n'):format(string.rep('-', 78)))
io.write(('%d passed, %d failed, %d pending, %d total\n'):format(passed, failed, #pendings, #tests))

if failed > 0 then
    io.write('\nFAILURES:\n')
    for _, f in ipairs(failures) do
        io.write((' - %s\n'):format(f.name))
    end
    os.exit(1)
end
os.exit(0)
