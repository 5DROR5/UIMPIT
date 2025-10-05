--[[    
    UIMPIT Client-Side Script (key.lua)
    Author: 5DROR5
    Version: 1.3.0
]]
local M = {}

local PLUGIN = "[EconomyUI-Client]"
local json = require("ge/extensions/dkjson")

local registered_events = false
local retry_acc = 0
local RETRY_INTERVAL = 1.0 -- seconds

-- Buffer for a wanted update when guihooks isn't ready
local pending_wanted = nil

print(PLUGIN .. " Key.lua LOADED")

local function send_to_ui(money)
    if type(money) ~= "number" then
        money = tonumber(money)
    end
    if not money then
        print(PLUGIN .. " ERROR: invalid money value, cannot send to UI:", tostring(money))
        return
    end

    if type(guihooks) == "table" and type(guihooks.trigger) == "function" then
        guihooks.trigger("EconomyUI_Update", { money = money })
        print(PLUGIN .. " Money sent to UI:", money)
    else
        print(PLUGIN .. " WARNING: guihooks not available, will retry on next frame")
    end
end

local function send_lang_to_ui(langCode)
    if type(guihooks) == "table" and type(guihooks.trigger) == "function" then
        guihooks.trigger("LanguageUpdate", langCode)
        print(PLUGIN .. " Language sent to UI:", langCode)
    else
        print(PLUGIN .. " WARNING: guihooks not available for language update")
    end
end

-- ========================================================================= --
-- Wanted handler: robust parsing + buffering if guihooks not available
-- ========================================================================= --
local function on_receive_wanted_status(payload)
    print(PLUGIN .. " Received wanted payload from server. Type: " .. type(payload) .. ", Value: " .. tostring(payload))
    local wantedTime = nil

    if type(payload) == "string" then
        local success, decoded = pcall(json.decode, payload)
        if success and type(decoded) == "table" and decoded.wantedTime ~= nil then
            wantedTime = tonumber(decoded.wantedTime)
        else
            wantedTime = tonumber(payload)
        end
    elseif type(payload) == "number" then
        wantedTime = payload
    elseif type(payload) == "table" and payload.wantedTime ~= nil then
        wantedTime = tonumber(payload.wantedTime)
    end

    if wantedTime ~= nil then
        wantedTime = math.max(0, math.floor(wantedTime))
        print(PLUGIN .. string.format(" Successfully parsed wantedTime: %d", wantedTime))

        -- Data to send to UI, formatted as a table for consistency
        local ui_payload = { wantedTime = wantedTime }

        -- Try to send immediately if guihooks available; otherwise buffer
        if type(guihooks) == "table" and type(guihooks.trigger) == "function" then
            guihooks.trigger("EconomyUI_WantedUpdate", ui_payload)
            print(PLUGIN .. " Wanted sent to UI (immediate):", wantedTime)
        else
            pending_wanted = ui_payload
            print(PLUGIN .. " guihooks not available — buffered wantedTime:", wantedTime)
        end
    else
        print(PLUGIN .. " ERROR: Could not parse wantedTime from payload:", tostring(payload))
    end
end

function setPlayerLanguage(langCode)
    print(PLUGIN, "Received language change request from UI:", langCode)
    if type(TriggerServerEvent) == "function" then
        TriggerServerEvent('setPlayerLanguage', langCode)
    else
        print(PLUGIN, "ERROR: TriggerServerEvent not available")
    end
end

_G.setPlayerLanguage = setPlayerLanguage

local function on_receive_money(payload)
    print(PLUGIN .. " Received payload from server. Type: " .. type(payload) .. ", Value: " .. tostring(payload))
    local money = nil

    if type(payload) == "number" then
        money = payload
    elseif type(payload) == "string" then
        local success, decoded = pcall(json.decode, payload)
        if success and type(decoded) == "table" and decoded.money ~= nil then
            money = tonumber(decoded.money)
            if money == nil then
                 print(PLUGIN .. " WARNING: 'money' field was not a number. Value: " .. tostring(decoded.money))
            end
        else
            print(PLUGIN .. " JSON decoding failed or data structure is incorrect. Attempting direct number conversion.")
            money = tonumber(payload)
        end
    elseif type(payload) == "table" and payload.money ~= nil then
        money = tonumber(payload.money)
    end

    if money then
        print(PLUGIN .. " Successfully parsed money:", money)
        send_to_ui(money)
    else
        print(PLUGIN .. " ERROR: Could not parse money from payload:", tostring(payload))
    end
end

local function on_receive_language(langCode)
    print(PLUGIN .. " Received language update from server:", langCode)
    send_lang_to_ui(langCode)
end

local function try_register()
    if registered_events then return end
    if type(AddEventHandler) == "function" then
        AddEventHandler("receiveMoney", on_receive_money)
        AddEventHandler("receiveLanguage", on_receive_language)

        -- This is the event coming from the server for wanted status
        AddEventHandler("updateWantedStatus", on_receive_wanted_status)

        registered_events = true
        print(PLUGIN .. " Registered GE event handlers")
    end
end

function M.onUpdate(dt)
    if not registered_events then
        retry_acc = retry_acc + (dt or 0)
        if retry_acc >= RETRY_INTERVAL then
            retry_acc = 0
            try_register()
        end
    end

    -- Every frame we try to flush pending wanted update if guihooks became available
    if pending_wanted then
        if type(guihooks) == "table" and type(guihooks.trigger) == "function" then
            guihooks.trigger("EconomyUI_WantedUpdate", pending_wanted)
            print(PLUGIN .. " Flushed pending wantedTime to UI onUpdate:", pending_wanted.wantedTime)
            pending_wanted = nil
        end
    end
end

-- try to register immediately
try_register()

return M
