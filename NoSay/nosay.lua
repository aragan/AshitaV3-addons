-- ==============================================
-- NoSay - Block /say (and accidental default chat)
-- Ashita v3 Addon
-- ==============================================

_addon.author  = 'Aragan';
_addon.name    = 'NoSay';
_addon.version = '1.1';
_addon.desc    = 'NoSay - Block /say (and accidental default chat)';

local chat_ok, chat = pcall(require, 'chat');

local function log(msg)
    if chat_ok and chat then
        print(chat.header(_addon.name):append(chat.message(msg)));
    else
        -- تقسيم النص إلى أسطر فردية
        for line in msg:gmatch("[^\r\n]+") do
            print(('\31\207[%s] %s'):format(_addon.name, line)); -- \31\207 لتحديد اللون الأزرق
        end
    end
end

local function trim(s)
    return (type(s) == 'string') and s:gsub('^%s+', ''):gsub('%s+$', '') or '';
end

local function lower(s)
    return (type(s) == 'string') and s:lower() or '';
end

local function split_args(s)
    local t = { };
    if type(s) ~= 'string' then return t end
    for a in s:gmatch('%S+') do
        t[#t + 1] = a;
    end
    return t;
end

local function is_command(s)
    return type(s) == 'string' and s:sub(1, 1) == '/';
end

local function merge_into(dst, src)
    if type(dst) ~= 'table' or type(src) ~= 'table' then return end
    for k, v in pairs(src) do
        if type(v) == 'table' and type(dst[k]) == 'table' then
            merge_into(dst[k], v);
        else
            dst[k] = v;
        end
    end
end

----------------------------------------------------------
-- Settings (saved to NoSay/settings/settings.json)
-- Supports per-character override keys at the root, eg:
-- {
--   "global": { ... },
--   "aragan": { "strict_mode": true }
-- }
----------------------------------------------------------
local defaults = {
    enabled = true,

    -- Block explicit /say and /s
    block_say = true,

    -- Block messages typed without "/" ONLY when last detected channel was SAY
    block_bare_when_last_is_say = true,

    -- Strict mode: block ANY message typed without "/"
    strict_mode = false,

    -- One-time bypass: start the message with this prefix to allow it.
    allow_prefix = '!!',

    -- Print a notice when something is blocked
    notify = true,
};

local settings_path = (_addon.path or '') .. 'settings/settings.json';

local settings_all = nil;   -- whole json { global=..., [char]=... }
local settings     = nil;   -- effective merged settings
local player_key   = nil;   -- lowercase player name key

-- Best-effort tracking of the last channel used via explicit slash commands.
-- (FFXI chat-mode changes done via the UI may not be detectable.)
local last_channel = 'say';

local function get_player_key()
    if player_key ~= nil then
        return player_key;
    end

    local name = nil;

    if AshitaCore and AshitaCore.GetMemoryManager then
        local party = AshitaCore:GetMemoryManager():GetParty();
        if party then
            name = party:GetMemberName(0);
        end
    end

    if type(name) == 'string' and name ~= '' then
        player_key = name:lower();
    else
        player_key = '';
    end

    return player_key;
end

local function rebuild_effective_settings()
    settings = { };
    merge_into(settings, defaults);

    if type(settings_all) == 'table' then
        if type(settings_all.global) == 'table' then
            merge_into(settings, settings_all.global);
        end

        local pk = get_player_key();
        if pk ~= '' and type(settings_all[pk]) == 'table' then
            merge_into(settings, settings_all[pk]);
        end
    end
end

local function normalize_loaded_settings(t)
    -- If the json was accidentally saved flat (no 'global' table), wrap it.
    if type(t) == 'table' and t.global == nil then
        local looks_flat = (t.enabled ~= nil) or (t.block_say ~= nil) or (t.allow_prefix ~= nil);
        if looks_flat then
            return { global = t };
        end
    end
    return t;
end

local function load_settings()
    local ok = (ashita and ashita.settings and ashita.settings.load) ~= nil;
    if ok then
        settings_all = ashita.settings.load(settings_path, { global = defaults });
        settings_all = normalize_loaded_settings(settings_all);
        settings_all.global = settings_all.global or { };
    else
        -- Fallback; should not happen on Ashita v3.
        settings_all = { global = defaults };
    end

    -- Ensure player key exists if the file has a case-different key (eg "Aragan")
    local pk = get_player_key();
    if pk ~= '' and type(settings_all[pk]) ~= 'table' then
        for k, v in pairs(settings_all) do
            if type(k) == 'string' and k:lower() == pk and type(v) == 'table' then
                settings_all[pk] = v;
                break;
            end
        end
    end

    rebuild_effective_settings();
end

local function save_settings()
    if ashita and ashita.settings and ashita.settings.save and type(settings_all) == 'table' then
        ashita.settings.save(settings_path, settings_all);
    end
end

local function set_setting_value(key, val)
    local pk = get_player_key();
    if pk ~= '' and type(settings_all[pk]) == 'table' and settings_all[pk][key] ~= nil then
        settings_all[pk][key] = val; -- keep editing the per-char override if it exists
    else
        settings_all.global[key] = val; -- otherwise, edit the global setting
    end
    rebuild_effective_settings();
    save_settings();
end

local function strip_allow_prefix(msg)
    local p = settings and settings.allow_prefix or defaults.allow_prefix;
    if type(msg) ~= 'string' then return msg, false end
    if p and p ~= '' and msg:sub(1, #p) == p then
        return msg:sub(#p + 1), true;
    end
    return msg, false;
end

local function detect_channel(cmdline)
    local cmd = lower(cmdline or '');
    if cmd:match('^/say%s') or cmd:match('^/s%s') then
        return 'say';
    elseif cmd:match('^/shout%s') or cmd:match('^/sh%s') then
        return 'shout';
    elseif cmd:match('^/yell%s') then
        return 'yell';
    elseif cmd:match('^/party%s') or cmd:match('^/p%s') then
        return 'party';
    elseif cmd:match('^/linkshell2%s') or cmd:match('^/l2%s') then
        return 'linkshell2';
    elseif cmd:match('^/linkshell%s') or cmd:match('^/l%s') then
        return 'linkshell';
    end
    return nil;
end

local function notify(msg)
    if settings and settings.notify then
        log(msg);
    end
end

----------------------------------------------------------
-- Outgoing text interceptor (Ashita: outgoing_text)
-- Signature:
--   outgoing_text(mode, message, modifiedmode, modifiedmessage, blocked)
-- Returns:
--   true to block, false to allow
--   or string / string,number to modify
----------------------------------------------------------
local function outgoing_text_cb(mode, message, modifiedmode, modifiedmessage, blocked)
    if blocked then
        return true;
    end
    if not settings or not settings.enabled then
        return false;
    end

    local original = nil;
    if type(modifiedmessage) == 'string' and modifiedmessage ~= '' then
        original = modifiedmessage;
    else
        original = message;
    end

    if type(original) ~= 'string' or original == '' then
        return false;
    end

    -- Allow-prefix handling for BOTH command and bare text
    if not is_command(original) then
        local cleaned, allowed = strip_allow_prefix(original);

        -- Strict mode: block any bare message unless allow-prefix is used
        if settings.strict_mode and not allowed then
            notify('[NoSay] Blocked a message (strict mode: no "/" prefix).');
            notify('[NoSay] if yuo want say anything use /say !!hello or just !!hello in chatbox');
            return true;
        end

        -- Block bare messages only when we believe last channel was SAY
        if settings.block_bare_when_last_is_say and (last_channel == 'say') and not allowed then
            notify('[NoSay] Blocked a message (default channel was SAY).');
            notify('[NoSay] if yuo want say anything use /say !!hello or just !!hello in chatbox');
            return true;
        end

        -- If allow-prefix was used, remove it and pass through
        if allowed then
            return cleaned, (modifiedmode or mode);
        end

        return false;
    end

    -- Command lines
    local lo = lower(original);

    -- Block explicit /say
    if settings.block_say and (lo:match('^/say%s') or lo:match('^/s%s')) then
        local msg = original:match('^/say%s+(.+)$') or original:match('^/s%s+(.+)$') or '';
        local cleaned, allowed = strip_allow_prefix(msg);

        if allowed then
            -- Allow this one-time say, prefix removed
            return ('/say ' .. cleaned), (modifiedmode or mode);
        end

        notify('[NoSay] Blocked a /say message.');
        return true;
    end

    -- If command is not blocked, update last_channel best-effort based on this command
    local ch = detect_channel(original);
    if ch then
        last_channel = ch;
    end

    return false;
end
----------------------------------------------------------
-- Commands (Ashita: command)
-- Signature:
--   command(cmd, nType)
-- Returns:
--   true if handled, false otherwise
----------------------------------------------------------
local function command_cb(cmd, nType)
    if type(cmd) ~= 'string' then
        return false;
    end

    local raw = trim(cmd);
    local lo  = lower(raw);

    -- Accept /nosay or //nosay
    if not (lo:match('^/nosay') or lo:match('^//nosay')) then
        return false;
    end

    local args = split_args(raw);
    local sub  = lower(args[2] or '');
    local a1   = lower(args[3] or '');

    if sub == 'on' then
        set_setting_value('enabled', true);
        log('Enabled.');
    elseif sub == 'off' then
        set_setting_value('enabled', false);
        log('Disabled.');
    elseif sub == 'toggle' then
        set_setting_value('enabled', not settings.enabled);
        log('Toggled: ' .. tostring(settings.enabled));
    elseif sub == 'status' or sub == '' then
        log(('[NoSay] enabled=%s block_say=%s bare_when_say=%s strict=%s last_channel=%s allow_prefix=%s notify=%s'):format(
            tostring(settings.enabled),
            tostring(settings.block_say),
            tostring(settings.block_bare_when_last_is_say),
            tostring(settings.strict_mode),
            tostring(last_channel),
            tostring(settings.allow_prefix),
            tostring(settings.notify)
        ));
    elseif sub == 'notify' then
        if a1 == 'on' then
            set_setting_value('notify', true);
        elseif a1 == 'off' then
            set_setting_value('notify', false);
        end
        log('[NoSay] notify=' .. tostring(settings.notify));
    elseif sub == 'strict' then
        if a1 == 'on' then
            set_setting_value('strict_mode', true);
        elseif a1 == 'off' then
            set_setting_value('strict_mode', false);
        elseif a1 == 'toggle' or a1 == '' then
            set_setting_value('strict_mode', not settings.strict_mode);
        end
        log('[NoSay] strict_mode=' .. tostring(settings.strict_mode));
    else
        log('Commands: /nosay on | off | toggle | status | notify on|off | strict on|off|toggle');
        log(('Allow prefix: start message with "%s" to bypass (prefix removed).'):format(settings.allow_prefix));
    end

    return true;
end
----------------------------------------------------------
-- Event Registration (Ashita)
----------------------------------------------------------
if ashita and ashita.register_event then
    ashita.register_event('load', function()
        load_settings();
        log('Loaded. Use /nosay status');
    end);

    ashita.register_event('unload', function()
        save_settings();
    end);

    ashita.register_event('command', command_cb);
    ashita.register_event('outgoing_text', outgoing_text_cb);

elseif ashita and ashita.events and ashita.events.register then
    -- Fallback for environments that use ashita.events.register with event tables.
    local function wrap_command(e)
        if type(e) ~= 'table' or type(e.command) ~= 'string' then return end
        local handled = command_cb(e.command, 0);
        if handled then
            e.blocked = true;
        end
    end

    local function wrap_outgoing(e)
        if type(e) ~= 'table' then return end
        local mode    = e.mode or 0;
        local msg     = e.message or e.text or '';
        local blocked = e.blocked == true;

        local r1, r2 = outgoing_text_cb(mode, msg, mode, msg, blocked);

        if r1 == true then
            e.blocked = true;
            return;
        end

        if type(r1) == 'string' then
            e.message = r1;
            if type(r2) == 'number' then
                e.mode = r2;
            end
        end
    end

    ashita.events.register('load', 'nosay_load', function()
        load_settings();
        log('Loaded. Use /nosay status');
    end);

    ashita.events.register('unload', 'nosay_unload', function()
        save_settings();
    end);

    ashita.events.register('command', 'nosay_command', wrap_command);
    ashita.events.register('outgoing_text', 'nosay_outgoing_text', wrap_outgoing);
end
