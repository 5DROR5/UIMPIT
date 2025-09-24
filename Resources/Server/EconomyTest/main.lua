--[[
    EconomyTest Server-Side Script
    Author: 5DROR5
    Version: 1.1
    Description: This script manages the entire server-side economy system,
    including player accounts, money, roles, chat commands, and timed events.
]]

-- =============================================================================
-- || CONSTANTS & INITIAL TABLES                                             ||
-- =============================================================================

-- Plugin identifier used in log output so we can find messages from this module easily.
local PLUGIN = "[EconomyTest]"

-- Table for storing zigzag cooldown timestamps per player (keyed by PID).
local zigzag_cooldowns = {}

-- Load the math module and create local shortcuts for rad/deg conversions to make
-- subsequent code shorter and clearer.
local math = require("math")
local rad = math.rad
local deg = math.deg

-- Try to require a JSON module in a protected call so the script doesn't crash if
-- the runtime doesn't provide a json library. If requiring fails, json becomes nil
-- and the code uses other fallbacks.
local ok_json, json = pcall(require, "json")
if not ok_json then json = nil end

-- Default language code and the list of supported language codes. These are used
-- when selecting translations for messages sent to players.
local DEFAULT_LANG = "en"
local SUPPORTED_LANGS = { "he", "en", "ar" }

-- Paths used by the script. If you move the resource folder, update ROOT.
local ROOT = "Resources/Server/EconomyTest"
local LANG_DIR = ROOT.. "/lang"
local ACCOUNTS_FILE = ROOT.. "/Data/players.DATA"

-- External list of police skins. This file should return a table of skin names.
local PoliceSkins = require("PoliceSkins")

-- ======= Timers / configurable defaults (change these to tune behavior) ======
-- Autosave interval in milliseconds. Default: 120000ms = 2 minutes.
local AUTOSAVE_INTERVAL_MS = 120000       
-- Interval for sending a periodic "cool" message to players. Default: 30s.
local COOL_MESSAGE_INTERVAL_MS = 30000    
-- Interval used to add money periodically (in ms). Default: 60s.
local MONEY_PER_MINUTE_INTERVAL = 60000   
-- Amount granted each MONEY_PER_MINUTE_INTERVAL tick. Default: 10.
local MONEY_PER_MINUTE_AMOUNT = 10        
-- How often we attempt to send the welcome message (used to wait for UI ready).
local WELCOME_CHECK_INTERVAL = 500        
-- Main combined update loop interval in milliseconds — runs checks such as
-- speeding and zigzag detection. Default: 1000ms (1 second).
local COMBINED_CHECK_INTERVAL = 1000      
-- Speed threshold in km/h for considering a vehicle to be "speeding".
local SPEED_LIMIT_KMH = 100               
-- Minimum cooldown between speeding events per-player (milliseconds).
local SPEEDING_COOLDOWN_MS = 120000       

-- Runtime tables used to track bonuses, translations, accounts, and states.
local speeding_cooldowns = {} 
local speeding_bonuses = {}  
local translations = {}      
local accounts = {}          
local players_awaiting_welcome_sync = {}
local zigzag_bonuses = {}        
local zigzag_last_angle = {}     
local zigzag_last_direction = {} 
local player_zigzag_state = {} 

-- Zigzag-specific configuration. Tweak these to make the zigzag bonus easier
-- or harder to obtain, or to change payout behavior.
local ZIGZAG_BONUS_DURATION_MS = 120000   -- How long the zigzag bonus lasts (ms).
local ZIGZAG_COOLDOWN_MS = 60000         -- Additional cooldown after a zigzag finishes.
local ZIGZAG_FINAL_BONUS_AMOUNT = 50     -- Lump-sum final reward at end of zigzag run.
local MIN_SPEED_KMH_FOR_ZIGZAG = 10       -- Minimum speed to consider zigzag detection.
local ZIGZAG_MIN_TURNS = 5               -- How many alternating turns constitute a zigzag.
local ZIGZAG_MIN_DELTA_ANGLE = math.rad(1) -- Minimum angle change between samples (radians).
local ZIGZAG_PRORATED_BONUS = 5          -- Amount per second paid while running the zigzag bonus.

-- =============================================================================
-- || HELPER MATH / SMALL UTILITIES                                          ||
-- =============================================================================

-- atan2 implementation: Lua's math library doesn't always provide atan2, so we
-- implement a robust version that returns angle in radians in range [-pi, pi].
-- Inputs: y (vertical component), x (horizontal component).
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

-- Simple logging helper that prefixes messages with the plugin tag so logs are
-- easy to filter.
local function log(msg)
    print(PLUGIN.. " ".. tostring(msg))
end

-- =============================================================================
-- || FILE IO / JSON HELPERS                                                 ||
-- =============================================================================

-- Check whether a file exists by trying to open it for reading. Returns true
-- if open succeeds, false otherwise. Used before attempting to read files.
local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

-- Read the full contents of a file safely. Returns the file string or nil if
-- the file could not be opened. Caller must handle nil.
local function safe_read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a") 
    f:close()
    return s
end

-- Write content to a file in "w+" mode. Returns true on success, false on
-- failure. Uses pcall around f.write to catch any write-time errors.
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

-- Encode a Lua table into JSON. This function attempts several backends in the
-- following order: Util.JsonEncode (BeamMP helper), the required json module,
-- and finally a simple fallback that encodes only a table with a 'money' field.
-- Returns the JSON string or nil on failure.
local function encode_json(tbl)
    if type(tbl) ~= "table" then return nil end
    if type(Util) == "table" and Util.JsonEncode then
        local ok, s = pcall(Util.JsonEncode, tbl)
        if ok and type(s) == "string" then return s end
    end
    if json and json.encode then
        local ok, s = pcall(json.encode, tbl)
        if ok and type(s) == "string" then return s end
    end
    -- Very small fallback used by this plugin when only money is required.
    if tbl.money ~= nil then
        return '{"money":'.. tostring(tbl.money).. '}'
    end
    return nil
end

-- Decode JSON string into a Lua table. Tries Util.JsonDecode and the json
-- module; returns nil if decoding fails.
local function decode_json(str)
    if type(str) ~= "string" then return nil end
    if type(Util) == "table" and Util.JsonDecode then
        local ok, t = pcall(Util.JsonDecode, str)
        if ok and type(t) == "table" then return t end
    end
    if json and json.decode then
        local ok, t = pcall(json.decode, str)
        if ok and type(t) == "table" then return t end
    end
    return nil
end

-- Load JSON file into a Lua table using safe_read + decode_json. If parsing
-- fails the file is removed (if FS.Remove is available) and an empty table is returned.
local function json_load(path)
    local s = safe_read(path)
    if not s or s == "" then return {} end 
    
    local ok, tbl = pcall(function() return decode_json(s) end)
    if ok and type(tbl) == "table" then return tbl end
    
    if type(Util) == "table" and Util.JsonDecode then
        local ok2, tbl2 = pcall(Util.JsonDecode, s)
        if ok2 and type(tbl2) == "table" then return tbl2 end
    end
    
    log("ERROR decoding JSON from ".. path.. ": ".. tostring(tbl))
    if FS and FS.Remove then pcall(FS.Remove, path) end
    return {}
end

-- Atomic save helper: write JSON to temp file and rename. If FS.Rename is
-- available it uses that (atomic on many platforms); otherwise falls back to
-- direct write.
local function atomic_json_save(path, tbl)
    local s = encode_json(tbl)
    if not s then
        log("ERROR encoding JSON for ".. path)
        return false
    end
    local temp_path = path.. ".tmp"
    if not safe_write(temp_path, s) then return false end
    
    if FS and FS.Rename then
        local ok, err = pcall(FS.Rename, temp_path, path)
        if not ok then
            pcall(FS.Remove, temp_path) 
            log("ERROR renaming temp file: ".. tostring(err))
            return false
        end
        return true
    else
        return safe_write(path, s)
    end
end

-- =============================================================================
-- || LANGUAGE / TRANSLATION HELPERS                                        ||
-- =============================================================================

-- Load a single language file (e.g. en.json / he.json). Returns the decoded
-- table or nil if file does not exist.
local function load_lang_file(code)
    local path = LANG_DIR.. "/".. code.. ".json"
    if not file_exists(path) then return nil end
    return json_load(path)
end

-- Load all supported languages into the global translations table. Missing
-- language files become empty tables so code can safely attempt lookups.
local function load_all_langs()
    translations = {}
    for _, code in ipairs(SUPPORTED_LANGS) do
        translations[code] = load_lang_file(code) or {}
    end
    log("Loaded languages: ".. table.concat(SUPPORTED_LANGS, ", "))
end

-- =============================================================================
-- || PLAYER IDENTIFIERS / NAMES / LANGUAGE                                  ||
-- =============================================================================

-- Resolve a stable UID for a PID. The function tries beammp id, steam id,
-- license id, and finally falls back to "pid:<pid>" so we always have a unique key.
local function getUID(pid)
    local ids = {}
    if MP and MP.GetPlayerIdentifiers then
        ids = MP.GetPlayerIdentifiers(pid) or {}
    end
    return ids.beammp or ids.steam or ids.license or ("pid:".. tostring(pid))
end

-- Safe wrapper for MP.GetPlayerName with pcall fallback so the server won't error
-- if the MP API behaves unexpectedly.
local function getPlayerNameSafe(pid)
    if MP and MP.GetPlayerName then
        local ok, name = pcall(MP.GetPlayerName, pid)
        return ok and name or ("Player".. tostring(pid))
    end
    return ("Player".. tostring(pid))
end

-- Get the language code for a player (based on account settings) or return
-- DEFAULT_LANG when none is set.
local function get_player_lang(pid)
    local uid = getUID(pid)
    return (accounts[uid] and accounts[uid].lang) or DEFAULT_LANG
end

-- Translate a key for a given pid and expand ${var} placeholders from vars table.
-- If translation not found we return the key itself (useful during development).
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

-- =============================================================================
-- || ACCOUNT MANAGEMENT                                                     ||
-- =============================================================================

-- Ensure an account exists for a PID; if not, create it with sensible defaults.
-- Default money is 1000 and default role is "civilian". Change these defaults
-- freely according to your server economy balance plan.
local function ensure_account_for_pid(pid)
    local uid = getUID(pid)
    if not accounts[uid] then
        accounts[uid] = { money = 1000, lang = DEFAULT_LANG, role = "civilian" }
    end
    return uid
end

-- Read-only accessor for money of a UID (returns 0 when account absent).
local function get_money(uid)
    return (accounts[uid] and accounts[uid].money) or 0
end

-- Safely add money to an account. amt is converted to number and floor/ceil is
-- intentionally not used — we keep decimals if passed. Money is clamped to >= 0.
local function add_money(uid, amt)
    amt = tonumber(amt) or 0
    accounts[uid] = accounts[uid] or { money = 0, lang = DEFAULT_LANG, role="civilian" }
    accounts[uid].money = math.max(0, (accounts[uid].money or 0) + amt)
end

-- Load accounts from disk; if file missing, create empty accounts table. Logs
-- number of loaded accounts for debugging.
local function load_accounts()
    accounts = file_exists(ACCOUNTS_FILE) and json_load(ACCOUNTS_FILE) or {}
    local count = 0
    for _,_ in pairs(accounts) do count = count + 1 end
    log("Loaded accounts: ".. tostring(count))
end

-- Persist accounts to disk using atomic_json_save for safety.
local function save_accounts()
    atomic_json_save(ACCOUNTS_FILE, accounts)
end

-- =============================================================================
-- || CHAT / UI HELPERS                                                      ||
-- =============================================================================

-- Send a chat message to a single player; uses pcall to ensure MP.SendChatMessage
-- errors do not crash the plugin. Only sends if player is connected.
local function sendTo(pid, msg)
    if MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid) then
        local ok, err = pcall(MP.SendChatMessage, pid, msg)
        if not ok then log("ERROR sending message to ".. tostring(pid).. ": ".. tostring(err)) end
    end
end

-- Broadcast a message to all connected players.
local function sendAll(msg)
    for pid,_ in pairs(MP.GetPlayers() or {}) do sendTo(pid, msg) end
end

-- Update the client UI about the player's money. Tries to encode the payload
-- as JSON, but falls back to a plain string if encoding is unavailable.
local function sendEconomyUIUpdate(pid)
    if not (MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid)) then return end
    local uid = getUID(pid)
    local playerData = accounts[uid]
    if not playerData then return end

    local payload_tbl = { money = tonumber(playerData.money) or 0 }
    local payload_str = encode_json(payload_tbl)
    
    if not payload_str then
        payload_str = tostring(payload_tbl.money)
    end

    if not payload_str then
        log("[EconomyUI]: ERROR generating payload for PID=".. tostring(pid))
        return
    end

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
-- || MESSAGES / TIMED EVENTS                                                 ||
-- =============================================================================

-- Send a periodic "cool message" to all players (text key resolved per-player).
local function ECON_send_cool_message()
    for pid,_ in pairs(MP.GetPlayers() or {}) do
        sendTo(pid, tr_for_pid(pid, "cool_player_message"))
    end
end

-- Periodic timer function that grants MONEY_PER_MINUTE_AMOUNT to each player.
-- Default behavior: every MONEY_PER_MINUTE_INTERVAL ms add MONEY_PER_MINUTE_AMOUNT.
function ECON_add_money_timer()
    log("ECON_add_money_timer tick")
    for pid,_ in pairs(MP.GetPlayers() or {}) do
        local uid = ensure_account_for_pid(pid)
        add_money(uid, MONEY_PER_MINUTE_AMOUNT)
        log(string.format("Added %d to UID=%s new_bal=%s", MONEY_PER_MINUTE_AMOUNT, tostring(uid), tostring(get_money(uid))))
        sendTo(pid, tr_for_pid(pid, "added_money_per_minute", { money=get_money(uid) }))
        sendEconomyUIUpdate(pid)
    end
end

-- Welcome sync: some clients need a small delay before receiving UI updates or
-- welcome text; this routine sends them after we flagged them in ECON_onJoin.
local function ECON_check_and_send_welcomes()
    for pid,_ in pairs(players_awaiting_welcome_sync) do
        if MP.IsPlayerConnected(pid) then
            sendTo(pid, tr_for_pid(pid, "welcome_server"))
            sendEconomyUIUpdate(pid)
            players_awaiting_welcome_sync[pid] = nil
        end
    end
end

-- =============================================================================
-- || VEHICLE / ROLE DETECTION                                                ||
-- =============================================================================

-- Update player's role (civilian/police) based on their vehicle skin/paint.
-- This function reads vehicles returned by MP.GetPlayerVehicles and tries to
-- decode a JSON snippet to find vcf.partConfigFilename and paint_design.
local function updatePlayerVehicleInfo(pid)
    if not (MP and MP.GetPlayerVehicles) then return end
    local vehicles = MP.GetPlayerVehicles(pid)
    if not vehicles or type(vehicles) ~= "table" then
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
            local json_match = v:match("{.*}")
            if json_match then
                local ok, data = pcall(function() return decode_json(json_match) end)
                if ok and type(data) == "table" then
                    local vehSkin = (data.vcf and data.vcf.partConfigFilename) or "default_skin"
                    local vehPaint = (data.vcf and data.vcf.parts and data.vcf.parts.paint_design)
                    local uid = ensure_account_for_pid(pid)
                    local oldRole = accounts[uid].role or "civilian"
                    local newRole = "civilian"
                    for _, skin in ipairs(PoliceSkins) do
                        if vehSkin == skin or vehPaint == skin then newRole = "police"; break end
                    end
                    if oldRole ~= newRole then
                        accounts[uid].role = newRole
                        sendTo(pid, tr_for_pid(pid, newRole == "police" and "welcome_police" or "welcome_civilian"))
                        sendEconomyUIUpdate(pid)
                    end
                    return
                end
            end
        end
    end
    local uid = ensure_account_for_pid(pid)
    if accounts[uid].role ~= "civilian" then
        accounts[uid].role = "civilian"
        sendTo(pid, tr_for_pid(pid, "welcome_civilian"))
        sendEconomyUIUpdate(pid)
    end
end

-- =============================================================================
-- || ZIGZAG / SPEED BONUS LOGIC                                             ||
-- =============================================================================

-- Cancel an ongoing zigzag bonus for a player. If there are unpaid prorated
-- seconds, they are paid before cancellation. The function can suppress player
-- notifications when no_notify is true (useful during disconnect cleanup).
local function cancel_zigzag_bonus(pid, no_notify, reason)
    if not pid then return end
    local bonus = zigzag_bonuses[pid]
    if not bonus then return end

    local now = os.time() * 1000
    local uid = getUID(pid)

    local elapsed = now - bonus.startTime
    local seconds_passed = math.floor(elapsed / 1000)
    local seconds_last_paid = math.floor((bonus.lastPayment - bonus.startTime) / 1000)
    local unpaid_seconds = 0
    if seconds_passed > seconds_last_paid then
        unpaid_seconds = seconds_passed - seconds_last_paid
        local ok, err = pcall(add_money, uid, unpaid_seconds)
        if not ok then log("ERROR adding prorated money for UID="..tostring(uid)..": "..tostring(err)) end
    end

    if not no_notify and MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid) then
        if unpaid_seconds > 0 then
            sendTo(pid, tr_for_pid(pid, "zigzag_bonus_prorated_end", { amount = unpaid_seconds }))
        else
            sendTo(pid, tr_for_pid(pid, "zigzag_bonus_cancelled", { reason = reason or "stopped" }))
        end
        sendEconomyUIUpdate(pid)
    end

    zigzag_bonuses[pid] = nil
    zigzag_cooldowns[pid] = now
    player_zigzag_state[pid] = nil

    log(string.format("Zigzag bonus cancelled PID=%s reason=%s paid=%d", tostring(pid), tostring(reason), unpaid_seconds))
end

-- Handle the detection that a player is "speeding". This starts a short-lived
-- bonus if the player is a civilian and not currently on cooldown.
local function handle_speeding(pid, speed)
    local now = os.time() * 1000 
    if speeding_cooldowns[pid] and now - speeding_cooldowns[pid] < SPEEDING_COOLDOWN_MS then
        return
    end
    local uid = getUID(pid)
    if accounts[uid] and accounts[uid].role == "civilian" then
        speeding_bonuses[pid] = { startTime = now, lastPayment = now }
        speeding_cooldowns[pid] = now 
        sendTo(pid, tr_for_pid(pid, "speed_bonus_start"))
    end
end

-- Cancel a speeding bonus, paying any prorated seconds and optionally notifying
-- the player (unless no_notify is true).
local function cancel_speeding_bonus(pid, no_notify, reason)
    if not pid then return end
    local bonus = speeding_bonuses[pid]
    if not bonus then return end

    local now = os.time() * 1000
    local uid = getUID(pid)

    local elapsed = now - bonus.startTime
    local seconds_passed = math.floor(elapsed / 1000)
    local seconds_last_paid = math.floor((bonus.lastPayment - bonus.startTime) / 1000)
    local unpaid_seconds = 0
    if seconds_passed > seconds_last_paid then
        unpaid_seconds = seconds_passed - seconds_last_paid
        local ok, err = pcall(add_money, uid, unpaid_seconds)
        if not ok then log("ERROR adding prorated money for UID="..tostring(uid)..": "..tostring(err)) end
    end

    if not no_notify and MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid) then
        if unpaid_seconds > 0 then
            sendTo(pid, tr_for_pid(pid, "speed_bonus_prorated_end", { amount = unpaid_seconds }))
        else
            sendTo(pid, tr_for_pid(pid, "speed_bonus_cancelled", { reason = reason or "stopped" }))
        end
        sendEconomyUIUpdate(pid)
    end

    speeding_bonuses[pid] = nil
    speeding_cooldowns[pid] = now

    log(string.format("Speed bonus cancelled PID=%s reason=%s paid=%d", tostring(pid), tostring(reason), unpaid_seconds))
end

-- Core zigzag detection. Analyzes player velocity, computes movement angle,
-- accumulates alternating turns, and starts a zigzag bonus when thresholds are met.
local function handle_zigzag(pid, pos)
    log("[ZIGZAG LOG] Starting zigzag check for PID: ".. tostring(pid))
    local uid = getUID(pid)
    if not accounts[uid] or accounts[uid].role ~= "civilian" then
        return
    end
    if not pos or not pos.rot or not pos.vel then
        return
    end

    if zigzag_bonuses[pid] then
        return
    end
    
    local speed = math.sqrt((pos.vel[1] or 0)^2 + (pos.vel[2] or 0)^2) * 3.6 
    local now = os.time() * 1000

    -- Compute movement angle from velocity vector.
    local move_angle = atan2(pos.vel[2], pos.vel[1])
    
    log(string.format("[ZIGZAG LOG] PID=%s - Speed: %.2f KMH, Move Angle: %.2f", pid, speed, move_angle))

    -- Respect per-player cooldowns for zigzag; if still cooling down, skip.
    if zigzag_cooldowns[pid] and (now - zigzag_cooldowns[pid] < ZIGZAG_COOLDOWN_MS) then
        log(string.format("[ZIGZAG LOG] PID=%s - Zigzag bonus on cooldown.", pid))
        return
    end

    if speed < MIN_SPEED_KMH_FOR_ZIGZAG then
        player_zigzag_state[pid] = nil
        return
    end
    
    if not player_zigzag_state[pid] then
        -- First sample: store angle and initialize counters.
        player_zigzag_state[pid] = {
            last_angle = move_angle,
            consecutive_turns = 0,
            last_direction = 0
        }
        log(string.format("[ZIGZAG LOG] PID=%s - Initialized, first move angle recorded.", pid))
        return
    end

    local state = player_zigzag_state[pid]
    local last_angle = state.last_angle
    
    -- Normalize angle difference to [-pi, pi]. This prevents spurious large deltas
    -- due to wrap-around at the -pi/pi boundary.
    local delta_angle = move_angle - last_angle
    if delta_angle > math.pi then
        delta_angle = delta_angle - 2 * math.pi
    elseif delta_angle < -math.pi then
        delta_angle = delta_angle + 2 * math.pi
    end
    
    local delta_angle_deg = math.deg(delta_angle)

    -- Ignore very small angle changes (noise) to avoid counting insignificant
    -- steering jitter as a zigzag turn.
    if math.abs(delta_angle_deg) < math.deg(ZIGZAG_MIN_DELTA_ANGLE) then
        log(string.format("[ZIGZAG LOG] PID=%s - Delta angle too small (%.2f < %.2f degrees), skipping.", pid, math.abs(delta_angle_deg), math.deg(ZIGZAG_MIN_DELTA_ANGLE)))
        return
    end
    
    local direction = (delta_angle > 0) and 1 or -1

    log(string.format("[ZIGZAG LOG] PID=%s - Last angle: %.2f, New angle: %.2f, Delta: %.2f deg, Last direction: %d, New direction: %d", 
                      pid, math.deg(last_angle), math.deg(move_angle), delta_angle_deg, state.last_direction, direction))

    -- Count alternating turns: increment when direction flips compared to last_direction.
    if state.last_direction ~= 0 and direction ~= state.last_direction then
        state.consecutive_turns = state.consecutive_turns + 1
        log(string.format("[ZIGZAG LOG] PID=%s - Zigzag turn detected! Consecutive turns: %d", pid, state.consecutive_turns))
    else
        -- Reset to 1 when it's the same direction or first counted turn.
        state.consecutive_turns = 1
        log(string.format("[ZIGZAG LOG] PID=%s - Direction is same or first turn. Resetting turns count to 1.", pid))
    end
    
    state.last_angle = move_angle
    state.last_direction = direction

    -- When enough alternating turns are observed, start the bonus and reset state.
    if state.consecutive_turns >= ZIGZAG_MIN_TURNS then
        zigzag_bonuses[pid] = { startTime = now, lastPayment = now }
        -- Set a cooldown that includes the duration of the bonus so we cannot
        -- immediately retrigger after it ends.
        zigzag_cooldowns[pid] = now + ZIGZAG_BONUS_DURATION_MS + ZIGZAG_COOLDOWN_MS
        sendTo(pid, tr_for_pid(pid, "zigzag_bonus_start"))
        log(string.format("[ZIGZAG LOG] PID=%s - Started a new zigzag bonus!", pid))
        
        player_zigzag_state[pid] = nil
    end
end

-- =============================================================================
-- || EVENT HANDLERS (vehicle/change/reset)                                  ||
-- =============================================================================

-- When a vehicle is edited on the client, cancel related bonuses. The ...
-- signature is used because MP passes multiple arguments; we only need the PID.
function ECON_onVehicleEdited(...)
    local pid = select(1, ...)
    if not pid or not (MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid)) then return end
    cancel_speeding_bonus(pid, false, "vehicle_edited")
    cancel_zigzag_bonus(pid, false, "change_vehicle")
end

-- When player changes vehicle: same cancellations as above.
function ECON_onChangeVehicle(...)
    local pid = select(1, ...)
    if not pid or not (MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid)) then return end
    cancel_speeding_bonus(pid, false, "change_vehicle")
    cancel_zigzag_bonus(pid, false, "change_vehicle")
end

-- =============================================================================
-- || COMBINED UPDATE LOOP                                                     ||
-- =============================================================================

-- This function is invoked periodically (every COMBINED_CHECK_INTERVAL ms) and
-- performs per-player checks: obtains raw position/velocity and runs the
-- speeding and zigzag handlers. It also updates running bonuses (prorated
-- payments) and final payouts when durations finish.
local function ECON_check_all_player_updates()
    local now = os.time() * 1000
    for pid,_ in pairs(MP.GetPlayers() or {}) do
        if MP.IsPlayerConnected(pid) then
            local ok, pos = pcall(MP.GetPositionRaw, pid, 0)
            if ok and pos and pos.vel then
                local speed = math.sqrt((pos.vel[1] or 0)^2 + (pos.vel[2] or 0)^2) * 3.6 
                if speed > SPEED_LIMIT_KMH then
                    pcall(handle_speeding, pid, speed)
                end
                local ok, err = pcall(handle_zigzag, pid, pos)
                if not ok then
                    log("ERROR: pcall failed for handle_zigzag: " .. tostring(err))
                end
            end
        end
    end

    -- Process active speeding bonuses: pay per-second increments and handle
    -- the final fixed payout after one minute (hard-coded 60000ms in this loop).
    local players_to_remove_speed = {}
    for pid, bonus_data in pairs(speeding_bonuses) do
        local elapsed = now - bonus_data.startTime
        local uid = getUID(pid)
        local seconds_passed = math.floor(elapsed / 1000)
        local seconds_last_paid = math.floor((bonus_data.lastPayment - bonus_data.startTime) / 1000)
        if seconds_passed > seconds_last_paid then
            add_money(uid, seconds_passed - seconds_last_paid)
            bonus_data.lastPayment = now
            sendEconomyUIUpdate(pid)
        end
        if elapsed >= 60000 then
            if MP.IsPlayerConnected(pid) then
                add_money(uid, 50) 
                sendTo(pid, tr_for_pid(pid, "speed_bonus_end"))
                sendEconomyUIUpdate(pid)
            end
            table.insert(players_to_remove_speed, pid)
        end
    end
    for _, pid in ipairs(players_to_remove_speed) do speeding_bonuses[pid] = nil end

    -- Process active zigzag bonuses: pay prorated per-second amounts and
    -- the final lump-sum at the end of the bonus duration.
    local players_to_remove_zigzag = {}
    for pid, bonus_data in pairs(zigzag_bonuses) do
        local elapsed = now - bonus_data.startTime
        local uid = getUID(pid)
        
        local seconds_passed = math.floor(elapsed / 1000)
        local seconds_last_paid = math.floor((bonus_data.lastPayment - bonus_data.startTime) / 1000)
        
        if seconds_passed > seconds_last_paid then
            add_money(uid, ZIGZAG_PRORATED_BONUS * (seconds_passed - seconds_last_paid))
            bonus_data.lastPayment = now
            sendEconomyUIUpdate(pid)
        end

        if elapsed >= ZIGZAG_BONUS_DURATION_MS then
            if MP.IsPlayerConnected(pid) then
                add_money(uid, ZIGZAG_FINAL_BONUS_AMOUNT)
                sendTo(pid, tr_for_pid(pid, "zigzag_bonus_end"))
                sendEconomyUIUpdate(pid)
            end
            table.insert(players_to_remove_zigzag, pid)
        end
    end
    for _, pid in ipairs(players_to_remove_zigzag) do zigzag_bonuses[pid] = nil end
end

-- =============================================================================
-- || ROLE CHECK TIMER                                                         ||
-- =============================================================================

-- Periodic check to update player's vehicle/role info. Runs independently from
-- the combined loop so it can be tuned separately.
function ECON_check_roles_timer()
    local players = MP.GetPlayers() or {}
    for pid, _ in pairs(players) do
        if MP.IsPlayerConnected(pid) then
            updatePlayerVehicleInfo(pid)
        end
    end
end

-- =============================================================================
-- || CHAT COMMANDS                                                           ||
-- =============================================================================

local function cmd_help(pid)
    local keys = { "help_title", "help_money", "help_who", "help_pay", "help_catch", "help_setlang", "help_repair" }
    for _, k in ipairs(keys) do sendTo(pid, tr_for_pid(pid, k)) end
end

local function cmd_money(pid)
    local uid = ensure_account_for_pid(pid)
    sendTo(pid, tr_for_pid(pid, "balance", { money = get_money(uid) }))
    sendEconomyUIUpdate(pid)
end

local function cmd_who(pid)
    sendTo(pid, tr_for_pid(pid, "who_title"))
    for id, name in pairs(MP.GetPlayers() or {}) do
        sendTo(id, ("      %d: %s"):format(id, name))
    end
end

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

-- =============================================================================
-- || UI LANGUAGE / SETTINGS                                                   ||
-- =============================================================================

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

-- =============================================================================
-- || POLICE / CATCH COMMAND                                                   ||
-- =============================================================================

local function cmd_catch(pid, targetStr)
    local target = tonumber(targetStr)
    if not target or not MP.IsPlayerConnected(target) then
        sendTo(pid, tr_for_pid(pid, "invalid_target"))
        return
    end
    local copUID, targetUID = ensure_account_for_pid(pid), getUID(target)
    if accounts[copUID].role == "police" and accounts[targetUID].role == "civilian" then
        add_money(copUID, 500) 
        for id, _ in pairs(MP.GetPlayers() or {}) do
            sendTo(id, tr_for_pid(id, "caught", { cop=getPlayerNameSafe(pid), criminal=getPlayerNameSafe(target) }))
        end
        sendEconomyUIUpdate(pid)
    else
        sendTo(pid, tr_for_pid(pid, "invalid_catch"))
    end
end

-- =============================================================================
-- || INITIALIZATION / TIMERS / REGISTRATION                                   ||
-- =============================================================================

function ECON_onInit()
    load_all_langs()
    load_accounts()
    MP.CreateEventTimer("ECON_autosave", AUTOSAVE_INTERVAL_MS)
    MP.CreateEventTimer("ECON_cool_message", COOL_MESSAGE_INTERVAL_MS)
    MP.CreateEventTimer("ECON_add_money", MONEY_PER_MINUTE_INTERVAL)
    MP.CreateEventTimer("ECON_welcome_checker", WELCOME_CHECK_INTERVAL)
    MP.CreateEventTimer("ECON_combined_checker", COMBINED_CHECK_INTERVAL)
    MP.CreateEventTimer("ECON_role_checker", 5000)
    
    log("EconomyTest initialized.")
    MP.RegisterEvent("onVehicleEdited", "ECON_onVehicleEdited")
end

function ECON_onAutosave()
    save_accounts()
    log("Autosave complete.")
end

-- Timers data table used for delayed UI updates per-player.
local timers_data = {}
function __ECON_UI_DELAY_CALLBACK_HANDLER(event_name)
    local pid = timers_data[event_name]
    if event_name and pid then
        if MP and MP.IsPlayerConnected(pid) then
            sendEconomyUIUpdate(pid)
        end
        if MP and MP.UnregisterEvent then
            MP.UnregisterEvent(event_name)
        end
        timers_data[event_name] = nil
    end
end

-- =============================================================================
-- || PLAYER JOIN / LEAVE / RESET HANDLERS                                     ||
-- =============================================================================

function ECON_onJoin(pid)
    players_awaiting_welcome_sync[pid] = true
    ensure_account_for_pid(pid)
    
    player_zigzag_state[pid] = nil
    zigzag_cooldowns[pid] = nil
    
    local event_name = "__ECON_UI_DELAY_"..tostring(pid)    
    timers_data[event_name] = pid    
    MP.RegisterEvent(event_name, "__ECON_UI_DELAY_CALLBACK_HANDLER")
    MP.CreateEventTimer(event_name, 1000, 1) 
end

function ECON_onLeave(pid)
    cancel_speeding_bonus(pid, true, "player_left")
    cancel_zigzag_bonus(pid, true, "player_left")

    save_accounts() 
    speeding_cooldowns[pid] = nil
    players_awaiting_welcome_sync[pid] = nil
    speeding_bonuses[pid] = nil 
    zigzag_bonuses[pid] = nil 
    player_zigzag_state[pid] = nil
    zigzag_cooldowns[pid] = nil

    local event_name = "__ECON_UI_DELAY_"..tostring(pid)
    if timers_data[event_name] then
        if MP and MP.UnregisterEvent then
            MP.UnregisterEvent(event_name)
        end
        timers_data[event_name] = nil
    end
end

function ECON_onVehicleReset(...)
    local pid = select(1, ...)
    if not pid or not (MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid)) then return end
    cancel_speeding_bonus(pid, false, "vehicle_reset")
    cancel_zigzag_bonus(pid, false, "change_vehicle")
end

function ECON_autosave() ECON_onAutosave() end
function ECON_cool_message() ECON_send_cool_message() end
function ECON_add_money() ECON_add_money_timer() end
function ECON_welcome_checker() ECON_check_and_send_welcomes() end
function ECON_combined_checker() ECON_check_all_player_updates() end
function ECON_role_checker() ECON_check_roles_timer() end

-- Register events so MP will call our handlers at the right moments.
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
MP.RegisterEvent("onVehicleReset", "ECON_onVehicleReset")
