-- SPDX-License-Identifier: AGPL-3.0-only
-- Minfolio: a native KOReader live-styled Markdown editor for the Kindle, launched from KUAL.
-- The KUAL shortcut writes a target into /tmp/minfolio_launch; this opens the notes browser at startup.
local Device = require("device")
local Dispatcher = require("dispatcher")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local Menu = require("ui/widget/menu")
local TitleBar = require("ui/widget/titlebar")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local IconWidget = require("ui/widget/iconwidget")
local Font = require("ui/font")
Font.fontmap.ifont = Font.fontmap.ifont or "NotoSans-Italic.ttf"
local Blitbuffer = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Notification = require("ui/widget/notification")
local lfs = require("libs/libkoreader-lfs")
local socket = require("socket")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

local function now_seconds()
    return (socket and socket.gettime and socket.gettime()) or os.time()
end

local function plugin_dir()
    local src = debug.getinfo(1, "S").source or ""
    src = src:gsub("^@", "")
    return src:match("^(.*)/[^/]*$") or "."
end

local function load_local_config()
    local ok, cfg = pcall(dofile, plugin_dir() .. "/config.lua")
    if ok and type(cfg) == "table" then
        return cfg
    end
    return {}
end

local CONFIG = load_local_config()
local NOTES_DIR = CONFIG.notes_dir or "/mnt/us/notes"
local STATE_DIR = CONFIG.state_dir or "/mnt/us/minfolio"
local FL_STATE_PATH = STATE_DIR .. "/frontlight.lua"
local MINFOLIO_STATE_PATH = STATE_DIR .. "/state.lua"
local function status_date_text()
    return os.date("%a, %d %b  %I:%M %p")
end
local function status_time_text()
    return os.date("%I:%M %p")
end
local function battery_status_text()
    local ok, pd = pcall(function() return Device:getPowerDevice() end)
    if ok and pd then
        local cap = pd:getCapacity()
        if cap then return tostring(cap) .. "%" end
    end
    return ""
end
local function battery_info()
    local ok, pd = pcall(function() return Device:getPowerDevice() end)
    if not (ok and pd and pd.getCapacity) then return nil end
    local cap = pd:getCapacity()
    if not cap then return nil end
    local charging = false
    local cok, c = pcall(function() return pd:isCharging() end)
    if cok then charging = not not c end
    return { cap = math.max(0, math.min(100, math.floor(cap))), charging = charging }
end
-- A hand-drawn Kindle-style battery pill (outline + proportional fill + nub) with
-- the percentage beside it. Drawn from primitives so it never depends on an icon
-- font/asset being present, and stays crisp at the device DPI.
local function battery_indicator()
    local info = battery_info()
    if not info then return nil end
    local bs = function(px) return Screen:scaleBySize(px) end
    local bw, bh, pad = bs(22), bs(13), bs(1)
    local inner_w = bw - 2 * (1 + pad)
    local inner_h = bh - 2 * (1 + pad)
    local fill_w = info.charging and inner_w or math.max(0, math.min(inner_w, math.floor(inner_w * info.cap / 100)))
    local fill = HorizontalGroup:new{ align = "top" }
    if fill_w > 0 then
        fill[#fill+1] = LineWidget:new{ background = Blitbuffer.COLOR_BLACK, dimen = Geom:new{ w = fill_w, h = inner_h } }
    end
    if inner_w - fill_w > 0 then
        fill[#fill+1] = LineWidget:new{ background = Blitbuffer.Color8(215), dimen = Geom:new{ w = inner_w - fill_w, h = inner_h } }
    end
    local body = FrameContainer:new{ bordersize = 1, radius = bs(2), padding = pad, margin = 0,
        width = bw, height = bh, fill }
    local nub = CenterContainer:new{ dimen = Geom:new{ w = bs(3), h = bh },
        LineWidget:new{ background = Blitbuffer.COLOR_BLACK, dimen = Geom:new{ w = bs(2), h = bs(6) } } }
    local pct = TextWidget:new{ text = tostring(info.cap) .. "%",
        face = Font:getFace("cfont", 17), fgcolor = Blitbuffer.COLOR_BLACK }
    return HorizontalGroup:new{ align = "center", body, nub, HorizontalSpan:new{ width = bs(5) }, pct }
end
local function write_file(path, data)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end
local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end
local function split_text_lines(text)
    local lines = {}
    for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do lines[#lines+1] = line end
    if #lines == 0 then lines = { "" } end
    return lines
end
local function read_frontlight_state()
    local ok, state = pcall(dofile, FL_STATE_PATH)
    return (ok and type(state) == "table") and state or {}
end
local function clamp_minfolio_scale(scale)
    return math.max(0.6, math.min(1.8, tonumber(scale) or 1.0))
end
local function read_minfolio_state()
    local ok, state = pcall(dofile, MINFOLIO_STATE_PATH)
    return (ok and type(state) == "table") and state or {}
end
local MINFOLIO_STATE = read_minfolio_state()
MINFOLIO_STATE.scale = clamp_minfolio_scale(MINFOLIO_STATE.scale or CONFIG.minfolio_scale)
local function save_minfolio_state()
    lfs.mkdir(STATE_DIR)
    write_file(MINFOLIO_STATE_PATH, string.format("return { scale = %.3f }\n", clamp_minfolio_scale(MINFOLIO_STATE.scale)))
end
local FL
local function save_frontlight_state()
    lfs.mkdir(STATE_DIR)
    write_file(FL_STATE_PATH, string.format(
        "return { on = %s, bright = %d, last = %d, amber = %d }\n",
        FL.on and "true" or "false",
        math.floor(FL.bright or 0),
        math.floor(FL.last or 0),
        math.floor(FL.amber or 0)
    ))
end
-- Frontlight is driven through the Kindle framework's powerd (lipc) -- the same
-- controller the OS uses: flIntensity = brightness, currentAmberLevel = warmth.
-- Going through the framework (instead of writing the fp9966 sysfs banks behind
-- its back) means our changes persist across wakes and behave like the native
-- controls: no dual-controller fights, no self-relighting, no warmth drift, and
-- warmth no longer changes the brightness number.
local function lipc_get(prop)
    local h = io.popen("lipc-get-prop com.lab126.powerd " .. prop .. " 2>/dev/null")
    if not h then return nil end
    local v = h:read("*l"); h:close()
    return tonumber(v)
end
local function lipc_set(prop, v)
    os.execute("lipc-set-prop com.lab126.powerd " .. prop .. " " .. math.floor(v) .. " >/dev/null 2>&1")
end
local FL_MAX = lipc_get("flMaxIntensity") or 24
local FL_AMBER_MAX = 24
local FL_HAS_AMBER = lipc_get("currentAmberLevel") ~= nil
local FL_STEP = math.max(1, math.floor(FL_MAX / 8))
local FL_AMBER_STEP = math.max(1, math.floor(FL_AMBER_MAX / 6))
local FL_BRIGHT_NOW = lipc_get("flIntensity") or 0
local FL_AMBER_NOW = lipc_get("currentAmberLevel") or 0
local FL_SAVED = read_frontlight_state()
FL = {
    bright = FL_BRIGHT_NOW,
    amber  = FL_AMBER_NOW,
    last   = FL_BRIGHT_NOW > 0 and FL_BRIGHT_NOW
        or (tonumber(FL_SAVED.last or FL_SAVED.bright) or math.floor(FL_MAX / 2)),
    on     = FL_BRIGHT_NOW > 0,
}
local function fl_apply()
    local b = math.max(0, math.min(FL_MAX, FL.bright))
    lipc_set("flIntensity", b)
    if FL_HAS_AMBER then lipc_set("currentAmberLevel", math.max(0, math.min(FL_AMBER_MAX, FL.amber))) end
    FL.on = b > 0
    if b > 0 then FL.last = b end
    save_frontlight_state()
end
-- The framework owns the light and persists it across wakes, so there is nothing
-- to "restore" -- just resync our view (for the Light off/on label) from the
-- framework without changing the hardware.
local function fl_restore_if_needed()
    local b = lipc_get("flIntensity")
    if b then FL.bright = b; FL.on = b > 0; if b > 0 then FL.last = b end end
    if FL_HAS_AMBER then local a = lipc_get("currentAmberLevel"); if a then FL.amber = a end end
end
local function fl_adjust(db, da)
    if db and db ~= 0 then
        FL.bright = math.max(0, math.min(FL_MAX, FL.bright + db))
        if FL.bright > 0 then FL.last = FL.bright end
    end
    if da and da ~= 0 and FL_HAS_AMBER then
        FL.amber = math.max(0, math.min(FL_AMBER_MAX, FL.amber + da))
    end
    fl_apply()
end
local function toggle_light()
    if FL.bright > 0 then
        FL.last = FL.bright
        FL.bright = 0
    else
        FL.bright = (FL.last and FL.last > 0) and FL.last or math.floor(FL_MAX / 2)
    end
    fl_apply()
end
-- shared controls menu (frontlight brightness/warmth + per-app extras), reused across mirror / notes / launcher
local function show_controls(extra, on_close)
    local items = {
        { text = "Brightness +",  keep = true, callback = function() fl_adjust(FL_STEP, 0) end },
        { text = "Brightness -",  keep = true, callback = function() fl_adjust(-FL_STEP, 0) end },
        { text = FL.bright > 0 and "Light off" or "Light on", callback = toggle_light },
    }
    if FL_HAS_AMBER then
        table.insert(items, 3, { text = "Warmth +", keep = true, callback = function() fl_adjust(0, FL_AMBER_STEP) end })
        table.insert(items, 4, { text = "Warmth -", keep = true, callback = function() fl_adjust(0, -FL_AMBER_STEP) end })
    end
    for _, it in ipairs(extra or {}) do items[#items+1] = it end
    local menu
    local closed_by_select = false
    menu = Menu:new{
        title = "Controls", item_table = items, is_popout = true,
        width = math.floor(Screen:getWidth() * 0.72), height = math.floor(Screen:getHeight() * 0.7),
        onMenuSelect = function(_s, item)
            if item.keep then
                if item.callback then item.callback() end
                return
            end
            closed_by_select = true
            UIManager:close(menu)
            if on_close then on_close() end
            if item.callback then UIManager:scheduleIn(0.01, item.callback) end
        end,
        close_callback = function() if not closed_by_select and on_close then on_close() end end,
    }
    UIManager:show(menu)
    return menu
end

-- ============================ Markdown styled renderer (Phase 0) ============================
-- tokenize text -> array of lines, each {block=<style>, spans={{text,style},...}}
local MD_FACES = {
    normal = {"cfont", 22}, h1 = {"tfont", 34}, h2 = {"tfont", 29}, h3 = {"tfont", 25},
    bullet = {"cfont", 22}, task = {"cfont", 22}, quote = {"cfont", 22}, bold = {"tfont", 22}, italic = {"ifont", 22},
    code = {"infont", 20}, syntax = {"cfont", 22},
}
local MD_LH = { normal = 25, h1 = 39, h2 = 33, h3 = 29, bullet = 25, quote = 25 }  -- ~1.15 line-height
local MDEDIT_TABLE_PAD_X = 8
local MDEDIT_TABLE_PAD_Y = 5
local function md_face(style, scale)
    local f = MD_FACES[style] or MD_FACES.normal
    return Font:getFace(f[1], math.floor(f[2] * (scale or 1)))
end
local function md_color(style)
    if style == "syntax" then return Blitbuffer.COLOR_WHITE end
    if style == "code" then return Blitbuffer.Color8(55) end
    if style == "quote" then return Blitbuffer.Color8(95) end
    return Blitbuffer.COLOR_BLACK
end

local function md_inline(text)
    local spans, i, n, buf = {}, 1, #text, ""
    local function push(t, s, display) if t ~= "" then spans[#spans+1] = { text = t, style = s, display = display } end end
    while i <= n do
        local c2 = text:sub(i, i+1)
        local c1 = text:sub(i, i)
        local closer, inner_start, marker
        if c2 == "**" then marker = "**"; inner_start = i+2
        elseif c1 == "*" then marker = "*"; inner_start = i+1
        elseif c1 == "`" then marker = "`"; inner_start = i+1
        end
        if marker then closer = text:find(marker, inner_start, true) end
        if marker and closer then
            push(buf, "normal"); buf = ""
            local sty = (marker == "**") and "bold" or (marker == "*") and "italic" or "code"
            push(marker, "syntax", ""); push(text:sub(inner_start, closer-1), sty); push(marker, "syntax", "")
            i = closer + #marker
        else
            buf = buf .. c1; i = i + 1
        end
    end
    push(buf, "normal")
    if #spans == 0 then spans[1] = { text = "", style = "normal" } end
    return spans
end

local function md_tokenize(textstr)
    local lines = {}
    local function with_prefix(prefix, rest, block, display, style)
        local spans = {}
        if prefix and prefix ~= "" then spans[#spans+1] = { text = prefix, style = style or "syntax", display = display or "" } end
        for _, s in ipairs(md_inline(rest)) do spans[#spans+1] = s end
        return { block = block or "normal", spans = spans }
    end
    for line in (tostring(textstr or "") .. "\n"):gmatch("(.-)\n") do
        local hashes, hrest = line:match("^(#+%s+)(.*)$")
        if hashes then
            local level = math.min(#hashes:gsub("%s", ""), 3)
            lines[#lines+1] = { block = "h"..level, spans = {{ text = hashes, style = "syntax", display = "" }, { text = hrest, style = "h"..level }} }
        else
            local pre, rest = line:match("^(%s*[%-%*%+]%s+)(.*)$")
            local ordered = false
            if not pre then
                pre, rest = line:match("^(%s*%d+%.%s+)(.*)$")
                ordered = pre ~= nil
            end
            if pre then
                local task, taskrest = rest:match("^(%[[ xX]%]%s+)(.*)$")
                local spans = {}
                spans[#spans+1] = { text = pre, style = "bullet", display = task and "" or (ordered and pre:gsub("^%s+", "") or "\226\128\162 ") }
                if task then
                    local checked = task:match("%[[xX]%]") ~= nil
                    spans[#spans+1] = { text = task, style = "task", display = checked and "\226\152\145 " or "\226\152\144 " }
                    rest = taskrest
                end
                for _, s in ipairs(md_inline(rest)) do spans[#spans+1] = s end
                -- Keep the leading whitespace so nested items render indented; the
                -- marker span's display drops it (fixed glyph), so the indent is
                -- reapplied as real horizontal space in layoutLine.
                lines[#lines+1] = { block = "bullet", spans = spans, indent_ws = pre:match("^%s*") or "" }
            else
                local task, taskrest = line:match("^(%s*%[[ xX]%]%s+)(.*)$")
                if task then
                    local checked = task:match("%[[xX]%]") ~= nil
                    local tok = with_prefix(task, taskrest, "bullet", checked and "\226\152\145 " or "\226\152\144 ", "task")
                    tok.indent_ws = task:match("^%s*") or ""
                    lines[#lines+1] = tok
                else
                    if line:match("^>%s?") then
                        pre, rest = line:match("^(>%s?)(.*)$")
                        lines[#lines+1] = with_prefix(pre, rest, "quote", "", "syntax")
                    else
                        lines[#lines+1] = { block = "normal", spans = md_inline(line) }
                    end
                end
            end
        end
    end
    return lines
end

local function md_trim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

local function md_split_table_row(line)
    line = tostring(line or "")
    if not line:find("|", 1, true) then return nil end
    local first_pipe = line:find("|", 1, true)
    local last_pipe
    local pos = 1
    while true do
        local p = line:find("|", pos, true)
        if not p then break end
        last_pipe = p
        pos = p + 1
    end
    if not first_pipe or not last_pipe then return nil end

    local leading = line:match("^%s*|") ~= nil
    local trailing = line:match("|%s*$") ~= nil
    local start_pos = leading and (first_pipe + 1) or 1
    local end_pos = trailing and (last_pipe - 1) or #line
    if end_pos < start_pos then return nil end

    local cells = {}
    local cell_start = start_pos
    while cell_start <= end_pos + 1 do
        local pipe = line:find("|", cell_start, true)
        if not pipe or pipe > end_pos then pipe = end_pos + 1 end
        local raw_start, raw_end = cell_start, pipe - 1
        local raw = raw_start <= raw_end and line:sub(raw_start, raw_end) or ""
        local leading_ws = raw:match("^(%s*)") or ""
        local trailing_ws = raw:match("(%s*)$") or ""
        local text_start = raw_start + #leading_ws
        local text_end = raw_end - #trailing_ws
        local text = md_trim(raw)
        if text == "" then
            text_start = raw_start
            text_end = raw_start - 1
        end
        cells[#cells+1] = {
            text = text,
            start_col = math.max(0, text_start - 1),
            end_col = math.max(0, text_end),
        }
        cell_start = pipe + 1
        if pipe > end_pos then break end
    end
    if #cells < 2 then return nil end
    return cells
end

local function md_table_separator(cells)
    if not cells or #cells < 2 then return nil end
    local aligns = {}
    for i, cell in ipairs(cells) do
        local spec = md_trim(cell.text):gsub("%s+", "")
        if not spec:match("^:?-+:?$") then return nil end
        if spec:match("^:") and spec:match(":$") then aligns[i] = "center"
        elseif spec:match(":$") then aligns[i] = "right"
        else aligns[i] = "left" end
    end
    return aligns
end

local function md_table_block(lines, start_i)
    local header = md_split_table_row(lines[start_i])
    if not header then return nil end
    local sep = md_split_table_row(lines[start_i + 1])
    local aligns = md_table_separator(sep)
    if not aligns then return nil end
    local ncols = #sep
    if #header < ncols then return nil end

    local rows = {
        { line = start_i, cells = header, header = true },
    }
    local finish = start_i + 1
    local i = start_i + 2
    while i <= #lines do
        local cells = md_split_table_row(lines[i])
        if not cells or #cells < 2 or md_table_separator(cells) then break end
        rows[#rows+1] = { line = i, cells = cells }
        finish = i
        i = i + 1
    end
    return { start = start_i, finish = finish, ncols = ncols, aligns = aligns, rows = rows }
end

-- ============================ Live styled markdown editor (Phase 1) ============================
-- Shift map for BT-keyboard symbol keys (used by MDEdit:onKeyPress).
local SHIFT_SYM = {
    ["1"]="!", ["2"]="@", ["3"]="#", ["4"]="$", ["5"]="%", ["6"]="^", ["7"]="&", ["8"]="*", ["9"]="(", ["0"]=")",
    ["-"]="_", ["="]="+", ["["]="{", ["]"]="}", ["\\"]="|", [";"]=":", ["'"]='"', [","]="<", ["."]=">", ["/"]="?", ["`"]="~",
}
local KEYPAD_CHAR = {
    KP0 = "0", KP1 = "1", KP2 = "2", KP3 = "3", KP4 = "4", KP5 = "5", KP6 = "6", KP7 = "7", KP8 = "8", KP9 = "9",
    KPMinus = "-", KPPlus = "+", KPDot = ".",
}
local KEYBOARD_EVENT_MAP = {
    [1]="Back", [2]="1", [3]="2", [4]="3", [5]="4", [6]="5", [7]="6", [8]="7", [9]="8", [10]="9", [11]="0",
    [12]="-", [13]="=", [14]="Backspace", [15]="Tab",
    [16]="Q", [17]="W", [18]="E", [19]="R", [20]="T", [21]="Y", [22]="U", [23]="I", [24]="O", [25]="P",
    [26]="[", [27]="]", [28]="Press", [29]="Ctrl",
    [30]="A", [31]="S", [32]="D", [33]="F", [34]="G", [35]="H", [36]="J", [37]="K", [38]="L", [39]=";", [40]="'",
    [41]="`", [42]="Shift", [43]="\\",
    [44]="Z", [45]="X", [46]="C", [47]="V", [48]="B", [49]="N", [50]="M", [51]=",", [52]=".", [53]="/",
    [54]="Shift", [56]="Alt", [57]=" ", [58]="CapsLock",
    [59]="F1", [60]="F2", [61]="F3", [62]="F4", [63]="F5", [64]="F6", [65]="F7", [66]="F8", [67]="F9", [68]="F10",
    [69]="NumLock", [70]="ScrollLock",
    [71]="KP7", [72]="KP8", [73]="KP9", [74]="KPMinus", [75]="KP4", [76]="KP5", [77]="KP6", [78]="KPPlus",
    [79]="KP1", [80]="KP2", [81]="KP3", [82]="KP0", [83]="KPDot", [87]="F11", [88]="F12", [96]="Press",
    [97]="Ctrl", [98]="Home", [99]="PrintScr", [100]="Alt", [102]="Home", [103]="Up", [104]="PageUp",
    [105]="Left", [106]="Right", [107]="End", [108]="Down", [109]="PageDown", [110]="Ins", [111]="Del",
    [114]="VMinus", [115]="VPlus", [116]="Power", [119]="Pause", [125]="Meta", [126]="Meta", [127]="Menu", [139]="Menu",
}
-- UTF-8 cursor helpers: move/delete by whole characters, not bytes (continuation bytes are 0x80..0xBF)
local function utf8_left(s, c)
    if c <= 0 then return 0 end
    c = c - 1
    while c > 0 do local b = s:byte(c+1); if b and b >= 0x80 and b < 0xC0 then c = c - 1 else break end end
    return c
end
local function utf8_right(s, c)
    if c >= #s then return #s end
    c = c + 1
    while c < #s do local b = s:byte(c+1); if b and b >= 0x80 and b < 0xC0 then c = c + 1 else break end end
    return c
end
local function utf8_snap(s, c)        -- snap a byte index back to the nearest char boundary
    while c > 0 and c < #s do local b = s:byte(c+1); if b and b >= 0x80 and b < 0xC0 then c = c - 1 else break end end
    return c
end
local function char_is_space(s)
    return s ~= "" and s:match("^%s$") ~= nil
end
local function prev_word_col(s, c)
    local p = math.max(0, math.min(c or 0, #s))
    while p > 0 do
        local q = utf8_left(s, p)
        if not char_is_space(s:sub(q + 1, p)) then break end
        p = q
    end
    while p > 0 do
        local q = utf8_left(s, p)
        if char_is_space(s:sub(q + 1, p)) then break end
        p = q
    end
    return p
end
local function next_word_col(s, c)
    local p = math.max(0, math.min(c or 0, #s))
    while p < #s do
        local q = utf8_right(s, p)
        if not char_is_space(s:sub(p + 1, q)) then break end
        p = q
    end
    while p < #s do
        local q = utf8_right(s, p)
        if char_is_space(s:sub(p + 1, q)) then break end
        p = q
    end
    return p
end
local function keymod(mods, name)
    if not mods then return nil end
    if type(mods) == "string" then
        return mods == name or mods:lower() == name:lower()
    end
    if mods[name] or mods[name:lower()] or mods[name:upper()] then return true end
    if name == "Ctrl" then return mods.LCtrl or mods.RCtrl end
    if name == "Alt" then return mods.LAlt or mods.RAlt end
    if name == "Meta" then return mods.LMeta or mods.RMeta end
    if name == "Shift" then return mods.LShift or mods.RShift end
    for _, mod in pairs(mods) do
        if type(mod) == "string" and (mod == name or mod:lower() == name:lower()) then return true end
    end
    return nil
end
local function shortcut_mod(mods)
    return keymod(mods, "Ctrl") or keymod(mods, "Meta") or keymod(mods, "Cmd")
        or keymod(mods, "Command") or keymod(mods, "Gui") or keymod(mods, "Super")
end
local function word_key_mod(mods)
    return keymod(mods, "Alt") or shortcut_mod(mods)
end
local function fn_key_mod(mods)
    return keymod(mods, "Fn") or keymod(mods, "Function") or keymod(mods, "Mod5")
end
local function key_mods(key)
    local out = {}
    if Device.input and type(Device.input.modifiers) == "table" then
        for k, v in pairs(Device.input.modifiers) do out[k] = v end
    end
    if key and type(key.modifiers) == "table" then
        for k, v in pairs(key.modifiers) do out[k] = v end
    end
    if key then
        for _, name in ipairs({
            "Shift", "LShift", "RShift",
            "Ctrl", "LCtrl", "RCtrl",
            "Alt", "LAlt", "RAlt",
            "Meta", "LMeta", "RMeta",
            "Cmd", "Command", "Gui", "Super",
            "Fn", "Function", "Mod5",
        }) do
            if key[name] then out[name] = true end
        end
    end
    return out
end
local function install_keyboard_aliases()
    local input = Device.input
    if not input then return end
    local em = input.event_map
    if em then
        for code, name in pairs(KEYBOARD_EVENT_MAP) do
            em[code] = name
        end
    end
    local mods = input.modifiers
    if mods then
        mods.Alt = mods.Alt or false
        mods.Ctrl = mods.Ctrl or false
        mods.Shift = mods.Shift or false
        mods.Meta = mods.Meta or false
        mods.LAlt = mods.LAlt or false
        mods.RAlt = mods.RAlt or false
        mods.LCtrl = mods.LCtrl or false
        mods.RCtrl = mods.RCtrl or false
        mods.LShift = mods.LShift or false
        mods.RShift = mods.RShift or false
        mods.LMeta = mods.LMeta or false
        mods.RMeta = mods.RMeta or false
        mods.Fn = mods.Fn or false
        mods.Function = mods.Function or false
        mods.Mod5 = mods.Mod5 or false
    end
end
local function page_up_key(name)
    return name == "PageUp" or name == "Page_Up" or name == "PgUp" or name == "Prior"
end
local function page_down_key(name)
    return name == "PageDown" or name == "Page_Down" or name == "PgDown" or name == "Next"
end
local function left_key(name)
    return name == "Left" or name == "ArrowLeft" or name == "KEY_LEFT" or name == "CursorLeft"
end
local function right_key(name)
    return name == "Right" or name == "ArrowRight" or name == "KEY_RIGHT" or name == "CursorRight"
end
local function up_key(name)
    return name == "Up" or name == "ArrowUp" or name == "KEY_UP" or name == "CursorUp"
end
local function down_key(name)
    return name == "Down" or name == "ArrowDown" or name == "KEY_DOWN" or name == "CursorDown"
end
local function copy_arr(t) local r = {}; for i = 1, #t do r[i] = t[i] end; return r end
local md_clipboard = ""               -- shared across notes
local function path_join(dir, name)
    if dir == "/" then return "/" .. name end
    return dir .. "/" .. name
end
local function path_parent(path)
    path = tostring(path or NOTES_DIR):gsub("/+$", "")
    if path == "" or path == "/" then return "/" end
    local p = path:match("^(.*)/[^/]+$")
    if not p or p == "" then return "/" end
    return p
end
local function path_base(path)
    local p = tostring(path or ""):gsub("/+$", "")
    return p:match("[^/]+$") or p
end
local function is_markdown_file(name)
    return tostring(name or ""):lower():match("%.md$") ~= nil
end
local function file_signature(path)
    local ok, attr = pcall(lfs.attributes, path)
    if not ok or type(attr) ~= "table" then return nil end
    return {
        mode = attr.mode or "",
        size = tonumber(attr.size) or 0,
        modification = tonumber(attr.modification) or 0,
    }
end
local function same_file_signature(a, b)
    if a == b then return true end
    if not a or not b then return false end
    return a.mode == b.mode and a.size == b.size and a.modification == b.modification
end
local open_markdown_picker, rotate_screen_ccw   -- fwd decls
-- Only ever one editor at a time. Opening a note while another editor is live
-- (e.g. a re-send via kindle-send, or a duplicate launch-flag write) must not
-- stack a second MDEdit on the same file: both keep polling the file and each
-- one's autosave looks like an external change to the other, producing a
-- "Reloaded from disk" storm and a half-repainted screen. edit_note() enforces
-- the singleton; MDEdit clears it on close.
local active_mdedit
local function notify(text)
    UIManager:show(Notification:new{ text = text, timeout = 3 })
end
local wake_repaint_pending = false
local function schedule_wake_repaint()
    if wake_repaint_pending then return end
    wake_repaint_pending = true
    UIManager:scheduleIn(1.0, function()
        wake_repaint_pending = false
        UIManager:setDirty("all", "full")
    end)
end
local MDEDIT_PAD = 40
local MDEDIT_TOPBAR_H = 56
local MDEDIT_TOPBAR_GAP = 14
local MDEDIT_TOOL_MIN_CELL = 72
local MDEDIT_TOOL_DIVIDER = 1
local MDEDIT_TITLE_ACTION_GAP = 18
local MDEDIT_MENU_W = 52
local MDEDIT_TITLE_W = 360
local MDEDIT_PROGRESS_H = 2
local MDEDIT_PROGRESS_GAP = 10
local MDEDIT_LINE_HEIGHT = 0.80
local MDEDIT_LINE_GAP = 0
local MDEDIT_PARA_GAP = 12
local MDEDIT_CARET_BLINK = 0.55
local MDEDIT_SELECT_PAN_MIN = 18
local MDEDIT_EDIT_SCROLL_PAN_MIN = 42
local MDEDIT_PAGE_PAN_MIN = 24   -- min vertical drag (px) that triggers a page turn
local MDEDIT_EDIT_DTAP = 0.22    -- edit-mode double-tap must be deliberate; same cursor cell prevents reposition taps selecting
local MDEDIT_EDIT_DTAP_MOVE = 18
local MDEDIT_READER_DTAP = 0.25  -- reader double-tap must land within this fast window (also the single-tap page delay)
local MDEDIT_READER_EDGE = 130   -- reader taps within this many px of the L/R/bottom edge are page-turns, never an exit
local MDEDIT_AUTOSAVE_DELAY = 1.0
local MDEDIT_FILE_RELOAD_INTERVAL = 2.0
local MDEDIT_KEYBOARD_SWIPE_EDGE = 90
local MDEDIT_KEYBOARD_SWIPE_DY = 35
local MDEdit = InputContainer:extend{ path = nil, on_close = nil, is_always_active = true }
function MDEdit:init()
    install_keyboard_aliases()
    self.fw, self.fh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.fw, h = self.fh }
    self.covers_fullscreen = true
    self.scale = clamp_minfolio_scale(MINFOLIO_STATE.scale)
    self.parent = self            -- VirtualKeyboard reads inputbox.parent
    self.keyboard = nil
    self._wcache = {}             -- measured word widths (style|scale|text -> px)
    self._hcache = {}             -- measured text heights (style|scale -> px)
    self.sel = nil                -- selection anchor {row,col} (cursor is the other end)
    self.caret_on = true
    self._caret_blinking = true
    self.reader_mode = false
    local text = read_file(self.path) or ""
    self.lines = split_text_lines(text)
    self._file_signature = file_signature(self.path)
    self._file_text = text
    self.crow, self.ccol, self.top, self.vtop = 1, 0, 1, 1
    if Device:isTouchDevice() then
        self.ges_events = {
            Tap       = { GestureRange:new{ ges = "tap",        range = self.dimen } },
            DoubleTap = { GestureRange:new{ ges = "double_tap", range = self.dimen } },
            Pan       = { GestureRange:new{ ges = "pan",        range = self.dimen } },
            Swipe     = { GestureRange:new{ ges = "swipe",      range = self.dimen } },
            Hold      = { GestureRange:new{ ges = "hold",       range = self.dimen } },
        }
        if Device.input then
            -- Disable KOReader's own double-tap so taps arrive immediately; we
            -- detect double-taps ourselves (edit: word-select, reader: exit) via
            -- timestamps, which is reliable and gives us the tap position.
            self._old_disable_double_tap = Device.input.disable_double_tap
            Device.input.disable_double_tap = true
        end
    end
    self:rebuild()
    self:scheduleCaretBlink()
    self:scheduleFilePoll()
end
-- a thin caret bar that sits between styled spans without disturbing them
function MDEdit:caret(h)
    return LineWidget:new{ background = Blitbuffer.COLOR_BLACK,
        dimen = Geom:new{ w = 3, h = h or math.floor(32 * self.scale) } }
end
function MDEdit:scheduleCaretBlink()
    UIManager:scheduleIn(MDEDIT_CARET_BLINK, function()
        if not self._caret_blinking then return end
        if self.reader_mode then
            self.caret_on = false
            self:scheduleCaretBlink()
            return
        end
        local prev_vtop = self.vtop
        local prev_caret = self.caret_region
        self.caret_on = not self.caret_on
        self:rebuild()
        local region
        if prev_vtop and self.vtop and prev_vtop ~= self.vtop then
            region = self.editor_body_region
        else
            region = self:unionRegion(prev_caret, self.caret_region)
        end
        local dirty_full = false
        if self._last_dirty_at and now_seconds() - self._last_dirty_at < MDEDIT_CARET_BLINK then
            if self._last_dirty_full then
                dirty_full = true
                region = nil
            else
                region = self:unionRegion(self._last_dirty_region, region)
            end
        end
        if dirty_full or region then UIManager:setDirty(self, "ui", region) end
        self:scheduleCaretBlink()
    end)
end
function MDEdit:textw(txt, face)        -- measured rendered width of a string
    if txt == "" then return 0 end
    local tw = TextWidget:new{ text = txt, face = face }
    local w = tw:getSize().w; tw:free(); return w
end
function MDEdit:texth(style)
    local key = style .. "|" .. self.scale
    local c = self._hcache[key]
    if c then return c end
    local tw = TextWidget:new{ text = "Hg", face = md_face(style, self.scale) }
    local h = tw:getSize().h; tw:free()
    self._hcache[key] = h; return h
end
function MDEdit:wordw(txt, style)        -- cached measured width (keyed by style + scale)
    if txt == "" then return 0 end
    local key = style .. "|" .. self.scale .. "|" .. txt
    local c = self._wcache[key]
    if c then return c end
    local w = self:textw(txt, md_face(style, self.scale))
    self._wcache[key] = w; return w
end
function MDEdit:rowTextHeight(row)
    if not row.segs or #row.segs == 0 then return self:texth("normal") end
    local h = 0
    for _, seg in ipairs(row.segs) do h = math.max(h, self:texth(seg.style)) end
    return math.max(1, h)
end
function MDEdit:rowHeight(row, block)
    local measured = self:rowTextHeight(row)
    return math.max(1, math.ceil(measured * MDEDIT_LINE_HEIGHT)) + math.max(0, math.floor(MDEDIT_LINE_GAP * self.scale))
end
function MDEdit:trimToWidth(text, maxw, face)
    if self:textw(text, face) <= maxw then return text end
    local ell = "..."
    local lo, hi, best = 0, #text, ell
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local s = text:sub(1, mid) .. ell
        if self:textw(s, face) <= maxw then best = s; lo = mid + 1 else hi = mid - 1 end
    end
    return best
end
function MDEdit:toolCell(lbl, fnt, sz, w)
    w = w or MDEDIT_TOOL_MIN_CELL
    return FrameContainer:new{ bordersize = 0, padding = 0, margin = 0,
        CenterContainer:new{ dimen = Geom:new{ w = w, h = MDEDIT_TOPBAR_H },
            TextWidget:new{ text = lbl, face = Font:getFace(fnt or "tfont", sz or 24), fgcolor = Blitbuffer.COLOR_BLACK } } }
end
function MDEdit:toolDivider()
    return CenterContainer:new{ dimen = Geom:new{ w = MDEDIT_TOOL_DIVIDER, h = MDEDIT_TOPBAR_H },
        LineWidget:new{ background = Blitbuffer.Color8(205), dimen = Geom:new{ w = MDEDIT_TOOL_DIVIDER, h = math.floor(MDEDIT_TOPBAR_H * 0.62) } } }
end
function MDEdit:progressBar(width)
    local visual_count = self.visual_count or #self.lines
    local visible = self.visible_vrows or 16
    local w = math.max(1, width or 1)
    local filled = w
    if visual_count > visible then
        local bottom = math.min(visual_count, (self.vtop or 1) + visible - 1)
        filled = math.max(1, math.min(w, math.floor(w * bottom / visual_count)))
    end
    local parts = { align = "top" }
    if filled > 0 then
        parts[#parts+1] = LineWidget:new{
            background = Blitbuffer.COLOR_BLACK,
            dimen = Geom:new{ w = filled, h = MDEDIT_PROGRESS_H },
        }
    end
    if filled < w then
        parts[#parts+1] = LineWidget:new{
            background = Blitbuffer.Color8(205),
            dimen = Geom:new{ w = w - filled, h = MDEDIT_PROGRESS_H },
        }
    end
    return HorizontalGroup:new(parts)
end
function MDEdit:menuGlyph()
    -- Same "appbar.menu" icon KOReader's own title bars use, so this matches
    -- the hamburger on the file-listing screen instead of a hand-drawn glyph.
    return CenterContainer:new{ dimen = Geom:new{ w = MDEDIT_MENU_W, h = MDEDIT_TOPBAR_H },
        IconWidget:new{ icon = "appbar.menu", width = Screen:scaleBySize(24), height = Screen:scaleBySize(24) } }
end
function MDEdit:topBar(cw)
    local title_face = Font:getFace("cfont", 22)
    local raw_title = self.path:match("[^/]+$") or "note"
    self.top_zones = {}
    if self.reader_mode then
        -- Reader mode: no formatting toolbar. A single explicit "Edit" button so
        -- the reader never has to guess the double-tap gesture.
        local edit_face = Font:getFace("tfont", 24)
        local edit_w = math.max(MDEDIT_TOOL_MIN_CELL, self:textw("Edit", edit_face) + 28)
        local max_title_w = math.max(80, cw - MDEDIT_MENU_W - edit_w - MDEDIT_TITLE_ACTION_GAP)
        local title = self:trimToWidth(raw_title, max_title_w, title_face)
        local title_w = self:textw(title, title_face)
        local gap_w = math.max(MDEDIT_TITLE_ACTION_GAP, cw - MDEDIT_MENU_W - title_w - edit_w)
        local x = MDEDIT_MENU_W
        self.top_zones.menu = { x0 = 0, x1 = MDEDIT_MENU_W }
        x = x + title_w + gap_w
        self.top_zones.edit = { x0 = x, x1 = x + edit_w }
        return HorizontalGroup:new{ align = "center",
            self:menuGlyph(),
            CenterContainer:new{ dimen = Geom:new{ w = title_w, h = MDEDIT_TOPBAR_H },
                TextWidget:new{ text = title, face = title_face, fgcolor = Blitbuffer.Color8(110) } },
            HorizontalSpan:new{ width = gap_w },
            CenterContainer:new{ dimen = Geom:new{ w = edit_w, h = MDEDIT_TOPBAR_H },
                TextWidget:new{ text = "Edit", face = edit_face, fgcolor = Blitbuffer.COLOR_BLACK } },
        }
    end
    -- Reader glyph is a rectangle split into two columns (◫, vertical bisecting
    -- line) so it reads as a two-column page rather than many thin bars.
    local tools = { "H", "B", "I", "\226\128\162", "1.", "\226\152\144", "\226\151\171" }
    local divider_w = #tools * MDEDIT_TOOL_DIVIDER
    local min_action_w = ((#tools + 1) * MDEDIT_TOOL_MIN_CELL) + divider_w
    local max_title_w = math.min(MDEDIT_TITLE_W, math.max(80, cw - MDEDIT_MENU_W - min_action_w - MDEDIT_TITLE_ACTION_GAP))
    local title = self:trimToWidth(raw_title, max_title_w, title_face)
    local title_w = self:textw(title, title_face)
    local gap_w = math.min(MDEDIT_TITLE_ACTION_GAP, math.max(0, cw - MDEDIT_MENU_W - title_w - min_action_w))
    local action_w = math.max(min_action_w, cw - MDEDIT_MENU_W - title_w - gap_w)
    local tool_cell_w = math.max(MDEDIT_TOOL_MIN_CELL, math.floor((action_w - divider_w) / (#tools + 1)))
    action_w = tool_cell_w * (#tools + 1) + divider_w
    local x = MDEDIT_MENU_W
    self.top_zones.menu = { x0 = 0, x1 = MDEDIT_MENU_W }
    local title_widget = CenterContainer:new{ dimen = Geom:new{ w = title_w, h = MDEDIT_TOPBAR_H },
        TextWidget:new{ text = title, face = title_face, fgcolor = Blitbuffer.Color8(110) } }
    x = x + title_w + gap_w
    local tool_widgets = {}
    local tool_names = { "header", "bold", "italic", "list", "ordered", "task", "reader" }
    for i, lbl in ipairs(tools) do
        if i > 1 then
            tool_widgets[#tool_widgets+1] = self:toolDivider()
            x = x + MDEDIT_TOOL_DIVIDER
        end
        self.top_zones[tool_names[i]] = { x0 = x, x1 = x + tool_cell_w }
        local glyph_tool = i == 6 or i == 7   -- checkbox + reader glyphs render from cfont
        tool_widgets[#tool_widgets+1] = self:toolCell(lbl, glyph_tool and "cfont" or "tfont", glyph_tool and 24 or 23, tool_cell_w)
        x = x + tool_cell_w
    end
    x = x + MDEDIT_TOOL_DIVIDER
    self.top_zones.close = { x0 = x, x1 = x + tool_cell_w }
    return HorizontalGroup:new{ align = "center",
        self:menuGlyph(),
        title_widget,
        HorizontalSpan:new{ width = gap_w },
        HorizontalGroup:new(tool_widgets),
        self:toolDivider(),
        self:toolCell("\226\156\149", "cfont", 30, tool_cell_w),
    }
end
function MDEdit:pointToCursor(pos)
    if not pos then return self.crow, self.ccol end
    local nearest, nearest_dist
    for _, rm in ipairs(self.row_map or {}) do
        if pos.y >= rm.y0 and pos.y < rm.y1 then
            local raw_col
            if rm.table then raw_col = self:tableColAtX(rm, pos.x - MDEDIT_PAD)
            else raw_col = self:colAtX(rm.row, pos.x - MDEDIT_PAD) end
            local col = utf8_snap(self.lines[rm.line], raw_col)
            return rm.line, col
        end
        local dist = pos.y < rm.y0 and (rm.y0 - pos.y) or (pos.y - rm.y1)
        if not nearest_dist or dist < nearest_dist then
            nearest, nearest_dist = rm, dist
        end
    end
    if nearest then
        local raw_col
        if nearest.table then raw_col = self:tableColAtX(nearest, pos.x - MDEDIT_PAD)
        else raw_col = self:colAtX(nearest.row, pos.x - MDEDIT_PAD) end
        return nearest.line, utf8_snap(self.lines[nearest.line], raw_col)
    end
    if pos.y < (self.row_map and self.row_map[1] and self.row_map[1].y0 or self.fh) then
        return self.row_map and self.row_map[1] and self.row_map[1].line or self.top, 0
    end
    local last = self.row_map and self.row_map[#self.row_map]
    if last then return last.line, #self.lines[last.line] end
    return self.crow, self.ccol
end
function MDEdit:visibleWordRange(row, col)
    local line = self.lines[row] or ""
    local toks = md_tokenize(line)[1]
    local byte, target, prev_visible = 0, nil, nil
    for _, span in ipairs(toks.spans or {}) do
        local raw = span.text or ""
        local display = span.display
        if display == nil then display = raw end
        local start_col, end_col = byte, byte + #raw
        if display ~= "" and span.style ~= "syntax" and span.style ~= "bullet" and span.style ~= "task" then
            local candidate = { start_col, end_col, raw }
            if col >= start_col and col <= end_col then
                target = candidate
                break
            elseif col < start_col then
                target = candidate
                break
            end
            prev_visible = candidate
        end
        byte = end_col
    end
    target = target or prev_visible
    if not target then return nil end
    local start_col, end_col, raw = target[1], target[2], target[3]
    local local_col = math.max(0, math.min(#raw, col - start_col))
    local lo, hi = prev_word_col(raw, local_col), next_word_col(raw, local_col)
    if lo == hi and #raw > 0 then
        if local_col <= 0 then hi = next_word_col(raw, 0)
        else lo = prev_word_col(raw, utf8_left(raw, local_col)) end
    end
    if lo == hi then return start_col, end_col end
    return start_col + lo, start_col + hi
end
function MDEdit:selectWordAt(pos)
    local row, col = self:pointToCursor(pos)
    local line = self.lines[row] or ""
    local lo, hi = self:visibleWordRange(row, col)
    if not lo then lo, hi = prev_word_col(line, col), next_word_col(line, col) end
    if lo == hi and #line > 0 then hi = utf8_right(line, lo) end
    self._desired_x = nil
    self.sel = { row = row, col = lo }
    self.crow, self.ccol = row, hi
    self:refresh{ layout_dirty = false, selection = true }
end
function MDEdit:currentWordRange()
    local line = self.lines[self.crow] or ""
    if line == "" then return nil end
    local lo, hi = prev_word_col(line, self.ccol), next_word_col(line, self.ccol)
    if lo == hi and self.ccol > 0 then lo = prev_word_col(line, utf8_left(line, self.ccol)) end
    if lo == hi and self.ccol < #line then hi = next_word_col(line, utf8_right(line, self.ccol)) end
    if lo ~= hi then return lo, hi end
    return nil
end
-- word-wrap a logical line into visual rows that fit availw; each row/seg tracks its start byte
function MDEdit:layoutLine(toks, availw)
    local rows, byte = {}, 0
    local hanging = 0
    local base_indent = 0
    if toks.block == "bullet" then
        -- Nesting depth: leading whitespace becomes real horizontal indent (the
        -- marker glyph itself carries no indent). Continuation rows hang under the
        -- text, so they start at base_indent + marker width.
        if toks.indent_ws and toks.indent_ws ~= "" then
            base_indent = self:wordw(toks.indent_ws, "bullet")
        end
        hanging = base_indent
        for _, span in ipairs(toks.spans) do
            local raw = span.text or ""
            local display = span.display
            if display == nil or display == raw then break end
            if display ~= "" then hanging = hanging + self:wordw(display, span.style) end
        end
    end
    local function newRow(indent, sb)
        indent = indent or 0
        return { segs = {}, w = indent, sb = sb or 0, indent = indent }
    end
    local row = newRow(base_indent, 0)
    for _, span in ipairs(toks.spans) do
        local raw = span.text or ""
        local display = span.display
        if display == nil then display = raw end
        if display ~= raw then
            local uw = display ~= "" and self:wordw(display, span.style) or 0
            row.segs[#row.segs+1] = { text = raw, display = display, style = span.style, w = uw, sb = byte }
            row.w = row.w + uw; byte = byte + #raw
        else
            local pos = 1
            while pos <= #raw do
                local unit = raw:match("^%s+", pos) or raw:match("^%S+", pos) or raw:sub(pos)
                local uw = self:wordw(unit, span.style)
                if not unit:match("^%s") and #row.segs > 0 and row.w + uw > availw then
                    rows[#rows+1] = row; row = newRow(hanging, byte)
                end
                row.segs[#row.segs+1] = { text = unit, display = unit, style = span.style, w = uw, sb = byte }
                row.w = row.w + uw; byte = byte + #unit; pos = pos + #unit
            end
        end
    end
    rows[#rows+1] = row
    return rows
end
-- Rendering a row shapes glyphs into TextWidgets, which hold native (malloc'ed)
-- buffers that only :free() releases promptly -- Lua's GC won't get to them in
-- time. rebuild() re-renders every visible row on every scroll/cursor-move/caret
-- blink, so without this cache we'd shape fresh glyphs (and leak the old ones)
-- many times a second. A row's identity is stable across those redraws (see the
-- wrap cache in computeVisualRows below); only its own text or a scale change
-- actually needs a re-render.
function MDEdit:renderRow(row)
    if #row.segs == 0 then return VerticalSpan:new{ width = 2 } end
    if row._rendered and row._rendered_scale == self.scale then return row._rendered end
    if row._rendered then row._rendered:free() end
    local hg = HorizontalGroup:new{ align = "top" }
    if row.indent and row.indent > 0 then hg[#hg+1] = HorizontalSpan:new{ width = row.indent } end
    for _, seg in ipairs(row.segs) do
        local display = seg.display
        if display == nil then display = seg.text end
        if display ~= "" then
            hg[#hg+1] = TextWidget:new{ text = display,
                face = md_face(seg.style, self.scale), fgcolor = md_color(seg.style) }
        end
    end
    row._rendered, row._rendered_scale = hg, self.scale
    return hg
end
-- Greedy word-wrap of a table cell into lines that each fit `maxw` px. Words
-- longer than a column are hard-broken on UTF-8 boundaries so nothing is lost.
function MDEdit:wrapCellText(text, style, maxw)
    text = tostring(text or "")
    local face = md_face(style, self.scale)
    if text == "" then return { "" } end
    if self:textw(text, face) <= maxw then return { text } end
    local lines, cur = {}, ""
    for word in text:gmatch("%S+") do
        local candidate = cur == "" and word or (cur .. " " .. word)
        if self:textw(candidate, face) <= maxw then
            cur = candidate
        else
            if cur ~= "" then lines[#lines+1] = cur; cur = "" end
            if self:textw(word, face) <= maxw then
                cur = word
            else
                local w = word                          -- hard-break an over-long word
                while w ~= "" do
                    local i, prefix = 0, ""
                    while true do
                        local nxt = utf8_right(w, i)
                        if nxt == i then break end
                        if self:textw(w:sub(1, nxt), face) <= maxw then prefix = w:sub(1, nxt); i = nxt
                        else break end
                    end
                    if prefix == "" then prefix = w:sub(1, math.max(1, utf8_right(w, 0))) end
                    lines[#lines+1] = prefix
                    w = w:sub(#prefix + 1)
                end
            end
        end
    end
    if cur ~= "" then lines[#lines+1] = cur end
    if #lines == 0 then lines[1] = "" end
    return lines
end
function MDEdit:layoutTable(tbl, availw)
    local pad_x = math.floor(MDEDIT_TABLE_PAD_X * self.scale)
    local pad_x2 = 2 * pad_x
    local minw = math.max(34, math.floor(42 * self.scale))
    -- Natural single-line width each column would like, so short columns can stay
    -- compact while long ones absorb the wrapping.
    local nat = {}
    for c = 1, tbl.ncols do nat[c] = minw end
    for _, tr in ipairs(tbl.rows) do
        local style = tr.header and "bold" or "normal"
        for c = 1, tbl.ncols do
            local cell = tr.cells[c]
            nat[c] = math.max(nat[c], self:wordw(cell and cell.text or "", style) + pad_x2)
        end
    end
    local natsum = 0
    for c = 1, tbl.ncols do natsum = natsum + nat[c] end
    local widths = {}
    if natsum <= availw then
        for c = 1, tbl.ncols do widths[c] = nat[c] end
    else
        -- Water-filling: columns narrower than an even share keep their natural
        -- width; the remaining space is split evenly among the wide columns, which
        -- then wrap. Repeats until the wide set is stable.
        local remaining, count, avail = {}, tbl.ncols, availw
        for c = 1, tbl.ncols do remaining[c] = true end
        while true do
            local share = math.floor(avail / math.max(1, count))
            local changed = false
            for c = 1, tbl.ncols do
                if remaining[c] and nat[c] <= share then
                    widths[c] = nat[c]; remaining[c] = false
                    avail = avail - nat[c]; count = count - 1; changed = true
                end
            end
            if not changed or count == 0 then break end
        end
        if count > 0 then
            local share = math.max(minw, math.floor(avail / count))
            for c = 1, tbl.ncols do if remaining[c] then widths[c] = share end end
        end
    end
    local total = 0
    for c = 1, tbl.ncols do widths[c] = math.max(minw, widths[c]); total = total + widths[c] end

    local pad_y = math.floor(MDEDIT_TABLE_PAD_Y * self.scale)
    local entries = {}
    for ri, tr in ipairs(tbl.rows) do
        local style = tr.header and "bold" or "normal"
        local lineh = self:texth(style)
        local wrapped, maxlines = {}, 1
        for c = 1, tbl.ncols do
            local cell = tr.cells[c]
            local inner = math.max(1, widths[c] - pad_x2 - 2)
            local wl = self:wrapCellText(cell and cell.text or "", style, inner)
            wrapped[c] = wl
            if #wl > maxlines then maxlines = #wl end
        end
        local rowh = math.max(24, maxlines * lineh + 2 * pad_y + 2)
        entries[#entries+1] = {
            kind = "table_row",
            line = tr.line,
            table = tbl,
            cells = tr.cells,
            header = tr.header,
            ri = ri,
            h = rowh,
            w = total,
            col_widths = widths,
            aligns = tbl.aligns,
            wrapped = wrapped,
            lineh = lineh,
        }
    end
    return entries
end
function MDEdit:tableCell(lines, colw, rowh, style, align)
    local pad_x = math.floor(MDEDIT_TABLE_PAD_X * self.scale)
    local pad_y = math.floor(MDEDIT_TABLE_PAD_Y * self.scale)
    local face = md_face(style, self.scale)
    local vg = VerticalGroup:new{ align = "left", VerticalSpan:new{ width = pad_y } }
    for _, ln in ipairs(lines or { "" }) do
        local tw = self:textw(ln, face)
        local left = pad_x
        if align == "right" then left = math.max(pad_x, colw - pad_x - tw)
        elseif align == "center" then left = math.max(pad_x, math.floor((colw - tw) / 2)) end
        vg[#vg+1] = HorizontalGroup:new{
            HorizontalSpan:new{ width = left },
            TextWidget:new{ text = ln, face = face, fgcolor = Blitbuffer.COLOR_BLACK },
        }
    end
    return FrameContainer:new{ bordersize = 1, padding = 0, margin = 0, width = colw, height = rowh, vg }
end
function MDEdit:renderTableRow(vr)
    local style = vr.header and "bold" or "normal"
    local hg = HorizontalGroup:new{ align = "top" }
    for c = 1, #vr.col_widths do
        hg[#hg+1] = self:tableCell(vr.wrapped and vr.wrapped[c], vr.col_widths[c], vr.h, style, vr.aligns[c])
    end
    return hg
end
function MDEdit:tableColAtX(rm, x)
    if x < 0 then
        local first = rm.cells and rm.cells[1]
        return first and (first.start_col or 0) or 0
    end
    local hit = self:tableCellAtX(rm, x)
    if hit then
        local cell, w = hit.cell, hit.width
        local pad_x = math.floor(MDEDIT_TABLE_PAD_X * self.scale)
        local inner_x = math.max(0, math.min(w - (2 * pad_x), hit.inner_x))
        local span = math.max(0, (cell.end_col or 0) - (cell.start_col or 0))
        if span <= 0 then return cell.start_col or 0 end
        return math.floor((cell.start_col or 0) + (span * inner_x / math.max(1, w - (2 * pad_x))))
    end
    local last = rm.cells and rm.cells[#rm.cells]
    return last and (last.end_col or last.start_col or 0) or 0
end
function MDEdit:tableCellAtX(rm, x)
    if x < 0 then return nil end
    local acc = 0
    local widths = rm.col_widths or {}
    for c = 1, #widths do
        local w = widths[c]
        if x < acc + w then
            local cell = rm.cells and rm.cells[c]
            if not cell then return nil end
            local pad_x = math.floor(MDEDIT_TABLE_PAD_X * self.scale)
            return {
                line = rm.line,
                col = c,
                cell = cell,
                x0 = acc,
                x1 = acc + w,
                width = w,
                inner_x = x - acc - pad_x,
            }
        end
        acc = acc + w
    end
    return nil
end
function MDEdit:tableCellAtPos(pos)
    if not pos then return nil end
    for _, rm in ipairs(self.row_map or {}) do
        if rm.table and pos.y >= rm.y0 and pos.y < rm.y1 then
            return self:tableCellAtX(rm, pos.x - MDEDIT_PAD)
        end
    end
    return nil
end
function MDEdit:replaceTableCell(hit, value)
    if not hit or not hit.line or not hit.cell then return false end
    local line = self.lines[hit.line]
    if not line then return false end
    local cell = hit.cell
    local clean = tostring(value or ""):gsub("[\r\n]+", " "):gsub("|", "/")
    local before = line:sub(1, cell.start_col)
    local after = line:sub((cell.end_col or cell.start_col) + 1)
    self.lines[hit.line] = before .. clean .. after
    self.crow = hit.line
    self.ccol = #before + #clean
    self._vrows_dirty = true
    return true
end
function MDEdit:openTableCellEditor(hit)
    if not hit or not hit.cell then return false end
    if self._page_pending then UIManager:unschedule(self._page_pending); self._page_pending = nil end
    self._rtap = nil
    local dlg
    dlg = InputDialog:new{
        title = string.format(_("Table cell %d"), hit.col or 1),
        input = hit.cell.text or "",
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dlg) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local value = dlg:getInputText() or ""
                UIManager:close(dlg)
                self:snapshot()
                self._burst = nil
                if self:replaceTableCell(hit, value) then
                    self:save()
                    self:refresh()
                end
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
    return true
end
function MDEdit:cursorInRows(rows)       -- (visual row index, x within row) for the cursor
    for ri = #rows, 1, -1 do
        if self.ccol >= rows[ri].sb then
            return ri, self:rowXAt(rows[ri], self.ccol)
        end
    end
    return 1, 0
end
function MDEdit:colAtX(row, x)           -- byte column nearest x within a visual row (for tap-to-place)
    local b, accx = row.sb, row.indent or 0
    if x < accx then return b end
    for _, seg in ipairs(row.segs) do
        if x < accx + seg.w then
            local display = seg.display
            if display == nil then display = seg.text end
            if display ~= seg.text then
                return b + ((x - accx) < (seg.w / 2) and 0 or #seg.text)
            end
            local prev = 0
            for ci = 1, #seg.text do
                local w = self:wordw(seg.text:sub(1, ci), seg.style)
                if accx + w >= x then
                    if (x - accx - prev) < (accx + w - x) then return b + ci - 1 else return b + ci end
                end
                prev = w
            end
            return b + #seg.text
        end
        accx = accx + seg.w; b = b + #seg.text
    end
    return b
end
-- Tokenize + word-wrap the whole document into visual rows. This is the
-- expensive step (md_tokenize + font-width measurement per line), so its
-- result is cached (see :visualRows) and only recomputed when the text or the
-- available width changes -- never on a plain scroll.
-- Releases the native TextWidget buffers (see renderRow) cached on a wrap-cache
-- entry's rows. Call this only for entries that are actually being dropped.
local function free_wrap_entry(entry)
    for _, row in ipairs(entry.rows) do
        if row._rendered then row._rendered:free(); row._rendered = nil end
    end
end
function MDEdit:computeVisualRows(text_w)
    -- Per-logical-line wrap cache keyed by the line's exact text. Editing one
    -- line is a single cache miss (the tokenize + word-wrap for that line);
    -- every other line is reused untouched, so a keystroke re-wraps one line
    -- instead of the whole document. The cache is rebuilt from the live lines
    -- each pass, so it can never grow past the current document.
    local prev = (self._wrap_cache_w == text_w) and self._wrap_cache or nil
    local old_cache = self._wrap_cache
    local cache, out = {}, {}
    local function appendLine(i)
        local text = self.lines[i]
        local entry = cache[text] or (prev and prev[text])
        if not entry then
            local toks = md_tokenize(text)[1]
            entry = { rows = self:layoutLine(toks, text_w), block = toks.block }
        end
        cache[text] = entry
        for ri, row in ipairs(entry.rows) do
            out[#out+1] = { kind = "row", line = i, row = row, block = entry.block, ri = ri }
        end
        if i < #self.lines then
            out[#out+1] = { kind = "gap", line = i, h = MDEDIT_PARA_GAP }
        end
    end
    local i = 1
    while i <= #self.lines do
        if self.reader_mode then
            local tbl = md_table_block(self.lines, i)
            if tbl then
                for _, entry in ipairs(self:layoutTable(tbl, text_w)) do
                    out[#out+1] = entry
                end
                if tbl.finish < #self.lines then
                    out[#out+1] = { kind = "gap", line = tbl.finish, h = MDEDIT_PARA_GAP }
                end
                i = tbl.finish + 1
            else
                appendLine(i)
                i = i + 1
            end
        else
            appendLine(i)
            i = i + 1
        end
    end
    if old_cache then
        for text, entry in pairs(old_cache) do
            if cache[text] ~= entry then free_wrap_entry(entry) end
        end
    end
    self._wrap_cache, self._wrap_cache_w = cache, text_w
    if #out == 0 then out[1] = { kind = "row", line = 1, row = { segs = {}, w = 0, sb = 0 }, block = "normal", ri = 1 } end
    return out
end
-- Cached accessor: recompute only when the content is marked dirty (any edit
-- calls :refresh, which sets _vrows_dirty) or the text width changed (rotation).
function MDEdit:visualRows(text_w)
    if self._vrows and self._vrows_w == text_w and not self._vrows_dirty then
        return self._vrows
    end
    self._vrows = self:computeVisualRows(text_w)
    self._vrows_w = text_w
    self._vrows_dirty = false
    return self._vrows
end
-- Locate the caret within the cached rows. Cheap: only scans row metadata and
-- measures within the single logical line that holds the cursor.
function MDEdit:cursorVisual(vrows)
    local crow_rows, map = {}, {}
    for vi = 1, #vrows do
        local vr = vrows[vi]
        if vr.kind == "row" and vr.line == self.crow then
            crow_rows[#crow_rows+1] = vr.row
            map[#crow_rows] = vi
        end
    end
    if #crow_rows == 0 then return nil, nil end
    local cri, cx = self:cursorInRows(crow_rows)
    return map[cri], cx
end
function MDEdit:textWidth()
    return self.fw - (MDEDIT_PAD * 2)
end
function MDEdit:moveCursorVisual(drow)
    local vrows = self:visualRows(self:textWidth())
    local vi, cx = self:cursorVisual(vrows)
    if not vi then return false end
    local target_x = self._desired_x or cx or 0
    local text_rows, current_idx = {}, nil
    for i, vr in ipairs(vrows) do
        if vr.kind == "row" then
            text_rows[#text_rows+1] = { vi = i, vr = vr }
            if i == vi then current_idx = #text_rows end
        end
    end
    if not current_idx then return false end
    local target = text_rows[current_idx + (drow < 0 and -1 or 1)]
    local vr = target and target.vr
    if not vr or vr.kind ~= "row" then return true end
    self._desired_x = target_x
    self.crow = vr.line
    self.ccol = utf8_snap(self.lines[self.crow], self:colAtX(vr.row, target_x))
    return true
end
function MDEdit:visualRowHeight(vr)
    if vr.kind == "gap" then return vr.h or 0 end
    if vr.kind == "table_row" then return vr.h or 0 end
    return self:rowHeight(vr.row, vr.block)
end
function MDEdit:rebuild()
    local cw = self.fw - (MDEDIT_PAD * 2)
    local text_w = self:textWidth()
    local topbar = self:topBar(cw)
    local vg = VerticalGroup:new{ align = "left", topbar, VerticalSpan:new{ width = MDEDIT_TOPBAR_GAP } }
    local kbd_h = 0
    if self.keyboard then
        kbd_h = self.keyboard.dimen and self.keyboard.dimen.h or math.floor(self.fh * 0.36)
    end
    local editor_top = MDEDIT_PAD + MDEDIT_TOPBAR_H + MDEDIT_TOPBAR_GAP
    local progress_area = MDEDIT_PROGRESS_GAP + MDEDIT_PROGRESS_H
    local budget = self.fh - editor_top - MDEDIT_PAD - kbd_h - progress_area
    self.visible_budget = budget
    local body = VerticalGroup:new{ align = "left" }
    local visual_rows = self:visualRows(text_w)
    self.visual_count = #visual_rows
    self.vtop = math.max(1, math.min(self.visual_count, self.vtop or 1))
    local cursor_vi, cursor_cx
    if not self.reader_mode then cursor_vi, cursor_cx = self:cursorVisual(visual_rows) end
    local manual_scroll = self._manual_scroll_cursor
        and self._manual_scroll_cursor.row == self.crow
        and self._manual_scroll_cursor.col == self.ccol
    if self._manual_scroll_cursor and not manual_scroll then self._manual_scroll_cursor = nil end
    if not self.reader_mode and cursor_vi and not manual_scroll then
        if cursor_vi < self.vtop then self.vtop = cursor_vi end
        local used_to_cursor = 0
        for vi = self.vtop, cursor_vi do
            used_to_cursor = used_to_cursor + self:visualRowHeight(visual_rows[vi])
        end
        while self.vtop < cursor_vi and used_to_cursor > budget do
            used_to_cursor = used_to_cursor - self:visualRowHeight(visual_rows[self.vtop])
            self.vtop = self.vtop + 1
        end
    end
    self.row_map = {}
    self.caret_region = nil
    local ytop, used, shown = editor_top, 0, 0
    for vi = self.vtop, #visual_rows do
        local vr = visual_rows[vi]
        if vr.kind == "gap" then
            if used + vr.h > budget then break end
            body[#body+1] = VerticalSpan:new{ width = vr.h }
            used = used + vr.h
            shown = shown + 1
        elseif vr.kind == "table_row" then
            local rowh = vr.h
            if used + rowh > budget then break end
            body[#body+1] = self:renderTableRow(vr)
            self.row_map[#self.row_map+1] = {
                y0 = ytop + used,
                y1 = ytop + used + rowh,
                line = vr.line,
                table = vr.table,
                cells = vr.cells,
                col_widths = vr.col_widths,
            }
            used = used + rowh
            shown = shown + 1
        else
            local i, row = vr.line, vr.row
            local texth = self:rowTextHeight(row)
            local rowh = self:rowHeight(row, vr.block)
            local text_y = math.max(0, math.floor((rowh - texth) / 2))
            if used + rowh > budget then break end
            local slo, shi = self:lineSel(i)
            local args = { dimen = Geom:new{ w = text_w, h = rowh } }
            if slo and not self.reader_mode then          -- selection highlight, drawn behind the text
                local rb = row.sb
                for _, sg in ipairs(row.segs) do rb = rb + #sg.text end
                local a, b = math.max(slo, row.sb), math.min(shi, rb)
                if a < b then
                    local x0, x1 = self:rowXAt(row, a), self:rowXAt(row, b)
                    args[#args+1] = HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = x0 },
                        LineWidget:new{ background = Blitbuffer.Color8(205), dimen = Geom:new{ w = math.max(2, x1 - x0), h = rowh } } }
                end
            end
            args[#args+1] = VerticalGroup:new{ VerticalSpan:new{ width = text_y }, self:renderRow(row) }
            if vi == cursor_vi and cursor_cx and not self.reader_mode then
                local caret_h = math.max(18, math.min(rowh - 2, texth))
                local caret_y = math.max(0, text_y + math.floor((texth - caret_h) / 2))
                if self.caret_on then
                    args[#args+1] = VerticalGroup:new{
                        VerticalSpan:new{ width = caret_y },
                        HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = cursor_cx }, self:caret(caret_h) },
                    }
                end
                self.caret_region = Geom:new{
                    x = MDEDIT_PAD + cursor_cx - 2, y = ytop + used + caret_y, w = 7, h = caret_h,
                }
            end
            body[#body+1] = OverlapGroup:new(args)
            self.row_map[#self.row_map+1] = { y0 = ytop + used, y1 = ytop + used + rowh, line = i, row = row }
            used = used + rowh
            shown = shown + 1
        end
    end
    self.visible_vrows = math.max(1, shown)   -- visual entries (rows+gaps) on screen
    self.top = self.row_map[1] and self.row_map[1].line or 1
    vg[#vg+1] = body
    self.editor_refresh_region = Geom:new{
        x = 0, y = 0, w = self.fw,
        h = math.max(1, editor_top + budget + progress_area + MDEDIT_PAD),
    }
    -- Same as editor_refresh_region but starting below the top bar. The toolbar/
    -- title never change while scrolling, selecting, or reflowing text, so those
    -- repaints should leave it untouched (no e-ink flash of a stable strip).
    self.editor_body_region = Geom:new{
        x = 0, y = editor_top, w = self.fw,
        h = math.max(1, budget + progress_area + MDEDIT_PAD),
    }
    -- The progress bar is pinned to the very bottom of the screen (below the text
    -- frame's padding) so it holds a fixed position regardless of how much text is
    -- on screen, and never crowds the last line.
    self[1] = OverlapGroup:new{
        dimen = Geom:new{ x = 0, y = 0, w = self.fw, h = self.fh },
        FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = MDEDIT_PAD,
            width = self.fw, height = self.fh, vg },
        BottomContainer:new{ dimen = Geom:new{ w = self.fw, h = self.fh - 5 }, self:progressBar(cw) },
    }
end
-- Bounding bands (full width) of logical-line rows, for narrow e-ink refreshes
-- while typing.
function MDEdit:lineBand(row)
    local y0, y1
    for _, rm in ipairs(self.row_map or {}) do
        if rm.line == row then
            y0 = math.min(y0 or rm.y0, rm.y0)
            y1 = math.max(y1 or rm.y1, rm.y1)
        end
    end
    if not y0 then return nil end
    return Geom:new{ x = 0, y = math.max(0, y0 - 2), w = self.fw, h = (y1 - y0) + 4 }
end
function MDEdit:lineTailBand(row, col)
    local y0, y1
    for _, rm in ipairs(self.row_map or {}) do
        if rm.line == row then
            local include = true
            if rm.row then
                local rb = rm.row.sb or 0
                for _, sg in ipairs(rm.row.segs or {}) do rb = rb + #(sg.text or "") end
                include = col == nil or col <= rb
            end
            if include then
                y0 = math.min(y0 or rm.y0, rm.y0)
                y1 = math.max(y1 or rm.y1, rm.y1)
            end
        end
    end
    if not y0 then return self:lineBand(row) end
    return Geom:new{ x = 0, y = math.max(0, y0 - 2), w = self.fw, h = (y1 - y0) + 4 }
end
function MDEdit:lineTailRegions(row_map, row, col)
    local regions, first = {}, true
    for _, rm in ipairs(row_map or {}) do
        if rm.line == row and rm.row then
            local rb = rm.row.sb or 0
            for _, sg in ipairs(rm.row.segs or {}) do rb = rb + #(sg.text or "") end
            if col == nil or col <= rb then
                local x = 0
                if first then
                    x = math.max(0, MDEDIT_PAD + self:rowXAt(rm.row, math.max(col or 0, rm.row.sb or 0)) - 2)
                    first = false
                end
                regions[#regions+1] = Geom:new{
                    x = x,
                    y = math.max(0, rm.y0 - 2),
                    w = math.max(1, self.fw - x),
                    h = (rm.y1 - rm.y0) + 4,
                }
            end
        end
    end
    return #regions > 0 and regions or nil
end
function MDEdit:addRegions(dst, src)
    if not src then return dst end
    dst = dst or {}
    for _, region in ipairs(src) do dst[#dst+1] = region end
    return dst
end
-- The slice from the top of a logical line down to the bottom of the editor.
-- After a reflow (wrap/newline/join) or a line-height change, only this line and
-- everything below it moved; the top bar and lines above are untouched, so this
-- avoids repainting (and flashing) the whole page.
function MDEdit:regionFromLineToBottom(row)
    local band = self:lineBand(row)
    if not band then return nil end
    local bottom = self.editor_refresh_region.y + self.editor_refresh_region.h
    return Geom:new{ x = 0, y = band.y, w = self.fw, h = math.max(1, bottom - band.y) }
end
function MDEdit:unionRegion(a, b)
    if not a then return b end
    if not b then return a end
    local x0 = math.min(a.x, b.x)
    local y0 = math.min(a.y, b.y)
    local x1 = math.max(a.x + a.w, b.x + b.w)
    local y1 = math.max(a.y + a.h, b.y + b.h)
    return Geom:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end
function MDEdit:selectionIsMultiline()
    local lr, _, hr = self:selRange()
    return lr ~= nil and hr ~= nil and lr ~= hr
end
function MDEdit:refresh(opts)
    opts = opts or {}
    if opts.layout_dirty ~= false then
        self._vrows_dirty = true          -- content may have changed; rebuild the layout cache
    end
    self.caret_on = true
    local prev_count = self.visual_count
    local prev_vtop = self.vtop
    local prev_crow = self._render_crow or self.crow
    local prev_ccol = self._render_ccol or self.ccol
    local prev_band = self:lineBand(self.crow)
    local prev_caret = self.caret_region
    local prev_row_map = self.row_map
    local prev_sel_multiline = self._render_sel_multiline
    self:rebuild()
    local region = self.keyboard and self.editor_refresh_region or nil
    local regions
    local vtop_changed = prev_vtop and self.vtop and prev_vtop ~= self.vtop
    local selection_dirty = opts.selection or prev_sel_multiline or self:selectionIsMultiline()
    local band = self:lineBand(self.crow)
    local line_geometry_changed = prev_band and band
        and (prev_band.y ~= band.y or prev_band.h ~= band.h)
    -- If the wrapped-row count is unchanged, the edit stayed within one logical
    -- line and nothing below it moved -- refresh only the affected tail of that
    -- line. A reflow (wrap change, newline, line join) or a line-height change
    -- shifts the edited line and everything below it, but leaves the top bar and
    -- the lines above untouched -- repaint only that lower slice.
    -- With the on-screen keyboard visible, keep refreshing the whole editor band;
    -- partial editor redraws above a live keyboard leave mixed e-ink regions.
    local reflow = prev_count and self.visual_count ~= prev_count
    if opts.full then
        region = self.editor_refresh_region
    elseif selection_dirty or vtop_changed then
        region = self.editor_body_region
    elseif reflow or line_geometry_changed then
        if self.keyboard then
            region = self.editor_refresh_region
        else
            region = self:regionFromLineToBottom(math.min(prev_crow or self.crow, self.crow))
                or self.editor_refresh_region
        end
    elseif prev_count and self.visual_count == prev_count then
        if opts.cursor_move then
            if prev_caret and self.caret_region then
                regions = { prev_caret, self.caret_region }
                band = nil
            elseif prev_caret or self.caret_region then
                band = prev_caret or self.caret_region
            elseif prev_crow and prev_crow ~= self.crow then
                band = self:unionRegion(self:lineBand(prev_crow), band)
            end
        elseif opts.precise_edit then
            regions = self:addRegions(regions, self:lineTailRegions(prev_row_map, prev_crow, prev_ccol))
            regions = self:addRegions(regions, self:lineTailRegions(self.row_map, self.crow, self.ccol))
            if regions then
                band = nil
            else
                band = self:lineTailBand(self.crow, self.ccol)
            end
        else
            band = self:lineTailBand(self.crow, self.ccol)
            if prev_crow and prev_crow ~= self.crow then
                band = self:unionRegion(self:lineTailBand(prev_crow, prev_ccol), band)
            elseif prev_ccol and prev_ccol ~= self.ccol then
                band = self:unionRegion(self:lineTailBand(self.crow, prev_ccol), band)
            end
        end
        if band then region = band end
    end
    self._render_crow = self.crow
    self._render_ccol = self.ccol
    self._render_sel_multiline = self:selectionIsMultiline()
    self._last_dirty_at = now_seconds()
    self._last_dirty_region = regions and self.caret_region or region
    self._last_dirty_full = not regions and region == nil
    if regions then
        for _, dirty_region in ipairs(regions) do
            UIManager:setDirty(self, "ui", dirty_region)
        end
    else
        UIManager:setDirty(self, "ui", region)
    end
end
-- Scroll-only repaint: vtop moved but the text is unchanged, so reuse the
-- cached visual rows instead of re-tokenizing the whole document.
function MDEdit:refreshScroll()
    self.caret_on = true
    self:rebuild()
    UIManager:setDirty(self, "ui", self.editor_body_region)
end
function MDEdit:scheduleAutosave()
    self._dirty = true
    if self._autosave_paused_for_external then return end
    if self._autosave_pending then UIManager:unschedule(self._autosave_pending); self._autosave_pending = nil end
    local fn
    fn = function()
        if self._autosave_pending == fn then self._autosave_pending = nil end
        if self._dirty and not self._autosave_paused_for_external then self:save() end
    end
    self._autosave_pending = fn
    UIManager:scheduleIn(MDEDIT_AUTOSAVE_DELAY, fn)
end
function MDEdit:flushAutosave()
    if self._autosave_pending then UIManager:unschedule(self._autosave_pending); self._autosave_pending = nil end
    if self._autosave_paused_for_external then return end
    if self._dirty then self:save() end
end
function MDEdit:currentText()
    return table.concat(self.lines, "\n")
end
function MDEdit:reloadFromDisk(text, sig)
    if text == nil then text = read_file(self.path) end
    if text == nil then return false end
    self.lines = split_text_lines(text)
    self.crow = math.max(1, math.min(self.crow or 1, #self.lines))
    self.ccol = math.max(0, math.min(self.ccol or 0, #(self.lines[self.crow] or "")))
    self.sel = nil
    self._desired_x = nil
    self._burst = nil
    self._undo, self._redo = {}, {}
    self._dirty = false
    self._file_text = text
    self._file_signature = sig or file_signature(self.path)
    self._external_change_prompted = nil
    self._autosave_paused_for_external = nil
    if self._autosave_pending then UIManager:unschedule(self._autosave_pending); self._autosave_pending = nil end
    self:refresh{ layout_dirty = true, full = true }
    notify(_("Reloaded from disk"))
    return true
end
function MDEdit:promptExternalReload(text, sig)
    if self._external_change_prompted then return end
    self._external_change_prompted = true
    self._autosave_paused_for_external = true
    if self._autosave_pending then UIManager:unschedule(self._autosave_pending); self._autosave_pending = nil end
    UIManager:show(ConfirmBox:new{
        text = _("File changed on disk. Reload and discard unsaved edits?\nAutosave is paused until you reload or save."),
        ok_text = _("Reload"),
        ok_callback = function() self:reloadFromDisk(text, sig) end,
    })
end
function MDEdit:checkExternalFile()
    local sig = file_signature(self.path)
    if same_file_signature(sig, self._file_signature) then return end
    local text = read_file(self.path)
    if text == nil then
        if not self._external_missing_notified then
            self._external_missing_notified = true
            notify(_("File is unavailable on disk"))
        end
        return
    end
    self._external_missing_notified = nil
    if text == self:currentText() then
        self._file_text = text
        self._file_signature = sig
        self._dirty = false
        self._autosave_paused_for_external = nil
        return
    end
    if self._dirty then
        self:promptExternalReload(text, sig)
    else
        self:reloadFromDisk(text, sig)
    end
end
function MDEdit:scheduleFilePoll()
    if self._file_poll_pending then UIManager:unschedule(self._file_poll_pending); self._file_poll_pending = nil end
    local fn
    fn = function()
        if self._file_poll_pending == fn then self._file_poll_pending = nil end
        if self._closing then return end
        self:checkExternalFile()
        self:scheduleFilePoll()
    end
    self._file_poll_pending = fn
    UIManager:scheduleIn(MDEDIT_FILE_RELOAD_INTERVAL, fn)
end
function MDEdit:snapshot()
    self:scheduleAutosave()
    self._undo = self._undo or {}
    self._undo[#self._undo+1] = { lines = copy_arr(self.lines), crow = self.crow, ccol = self.ccol }
    if #self._undo > 80 then table.remove(self._undo, 1) end
    self._redo = {}
end
function MDEdit:edit(tag)             -- snapshot once per edit "burst" (typing vs deleting)
    if self._burst ~= tag then self:snapshot() end
    self._burst = tag
end
function MDEdit:_restore(stack, other)
    if not (stack and #stack > 0) then return end
    other[#other+1] = { lines = copy_arr(self.lines), crow = self.crow, ccol = self.ccol }
    local s = table.remove(stack)
    self.lines, self.crow, self.ccol, self._burst = s.lines, s.crow, s.ccol, nil
    self._desired_x = nil
    self:scheduleAutosave()
    self:refresh()
end
function MDEdit:undo() self._redo = self._redo or {}; self:_restore(self._undo, self._redo) end
function MDEdit:redo() self._undo = self._undo or {}; self:_restore(self._redo, self._undo) end
-- ---- selection + clipboard (anchor in self.sel, cursor at crow/ccol) ----
function MDEdit:selRange()
    if not self.sel then return nil end
    local ar, ac, br, bc = self.sel.row, self.sel.col, self.crow, self.ccol
    if ar < br or (ar == br and ac <= bc) then return ar, ac, br, bc else return br, bc, ar, ac end
end
function MDEdit:hasSel()
    local lr, lc, hr, hc = self:selRange()
    return lr ~= nil and not (lr == hr and lc == hc)
end
function MDEdit:lineSel(i)            -- selected byte range [lo,hi] within line i, or nil
    local lr, lc, hr, hc = self:selRange()
    if not lr or i < lr or i > hr then return nil end
    if lr == hr then if lc == hc then return nil end; return lc, hc end
    if i == lr then return lc, #self.lines[i]
    elseif i == hr then return 0, hc
    else return 0, #self.lines[i] end
end
function MDEdit:selText()
    local lr, lc, hr, hc = self:selRange()
    if not lr then return "" end
    if lr == hr then return self.lines[lr]:sub(lc+1, hc) end
    local parts = { self.lines[lr]:sub(lc+1) }
    for k = lr+1, hr-1 do parts[#parts+1] = self.lines[k] end
    parts[#parts+1] = self.lines[hr]:sub(1, hc)
    return table.concat(parts, "\n")
end
function MDEdit:deleteSelection()
    local lr, lc, hr, hc = self:selRange()
    if not lr then return false end
    self._desired_x = nil
    if lr == hr then
        self.lines[lr] = self.lines[lr]:sub(1, lc) .. self.lines[lr]:sub(hc+1)
    else
        self.lines[lr] = self.lines[lr]:sub(1, lc) .. self.lines[hr]:sub(hc+1)
        for k = hr, lr+1, -1 do table.remove(self.lines, k) end
    end
    self.crow, self.ccol, self.sel = lr, lc, nil
    return true
end
function MDEdit:copy() if self:hasSel() then md_clipboard = self:selText() end end
function MDEdit:cut()
    if not self:hasSel() then return end
    md_clipboard = self:selText(); self:snapshot(); self._burst = nil
    self._desired_x = nil
    self:deleteSelection(); self:refresh()
end
function MDEdit:paste()
    if not md_clipboard or md_clipboard == "" then return end
    self:snapshot(); self._burst = nil
    self._desired_x = nil
    if self:hasSel() then self:deleteSelection() end
    local cl = {}
    for line in (md_clipboard .. "\n"):gmatch("(.-)\n") do cl[#cl+1] = line end
    local l = self.lines[self.crow]
    if #cl <= 1 then
        local one = cl[1] or ""
        self.lines[self.crow] = l:sub(1, self.ccol) .. one .. l:sub(self.ccol+1)
        self.ccol = self.ccol + #one
    else
        local tail = l:sub(self.ccol+1)
        self.lines[self.crow] = l:sub(1, self.ccol) .. cl[1]
        for k = 2, #cl do table.insert(self.lines, self.crow + k - 1, cl[k]) end
        self.crow = self.crow + #cl - 1
        self.ccol = #cl[#cl]
        self.lines[self.crow] = self.lines[self.crow] .. tail
    end
    self:refresh()
end
function MDEdit:selectAll()
    self._desired_x = nil
    self.sel = { row = 1, col = 0 }
    self.crow = #self.lines; self.ccol = #self.lines[#self.lines]
    self:refresh{ layout_dirty = false, selection = true, full = true }
end
function MDEdit:rowXAt(row, p)        -- x of absolute byte col p within a visual row
    local b, x = row.sb, row.indent or 0
    for _, seg in ipairs(row.segs) do
        if p <= b + #seg.text then
            local display = seg.display
            if display == nil then display = seg.text end
            if display == "" then return x end
            if display ~= seg.text then
                local raw_len = math.max(1, #seg.text)
                return x + math.floor(seg.w * math.max(0, p - b) / raw_len)
            end
            return x + self:wordw(seg.text:sub(1, p - b), seg.style)
        end
        x = x + seg.w; b = b + #seg.text
    end
    return x
end
function MDEdit:arrow(drow, dcol, m)  -- arrow key with optional Shift (select) / Alt-or-Command (word)
    local selecting = keymod(m, "Shift")
    if selecting then if not self.sel then self.sel = { row = self.crow, col = self.ccol } end
    else self.sel = nil end
    if word_key_mod(m) and dcol ~= 0 then if dcol < 0 then self:wordLeft(selecting) else self:wordRight(selecting) end
    else self:moveCursor(drow, dcol, { selection = selecting }) end
end
local md_split_line_prefix
function MDEdit:addChars(s)
    if s == "\n" then return self:newline() end
    self._desired_x = nil
    local had_sel = self:hasSel()
    if had_sel then self:snapshot(); self._burst = nil; self:deleteSelection() else self:edit("type") end
    local l = self.lines[self.crow]
    if s == " " and self.ccol >= 1 and l:sub(self.ccol, self.ccol) == " "
       and (self.ccol < 2 or l:sub(self.ccol-1, self.ccol-1) ~= " ") then  -- double space -> ". "
        self.lines[self.crow] = l:sub(1, self.ccol-1) .. ". " .. l:sub(self.ccol+1)
        self.ccol = self.ccol + 1
        return self:refresh()
    end
    self.lines[self.crow] = l:sub(1, self.ccol) .. s .. l:sub(self.ccol+1)
    self.ccol = self.ccol + #s
    self:refresh{ precise_edit = not had_sel }
end
function MDEdit:newline()
    self:snapshot(); self._burst = nil
    self._desired_x = nil
    if self:hasSel() then self:deleteSelection() end
    local l = self.lines[self.crow]
    local before, after = l:sub(1, self.ccol), l:sub(self.ccol+1)
    local prefix = ""
    if md_split_line_prefix then
        local indent, kind, marker, task, body = md_split_line_prefix(before)
        if (kind or task) and body == "" and after == "" then
            self.lines[self.crow] = indent
            self.ccol = #indent
            return self:refresh()
        end
        if kind == "ordered" then
            local n = tonumber((marker or ""):match("^(%d+)")) or 1
            prefix = indent .. tostring(n + 1) .. ". "
        elseif kind == "bullet" then
            prefix = indent .. (marker or "- ")
        elseif task then
            prefix = indent
        end
        if task then prefix = prefix .. "[ ] " end
    end
    table.insert(self.lines, self.crow+1, prefix .. after)
    self.lines[self.crow] = before
    self.crow = self.crow + 1; self.ccol = #prefix
    self:refresh()
end
function MDEdit:delChar()
    self._desired_x = nil
    if self:hasSel() then self:snapshot(); self._burst = nil; self:deleteSelection(); return self:refresh() end
    self:edit("del")
    if self.ccol > 0 then
        local l = self.lines[self.crow]
        local prev = utf8_left(l, self.ccol)          -- delete the whole UTF-8 char to the left
        self.lines[self.crow] = l:sub(1, prev) .. l:sub(self.ccol+1)
        self.ccol = prev
        return self:refresh{ precise_edit = true }
    elseif self.crow > 1 then
        local prev = self.lines[self.crow-1]
        self.ccol = #prev
        self.lines[self.crow-1] = prev .. self.lines[self.crow]
        table.remove(self.lines, self.crow); self.crow = self.crow - 1
    end
    self:refresh()
end
function MDEdit:moveCursor(drow, dcol, opts)
    self._burst = nil
    if dcol ~= 0 then self._desired_x = nil end
    if dcol < 0 then
        if self.ccol <= 0 then
            if self.crow > 1 then self.crow = self.crow - 1; self.ccol = #self.lines[self.crow] end
        else self.ccol = utf8_left(self.lines[self.crow], self.ccol) end
    elseif dcol > 0 then
        if self.ccol >= #self.lines[self.crow] then
            if self.crow < #self.lines then self.crow = self.crow + 1; self.ccol = 0 end
        else self.ccol = utf8_right(self.lines[self.crow], self.ccol) end
    end
    if drow ~= 0 then
        if not self:moveCursorVisual(drow) then
            self.crow = math.max(1, math.min(#self.lines, self.crow + drow))
            self.ccol = math.min(self.ccol, #self.lines[self.crow])
        end
    end
    opts = opts or {}
    opts.layout_dirty = false
    opts.cursor_move = true
    self:refresh(opts)
end
-- VirtualKeyboard inputbox interface
function MDEdit:leftChar()  self.sel = nil; self:moveCursor(0, -1) end
function MDEdit:rightChar() self.sel = nil; self:moveCursor(0, 1) end
function MDEdit:upLine()    self.sel = nil; self:moveCursor(-1, 0) end
function MDEdit:downLine()  self.sel = nil; self:moveCursor(1, 0) end
function MDEdit:goToStartOfLine() self._desired_x = nil; self.ccol = 0; self:refresh{ layout_dirty = false, cursor_move = true } end
function MDEdit:goToEndOfLine()   self._desired_x = nil; self.ccol = #self.lines[self.crow]; self:refresh{ layout_dirty = false, cursor_move = true } end
function MDEdit:delToStartOfLine()
    self:snapshot(); self._burst = nil
    self._desired_x = nil
    local l = self.lines[self.crow]; self.lines[self.crow] = l:sub(self.ccol+1); self.ccol = 0; self:refresh()
end
function MDEdit:delWord()
    self._desired_x = nil
    if self:hasSel() then self:snapshot(); self._burst = nil; self:deleteSelection(); return self:refresh() end
    -- At the start of a line there is no word to delete on this line; fall back to
    -- delChar so a word-delete still joins with the previous line (matches every
    -- editor, and is the path the Bluetooth keyboard's backspace takes).
    if self.ccol <= 0 then return self:delChar() end
    self:snapshot(); self._burst = nil
    local l = self.lines[self.crow]
    local before = l:sub(1, prev_word_col(l, self.ccol))
    self.lines[self.crow] = before .. l:sub(self.ccol+1); self.ccol = #before; self:refresh{ precise_edit = true }
end
function MDEdit:wordLeft(selecting)
    self._burst = nil
    self._desired_x = nil
    self.ccol = prev_word_col(self.lines[self.crow], self.ccol); self:refresh{ layout_dirty = false, selection = selecting, cursor_move = true }
end
function MDEdit:wordRight(selecting)
    self._burst = nil
    self._desired_x = nil
    self.ccol = next_word_col(self.lines[self.crow], self.ccol); self:refresh{ layout_dirty = false, selection = selecting, cursor_move = true }
end
function MDEdit:scrollBy(lines)
    local old = self.vtop or 1
    local max_top = math.max(1, self.visual_count or #self.lines)
    self.vtop = math.max(1, math.min(max_top, old + lines))
    if self.vtop ~= old then
        self._manual_scroll_cursor = { row = self.crow, col = self.ccol }
    end
    self:refreshScroll()
end
-- Page turns advance by roughly 3/4 of the visible editor height. Count
-- rendered row heights instead of visible row count so headings, gaps, and
-- tables don't distort physical scroll distance.
function MDEdit:pageStep()
    local rows = self._vrows
    local start = self.vtop or 1
    if not rows or #rows == 0 then return math.max(1, math.floor((self.visible_vrows or 12) * 0.75)) end
    local target = math.max(1, math.floor((self.visible_budget or math.floor(self.fh / 2)) * 0.75))
    local step, used = 0, 0
    while start + step <= #rows and used < target do
        step = step + 1
        used = used + self:visualRowHeight(rows[start + step - 1])
    end
    return math.max(1, step)
end
function MDEdit:pageUp()   self:scrollBy(-self:pageStep()) end
function MDEdit:pageDown() self:scrollBy(self:pageStep()) end
function MDEdit:pageLeft()  self:pageUp() end
function MDEdit:pageRight() self:pageDown() end
function MDEdit:pageFromTap(pos)
    if pos and pos.x < (self.fw / 2) then self:pageLeft() else self:pageRight() end
end
function MDEdit:setReaderMode(enabled, target_row, target_col)
    enabled = not not enabled
    if self.reader_mode == enabled then return end
    self.reader_mode = enabled
    self._pan_mode = nil
    self._last_tap = nil
    self._desired_x = nil
    self.sel = nil
    if enabled then
        if self.keyboard then self:hideKeyboard() end
        self.caret_on = false
        notify(_("Reader mode: tap Edit to return"))
    else
        local trow = target_row or self.top
        self.crow = math.max(1, math.min(#self.lines, trow))
        self.ccol = math.max(0, math.min(target_col or self.ccol or 0, #(self.lines[self.crow] or "")))
        self.caret_on = true
        notify(_("Editing mode"))
    end
    -- The top bar itself changes on a mode switch (formatting tools <-> "Edit"),
    -- so force a full repaint; the partial-region paths only cover the text body
    -- and would leave a stale toolbar when the keyboard is hidden.
    self:refresh{ full = true }
end
function MDEdit:onSwitchingKeyboardLayout() end
function MDEdit:showKeyboard()
    if self.reader_mode then return end
    if self.keyboard then return end
    local VirtualKeyboard = require("ui/widget/virtualkeyboard")
    local keyboard = VirtualKeyboard:new{ inputbox = self }
    keyboard.modal = false
    self.keyboard = keyboard
    local editor = self
    local original_close = keyboard.onCloseWidget
    function keyboard:onCloseWidget()
        if original_close then original_close(self) end
        if editor.keyboard == self then
            editor.keyboard = nil
            if editor._caret_blinking then
                editor:refresh{ layout_dirty = false, full = true }
            end
        end
    end
    self:refresh{ layout_dirty = false, full = true }
    UIManager:show(keyboard)
end
function MDEdit:hideKeyboard()
    if not self.keyboard then return end
    local keyboard = self.keyboard
    self.keyboard = nil
    UIManager:close(keyboard)
    self:refresh{ layout_dirty = false, full = true }
end
function MDEdit:isKeyboardRevealGesture(ges)
    if self.reader_mode or self.keyboard then return false end
    local p = ges and ges.pos
    local sp = ges and ges.start_pos or p
    if not p or not sp then return false end
    local x = sp.x or p.x
    local bottom_y = math.max(sp.y or 0, p.y or 0)
    local dy = (p.y or 0) - (sp.y or 0)
    local center = x >= self.fw * 0.36 and x <= self.fw * 0.64
    local from_bottom = bottom_y >= self.fh - MDEDIT_KEYBOARD_SWIPE_EDGE
    local upward = (ges.direction == "north") or dy <= -MDEDIT_KEYBOARD_SWIPE_DY
    return center and from_bottom and upward
end
function MDEdit:save()
    local text = self:currentText()
    local out = io.open(self.path, "w")
    if out then
        out:write(text)
        out:close()
        self._dirty = false
        self._file_text = text
        self._file_signature = file_signature(self.path)
        self._external_change_prompted = nil
        self._autosave_paused_for_external = nil
        if self._autosave_pending then UIManager:unschedule(self._autosave_pending); self._autosave_pending = nil end
        return true
    end
    return false
end
-- Handles both the app's own Rotate screen action and any generic resize;
-- rotate_screen_ccw() has already applied Screen:setRotationMode by the time
-- this runs, so this only needs to reflow the editor at the new dimensions.
function MDEdit:onScreenResize()
    self.fw, self.fh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.fw, h = self.fh }
    if self.ges_events then
        for _, ev in pairs(self.ges_events) do
            for _, range in ipairs(ev) do range.range = self.dimen end
        end
    end
    self._wcache, self._hcache = {}, {}
    if self._wrap_cache then
        for _, entry in pairs(self._wrap_cache) do free_wrap_entry(entry) end
    end
    self._wrap_cache = nil
    self:refresh{ layout_dirty = true, full = true }
    return true
end
function MDEdit:onResume()
    self:checkExternalFile()
    self.caret_on = true
    self:refresh{ layout_dirty = false, full = true }
    schedule_wake_repaint()
end
function MDEdit:saveAndClose()
    self:save()
    local keyboard = self.keyboard
    self.keyboard = nil
    if keyboard then UIManager:close(keyboard) end
    UIManager:close(self)
    if self.on_close then self.on_close() end
end
function MDEdit:saveAndOpenMarkdown()
    self:save()
    local keyboard = self.keyboard
    self.keyboard = nil
    if keyboard then UIManager:close(keyboard) end
    UIManager:close(self)
    if open_markdown_picker then open_markdown_picker(path_parent(self.path)) end
end
function MDEdit:onCloseWidget()
    self._closing = true
    if active_mdedit == self then active_mdedit = nil end
    self:flushAutosave()
    self._caret_blinking = false
    if self._file_poll_pending then UIManager:unschedule(self._file_poll_pending); self._file_poll_pending = nil end
    if self._page_pending then UIManager:unschedule(self._page_pending); self._page_pending = nil end
    if self._pan_reset then UIManager:unschedule(self._pan_reset); self._pan_reset = nil end
    if Device.input and self._old_disable_double_tap ~= nil then
        Device.input.disable_double_tap = self._old_disable_double_tap
    end
    -- Free every cached row's native TextWidget buffers, not just the ones
    -- currently on screen (UIManager's own close-time free only reaches the
    -- visible tree); off-screen rows are only reachable through this cache.
    if self._wrap_cache then
        for _, entry in pairs(self._wrap_cache) do free_wrap_entry(entry) end
        self._wrap_cache = nil
    end
end
function MDEdit:onKeyPress(key)
    local name = key and key.key
    if not name then return true end
    if self.reader_mode then
        if left_key(name) or up_key(name) or page_up_key(name) then self:pageLeft()
        elseif right_key(name) or down_key(name) or name == "Space" or name == "space" or name == " "
            or name == "Press" or name == "Return" or name == "Enter" or name == "KP_Enter"
            or page_down_key(name) then self:pageRight()
        end
        return true
    end
    local lname = name:lower()
    local m = key_mods(key)
    if shortcut_mod(m) and #name == 1 then
        if lname == "z" then if keymod(m, "Shift") then self:redo() else self:undo() end; return true
        elseif lname == "y" then self:redo(); return true
        elseif lname == "c" then self:copy(); return true
        elseif lname == "x" then self:cut(); return true
        elseif lname == "v" then self:paste(); return true
        elseif lname == "a" then self:selectAll(); return true end
    end
    if name == "Backspace" or name == "BackSpace" or name == "Del" or name == "Delete" then
        if word_key_mod(m) then self:delWord() else self:delChar() end
    elseif name == "Press" or name == "Return" or name == "Enter" or name == "KP_Enter" then self:newline()
    elseif fn_key_mod(m) and up_key(name) then self.sel = nil; self:pageUp()
    elseif fn_key_mod(m) and down_key(name) then self.sel = nil; self:pageDown()
    elseif left_key(name)  then self:arrow(0, -1, m)
    elseif right_key(name) then self:arrow(0, 1, m)
    elseif up_key(name)    then self:arrow(-1, 0, m)
    elseif down_key(name)  then self:arrow(1, 0, m)
    elseif page_up_key(name) then self.sel = nil; self:pageUp()
    elseif page_down_key(name) then self.sel = nil; self:pageDown()
    elseif name == "Space" or name == "space" or name == " " then if keymod(m, "Alt") then self.sel = nil; self:wordRight() else self:addChars(" ") end
    elseif name == "ISO_Left_Tab" or name == "BackTab" then self:indentLine(-1)
    elseif name == "Tab" then
        if keymod(m, "Shift") then self:indentLine(-1)
        else
            local _, kind, _, task = md_split_line_prefix(self.lines[self.crow])
            if kind or task then self:indentLine(1) else self:addChars("  ") end
        end
    elseif name == "Home" then self:goToStartOfLine()
    elseif name == "End" then self:goToEndOfLine()
    elseif KEYPAD_CHAR[name] then self:addChars(KEYPAD_CHAR[name])
    elseif #name == 1 then
        if keymod(m, "Alt") then return true end
        local ch = lname
        if keymod(m, "Shift") then
            if SHIFT_SYM[ch] then ch = SHIFT_SYM[ch] elseif ch:match("%a") then ch = ch:upper() end
        end
        self:addChars(ch)
    end
    return true
end
function MDEdit:onHold()
    if self.reader_mode then return true end
    if self.keyboard then self:hideKeyboard() end
    return true
end
function MDEdit:onSwipe(_, ges)
    if self._pan_mode == "select" then self._pan_mode = nil; return true end
    if self:isKeyboardRevealGesture(ges) then
        if self._pan_reset then UIManager:unschedule(self._pan_reset); self._pan_reset = nil end
        self._pan_active = nil
        self._pan_paged = nil
        self._pan_mode = nil
        self:showKeyboard()
        return true
    end
    -- Paging is handled in onPan, so swipes only clear the current gesture mode.
    -- Do not hide the keyboard here; accidental south swipes are common while
    -- editing near the on-screen keyboard.
    if self._pan_reset then UIManager:unschedule(self._pan_reset); self._pan_reset = nil end
    self._pan_active = nil
    self._pan_paged = nil
    self._pan_mode = nil
    return true
end
function MDEdit:bumpScale(d)
    self.scale = clamp_minfolio_scale(self.scale + d)
    MINFOLIO_STATE.scale = self.scale
    save_minfolio_state()
    self._wcache = {}; self._hcache = {}
    if self._wrap_cache then
        for _, entry in pairs(self._wrap_cache) do free_wrap_entry(entry) end
    end
    self._wrap_cache = nil          -- scale changes wrapping/heights; drop the per-line cache
    self:refresh()
end
function MDEdit:fmtWrap(mk)          -- wrap selection (or the cursor) in markers
    self:snapshot(); self._burst = nil
    if self:hasSel() then
        local lr, lc, hr, hc = self:selRange()
        if lr == hr then                -- wrap a single-line selection
            local l = self.lines[lr]
            self.lines[lr] = l:sub(1, lc) .. mk .. l:sub(lc+1, hc) .. mk .. l:sub(hc+1)
            self.crow = lr; self.ccol = hc + 2*#mk; self.sel = nil
            return self:refresh()
        end
    end
    local wl, wh = self:currentWordRange()
    if wl and wh then
        local l = self.lines[self.crow]
        self.lines[self.crow] = l:sub(1, wl) .. mk .. l:sub(wl+1, wh) .. mk .. l:sub(wh+1)
        self.ccol = wh + 2 * #mk
        return self:refresh()
    end
    local l = self.lines[self.crow]
    self.lines[self.crow] = l:sub(1, self.ccol) .. mk .. mk .. l:sub(self.ccol+1)
    self.ccol = self.ccol + #mk; self:refresh()
end
md_split_line_prefix = function(line)
    local indent, rest = line:match("^(%s*)(.*)$")
    local marker, body = rest:match("^([%-%*%+]%s+)(.*)$")
    local kind = marker and "bullet" or nil
    if not marker then
        marker, body = rest:match("^(%d+%.%s+)(.*)$")
        kind = marker and "ordered" or nil
    end
    body = body or rest
    local task, task_body = body:match("^(%[[ xX]%]%s+)(.*)$")
    if task then body = task_body end
    return indent or "", kind, marker, task, body
end
function MDEdit:setLinePrefix(kind, want_task)
    self:snapshot(); self._burst = nil
    local line = self.lines[self.crow]
    local indent, old_kind, marker, task, body = md_split_line_prefix(line)
    local old_prefix = indent .. (marker or "") .. (task or "")
    local new_marker = marker or ""
    if kind == "bullet" then
        new_marker = old_kind == "bullet" and "" or "- "
    elseif kind == "ordered" then
        new_marker = old_kind == "ordered" and "" or "1. "
    end
    local new_task = task or ""
    if want_task ~= nil then new_task = want_task and "[ ] " or "" end
    local new_prefix = indent .. new_marker .. new_task
    self.lines[self.crow] = new_prefix .. body
    self.ccol = math.max(0, self.ccol + #new_prefix - #old_prefix)
    self:refresh()
end
-- Indent (dir > 0) or outdent (dir < 0) the current logical line by one level
-- (INDENT_UNIT). Nesting is stored as leading whitespace; layoutLine turns it
-- into visual indent. Returns true if the line changed.
function MDEdit:indentLine(dir)
    local INDENT_UNIT = "  "
    local line = self.lines[self.crow]
    local indent, rest = line:match("^(%s*)(.*)$")
    local new_indent
    if dir > 0 then
        new_indent = INDENT_UNIT .. indent
    elseif indent:sub(1, #INDENT_UNIT) == INDENT_UNIT then
        new_indent = indent:sub(#INDENT_UNIT + 1)
    elseif #indent > 0 then
        new_indent = ""                       -- collapse a stray partial indent
    else
        return false                          -- already at column 0, nothing to do
    end
    self:snapshot(); self._burst = nil
    local newline = new_indent .. rest
    self.lines[self.crow] = newline
    self.ccol = math.max(0, math.min(#newline, self.ccol + (#newline - #line)))
    self:refresh()
    return true
end
function MDEdit:fmtToggle(findpat, prefix)  -- remove existing line prefix, else add it
    self:snapshot(); self._burst = nil
    local l = self.lines[self.crow]
    local pre = l:match(findpat)
    if pre then self.lines[self.crow] = l:sub(#pre+1); self.ccol = math.max(0, self.ccol - #pre)
    else self.lines[self.crow] = prefix .. l; self.ccol = self.ccol + #prefix end
    self:refresh()
end
function MDEdit:fmtHeader() self:fmtToggle("^(#+%s)", "# ") end
function MDEdit:fmtList()   self:setLinePrefix("bullet") end
function MDEdit:fmtOrdered() self:setLinePrefix("ordered") end
function MDEdit:fmtTask()
    local _, kind, _, task = md_split_line_prefix(self.lines[self.crow])
    if task then
        self:setLinePrefix(nil, false)
    else
        self:setLinePrefix(kind and nil or "bullet", true)
    end
end
function MDEdit:insertTable()
    self:snapshot(); self._burst = nil
    if self:hasSel() then self:deleteSelection() end
    local rows = { "| Column 1 | Column 2 |", "|---|---|", "|  |  |" }
    local l = self.lines[self.crow] or ""
    local before, after = l:sub(1, self.ccol), l:sub(self.ccol + 1)
    local body_row
    if before == "" and after == "" then
        self.lines[self.crow] = rows[1]
        for i = 2, #rows do table.insert(self.lines, self.crow + i - 1, rows[i]) end
        body_row = self.crow + 2
    else
        self.lines[self.crow] = before
        local insert_at = self.crow
        for _, row in ipairs(rows) do
            insert_at = insert_at + 1
            table.insert(self.lines, insert_at, row)
        end
        if after ~= "" then table.insert(self.lines, insert_at + 1, after) end
        body_row = self.crow + 3
    end
    self.crow = math.min(#self.lines, body_row)
    self.ccol = math.min(2, #(self.lines[self.crow] or ""))
    self:refresh()
end
function MDEdit:runTopAction(name)
    if name == "menu" then self:openControls()
    elseif name == "edit" then self:setReaderMode(false)
    elseif self.reader_mode and name == "close" then self:saveAndClose()
    elseif self.reader_mode then return
    elseif name == "header" then self:fmtHeader()
    elseif name == "bold" then self:fmtWrap("**")
    elseif name == "italic" then self:fmtWrap("*")
    elseif name == "list" then self:fmtList()
    elseif name == "ordered" then self:fmtOrdered()
    elseif name == "task" then self:fmtTask()
    elseif name == "reader" then self:setReaderMode(true)
    elseif name == "table" then self:insertTable()
    elseif name == "smaller" then self:bumpScale(-0.1)
    elseif name == "larger" then self:bumpScale(0.1)
    elseif name == "close" then self:saveAndClose()
    end
end
function MDEdit:openControls()
    if self.reader_mode then
        show_controls({
            { text = "Exit reader mode", callback = function() self:setReaderMode(false) end },
            { text = "⟲ Rotate screen", callback = function() rotate_screen_ccw() end },
            { text = "Save & close note", callback = function() self:saveAndClose() end },
        })
        return
    end
    local keyboard_item
    if self.keyboard then
        keyboard_item = { text = "Hide keyboard", callback = function() self:hideKeyboard() end }
    else
        keyboard_item = { text = "Show keyboard", callback = function() self:showKeyboard() end }
    end
    show_controls({
        { text = "Reader mode", callback = function() self:setReaderMode(true) end },
        keyboard_item,
        { text = "Heading", callback = function() self:fmtHeader() end },
        { text = "Bold", callback = function() self:fmtWrap("**") end },
        { text = "Italic", callback = function() self:fmtWrap("*") end },
        { text = "List item", callback = function() self:fmtList() end },
        { text = "Numbered list", callback = function() self:fmtOrdered() end },
        { text = "Checkbox", callback = function() self:fmtTask() end },
        { text = "Table", callback = function() self:insertTable() end },
        { text = "Text size +", callback = function() self:bumpScale(0.1) end },
        { text = "Text size -", callback = function() self:bumpScale(-0.1) end },
        { text = "Select all", callback = function() self:selectAll() end },
        { text = "Copy",  callback = function() self:copy() end },
        { text = "Cut",   callback = function() self:cut() end },
        { text = "Paste", callback = function() self:paste() end },
        { text = "Undo",  callback = function() self:undo() end },
        { text = "Redo",  callback = function() self:redo() end },
        { text = "⟲ Rotate screen", callback = function() rotate_screen_ccw() end },
        { text = "Open .md file...", callback = function() self:saveAndOpenMarkdown() end },
        { text = "Save & close note", callback = function() self:saveAndClose() end },
    })
end
function MDEdit:onTap(_, ges)
    local p = ges.pos
    if not p then return true end
    if self._pan_mode or self._pan_paged then
        if self._pan_reset then UIManager:unschedule(self._pan_reset); self._pan_reset = nil end
        self._pan_active = nil
        self._pan_paged = nil
        self._pan_mode = nil
        self._last_tap = nil
        return true
    end
    self._pan_mode = nil
    if p.y < 95 then                                          -- top bar
        local x = p.x - MDEDIT_PAD
        for name, z in pairs(self.top_zones or {}) do
            if x >= z.x0 and x < z.x1 then self:runTopAction(name); return true end
        end
        return true
    end
    if self.reader_mode then
        -- Taps near the L/R/bottom edge are page-turns (likely scrolling), never
        -- an exit gesture -- page immediately, no double-tap delay.
        if p.x < MDEDIT_READER_EDGE or p.x > self.fw - MDEDIT_READER_EDGE
            or p.y > self.fh - MDEDIT_READER_EDGE then
            self._rtap = nil
            if self._page_pending then UIManager:unschedule(self._page_pending); self._page_pending = nil end
            self:pageFromTap(p)
            return true
        end
        local table_hit = self:tableCellAtPos(p)
        if table_hit then
            self:openTableCellEditor(table_hit)
            return true
        end
        local now = now_seconds()
        if self._rtap and now - self._rtap.t < MDEDIT_READER_DTAP
            and math.abs(p.x - self._rtap.x) < 40 and math.abs(p.y - self._rtap.y) < 40 then
            -- fast double tap: cancel the pending page turn, drop into edit mode
            -- with the cursor placed where the user tapped.
            self._rtap = nil
            if self._page_pending then UIManager:unschedule(self._page_pending); self._page_pending = nil end
            local row, col = self:pointToCursor(p)
            self:setReaderMode(false, row, col)
            return true
        end
        self._rtap = { t = now, x = p.x, y = p.y }
        if self._page_pending then UIManager:unschedule(self._page_pending); self._page_pending = nil end
        local pos = { x = p.x, y = p.y }
        local fn
        fn = function()
            if self._page_pending == fn then self._page_pending = nil end
            self:pageFromTap(pos)
        end
        self._page_pending = fn
        UIManager:scheduleIn(MDEDIT_READER_DTAP, fn)
        return true
    end
    local now = now_seconds()
    local tap_row, tap_col = self:pointToCursor(p)
    if self._last_tap and now - self._last_tap.t < MDEDIT_EDIT_DTAP
        and math.abs(p.x - self._last_tap.x) < MDEDIT_EDIT_DTAP_MOVE
        and math.abs(p.y - self._last_tap.y) < MDEDIT_EDIT_DTAP_MOVE
        and tap_row == self._last_tap.row
        and tap_col == self._last_tap.col then
        self._last_tap = nil
        self:selectWordAt(p)
        return true
    end
    self._last_tap = { t = now, x = p.x, y = p.y, row = tap_row, col = tap_col }
    self.crow, self.ccol = tap_row, tap_col
    self._desired_x = nil
    self._manual_scroll_cursor = { row = self.crow, col = self.ccol }
    self.sel = nil; self:refresh{ layout_dirty = false, cursor_move = true }
    return true
end
function MDEdit:onDoubleTap(_, ges)
    -- Backup path: only reached if KOReader's double_tap is somehow active
    -- (we normally disable it and detect double-taps in onTap).
    self._pan_mode = nil
    if self.reader_mode then
        local p = ges.pos
        if p and p.y >= 95 and p.x >= MDEDIT_READER_EDGE and p.x <= self.fw - MDEDIT_READER_EDGE
            and p.y <= self.fh - MDEDIT_READER_EDGE then
            local table_hit = self:tableCellAtPos(p)
            if table_hit then
                self:openTableCellEditor(table_hit)
                return true
            end
            local row, col = self:pointToCursor(p)
            self:setReaderMode(false, row, col)
        end
        return true
    end
    if ges.pos and ges.pos.y >= 95 then self:selectWordAt(ges.pos) end
    return true
end
function MDEdit:onPan(_, ges)
    local p = ges.pos
    local sp = ges.start_pos
    if not sp and p then
        if self._pan_active and self._pan_start_x and self._pan_start_y then
            sp = { x = self._pan_start_x, y = self._pan_start_y }
        else
            sp = p
        end
    end
    if not p or not sp or sp.y < 95 then return true end
    if self._pan_reset then UIManager:unschedule(self._pan_reset); self._pan_reset = nil end
    local reset
    reset = function()
        if self._pan_reset == reset then
            self._pan_reset = nil
            self._pan_active = nil
            self._pan_paged = nil
            self._pan_mode = nil
        end
    end
    self._pan_reset = reset
    UIManager:scheduleIn(0.35, reset)
    local is_new_pan = not self._pan_active
        or (ges.start_pos and self._pan_start_x
            and (math.abs(sp.x - self._pan_start_x) > 2 or math.abs(sp.y - self._pan_start_y) > 2))
    if is_new_pan then
        self._pan_active = true
        self._pan_start_x, self._pan_start_y = sp.x, sp.y
        self._pan_mode, self._pan_last_y, self._pan_paged = nil, sp.y, false
    end
    if self.reader_mode then
        -- One page turn per drag, then latch until the finger lifts.
        local dy = p.y - sp.y
        if not self._pan_paged and math.abs(dy) >= MDEDIT_PAGE_PAN_MIN then
            self._pan_paged = true
            if dy < 0 then self:pageDown() else self:pageUp() end
        end
        return true
    end
    local dx, dy = p.x - sp.x, p.y - sp.y
    local adx, ady = math.abs(dx), math.abs(dy)
    if self._pan_mode == "keyboard" then return true end
    if self:isKeyboardRevealGesture(ges) then
        self._pan_mode = "keyboard"
        self._pan_paged = true
        self:showKeyboard()
        return true
    end
    if not self._pan_mode then
        if math.max(adx, ady) < MDEDIT_SELECT_PAN_MIN then return true end
        if adx >= ady * 1.2 then
            self._pan_mode = "select"
            local sr, sc = self:pointToCursor(sp)
            self.sel = { row = sr, col = sc }
        elseif ady >= MDEDIT_EDIT_SCROLL_PAN_MIN then
            self._pan_mode = "scroll"
            self.sel = nil
        else
            return true
        end
    end
    if self._pan_mode == "scroll" then
        -- One page turn per drag, then latch until the finger lifts.
        if not self._pan_paged then
            self._pan_paged = true
            if dy < 0 then self:pageDown() else self:pageUp() end
        end
        return true
    end
    local row, col = self:pointToCursor(p)
    self.crow, self.ccol = row, col
    self:refresh{ layout_dirty = false, selection = true }
    return true
end

-- ============================ Minfolio (native KOReader) ============================
local function edit_note(path)
    fl_restore_if_needed()
    if active_mdedit and not active_mdedit._closing then
        -- Already editing this exact file: keep the live editor (with its cursor
        -- and unsaved edits) instead of stacking a duplicate that would fight it.
        if active_mdedit.path == path then return end
        -- Switching files: flush and close the current editor first so only one
        -- editor (and one file poller) is ever live.
        active_mdedit:saveAndClose()
    end
    local ed = MDEdit:new{ path = path }
    active_mdedit = ed
    UIManager:show(ed, "full")   -- "full" forces a complete repaint over the menu
end

-- Rotates the whole device screen 90° counter-clockwise (repeat to cycle through
-- upright / sideways / upside-down / sideways-the-other-way, same 4 modes KOReader
-- itself uses for its own rotation).
rotate_screen_ccw = function()
    local mode = Screen:getRotationMode()
    Screen:setRotationMode((mode - 1) % 4)
    -- Every full-screen widget we show (the file listing, the editor, any
    -- popout) is sized from Screen:getWidth()/getHeight() at construction
    -- time, so it goes stale the instant the physical rotation flips those --
    -- reads as a frozen/undersized screen. Broadcasting ScreenResize reaches
    -- every widget in the stack (including ones sitting hidden underneath
    -- another, e.g. the file list behind an open note), not just the one on
    -- top, so nothing is left showing a layout built for the old dimensions.
    UIManager:broadcastEvent(Event:new("ScreenResize"))
end

local function clean_entry_name(name, add_md_ext)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" or name == "." or name == ".." or name:find("/", 1, true) or name:find("%z") then
        return nil
    end
    if add_md_ext and not name:match("%.%w+$") then name = name .. ".md" end
    return name
end

local function ensure_dir(path)
    if lfs.attributes(path, "mode") == "directory" then return true end
    return lfs.mkdir(path)
end

local function remove_tree(path)
    local mode = lfs.attributes(path, "mode")
    if mode == "file" then return os.remove(path) end
    if mode ~= "directory" then return false end
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            if not remove_tree(path_join(path, name)) then return false end
        end
    end
    return lfs.rmdir(path)
end

local function dir_entries(dir)
    local dirs, files = {}, {}
    local ok = pcall(function()
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." and not name:match("^%.") then
                local path = path_join(dir, name)
                local mode = lfs.attributes(path, "mode")
                if mode == "directory" then
                    dirs[#dirs+1] = name
                elseif mode == "file" then
                    files[#files+1] = name
                end
            end
        end
    end)
    table.sort(dirs)
    table.sort(files)
    return dirs, files, ok
end

open_markdown_picker = function(start_dir)
    local dir = start_dir or NOTES_DIR
    if lfs.attributes(dir, "mode") ~= "directory" then dir = NOTES_DIR end
    if lfs.attributes(dir, "mode") ~= "directory" then dir = "/mnt/us" end

    local dirs, all_files, ok = dir_entries(dir)
    local files = {}
    for _, name in ipairs(all_files) do
        if is_markdown_file(name) then files[#files+1] = name end
    end

    local items = {}
    if dir ~= "/" then items[#items+1] = { text = "../", kind = "dir", path = path_parent(dir) } end
    if dir ~= NOTES_DIR and lfs.attributes(NOTES_DIR, "mode") == "directory" then
        items[#items+1] = { text = _("Minfolio folder"), kind = "dir", path = NOTES_DIR }
    end
    for _, name in ipairs(dirs) do
        items[#items+1] = { text = name .. "/", kind = "dir", path = path_join(dir, name) }
    end
    for _, name in ipairs(files) do
        items[#items+1] = { text = name, kind = "file", path = path_join(dir, name) }
    end
    if #items == 0 or not ok then
        items[#items+1] = { text = ok and _("No Markdown files here") or _("Cannot read this folder"), kind = "noop" }
    end

    local menu
    menu = Menu:new{
        title = _("Open .md") .. " - " .. (path_base(dir) ~= "" and dir or "/"),
        item_table = items,
        is_popout = false,
        onMenuSelect = function(_self, item)
            if item.kind == "dir" then
                UIManager:close(menu)
                open_markdown_picker(item.path)
            elseif item.kind == "file" then
                UIManager:close(menu)
                edit_note(item.path)
            end
        end,
    }
    UIManager:show(menu)
end

local show_file_manager

local function refresh_file_manager(menu, dir)
    if menu then UIManager:close(menu) end
    show_file_manager(dir)
end

local function show_new_entry_dialog(menu, dir, kind)
    local is_folder = kind == "folder"
    local dlg
    dlg = InputDialog:new{
        title = is_folder and _("New folder") or _("New note"),
        input = "",
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dlg) end },
            { text = _("Create"), is_enter_default = true, callback = function()
                local name = clean_entry_name(dlg:getInputText(), not is_folder)
                UIManager:close(dlg)
                if not name then notify(_("Invalid name")); return end
                local path = path_join(dir, name)
                if lfs.attributes(path, "mode") then notify(_("Name already exists")); return end
                if is_folder then
                    if ensure_dir(path) then
                        refresh_file_manager(menu, dir)
                    else
                        notify(_("Could not create folder"))
                    end
                else
                    if write_file(path, "") then
                        refresh_file_manager(menu, dir)
                        edit_note(path)
                    else
                        notify(_("Could not create note"))
                    end
                end
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

local function show_rename_dialog(parent_menu, dir, item)
    local dlg
    dlg = InputDialog:new{
        title = _("Rename"),
        input = item.name,
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dlg) end },
            { text = _("Rename"), is_enter_default = true, callback = function()
                local name = clean_entry_name(dlg:getInputText(), item.kind == "file" and is_markdown_file(item.name))
                UIManager:close(dlg)
                if not name then notify(_("Invalid name")); return end
                if name == item.name then return end
                local dest = path_join(dir, name)
                if lfs.attributes(dest, "mode") then notify(_("Name already exists")); return end
                if os.rename(item.path, dest) then
                    refresh_file_manager(parent_menu, dir)
                else
                    notify(_("Could not rename"))
                end
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

local function confirm_delete(parent_menu, dir, item)
    UIManager:show(ConfirmBox:new{
        text = string.format(_("Delete %s?"), item.name),
        ok_text = _("Delete"),
        ok_callback = function()
            if remove_tree(item.path) then
                refresh_file_manager(parent_menu, dir)
            else
                notify(_("Could not delete"))
            end
        end,
    })
end

local function show_item_actions(parent_menu, dir, item)
    local actions = {}
    if item.kind == "dir" then
        actions[#actions+1] = { text = _("Open folder"), callback = function()
            refresh_file_manager(parent_menu, item.path)
        end }
    elseif is_markdown_file(item.name) then
        actions[#actions+1] = { text = _("Open"), callback = function()
            edit_note(item.path)
        end }
    end
    actions[#actions+1] = { text = _("Rename"), callback = function() show_rename_dialog(parent_menu, dir, item) end }
    actions[#actions+1] = { text = _("Delete"), callback = function() confirm_delete(parent_menu, dir, item) end }

    -- A compact centered popup (context menu) sized to its few actions, rather
    -- than a full-screen list -- long-press should feel like a contextual menu.
    local n = #actions
    local box_h = math.min(math.floor(Screen:getHeight() * 0.7),
        Screen:scaleBySize(96 + n * 58))
    local menu
    menu = Menu:new{
        title = item.name,
        item_table = actions,
        is_popout = true,
        width = math.floor(Screen:getWidth() * 0.62),
        height = box_h,
        onMenuSelect = function(_self, action)
            UIManager:close(menu)
            if action.callback then UIManager:scheduleIn(0.01, action.callback) end
        end,
    }
    UIManager:show(menu)
end

show_file_manager = function(start_dir)
    fl_restore_if_needed()
    ensure_dir(NOTES_DIR)
    local dir = start_dir or NOTES_DIR
    if lfs.attributes(dir, "mode") ~= "directory" then dir = NOTES_DIR end

    local dirs, files, ok = dir_entries(dir)
    local menu
    local items = {
        { text = "＋ " .. _("New note"), kind = "new_note" },
        { text = "＋ " .. _("New folder"), kind = "new_folder" },
        { text = _("Open .md file..."), is_open = true },
    }
    if dir ~= NOTES_DIR then items[#items+1] = { text = "../", kind = "dir_nav", path = path_parent(dir) } end
    for _, name in ipairs(dirs) do
        local item = { text = name .. "/", kind = "dir", name = name, path = path_join(dir, name) }
        item.hold_callback = function() show_item_actions(menu, dir, item) end
        items[#items+1] = item
    end
    for _, name in ipairs(files) do
        local item = { text = name, kind = "file", name = name, path = path_join(dir, name) }
        item.hold_callback = function() show_item_actions(menu, dir, item) end
        items[#items+1] = item
    end
    if not ok then items[#items+1] = { text = _("Cannot read this folder"), kind = "noop" } end
    logger.info("minfolio open_notes: showing", #items, "items")
    -- Custom title bar so we can show a Kindle-style battery indicator to the left
    -- of the close (X) icon. TitleBar only exposes a single right icon (the close
    -- button), so the battery is added as an extra right-aligned overlap child.
    local title_text = _("Minfolio") .. " - " .. (dir == NOTES_DIR and path_base(NOTES_DIR) or dir)
    local title_bar = TitleBar:new{
        width = Screen:getWidth(),
        align = "center",
        title = title_text,
        with_bottom_line = true,
        left_icon = "appbar.menu",
        left_icon_tap_callback = function()
            show_controls({ { text = "⟲ " .. _("Rotate screen"), callback = rotate_screen_ccw } })
        end,
        close_callback = function() if menu then menu:onClose() end end,
    }
    local batt = battery_indicator()
    if batt then
        local batt_cell = CenterContainer:new{
            dimen = Geom:new{ w = batt:getSize().w, h = title_bar:getHeight() }, batt }
        table.insert(title_bar, HorizontalGroup:new{
            align = "center", overlap_align = "right",
            batt_cell, HorizontalSpan:new{ width = Screen:scaleBySize(44) },
        })
    end
    menu = Menu:new{
        title = title_text,
        item_table = items,
        is_popout = false,
        handle_hold_on_hold_release = true,
        custom_title_bar = title_bar,
        onMenuSelect = function(_self, item)
            -- keep this list open underneath; the editor closes back to it (not the file manager)
            if item.kind == "new_note" then show_new_entry_dialog(menu, dir, "note")
            elseif item.kind == "new_folder" then show_new_entry_dialog(menu, dir, "folder")
            elseif item.is_open then open_markdown_picker(dir)
            elseif item.kind == "dir_nav" then refresh_file_manager(menu, item.path)
            elseif item.kind == "dir" then refresh_file_manager(menu, item.path)
            elseif item.kind == "file" then
                if is_markdown_file(item.name) then edit_note(item.path) else show_item_actions(menu, dir, item) end
            end
        end,
        onMenuHold = function(_self, item)
            logger.info("minfolio file manager hold:", item and item.name, item and item.kind)
            if item and item.hold_callback then
                item.hold_callback()
            elseif item and (item.kind == "dir" or item.kind == "file") then
                show_item_actions(menu, dir, item)
            end
            return true
        end,
    }
    title_bar.show_parent = menu
    if title_bar.left_button then title_bar.left_button.show_parent = menu end
    if title_bar.right_button then title_bar.right_button.show_parent = menu end
    UIManager:show(menu)
end

local function open_notes()
    show_file_manager(NOTES_DIR)
end

-- ============================ Plugin ============================
local Minfolio = WidgetContainer:extend{ name = "minfolio", is_doc_only = false }

local LAUNCH_FLAG = "/tmp/minfolio_launch"
local function read_launch_target(path)
    local fp = io.open(path, "r"); if not fp then return nil end
    local t = fp:read("*l"); fp:close()
    return t and t:gsub("%s+$", "")
end

function Minfolio:openLaunchTarget(target)
    if not target or target == "" then return end
    logger.info("minfolio launch target =", tostring(target))
    if target == "notes" or target == "open" then
        UIManager:scheduleIn(0.1, open_notes)
    elseif target:match("^edit:") then                  -- open a specific file in the editor
        local path = target:sub(6)
        UIManager:scheduleIn(0.1, function() edit_note(path) end)
    end
end

function Minfolio:pollLaunchFlag()
    local target = read_launch_target(LAUNCH_FLAG)
    if target and target ~= "" then
        os.remove(LAUNCH_FLAG)
        self:openLaunchTarget(target)
    end
    UIManager:scheduleIn(0.5, function() self:pollLaunchFlag() end)
end

function Minfolio:onResume()
    -- The Kindle framework owns the light; resync labels/state and repaint after
    -- the screensaver/framework wake transition settles.
    fl_restore_if_needed()
    schedule_wake_repaint()
end

function Minfolio:onDispatcherRegisterActions()
    Dispatcher:registerAction("minfolio_open",
        { category = "none", event = "MinfolioOpen", title = _("Open Minfolio"), general = true })
end

function Minfolio:init()
    install_keyboard_aliases()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if not _G.__minfolio_launch_polling then
        _G.__minfolio_launch_polling = true
        UIManager:scheduleIn(0.5, function() self:pollLaunchFlag() end)
    end
    local target = read_launch_target(LAUNCH_FLAG)
    if target and target ~= "" then
        os.remove(LAUNCH_FLAG)
        self:openLaunchTarget(target)
    end
end

function Minfolio:onMinfolioOpen() open_notes(); return true end

function Minfolio:addToMainMenu(menu_items)
    menu_items.minfolio = {
        text = _("Minfolio"),
        sorting_hint = "more_tools",
        callback = function() open_notes() end,
    }
end

return Minfolio
