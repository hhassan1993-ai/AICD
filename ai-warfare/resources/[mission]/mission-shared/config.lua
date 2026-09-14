-- mission-shared/config.lua — ENGINE-SPEC v0.1 §3
-- Loaded by mission-core / mission-ai / population-ctl via:
--     shared_script '@mission-shared/config.lua'
-- Nothing in here may touch the game world; it is data + pure helpers only.

Config = {}

Config.Factions = {
    A = {
        name    = 'Coastal Republic',
        group   = 'MO_FACTION_A',
        color   = 1,
        models  = { 's_m_y_marine_01', 's_m_y_marine_03' },
        weapons = { 'WEAPON_CARBINERIFLE', 'WEAPON_ASSAULTRIFLE' },
    },
    B = {
        name    = 'Blackline Syndicate',
        group   = 'MO_FACTION_B',
        color   = 6,
        models  = { 's_m_y_blackops_01', 's_m_y_blackops_02' },
        weapons = { 'WEAPON_ASSAULTRIFLE', 'WEAPON_SPECIALCARBINE' },
    },
}

Config.SquadSize = 5

Config.Combat = {
    accuracy     = 35,
    seeRange     = 120.0,
    hearRange    = 120.0,
    engageRadius = 80.0,
}

Config.Tick = {
    clientMs      = 500,
    serverAuditMs = 1000,
}

-- PLACEHOLDER coordinates (unverified). Replace with /coords dumper output before first session.
Config.Spawns = {
    A = vector4(1700.0, 3250.0, 41.0, 200.0),
    B = vector4(1580.0, 3120.0, 41.0, 20.0),
}

Config.FormationOffset = 2.5 -- metres between squad members (line abreast, slot-indexed)

-- ---------------------------------------------------------------------------
-- Pure helpers (no natives) — shared so the server spawns in the same shape the
-- client tasks into.
-- ---------------------------------------------------------------------------

--- Heading (GTA degrees, 0 = +Y / north) for a direction of travel.
--- Forward vector for heading h is (-sin h, cos h), so h = atan2(-dx, dy).
--- @param dx number
--- @param dy number
--- @return number headingDeg  0.0 when the vector is degenerate
function Config.HeadingFromVector(dx, dy)
    dx = tonumber(dx) or 0.0
    dy = tonumber(dy) or 0.0
    if dx == 0.0 and dy == 0.0 then
        return 0.0
    end
    return math.deg(math.atan(-dx, dy)) % 360.0
end

--- Line-abreast formation offset, PERPENDICULAR to the direction of travel.
--- Slot 0 sits on the centre line; slots then alternate right (+) / left (-):
---   slot 0 -> 0            slot 1 -> +1d        slot 2 -> -1d
---   slot 3 -> +2d          slot 4 -> -2d        ...
--- Right vector for heading h is (cos h, sin h).
--- @param slot number       squad slot index, 0-based
--- @param headingDeg number direction of travel, GTA degrees
--- @return number ox, number oy  world-space XY offset in metres
function Config.FormationSlotOffset(slot, headingDeg)
    slot = math.floor(tonumber(slot) or 0)
    if slot < 0 then slot = 0 end
    if slot == 0 then
        return 0.0, 0.0
    end

    headingDeg = tonumber(headingDeg) or 0.0

    local rank = math.ceil(slot / 2)                 -- 1,1,2,2,3,3 ...
    local sign = (slot % 2 == 1) and 1.0 or -1.0     -- +,-,+,-  ...
    local d    = rank * sign * (tonumber(Config.FormationOffset) or 2.5)

    local rad = math.rad(headingDeg)
    return d * math.cos(rad), d * math.sin(rad)
end

--- Normalise / validate a faction argument. Returns 'A' | 'B' | nil.
--- @param raw any
--- @return string|nil
function Config.ValidFaction(raw)
    if type(raw) ~= 'string' then
        if type(raw) == 'number' then raw = tostring(raw) else return nil end
    end
    local f = string.upper((raw:gsub('%s', '')))
    if Config.Factions[f] ~= nil then
        return f
    end
    return nil
end

--- The opposing faction key, or nil when `f` is not a valid faction.
--- @param f any
--- @return string|nil
function Config.OtherFaction(f)
    local v = Config.ValidFaction(f)
    if v == 'A' then return 'B' end
    if v == 'B' then return 'A' end
    return nil
end
