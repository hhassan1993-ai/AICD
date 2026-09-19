--[[===========================================================================
  tests/fivem_mock.lua — offline FiveM runtime mock

  Purpose: actually EXECUTE the mission-engine Lua (server + N clients) against a
  simulated world, a virtual clock and a shared state-bag store, so behaviour can
  be asserted. No FXServer, no game client, no real time.

  Design notes
  ------------
  * One world, many Lua environments. `Mock.makeEnv()` builds a fresh `_ENV`
    holding its own natives (so every recorded call is attributed to the env that
    made it) but every env talks to the SAME world/state-bag/scheduler tables.
    That is what makes ownership migration (risk T1) testable offline.
  * Unimplemented natives raise instead of returning nil: any unknown global that
    looks like a native (leading capital) becomes a function that errors with its
    own name, so the harness tells you exactly what is missing.
  * Virtual clock only. A 90 s in-game Wait() completes in microseconds.
  * Instantiation is modelled. A ped created server-side is NOT instantiated in
    its creation frame: no client holds it yet, so `GetEntityHealth` reads 0,
    `IsPedDeadOrDying` reads true, the ped is absent from every client's
    `GetGamePool('CPed')`, and `DoesEntityExist` reads whatever
    `Mock.existsBeforeInstantiation` says (true by default — the real server was
    observed registering the ped, so the handle is queryable; flip it to false to
    exercise the other variant). `Mock.autoInstantiate` (default true) then
    instantiates the ped on the first clock advance past its creation frame,
    which is "a client is in scope and pulls it in". Set it to false to model a
    spawn point no client ever reaches, and call `Mock.instantiatePed` /
    `Mock.instantiateAll` to bring peds in by hand.
===========================================================================]]

local Mock = {}

local unpack = table.unpack

-- ---------------------------------------------------------------------------
-- vector3 / vector4
-- ---------------------------------------------------------------------------

local vec3mt, vec4mt = {}, {}

local function vector3(x, y, z)
    return setmetatable({ x = (x or 0) + 0.0, y = (y or 0) + 0.0, z = (z or 0) + 0.0 }, vec3mt)
end

local function vector4(x, y, z, w)
    return setmetatable({ x = (x or 0) + 0.0, y = (y or 0) + 0.0, z = (z or 0) + 0.0, w = (w or 0) + 0.0 }, vec4mt)
end

local function len3(v) return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) end

vec3mt.__index    = vec3mt
vec3mt.__name     = 'vector3'
vec3mt.__sub      = function(a, b) return vector3(a.x - b.x, a.y - b.y, a.z - b.z) end
vec3mt.__add      = function(a, b) return vector3(a.x + b.x, a.y + b.y, a.z + b.z) end
vec3mt.__len      = len3
vec3mt.__eq       = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
vec3mt.__tostring = function(v) return ('vector3(%.4f, %.4f, %.4f)'):format(v.x, v.y, v.z) end

vec4mt.__index    = vec4mt
vec4mt.__name     = 'vector4'
vec4mt.__sub      = function(a, b) return vector3(a.x - b.x, a.y - b.y, a.z - b.z) end
vec4mt.__add      = function(a, b) return vector3(a.x + b.x, a.y + b.y, a.z + b.z) end
vec4mt.__len      = len3
vec4mt.__eq       = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z and a.w == b.w end
vec4mt.__tostring = function(v) return ('vector4(%.4f, %.4f, %.4f, %.4f)'):format(v.x, v.y, v.z, v.w) end

Mock.vector3 = vector3
Mock.vector4 = vector4

-- ---------------------------------------------------------------------------
-- Minimal JSON (flat arrays of flat records is all the engine stores)
-- ---------------------------------------------------------------------------

local json = {}

local ESCAPES = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function encodeString(s)
    return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
        return ESCAPES[c] or ('\\u%04x'):format(c:byte())
    end) .. '"'
end

local function isArray(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= 'number' or k < 1 or k ~= math.floor(k) then return false end
        n = n + 1
    end
    return n == #t
end

local function encodeValue(v)
    local tv = type(v)
    if v == nil then return 'null' end
    if tv == 'boolean' then return tostring(v) end
    if tv == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then error('json: non-finite number') end
        if math.type(v) == 'integer' then return tostring(v) end
        return ('%.14g'):format(v)
    end
    if tv == 'string' then return encodeString(v) end
    if tv == 'table' then
        local parts = {}
        if isArray(v) then
            for i = 1, #v do parts[#parts + 1] = encodeValue(v[i]) end
            return '[' .. table.concat(parts, ',') .. ']'
        end
        -- deterministic key order so the file diffs cleanly
        local keys = {}
        for k in pairs(v) do
            if type(k) ~= 'string' then error('json: non-string object key') end
            keys[#keys + 1] = k
        end
        table.sort(keys)
        for i = 1, #keys do
            parts[#parts + 1] = encodeString(keys[i]) .. ':' .. encodeValue(v[keys[i]])
        end
        return '{' .. table.concat(parts, ',') .. '}'
    end
    error('json: cannot encode ' .. tv)
end

function json.encode(v) return encodeValue(v) end

local decodeValue

local function skipWs(s, i)
    local _, j = s:find('^[ \t\r\n]*', i)
    return (j or i - 1) + 1
end

local UNESCAPES = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

local function decodeString(s, i)
    assert(s:sub(i, i) == '"', 'json: expected string at ' .. i)
    i = i + 1
    local out = {}
    while true do
        local c = s:sub(i, i)
        if c == '' then error('json: unterminated string') end
        if c == '"' then return table.concat(out), i + 1 end
        if c == '\\' then
            local e = s:sub(i + 1, i + 1)
            if e == 'u' then
                local hex = s:sub(i + 2, i + 5)
                out[#out + 1] = utf8.char(tonumber(hex, 16) or 63)
                i = i + 6
            else
                out[#out + 1] = UNESCAPES[e] or e
                i = i + 2
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
end

decodeValue = function(s, i)
    i = skipWs(s, i)
    local c = s:sub(i, i)
    if c == '' then error('json: unexpected end of input') end
    if c == '{' then
        local obj = {}
        i = skipWs(s, i + 1)
        if s:sub(i, i) == '}' then return obj, i + 1 end
        while true do
            local k, v
            i = skipWs(s, i)
            k, i = decodeString(s, i)
            i = skipWs(s, i)
            assert(s:sub(i, i) == ':', 'json: expected :')
            v, i = decodeValue(s, i + 1)
            obj[k] = v
            i = skipWs(s, i)
            local d = s:sub(i, i)
            if d == ',' then i = i + 1
            elseif d == '}' then return obj, i + 1
            else error('json: expected , or } at ' .. i) end
        end
    elseif c == '[' then
        local arr = {}
        i = skipWs(s, i + 1)
        if s:sub(i, i) == ']' then return arr, i + 1 end
        while true do
            local v
            v, i = decodeValue(s, i)
            arr[#arr + 1] = v
            i = skipWs(s, i)
            local d = s:sub(i, i)
            if d == ',' then i = i + 1
            elseif d == ']' then return arr, i + 1
            else error('json: expected , or ] at ' .. i) end
        end
    elseif c == '"' then
        return decodeString(s, i)
    elseif s:sub(i, i + 3) == 'true' then
        return true, i + 4
    elseif s:sub(i, i + 4) == 'false' then
        return false, i + 5
    elseif s:sub(i, i + 3) == 'null' then
        return nil, i + 4
    else
        local num = s:match('^%-?%d+%.?%d*[eE]?[%+%-]?%d*', i)
        if not num or num == '' then error('json: unexpected character ' .. c .. ' at ' .. i) end
        return tonumber(num), i + #num
    end
end

function json.decode(str)
    assert(type(str) == 'string', 'json.decode: expected string')
    local v, i = decodeValue(str, 1)
    i = skipWs(str, i)
    assert(i > #str, 'json: trailing garbage')
    return v
end

Mock.json = json

-- ---------------------------------------------------------------------------
-- Virtual clock + cooperative scheduler
-- ---------------------------------------------------------------------------

local clock      = 0      -- virtual milliseconds
local frameMs    = 16     -- Wait(0) == "next frame"
local threads    = {}     -- { { co, wake, id, ctx } }
local threadSeq  = 0

Mock.errors = {}          -- { { ctx, message } } — thread/command errors, never swallowed silently

function Mock.now() return clock end
function Mock.setFrameMs(ms) frameMs = ms end

local function spawnThread(ctx, fn)
    threadSeq = threadSeq + 1
    local co = coroutine.create(fn)
    threads[#threads + 1] = { co = co, wake = clock, id = threadSeq, ctx = ctx }
    return co
end

local function resumeThread(t)
    local ok, res = coroutine.resume(t.co)
    if not ok then
        local msg = ('[%s] thread error: %s'):format(t.ctx, tostring(res))
        Mock.errors[#Mock.errors + 1] = { ctx = t.ctx, message = tostring(res) }
        io.stderr:write(msg .. '\n')
        t.dead = true
        return
    end
    if coroutine.status(t.co) == 'dead' then
        t.dead = true
        return
    end
    local ms = tonumber(res) or 0
    if ms <= 0 then ms = frameMs end
    t.wake = clock + ms
end

--- Advance the virtual clock by `ms`, resuming every thread that becomes due.
--- Never sleeps in real time.
function Mock.advance(ms)
    local target = clock + (tonumber(ms) or 0)
    local guard = 0
    while true do
        guard = guard + 1
        if guard > 200000 then error('Mock.advance: scheduler did not converge (runaway Wait(0) loop?)') end

        -- compact dead threads
        for i = #threads, 1, -1 do
            if threads[i].dead or coroutine.status(threads[i].co) == 'dead' then
                table.remove(threads, i)
            end
        end

        local nextWake
        for i = 1, #threads do
            local w = threads[i].wake
            if not nextWake or w < nextWake then nextWake = w end
        end
        if not nextWake or nextWake > target then break end

        if nextWake > clock then
            clock = nextWake
            -- A new frame started: peds created in an earlier frame can now be
            -- instantiated by a client in scope. Defined further down the file.
            if Mock.autoInstantiateDue then Mock.autoInstantiateDue() end
        end

        local snapshot = {}
        for i = 1, #threads do snapshot[i] = threads[i] end
        table.sort(snapshot, function(a, b)
            if a.wake ~= b.wake then return a.wake < b.wake end
            return a.id < b.id
        end)
        for i = 1, #snapshot do
            local t = snapshot[i]
            if not t.dead and t.wake <= clock and coroutine.status(t.co) == 'suspended' then
                resumeThread(t)
            end
        end
    end
    local moved = target > clock
    clock = target
    if moved and Mock.autoInstantiateDue then Mock.autoInstantiateDue() end
end

--- Run every thread that is due right now without moving the clock forward.
function Mock.pump() Mock.advance(0) end

-- ---------------------------------------------------------------------------
-- World model
-- ---------------------------------------------------------------------------

local world = {
    peds      = {},   -- [handle] = pedRecord
    pedOrder  = {},   -- creation-ordered list of handles (live only)
    nextHandle = 1000,
    nextNetId  = 1,
}

Mock.world         = world
Mock.defaultOwner  = 1   -- server id of the client that owns freshly created peds
Mock.groundZFor    = function(_, _, z) return true, z - 1.0 end  -- no snap by default

--- Instantiation model (see the header). Both knobs are global to the world and
--- are reset per test by run_tests.lua's reset().
Mock.autoInstantiate           = true   -- a client pulls peds in one frame after creation
Mock.existsBeforeInstantiation = true   -- DoesEntityExist for a not-yet-instantiated ped
Mock.spawnHealth               = 200    -- health a ped gets the moment it instantiates

local function newPed(ctx, model, x, y, z, heading)
    world.nextHandle = world.nextHandle + 1
    world.nextNetId  = world.nextNetId + 1
    local ped = {
        handle   = world.nextHandle,
        netId    = world.nextNetId,
        model    = model,
        coords   = vector3(x, y, z),
        heading  = (tonumber(heading) or 0.0) + 0.0,
        -- Not instantiated yet: no client owns the model, so health reads 0.
        health   = 0,
        instantiated = false,
        createdAt = clock,
        armour   = 0,
        owner    = Mock.defaultOwner,
        exists   = true,
        createdBy = ctx,
        combatTarget = nil,
        weapons  = {},
    }
    world.peds[ped.handle] = ped
    world.pedOrder[#world.pedOrder + 1] = ped.handle
    return ped
end

local function pedOf(handle)
    local p = world.peds[handle]
    if p and p.exists then return p end
    return nil
end

local function destroyPed(handle)
    local p = world.peds[handle]
    if not p then return false end
    p.exists = false
    for i = #world.pedOrder, 1, -1 do
        if world.pedOrder[i] == handle then table.remove(world.pedOrder, i) end
    end
    return true
end

Mock.newPed     = newPed
Mock.pedOf      = pedOf
Mock.destroyPed = destroyPed

--- True while the ped is still in the world (not deleted). Unlike the
--- DoesEntityExist native this ignores instantiation: it answers "is this ped
--- still holding a pool slot", which is what the leak tests need to know.
function Mock.pedExists(handle)
    return pedOf(handle) ~= nil
end

--- A client came into scope and instantiated this ped: it now has real health
--- and shows up in GetGamePool('CPed'). Idempotent, so a ped that instantiated
--- and was then killed is not resurrected.
function Mock.instantiatePed(handle)
    local p = world.peds[handle]
    assert(p, 'Mock.instantiatePed: no such ped ' .. tostring(handle))
    if p.instantiated then return p end
    p.instantiated = true
    if p.health <= 0 then p.health = Mock.spawnHealth end
    return p
end

--- Instantiate every ped still in the world.
function Mock.instantiateAll()
    for i = 1, #world.pedOrder do
        Mock.instantiatePed(world.pedOrder[i])
    end
end

--- True once a client has instantiated this ped.
function Mock.isInstantiated(handle)
    local p = pedOf(handle)
    return p ~= nil and p.instantiated == true
end

--- Instantiate every ped created in an earlier frame ("a client is in scope").
local function autoInstantiateDue()
    if not Mock.autoInstantiate then return end
    for i = 1, #world.pedOrder do
        local p = world.peds[world.pedOrder[i]]
        if p and not p.instantiated and p.createdAt < clock then
            Mock.instantiatePed(p.handle)
        end
    end
end
Mock.autoInstantiateDue = autoInstantiateDue

function Mock.livePeds()
    local out = {}
    for i = 1, #world.pedOrder do out[#out + 1] = world.peds[world.pedOrder[i]] end
    return out
end

function Mock.livePedsCreatedBy(ctx)
    local out = {}
    for _, p in ipairs(Mock.livePeds()) do
        if p.createdBy == ctx then out[#out + 1] = p end
    end
    return out
end

function Mock.setOwner(handle, owner)
    local p = world.peds[handle]
    assert(p, 'Mock.setOwner: no such ped ' .. tostring(handle))
    p.owner = owner
end

function Mock.setHealth(handle, hp)
    local p = world.peds[handle]
    assert(p, 'Mock.setHealth: no such ped ' .. tostring(handle))
    p.health = hp
end

function Mock.setCoords(handle, x, y, z)
    local p = world.peds[handle]
    assert(p, 'Mock.setCoords: no such ped ' .. tostring(handle))
    p.coords = vector3(x, y, z)
end

-- ---------------------------------------------------------------------------
-- State bags (shared by the server and every client — the whole T1 design)
-- ---------------------------------------------------------------------------

local bagStore = {}   -- [handle] = { key = value }
Mock.bagStore = bagStore

local function deepCopy(v, seen)
    if type(v) ~= 'table' then return v end
    if getmetatable(v) == vec3mt then return vector3(v.x, v.y, v.z) end
    if getmetatable(v) == vec4mt then return vector4(v.x, v.y, v.z, v.w) end
    seen = seen or {}
    if seen[v] then return seen[v] end
    local out = {}
    seen[v] = out
    for k, val in pairs(v) do out[deepCopy(k, seen)] = deepCopy(val, seen) end
    return out
end
Mock.deepCopy = deepCopy

--- Optional hook: `Mock.bagWriteBlocked(handle, key)` returning true makes that
--- state-bag write raise, the way a write to a not-yet-instantiated entity can.
--- The engine wraps every write in pcall, so this exercises the failure branch.
Mock.bagWriteBlocked = nil

local bagMeta = {}
bagMeta.__index = function(self, k)
    if k == 'set' then
        return function(bag, key, value, replicated)
            if Mock.bagWriteBlocked and Mock.bagWriteBlocked(bag.__handle, key) then
                error(('state bag write refused for entity %s key %q'):format(tostring(bag.__handle), tostring(key)), 2)
            end
            local store = bagStore[bag.__handle]
            if not store then
                store = {}
                bagStore[bag.__handle] = store
            end
            store[key] = deepCopy(value)
            bag.__replicated[key] = replicated and true or false
            return true
        end
    end
    local store = bagStore[rawget(self, '__handle')]
    if not store then return nil end
    return store[k]
end

local bagCache = {}

local function stateBagFor(handle)
    local bag = bagCache[handle]
    if not bag then
        bag = setmetatable({ __handle = handle, __replicated = {} }, bagMeta)
        bagCache[handle] = bag
    end
    return bag
end

local entityCache = {}

local function entityWrapper(handle)
    local e = entityCache[handle]
    if not e then
        e = { state = stateBagFor(handle) }
        entityCache[handle] = e
    end
    return e
end

function Mock.getState(handle, key)
    local store = bagStore[handle]
    return store and store[key] or nil
end

function Mock.isReplicated(handle, key)
    local bag = bagCache[handle]
    return bag and bag.__replicated[key] or false
end

-- ---------------------------------------------------------------------------
-- Call recorder
-- ---------------------------------------------------------------------------

local callLog = {}
Mock.callLog = callLog

local function record(ctx, name, ...)
    callLog[#callLog + 1] = { name = name, ctx = ctx, tick = clock, n = select('#', ...), args = { ... } }
end
Mock.record = record

function Mock.clearLog()
    for i = #callLog, 1, -1 do callLog[i] = nil end
end

--- Filter the call log. `filter` = { name=, ctx=, arg1= (first argument) }.
function Mock.calls(filter)
    filter = filter or {}
    local out = {}
    for i = 1, #callLog do
        local c = callLog[i]
        local ok = true
        if filter.name and c.name ~= filter.name then ok = false end
        if ok and filter.ctx and c.ctx ~= filter.ctx then ok = false end
        if ok and filter.arg1 ~= nil and c.args[1] ~= filter.arg1 then ok = false end
        if ok then out[#out + 1] = c end
    end
    return out
end

function Mock.countCalls(filter) return #Mock.calls(filter) end

-- ---------------------------------------------------------------------------
-- Captured console output
-- ---------------------------------------------------------------------------

Mock.output  = {}
Mock.verbose = os.getenv('MOCK_VERBOSE') == '1'

function Mock.clearOutput()
    for i = #Mock.output, 1, -1 do Mock.output[i] = nil end
end

function Mock.outputText() return table.concat(Mock.output, '\n') end

function Mock.outputMatches(pattern)
    for i = 1, #Mock.output do
        if Mock.output[i]:find(pattern) then return true, Mock.output[i] end
    end
    return false
end

function Mock.clearErrors()
    for i = #Mock.errors, 1, -1 do Mock.errors[i] = nil end
end

-- ---------------------------------------------------------------------------
-- Resource file store (LoadResourceFile / SaveResourceFile)
-- ---------------------------------------------------------------------------

local fileStore = {}   -- [resource .. '/' .. file] = string
Mock.fileStore = fileStore

function Mock.readResourceFile(res, file) return fileStore[res .. '/' .. file] end
function Mock.writeResourceFile(res, file, data) fileStore[res .. '/' .. file] = data end
function Mock.clearResourceFiles()
    for k in pairs(fileStore) do fileStore[k] = nil end
end

-- ---------------------------------------------------------------------------
-- Events + commands
-- ---------------------------------------------------------------------------

local envs = {}          -- [name] = env
Mock.envs = envs
Mock.serverEnv = nil

-- ---------------------------------------------------------------------------
-- Native tables
-- ---------------------------------------------------------------------------

-- Natives that only need to be recorded (no world side effect the engine reads
-- back). Listed explicitly so an unlisted native raises instead of no-op'ing.
local RECORD_ONLY = {
    -- ped configuration / combat tuning (§5.3)
    'SetPedAccuracy', 'SetPedSeeingRange', 'SetPedHearingRange',
    'SetPedCombatAbility', 'SetPedCombatRange', 'SetPedCombatMovement',
    'SetPedCombatAttributes', 'SetPedFleeAttributes', 'SetBlockingOfNonTemporaryEvents',
    'SetPedDropsWeaponsWhenDead', 'SetPedCanRagdoll', 'SetPedRelationshipGroupHash',
    'SetPedArmour', 'GiveWeaponToPed',
    -- relationship groups (§5.1)
    'AddRelationshipGroup', 'SetRelationshipBetweenGroups', 'RemoveRelationshipGroup',
    -- tasks with no state the engine reads back
    'TaskGuardCurrentPosition', 'TaskCombatHatedTargetsAroundPed', 'TaskStandStill',
    'TaskWanderStandard',
    -- population / dispatch / radio family (§6)
    'SetVehicleDensityMultiplierThisFrame', 'SetPedDensityMultiplierThisFrame',
    'SetRandomVehicleDensityMultiplierThisFrame', 'SetParkedVehicleDensityMultiplierThisFrame',
    'SetScenarioPedDensityMultiplierThisFrame', 'SetGarbageTrucks', 'SetRandomBoats',
    'SetCreateRandomCops', 'SetCreateRandomCopsNotOnScenarios', 'SetCreateRandomCopsOnScenarios',
    'EnableDispatchService', 'SetMaxWantedLevel', 'SetAudioFlag',
    'SetUserRadioControlEnabled', 'SetRadioToStationName',
    'SetPlayerWantedLevel', 'SetPlayerWantedLevelNow',
}

local LUA_BASE = {
    'assert', 'error', 'ipairs', 'next', 'pairs', 'pcall', 'xpcall', 'select',
    'setmetatable', 'getmetatable', 'rawget', 'rawset', 'rawequal', 'rawlen',
    'tonumber', 'tostring', 'type', 'unpack', 'require', 'load', 'utf8',
    'math', 'string', 'table', 'os', 'coroutine',
}

--- Stable non-cryptographic string hash. Real joaat is not required; only
--- stability and collision-freedom across the small set of names used here.
local function stableHash(s)
    s = tostring(s)
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 0x100000000
    end
    return h
end
Mock.stableHash = stableHash

--- Build one Lua environment (one "resource" on one "machine").
--- opts = { resource = 'mission-core', side = 'server'|'client', player = <server id> }
function Mock.makeEnv(name, opts)
    opts = opts or {}
    local resource = opts.resource or name
    local side     = opts.side or 'client'
    local playerId = opts.player or 1

    local env = {}
    local handlers = {}     -- [eventName] = { fn, ... }
    local commands = {}     -- [cmdName]  = { fn = , restricted = }
    env.__mockName      = name
    env.__mockResource  = resource
    env.__mockSide      = side
    env.__mockPlayer    = playerId
    env.__handlers      = handlers
    env.__commands      = commands

    for _, k in ipairs(LUA_BASE) do env[k] = _G[k] end
    env._G = env

    env.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        local line = table.concat(parts, '\t')
        Mock.output[#Mock.output + 1] = line
        if Mock.verbose then io.write(('[%s] %s\n'):format(name, line)) end
    end

    env.vector3 = vector3
    env.vector4 = vector4
    env.json    = json

    -- ---- scheduler -------------------------------------------------------
    local Citizen = {}
    Citizen.CreateThread = function(fn) return spawnThread(name, fn) end
    Citizen.Wait         = function(ms) return coroutine.yield(tonumber(ms) or 0) end
    Citizen.SetTimeout   = function(ms, fn)
        return spawnThread(name, function()
            coroutine.yield(tonumber(ms) or 0)
            fn()
        end)
    end
    Citizen.InvokeNative = function(h) error(('unimplemented native: Citizen.InvokeNative(%s)'):format(tostring(h)), 2) end
    setmetatable(Citizen, { __index = function(_, k)
        return function() error(('unimplemented native: Citizen.%s'):format(tostring(k)), 2) end
    end })
    env.Citizen      = Citizen
    env.CreateThread = Citizen.CreateThread
    env.Wait         = Citizen.Wait
    env.SetTimeout   = Citizen.SetTimeout

    -- ---- record-only natives --------------------------------------------
    for _, nativeName in ipairs(RECORD_ONLY) do
        env[nativeName] = function(...)
            record(name, nativeName, ...)
        end
    end

    -- ---- world natives ---------------------------------------------------
    env.GetHashKey = stableHash
    env.GetHashKeyNoThrow = stableHash

    env.Entity = function(handle) return entityWrapper(handle) end

    env.CreatePed = function(pedType, model, x, y, z, heading, isNetwork, bScriptHostPed)
        record(name, 'CreatePed', pedType, model, x, y, z, heading, isNetwork, bScriptHostPed)
        if type(pedType) ~= 'number' then
            error('CreatePed: server-side CREATE_PED expects a leading pedType (got ' .. type(pedType) .. ')', 2)
        end
        local p = newPed(name, model, x, y, z, heading)
        -- A client-created ped is instantiated on the machine that made it; a
        -- server-created one is not instantiated until a client pulls it in.
        if side ~= 'server' then Mock.instantiatePed(p.handle) end
        return p.handle
    end

    env.DoesEntityExist = function(h)
        local p = pedOf(h)
        if not p then return false end
        if not p.instantiated and not Mock.existsBeforeInstantiation then return false end
        return true
    end

    env.DeleteEntity = function(h)
        record(name, 'DeleteEntity', h)
        destroyPed(h)
    end

    env.GetEntityCoords = function(h)
        local p = pedOf(h)
        if not p then return vector3(0, 0, 0) end
        return vector3(p.coords.x, p.coords.y, p.coords.z)
    end

    env.GetEntityHealth = function(h)
        local p = pedOf(h)
        if not p then return 0 end
        -- Not instantiated: no client holds the model, so there is no health to
        -- report. This is the production blocker's likeliest shape.
        if not p.instantiated then return 0 end
        return p.health
    end

    env.GetEntityHeading = function(h)
        local p = pedOf(h)
        if not p then return 0.0 end
        return p.heading
    end

    env.SetEntityCoords = function(h, x, y, z, ...)
        record(name, 'SetEntityCoords', h, x, y, z, ...)
        local p = pedOf(h)
        if p then p.coords = vector3(x, y, z) end
    end

    env.SetEntityHeading = function(h, hdg)
        record(name, 'SetEntityHeading', h, hdg)
        local p = pedOf(h)
        if p then p.heading = (tonumber(hdg) or 0.0) + 0.0 end
    end

    env.IsPedDeadOrDying = function(h)
        local p = pedOf(h)
        if not p then return true end
        if not p.instantiated then return true end
        return p.health <= 0
    end

    env.GetGamePool = function(poolName)
        if poolName ~= 'CPed' then
            error(('unimplemented native: GetGamePool(%q)'):format(tostring(poolName)), 2)
        end
        -- Only instantiated peds are in a client's ped pool.
        local out = {}
        for i = 1, #world.pedOrder do
            local p = world.peds[world.pedOrder[i]]
            if p and p.instantiated then out[#out + 1] = p.handle end
        end
        return out
    end

    env.NetworkGetNetworkIdFromEntity = function(h)
        local p = pedOf(h)
        return p and p.netId or 0
    end

    env.NetworkGetEntityFromNetworkId = function(netId)
        for handle, p in pairs(world.peds) do
            if p.exists and p.netId == netId then return handle end
        end
        return 0
    end

    env.NetworkGetEntityOwner = function(h)
        local p = pedOf(h)
        return p and p.owner or -1
    end

    env.NetworkHasControlOfEntity = function(h)
        local p = pedOf(h)
        if not p then return false end
        if side == 'server' then return true end
        return p.owner == playerId
    end

    env.GetGroundZFor_3dCoord = function(x, y, z, unk)
        return Mock.groundZFor(x, y, z, unk)
    end

    -- ---- task natives with world effects ---------------------------------
    env.TaskGoToCoordAnyMeans = function(ped, x, y, z, speed, entity, p6, walkingStyle, p8)
        record(name, 'TaskGoToCoordAnyMeans', ped, x, y, z, speed, entity, p6, walkingStyle, p8)
        local p = pedOf(ped)
        if p then
            p.combatTarget = nil
            p.task = { kind = 'goto', x = x, y = y, z = z }
        end
    end

    env.TaskCombatPed = function(ped, targetPed, p2, combatFlags)
        record(name, 'TaskCombatPed', ped, targetPed, p2, combatFlags)
        local p = pedOf(ped)
        if p then
            p.combatTarget = targetPed
            p.task = { kind = 'combat', target = targetPed }
        end
    end

    env.ClearPedTasks = function(ped)
        record(name, 'ClearPedTasks', ped)
        local p = pedOf(ped)
        if p then
            p.combatTarget = nil
            p.task = nil
        end
    end

    env.ClearPedTasksImmediately = function(ped)
        record(name, 'ClearPedTasksImmediately', ped)
        local p = pedOf(ped)
        if p then
            p.combatTarget = nil
            p.task = nil
        end
    end

    --- A ped is "in combat" only while the ped it was tasked against still
    --- exists and is alive — matching the game, where combat ends when the
    --- target dies. Without this, supervise() could never resume its advance.
    env.IsPedInCombat = function(ped, target)
        record(name, 'IsPedInCombat', ped, target)
        local p = pedOf(ped)
        if not p or not p.combatTarget then return false end
        local t = pedOf(p.combatTarget)
        if not t or t.health <= 0 then return false end
        return true
    end

    -- ---- player / misc ---------------------------------------------------
    env.PlayerId  = function() return playerId end
    env.PlayerPedId = function()
        if side == 'server' then error('PlayerPedId is a client native', 2) end
        if not env.__playerPed then
            local p = newPed(name .. ':player', 'mp_m_freemode_01', 0.0, 0.0, 0.0, 0.0)
            Mock.instantiatePed(p.handle)   -- a player's own ped is always instantiated
            env.__playerPed = p.handle
        end
        return env.__playerPed
    end
    env.GetPlayerName = function(src) return 'MockPlayer' .. tostring(src) end
    env.GetPlayerPed  = function() return env.PlayerPedId() end
    env.GetPlayerWantedLevel = function() return 0 end
    env.GetVehiclePedIsIn = function() return 0 end
    env.GetCurrentResourceName = function() return resource end

    env.LoadResourceFile = function(res, file) return fileStore[res .. '/' .. file] end
    env.SaveResourceFile = function(res, file, data, len)
        record(name, 'SaveResourceFile', res, file, len)
        fileStore[res .. '/' .. file] = data
        return true
    end

    -- ---- events ----------------------------------------------------------
    env.RegisterNetEvent = function(evName)
        handlers[evName] = handlers[evName] or {}
        return true
    end

    env.AddEventHandler = function(evName, fn)
        handlers[evName] = handlers[evName] or {}
        handlers[evName][#handlers[evName] + 1] = fn
        return { name = evName }
    end
    env.RegisterServerEvent = env.RegisterNetEvent

    local function dispatch(targetEnv, evName, src, ...)
        local hs = targetEnv.__handlers[evName]
        if not hs then return 0 end
        local prev = rawget(targetEnv, 'source')
        targetEnv.source = src
        local count = 0
        local packed = table.pack(...)
        for i = 1, #hs do
            local ok, err = pcall(hs[i], unpack(packed, 1, packed.n))
            count = count + 1
            if not ok then
                Mock.errors[#Mock.errors + 1] = { ctx = targetEnv.__mockName, message = tostring(err) }
                io.stderr:write(('[%s] event %s handler error: %s\n'):format(targetEnv.__mockName, evName, tostring(err)))
            end
        end
        targetEnv.source = prev
        return count
    end
    Mock.dispatch = dispatch

    env.TriggerEvent = function(evName, ...)
        record(name, 'TriggerEvent', evName)
        return dispatch(env, evName, side == 'server' and 0 or playerId, ...)
    end

    env.TriggerServerEvent = function(evName, ...)
        record(name, 'TriggerServerEvent', evName, ...)
        assert(Mock.serverEnv, 'TriggerServerEvent with no server env loaded')
        return dispatch(Mock.serverEnv, evName, playerId, ...)
    end

    env.TriggerClientEvent = function(evName, targetPlayer, ...)
        record(name, 'TriggerClientEvent', evName, targetPlayer, ...)
        local delivered = 0
        for _, e in pairs(envs) do
            if e.__mockSide == 'client' and (targetPlayer == -1 or e.__mockPlayer == targetPlayer) then
                delivered = delivered + dispatch(e, evName, 0, ...)
            end
        end
        return delivered
    end

    -- ---- commands --------------------------------------------------------
    env.RegisterCommand = function(cmdName, fn, restricted)
        commands[cmdName] = { fn = fn, restricted = restricted and true or false }
        return true
    end

    env.ExecuteCommand = function(line)
        record(name, 'ExecuteCommand', line)
        return Mock.runCommand(env, line)
    end

    -- ---- unknown natives raise -------------------------------------------
    setmetatable(env, { __index = function(_, k)
        if type(k) == 'string' and k:match('^%u') then
            return function()
                error(('unimplemented native: %s (called from env %q)'):format(k, name), 2)
            end
        end
        return nil
    end })

    envs[name] = env
    if side == 'server' then Mock.serverEnv = env end
    return env
end

--- Invoke a registered command exactly as the console would.
--- Returns ok, err. Errors are recorded, never thrown (FiveM catches them too).
function Mock.runCommand(env, line, src)
    local parts = {}
    for word in tostring(line):gmatch('%S+') do parts[#parts + 1] = word end
    local cmdName = table.remove(parts, 1)
    local entry = env.__commands[cmdName]
    if not entry then
        return false, ('no such command: %s'):format(tostring(cmdName))
    end
    local ok, err = pcall(entry.fn, src or 0, parts, line)
    if not ok then
        Mock.errors[#Mock.errors + 1] = { ctx = env.__mockName, message = tostring(err) }
        io.stderr:write(('[%s] command %s error: %s\n'):format(env.__mockName, cmdName, tostring(err)))
    end
    return ok, err
end

--- Load a resource .lua file into `env`.
function Mock.loadInto(env, path)
    local chunk, err = loadfile(path, 't', env)
    if not chunk then error(('failed to load %s: %s'):format(path, tostring(err))) end
    chunk()
    return env
end

return Mock
