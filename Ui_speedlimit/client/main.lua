Citizen.Wait(500) -- General wait for other resources to load

-- Framework/Lib Objects - Initialize to nil
local ESX = nil
local QBCore = nil
local ox_lib = nil -- Attempt to get export only if configured or needed elsewhere

-- Attempt to get necessary objects/exports based *only* on the configured Notification System
-- This prevents errors if, e.g., QB is configured but ESX isn't running.

if Config.NotificationSystem == 'esx' then
    if GetResourceState('es_extended') == 'started' then
        TriggerEvent('esx:getSharedObject', function(obj) ESX = obj end)
        Citizen.Wait(100) -- Small wait for the event callback
        if not ESX then
             print("[car_speed_limiter] WARNING: Configured for ESX notifications, but 'es_extended' resource seems started but ESX object wasn't retrieved.")
        end
    else
        print("[car_speed_limiter] WARNING: Configured for ESX notifications, but 'es_extended' resource is not started.")
    end
elseif Config.NotificationSystem == 'qb' then
     if GetResourceState('qb-core') == 'started' then
        QBCore = exports['qb-core']:GetCoreObject()
        if not QBCore then
            print("[car_speed_limiter] WARNING: Configured for QB notifications, but 'qb-core' resource seems started but QBCore object wasn't retrieved via export.")
        end
     else
        print("[car_speed_limiter] WARNING: Configured for QB notifications, but 'qb-core' resource is not started.")
     end
elseif Config.NotificationSystem == 'ox' then
    -- Check for ox_lib using exports - this is generally safer than resource state alone
    if exports.ox_lib then
        ox_lib = exports.ox_lib
    else
         print("[car_speed_limiter] WARNING: Configured for ox_lib notifications, but 'ox_lib' exports are not available. Ensure ox_lib is started before this script.")
    end
end


-- The rest of the script (speed limiting logic, notification logic using the potentially nil objects)
-- remains largely the same as the previous version, as it already checks if the objects exist
-- before trying to use them.

local isCurrentlyLimited = false
local lastVehicle = 0

-- Function to reset max speed
local function ResetVehicleMaxSpeed(vehicle)
    if DoesEntityExist(vehicle) then
        SetVehicleMaxSpeed(vehicle, 300.0)
    end
end

-- Main Speed Limiting Thread (Unaffected by framework choice)
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(Config.CheckInterval)
        local playerPed = PlayerPedId()
        local currentVehicle = GetVehiclePedIsIn(playerPed, false)

        if currentVehicle ~= 0 and GetPedInVehicleSeat(currentVehicle, -1) == playerPed then
            if currentVehicle ~= lastVehicle then
                if isCurrentlyLimited and lastVehicle ~= 0 then ResetVehicleMaxSpeed(lastVehicle) end
                lastVehicle = currentVehicle
                isCurrentlyLimited = false
            end

            local vehicleModelHash = GetEntityModel(currentVehicle)
            local foundLimit = false
            local limitMs = 0

            for modelName, limitData in pairs(Config.VehicleSpeedLimits) do
                local modelHash = GetHashKey(modelName)
                if vehicleModelHash == modelHash then
                    if type(limitData) == 'table' and limitData.value and limitData.unit then
                        local conversionFactor = Config.KmhToMs
                        if limitData.unit == 'mph' then conversionFactor = Config.MphToMs
                        elseif limitData.unit ~= 'kmh' then
                             print(('[car_speed_limiter] ERROR: Invalid unit "%s" for model "%s".'):format(limitData.unit, modelName))
                             goto next_vehicle_check
                        end
                        limitMs = limitData.value * conversionFactor
                        foundLimit = true
                    else
                        print(('[car_speed_limiter] ERROR: Invalid config format for model "%s".'):format(modelName))
                        goto next_vehicle_check
                    end
                    break
                end
            end

            if foundLimit then SetVehicleMaxSpeed(currentVehicle, limitMs); isCurrentlyLimited = true
            else if isCurrentlyLimited then ResetVehicleMaxSpeed(currentVehicle); isCurrentlyLimited = false end end
            ::next_vehicle_check::
        else
            if isCurrentlyLimited and lastVehicle ~= 0 then ResetVehicleMaxSpeed(lastVehicle) end
            lastVehicle = 0
            isCurrentlyLimited = false
        end
    end
end)

-- Notification Thread (Checks for available notification system object before calling)
if Config.EnableEnterVehicleNotification and Config.NotificationSystem ~= 'none' then
    Citizen.CreateThread(function()
        local lastNotifiedVehicle = 0
        while true do
            Citizen.Wait(1000)
            local playerPed = PlayerPedId()
            local vehicle = GetVehiclePedIsIn(playerPed, false)

            if vehicle ~= 0 and GetPedInVehicleSeat(vehicle, -1) == playerPed then
                if vehicle ~= lastNotifiedVehicle then
                    lastNotifiedVehicle = vehicle
                    local vehicleModelHash = GetEntityModel(vehicle)
                    local foundLimitData = nil

                    for modelName, limitData in pairs(Config.VehicleSpeedLimits) do
                        if vehicleModelHash == GetHashKey(modelName) then
                            if type(limitData) == 'table' and limitData.value and limitData.unit and (limitData.unit == 'kmh' or limitData.unit == 'mph') then
                                foundLimitData = limitData
                            end; break
                        end
                    end

                    if foundLimitData then
                        local limitValue = foundLimitData.value
                        local limitUnitLabel = foundLimitData.unit
                        local message = ('This vehicle has a speed limit of %d %s.'):format(limitValue, limitUnitLabel)

                        -- Use the correct notification system IF its object/export was successfully retrieved earlier
                        if Config.NotificationSystem == 'esx' then
                            if ESX and ESX.ShowNotification then ESX.ShowNotification(message:gsub('%s.', '~s~.'):gsub('%d', '~r~%0~s~'))
                            else print("[car_speed_limiter] Cannot show ESX notification - ESX object not available.") end
                        elseif Config.NotificationSystem == 'ox' then
                            if ox_lib and ox_lib.notify then ox_lib:notify({title = 'Vehicle Info', description = message, type = 'inform', duration = 5000,})
                            else print("[car_speed_limiter] Cannot show ox_lib notification - ox_lib exports not available.") end
                        elseif Config.NotificationSystem == 'qb' then
                            if QBCore and QBCore.Functions.Notify then QBCore.Functions.Notify(message, 'primary', 5000)
                            else print("[car_speed_limiter] Cannot show QB notification - QBCore object/function not available.") end
                        end
                    end
                end
            else lastNotifiedVehicle = 0 end
        end
    end)
end

-- Resource Stop Handler (Unaffected)
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() == resourceName then
        if isCurrentlyLimited and lastVehicle ~= 0 then
             ResetVehicleMaxSpeed(lastVehicle)
             print("Car Speed Limiter: Resetting max speed for last driven vehicle on resource stop.")
        end
    end
end)

-- Developer Command (Uses configured notification system if available)
RegisterCommand("resetMyVehicleLimits", function()
    local playerPed = PlayerPedId()
    local veh = GetVehiclePedIsIn(playerPed, false)
    local notifyTitle = 'Dev Command'
    local notifyMsg, notifyType = '', ''

    if veh ~= 0 then ResetVehicleMaxSpeed(veh); notifyMsg = 'Reset max speed attempt for current vehicle.'; notifyType = 'inform'
    else notifyMsg = 'You are not in a vehicle.'; notifyType = 'warning' end
    print("Car Speed Limiter: " .. notifyMsg)

    -- Send notification using the configured system IF it's available
    if Config.NotificationSystem == 'ox' then
        if ox_lib and ox_lib.notify then ox_lib:notify({title = notifyTitle, description = notifyMsg, type = notifyType}) end
    elseif Config.NotificationSystem == 'esx' then
        if ESX and ESX.ShowNotification then ESX.ShowNotification(notifyMsg) end
    elseif Config.NotificationSystem == 'qb' then
         if QBCore and QBCore.Functions.Notify then QBCore.Functions.Notify(notifyMsg, (notifyType == 'inform' and 'primary' or notifyType), 5000) end
    end
end, false)