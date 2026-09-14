--[[===========================================================================
  population-ctl/client.lua — ENGINE-SPEC v0.1 §6

  Client-only. Every native here is a client native (the density / dispatch /
  audio families have no server-side equivalent), so this runs on each player's
  machine for their own scope.

  §5 note: licensed radio stations are a Content ID problem for the caster, so
  the radio is forced off on vehicle entry.
===========================================================================]]

local TAG = '[population-ctl]'

local function log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print(('%s %s'):format(TAG, ok and msg or tostring(fmt)))
end

local DISPATCH_SERVICE_MIN = 1
local DISPATCH_SERVICE_MAX = 15

-- ---------------------------------------------------------------------------
-- One-shot suppression
-- ---------------------------------------------------------------------------

local function applyOnceSettings(enabled)
    local on = enabled and true or false

    SetGarbageTrucks(on)
    SetRandomBoats(on)
    SetCreateRandomCops(on)
    SetCreateRandomCopsNotOnScenarios(on)
    SetCreateRandomCopsOnScenarios(on)

    for i = DISPATCH_SERVICE_MIN, DISPATCH_SERVICE_MAX do
        EnableDispatchService(i, on)
    end

    SetMaxWantedLevel(on and 5 or 0)

    -- VERIFY in-game: audio flag name string 'DisableFlightMusic'.
    SetAudioFlag('DisableFlightMusic', not on)

    SetUserRadioControlEnabled(on)
end

Citizen.CreateThread(function()
    applyOnceSettings(false)
    log('ambient population, cops, dispatch services %d-%d, wanted levels and radio control disabled',
        DISPATCH_SERVICE_MIN, DISPATCH_SERVICE_MAX)
end)

-- ---------------------------------------------------------------------------
-- Per-frame suppression (these natives are all "ThisFrame")
-- ---------------------------------------------------------------------------

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)

        SetVehicleDensityMultiplierThisFrame(0.0)
        SetPedDensityMultiplierThisFrame(0.0)
        SetRandomVehicleDensityMultiplierThisFrame(0.0)
        SetParkedVehicleDensityMultiplierThisFrame(0.0)
        SetScenarioPedDensityMultiplierThisFrame(0.0, 0.0)

        local playerId = PlayerId()
        if GetPlayerWantedLevel(playerId) ~= 0 then
            SetPlayerWantedLevel(playerId, 0, false)
            SetPlayerWantedLevelNow(playerId, false)
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Radio off on vehicle entry (§5 / §6)
-- ---------------------------------------------------------------------------

Citizen.CreateThread(function()
    local lastVehicle = 0

    while true do
        Citizen.Wait(500)

        local ped = PlayerPedId()
        if type(ped) == 'number' and ped ~= 0 and DoesEntityExist(ped) then
            local veh = GetVehiclePedIsIn(ped, false)
            if type(veh) ~= 'number' then veh = 0 end

            if veh ~= 0 and DoesEntityExist(veh) then
                if veh ~= lastVehicle then
                    SetUserRadioControlEnabled(false)
                    SetRadioToStationName('OFF')
                    lastVehicle = veh
                    log('radio forced OFF on entering vehicle %d', veh)
                end
            else
                lastVehicle = 0
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Restore on stop so a dev session does not leave the world permanently empty.
-- ---------------------------------------------------------------------------

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    applyOnceSettings(true)
    log('restored ambient population defaults')
end)

log('loaded')
