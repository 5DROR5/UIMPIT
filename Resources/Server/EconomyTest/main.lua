--[[
    UIMPIT Server-Side Script
    Author: 5DROR5
    Version: 1.3.0
    Description: This script manages the entire server-side economy system,
    including player accounts, money, roles, chat commands, and timed events.
    This version is adapted to load all its settings from config.json.
]]

local PLUGIN = "[EconomyTest]"
local math = require("math")
local rad = math.rad
local deg = math.deg

local ok_json, json = pcall(require, "json")
if not ok_json then json = nil end

local DEFAULT_LANG = "en"
local SUPPORTED_LANGS = { "he", "en", "ar" }

local ROOT = "Resources/Server/EconomyTest"
local LANG_DIR = ROOT.. "/lang"
local ACCOUNTS_FILE = ROOT.. "/Data/players.DATA"
local CONFIG_FILE = ROOT.. "/config.json"
local PoliceSkins = require("PoliceSkins")

local config = {}

local WELCOME_CHECK_INTERVAL = 500
local COMBINED_CHECK_INTERVAL = 1000

local translations = {}
local accounts = {}
local players_awaiting_welcome_sync = {}

local speeding_cooldowns = {}
local speeding_bonuses = {}
local zigzag_bonuses = {}
local zigzag_cooldowns = {}
local player_zigzag_state = {}
local busted_timers = {}
local wanted_timers = {}

local last_sent_wanted = {}

local function log(msg)
    print(PLUGIN.. " ".. tostring(msg))
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

local function safe_read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

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
    if tbl.money ~= nil then
        return '{"money":'.. tostring(tbl.money).. '}'
    end
    return nil
end

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

local function json_load(path)
    local s = safe_read(path)
    if not s or s == "" then return {} end

    local ok, tbl = pcall(function() return decode_json(s) end)
    if ok and type(tbl) == "table" then return tbl end

    log("ERROR decoding JSON from ".. path.. ": ".. tostring(tbl))
    if FS and FS.Remove then pcall(FS.Remove, path) end
    return {}
end

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

local function load_config()
    local defaults = {
        features = {
            roleplay_enabled = true, money_per_minute_enabled = true, cool_message_enabled = true,
            speeding_bonus_enabled = true, zigzag_bonus_enabled = true, police_features_enabled = true
        },
        general = {autosave_interval_ms = 120000},
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

    local loaded_config = {}
    if file_exists(CONFIG_FILE) then
        loaded_config = json_load(CONFIG_FILE) or {}
    else
        log("WARNING: config.json not found. Using internal default values.")
    end

    for category, fields in pairs(defaults) do
        config[category] = config[category] or {}
        if type(fields) == "table" then
            for key, value in pairs(fields) do
                if loaded_config[category] and loaded_config[category][key] ~= nil then
                    config[category][key] = loaded_config[category][key]
                else
                    config[category][key] = value
                end
            end
        end
    end
    log("Configuration loaded successfully.")
end


local function load_lang_file(code)
    local path = LANG_DIR.. "/".. code.. ".json"
    if not file_exists(path) then return nil end
    return json_load(path)
end

local function load_all_langs()
    translations = {}
    for _, code in ipairs(SUPPORTED_LANGS) do
        translations[code] = load_lang_file(code) or {}
    end
    log("Loaded languages: ".. table.concat(SUPPORTED_LANGS, ", "))
end

local function getUID(pid)
    local ids = {}
    if MP and MP.GetPlayerIdentifiers then
        ids = MP.GetPlayerIdentifiers(pid) or {}
    end
    return ids.beammp or ids.steam or ids.license or ("pid:".. tostring(pid))
end

local function getPlayerNameSafe(pid)
    if MP and MP.GetPlayerName then
        local ok, name = pcall(MP.GetPlayerName, pid)
        return ok and name or ("Player".. tostring(pid))
    end
    return ("Player".. tostring(pid))
end

local function get_player_lang(pid)
    local uid = getUID(pid)
    return (accounts[uid] and accounts[uid].lang) or DEFAULT_LANG
end

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

local function ensure_account_for_pid(pid)
    local uid = getUID(pid)
    if not accounts[uid] then
        accounts[uid] = { money = config.money.starting_money, lang = DEFAULT_LANG, role = "civilian" }
    end
    return uid
end

local function get_money(uid)
    return (accounts[uid] and accounts[uid].money) or 0
end

local function add_money(uid, amt)
    amt = tonumber(amt) or 0
    accounts[uid] = accounts[uid] or { money = 0, lang = DEFAULT_LANG, role="civilian" }
    accounts[uid].money = math.max(0, (accounts[uid].money or 0) + amt)
end

local function load_accounts()
    accounts = file_exists(ACCOUNTS_FILE) and json_load(ACCOUNTS_FILE) or {}
    local count = 0
    for _,_ in pairs(accounts) do count = count + 1 end
    log("Loaded accounts: ".. tostring(count))
end

local function save_accounts()
    atomic_json_save(ACCOUNTS_FILE, accounts)
end

local function sendTo(pid, msg)
    if MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid) then
        local ok, err = pcall(MP.SendChatMessage, pid, msg)
        if not ok then log("ERROR sending message to ".. tostring(pid).. ": ".. tostring(err)) end
    end
end

local function sendAll(msg)
    for pid,_ in pairs(MP.GetPlayers() or {}) do sendTo(pid, msg) end
end

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

local function ECON_send_cool_message()
    for pid,_ in pairs(MP.GetPlayers() or {}) do
        sendTo(pid, tr_for_pid(pid, "cool_player_message"))
    end
end

function ECON_add_money_timer()
    log("ECON_add_money_timer tick")
    for pid,_ in pairs(MP.GetPlayers() or {}) do
        local uid = ensure_account_for_pid(pid)
        add_money(uid, config.money.money_per_minute_amount)
        log(string.format("Added %d to UID=%s new_bal=%s", config.money.money_per_minute_amount, tostring(uid), tostring(get_money(uid))))
        sendTo(pid, tr_for_pid(pid, "added_money_per_minute", { amount=config.money.money_per_minute_amount, money=get_money(uid) }))
        sendEconomyUIUpdate(pid)
    end
end

local function ECON_check_and_send_welcomes()
    for pid,_ in pairs(players_awaiting_welcome_sync) do
        if MP.IsPlayerConnected(pid) then
            sendTo(pid, tr_for_pid(pid, "welcome_server"))
            sendEconomyUIUpdate(pid)
            players_awaiting_welcome_sync[pid] = nil
        end
    end
end

local ZIGZAG_MIN_DELTA_ANGLE = math.rad(1)

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

local function dist(pos1, pos2)
    local dx = (pos1[1] or 0) - (pos2[1] or 0)
    local dy = (pos1[2] or 0) - (pos2[2] or 0)
    local dz = (pos1[3] or 0) - (pos2[3] or 0)
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

local function sendWantedUIUpdate(pid, seconds)
    if not (MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid)) then return end

    local secs = tonumber(seconds) or 0
    secs = math.max(0, math.ceil(secs))

    if last_sent_wanted[pid] == secs then return end
    last_sent_wanted[pid] = secs

    local payload_tbl = { wantedTime = secs }
    local payload_str = encode_json and encode_json(payload_tbl) or nil

    if not payload_str then
        if log then log("[EconomyUI-Wanted]: ERROR generating payload for PID=".. tostring(pid)) end
        return
    end

    local ok, err = pcall(function()
        MP.TriggerClientEvent(pid, "updateWantedStatus", payload_str)
    end)
    if not ok then
        if log then log("[EconomyUI-Wanted]: ERROR sending UI update PID=".. tostring(pid).. " err=".. tostring(err)) end
    end
end

local function update_wanted_timer(pid, duration_ms, source_key)
    local now = os.time() * 1000
    local current_expiration = wanted_timers[pid] or 0
    local new_expiration = current_expiration
    local duration_sec = duration_ms / 1000

    if current_expiration < now then
        new_expiration = now + duration_ms
        sendTo(pid, tr_for_pid(pid, source_key, { duration = duration_sec }))
        if log then log(string.format("[WANTED] PID=%s - Started WANTED timer for %.2f seconds (Source: %s).", pid, duration_sec, source_key)) end
    else
        new_expiration = current_expiration + duration_ms
        sendTo(pid, tr_for_pid(pid, "wanted_extended", { seconds = duration_sec }))
        if log then log(string.format("[WANTED] PID=%s - Extended WANTED timer by %.2f seconds. New total: %.2f seconds.", pid, duration_sec, (new_expiration - now) / 1000)) end
    end

    wanted_timers[pid] = new_expiration
    local remaining_sec = math.max(0, math.ceil((new_expiration - now) / 1000))
    sendWantedUIUpdate(pid, remaining_sec)
end

function fail_wanted_status(pid, reason_key)
    if not (MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid)) then return end

    local uid = getUID(pid)
    local current_role = accounts[uid] and accounts[uid].role

    if current_role ~= "civilian" then
        if log then log(string.format("[WANTED-FAIL] PID=%s is not a civilian. Aborting failure logic for reason: %s.", pid, reason_key)) end
        return
    end

    if not wanted_timers[pid] or wanted_timers[pid] <= os.time() * 1000 then
        if log then log(string.format("[WANTED-FAIL] PID=%s is not currently WANTED. Aborting penalty/cleanup for reason: %s.", pid, reason_key)) end
        return
    end

    local current_money = get_money(uid) or 0
    local penalty = config.civilian.wanted_fail_penalty

    add_money(uid, -penalty)
    local new_money = get_money(uid)

    if log then log(string.format("[WANTED-FAIL-MONEY] PID=%s UID=%s. Old: $%d. New: $%d (Penalty: $%d).", pid, uid, current_money, new_money, penalty)) end

    sendTo(pid, tr_for_pid(pid, "wanted_fail_message", {
        penalty = penalty,
        reason = tr_for_pid(pid, reason_key)
    }))

    sendEconomyUIUpdate(pid)

    wanted_timers[pid] = nil
    last_sent_wanted[pid] = nil
    sendWantedUIUpdate(pid, 0)

    speeding_bonuses[pid] = nil
    zigzag_bonuses[pid] = nil

    speeding_cooldowns[pid] = nil
    zigzag_cooldowns[pid] = nil

    busted_timers[pid] = nil
    player_zigzag_state[pid] = nil

    if log then log(string.format("[WANTED-FAIL] PID=%s FAILED WANTED status (Reason: %s). Penalty: $%d. Cooldowns reset.", pid, reason_key, penalty)) end
end

local function handle_speeding(pid, speed)
    local now = os.time() * 1000

    if speeding_cooldowns[pid] and now - speeding_cooldowns[pid] < config.civilian.speeding_cooldown_ms then
        return
    end

    local uid = getUID(pid)
    if accounts[uid] and accounts[uid].role == "civilian" then
        if not speeding_bonuses[pid] then
            speeding_bonuses[pid] = { startTime = now, lastPayment = now }
        end

        update_wanted_timer(pid, config.civilian.speeding_bonus_duration_ms, "speed_start_wanted")
        speeding_cooldowns[pid] = now
    end
end

local function handle_zigzag(pid, pos)
    local uid = getUID(pid)
    if not accounts[uid] or accounts[uid].role ~= "civilian" then return end
    if not pos or not pos.rot or not pos.vel then return end

    local now = os.time() * 1000

    local speed = math.sqrt((pos.vel[1] or 0)^2 + (pos.vel[2] or 0)^2) * 3.6
    if speed < config.civilian.min_speed_kmh_for_zigzag then
        player_zigzag_state[pid] = nil
        return
    end

    if zigzag_cooldowns[pid] and (now - zigzag_cooldowns[pid] < config.civilian.zigzag_cooldown_ms) then return end

    local move_angle = atan2(pos.vel[2], pos.vel[1])

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

    local delta_angle = move_angle - last_angle
    if delta_angle > math.pi then delta_angle = delta_angle - 2 * math.pi
    elseif delta_angle < -math.pi then delta_angle = delta_angle + 2 * math.pi end

    if math.abs(math.deg(delta_angle)) < math.deg(ZIGZAG_MIN_DELTA_ANGLE) then return end

    local direction = (delta_angle > 0) and 1 or -1

    if state.last_direction ~= 0 and direction ~= state.last_direction then
        state.consecutive_turns = state.consecutive_turns + 1
    else
        state.consecutive_turns = 1
    end

    state.last_angle = move_angle
    state.last_direction = direction

    if state.consecutive_turns >= config.civilian.zigzag_min_turns then
        if not zigzag_bonuses[pid] then
            zigzag_bonuses[pid] = { startTime = now, lastPayment = now }
        end

        update_wanted_timer(pid, config.civilian.zigzag_bonus_duration_ms, "zigzag_start_wanted")
        zigzag_cooldowns[pid] = now
        player_zigzag_state[pid] = nil
    end
end

function updatePlayerVehicleInfo(pid)
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
            if type(v) == "string" then
                local json_match = v:match("{.*}")
                if json_match then
                    local ok_json, data = pcall(function() return decode_json(json_match) end)
                    if ok_json and type(data) == "table" then
                        local vehSkin = (data.vcf and data.vcf.partConfigFilename) or ""
                        local vehPaint = (data.vcf and data.vcf.parts and data.vcf.parts.paint_design) or ""

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

    if current_role ~= new_role then
        accounts[uid].role = new_role

        if new_role == "police" then
            sendTo(pid, tr_for_pid(pid, "welcome_police"))

            if wanted_timers[pid] and wanted_timers[pid] > os.time() * 1000 then
                 fail_wanted_status(pid, "reason_became_police")
            end

            accounts[uid].last_police_payment = os.time() * 1000

        elseif new_role == "civilian" then
            sendTo(pid, tr_for_pid(pid, "welcome_civilian"))
        end
        sendEconomyUIUpdate(pid)
        sendWantedUIUpdate(pid, 0)
        if log then log(string.format("PID=%s role changed from %s to %s", pid, current_role, new_role)) end
    end
end

function ECON_check_all_player_updates()
    local now = os.time() * 1000
    local all_players = MP.GetPlayers() or {}

    local player_data = {}
    local wanted_civilian_data = {}
    local police_data = {}

    local civilian_police_proximity_count = {}
    local police_near_event_count = {}

    for pid,_ in pairs(all_players) do
        if MP.IsPlayerConnected(pid) then
            local uid = getUID(pid)
            local role = accounts[uid] and accounts[uid].role or "civilian"

            local ok, pos = pcall(MP.GetPositionRaw, pid, 0)
            local speed = (ok and pos and pos.vel) and math.sqrt(pos.vel[1]^2 + pos.vel[2]^2) * 3.6 or 0

            player_data[pid] = { pos = (ok and pos and pos.pos) or nil, speed = speed, role = role }

            if role == "civilian" then
                if ok and pos then
                    if config.features.speeding_bonus_enabled and speed > config.civilian.speeding_limit_kmh then
                        pcall(handle_speeding, pid, speed)
                    end
                    if config.features.zigzag_bonus_enabled then
                        pcall(handle_zigzag, pid, pos)
                    end
                end

                if wanted_timers[pid] and wanted_timers[pid] > now then
                    if player_data[pid].pos then
                        wanted_civilian_data[pid] = player_data[pid]
                    end
                end
            elseif role == "police" then
                police_data[pid] = player_data[pid]
            end
        end
    end

for civil_pid, civil_data in pairs(wanted_civilian_data) do
    local police_count = 0
    local closest_cop_dist = config.police.police_proximity_range_m + 1
    local nearby_police = {}

    if civil_data.pos then
        for cop_pid, cop_data in pairs(police_data) do
            if cop_data.pos then
                local distance = dist(civil_data.pos, cop_data.pos)

                if distance <= config.police.police_proximity_range_m then
                    police_count = police_count + 1
                    police_near_event_count[cop_pid] = (police_near_event_count[cop_pid] or 0) + 1
                end

                if distance <= config.police.busted_range_m then
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
        if civil_data.speed < config.police.busted_speed_limit_kmh and closest_cop_dist <= config.police.busted_range_m then
            if not busted_timers[civil_pid] then
                busted_timers[civil_pid] = now
            else
                local elapsed_time = now - busted_timers[civil_pid]
                if elapsed_time >= config.police.busted_stop_time_ms then
                    local uid = getUID(civil_pid)
                    local name = MP.GetPlayerName(civil_pid)

                    fail_wanted_status(civil_pid, "reason_busted")

                    busted_timers[civil_pid] = nil

                    sendAll(tr_for_pid(civil_pid, "busted_global_message", { criminal = name }))

                    local bust_bonus = config.police.bust_bonus_amount

                    for _, cop_pid in ipairs(nearby_police) do
                        local cop_uid = getUID(cop_pid)
                        add_money(cop_uid, bust_bonus)

                        sendTo(cop_pid, tr_for_pid(cop_pid, "police_bust_bonus", { amount = bust_bonus, criminal = name }))

                        sendEconomyUIUpdate(cop_pid)

                        if log then log(string.format("[BUSTED] Rewarded Police PID=%s UID=%s with $%d for bust of PID=%s.", cop_pid, cop_uid, bust_bonus, civil_pid)) end
                    end
                end
            end
        else
            busted_timers[civil_pid] = nil
        end
    end
end

    for pid,_ in pairs(all_players) do
        if MP.IsPlayerConnected(pid) then
            local uid = getUID(pid)
            local role = accounts[uid] and accounts[uid].role or "civilian"
            local is_wanted = wanted_timers[pid] and wanted_timers[pid] > now

            local remaining_wanted_ms = (wanted_timers[pid] or 0) - now
            local remaining_wanted_seconds = math.max(0, math.ceil(remaining_wanted_ms / 1000))
            sendWantedUIUpdate(pid, remaining_wanted_seconds)

            if wanted_timers[pid] and wanted_timers[pid] <= now then

                local bonus_amount = config.civilian.zigzag_final_bonus_amount

                add_money(uid, bonus_amount)

                sendTo(pid, tr_for_pid(pid, "zigzag_end_reward", { amount = bonus_amount }))
                sendEconomyUIUpdate(pid)

                if log then log(string.format("[EVASION] PID %d (UID: %s) evaded WANTED status and received $%.2f bonus.", pid, uid, bonus_amount)) end

                wanted_timers[pid] = nil
                last_sent_wanted[pid] = nil
                is_wanted = false
            end

            if (is_wanted and config.features.roleplay_enabled) or (role == "police" and config.features.police_features_enabled) then

                local last_payment_ms = now - 1000

                if role == "police" then
                    last_payment_ms = accounts[uid].last_police_payment or (now - 1000)
                elseif is_wanted then
                    last_payment_ms = speeding_bonuses[pid] and speeding_bonuses[pid].lastPayment or zigzag_bonuses[pid] and zigzag_bonuses[pid].lastPayment or (now - 1000)
                end

                local seconds_passed = math.max(0, math.floor(now / 1000) - math.floor(last_payment_ms / 1000))

                if seconds_passed > 0 then
                    local money_to_add = 0

                    if role == "police" then
                        local civilian_event_count = police_near_event_count[pid] or 0
                        if civilian_event_count > 0 and config.police.police_bonus_per_second ~= nil then
                            money_to_add = seconds_passed * config.police.police_bonus_per_second * civilian_event_count
                            accounts[uid].last_police_payment = now
                        end

                    elseif is_wanted then
                        local police_count = civilian_police_proximity_count[pid] or 0

                        if police_count > 0 then
                            if speeding_bonuses[pid] and config.features.speeding_bonus_enabled then
                                money_to_add = money_to_add + (seconds_passed * config.civilian.speeding_bonus_per_second * police_count)
                            end
                            if zigzag_bonuses[pid] and config.features.zigzag_bonus_enabled then
                                money_to_add = money_to_add + (seconds_passed * config.civilian.zigzag_prorated_bonus * police_count)
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

function ECON_onVehicleEdited(...)
    local pid = select(1, ...)
    if not pid or not (MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid)) then return end

    fail_wanted_status(pid, "reason_vehicle_edited")

    updatePlayerVehicleInfo(pid)
end

function ECON_onChangeVehicle(...)
    local pid = select(1, ...)
    if not pid or not (MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid)) then return end

    fail_wanted_status(pid, "reason_change_vehicle")

    updatePlayerVehicleInfo(pid)
end

function ECON_onVehicleReset(...)
    local pid = select(1, ...)
    if not pid or not (MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid)) then return end

    fail_wanted_status(pid, "reason_vehicle_reset")

    updatePlayerVehicleInfo(pid)
end

function ECON_onPlayerExitVehicle(...)
    local pid = select(1, ...)
    if not pid or not (MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid)) then return end

    fail_wanted_status(pid, "reason_exit_vehicle")
end

function ECON_onVehicleDelete(...)
    local pid = select(1, ...)
    if not pid or not (MP and MP.IsPlayerConnected and MP.IsPlayerConnected(pid)) then return end

    fail_wanted_status(pid, "reason_vehicle_delete")

    updatePlayerVehicleInfo(pid)
end

function ECON_check_roles_timer()
    local players = MP.GetPlayers() or {}
    for pid, _ in pairs(players) do
        if MP.IsPlayerConnected(pid) then
            updatePlayerVehicleInfo(pid)
        end
    end
end

local function cmd_help(pid)
    local keys = { "help_title", "help_money", "help_who", "help_pay", "help_setlang", "help_repair" }
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

function ECON_onInit()
    load_config()
    load_all_langs()
    load_accounts()

    MP.CreateEventTimer("ECON_autosave", config.general.autosave_interval_ms)
    MP.CreateEventTimer("ECON_welcome_checker", WELCOME_CHECK_INTERVAL)

    if config.features.cool_message_enabled then
        MP.CreateEventTimer("ECON_cool_message", config.money.cool_message_interval_ms)
    end
    if config.features.money_per_minute_enabled then
        MP.CreateEventTimer("ECON_add_money", config.money.money_per_minute_interval_ms)
    end
    
    if config.features.roleplay_enabled then
        MP.CreateEventTimer("ECON_combined_checker", COMBINED_CHECK_INTERVAL)
        MP.CreateEventTimer("ECON_role_checker", 5000)

        MP.RegisterEvent("onVehicleEdited", "ECON_onVehicleEdited")
        MP.RegisterEvent("onPlayerChangeVehicle", "ECON_onChangeVehicle")
        MP.RegisterEvent("onVehicleReset", "ECON_onVehicleReset")
        MP.RegisterEvent("onPlayerExitVehicle", "ECON_onPlayerExitVehicle")
        MP.RegisterEvent("onVehicleDelete", "ECON_onVehicleDelete")
    end

    log("EconomyTest initialized.")
end

function ECON_onAutosave()
    save_accounts()
    log("Autosave complete.")
end

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

function ECON_onJoin(pid)
    players_awaiting_welcome_sync[pid] = true
    ensure_account_for_pid(pid)

    player_zigzag_state[pid] = nil
    zigzag_cooldowns[pid] = nil
    busted_timers[pid] = nil

    local event_name = "__ECON_UI_DELAY_"..tostring(pid)
    timers_data[event_name] = pid
    MP.RegisterEvent(event_name, "__ECON_UI_DELAY_CALLBACK_HANDLER")
    MP.CreateEventTimer(event_name, 1500, 1)
end

function ECON_onLeave(pid)
    if config.features.roleplay_enabled and fail_wanted_status then
        pcall(fail_wanted_status, pid, "reason_player_left")
    end

    save_accounts()
    players_awaiting_welcome_sync[pid] = nil
    speeding_cooldowns[pid] = nil
    speeding_bonuses[pid] = nil
    zigzag_bonuses[pid] = nil
    player_zigzag_state[pid] = nil
    zigzag_cooldowns[pid] = nil
    busted_timers[pid] = nil

    local event_name = "__ECON_UI_DELAY_"..tostring(pid)
    if timers_data[event_name] then
        if MP and MP.UnregisterEvent then
            MP.UnregisterEvent(event_name)
        end
        timers_data[event_name] = nil
    end
end

function ECON_autosave() ECON_onAutosave() end
function ECON_cool_message() ECON_send_cool_message() end
function ECON_add_money() ECON_add_money_timer() end
function ECON_welcome_checker() ECON_check_and_send_welcomes() end
function ECON_combined_checker() ECON_check_all_player_updates() end
function ECON_role_checker() ECON_check_roles_timer() end


MP.RegisterEvent("onInit", "ECON_onInit")
MP.RegisterEvent("ECON_autosave", "ECON_autosave")
MP.RegisterEvent("onPlayerJoining", "ECON_onJoin")
MP.RegisterEvent("onPlayerDisconnect", "ECON_onLeave")
MP.RegisterEvent("onChatMessage", "ECON_onChat")
MP.RegisterEvent("setPlayerLanguage", "ECON_onUI_setLanguage")

if config and config.features and config.features.cool_message_enabled then
    MP.RegisterEvent("ECON_cool_message", "ECON_cool_message")
end
if config and config.features and config.features.money_per_minute_enabled then
    MP.RegisterEvent("ECON_add_money", "ECON_add_money")
end
MP.RegisterEvent("ECON_welcome_checker", "ECON_welcome_checker")

if config and config.features and config.features.roleplay_enabled then
    MP.RegisterEvent("ECON_combined_checker", "ECON_combined_checker")
    MP.RegisterEvent("ECON_role_checker", "ECON_role_checker")
end
