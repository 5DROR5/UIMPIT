--[[
    EconomyUI Client-Side Script (key.lua)
    Description: This script acts as the bridge between the server and the
    HTML/JS-based user interface (UI). It receives events from the server (like money updates)
    and forwards them to the UI, and it sends events from the UI (like language changes)
    to the server.
]]
local M = {}

local PLUGIN = "[EconomyUI-Client]"
-- Load the JSON library, essential for parsing data from the server.
local json = require("ge/extensions/dkjson")

-- State variables to manage event handler registration.
local registered_events = false
local retry_acc = 0
local RETRY_INTERVAL = 1.0 -- Time in seconds to wait before retrying to register events.

print(PLUGIN .. " Key.lua LOADED")

-- Sends the money value to the UI using the game's guihooks system.
local function send_to_ui(money)
    -- Ensure the money value is a number before sending.
    if type(money) ~= "number" then
        money = tonumber(money)
    end
    if not money then
        print(PLUGIN .. " ERROR: invalid money value, cannot send to UI:", tostring(money))
        return
    end

    -- Check if the guihooks system is available before trying to use it.
    if type(guihooks) == "table" and type(guihooks.trigger) == "function" then
        -- Trigger a custom event that the JavaScript part of the UI is listening for.
        guihooks.trigger("EconomyUI_Update", { money = money })
        print(PLUGIN .. " Money sent to UI:", money)
    else
        -- If guihooks isn't ready yet, log a warning. The onUpdate function will retry.
        print(PLUGIN .. " WARNING: guihooks not available, will retry on next frame")
    end
end

-- Sends the selected language code to the UI.
local function send_lang_to_ui(langCode)
    if type(guihooks) == "table" and type(guihooks.trigger) == "function" then
        guihooks.trigger("LanguageUpdate", langCode)
        print(PLUGIN .. " Language sent to UI:", langCode)
    else
        print(PLUGIN .. " WARNING: guihooks not available for language update")
    end
end

-- Event handler for when the client receives a 'receiveMoney' event from the server.
local function on_receive_money(payload)
    print(PLUGIN .. " Received payload from server. Type: " .. type(payload) .. ", Value: " .. tostring(payload))
    local money = nil

    -- The payload from the server can be in different formats (number, JSON string),
    -- so this block robustly parses it.
    if type(payload) == "number" then
        money = payload
    elseif type(payload) == "string" then
        -- Try to decode the string as JSON.
        local success, decoded = pcall(json.decode, payload)

        if success and type(decoded) == "table" and decoded.money ~= nil then
            money = tonumber(decoded.money)
            if money == nil then
                 print(PLUGIN .. " WARNING: 'money' field was not a number. Value: " .. tostring(decoded.money))
            end
        else
            -- If JSON decoding fails, try a direct conversion to a number as a fallback.
            print(PLUGIN .. " JSON decoding failed or data structure is incorrect. Attempting direct number conversion.")
            money = tonumber(payload)
        end
    elseif type(payload) == "table" and payload.money ~= nil then
        money = tonumber(payload.money)
    end

    -- If money was successfully parsed, send it to the UI.
    if money then
        print(PLUGIN .. " Successfully parsed money:", money)
        send_to_ui(money)
    else
        print(PLUGIN .. " ERROR: Could not parse money from payload:", tostring(payload))
    end
end

-- Event handler for when the client receives a language update.
local function on_receive_language(langCode)
    print(PLUGIN .. " Received language update from server:", langCode)
    send_lang_to_ui(langCode)
end

-- This function is called FROM the JavaScript UI to send an event TO the server.
function setPlayerLanguage(langCode)
    print(PLUGIN, "Received language change request from UI:", langCode)
    
    -- Use the global TriggerServerEvent function to communicate with the server script.
    if type(TriggerServerEvent) == "function" then
        TriggerServerEvent('setPlayerLanguage', langCode)
    else
        print(PLUGIN, "ERROR: TriggerServerEvent not available")
    end
end

-- Expose the function globally so the UI's `bngApi.engineLua` can call it.
_G.setPlayerLanguage = setPlayerLanguage

-- A function to register the event handlers that listen for messages from the server.
local function try_register()
    if registered_events then return end -- Don't register more than once.
    -- The AddEventHandler function might not be available immediately when the script loads.
    if type(AddEventHandler) == "function" then
        AddEventHandler("receiveMoney", on_receive_money)
        AddEventHandler("receiveLanguage", on_receive_language)
        registered_events = true
        print(PLUGIN .. " Registered GE event handlers")
    end
end

-- This function is called by the game engine on every frame.
function M.onUpdate(dt)
    -- If events aren't registered yet, keep trying on a timer.
    -- This ensures the script works even if it loads before the game's event system is ready.
    if not registered_events then
        retry_acc = retry_acc + (dt or 0)
        if retry_acc >= RETRY_INTERVAL then
            retry_acc = 0
            try_register()
        end
    end
end

-- Attempt to register immediately on script load.
try_register()

return M
