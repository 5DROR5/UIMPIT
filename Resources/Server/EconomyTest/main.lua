--[[
    UIMPIT Server-Side Script
    Author: 5DROR5
    Version: 1.3.0 (Combined)
    Description: This script manages the entire server-side economy system,
    including player accounts, money, roles, chat commands, and timed events.
]]

-- A unique identifier for log messages from this script, making it easier to debug.
local PLUGIN = "[EconomyTest]"
-- Importing the math library for calculations like angles and distances.
local math = require("math")
local rad = math.rad
local deg = math.deg

-- Safely load the JSON library. If it fails (e.g., not installed), json will be nil, preventing crashes.
local ok_json, json = pcall(require, "json")
if not ok_json then json = nil end

-- Default language for new players or if their language isn't supported. This value can be changed.
local DEFAULT_LANG = "en"
-- A list of supported languages for translations. You can add more language codes here.
local SUPPORTED_LANGS = { "he", "en", "ar" }

-- Define file paths relative to the server's resource folder.
local ROOT = "Resources/Server/EconomyTest"
local CONFIG_FILE = ROOT.. "/config.json" 
local LANG_DIR = ROOT.. "/lang"
local ACCOUNTS_FILE = ROOT.. "/Data/players.DATA"
-- Loads police skins definitions from a separate file, making the code more organized.
local PoliceSkins = require("PoliceSkins")

-- The 'config' table will hold all settings loaded from config.json.
local config = {}
-- The 'translations' table will hold all loaded language strings.
local translations = {}
-- The 'accounts' table will store data for all players, indexed by their unique ID (UID).
local accounts = {}
-- A temporary list for players who have just joined and are waiting for a welcome message.
local players_awaiting_welcome_sync = {}

-- Tables to manage cooldowns and statuses for various gameplay features.
local speeding_cooldowns = {}
local speeding_bonuses = {}
local zigzag_bonuses = {}
local zigzag_cooldowns = {}
local player_zigzag_state = {}
local busted_timers = {}
local wanted_timers = {}

-- Stores the last "wanted" time sent to each player's UI to avoid sending redundant updates.
local last_sent_wanted = {} 

-- ** Fallback default settings **
-- These are used to ensure the script runs correctly even if config.json is missing, corrupted, or incomplete.
-- This prevents errors if a value is not found in the config file.
local FALLBACK_DEFAULTS = {
    features = {
        roleplay_enabled = true, money_per_minute_enabled = true, cool_message_enabled = true,
        speeding_bonus_enabled = true, zigzag_bonus_enabled = true, police_features_enabled = true
    },
    general = { autosave_interval_ms = 120000 },
    money = {
        money_per_minute_interval_ms = 60000, money_per_minute_amount = 10,
        starting_money = 3333, cool_message_interval_ms = 30000
    },
    civilian = {
        speeding_limit_kmh = 100, speeding_bonus_duration_ms = 60000, speeding_cooldown_ms = 200000,
        speeding_bonus_per_second = 1, zigzag_bonus_duration_ms = 120000, zigzag_cooldown_ms = 200000,
        zigzag_final_bonus_amount = 50, zigzag_prorated_bonus = 5, min_speed_kmh_for_zigzag = 10,
        zigzag_min_turns = 5, wanted_fail_penalty = 50
    },
    police = {
        police_proximity_range_m = 150, busted_range_m = 20, busted_stop_time_ms = 7000,
        busted_speed_limit_kmh = 5, police_bonus_per_second = 2, bust_bonus_amount = 100
    }
}

-- Hardcoded settings that are not intended to be changed by the user via config.json.
local WELCOME_CHECK_INTERVAL = 500 -- How often to check if a new player is ready for a welcome message.
local COMBINED_CHECK_INTERVAL = 1000 -- How often to run the main game loop for all players.
local ZIGZAG_MIN_DELTA_ANGLE = math.rad(1) -- Minimum steering angle change to be considered a "turn" for the zigzag challenge.

-- A utility function for logging messages with the plugin's prefix for easy identification.
local function log(msg)
    print(PLUGIN.. " ".. tostring(msg))
end

-- A utility function to check if a file exists at a given path.
local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

-- Safely reads the entire content of a file. Returns nil if the file cannot be read.
local function safe_read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- Safely writes content to a file. Returns true on success, false on failure.
local function safe_write(path, content)
    local f = io.open(path, "w+")
    if not f then
        log("ERROR: Could not open file for writing: ".. path)
        return false
    end
    local ok, err = pcall(f.write, f, content)
    f:close()
    if not ok then
        log("ERROR writing file ".. path.. ": ".. tostring(err))
        return false
    end
    return true
end

-- Safely encodes a Lua table into a JSON string. Tries multiple methods for compatibility.
local function encode_json(tbl)
    if type(tbl) ~= "table" then return nil end
    -- First, try the server's built-in Util library if it exists.
    if type(Util) == "table" and Util.JsonEncode then
        local ok, s = pcall(Util.JsonEncode, tbl)
        if ok and type(s) == "string" then return s end
    end
    -- If that fails, try the included 'json' library.
    if json and json.encode then
        local ok, s = pcall(json.encode, tbl)
        if ok and type(s) == "string" then return s end
    end
    -- As a last resort, create a simple JSON object for money updates manually.
    if tbl.money ~= nil then
        return '{"money":'.. tostring(tbl.money).. '}'
    end
    return nil
end

-- Safely decodes a JSON string into a Lua table. Tries multiple methods for compatibility.
local function decode_json(str)
    if type(str) ~= "string" then return nil end
    -- First, try the server's built-in Util library.
    if type(Util) == "table" and Util.JsonDecode then
        local ok, t = pcall(Util.JsonDecode, str)
        if ok and type(t) == "table" then return t end
    end
    -- If that fails, try the included 'json' library.
    if json and json.decode then
        local ok, t = pcall(json.decode, str)
        if ok and type(t) == "table" then return t end
    end
    return nil
end

-- Loads a JSON file from a path and decodes it. Returns an empty table on failure.
local function json_load(path)
    local s = safe_read(path)
    if not s or s == "" then return {} end

    local ok, tbl = pcall(function() return decode_json(s) end)
    if ok and type(tbl) == "table" then return tbl end

    -- If decoding fails, log an error and try to remove the corrupted file.
    log("ERROR decoding JSON from ".. path.. ": ".. tostring(tbl))
    if FS and FS.Remove then pcall(FS.Remove, path) end
    return {}
end

-- An "atomic" save function that first writes to a temporary file.
-- This prevents data corruption if the server crashes during the save process.
local function atomic_json_save(path, tbl)
    local s = encode_json(tbl)
    if not s then
        log("ERROR encoding JSON for ".. path)
        return false
    end
    local temp_path = path.. ".tmp"
    if not safe_write(temp_path, s) then return false end

    -- Use the server's file system (FS) to rename the file, which is an atomic operation on most systems.
    if FS and FS.Rename then
        local ok, err = pcall(FS.Rename, temp_path, path)
        if not ok then
            pcall(FS.Remove, temp_path)
            log("ERROR renaming temp file: ".. tostring(err))
            return false
        end
        return true
    else
        -- If FS.Rename is not available, fall back to a simple write (less safe).
        return safe_write(path, s)
    end
end

-- This function loads the configuration from config.json.
-- It merges the loaded settings with the fallback defaults to ensure all necessary values are present.
local function load_config()
    local loaded_config = json_load(CONFIG_FILE)

    config = {}
    
    -- Deep merge with defaults to ensure all fields exist and prevent errors.
    for category, defaults in pairs(FALLBACK_DEFAULTS) do
        config[category] = config[category] or {}
        local loaded_category = loaded_config[category] or {}
        for key, value in pairs(defaults) do
            -- Use the loaded value from config.json, or the fallback default if it's missing.
            config[category][key] = loaded_category[key] ~= nil and loaded_category[key] or value
        end
    end
    
    log("Configuration loaded.")
    -- Log a message if a custom starting money value is detected.
    local starting_money = config.money and config.money.starting_money or FALLBACK_DEFAULTS.money.starting_money
    if starting_money ~= FALLBACK_DEFAULTS.money.starting_money then
        log(string.format("Custom starting money detected: %d", starting_money))
    end
end

-- Loads a single language file based on its language code (e.g., "en", "he").
local function load_lang_file(code)
    local path = LANG_DIR.. "/".. code.. ".json"
    if not file_exists(path) then return nil end
    return json_load(path)
end

-- This function loads all supported language files into the 'translations' table.
local function load_all_langs()
    translations = {}
    for _, code in ipairs(SUPPORTED_LANGS) do
        translations[code] = load_lang_file(code) or {}
    end
    log("Loaded languages: ".. table.concat(SUPPORTED_LANGS, ", "))
end

-- Gets a unique identifier (UID) for a player to store their data.
-- It tries to find the most stable ID available (BeamMP, Steam, etc.).
local function getUID(pid)
    local ids = {}
    if MP and MP.GetPlayerIdentifiers then
        ids = MP.GetPlayerIdentifiers(pid) or {}
    end
    return ids.beammp or ids.steam or ids.license or ("pid:".. tostring(pid))
end

-- Safely gets a player's name from their player ID (pid).
local function getPlayerNameSafe(pid)
    if MP and MP.GetPlayerName then
        local ok, name = pcall(MP.GetPlayerName, pid)
        return ok and name or ("Player".. tostring(pid))
    end
    return ("Player".. tostring(pid))
end

-- Gets the language code for a specific player.
local function get_player_lang(pid)
    local uid = getUID(pid)
    return (accounts[uid] and accounts[uid].lang) or DEFAULT_LANG
end

-- Gets a translated string for a specific player, based on their chosen language.
-- It can also replace placeholders like ${amount} with actual values.
local function tr_for_pid(pid, key, vars)
    local lang = get_player_lang(pid)
    local text = (translations[lang] or {})[key] or key
    if vars then
        for k,v in pairs(vars) do
            text = text:gsub("${".. k.. "}", tostring(v))
        end
    end
    return text
end

-- Checks if an account exists for a player. If not, it creates a new one with starting money.
local function ensure_account_for_pid(pid)
    local uid = getUID(pid)
    if not accounts[uid] then
        local starting_money = (config.money and config.money.starting_money) or FALLBACK_DEFAULTS.money.starting_money
        accounts[uid] = { money = starting_money, lang = DEFAULT_LANG, role = "civilian" }
    end
    return uid
end

-- Returns the current money for a given UID. Returns 0 if the account doesn't exist.
local function get_money(uid)
    return (accounts[uid] and accounts[uid].money) or 0
end

-- Adds a specified amount of money to a player's account. Ensures money doesn't go below zero.
local function add_money(uid, amt)
    amt = tonumber(amt) or 0
    -- If the account doesn't exist for some reason, create it on the fly.
    local starting_money = (config.money and config.money.starting_money) or FALLBACK_DEFAULTS.money.starting_money
    accounts[uid] = accounts[uid] or { money = starting_money, lang = DEFAULT_LANG, role="civilian" }
    accounts[uid].money = math.max(0, (accounts[uid].money or 0) + amt)
end

-- Loads all player accounts from the data file.
local function load_accounts()
    accounts = file_exists(ACCOUNTS_FILE) and json_load(ACCOUNTS_FILE) or {}
    local count = 0
    for _,_ in pairs(accounts) do count = count + 1 end
    log("Loaded accounts: ".. tostring(count))
end

-- Saves all player accounts to the data file using the atomic save function.
local function save_accounts()
    atomic_json_save(ACCOUNTS_FILE, accounts)
end

-- Sends a chat message to a specific player by their pid.
local function sendTo(pid, msg)
    if MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid) then
        local ok, err = pcall(MP.SendChatMessage, pid, msg)
        if not ok then log("ERROR sending message to ".. tostring(pid).. ": ".. tostring(err)) end
    end
end

-- Sends a chat message to all connected players.
local function sendAll(msg)
    for pid,_ in pairs(MP.GetPlayers() or {}) do sendTo(pid, msg) end
end

-- Sends an update to the player's UI (HUD) with their current money.
-- This function can be disabled by commenting it out if you don't use the client-side UI.
local function sendEconomyUIUpdate(pid)
    if not (MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid)) then return end
    local uid = getUID(pid)
    local playerData = accounts[uid]
    if not playerData then return end

    local payload_tbl = { money = tonumber(playerData.money) or 0 }
    -- Encode the data to a JSON string to send to the client.
    local payload_str = encode_json(payload_tbl)

    -- Fallback in case encoding fails, just send the number.
    if not payload_str then
        payload_str = tostring(payload_tbl.money)
    end

    if not payload_str then
        log("[EconomyUI]: ERROR generating payload for PID=".. tostring(pid))
        return
    end

    -- Trigger the client-side event to update the UI.
    local ok, err = pcall(function()
        MP.TriggerClientEvent(pid, "receiveMoney", payload_str)
    end)
    if ok then
        log("[EconomyUI]: Sent UI update for PID: ".. tostring(pid).. " payload=".. tostring(payload_str))
    else
        log("[EconomyUI]: ERROR sending UI update PID=".. tostring(pid).. " err=".. tostring(err))
    end
end

-- Sends a "cool message" to all players, defined in the language files.
-- This function can be disabled in config.json.
local function ECON_send_cool_message()
    if not (config.features and config.features.cool_message_enabled) then return end
    
    for pid,_ in pairs(MP.GetPlayers() or {}) do
        sendTo(pid, tr_for_pid(pid, "cool_player_message"))
    end
end

-- This function is called by a timer to give all players a set amount of money.
-- The amount and interval are configurable, and the feature can be disabled.
function ECON_add_money_timer()
    if not (config.features and config.features.money_per_minute_enabled) then return end
    local MONEY_PER_MINUTE_AMOUNT_VAL = (config.money and config.money.money_per_minute_amount) or FALLBACK_DEFAULTS.money.money_per_minute_amount

    log("ECON_add_money_timer tick")
    for pid,_ in pairs(MP.GetPlayers() or {}) do
        local uid = ensure_account_for_pid(pid)
        add_money(uid, MONEY_PER_MINUTE_AMOUNT_VAL)
        log(string.format("Added %d to UID=%s new_bal=%s", MONEY_PER_MINUTE_AMOUNT_VAL, tostring(uid), tostring(get_money(uid))))
        sendTo(pid, tr_for_pid(pid, "added_money_per_minute", { amount=MONEY_PER_MINUTE_AMOUNT_VAL, money=get_money(uid) }))
        sendEconomyUIUpdate(pid)
    end
end

-- Checks for new players who are ready to receive their welcome message and UI data.
local function ECON_check_and_send_welcomes()
    for pid,_ in pairs(players_awaiting_welcome_sync) do
        if MP.IsPlayerConnected(pid) then
            sendTo(pid, tr_for_pid(pid, "welcome_server"))
            sendEconomyUIUpdate(pid)
            players_awaiting_welcome_sync[pid] = nil
        end
    end
end


-- A more numerically stable implementation of atan2, for calculating angles.
local function atan2(y, x)
    if x > 0 then
        return math.atan(y / x)
    elseif x < 0 and y >= 0 then
        return math.atan(y / x) + math.pi
    elseif x < 0 and y < 0 then
        return math.atan(y / x) - math.pi
    elseif x == 0 and y > 0 then
        return math.pi / 2
    elseif x == 0 and y < 0 then
        return -math.pi / 2
    else
        return 0
    end
end

-- Calculates the Euclidean distance between two 3D points.
local function dist(pos1, pos2)
    local dx = (pos1[1] or 0) - (pos2[1] or 0)
    local dy = (pos1[2] or 0) - (pos2[2] or 0)
    local dz = (pos1[3] or 0) - (pos2[3] or 0)
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

-- Sends an update to the UI about the player's "wanted" status and remaining time.
local function sendWantedUIUpdate(pid, seconds)
    if not (MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid)) then return end

    local secs = tonumber(seconds) or 0
    secs = math.max(0, math.ceil(secs))

    -- Only send an update if the time has changed to reduce network traffic.
    if last_sent_wanted[pid] == secs then return end
    last_sent_wanted[pid] = secs

    local payload_tbl = { wantedTime = secs }
    local payload_str = encode_json and encode_json(payload_tbl) or nil

    if not payload_str then
        if log then log("[EconomyUI-Wanted]: ERROR generating payload for PID=".. tostring(pid)) end
        return
    end

    -- Trigger the client-side event.
    local ok, err = pcall(function()
        MP.TriggerClientEvent(pid, "updateWantedStatus", payload_str)
    end)
    if not ok then
        if log then log("[EconomyUI-Wanted]: ERROR sending UI update PID=".. tostring(pid).. " err=".. tostring(err)) end
    end
end

-- Starts or extends a player's "wanted" timer.
local function update_wanted_timer(pid, duration_ms, source_key)
    if not (config.features and config.features.roleplay_enabled) then return end
    
    local now = os.time() * 1000
    local current_expiration = wanted_timers[pid] or 0
    local new_expiration = current_expiration
    local duration_sec = duration_ms / 1000

    -- If the player is not currently wanted, start a new timer.
    if current_expiration < now then
        new_expiration = now + duration_ms
        sendTo(pid, tr_for_pid(pid, source_key, { duration = duration_sec }))
        if log then log(string.format("[WANTED] PID=%s - Started WANTED timer for %.2f seconds (Source: %s).", pid, duration_sec, source_key)) end
    -- If the player is already wanted, extend the existing timer.
    else
        new_expiration = current_expiration + duration_ms
        sendTo(pid, tr_for_pid(pid, "wanted_extended", { seconds = duration_sec }))
        if log then log(string.format("[WANTED] PID=%s - Extended WANTED timer by %.2f seconds. New total: %.2f seconds.", pid, duration_sec, (new_expiration - now) / 1000)) end
    end

    wanted_timers[pid] = new_expiration
    local remaining_sec = math.max(0, math.ceil((new_expiration - now) / 1000))
    sendWantedUIUpdate(pid, remaining_sec)
end

-- This function is called when a player fails their "wanted" status (e.g., gets busted, resets their vehicle).
-- It applies a penalty and resets all their gameplay state.
local function fail_wanted_status(pid, reason_key)
    if not (config.features and config.features.roleplay_enabled) then return end
    local WANTED_FAIL_PENALTY_VAL = (config.civilian and config.civilian.wanted_fail_penalty) or FALLBACK_DEFAULTS.civilian.wanted_fail_penalty
    
    if not (MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid)) then return end

    local uid = getUID(pid)
    local current_role = accounts[uid] and accounts[uid].role

    -- Only apply to civilians who are actually wanted.
    if current_role ~= "civilian" then
        if log then log(string.format("[WANTED-FAIL] PID=%s is not a civilian. Aborting failure logic for reason: %s.", pid, reason_key)) end
        return
    end

    if not wanted_timers[pid] or wanted_timers[pid] <= os.time() * 1000 then
        if log then log(string.format("[WANTED-FAIL] PID=%s is not currently WANTED. Aborting penalty/cleanup for reason: %s.", pid, reason_key)) end
        return
    end

    -- Apply the money penalty.
    local current_money = get_money(uid) or 0
    add_money(uid, -WANTED_FAIL_PENALTY_VAL)
    local new_money = get_money(uid)
    if log then log(string.format("[WANTED-FAIL-MONEY] PID=%s UID=%s. Old: $%d. New: $%d (Penalty: $%d).", pid, uid, current_money, new_money, WANTED_FAIL_PENALTY_VAL)) end

    -- Send a message to the player.
    sendTo(pid, tr_for_pid(pid, "wanted_fail_message", {
        penalty = WANTED_FAIL_PENALTY_VAL,
        reason = tr_for_pid(pid, reason_key)
    }))

    -- Update the UI.
    sendEconomyUIUpdate(pid)

    -- Clear all timers and state related to the "wanted" status. This is a full reset.
    wanted_timers[pid] = nil
    last_sent_wanted[pid] = nil
    sendWantedUIUpdate(pid, 0)
    speeding_bonuses[pid] = nil
    zigzag_bonuses[pid] = nil
    speeding_cooldowns[pid] = nil
    zigzag_cooldowns[pid] = nil
    busted_timers[pid] = nil
    player_zigzag_state[pid] = nil

    if log then log(string.format("[WANTED-FAIL] PID=%s FAILED WANTED status (Reason: %s). Penalty: $%d. Cooldowns reset.", pid, reason_key, WANTED_FAIL_PENALTY_VAL)) end
end

-- Handles the logic for starting the speeding challenge.
local function handle_speeding(pid, speed)
    if not (config.features and config.features.roleplay_enabled and config.features.speeding_bonus_enabled) then return end
    local SPEEDING_COOLDOWN_MS_VAL = (config.civilian and config.civilian.speeding_cooldown_ms) or FALLBACK_DEFAULTS.civilian.speeding_cooldown_ms
    local SPEEDING_BONUS_DURATION_MS_VAL = (config.civilian and config.civilian.speeding_bonus_duration_ms) or FALLBACK_DEFAULTS.civilian.speeding_bonus_duration_ms
    
    local now = os.time() * 1000

    -- Check if the player is on cooldown for this challenge.
    if speeding_cooldowns[pid] and now - speeding_cooldowns[pid] < SPEEDING_COOLDOWN_MS_VAL then
        return
    end

    local uid = getUID(pid)
    if accounts[uid] and accounts[uid].role == "civilian" then
        -- If the challenge isn't active, start it.
        if not speeding_bonuses[pid] then
            speeding_bonuses[pid] = { startTime = now, lastPayment = now }
        end

        -- Make the player wanted for the duration of the challenge.
        update_wanted_timer(pid, SPEEDING_BONUS_DURATION_MS_VAL, "speed_start_wanted")
        speeding_cooldowns[pid] = now
    end
end

-- Handles the logic for detecting zigzag driving and starting the challenge.
local function handle_zigzag(pid, pos)
    if not (config.features and config.features.roleplay_enabled and config.features.zigzag_bonus_enabled) then return end
    local MIN_SPEED_KMH_FOR_ZIGZAG_VAL = (config.civilian and config.civilian.min_speed_kmh_for_zigzag) or FALLBACK_DEFAULTS.civilian.min_speed_kmh_for_zigzag
    local ZIGZAG_COOLDOWN_MS_VAL = (config.civilian and config.civilian.zigzag_cooldown_ms) or FALLBACK_DEFAULTS.civilian.zigzag_cooldown_ms
    local ZIGZAG_MIN_TURNS_VAL = (config.civilian and config.civilian.zigzag_min_turns) or FALLBACK_DEFAULTS.civilian.zigzag_min_turns
    local ZIGZAG_BONUS_DURATION_MS_VAL = (config.civilian and config.civilian.zigzag_bonus_duration_ms) or FALLBACK_DEFAULTS.civilian.zigzag_bonus_duration_ms
    
    local uid = getUID(pid)
    if not accounts[uid] or accounts[uid].role ~= "civilian" then return end
    if not pos or not pos.rot or not pos.vel then return end

    local now = os.time() * 1000

    -- Check if the player is driving fast enough.
    local speed = math.sqrt((pos.vel[1] or 0)^2 + (pos.vel[2] or 0)^2) * 3.6
    if speed < MIN_SPEED_KMH_FOR_ZIGZAG_VAL then
        player_zigzag_state[pid] = nil
        return
    end

    -- Check for cooldown.
    if zigzag_cooldowns[pid] and (now - zigzag_cooldowns[pid] < ZIGZAG_COOLDOWN_MS_VAL) then return end

    local move_angle = atan2(pos.vel[2], pos.vel[1])

    -- Initialize the state for tracking turns if it doesn't exist.
    if not player_zigzag_state[pid] then
        player_zigzag_state[pid] = {
            last_angle = move_angle,
            consecutive_turns = 0,
            last_direction = 0
        }
        return
    end

    local state = player_zigzag_state[pid]
    local last_angle = state.last_angle

    -- Calculate the change in direction.
    local delta_angle = move_angle - last_angle
    if delta_angle > math.pi then delta_angle = delta_angle - 2 * math.pi
    elseif delta_angle < -math.pi then delta_angle = delta_angle + 2 * math.pi end

    -- Ignore very small steering adjustments.
    if math.abs(math.deg(delta_angle)) < math.deg(ZIGZAG_MIN_DELTA_ANGLE) then return end

    local direction = (delta_angle > 0) and 1 or -1

    -- If the player turned in the opposite direction from their last turn, increment the turn counter.
    if state.last_direction ~= 0 and direction ~= state.last_direction then
        state.consecutive_turns = state.consecutive_turns + 1
    else
        state.consecutive_turns = 1
    end

    state.last_angle = move_angle
    state.last_direction = direction

    -- If enough consecutive turns have been made, start the challenge.
    if state.consecutive_turns >= ZIGZAG_MIN_TURNS_VAL then
        if not zigzag_bonuses[pid] then
            zigzag_bonuses[pid] = { startTime = now, lastPayment = now }
        end

        update_wanted_timer(pid, ZIGZAG_BONUS_DURATION_MS_VAL, "zigzag_start_wanted")
        zigzag_cooldowns[pid] = now
        player_zigzag_state[pid] = nil
    end
end

-- Checks a player's vehicle skin to determine if they are in a police car.
function updatePlayerVehicleInfo(pid)
    if not (config.features and config.features.roleplay_enabled) then return end

    local uid = getUID(pid)
    if not accounts[uid] then return end

    if not (MP and MP.GetPlayerVehicles) then
        if log then log("ERROR: MP.GetPlayerVehicles is not available.") end
        return
    end

    local ok, vehicles = pcall(MP.GetPlayerVehicles, pid)

    local is_police = false
    local current_role = accounts[uid].role or "civilian"
    local new_role = "civilian"

    if ok and vehicles and type(vehicles) == "table" then
        for _, v in pairs(vehicles) do
            -- The vehicle data is often a JSON string within the table.
            if type(v) == "string" then
                local json_match = v:match("{.*}")
                if json_match then
                    local ok_json, data = pcall(function() return decode_json(json_match) end)
                    if ok_json and type(data) == "table" then
                        -- Check both the skin file and the paint design part.
                        local vehSkin = (data.vcf and data.vcf.partConfigFilename) or ""
                        local vehPaint = (data.vcf and data.vcf.parts and data.vcf.parts.paint_design) or ""

                        -- Compare against the list of police skins.
                        for _, skin in ipairs(PoliceSkins or {}) do
                            if vehSkin == skin or vehPaint == skin then
                                new_role = "police";
                                is_police = true;
                                break
                            end
                        end
                        if is_police then break end
                    end
                end
            end
        end
    end

    -- If the player's role has changed, update their account.
    if current_role ~= new_role then
        accounts[uid].role = new_role

        if new_role == "police" then
            sendTo(pid, tr_for_pid(pid, "welcome_police"))
            -- If a player becomes a cop while wanted, cancel the wanted status.
            if wanted_timers[pid] and wanted_timers[pid] > os.time() * 1000 then
                 fail_wanted_status(pid, "reason_became_police")
            end
            accounts[uid].last_police_payment = os.time() * 1000
        elseif new_role == "civilian" then
            sendTo(pid, tr_for_pid(pid, "welcome_civilian"))
        end
        -- Send UI updates to reflect the change.
        sendEconomyUIUpdate(pid)
        sendWantedUIUpdate(pid, 0)
        if log then log(string.format("PID=%s role changed from %s to %s", pid, current_role, new_role)) end
    end
end

-- This is the main game loop that runs every second.
-- It gathers data for all players and then processes all the game logic.
function ECON_check_all_player_updates()
    if not (config.features and config.features.roleplay_enabled) then return end

    -- Load all configurable values, with fallbacks. This allows for hot-reloading the config without restarting the script.
    local SPEED_LIMIT_KMH_VAL = (config.civilian and config.civilian.speeding_limit_kmh) or FALLBACK_DEFAULTS.civilian.speeding_limit_kmh
    local POLICE_PROXIMITY_RANGE_M_VAL = (config.police and config.police.police_proximity_range_m) or FALLBACK_DEFAULTS.police.police_proximity_range_m
    local BUSTED_RANGE_M_VAL = (config.police and config.police.busted_range_m) or FALLBACK_DEFAULTS.police.busted_range_m
    local BUSTED_STOP_TIME_MS_VAL = (config.police and config.police.busted_stop_time_ms) or FALLBACK_DEFAULTS.police.busted_stop_time_ms
    local BUSTED_SPEED_LIMIT_KMH_VAL = (config.police and config.police.busted_speed_limit_kmh) or FALLBACK_DEFAULTS.police.busted_speed_limit_kmh
    local BUST_BONUS_AMOUNT_VAL = (config.police and config.police.bust_bonus_amount) or FALLBACK_DEFAULTS.police.bust_bonus_amount
    local POLICE_BONUS_PER_SECOND_VAL = (config.police and config.police.police_bonus_per_second) or FALLBACK_DEFAULTS.police.police_bonus_per_second
    local SPEEDING_BONUS_PER_SECOND_VAL = (config.civilian and config.civilian.speeding_bonus_per_second) or FALLBACK_DEFAULTS.civilian.speeding_bonus_per_second
    local ZIGZAG_PRORATED_BONUS_VAL = (config.civilian and config.civilian.zigzag_prorated_bonus) or FALLBACK_DEFAULTS.civilian.zigzag_prorated_bonus
    local ZIGZAG_FINAL_BONUS_AMOUNT_VAL = (config.civilian and config.civilian.zigzag_final_bonus_amount) or FALLBACK_DEFAULTS.civilian.zigzag_final_bonus_amount
    
    local now = os.time() * 1000
    local all_players = MP.GetPlayers() or {}

    -- ** Data Gathering Phase **
    -- Collect position, speed, and role for all players in one go to be efficient.
    local player_data = {}
    local wanted_civilian_data = {}
    local police_data = {}

    for pid,_ in pairs(all_players) do
        if MP.IsPlayerConnected(pid) then
            local uid = getUID(pid)
            local role = accounts[uid] and accounts[uid].role or "civilian"

            local ok, pos = pcall(MP.GetPositionRaw, pid, 0)
            local speed = (ok and pos and pos.vel) and math.sqrt(pos.vel[1]^2 + pos.vel[2]^2) * 3.6 or 0

            player_data[pid] = { pos = (ok and pos and pos.pos) or nil, speed = speed, role = role }

            -- Handle civilian driving checks.
            if role == "civilian" then
                if ok and pos then
                    if config.features.speeding_bonus_enabled and speed > SPEED_LIMIT_KMH_VAL then pcall(handle_speeding, pid, speed) end
                    if config.features.zigzag_bonus_enabled then pcall(handle_zigzag, pid, pos) end
                end
                -- Add to the wanted list if they are currently wanted.
                if wanted_timers[pid] and wanted_timers[pid] > now then
                    if player_data[pid].pos then
                        wanted_civilian_data[pid] = player_data[pid]
                    end
                end
            -- Add to the police list if they are a cop.
            elseif role == "police" and config.features.police_features_enabled then
                police_data[pid] = player_data[pid]
            end
        end
    end

    -- ** Busted Logic Phase **
    -- This logic determines if a wanted civilian gets busted by the police.
    local civilian_police_proximity_count = {}
    local police_near_event_count = {}

    if config.features.police_features_enabled then
        for civil_pid, civil_data in pairs(wanted_civilian_data) do
            local police_count = 0
            local closest_cop_dist = POLICE_PROXIMITY_RANGE_M_VAL + 1
            local nearby_police = {}

            if civil_data.pos then
                -- Check distance to every cop.
                for cop_pid, cop_data in pairs(police_data) do
                    if cop_data.pos then
                        local distance = dist(civil_data.pos, cop_data.pos)

                        -- Count how many cops are within the wider proximity range.
                        if distance <= POLICE_PROXIMITY_RANGE_M_VAL then
                            police_count = police_count + 1
                            police_near_event_count[cop_pid] = (police_near_event_count[cop_pid] or 0) + 1
                        end
                        -- Keep a list of cops who are close enough to make the bust.
                        if distance <= BUSTED_RANGE_M_VAL then
                            table.insert(nearby_police, cop_pid)
                        end
                        if distance < closest_cop_dist then
                            closest_cop_dist = distance
                        end
                    end
                end
            end

            civilian_police_proximity_count[civil_pid] = police_count

            if civil_data.pos then
                -- Check if the civilian is stopped and a cop is very close.
                if civil_data.speed < BUSTED_SPEED_LIMIT_KMH_VAL and closest_cop_dist <= BUSTED_RANGE_M_VAL then
                    if not busted_timers[civil_pid] then
                        busted_timers[civil_pid] = now
                    else
                        -- If they have been stopped for long enough, they are busted.
                        local elapsed_time = now - busted_timers[civil_pid]
                        if elapsed_time >= BUSTED_STOP_TIME_MS_VAL then
                            local uid = getUID(civil_pid)
                            local name = MP.GetPlayerName(civil_pid)

                            fail_wanted_status(civil_pid, "reason_busted")
                            busted_timers[civil_pid] = nil
                            sendAll(tr_for_pid(civil_pid, "busted_global_message", { criminal = name }))

                            -- Reward all nearby police officers.
                            for _, cop_pid in ipairs(nearby_police) do
                                local cop_uid = getUID(cop_pid)
                                add_money(cop_uid, BUST_BONUS_AMOUNT_VAL)
                                sendTo(cop_pid, tr_for_pid(cop_pid, "police_bust_bonus", { amount = BUST_BONUS_AMOUNT_VAL, criminal = name }))
                                sendEconomyUIUpdate(cop_pid)
                                if log then log(string.format("[BUSTED] Rewarded Police PID=%s UID=%s with $%d for bust of PID=%s.", cop_pid, cop_uid, BUST_BONUS_AMOUNT_VAL, civil_pid)) end
                            end
                        end
                    end
                else
                    -- If they start moving again, reset the busted timer.
                    busted_timers[civil_pid] = nil
                end
            end
        end
    end

    -- ** Payment & Timer Update Phase **
    -- This loop handles ongoing payments and checks for expired timers.
    for pid,_ in pairs(all_players) do
        if MP.IsPlayerConnected(pid) then
            local uid = getUID(pid)
            local role = accounts[uid] and accounts[uid].role or "civilian"
            local is_wanted = wanted_timers[pid] and wanted_timers[pid] > now

            -- Update the UI timer for all players.
            local remaining_wanted_ms = (wanted_timers[pid] or 0) - now
            local remaining_wanted_seconds = math.max(0, math.ceil(remaining_wanted_ms / 1000))
            sendWantedUIUpdate(pid, remaining_wanted_seconds)

            -- Check if a wanted timer has expired successfully.
            if wanted_timers[pid] and wanted_timers[pid] <= now then
                local bonus_amount = ZIGZAG_FINAL_BONUS_AMOUNT_VAL
                add_money(uid, bonus_amount)
                sendTo(pid, tr_for_pid(pid, "zigzag_end_reward", { amount = bonus_amount }))
                sendEconomyUIUpdate(pid)
                if log then log(string.format("[EVASION] PID %d (UID: %s) evaded WANTED status and received $%.2f bonus.", pid, uid, bonus_amount)) end

                wanted_timers[pid] = nil
                last_sent_wanted[pid] = nil
                is_wanted = false
            end
            
            -- Handle periodic payments for police and wanted civilians.
            if config.features.roleplay_enabled then
                if is_wanted or role == "police" then
                    local last_payment_ms = now - 1000
                    if role == "police" then
                        last_payment_ms = accounts[uid].last_police_payment or (now - 1000)
                    elseif is_wanted then
                        last_payment_ms = speeding_bonuses[pid] and speeding_bonuses[pid].lastPayment or zigzag_bonuses[pid] and zigzag_bonuses[pid].lastPayment or (now - 1000)
                    end

                    local seconds_passed = math.max(0, math.floor(now / 1000) - math.floor(last_payment_ms / 1000))

                    if seconds_passed > 0 then
                        local money_to_add = 0
                        -- Police get paid for each wanted civilian they are near.
                        if role == "police" and config.features.police_features_enabled then
                            local civilian_event_count = police_near_event_count[pid] or 0
                            if civilian_event_count > 0 and POLICE_BONUS_PER_SECOND_VAL ~= nil then
                                money_to_add = seconds_passed * POLICE_BONUS_PER_SECOND_VAL * civilian_event_count
                                accounts[uid].last_police_payment = now
                            end
                        -- Wanted civilians get paid for each cop they are near while doing a challenge.
                        elseif is_wanted then
                            local police_count = civilian_police_proximity_count[pid] or 0
                            if police_count > 0 then
                                if speeding_bonuses[pid] and config.features.speeding_bonus_enabled then
                                    money_to_add = money_to_add + (seconds_passed * SPEEDING_BONUS_PER_SECOND_VAL * police_count)
                                end
                                if zigzag_bonuses[pid] and config.features.zigzag_bonus_enabled then
                                    money_to_add = money_to_add + (seconds_passed * ZIGZAG_PRORATED_BONUS_VAL * police_count)
                                end
                            end
                        end

                        if money_to_add > 0 then
                            add_money(uid, money_to_add)
                            sendEconomyUIUpdate(pid)
                            if speeding_bonuses[pid] then speeding_bonuses[pid].lastPayment = now end
                            if zigzag_bonuses[pid] then zigzag_bonuses[pid].lastPayment = now end
                        end
                    end
                end
            end
        end
    end
end

-- Event handler: Called when a player edits their vehicle.
function ECON_onVehicleEdited(...)
    local pid = select(1, ...)
    if not pid or not (MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid)) then return end
    fail_wanted_status(pid, "reason_vehicle_edited")
    updatePlayerVehicleInfo(pid)
end

-- Event handler: Called when a player changes their vehicle.
function ECON_onChangeVehicle(...)
    local pid = select(1, ...)
    if not pid or not (MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid)) then return end
    fail_wanted_status(pid, "reason_change_vehicle")
    updatePlayerVehicleInfo(pid)
end

-- Event handler: Called when a player resets their vehicle.
function ECON_onVehicleReset(...)
    local pid = select(1, ...)
    if not pid or not (MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid)) then return end
    fail_wanted_status(pid, "reason_vehicle_reset")
    updatePlayerVehicleInfo(pid)
end

-- Event handler: Called when a player exits their vehicle.
function ECON_onPlayerExitVehicle(...)
    local pid = select(1, ...)
    if not pid or not (MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid)) then return end
    fail_wanted_status(pid, "reason_exit_vehicle")
end

-- Event handler: Called when a player's vehicle is deleted.
function ECON_onVehicleDelete(...)
    local pid = select(1, ...)
    if not pid or not (MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid)) then return end
    fail_wanted_status(pid, "reason_vehicle_delete")
    updatePlayerVehicleInfo(pid)
end

-- This function is called by a timer to check player roles periodically.
function ECON_check_roles_timer()
    if not (config.features and config.features.roleplay_enabled) then return end
    
    local players = MP.GetPlayers() or {}
    for pid, _ in pairs(players) do
        if MP.IsPlayerConnected(pid) then
            updatePlayerVehicleInfo(pid)
        end
    end
end


-- ** Chat Command Handlers **
-- These functions are called when a player uses a chat command.

-- Command: /help - Shows a list of available commands.
local function cmd_help(pid)
    local keys = { "help_title", "help_money", "help_who", "help_pay", "help_setlang", "help_repair" }
    for _, k in ipairs(keys) do sendTo(pid, tr_for_pid(pid, k)) end
end

-- Command: /money - Shows the player's current balance.
local function cmd_money(pid)
    local uid = ensure_account_for_pid(pid)
    sendTo(pid, tr_for_pid(pid, "balance", { money = get_money(uid) }))
    sendEconomyUIUpdate(pid)
end

-- Command: /who - Shows a list of connected players.
local function cmd_who(pid)
    sendTo(pid, tr_for_pid(pid, "who_title"))
    for id, name in pairs(MP.GetPlayers() or {}) do
        sendTo(id, ("      %d: %s"):format(id, name))
    end
end

-- Command: /pay <player_id> <amount> - Pays another player.
local function cmd_pay(pid, toStr, amtStr)
    local to = tonumber(toStr)
    local amt = tonumber(amtStr)
    if not to or not amt or not MP.IsPlayerConnected(to) or amt <= 0 then
        sendTo(pid, tr_for_pid(pid, "invalid_target"))
        return
    end
    local fromUID, toUID = ensure_account_for_pid(pid), ensure_account_for_pid(to)
    if get_money(fromUID) < amt then
        sendTo(pid, tr_for_pid(pid, "no_money"))
        return
    end
    add_money(fromUID, -amt)
    add_money(toUID, amt)
    sendTo(pid, tr_for_pid(pid, "pay_sent", { amount = amt, to = getPlayerNameSafe(to), money = get_money(fromUID) }))
    sendTo(to, tr_for_pid(to, "pay_received", { amount = amt, from = getPlayerNameSafe(pid), money = get_money(toUID) }))
    sendEconomyUIUpdate(pid)
    sendEconomyUIUpdate(to)
end

-- Main chat message handler. Parses the command and calls the appropriate function.
function ECON_onChat(pid, msg)
    local args = {}
    for arg in msg:gmatch("%S+") do table.insert(args, arg) end
    if #args == 0 then return end

    local cmd = args[1]:lower()
    if cmd == "/help" then
        cmd_help(pid)
    elseif cmd == "/money" then
        cmd_money(pid)
    elseif cmd == "/who" then
        cmd_who(pid)
    elseif cmd == "/pay" then
        cmd_pay(pid, args[2], args[3])
    elseif cmd == "/setlang" then
        ECON_onUI_setLanguage(pid, args[2])
    end
end

-- This is called by the UI when the player selects a new language.
function ECON_onUI_setLanguage(pid, langCode)
    if not translations[langCode] then
        sendTo(pid, tr_for_pid(pid, "lang_not_found", { supported_langs = table.concat(SUPPORTED_LANGS, ", ") }))
        return
    end

    local uid = ensure_account_for_pid(pid)
    accounts[uid].lang = langCode
    save_accounts()
    sendTo(pid, tr_for_pid(pid, "language_changed"))
    MP.TriggerClientEvent(pid, "receiveLanguage", langCode)
end

-- This is the main initialization function. It's called once when the script is loaded.
function ECON_onInit()
    load_config() 
    load_all_langs()
    load_accounts()

    -- Load timer intervals from the config file.
    local AUTOSAVE_INTERVAL_MS_VAL = (config.general and config.general.autosave_interval_ms) or FALLBACK_DEFAULTS.general.autosave_interval_ms
    local COOL_MESSAGE_INTERVAL_MS_VAL = (config.money and config.money.cool_message_interval_ms) or FALLBACK_DEFAULTS.money.cool_message_interval_ms
    local MONEY_PER_MINUTE_INTERVAL_MS_VAL = (config.money and config.money.money_per_minute_interval_ms) or FALLBACK_DEFAULTS.money.money_per_minute_interval_ms

    -- Create all the timers for recurring events.
    MP.CreateEventTimer("ECON_autosave", AUTOSAVE_INTERVAL_MS_VAL)
    MP.CreateEventTimer("ECON_cool_message", COOL_MESSAGE_INTERVAL_MS_VAL)
    MP.CreateEventTimer("ECON_add_money", MONEY_PER_MINUTE_INTERVAL_MS_VAL)
    MP.CreateEventTimer("ECON_welcome_checker", WELCOME_CHECK_INTERVAL)
    MP.CreateEventTimer("ECON_combined_checker", COMBINED_CHECK_INTERVAL)
    MP.CreateEventTimer("ECON_role_checker", 5000) -- Check roles every 5 seconds.

    log("EconomyTest initialized.")

    -- Register vehicle-related events to handle "wanted" status failures.
    MP.RegisterEvent("onVehicleEdited", "ECON_onVehicleEdited")
    MP.RegisterEvent("onPlayerChangeVehicle", "ECON_onChangeVehicle")
    MP.RegisterEvent("onVehicleReset", "ECON_onVehicleReset")
    MP.RegisterEvent("onPlayerExitVehicle", "ECON_onPlayerExitVehicle")
    MP.RegisterEvent("onVehicleDelete", "ECON_onVehicleDelete")
end

-- Function called by the autosave timer.
function ECON_onAutosave()
    save_accounts()
    log("Autosave complete.")
end

-- A table to keep track of delayed UI update timers for joining players.
local timers_data = {}
-- The callback function for the delayed UI update timer.
function __ECON_UI_DELAY_CALLBACK_HANDLER(event_name)
    local pid = timers_data[event_name]
    if event_name and pid then
        if MP and MP.IsPlayerConnected(pid) then
            sendEconomyUIUpdate(pid)
        end
        -- Clean up the event and timer after it has run.
        if MP and MP.UnregisterEvent then
            MP.UnregisterEvent(event_name)
        end
        timers_data[event_name] = nil
    end
end

-- Event handler: Called when a player joins the server.
function ECON_onJoin(pid)
    players_awaiting_welcome_sync[pid] = true
    ensure_account_for_pid(pid)

    -- Reset gameplay state for the joining player.
    player_zigzag_state[pid] = nil
    zigzag_cooldowns[pid] = nil
    busted_timers[pid] = nil

    -- Create a delayed timer to send the first UI update.
    -- This helps ensure the client-side UI is ready to receive it.
    local event_name = "__ECON_UI_DELAY_"..tostring(pid)
    timers_data[event_name] = pid
    MP.RegisterEvent(event_name, "__ECON_UI_DELAY_CALLBACK_HANDLER")
    MP.CreateEventTimer(event_name, 1500, 1) -- Runs once after 1.5 seconds.
end

-- Event handler: Called when a player disconnects.
function ECON_onLeave(pid)
    -- If the player was wanted, fail their status.
    if fail_wanted_status then
        pcall(fail_wanted_status, pid, "reason_player_left")
    end

    save_accounts()
    -- Clean up all data associated with the leaving player to prevent memory leaks.
    players_awaiting_welcome_sync[pid] = nil
    speeding_cooldowns[pid] = nil
    speeding_bonuses[pid] = nil
    zigzag_bonuses[pid] = nil
    player_zigzag_state[pid] = nil
    zigzag_cooldowns[pid] = nil
    busted_timers[pid] = nil

    -- Clean up any pending delayed UI update timers.
    local event_name = "__ECON_UI_DELAY_"..tostring(pid)
    if timers_data[event_name] then
        if MP and MP.UnregisterEvent then
            MP.UnregisterEvent(event_name)
        end
        timers_data[event_name] = nil
    end
end

-- Alias functions to match the timer names. These are called by the timers created in onInit.
function ECON_autosave() ECON_onAutosave() end
function ECON_cool_message() ECON_send_cool_message() end
function ECON_add_money() ECON_add_money_timer() end
function ECON_welcome_checker() ECON_check_and_send_welcomes() end
function ECON_combined_checker() ECON_check_all_player_updates() end
function ECON_role_checker() ECON_check_roles_timer() end


-- Register all primary event handlers with the server.
MP.RegisterEvent("onInit", "ECON_onInit")
MP.RegisterEvent("ECON_autosave", "ECON_autosave")
MP.RegisterEvent("onPlayerJoining", "ECON_onJoin")
MP.RegisterEvent("onPlayerDisconnect", "ECON_onLeave")
MP.RegisterEvent("onChatMessage", "ECON_onChat")
MP.RegisterEvent("ECON_cool_message", "ECON_cool_message")
MP.RegisterEvent("ECON_add_money", "ECON_add_money")
MP.RegisterEvent("ECON_welcome_checker", "ECON_welcome_checker")
MP.RegisterEvent("ECON_combined_checker", "ECON_combined_checker")
MP.RegisterEvent("ECON_role_checker", "ECON_role_checker")
-- Register an event that can be called from the client UI.
MP.RegisterEvent("setPlayerLanguage", "ECON_onUI_setLanguage")
