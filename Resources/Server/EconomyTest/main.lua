--[[
    EconomyTest Server-Side Script
    Author: 5DROR5
    Version: 1.0
    Description: This script manages the entire server-side economy system,
    including player accounts, money, roles, chat commands, and timed events.
]]

-- A placeholder for a plugin name, useful for logging.
local PLUGIN = "[EconomyTest]"

-- Safely attempts to load the JSON library. pcall (protected call) prevents errors if the library doesn't exist.
-- This is a fallback in case the built-in BeamMP JSON utility isn't available.
local ok_json, json = pcall(require, "json")
if not ok_json then json = nil end

-- =============================================================================
-- || CONFIGURATION & CONSTANTS                                             ||
-- =============================================================================

-- The default language code to use if a player hasn't set one.
local DEFAULT_LANG = "en"
-- A list of all supported language codes. The system will look for JSON files with these names.
local SUPPORTED_LANGS = { "he", "en", "ar" }
-- The root directory for this resource, used to locate other files like data and languages.
local ROOT = "Resources/Server/EconomyTest"
-- The directory where language translation files (.json) are stored.
local LANG_DIR = ROOT.. "/lang"
-- The file path for storing all player account data.
local ACCOUNTS_FILE = ROOT.. "/Data/players.DATA"

-- Time intervals for various automated tasks, in milliseconds.
local AUTOSAVE_INTERVAL_MS = 120000       -- How often to save player data to the file (e.g., every 2 minutes).
local COOL_MESSAGE_INTERVAL_MS = 30000    -- How often to send a fun message to all players (e.g., every 30 seconds).
local MONEY_PER_MINUTE_INTERVAL = 60000   -- How often to grant passive income to players (e.g., every 1 minute).
local MONEY_PER_MINUTE_AMOUNT = 10        -- The amount of money to give players each interval.
local WELCOME_CHECK_INTERVAL = 500        -- How often to check for new players who need a welcome message.
local COMBINED_CHECK_INTERVAL = 1000      -- How often to run frequent checks like player speed.
local SPEED_LIMIT_KMH = 100               -- The speed threshold for triggering the speeding bonus.
local SPEEDING_COOLDOWN_MS = 120000       -- Cooldown period before a player can start another speeding bonus session.

-- Tables to store runtime data.
local speeding_cooldowns = {} -- Stores cooldown timestamps for players who have recently completed a speeding bonus.
local speeding_bonuses = {}   -- Stores active speeding bonus data for players.
local translations = {}       -- A nested table to hold all loaded language strings. e.g., translations['en']['welcome_message']
local accounts = {}           -- The main table holding all player account data, indexed by UID.
local players_awaiting_welcome_sync = {} -- A temporary list of newly joined players.

-- A list of vehicle skin names that identify a player as being in a "police" role.
-- You can put the names of the parts you want to base on in a separate file with the appropriate reference.
local PoliceSkins = {
"autobello_skin_carabinieri",
"midtruck_skin_carabinieri",
"bastion_skin_policeb",
"legran_skin_police",
"nine_skin_police",
"burnside_skin_police",
"vivace_skin_polizia",
"vivace_skin_gendarmerie",
"bolide_skin_polizia",
"scintilla_skin_police",
"etk800_skin_police",
"etk800_skin_polizei",
"etk800_skin_polizia",
"etkc_skin_polizei",
"bluebuck_skin_police",
"bluebuck_skin_police2",
"pickup_skin_parkranger",
"fullsize_skin_bcpd",
"fullsize_skin_police",
"fullsize_skin_policeinterceptor",
"van_skin_glass_tint",
"van_skin_police_alt",
"md_series_reversewarn",
"roamer_skin_sheriff",
"roamer_skin_bcpd",
"sunburst2_skin_gendarmerie",
"sunburst2_skin_police",
"sunburst2_skin_policeBelasco",
"sunburst2_skin_policelnterceptor",
"sunburst2_skin_polizia",
"sunburst2_skin_polizia_alt",
"bx_skin_police",
"bx_skin_police_firwood",
"covet_skin_police",
"hopper_skin_sheriff",
"hopper_skin_parkranger",
"midsize_skin_statetrooper",
"lansdale_skin_security",
"lansdale_skin_police",
"wendover_skin_interceptor"
}

-- =============================================================================
-- || UTILITY FUNCTIONS                                                     ||
-- =============================================================================

-- A simple logging function to prefix all console messages for easier debugging.
local function log(msg)
    print(PLUGIN.. " ".. tostring(msg))
end

-- Checks if a file exists at the given path.
-- Returns true if the file exists, false otherwise.
local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

-- Safely reads the entire content of a file.
-- Returns the file content as a string, or nil if the file couldn't be read.
local function safe_read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a") -- "*a" means read the whole file
    f:close()
    return s
end

-- Safely writes content to a file, overwriting it if it exists.
-- Returns true on success, false on failure.
local function safe_write(path, content)
    local f = io.open(path, "w+") -- "w+" opens for writing, creates the file if it doesn't exist.
    if not f then
        log("ERROR: Could not open file for writing: ".. path)
        return false
    end
    -- Use a protected call (pcall) to write, catching potential errors.
    local ok, err = pcall(f.write, f, content)
    f:close()
    if not ok then
        log("ERROR writing file ".. path.. ": ".. tostring(err))
        return false
    end
    return true
end

-- =============================================================================
-- || JSON HANDLING FUNCTIONS                                               ||
-- =============================================================================

-- Encodes a Lua table into a JSON string.
-- It prioritizes the BeamMP built-in utility if available, otherwise falls back to the loaded 'json' library.
local function encode_json(tbl)
    if type(tbl) ~= "table" then return nil end
    -- Try BeamMP's utility first.
    if type(Util) == "table" and Util.JsonEncode then
        local ok, s = pcall(Util.JsonEncode, tbl)
        if ok and type(s) == "string" then return s end
    end
    -- Fallback to the standard json library.
    if json and json.encode then
        local ok, s = pcall(json.encode, tbl)
        if ok and type(s) == "string" then return s end
    end
    -- A very basic manual fallback for simple cases, just in case.
    if tbl.money ~= nil then
        return '{"money":'.. tostring(tbl.money).. '}'
    end
    return nil
end

-- Decodes a JSON string into a Lua table.
-- Similar to encode_json, it tries multiple methods to ensure compatibility.
local function decode_json(str)
    if type(str) ~= "string" then return nil end
    -- Try BeamMP's utility first.
    if type(Util) == "table" and Util.JsonDecode then
        local ok, t = pcall(Util.JsonDecode, str)
        if ok and type(t) == "table" then return t end
    end
    -- Fallback to the standard json library.
    if json and json.decode then
        local ok, t = pcall(json.decode, str)
        if ok and type(t) == "table" then return t end
    end
    return nil
end

-- Loads and decodes a JSON file from a given path.
-- Returns a Lua table, or an empty table if the file is empty, missing, or corrupt.
local function json_load(path)
    local s = safe_read(path)
    if not s or s == "" then return {} end -- Return empty table for empty or unreadable file.
    
    local ok, tbl = pcall(function() return decode_json(s) end)
    if ok and type(tbl) == "table" then return tbl end
    
    -- If the primary decode failed, try the Util decoder directly as another fallback.
    if type(Util) == "table" and Util.JsonDecode then
        local ok2, tbl2 = pcall(Util.JsonDecode, s)
        if ok2 and type(tbl2) == "table" then return tbl2 end
    end
    
    log("ERROR decoding JSON from ".. path.. ": ".. tostring(tbl))
    -- If the file is corrupt, remove it to prevent future errors.
    if FS and FS.Remove then pcall(FS.Remove, path) end
    return {}
end

-- Atomically saves a Lua table to a JSON file.
-- This prevents data corruption by first writing to a temporary file,
-- then renaming it to the final destination. If any step fails, the original file remains intact.
local function atomic_json_save(path, tbl)
    local s = encode_json(tbl)
    if not s then
        log("ERROR encoding JSON for ".. path)
        return false
    end
    local temp_path = path.. ".tmp"
    if not safe_write(temp_path, s) then return false end
    
    -- Use the filesystem's rename operation, which is typically atomic.
    if FS and FS.Rename then
        local ok, err = pcall(FS.Rename, temp_path, path)
        if not ok then
            pcall(FS.Remove, temp_path) -- Clean up the temp file on failure.
            log("ERROR renaming temp file: ".. tostring(err))
            return false
        end
        return true
    else
        -- Fallback to a simple write if atomic rename is not available.
        return safe_write(path, s)
    end
end

-- =============================================================================
-- || LANGUAGE & TRANSLATION FUNCTIONS                                      ||
-- =============================================================================

-- Loads a single language file based on its language code (e.g., "en").
local function load_lang_file(code)
    local path = LANG_DIR.. "/".. code.. ".json"
    if not file_exists(path) then return nil end
    return json_load(path)
end

-- Loads all supported languages from their JSON files into the `translations` table.
local function load_all_langs()
    translations = {}
    for _, code in ipairs(SUPPORTED_LANGS) do
        translations[code] = load_lang_file(code) or {}
    end
    log("Loaded languages: ".. table.concat(SUPPORTED_LANGS, ", "))
end

-- =============================================================================
-- || PLAYER DATA & ACCOUNT MANAGEMENT                                      ||
-- =============================================================================

-- Gets a unique identifier (UID) for a player.
-- It prioritizes BeamMP ID, then Steam ID, etc., ensuring a consistent ID across sessions.
local function getUID(pid)
    local ids = {}
    if MP and MP.GetPlayerIdentifiers then
        ids = MP.GetPlayerIdentifiers(pid) or {}
    end
    -- Return the first available identifier in order of preference.
    return ids.beammp or ids.steam or ids.license or ("pid:".. tostring(pid))
end

-- Safely gets a player's name. If the API fails, it returns a generic name.
local function getPlayerNameSafe(pid)
    if MP and MP.GetPlayerName then
        local ok, name = pcall(MP.GetPlayerName, pid)
        return ok and name or ("Player".. tostring(pid))
    end
    return ("Player".. tostring(pid))
end

-- Retrieves the language setting for a specific player.
local function get_player_lang(pid)
    local uid = getUID(pid)
    return (accounts[uid] and accounts[uid].lang) or DEFAULT_LANG
end

-- Translates a given key into the player's selected language.
-- It can also replace variables in the string (e.g., "${money}").
local function tr_for_pid(pid, key, vars)
    local lang = get_player_lang(pid)
    -- Get the base text, falling back to the key itself if not found.
    local text = (translations[lang] or {})[key] or key
    -- If variables are provided, substitute them into the text.
    if vars then
        for k,v in pairs(vars) do
            text = text:gsub("${".. k.. "}", tostring(v))
        end
    end
    return text
end

-- Ensures that an account exists for a given player ID.
-- If no account exists, it creates a new one with default values.
-- Returns the player's UID.
local function ensure_account_for_pid(pid)
    local uid = getUID(pid)
    if not accounts[uid] then
        accounts[uid] = { money = 1000, lang = DEFAULT_LANG, role = "civilian" }
    end
    return uid
end

-- Gets the money balance for a given UID.
local function get_money(uid)
    return (accounts[uid] and accounts[uid].money) or 0
end

-- Adds (or removes, if amt is negative) money from a player's account.
-- Ensures the balance never drops below zero.
local function add_money(uid, amt)
    amt = tonumber(amt) or 0
    -- If the account doesn't exist for some reason, create it.
    accounts[uid] = accounts[uid] or { money = 0, lang = DEFAULT_LANG, role="civilian" }
    accounts[uid].money = math.max(0, (accounts[uid].money or 0) + amt)
end

-- Loads all player accounts from the data file into memory.
local function load_accounts()
    accounts = file_exists(ACCOUNTS_FILE) and json_load(ACCOUNTS_FILE) or {}
    local count = 0
    for _,_ in pairs(accounts) do count = count + 1 end
    log("Loaded accounts: ".. tostring(count))
end

-- Saves the current state of all player accounts to the data file.
local function save_accounts()
    atomic_json_save(ACCOUNTS_FILE, accounts)
end

-- =============================================================================
-- || COMMUNICATION FUNCTIONS                                               ||
-- =============================================================================

-- Sends a chat message to a single player.
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

-- Sends an economy UI update event to a specific player's client.
-- This tells the client-side UI to refresh the money display.
local function sendEconomyUIUpdate(pid)
    if not (MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid)) then return end
    local uid = getUID(pid)
    local playerData = accounts[uid]
    if not playerData then return end

    -- Prepare the data payload.
    local payload_tbl = { money = tonumber(playerData.money) or 0 }
    local payload_str = encode_json(payload_tbl)
    
    -- Fallback if JSON encoding fails.
    if not payload_str then
        payload_str = tostring(payload_tbl.money)
    end

    if not payload_str then
        log("[EconomyUI]: ERROR generating payload for PID=".. tostring(pid))
        return
    end

    -- Trigger the client-side event.
    local ok, err = pcall(function()
        MP.TriggerClientEvent(pid, "receiveMoney", payload_str)
    end)
    if ok then
         log("[EconomyUI]: Sent UI update for PID: ".. tostring(pid).. " payload=".. tostring(payload_str))
    else
        log("[EconomyUI]: ERROR sending UI update PID=".. tostring(pid).. " err=".. tostring(err))
    end
end

-- =============================================================================
-- || TIMED EVENTS & CORE LOGIC                                             ||
-- =============================================================================

-- Sends a "cool player message" to everyone, triggered by a timer.
local function ECON_send_cool_message()
    for pid,_ in pairs(MP.GetPlayers() or {}) do
        sendTo(pid, tr_for_pid(pid, "cool_player_message"))
    end
end

-- The main function for the passive income timer.
-- It iterates through all players and adds money to their accounts.
function ECON_add_money_timer()
    log("ECON_add_money_timer tick")
    for pid,_ in pairs(MP.GetPlayers() or {}) do
        local uid = ensure_account_for_pid(pid)
        add_money(uid, MONEY_PER_MINUTE_AMOUNT)
        log(string.format("Added %d to UID=%s new_bal=%s", MONEY_PER_MINUTE_AMOUNT, tostring(uid), tostring(get_money(uid))))
        -- Notify the player and update their UI.
        sendTo(pid, tr_for_pid(pid, "added_money_per_minute", { money=get_money(uid) }))
        sendEconomyUIUpdate(pid)
    end
end

-- Checks for newly joined players and sends them a welcome message.
-- This is done in a timer to ensure the player is fully loaded into the game.
local function ECON_check_and_send_welcomes()
    for pid,_ in pairs(players_awaiting_welcome_sync) do
        if MP.IsPlayerConnected(pid) then
            sendTo(pid, tr_for_pid(pid, "welcome_server"))
            sendEconomyUIUpdate(pid)
            -- Remove the player from the list once the message is sent.
            players_awaiting_welcome_sync[pid] = nil
        end
    end
end

-- Updates a player's role (civilian/police) based on their current vehicle's skin.
local function updatePlayerVehicleInfo(pid)
    if not (MP and MP.GetPlayerVehicles) then return end
    local vehicles = MP.GetPlayerVehicles(pid)
    if not vehicles or type(vehicles) ~= "table" then
        -- If player has no vehicle, ensure they are a civilian.
        local uid = ensure_account_for_pid(pid)
        if accounts[uid].role ~= "civilian" then
            accounts[uid].role = "civilian"
            sendTo(pid, tr_for_pid(pid, "welcome_civilian"))
            sendEconomyUIUpdate(pid)
        end
        return
    end
    for _, v in pairs(vehicles) do
        if type(v) == "string" then
            -- Vehicle data is often a JSON string, so we extract it.
            local json_match = v:match("{.*}")
            if json_match then
                local ok, data = pcall(function() return decode_json(json_match) end)
                if ok and type(data) == "table" then
                    -- Extract skin information from the vehicle data.
                    local vehSkin = (data.vcf and data.vcf.partConfigFilename) or "default_skin"
                    local vehPaint = (data.vcf and data.vcf.parts and data.vcf.parts.paint_design)
                    local uid = ensure_account_for_pid(pid)
                    local oldRole = accounts[uid].role or "civilian"
                    local newRole = "civilian"
                    -- Check if the skin matches any of the police skins.
                    for _, skin in ipairs(PoliceSkins) do
                        if vehSkin == skin or vehPaint == skin then newRole = "police"; break end
                    end
                    -- If the role has changed, update the account and notify the player.
                    if oldRole ~= newRole then
                        accounts[uid].role = newRole
                        sendTo(pid, tr_for_pid(pid, newRole == "police" and "welcome_police" or "welcome_civilian"))
                        sendEconomyUIUpdate(pid)
                    end
                    return -- Stop after processing the first valid vehicle.
                end
            end
        end
    end
    -- If no police vehicle was found, ensure role is civilian.
    local uid = ensure_account_for_pid(pid)
    if accounts[uid].role ~= "civilian" then
        accounts[uid].role = "civilian"
        sendTo(pid, tr_for_pid(pid, "welcome_civilian"))
        sendEconomyUIUpdate(pid)
    end
end

-- Handles the logic for starting a speeding bonus for a civilian player.
local function handle_speeding(pid, speed)
    local now = os.time() * 1000 -- current time in milliseconds
    -- Check if the player is on cooldown.
    if speeding_cooldowns[pid] and now - speeding_cooldowns[pid] < SPEEDING_COOLDOWN_MS then
        return
    end
    local uid = getUID(pid)
    -- Only civilians can get a speeding bonus.
    if accounts[uid] and accounts[uid].role == "civilian" then
        speeding_bonuses[pid] = { startTime = now, lastPayment = now }
        speeding_cooldowns[pid] = now -- Start the cooldown immediately.
        sendTo(pid, tr_for_pid(pid, "speed_bonus_start"))
    end
end

-- A combined check that runs frequently for all players.
-- Currently, it checks player speed and manages speeding bonus payouts.
local function ECON_check_all_player_updates()
    local now = os.time() * 1000
    for pid,_ in pairs(MP.GetPlayers() or {}) do
        if MP.IsPlayerConnected(pid) then
            -- Get player's current speed.
            local ok, pos = pcall(MP.GetPositionRaw, pid, 0)
            if ok and pos and pos.vel then
                local speed = math.sqrt((pos.vel[1] or 0)^2 + (pos.vel[2] or 0)^2) * 3.6 -- m/s to km/h
                if speed > SPEED_LIMIT_KMH then
                    pcall(handle_speeding, pid, speed)
                end
            end
        end
    end

    -- Process active speeding bonuses.
    local players_to_remove = {}
    for pid, bonus_data in pairs(speeding_bonuses) do
        local elapsed = now - bonus_data.startTime
        local uid = getUID(pid)
        local seconds_passed = math.floor(elapsed / 1000)
        local seconds_last_paid = math.floor((bonus_data.lastPayment - bonus_data.startTime) / 1000)
        -- Pay $1 for each second they've been speeding.
        if seconds_passed > seconds_last_paid then
            add_money(uid, seconds_passed - seconds_last_paid)
            bonus_data.lastPayment = now
            sendEconomyUIUpdate(pid)
        end
        -- End the bonus after 1 minute (60000 ms).
        if elapsed >= 60000 then
            if MP.IsPlayerConnected(pid) then
                add_money(uid, 50) -- Add the final bonus amount.
                sendTo(pid, tr_for_pid(pid, "speed_bonus_end"))
                sendEconomyUIUpdate(pid)
            end
            table.insert(players_to_remove, pid)
        end
    end
    -- Clean up finished bonuses.
    for _, pid in ipairs(players_to_remove) do speeding_bonuses[pid] = nil end
end

-- The timer function that calls the role checker for all players.
function ECON_check_roles_timer()
    local players = MP.GetPlayers() or {}
    for pid, _ in pairs(players) do
        if MP.IsPlayerConnected(pid) then
            updatePlayerVehicleInfo(pid)
        end
    end
end

-- =============================================================================
-- || CHAT COMMANDS                                                         ||
-- =============================================================================

-- Displays a list of available commands to the player.
local function cmd_help(pid)
    local keys = { "help_title", "help_money", "help_who", "help_pay", "help_catch", "help_setlang", "help_repair" }
    for _, k in ipairs(keys) do sendTo(pid, tr_for_pid(pid, k)) end
end

-- Displays the player's current money balance.
local function cmd_money(pid)
    local uid = ensure_account_for_pid(pid)
    sendTo(pid, tr_for_pid(pid, "balance", { money = get_money(uid) }))
    sendEconomyUIUpdate(pid)
end

-- Displays a list of all connected players and their IDs.
local function cmd_who(pid)
    sendTo(pid, tr_for_pid(pid, "who_title"))
    for id, name in pairs(MP.GetPlayers() or {}) do
        sendTo(pid, ("      %d: %s"):format(id, name))
    end
end

-- Allows a player to pay money to another player.
local function cmd_pay(pid, toStr, amtStr)
    local to = tonumber(toStr)
    local amt = tonumber(amtStr)
    -- Input validation.
    if not to or not amt or not MP.IsPlayerConnected(to) or amt <= 0 then
        sendTo(pid, tr_for_pid(pid, "invalid_target"))
        return
    end
    local fromUID, toUID = ensure_account_for_pid(pid), ensure_account_for_pid(to)
    -- Check if the sender has enough money.
    if get_money(fromUID) < amt then
        sendTo(pid, tr_for_pid(pid, "no_money"))
        return
    end
    -- Perform the transaction.
    add_money(fromUID, -amt)
    add_money(toUID, amt)
    -- Notify both players and update their UIs.
    sendTo(pid, tr_for_pid(pid, "pay_sent", { amount = amt, to = getPlayerNameSafe(to), money = get_money(fromUID) }))
    sendTo(to, tr_for_pid(to, "pay_received", { amount = amt, from = getPlayerNameSafe(pid), money = get_money(toUID) }))
    sendEconomyUIUpdate(pid)
    sendEconomyUIUpdate(to)
end

-- Handles the request from the client's UI to change language.
function ECON_onUI_setLanguage(pid, langCode)
    if not translations[langCode] then
        sendTo(pid, tr_for_pid(pid, "lang_not_found", { supported_langs = table.concat(SUPPORTED_LANGS, ", ") }))
        return
    end
    
    local uid = ensure_account_for_pid(pid)
    accounts[uid].lang = langCode
    save_accounts() -- Save the change immediately.
    sendTo(pid, tr_for_pid(pid, "language_changed"))
    -- Also tell the client UI that the language has been set, for confirmation.
    MP.TriggerClientEvent(pid, "receiveLanguage", langCode)
end

-- Allows a police player to "catch" a civilian player.
local function cmd_catch(pid, targetStr)
    local target = tonumber(targetStr)
    if not target or not MP.IsPlayerConnected(target) then
        sendTo(pid, tr_for_pid(pid, "invalid_target"))
        return
    end
    local copUID, targetUID = ensure_account_for_pid(pid), getUID(target)
    -- Check if the roles are correct for a catch.
    if accounts[copUID].role == "police" and accounts[targetUID].role == "civilian" then
        add_money(copUID, 500) -- Reward the cop.
        -- Announce the catch to the whole server.
        for id, _ in pairs(MP.GetPlayers() or {}) do
            sendTo(id, tr_for_pid(id, "caught", { cop=getPlayerNameSafe(pid), criminal=getPlayerNameSafe(target) }))
        end
        sendEconomyUIUpdate(pid)
    else
        sendTo(pid, tr_for_pid(pid, "invalid_catch"))
    end
end

-- =============================================================================
-- || INITIALIZATION & EVENT HANDLERS                                       ||
-- =============================================================================

-- The main initialization function, called when the server script starts.
function ECON_onInit()
    load_all_langs()
    load_accounts()
    -- Create all the timers that run the core logic.
    MP.CreateEventTimer("ECON_autosave", AUTOSAVE_INTERVAL_MS)
    MP.CreateEventTimer("ECON_cool_message", COOL_MESSAGE_INTERVAL_MS)
    MP.CreateEventTimer("ECON_add_money", MONEY_PER_MINUTE_INTERVAL)
    MP.CreateEventTimer("ECON_welcome_checker", WELCOME_CHECK_INTERVAL)
    MP.CreateEventTimer("ECON_combined_checker", COMBINED_CHECK_INTERVAL)
    MP.CreateEventTimer("ECON_role_checker", 5000)
    
    log("EconomyTest initialized.")
    MP.RegisterEvent("onVehicleEdited", "ECON_onVehicleEdited")
end

-- Called by the ECON_autosave timer.
function ECON_onAutosave()
    save_accounts()
    log("Autosave complete.")
end

-- A small system to delay the initial UI update for a joining player.
-- This ensures the UI is ready to receive the data.
local timers_data = {}
function __ECON_UI_DELAY_CALLBACK_HANDLER(event_name)
    local pid = timers_data[event_name]
    if event_name and pid then
        if MP and MP.IsPlayerConnected(pid) then
            sendEconomyUIUpdate(pid)
        end
        -- Clean up the event and timer.
        if MP and MP.UnregisterEvent then
            MP.UnregisterEvent(event_name)
        end
        timers_data[event_name] = nil
    end
end

-- Called when a player joins the server.
function ECON_onJoin(pid)
    players_awaiting_welcome_sync[pid] = true
    ensure_account_for_pid(pid)
    
    -- Create a unique, one-time timer to send the first UI update.
    local event_name = "__ECON_UI_DELAY_"..tostring(pid)    
    timers_data[event_name] = pid    
    MP.RegisterEvent(event_name, "__ECON_UI_DELAY_CALLBACK_HANDLER")
    MP.CreateEventTimer(event_name, 1000, 1) -- Fire once after 1 second.
end

-- Called when a player leaves the server.
function ECON_onLeave(pid)
    save_accounts() -- Save all data when a player leaves.
    -- Clean up any runtime data associated with the player.
    speeding_cooldowns[pid] = nil
    players_awaiting_welcome_sync[pid] = nil
    speeding_bonuses[pid] = nil
    
    -- Clean up the delay timer if the player leaves before it fires.
    local event_name = "__ECON_UI_DELAY_"..tostring(pid)
    if timers_data[event_name] then
        if MP and MP.UnregisterEvent then
            MP.UnregisterEvent(event_name)
        end
        timers_data[event_name] = nil
    end
end

-- Simple alias functions to link timers to their logic.
function ECON_autosave() ECON_onAutosave() end
function ECON_cool_message() ECON_send_cool_message() end
function ECON_add_money() ECON_add_money_timer() end
function ECON_welcome_checker() ECON_check_and_send_welcomes() end
function ECON_combined_checker() ECON_check_all_player_updates() end
function ECON_role_checker() ECON_check_roles_timer() end

-- Register all necessary BeamMP events to their corresponding functions.
MP.RegisterEvent("onInit", "ECON_onInit")
MP.RegisterEvent("ECON_autosave", "ECON_autosave")
MP.RegisterEvent("onPlayerJoining", "ECON_onJoin")
MP.RegisterEvent("onPlayerDisconnect", "ECON_onLeave")
MP.RegisterEvent("onChatMessage", "ECON_onChat")
MP.RegisterEvent("onPlayerChangeVehicle", "ECON_onChangeVehicle")
MP.RegisterEvent("ECON_cool_message", "ECON_cool_message")
MP.RegisterEvent("ECON_add_money", "ECON_add_money")
MP.RegisterEvent("ECON_welcome_checker", "ECON_welcome_checker")
MP.RegisterEvent("ECON_combined_checker", "ECON_combined_checker")
MP.RegisterEvent("onVehicleEdited", "ECON_onVehicleEdited")
MP.RegisterEvent("ECON_role_checker", "ECON_role_checker")
MP.RegisterEvent("setPlayerLanguage", "ECON_onUI_setLanguage")
