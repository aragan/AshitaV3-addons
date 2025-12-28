--[[
    Singer (Ashita v3 ONLY) - No HUD

    - Saved settings: configs.xml (single file)
    - Playlists source: settings.lua ONLY (old style). The addon will NOT save/modify playlists.
    - Chat output in English only.
--]]

----------------------------------------------------------------------------------------------------
-- Addon info (Ashita v3 style)
----------------------------------------------------------------------------------------------------
_addon = _addon or {}
_addon.name     = 'singer'
_addon.author   = 'Aragan'
_addon.version  = '1.1-v3- version transformers coming'
_addon.desc     = 'Singer (No HUD) for Ashita v3 ONLY'

pcall(require, 'common')

----------------------------------------------------------------------------------------------------
-- Addon path (important on Ashita v3)
----------------------------------------------------------------------------------------------------
local SCRIPT_DIR = ''
do
    local info = debug.getinfo(1, 'S')
    local src = (info and info.source) or ''
    src = src:gsub('^@', '')
    src = src:gsub('^[\\/]+', '')
    SCRIPT_DIR = src:match('^(.+[\\/])') or ''
end

if SCRIPT_DIR ~= '' and type(package) == 'table' and type(package.path) == 'string' then
    package.path = package.path .. ';' .. SCRIPT_DIR .. '?.lua;' .. SCRIPT_DIR .. '?\\init.lua;' .. SCRIPT_DIR .. '?/init.lua'
end

local CONFIG_FILE   = (SCRIPT_DIR ~= '' and (SCRIPT_DIR .. 'configs.xml')) or 'configs.xml'
local SETTINGS_FILE = (SCRIPT_DIR ~= '' and (SCRIPT_DIR .. 'settings.lua')) or 'settings.lua'

----------------------------------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------------------------------
local state = {
    enabled         = false,
    repeat_cycle    = true,

    busy            = false,
    busy_until      = 0.0,

    pending         = nil,
    pending_i       = 0,
    next_action     = 0.0,

    song_delay      = 8.5,
    interval        = 80.0,
    next_cycle      = 0.0,

    songs           = {},
    target          = '<me>',

    nitro           = false,
    ccsv            = false,
    marcato_first   = false, -- persistent (first song only)

    marcato_arm     = false, -- one-shot (requires /singer now)
    marcato_song    = nil,

    pad             = 2.5,

    settings        = nil,      -- loaded settings.lua table
    playlist        = nil,      -- current playlist name

    -- caches for playlists listing / lookup
    _pl_names_cache = nil,      -- sorted playlist names
    _pl_pos         = 1,        -- paging cursor
    _pl_lut         = nil,      -- lower(name) -> actual name

    _last_tick_ms   = -1,
    _queue_sig      = nil,      -- 'cmd_delay' | 'delay_cmd' | 'cmd_only'
}

----------------------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------------------
local function now_clock()
    return os.clock()
end

local function tokenize_command(cmd)
    local out = {}
    local i, n = 1, #cmd
    local inq = false
    local cur = {}

    while i <= n do
        local c = cmd:sub(i, i)
        if c == '"' then
            inq = not inq
        elseif (not inq) and (c == ' ' or c == '\t') then
            if #cur > 0 then
                out[#out+1] = table.concat(cur)
                cur = {}
            end
        else
            cur[#cur+1] = c
        end
        i = i + 1
    end

    if #cur > 0 then
        out[#out+1] = table.concat(cur)
    end

    return out
end

local function norm_prefix(tok)
    tok = tok or ''
    tok = tok:gsub('^//', '/')
    return tok:lower()
end

----------------------------------------------------------------------------------------------------
-- QueueCommand (Ashita v3) signature pinning (prevents freezes / spam issues)
----------------------------------------------------------------------------------------------------
local function queue_command_raw(cm, cmd, delay)
    local d = tonumber(delay) or 0
    if d < -1 then d = -1 end

    if state._queue_sig == 'cmd_delay' then
        return pcall(function() cm:QueueCommand(cmd, d) end)
    elseif state._queue_sig == 'delay_cmd' then
        return pcall(function() cm:QueueCommand(d, cmd) end)
    elseif state._queue_sig == 'cmd_only' then
        return pcall(function() cm:QueueCommand(cmd) end)
    end

    local ok = pcall(function() cm:QueueCommand(cmd, d) end)
    if ok then state._queue_sig = 'cmd_delay'; return true end

    ok = pcall(function() cm:QueueCommand(d, cmd) end)
    if ok then state._queue_sig = 'delay_cmd'; return true end

    ok = pcall(function() cm:QueueCommand(cmd) end)
    if ok then state._queue_sig = 'cmd_only'; return true end

    return false
end

local function queue_command(cmd, delay)
    if type(cmd) ~= 'string' or cmd == '' then return false end
    if not AshitaCore or not AshitaCore.GetChatManager then return false end

    local cm = AshitaCore:GetChatManager()
    if not cm then return false end

    return queue_command_raw(cm, cmd, delay)
end

local function echo(msg)
    local prefix = '[Singer] '
    local cm = (AshitaCore and AshitaCore.GetChatManager) and AshitaCore:GetChatManager() or nil
    if cm and cm.AddChatMessage then
        local ok = pcall(function() cm:AddChatMessage(200, prefix .. msg) end)
        if ok then return end
        ok = pcall(function() cm:AddChatMessage(prefix .. msg) end)
        if ok then return end
    end

    local ok = queue_command(('/echo %s%s'):format(prefix, msg), 0)
    if not ok then
        print(prefix .. msg)
    end
end

----------------------------------------------------------------------------------------------------
-- configs.xml (single-file persistence)
----------------------------------------------------------------------------------------------------
local function xml_escape(s)
    s = tostring(s or '')
    s = s:gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;'):gsub('"','&quot;'):gsub("'","&apos;")
    return s
end

local function xml_unescape(s)
    s = tostring(s or '')
    s = s:gsub('&lt;','<'):gsub('&gt;','>'):gsub('&quot;','"'):gsub('&apos;',"'"):gsub('&amp;','&')
    return s
end

local function xml_get_attr(tag, name)
    local v = tag:match(name .. '%s*=%s*"(.-)"')
    if v ~= nil then return xml_unescape(v) end
    return nil
end

local function to_bool(v)
    if type(v) == 'boolean' then return v end
    if type(v) ~= 'string' then return false end
    v = v:lower()
    return (v == 'true' or v == '1' or v == 'yes' or v == 'on')
end

local function to_num(v, d)
    local n = tonumber(v)
    return n ~= nil and n or d
end

local function load_configs()
    local f = io.open(CONFIG_FILE, 'r')
    if not f then return false end
    local xml = f:read('*a')
    f:close()

    local settings_tag = xml:match('<settings%s+.-/>') or ''
    if settings_tag ~= '' then
        state.enabled      = false
        state.repeat_cycle = to_bool(xml_get_attr(settings_tag, 'repeat'))
        state.song_delay   = to_num(xml_get_attr(settings_tag, 'delay'), 8.5)
        state.interval     = to_num(xml_get_attr(settings_tag, 'cycle'), 80.0)
        state.target       = xml_get_attr(settings_tag, 'target') or '<me>'
        state.nitro        = to_bool(xml_get_attr(settings_tag, 'use_nitro'))
        state.ccsv         = to_bool(xml_get_attr(settings_tag, 'use_ccsv'))
        state.marcato_first = to_bool(xml_get_attr(settings_tag, 'use_marcato'))
        state.marcato_index   = to_num(xml_get_attr(settings_tag, 'marcato_index'), 1)
        if state.marcato_index < 1 then state.marcato_index = 1 end
        state.marcato_song    = xml_get_attr(settings_tag, 'marcato_song') or nil
        if state.marcato_song == '' then state.marcato_song = nil end
        state.playlist     = xml_get_attr(settings_tag, 'active') or nil
    end

    return true
end

local function save_configs()
    local lines = {}
    lines[#lines+1] = '<?xml version="1.0" encoding="UTF-8"?>'
    lines[#lines+1] = '<configs>'
    lines[#lines+1] = ('  <settings enabled="%s" repeat="%s" delay="%.1f" cycle="%.1f" target="%s" active="%s" use_nitro="%s" use_ccsv="%s" use_marcato="%s" marcato_index="%s" marcato_song="%s" debug="false" />'):format(
        state.enabled and 'true' or 'false',
        state.repeat_cycle and 'true' or 'false',
        tonumber(state.song_delay) or 8.5,
        tonumber(state.interval) or 80.0,
        xml_escape(state.target or '<me>'),
        xml_escape(state.playlist or ''),
        state.nitro and 'true' or 'false',
        state.ccsv and 'true' or 'false',
        state.marcato_first and 'true' or 'false',
        tostring(math.floor(tonumber(state.marcato_index) or 1)),
        xml_escape(state.marcato_song or '')
    )
    lines[#lines+1] = '</configs>'

    local f = io.open(CONFIG_FILE, 'w+')
    if not f then
        echo('Warning: Failed to save configs.xml (cannot write).')
        return false
    end
    f:write(table.concat(lines, '\n'))
    f:write('\n')
    f:close()
    return true
end

----------------------------------------------------------------------------------------------------
-- settings.lua (playlists) - copy behavior from the provided singer.lua
----------------------------------------------------------------------------------------------------
if type(_G.L) ~= 'function' then _G.L = function(t) return t end end
if type(_G.T) ~= 'function' then _G.T = function(t) return t end end

local function rebuild_playlist_cache()
    state._pl_names_cache = nil
    state._pl_pos = 1
    state._pl_lut = nil

    local cfg = state.settings
    if not cfg or type(cfg.playlist) ~= 'table' then
        return
    end

    local names = {}
    local lut = {}
    for k, _ in pairs(cfg.playlist) do
        if type(k) == 'string' then
            names[#names + 1] = k
            lut[k:lower()] = k
        end
    end

    table.sort(names, function(a,b) return a:lower() < b:lower() end)
    state._pl_names_cache = names
    state._pl_lut = lut
end

local function load_settings()
    package.loaded['settings'] = nil

    -- 1) require (after package.path injection)
    local ok, cfg = pcall(require, 'settings')
    if ok and type(cfg) == 'table' then
        state.settings = cfg
        rebuild_playlist_cache()
        return true
    end

    -- 2) fallback: dofile from addon dir (strongest for v3)
    if SCRIPT_DIR ~= '' then
        ok, cfg = pcall(dofile, SETTINGS_FILE)
        if ok and type(cfg) == 'table' then
            state.settings = cfg
            rebuild_playlist_cache()
            return true
        end
    end

    state.settings = nil
    rebuild_playlist_cache()
    return false
end

local function list_playlists()
    local cfg = state.settings
    if not cfg or type(cfg.playlist) ~= 'table' then
        echo('No playlists found. Put settings.lua next to singer.lua.')
        return
    end

    if not state._pl_names_cache then
        rebuild_playlist_cache()
    end

    local names = state._pl_names_cache
    if not names or #names == 0 then
        echo('No playlists in settings.lua (playlist table is empty).')
        return
    end

    local per_call = 10
    local i = state._pl_pos or 1
    if i > #names then i = 1 end
    local j = math.min(i + per_call - 1, #names)

    local slice = {}
    for k = i, j do
        slice[#slice + 1] = names[k]
    end

    echo(('Playlists %d-%d of %d: %s'):format(i, j, #names, table.concat(slice, ', ')))

    if j >= #names then
        state._pl_pos = #names + 1
        echo('Use /singer playlists again to restart from the beginning.')
    else
        state._pl_pos = j + 1
        echo('Use /singer playlists again for next list.')
    end
end

local function set_playlist(name)
    local cfg = state.settings
    if not cfg or type(cfg.playlist) ~= 'table' then
        echo('settings.lua not loaded.')
        return false
    end

    if not state._pl_lut then
        rebuild_playlist_cache()
    end

    local real = state._pl_lut and state._pl_lut[tostring(name):lower()] or nil
    if not real then
        echo('Set not found: ' .. tostring(name))
        return false
    end

    local pl = cfg.playlist[real]
    if type(pl) ~= 'table' then
        echo('Set not found: ' .. tostring(name))
        return false
    end

    local songs = {}
    for i = 1, #pl do
        if type(pl[i]) == 'string' and pl[i] ~= '' then
            songs[#songs + 1] = pl[i]
        end
    end

    state.songs = songs
    state.playlist = real
    save_configs()

    echo('Playlist set: ' .. real)

    -- Print song list (like the original behavior) when selecting a playlist.
    if #songs > 0 then
        echo(('Songs (%d):'):format(#songs))

        -- Print in a safe way (split long lines).
        local line = ''
        for i = 1, #songs do
            local item = ('%d) %s'):format(i, songs[i])
            if line == '' then
                line = item
            elseif (#line + 2 + #item) <= 160 then
                line = line .. ', ' .. item
            else
                echo(line)
                line = item
            end
        end
        if line ~= '' then
            echo(line)
        end
    end
    return true
end

----------------------------------------------------------------------------------------------------
-- Casting logic
----------------------------------------------------------------------------------------------------
local MAX_ACTIONS_PER_CYCLE = 32

local function begin_busy(total_delay)
    state.busy = true
    state.busy_until = now_clock() + (tonumber(total_delay) or 0) + 0.25
end

local function start_pending(steps)
    if state.pending ~= nil then return false end
    if type(steps) ~= 'table' or #steps == 0 then return false end

    state.pending = steps
    state.pending_i = 1
    state.next_action = now_clock() + 0.10

    local total = 0.0
    for _, s in ipairs(steps) do
        total = total + (tonumber(s.wait) or 0)
    end
    begin_busy(total)
    return true
end

local function build_steps_for_song_list(list)
    local steps = {}
    local actions = 0

    if state.nitro then
        steps[#steps+1] = { cmd = '/ja "Nightingale" <me>', wait = 1.6 }
        steps[#steps+1] = { cmd = '/ja "Troubadour" <me>',  wait = 1.6 }
        actions = actions + 2
    end

    if state.ccsv then
        steps[#steps+1] = { cmd = '/ja "Clarion Call" <me>', wait = 1.6 }
        steps[#steps+1] = { cmd = '/ja "Soul Voice" <me>',   wait = 2.0 }
        actions = actions + 2
    end

    -- Marcato rules:
    -- Marcato rules:
    -- 1) If Marcato (first song) is enabled, queue Marcato at the start.
    -- 2) If marcato_song is set, queue Marcato right before that matching song (once per cycle).
    local marc_used = false

    local marc_index = math.floor(tonumber(state.marcato_index) or 1)
    if marc_index < 1 then marc_index = 1 end

    local marc_song = (state.marcato_first and nil) or state.marcato_song
    if type(marc_song) == 'string' then
        marc_song = marc_song:gsub('^%s+', ''):gsub('%s+$', ''):lower()
        if marc_song == '' then marc_song = nil end
    else
        marc_song = nil
    end

    for i, song in ipairs(list) do
        if actions >= MAX_ACTIONS_PER_CYCLE then break end

        -- Marcato by index when enabled (marcato on): queue Marcato right before that song index (once per cycle).
        if state.marcato_first and (not marc_used) and (i == marc_index) then
            steps[#steps+1] = { cmd = '/ja "Marcato" <me>', wait = 2.2 }
            actions = actions + 1
            marc_used = true
        end

        -- Song-specific Marcato (only when marcato on is OFF).
        if (not marc_used) and marc_song and type(song) == 'string' then
            local sn = song:gsub('^%s+', ''):gsub('%s+$', ''):lower()
            if sn == marc_song then
                steps[#steps+1] = { cmd = '/ja "Marcato" <me>', wait = 2.2 }
                actions = actions + 1
                marc_used = true
            end
        end
        steps[#steps+1] = {
            cmd  = ('/ma "%s" %s'):format(song, state.target),
            wait = (state.song_delay + (state.pad or 0)),
        }
        actions = actions + 1
    end

    return steps
end

local function cast_song_list(list)
    if state.pending ~= nil then return false end
    if state.busy then return false end
    if type(list) ~= 'table' then return false end

    local steps = build_steps_for_song_list(list)
    if #steps == 0 then return false end
    return start_pending(steps)
end

local function cast_cycle()
    return cast_song_list(state.songs)
end

----------------------------------------------------------------------------------------------------
-- Status / Help
----------------------------------------------------------------------------------------------------
local function show_status()
    echo(('Status: %s | Repeat: %s | Delay: %.1fs (+%.1f) | Interval: %.0fs | Target: %s | Nitro: %s | CCSV: %s | Marcato: %s(index=%d) | MarcatoSong: %s | Playlist: %s'):format(
        state.enabled and 'ON' or 'OFF',
        state.repeat_cycle and 'ON' or 'OFF',
        state.song_delay,
        (state.pad or 0),
        state.interval,
        state.target,
        state.nitro and 'ON' or 'OFF',
        state.ccsv and 'ON' or 'OFF',
        state.marcato_first and 'ON' or 'OFF',
        math.floor(tonumber(state.marcato_index) or 1),
        state.marcato_song or 'none',
        state.playlist or 'none'
    ))
end

local function show_help()
    echo('Commands:')
    echo('/singer on | off | toggle | status')
    echo('/singer now')
    echo('/singer playlists')
    echo('/singer playlist <name>')
    echo('/singer delay <sec>   (min 0.5)')
    echo('/singer interval <sec> (min 30)')
    echo('/singer target <tgt>  (ex: <me> or <t>)')
    echo('/singer nitro on|off|toggle')
    echo('/singer ccsv  on|off|toggle')
    echo('/singer repeat on|off|toggle')
end

----------------------------------------------------------------------------------------------------
-- Tick
----------------------------------------------------------------------------------------------------
local function tick()
    local t = now_clock()
    local ms = math.floor(t * 1000)
    if ms == state._last_tick_ms then return end
    state._last_tick_ms = ms

    if state.pending ~= nil then
        local step = state.pending[state.pending_i]
        if step and t >= (state.next_action or 0.0) then
            queue_command(step.cmd, 0)
            local wait = tonumber(step.wait) or 0
            state.pending_i = state.pending_i + 1

            if state.pending_i > #state.pending then
                state.pending = nil
                state.pending_i = 0
                state.busy = false
                state.busy_until = 0.0
            else
                state.next_action = t + wait
            end
        end
        return
    end

    if state.busy and t >= (state.busy_until or 0.0) then
        state.busy = false
    end

    if not state.enabled then return end
    if state.busy then return end

    if t >= (state.next_cycle or 0.0) then
        cast_cycle()
        if state.repeat_cycle then
            state.next_cycle = t + (state.interval or 240.0)
        else
            -- Repeat is OFF: run only once (still allow /singer now manually)
            state.next_cycle = t + 9999999.0
        end
    end
end

----------------------------------------------------------------------------------------------------
-- Command handler (Ashita v3)
----------------------------------------------------------------------------------------------------
local function handle_command(cmd, nType)
    if type(cmd) ~= 'string' or cmd == '' then return false end

    local parts = tokenize_command(cmd)
    if #parts == 0 then return false end

    local p0 = norm_prefix(parts[1])
    if p0 ~= '/singer' and p0 ~= '/sing' then
        return false
    end

    local sub = (parts[2] or ''):lower()

    if sub == '' or sub == 'status' then
        show_status(); return true
    end
    if sub == 'help' then
        show_help(); return true
    end

    if sub == 'on' then
        state.enabled = true
        state.busy = false
        state.next_cycle = now_clock() + 0.5
        save_configs()
        echo('Enabled.')
        return true
    elseif sub == 'off' then
        state.enabled = false
        state.busy = false
        save_configs()
        echo('Disabled.')
        return true
    elseif sub == 'toggle' then
        state.enabled = not state.enabled
        state.busy = false
        if state.enabled then state.next_cycle = now_clock() + 0.5 end
        save_configs()
        echo(('Toggled: %s'):format(state.enabled and 'ON' or 'OFF'))
        return true
    elseif sub == 'now' then
        local ok = cast_cycle()
        echo(ok and 'Casting.' or 'Busy.')
        return true
    elseif sub == 'playlists' then
        if not state.settings then load_settings() end
        list_playlists()
        return true
    elseif sub == 'playlist' then
        local name = parts[3]
        if not name or name == '' then
            echo('Usage: /singer playlist <name>')
            return true
        end
        if not state.settings then load_settings() end
        set_playlist(name)
        return true
    elseif sub == 'delay' then
        local v = tonumber(parts[3] or '')
        if not v or v < 0.5 then
            echo('Invalid delay. Minimum 0.5')
            return true
        end
        state.song_delay = v
        save_configs()
        echo(('Delay set to %.1f'):format(state.song_delay))
        return true
    elseif sub == 'interval' then
        local v = tonumber(parts[3] or '')
        if not v or v < 30 then
            echo('Invalid interval. Minimum 30')
            return true
        end
        state.interval = v
        save_configs()
        echo(('Interval set to %.0f'):format(state.interval))
        return true
    elseif sub == 'target' then
        local tgt = parts[3]
        if not tgt or #tgt == 0 then
            echo('Invalid target.')
            return true
        end
        state.target = tgt
        save_configs()
        echo(('Target set to %s'):format(state.target))
        return true
    elseif sub == 'nitro' then
        local v = (parts[3] or ''):lower()
        if v == '' or v == 'toggle' then state.nitro = not state.nitro
        elseif v == 'on' then state.nitro = true
        elseif v == 'off' then state.nitro = false
        else
            echo('Usage: /singer nitro on|off|toggle')
            return true
        end
        save_configs()
        echo(('Nitro: %s'):format(state.nitro and 'ON' or 'OFF'))
        return true
    elseif sub == 'ccsv' then
        local v = (parts[3] or ''):lower()
        if v == '' or v == 'toggle' then state.ccsv = not state.ccsv
        elseif v == 'on' then state.ccsv = true
        elseif v == 'off' then state.ccsv = false
        else
            echo('Usage: /singer ccsv on|off|toggle')
            return true
        end
        save_configs()
        echo(('CCSV: %s'):format(state.ccsv and 'ON' or 'OFF'))
        return true

    elseif sub == 'marcato' then
        local v = parts[3] or ''
        local lv = v:lower()

        -- Toggle / enable / disable: controls Marcato-by-index.
        if lv == '' or lv == 'toggle' or lv == 'on' or lv == 'off' then
            if lv == '' or lv == 'toggle' then
                state.marcato_first = not state.marcato_first
            elseif lv == 'on' then
                state.marcato_first = true
            elseif lv == 'off' then
                state.marcato_first = false
            end
            save_configs()
            echo(('Marcato (by index): %s (index=%d)'):format(state.marcato_first and 'ON' or 'OFF', math.floor(tonumber(state.marcato_index) or 1)))
            return true
        end

        -- Numeric: set the song index for Marcato when enabled.
        local n = tonumber(v)
        if n and n >= 1 then
            state.marcato_index = math.floor(n)
            save_configs()
            echo(('Marcato index set to %d (use /singer marcato on)'):format(state.marcato_index))
            return true
        end

        -- Song name: save MarcatoSong persistently (used only when Marcato-by-index is OFF).
        state.marcato_song = v
        save_configs()
        echo(('Marcato song saved: %s (used only when marcato on is OFF)'):format(v))
        return true
    end

    echo('Unknown command. Use /singer help')
    return true
end

----------------------------------------------------------------------------------------------------
-- Events (Ashita v3 only)
----------------------------------------------------------------------------------------------------
if ashita and ashita.register_event then
    ashita.register_event('load', function()
        -- remove any leftover tmp from older experiments
        pcall(function() os.remove(SCRIPT_DIR .. 'settings.lua.tmp') end)

        load_settings()
        load_configs()

        -- If configs.xml saved a playlist name, apply it after settings loaded
        if state.settings and state.playlist and state.playlist ~= '' then
            set_playlist(state.playlist)
        end

        -- Always disable auto-start on addon load (prevents singing after reload / game restart).
        state.enabled = false
        state.busy = false
        state.pending = nil
        state.pending_i = 0
        state.next_action = 0.0
        state.next_cycle = now_clock() + 9999999.0
        pcall(save_configs) -- persist disabled so it never resumes automatically.
        echo('Loaded (Ashita v3 ONLY, NO HUD). Auto-start is DISABLED. Use /singer on or /singer now')
        -- IMPORTANT: do not return any value here (no "return nil")
    end)

    ashita.register_event('unload', function()
        pcall(save_configs)
        echo('Unloaded.')
        -- IMPORTANT: do not return any value here (no "return nil")
    end)

    ashita.register_event('command', function(cmd, nType)
        local handled = handle_command(cmd, nType)
        return handled
    end)

    pcall(function() ashita.register_event('d3d_present', function() tick() end) end)
    pcall(function() ashita.register_event('render',      function() tick() end) end)
    pcall(function() ashita.register_event('prerender',   function() tick() end) end)
end
