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
_addon.version  = '1.1-v3-playlist-cycle'
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
    ------------------------------------------------------------------------------------------------
    -- HUD Settings (pbar-style)
    ------------------------------------------------------------------------------------------------
    hud_enabled     = true,
    hud_x           = 7,
    hud_y           = 120,

    -- Font style (ثابت مثل pbar.lua)
    hud_font_name   = 'Arial',
    hud_font_size   = 10,
    hud_font_color  = 0xFFFFFFFF,
    hud_font_bold   = true,
    hud_bg_color    = 0x80000000,
    hud_bg_visible  = true,

    -- داخلي
    _hud_ready      = false,
    _hud_box        = { x = 7, y = 120, w = 220, h = 120 },
    _hud_lines      = {},
    _hud_actions    = {},
    _hud_dragging   = false,
    _hud_drag_dx    = 0,
    _hud_drag_dy    = 0,
    _hud_next_upd   = 0.0,

}

------------------------------------------------------------------------------------------------
-- تعريفات مسبقة للـ HUD (لتفادي اعتبارها globals قبل تعريفها)
------------------------------------------------------------------------------------------------
local hud_update
local hud_set_visible

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
        state.marcato_song    = xml_get_attr(settings_tag, 'marcato_song') or nil
        if state.marcato_song == '' then state.marcato_song = nil end
        state.playlist     = xml_get_attr(settings_tag, 'active') or nil
    end

        -- HUD settings
        local hv = xml_get_attr(settings_tag, 'hud')
        if hv ~= nil then state.hud_enabled = to_bool(hv) else state.hud_enabled = true end
        state.hud_x = to_num(xml_get_attr(settings_tag, 'hud_x'), tonumber(state.hud_x) or 7)
        state.hud_y = to_num(xml_get_attr(settings_tag, 'hud_y'), tonumber(state.hud_y) or 120)

    return true
end

local function save_configs()
    local lines = {}
    lines[#lines+1] = '<?xml version="1.0" encoding="UTF-8"?>'
    lines[#lines+1] = '<configs>'
        lines[#lines+1] = ('  <settings enabled="%s" repeat="%s" delay="%.1f" cycle="%.1f" target="%s" active="%s" '
        .. 'use_nitro="%s" use_ccsv="%s" use_marcato="%s" marcato_index="%d" marcato_song="%s" '
        .. 'hud="%s" hud_x="%d" hud_y="%d" debug="false" />'):format(
        state.enabled and 'true' or 'false',
        state.repeat_cycle and 'true' or 'false',
        tonumber(state.song_delay) or 8.5,
        tonumber(state.interval) or 80.0,
        xml_escape(state.target or '<me>'),
        xml_escape(state.playlist or ''),
        state.nitro and 'true' or 'false',
        state.ccsv and 'true' or 'false',
        state.marcato_first and 'true' or 'false',
        math.floor(tonumber(state.marcato_index) or 1),
        xml_escape(state.marcato_song or ''),
        state.hud_enabled and 'true' or 'false',
        math.floor(tonumber(state.hud_x) or 7),
        math.floor(tonumber(state.hud_y) or 120)
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


----------------------------------------------------------------------------------------------------
-- استخراج ترتيب أسماء الـ Playlists من settings.lua بنفس ترتيب الكتابة داخل الملف
-- (لأن pairs() لا يضمن ترتيب ثابت في Lua 5.1)
----------------------------------------------------------------------------------------------------
local function parse_playlist_names_from_settings_file()
    local f = io.open(SETTINGS_FILE, 'r')
    if not f then return nil end
    local file_text = f:read('*a') or ''
    f:close()

    -- ابحث عن جدول: playlist = { ... }
    local s = file_text:find('playlist')
    if not s then return nil end

    local eq = file_text:find('=', s)
    if not eq then return nil end

    local brace = file_text:find('{', eq)
    if not brace then return nil end

    -- حدد نهاية جدول playlist عبر عدّ الأقواس (يشمل الجداول الداخلية للأغاني)
    local depth = 0
    local i = brace
    local finish = nil
    while i <= #file_text do
        local c = file_text:sub(i,i)
        if c == '{' then
            depth = depth + 1
        elseif c == '}' then
            depth = depth - 1
            if depth == 0 then
                finish = i
                break
            end
        end
        i = i + 1
    end

    if not finish or finish <= brace then
        return nil
    end

    local chunk = file_text:sub(brace, finish)

    -- التقط أسماء المفاتيح ["name"] = {  بالترتيب
    local names = {}
    for key in chunk:gmatch('%[%s*["\']([^"\']+)["\']%s*%]%s*=%s*%{') do
        if key and key ~= '' then
            names[#names + 1] = key
        end
    end

    if #names == 0 then
        return nil
    end
    return names
end

local function rebuild_playlist_cache()
    state._pl_names_cache = nil
    state._pl_pos = 1
    state._pl_lut = nil

    local cfg = state.settings
    if not cfg or type(cfg.playlist) ~= 'table' then
        return
    end

    -- Build LUT for case-insensitive matching:
    local names = {}
    local lut = {}
    for k, _ in pairs(cfg.playlist) do
        if type(k) == 'string' then
            names[#names + 1] = k
            lut[k:lower()] = k
        end
    end

    -- Preserve the order from settings.lua (file order) if possible:
    local file_names = parse_playlist_names_from_settings_file()
    if file_names and #file_names > 0 then
        local ordered = {}
        local seen = {}

        for i = 1, #file_names do
            local want = tostring(file_names[i] or ''):lower()
            local real = lut[want]
            if real and not seen[real:lower()] then
                ordered[#ordered + 1] = real
                seen[real:lower()] = true
            end
        end

        -- Append anything not found in the file-order scan (fallback)
        for i = 1, #names do
            local k = names[i]
            local kl = k:lower()
            if not seen[kl] then
                ordered[#ordered + 1] = k
                seen[kl] = true
            end
        end

        if #ordered > 0 then
            names = ordered
        end
    else
        -- Stable fallback: alphabetical
        table.sort(names, function(a,b) return a:lower() < b:lower() end)
    end

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
-- /sing playlist cycle
-- كل مرة: ينتقل للـ Playlist التالي (حسب ترتيب settings.lua)
----------------------------------------------------------------------------------------------------
local function cycle_playlist()
    if not state.settings then
        load_settings()
    end
    if not state._pl_names_cache then
        rebuild_playlist_cache()
    end

    local names = state._pl_names_cache
    if not names or #names == 0 then
        echo('No playlists found. Put settings.lua next to singer.lua.')
        return false
    end

    local cur = tostring(state.playlist or ''):lower()
    local idx = 0
    for i = 1, #names do
        if tostring(names[i] or ''):lower() == cur then
            idx = i
            break
        end
    end

    local next_i = (idx % #names) + 1
    local next_name = names[next_i]
    return set_playlist(next_name)
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

    -- Marcato behavior (copied from the original Singer idea in sing_cast.lua):
    -- When the next song to be cast matches the configured Marcato target, cast Marcato FIRST,
    -- then cast the song on the next queued step (same cycle). It never replaces the whole playlist.
    local marc_used = false
    local marc_index = math.floor(tonumber(state.marcato_index) or 1)
    if marc_index < 1 then marc_index = 1 end

    local marc_song = state.marcato_song
    if type(marc_song) == 'string' then
        marc_song = marc_song:gsub('^%s+', ''):gsub('%s+$', ''):lower()
        if marc_song == '' then marc_song = nil end
    else
        marc_song = nil
    end

    for i, song in ipairs(list) do
        if actions >= MAX_ACTIONS_PER_CYCLE then break end

        local song_name = (type(song) == 'string') and (song:gsub('^%s+', ''):gsub('%s+$', '')) or nil
        local song_lower = song_name and song_name:lower() or nil

        -- Mode A: Marcato ON (by index) -> Marcato before song #marc_index.
        if state.marcato_first and (not marc_used) and (i == marc_index) then
            steps[#steps+1] = { cmd = '/ja "Marcato" <me>', wait = 2.2 }
            actions = actions + 1
            marc_used = true
        end

        -- Mode B: Marcato OFF -> if marcato_song matches this song, Marcato before it.
        if (not state.marcato_first) and (not marc_used) and marc_song and song_lower and (song_lower == marc_song) then
            steps[#steps+1] = { cmd = '/ja "Marcato" <me>', wait = 2.2 }
            actions = actions + 1
            marc_used = true
        end

        if song_name and song_name ~= '' then
            steps[#steps+1] = {
                cmd  = ('/ma "%s" %s'):format(song_name, state.target),
                wait = (state.song_delay + (state.pad or 0)),
            }
            actions = actions + 1
        end
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
    hud_update(false)
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
            echo('Usage: /singer playlist <name|cycle>')
            return true
        end

        if tostring(name):lower() == 'cycle' then
            cycle_playlist()
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
            echo(('Marcato (by index): %s (index=%d)'):format(
                state.marcato_first and 'ON' or 'OFF',
                math.floor(tonumber(state.marcato_index) or 1)
            ))
            return true
        end

        -- Numeric: set the song index for Marcato when enabled.
        local n = tonumber(v)
        if n and n >= 1 then
            state.marcato_index = math.floor(n)
            save_configs()
            echo(('Marcato index set to %d'):format(state.marcato_index))
            return true
        end

        -- Song name: save MarcatoSong persistently (used only when marcato on is OFF).
        state.marcato_song = v
        save_configs()
        echo(('Marcato song saved: %s'):format(v))
        return true
    elseif sub == 'repeat' then
        local v = (parts[3] or ''):lower()
        if v == '' or v == 'toggle' then state.repeat_cycle = not state.repeat_cycle
        elseif v == 'on' then state.repeat_cycle = true
        elseif v == 'off' then state.repeat_cycle = false
        else
            echo('Usage: /singer repeat on|off|toggle')
            return true
        end
        save_configs()
        if state.repeat_cycle then
            state.next_cycle = now_clock() + 0.5
        end
        echo(('Repeat: %s'):format(state.repeat_cycle and 'ON' or 'OFF'))
        return true
    end

    
    if sub == 'hud' then
        local v = (parts[3] or ''):lower()
        if v == '' then
            echo(('HUD: %s (x=%d,y=%d)'):format(state.hud_enabled and 'ON' or 'OFF', math.floor(tonumber(state.hud_x) or 7), math.floor(tonumber(state.hud_y) or 120)))
            return true
        end
        if v == 'on' then
            state.hud_enabled = true
            save_configs()
            hud_update(true)
            echo('HUD: ON')
            return true
        end
        if v == 'off' then
            state.hud_enabled = false
            save_configs()
            hud_set_visible(false)
            echo('HUD: OFF')
            return true
        end
        if v == 'toggle' then
            state.hud_enabled = not state.hud_enabled
            save_configs()
            hud_update(true)
            echo('HUD: ' .. (state.hud_enabled and 'ON' or 'OFF'))
            return true
        end
        echo('Usage: /singer hud on|off|toggle')
        return true
    end

echo('Unknown command. Use /singer help')
    return true
end

----------------------------------------------------------------------------------------------------

----------------------------------------------------------------------------------------------------
-- pbar-style HUD (Ashita v3)
-- نفس طريقة pbar.lua: FontManager + Background + تحديث في render / d3d_present / prerender.
----------------------------------------------------------------------------------------------------
local HUD_ALIAS = '__singer_addon_hud'

-- Windows mouse message ids (Ashita v3 passes these)
local WM_MOUSEMOVE   = 0x0200
local WM_LBUTTONDOWN = 0x0201
local WM_LBUTTONUP   = 0x0202

-- -----------------------------------------------------------------------------------------------
-- دوال HUD مساعدة
-- -----------------------------------------------------------------------------------------------
local function hud_get_font()
    local fm = nil
    local f  = nil
    pcall(function()
        fm = AshitaCore:GetFontManager()
        if fm then
            -- Create() غالباً يرجّع نفس الكائن اذا كان موجود
            f = fm:Create(HUD_ALIAS)
        end
    end)
    return f
end

local function hud_init()
    if state._hud_ready then return end
    local f = hud_get_font()
    if not f then return end

    pcall(function()
        f:SetBold(state.hud_font_bold and true or false)
        f:SetColor(state.hud_font_color)
        f:SetFontFamily(state.hud_font_name)
        f:SetFontHeight(state.hud_font_size)
        f:SetPositionX(tonumber(state.hud_x) or 7)
        f:SetPositionY(tonumber(state.hud_y) or 120)
        f:SetText('')
        f:SetVisibility(false)

        local bg = f:GetBackground()
        if bg then
            bg:SetColor(state.hud_bg_color)
            bg:SetVisibility(state.hud_bg_visible and true or false)
        end
    end)

    state._hud_ready = true
end

hud_set_visible = function(v)
    local f = hud_get_font()
    if not f then return end
    pcall(function()
        f:SetVisibility(v and true or false)
    end)
end

local function hud_set_position(x, y)
    local f = hud_get_font()
    if not f then return end
    pcall(function()
        f:SetPositionX(x)
        f:SetPositionY(y)
    end)
end

local function hud_set_text(text)
    local f = hud_get_font()
    if not f then return end
    pcall(function()
        f:SetText(text or '')
    end)
end

-- color helpers for Ashita text (|cAARRGGBB| .. |r)
local function hud_col(on, on_color, off_color)
    if on then
        return ('|c%s|ON|r'):format(on_color or 'FF00FF00')
    end
    return ('|c%s|OFF|r'):format(off_color or 'FFFF0000')
end

local function hud_build_lines()
    state._hud_lines = {}
    state._hud_actions = {}

    local function add(line, fn)
        state._hud_lines[#state._hud_lines+1] = line
        state._hud_actions[#state._hud_actions+1] = fn
    end

    -- سطر 1: عنوان (منطقة سحب)
    add('|cFFFFFFFF|Singer|r', nil)

    -- سطر 2: Enabled (click)
    add(('Enabled: [%s]'):format(hud_col(state.enabled)), function()
        state.enabled = not state.enabled
        state.busy = false
        if state.enabled then
            state.next_cycle = now_clock() + 0.5
        else
            state.next_cycle = now_clock() + 9999999.0
        end
        save_configs()
    end)

    -- سطر 3: Repeat (click)
    add(('Repeat:  [%s]'):format(hud_col(state.repeat_cycle)), function()
        state.repeat_cycle = not state.repeat_cycle
        save_configs()
    end)

    -- سطر 4: Playlist
    add(('Playlist: |cFFFFFFFF|%s|r'):format(state.playlist or 'none'), nil)

    -- سطر 5: Nitro (click)
    add(('Nitro:   [%s]'):format(hud_col(state.nitro)), function()
        state.nitro = not state.nitro
        save_configs()
    end)

    -- سطر 6: CCSV (click)
    add(('CCSV:    [%s]'):format(hud_col(state.ccsv)), function()
        state.ccsv = not state.ccsv
        save_configs()
    end)

    -- سطر 7: Marcato (click)
    add(('Marcato: [%s] (index=%d)'):format(hud_col(state.marcato_first), math.floor(tonumber(state.marcato_index) or 1)), function()
        state.marcato_first = not state.marcato_first
        save_configs()
    end)

    if (not state.marcato_first) and state.marcato_song and state.marcato_song ~= '' then
        add(('MarcatoSong: |cFFFFFFFF|%s|r'):format(state.marcato_song), nil)
    end

    -- قائمة الأغاني (عرض فقط)
    if state.songs and type(state.songs) == 'table' then
        local mi = math.floor(tonumber(state.marcato_index) or 1)
        for i = 1, #state.songs do
            local sname = tostring(state.songs[i] or '')
            local mark = ''
            if state.marcato_first and i == mi then
                mark = '|cFFFFFF00|*|r '
            end
            add(('  %s%d) %s'):format(mark, i, sname), nil)
            if #state._hud_lines >= 14 then break end -- امنع التمدد الكبير
        end
    end
end

local function hud_recalc_box()
    local line_h = (tonumber(state.hud_font_size) or 10) + 4
    local pad    = 6
    local char_w = 7

    local maxlen = 0
    for i = 1, #state._hud_lines do
        local l = state._hud_lines[i] or ''
        if #l > maxlen then maxlen = #l end
    end

    state._hud_box.x = math.floor(tonumber(state.hud_x) or 7)
    state._hud_box.y = math.floor(tonumber(state.hud_y) or 120)
    state._hud_box.w = (maxlen * char_w) + (pad * 2)
    state._hud_box.h = (#state._hud_lines * line_h) + (pad * 2)
    state._hud_box._line_h = line_h
    state._hud_box._pad = pad
end

local function hud_point_inside(x, y)
    local b = state._hud_box
    return (x >= b.x and x <= (b.x + b.w) and y >= b.y and y <= (b.y + b.h))
end

local function hud_line_at(y)
    local b = state._hud_box
    local rel = y - b.y - (b._pad or 6)
    if rel < 0 then return 0 end
    return math.floor(rel / (b._line_h or 14)) + 1
end

hud_update = function(force)
    if not state.hud_enabled then
        hud_set_visible(false)
        return
    end

    hud_init()

    local t = now_clock()
    if (not force) and t < (state._hud_next_upd or 0.0) then
        return
    end

    hud_build_lines()
    hud_recalc_box()

    hud_set_position(state._hud_box.x, state._hud_box.y)
    hud_set_text(table.concat(state._hud_lines, '\n'))
    hud_set_visible(true)

    state._hud_next_upd = t + 0.20
end

-- -----------------------------------------------------------------------------------------------
-- Mouse (Drag + Click)
-- يدعم شكلين من حدث الماوس:
--  1) mouse(id, x, y, delta, blocked)
--  2) mouse(e) حيث e جدول فيه message/x/y/delta/blocked
-- -----------------------------------------------------------------------------------------------
local function hud_handle_mouse(id, x, y, delta, blocked)
    -- ignore invalid coordinates
    if type(x) ~= 'number' or type(y) ~= 'number' then return false end

    -- سحب
    if state._hud_dragging then
        if id == WM_MOUSEMOVE then
            state.hud_x = math.floor(x - state._hud_drag_dx)
            state.hud_y = math.floor(y - state._hud_drag_dy)
            hud_update(true)
            return true
        elseif id == WM_LBUTTONUP then
            state._hud_dragging = false
            save_configs()
            hud_update(true)
            return true
        end
        return true
    end

    if id == WM_LBUTTONDOWN then
        hud_update(true)
        if not hud_point_inside(x, y) then return false end

        local line = hud_line_at(y)
        if line == 1 then
            state._hud_dragging = true
            state._hud_drag_dx = x - (tonumber(state.hud_x) or state._hud_box.x)
            state._hud_drag_dy = y - (tonumber(state.hud_y) or state._hud_box.y)
            return true
        end

        return true
    elseif id == WM_LBUTTONUP then
        if not hud_point_inside(x, y) then return false end

        local line = hud_line_at(y)
        local fn = state._hud_actions and state._hud_actions[line] or nil
        if type(fn) == 'function' then
            fn()
            hud_update(true)
            return true
        end
        return true
    end

    return false
end

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
        echo('Loaded (Ashita v3 ONLY, HUD (pbar-style)). Auto-start is DISABLED. Use /singer on or /singer now')
        -- IMPORTANT: do not return any value here (no "return nil")
    end)

    ashita.register_event('unload', function()
        pcall(save_configs)
        -- حذف HUD
        pcall(function()
            local fm = AshitaCore:GetFontManager()
            if fm and fm.Delete then fm:Delete(HUD_ALIAS) end
        end)

        echo('Unloaded.')
        -- IMPORTANT: do not return any value here (no "return nil")
    end)

    ashita.register_event('command', function(cmd, nType)
        local handled = handle_command(cmd, nType)
        return handled
    end)

    ashita.register_event('mouse', function(a, b, c, d, e)
        -- يدعم mouse(e) او mouse(id,x,y,delta,blocked)
        local id, x, y, delta, blocked
        if type(a) == 'table' then
            id = a.message or a.id or a.msg
            x  = a.x or a.X
            y  = a.y or a.Y
            delta = a.delta
            blocked = a.blocked
        else
            id, x, y, delta, blocked = a, b, c, d, e
        end
        local handled = false
        pcall(function() handled = hud_handle_mouse(id, x, y, delta, blocked) end)
        return handled
    end)


    pcall(function() ashita.register_event('d3d_present', function() tick() end) end)
    pcall(function() ashita.register_event('render',      function() tick() end) end)
    pcall(function() ashita.register_event('prerender',   function() tick() end) end)
end
