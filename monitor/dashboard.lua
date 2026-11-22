require 'cairo'
pcall(require, 'cairo_xlib')

local FONT_FAMILY = 'Noto Sans CJK SC'
local WIN_W = 436
local WIN_H = 580

-- Layout geometry
local CARD_X = 2
local CARD_Y = 2
local CARD_W = 432
local CARD_H = 576
local CARD_R = 16

local PAD_X = 22
local RIGHT_X = WIN_W - PAD_X            -- 414
local INNER_W = RIGHT_X - PAD_X          -- 392
local LEFT_BAR_W = 284
local LEFT_BAR_RIGHT = PAD_X + LEFT_BAR_W -- 306
local GPU_COL2_X = 176
local DISK_R_X = 314
local NET_GAP = 10
local NET_BAR_W = (INNER_W - NET_GAP) / 2 -- 191

local GPU_STATS_PATH = '/tmp/conky-gpu-stats.txt'
local GPU_PID_PATH = '/tmp/conky-gpu-daemon.pid'
local SCRIPT_DIR = (debug.getinfo(1, 'S') and debug.getinfo(1, 'S').source:match('^@(.*/)'))
    or ((os.getenv('HOME') or '') .. '/.config/conky/')
local GPU_DAEMON_SCRIPT = SCRIPT_DIR .. 'gpu_daemon.py'
local DRAG_HELPER_SCRIPT = SCRIPT_DIR .. 'drag_helper.py'

-- Reusable text extents struct (avoid per-frame allocations)
local text_ext = create_cairo_text_extents_t and create_cairo_text_extents_t()
    or (cairo_text_extents_t and cairo_text_extents_t:create())

-- Persistent state across frames
local state = {
    last_updates = -1,
    prev_uptime = nil,
    -- CPU
    cpu_name = nil,
    cpu_freq_paths = nil,
    coretemp_path = nil,
    x86_pkg_path = nil,
    prev_rapl_uj = nil,
    rapl_max_uj = nil,
    -- RAM
    ram_temp_paths = nil,
    last_ram_scan = -999,
    -- Network
    net_iface = nil,
    last_net_iface_check = -999,
    prev_rx = nil,
    prev_tx = nil,
    -- Disks
    disks = nil,
    last_smart_check = -999,
    -- Battery
    bat_dir = nil,
    last_bat_scan = -999,
    -- GPU daemon & mouse drag
    last_gpu_spawn = -999,
    last_drag_launch = -999,
    -- Current snapshot values for drawing
    data = {
        cpu_name = 'CPU',
        cpu_pct = 0,
        cpu_temp = nil,
        cpu_power_w = nil,
        cpu_freq_ghz = nil,
        gpu_name = 'GPU',
        gpu_pct = 0,
        gpu_temp = nil,
        gpu_power_w = nil,
        gpu_clock_mhz = nil,
        gpu_mem_clock_mhz = nil,
        gpu_mem_temp = nil,
        gpu_vram_used_gb = nil,
        gpu_vram_total_gb = nil,
        gpu_vram_pct = nil,
        ram_used_gb = 0,
        ram_total_gb = 0,
        ram_pct = 0,
        ram_temps = {},
        net_rx_kbs = 0,
        net_tx_kbs = 0,
        disks = {},
        bat_pct = nil,
        bat_power_w = nil,
        bat_chg_a = nil,
        bat_dchg_a = nil,
    }
}

-- ============================================================================
-- Low-level file & string utilities
-- ============================================================================

local function trim(s)
    if not s then return '' end
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function read_file(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local content = f:read('*a')
    f:close()
    return content
end

local function read_line(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local line = f:read('*l')
    f:close()
    return line
end

local function read_num(path)
    local s = read_line(path)
    if not s then return nil end
    return tonumber(trim(s))
end

local function run_cmd(cmd)
    local p = io.popen(cmd, 'r')
    if not p then return '' end
    local out = p:read('*a') or ''
    p:close()
    return out
end

local function get_uptime()
    local line = read_line('/proc/uptime')
    if not line then return os.clock() end
    return tonumber(line:match('^(%S+)')) or os.clock()
end

local function parse_num(s)
    if not s then return nil end
    s = trim(s)
    if s == '' or s == 'N/A' or s == '[N/A]' or s:find('Not Supported', 1, true) then
        return nil
    end
    return tonumber(s)
end

-- ============================================================================
-- Hardware discovery helpers
-- ============================================================================

local function detect_cpu_static()
    if state.cpu_name == nil then
        local cpuinfo = read_file('/proc/cpuinfo') or ''
        local raw = cpuinfo:match('model name%s*:%s*([^\n]+)') or 'CPU'
        raw = raw:gsub('Intel%(R%)', ''):gsub('AMD ', ''):gsub('%(TM%)', ''):gsub('%(R%)', '')
        raw = raw:gsub('%s+', ' ')
        state.cpu_name = trim(raw):upper()
    end

    if state.cpu_freq_paths == nil then
        state.cpu_freq_paths = {}
        local out = run_cmd('ls -1 /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null')
        for p in out:gmatch('[^\n]+') do
            table.insert(state.cpu_freq_paths, p)
        end
    end

    if state.coretemp_path == nil then
        for i = 0, 32 do
            local hw = '/sys/class/hwmon/hwmon' .. i
            local name = trim(read_line(hw .. '/name'))
            if name == 'coretemp' then
                for t = 1, 64 do
                    local lbl = trim(read_line(hw .. '/temp' .. t .. '_label'))
                    if lbl == 'Package id 0' then
                        local inp = hw .. '/temp' .. t .. '_input'
                        if read_num(inp) then
                            state.coretemp_path = inp
                            break
                        end
                    end
                end
                if state.coretemp_path then break end
            end
        end
    end

    if state.x86_pkg_path == nil and state.coretemp_path == nil then
        for i = 0, 20 do
            local tz = '/sys/class/thermal/thermal_zone' .. i
            if trim(read_line(tz .. '/type')) == 'x86_pkg_temp' then
                local inp = tz .. '/temp'
                if read_num(inp) then
                    state.x86_pkg_path = inp
                    break
                end
            end
        end
    end
end

local function scan_ram_temp_sensors(now)
    if state.ram_temp_paths ~= nil and #state.ram_temp_paths > 0 then
        return
    end
    if now - state.last_ram_scan < 10 then
        return
    end
    state.last_ram_scan = now
    local found = {}
    for i = 0, 32 do
        local hw = '/sys/class/hwmon/hwmon' .. i
        local name = trim(read_line(hw .. '/name'))
        if name == 'spd5118' or name == 'jc42' then
            local inp = hw .. '/temp1_input'
            if read_num(inp) then
                table.insert(found, inp)
            end
        end
    end
    state.ram_temp_paths = found
end

local function detect_net_iface(now)
    if state.net_iface ~= nil and (now - state.last_net_iface_check < 10) then
        return
    end
    state.last_net_iface_check = now
    local route = run_cmd('ip route get 1.1.1.1 2>/dev/null')
    local iface = route:match(' dev%s+(%S+)')
    if not iface or iface == '' then
        local out = run_cmd('ls -1 /sys/class/net 2>/dev/null')
        for dev in out:gmatch('[^\n]+') do
            if dev ~= 'lo' then
                local st = trim(read_line('/sys/class/net/' .. dev .. '/operstate'))
                if st == 'up' then
                    iface = dev
                    break
                end
            end
        end
    end
    if iface ~= state.net_iface then
        state.net_iface = iface
        state.prev_rx = nil
        state.prev_tx = nil
    end
end

local function short_brand_name(model)
    local low = model:lower()
    if low:find('hynix', 1, true) then return 'Hynix' end
    if low:find('samsung', 1, true) then return 'Samsung' end
    if low:find('western digital', 1, true) or low:find('wdc', 1, true) or low:find('sandisk', 1, true) or low:match('^wd%f[^%w]') then
        return 'WD'
    end
    if low:find('crucial', 1, true) or low:find('micron', 1, true) then return 'Micron' end
    if low:find('kioxia', 1, true) or low:find('toshiba', 1, true) then return 'Kioxia' end
    if low:find('kingston', 1, true) then return 'Kingston' end
    if low:find('solidigm', 1, true) or low:find('intel', 1, true) then return 'Solidigm' end
    local first = model:match('^(%S+)') or 'NVMe'
    if #first > 8 then first = first:sub(1, 8) end
    return first
end

local function discover_disks()
    if state.disks ~= nil then return end

    local root_src = trim(run_cmd('findmnt -n -o SOURCE / 2>/dev/null'))
    local drives_introspect = run_cmd(
        'gdbus introspect --system --dest org.freedesktop.UDisks2 --object-path /org/freedesktop/UDisks2/drives 2>/dev/null'
    )
    local udisks_nodes = {}
    for node_name in drives_introspect:gmatch('node%s+([^%s%{]+)%s*%{') do
        if not node_name:find('^/') then
            table.insert(udisks_nodes, node_name)
        end
    end

    local disks = {}
    local nvme_list = run_cmd('ls -1 /sys/class/nvme 2>/dev/null')
    for ctrl in nvme_list:gmatch('[^\n]+') do
        local base = '/sys/class/nvme/' .. ctrl
        local model = trim(read_line(base .. '/model'))
        local serial = trim(read_line(base .. '/serial'))
        local blk = ctrl .. 'n1'
        local is_root = root_src:find('/dev/' .. blk, 1, true) ~= nil

        local hwmon_temp = trim(run_cmd('ls -1 ' .. base .. '/hwmon*/temp1_input 2>/dev/null | head -n1'))
        if hwmon_temp == '' then hwmon_temp = nil end

        local udisks_path = nil
        if serial ~= '' then
            for _, node_name in ipairs(udisks_nodes) do
                if node_name:find(serial, 1, true) then
                    udisks_path = '/org/freedesktop/UDisks2/drives/' .. node_name
                    break
                end
            end
        end

        table.insert(disks, {
            ctrl = ctrl,
            blk = blk,
            brand = short_brand_name(model),
            is_root = is_root,
            temp_path = hwmon_temp,
            udisks_path = udisks_path,
            temp_c = nil,
            health_pct = nil,
            read_mbs = 0,
            write_mbs = 0,
            prev_rd_sec = nil,
            prev_wr_sec = nil,
        })
    end

    table.sort(disks, function(a, b)
        if a.is_root ~= b.is_root then
            return a.is_root
        end
        return a.ctrl < b.ctrl
    end)

    state.disks = disks
end

local function refresh_disk_smart(now)
    if now - state.last_smart_check < 600 then
        return
    end
    state.last_smart_check = now
    for _, d in ipairs(state.disks or {}) do
        if d.udisks_path then
            local out = run_cmd(
                "gdbus call --system --dest org.freedesktop.UDisks2 --object-path '"
                .. d.udisks_path
                .. "' --method org.freedesktop.UDisks2.NVMe.Controller.SmartGetAttributes '{}' 2>/dev/null"
            )
            local hex = out:match("'percent_used'%s*:%s*<byte%s+0x([0-9a-fA-F]+)>")
            local used = nil
            if hex then
                used = tonumber(hex, 16)
            else
                local dec = out:match("'percent_used'%s*:%s*<byte%s+(%d+)>")
                if dec then used = tonumber(dec) end
            end
            if used then
                d.health_pct = math.max(0, math.min(100, 100 - used))
            end
        end
    end
end

local function detect_battery(now)
    if state.bat_dir ~= nil then return end
    if now - state.last_bat_scan < 30 then return end
    state.last_bat_scan = now
    local out = run_cmd('ls -1 /sys/class/power_supply 2>/dev/null')
    for entry in out:gmatch('[^\n]+') do
        local p = '/sys/class/power_supply/' .. entry
        if trim(read_line(p .. '/type')) == 'Battery' then
            state.bat_dir = p
            break
        end
    end
end

-- ============================================================================
-- Per-tick sensor collection
-- ============================================================================

local function update_sensors()
    local now = get_uptime()
    local dt = state.prev_uptime and (now - state.prev_uptime) or 0
    if dt < 0 then dt = 0 end
    state.prev_uptime = now

    local d = state.data

    -- 1. CPU
    detect_cpu_static()
    d.cpu_name = state.cpu_name
    d.cpu_pct = tonumber(conky_parse('${cpu cpu0}')) or 0

    local ctemp = state.coretemp_path and read_num(state.coretemp_path)
        or (state.x86_pkg_path and read_num(state.x86_pkg_path))
    d.cpu_temp = ctemp and (ctemp / 1000) or nil

    local max_khz = 0
    for _, p in ipairs(state.cpu_freq_paths or {}) do
        local khz = read_num(p)
        if khz and khz > max_khz then max_khz = khz end
    end
    d.cpu_freq_ghz = max_khz > 0 and (max_khz / 1000000) or nil

    local rapl_uj = read_num('/sys/class/powercap/intel-rapl:0/energy_uj')
    if rapl_uj then
        if state.prev_rapl_uj and dt > 0.05 then
            local diff = rapl_uj - state.prev_rapl_uj
            if diff < 0 then
                if not state.rapl_max_uj then
                    state.rapl_max_uj = read_num('/sys/class/powercap/intel-rapl:0/max_energy_range_uj') or 0
                end
                if state.rapl_max_uj > 0 then
                    diff = diff + state.rapl_max_uj
                else
                    diff = nil
                end
            end
            if diff and diff >= 0 then
                d.cpu_power_w = diff / (dt * 1000000)
            end
        end
        state.prev_rapl_uj = rapl_uj
    else
        state.prev_rapl_uj = nil
        d.cpu_power_w = nil
    end

    -- 2. GPU (fast read from persistent NVML + NVAPI daemon)
    local gpu_txt = read_file(GPU_STATS_PATH)
    local kv = {}
    if gpu_txt then
        for line in gpu_txt:gmatch('[^\n]+') do
            local k, v = line:match('^([^=]+)=(.*)$')
            if k then kv[k] = trim(v) end
        end
    end
    local gpu_ts = tonumber(kv.ts)
    if gpu_ts and math.abs(now - gpu_ts) <= 15 then
        local gname = kv.name and kv.name ~= '' and kv.name or 'GPU'
        gname = gname:gsub('^NVIDIA%s+GeForce%s+', ''):gsub('%s+GPU$', ''):upper()
        d.gpu_name = gname
        d.gpu_pct = parse_num(kv.util) or 0
        d.gpu_temp = parse_num(kv.core_temp)
        d.gpu_mem_temp = parse_num(kv.mem_temp)
        d.gpu_power_w = parse_num(kv.power_w)
        d.gpu_clock_mhz = parse_num(kv.core_clk)
        d.gpu_mem_clock_mhz = parse_num(kv.mem_clk)
        local v_used = parse_num(kv.vram_used_mib)
        local v_tot = parse_num(kv.vram_total_mib)
        if v_used and v_tot and v_tot > 0 then
            d.gpu_vram_used_gb = v_used / 1024
            d.gpu_vram_total_gb = v_tot / 1024
            d.gpu_vram_pct = (v_used / v_tot) * 100
        end
    else
        d.gpu_pct = 0
        d.gpu_temp = nil
        d.gpu_mem_temp = nil
        d.gpu_power_w = nil
        d.gpu_clock_mhz = nil
        d.gpu_mem_clock_mhz = nil
        d.gpu_vram_used_gb = nil
        d.gpu_vram_total_gb = nil
        d.gpu_vram_pct = nil
        if now - state.last_gpu_spawn >= 15 then
            state.last_gpu_spawn = now
            local stat_line = read_line('/proc/self/stat')
            local self_pid = stat_line and stat_line:match('^(%d+)')
            if self_pid then
                os.execute('/usr/bin/python3 "' .. GPU_DAEMON_SCRIPT .. '"' .. ' --ppid ' .. self_pid .. ' >/tmp/conky-gpu-daemon.log 2>&1 </dev/null &')
            end
        end
    end

    -- 3. RAM
    local meminfo = read_file('/proc/meminfo') or ''
    local mem_total_kb = tonumber(meminfo:match('MemTotal:%s*(%d+)')) or 0
    local mem_avail_kb = tonumber(meminfo:match('MemAvailable:%s*(%d+)'))
    if not mem_avail_kb then
        mem_avail_kb = tonumber(meminfo:match('MemFree:%s*(%d+)')) or 0
    end
    if mem_total_kb > 0 then
        local used_kb = math.max(0, mem_total_kb - mem_avail_kb)
        d.ram_total_gb = mem_total_kb / 1048576
        d.ram_used_gb = used_kb / 1048576
        d.ram_pct = math.floor((used_kb / mem_total_kb) * 100 + 0.5)
    end

    scan_ram_temp_sensors(now)
    d.ram_temps = {}
    for _, p in ipairs(state.ram_temp_paths or {}) do
        local t = read_num(p)
        if t then
            table.insert(d.ram_temps, t / 1000)
        end
    end
    if #d.ram_temps == 0 and gpu_ts and math.abs(now - gpu_ts) <= 15 and kv.ram_temps and kv.ram_temps ~= '' then
        for part in kv.ram_temps:gmatch('[^,]+') do
            local val = parse_num(part)
            if val then
                table.insert(d.ram_temps, val)
            end
        end
    end

    -- 4. NETWORK
    detect_net_iface(now)
    if state.net_iface then
        local rx = read_num('/sys/class/net/' .. state.net_iface .. '/statistics/rx_bytes')
        local tx = read_num('/sys/class/net/' .. state.net_iface .. '/statistics/tx_bytes')
        if rx and tx then
            if state.prev_rx and state.prev_tx and dt > 0.05 then
                local drx = rx >= state.prev_rx and (rx - state.prev_rx) or 0
                local dtx = tx >= state.prev_tx and (tx - state.prev_tx) or 0
                d.net_rx_kbs = drx / (dt * 1024)
                d.net_tx_kbs = dtx / (dt * 1024)
            end
            state.prev_rx = rx
            state.prev_tx = tx
        end
    else
        d.net_rx_kbs = 0
        d.net_tx_kbs = 0
    end

    -- 5. DISKS
    discover_disks()
    refresh_disk_smart(now)
    local diskstats = read_file('/proc/diskstats') or ''
    local ds_map = {}
    for line in diskstats:gmatch('[^\n]+') do
        local name, f4, f5, rd_sec, f7, f8, f9, wr_sec =
            line:match('^%s*%d+%s+%d+%s+(%S+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)')
        if name then
            ds_map[name] = { tonumber(rd_sec), tonumber(wr_sec) }
        end
    end
    for _, disk in ipairs(state.disks or {}) do
        if disk.temp_path then
            local t = read_num(disk.temp_path)
            disk.temp_c = t and math.floor(t / 1000 + 0.5) or nil
        end
        local ds = ds_map[disk.blk]
        if ds then
            local rd, wr = ds[1], ds[2]
            if disk.prev_rd_sec and disk.prev_wr_sec and dt > 0.05 then
                local drd = rd >= disk.prev_rd_sec and (rd - disk.prev_rd_sec) or 0
                local dwr = wr >= disk.prev_wr_sec and (wr - disk.prev_wr_sec) or 0
                disk.read_mbs = (drd * 512) / (dt * 1048576)
                disk.write_mbs = (dwr * 512) / (dt * 1048576)
            end
            disk.prev_rd_sec = rd
            disk.prev_wr_sec = wr
        end
    end
    d.disks = state.disks or {}

    -- 6. BATTERY
    detect_battery(now)
    if state.bat_dir then
        local cap = read_num(state.bat_dir .. '/capacity')
        local status = trim(read_line(state.bat_dir .. '/status'))
        local cur_ua = read_num(state.bat_dir .. '/current_now') or 0
        local volt_uv = read_num(state.bat_dir .. '/voltage_now') or 0
        local pwr_uw = read_num(state.bat_dir .. '/power_now')
        local amps = math.abs(cur_ua) / 1000000
        local watts = pwr_uw and (math.abs(pwr_uw) / 1000000) or (amps * (volt_uv / 1000000))
        d.bat_pct = cap
        d.bat_power_w = watts
        d.bat_chg_a = (status == 'Charging') and amps or 0
        d.bat_dchg_a = (status == 'Discharging') and amps or 0
    end
end

-- ============================================================================
-- Cairo drawing helpers
-- ============================================================================

local function rounded_rect(cr, x, y, w, h, r)
    local rad = math.min(r, w / 2, h / 2)
    cairo_new_sub_path(cr)
    cairo_arc(cr, x + w - rad, y + rad, rad, -math.pi / 2, 0)
    cairo_arc(cr, x + w - rad, y + h - rad, rad, 0, math.pi / 2)
    cairo_arc(cr, x + rad, y + h - rad, rad, math.pi / 2, math.pi)
    cairo_arc(cr, x + rad, y + rad, rad, math.pi, 3 * math.pi / 2)
    cairo_close_path(cr)
end

local function draw_card_background(cr)
    -- Base steel-blue frosted-glass gradient
    rounded_rect(cr, CARD_X, CARD_Y, CARD_W, CARD_H, CARD_R)
    local bg = cairo_pattern_create_linear(CARD_X, CARD_Y, CARD_X + CARD_W * 0.45, CARD_Y + CARD_H)
    cairo_pattern_add_color_stop_rgba(bg, 0.0, 0.175, 0.255, 0.340, 0.62)
    cairo_pattern_add_color_stop_rgba(bg, 0.5, 0.125, 0.195, 0.270, 0.58)
    cairo_pattern_add_color_stop_rgba(bg, 1.0, 0.095, 0.155, 0.220, 0.65)
    cairo_set_source(cr, bg)
    cairo_fill_preserve(cr)
    cairo_pattern_destroy(bg)

    -- Soft top-edge glass sheen clipped inside card
    cairo_save(cr)
    cairo_clip_preserve(cr)
    local sheen = cairo_pattern_create_linear(CARD_X, CARD_Y, CARD_X, CARD_Y + CARD_H * 0.32)
    cairo_pattern_add_color_stop_rgba(sheen, 0.0, 1.0, 1.0, 1.0, 0.12)
    cairo_pattern_add_color_stop_rgba(sheen, 0.55, 1.0, 1.0, 1.0, 0.03)
    cairo_pattern_add_color_stop_rgba(sheen, 1.0, 1.0, 1.0, 1.0, 0.0)
    cairo_set_source(cr, sheen)
    cairo_paint(cr)
    cairo_pattern_destroy(sheen)
    cairo_restore(cr)

    -- Subtle outer dark definition + crisp inner glass rim
    cairo_set_line_width(cr, 1.0)
    cairo_set_source_rgba(cr, 0.02, 0.05, 0.09, 0.30)
    cairo_stroke(cr)

    rounded_rect(cr, CARD_X + 1, CARD_Y + 1, CARD_W - 2, CARD_H - 2, CARD_R - 1)
    local rim = cairo_pattern_create_linear(CARD_X, CARD_Y, CARD_X, CARD_Y + CARD_H)
    cairo_pattern_add_color_stop_rgba(rim, 0.0, 1.0, 1.0, 1.0, 0.28)
    cairo_pattern_add_color_stop_rgba(rim, 0.3, 1.0, 1.0, 1.0, 0.14)
    cairo_pattern_add_color_stop_rgba(rim, 1.0, 1.0, 1.0, 1.0, 0.08)
    cairo_set_source(cr, rim)
    cairo_set_line_width(cr, 1.0)
    cairo_stroke(cr)
    cairo_pattern_destroy(rim)
end

local function set_font(cr, size, bold)
    local weight = bold and CAIRO_FONT_WEIGHT_BOLD or CAIRO_FONT_WEIGHT_NORMAL
    cairo_select_font_face(cr, FONT_FAMILY, CAIRO_FONT_SLANT_NORMAL, weight)
    cairo_set_font_size(cr, size)
end

local function measure_width(cr, text)
    if not text_ext or text == '' then return 0 end
    cairo_text_extents(cr, text, text_ext)
    return text_ext.x_advance
end

local function draw_text(cr, x, y, text, size, bold, align, color_rgba, shadow_dy)
    if not text or text == '' then return end
    set_font(cr, size, bold)
    local draw_x = x
    if align == 'right' then
        draw_x = x - measure_width(cr, text)
    end
    local sdy = shadow_dy or 1.2
    cairo_set_source_rgba(cr, 0.0, 0.02, 0.05, 0.45)
    cairo_move_to(cr, draw_x, y + sdy)
    cairo_show_text(cr, text)

    local c = color_rgba or { 0.965, 0.976, 0.992, 0.96 }
    cairo_set_source_rgba(cr, c[1], c[2], c[3], c[4])
    cairo_move_to(cr, draw_x, y)
    cairo_show_text(cr, text)
end

-- Draw mixed normal + dimmed segments left-to-right or right-aligned
local function draw_segments(cr, x, y, size, bold, align, segs)
    set_font(cr, size, bold)
    local total_w = 0
    if align == 'right' then
        for _, seg in ipairs(segs) do
            total_w = total_w + measure_width(cr, seg[1])
        end
    end
    local cur_x = (align == 'right') and (x - total_w) or x
    for _, seg in ipairs(segs) do
        local txt = seg[1]
        if txt and txt ~= '' then
            draw_text(cr, cur_x, y, txt, size, bold, 'left', seg[2])
            cur_x = cur_x + measure_width(cr, txt)
        end
    end
end

local function draw_bar(cr, x, y, w, h, ratio)
    local r = h / 2
    local pct = math.max(0, math.min(1, ratio or 0))
    rounded_rect(cr, x, y, w, h, r)
    cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.22)
    cairo_fill(cr)

    if pct > 0.002 then
        local fw = math.max(h, w * pct)
        rounded_rect(cr, x, y, fw, h, r)
        cairo_set_source_rgba(cr, 0.965, 0.980, 1.0, 0.92)
        cairo_fill(cr)
    end
end

local function draw_divider(cr, y)
    cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.18)
    cairo_set_line_width(cr, 1.0)
    cairo_move_to(cr, PAD_X, y + 0.5)
    cairo_line_to(cr, RIGHT_X, y + 0.5)
    cairo_stroke(cr)
end

local function fmt_net_speed(kbs, arrow)
    return string.format('%.2f MB/s %s', (kbs or 0) / 1024, arrow)
end

local function net_log_ratio(kbs)
    if not kbs or kbs < 0.05 then return 0 end
    return math.min(1.0, math.log(1 + kbs / 5) / math.log(1 + 100000 / 5))
end

-- ============================================================================
-- Main dashboard render
-- ============================================================================

local WHITE = { 0.965, 0.976, 0.992, 0.96 }
local SUB_WHITE = { 0.920, 0.945, 0.975, 0.90 }
local DIM_WHITE = { 0.824, 0.871, 0.925, 0.58 }

local function render_dashboard(cr)
    local d = state.data

    -- Clear drawable completely to preserve clean transparent corners
    cairo_save(cr)
    cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR)
    cairo_paint(cr)
    cairo_restore(cr)

    draw_card_background(cr)

    -- 1. CPU SECTION (y=24..102)
    draw_text(cr, PAD_X, 38, d.cpu_name, 14.5, true, 'left', WHITE)
    draw_text(cr, LEFT_BAR_RIGHT, 38, string.format('%d%%', math.floor(d.cpu_pct + 0.5)), 13.5, false, 'right', WHITE)
    draw_bar(cr, PAD_X, 48, LEFT_BAR_W, 5, d.cpu_pct / 100)

    draw_segments(cr, PAD_X, 78, 13, false, 'left', {
        { 'Power: ', SUB_WHITE },
        { d.cpu_power_w and string.format('%.1f W', d.cpu_power_w) or '-- W', d.cpu_power_w and SUB_WHITE or DIM_WHITE },
    })
    draw_segments(cr, GPU_COL2_X, 78, 13, false, 'left', {
        { 'Clock: ', SUB_WHITE },
        { d.cpu_freq_ghz and string.format('%.1f GHz', d.cpu_freq_ghz) or '-- GHz', d.cpu_freq_ghz and SUB_WHITE or DIM_WHITE },
    })

    local cpu_t_str = d.cpu_temp and string.format('%d°', math.floor(d.cpu_temp + 0.5)) or '--°'
    draw_text(cr, RIGHT_X, 75, cpu_t_str, 44, false, 'right', d.cpu_temp and WHITE or DIM_WHITE, 2.0)

    draw_divider(cr, 102)

    -- 2. GPU SECTION (y=118..236)
    draw_text(cr, PAD_X, 132, d.gpu_name, 14.5, true, 'left', WHITE)
    draw_text(cr, LEFT_BAR_RIGHT, 132, string.format('%d%%', math.floor(d.gpu_pct + 0.5)), 13.5, false, 'right', WHITE)
    draw_bar(cr, PAD_X, 142, LEFT_BAR_W, 5, d.gpu_pct / 100)

    local gpu_t_str = d.gpu_temp and string.format('%d°', math.floor(d.gpu_temp + 0.5)) or '--°'
    draw_text(cr, RIGHT_X, 169, gpu_t_str, 44, false, 'right', d.gpu_temp and WHITE or DIM_WHITE, 2.0)

    draw_segments(cr, PAD_X, 172, 13, false, 'left', {
        { 'Power: ', SUB_WHITE },
        { d.gpu_power_w and string.format('%.1f W', d.gpu_power_w) or '-- W', d.gpu_power_w and SUB_WHITE or DIM_WHITE },
    })
    draw_segments(cr, GPU_COL2_X, 172, 13, false, 'left', {
        { 'Core: ', SUB_WHITE },
        { d.gpu_clock_mhz and string.format('%d MHz', math.floor(d.gpu_clock_mhz + 0.5)) or '-- MHz', d.gpu_clock_mhz and SUB_WHITE or DIM_WHITE },
    })

    draw_segments(cr, PAD_X, 194, 13, false, 'left', {
        { 'MemClk: ', SUB_WHITE },
        { d.gpu_mem_clock_mhz and string.format('%d MHz', math.floor(d.gpu_mem_clock_mhz + 0.5)) or '-- MHz', d.gpu_mem_clock_mhz and SUB_WHITE or DIM_WHITE },
    })
    draw_segments(cr, GPU_COL2_X, 194, 13, false, 'left', {
        { 'Mem°: ', SUB_WHITE },
        { d.gpu_mem_temp and string.format('%d°', math.floor(d.gpu_mem_temp + 0.5)) or '--', d.gpu_mem_temp and SUB_WHITE or DIM_WHITE },
    })

    if d.gpu_vram_used_gb and d.gpu_vram_total_gb then
        local vram_txt = string.format('VRAM: %.1f / %.1f GB  (%.1f%%)', d.gpu_vram_used_gb, d.gpu_vram_total_gb, d.gpu_vram_pct or 0)
        draw_text(cr, PAD_X, 216, vram_txt, 13, false, 'left', SUB_WHITE)
    else
        draw_text(cr, PAD_X, 216, 'VRAM: -- / -- GB', 13, false, 'left', DIM_WHITE)
    end

    draw_divider(cr, 236)

    -- 3. RAM SECTION (y=252..324)
    draw_text(cr, PAD_X, 266, 'RAM', 14.5, true, 'left', WHITE)
    if #d.ram_temps > 0 then
        local t_parts = {}
        for _, t in ipairs(d.ram_temps) do
            table.insert(t_parts, string.format('%.1f°', t))
        end
        draw_text(cr, RIGHT_X, 266, 'Temp: ' .. table.concat(t_parts, ' / '), 13, false, 'right', SUB_WHITE)
    else
        draw_segments(cr, RIGHT_X, 266, 13, false, 'right', {
            { 'Temp: ', SUB_WHITE },
            { '-- / --', DIM_WHITE },
        })
    end

    draw_text(cr, PAD_X, 290, string.format('%.1f GB / %.1f GB', d.ram_used_gb, d.ram_total_gb), 13, false, 'left', SUB_WHITE)
    draw_text(cr, RIGHT_X, 290, string.format('%d%%', d.ram_pct), 13, false, 'right', WHITE)
    draw_bar(cr, PAD_X, 300, INNER_W, 5, d.ram_pct / 100)

    draw_divider(cr, 324)

    -- 4. NETWORK SECTION (y=340..412)
    draw_text(cr, PAD_X, 354, 'NETWORK', 14.5, true, 'left', WHITE)
    draw_text(cr, PAD_X, 378, fmt_net_speed(d.net_rx_kbs, '↓'), 13, false, 'left', SUB_WHITE)
    draw_text(cr, RIGHT_X, 378, fmt_net_speed(d.net_tx_kbs, '↑'), 13, false, 'right', SUB_WHITE)
    draw_bar(cr, PAD_X, 388, NET_BAR_W, 5, net_log_ratio(d.net_rx_kbs))
    draw_bar(cr, PAD_X + NET_BAR_W + NET_GAP, 388, NET_BAR_W, 5, net_log_ratio(d.net_tx_kbs))

    draw_divider(cr, 412)

    -- 5. DISKS SECTION (y=428..508)
    draw_text(cr, PAD_X, 442, 'DISKS', 14.5, true, 'left', WHITE)
    for idx, disk in ipairs(d.disks) do
        if idx > 2 then break end
        local row_y = (idx == 1) and 466 or 489
        local segs = {
            { disk.brand .. ': ', SUB_WHITE },
            { disk.temp_c and string.format('%d°', disk.temp_c) or '--°', disk.temp_c and SUB_WHITE or DIM_WHITE },
            { ' (寿命', SUB_WHITE },
            { disk.health_pct and string.format('%d%%', disk.health_pct) or '--%', disk.health_pct and SUB_WHITE or DIM_WHITE },
            { ')', SUB_WHITE },
        }
        draw_segments(cr, PAD_X, row_y, 13, false, 'left', segs)
        draw_text(cr, DISK_R_X, row_y, string.format('R %.1f MB/s', disk.read_mbs or 0), 13, false, 'right', SUB_WHITE)
        draw_text(cr, RIGHT_X, row_y, string.format('W %.1f MB/s', disk.write_mbs or 0), 13, false, 'right', SUB_WHITE)
    end

    draw_divider(cr, 508)

    -- 6. BATTERY SECTION (y=524..568)
    draw_text(cr, PAD_X, 538, 'BATTERY', 14.5, true, 'left', WHITE)
    if d.bat_pct ~= nil then
        local bat_left = string.format('%d%%  |  %.1f W', math.floor(d.bat_pct + 0.5), d.bat_power_w or 0)
        local bat_right = string.format('Chg %.2fA  |  Dchg %.2fA', d.bat_chg_a or 0, d.bat_dchg_a or 0)
        draw_text(cr, PAD_X, 561, bat_left, 13, false, 'left', SUB_WHITE)
        draw_text(cr, RIGHT_X, 561, bat_right, 13, false, 'right', SUB_WHITE)
    else
        draw_text(cr, PAD_X, 561, 'Battery unavailable', 13, false, 'left', DIM_WHITE)
    end
end

function conky_startup()
    state.last_gpu_spawn = get_uptime()
    local stat_line = read_line('/proc/self/stat')
    local self_pid = stat_line and stat_line:match('^(%d+)')
    if self_pid then
        os.execute('/usr/bin/python3 "' .. GPU_DAEMON_SCRIPT .. '"' .. ' --ppid ' .. self_pid .. ' >/tmp/conky-gpu-daemon.log 2>&1 </dev/null &')
    end
end

function conky_shutdown()
    local pid_str = trim(read_line(GPU_PID_PATH))
    if pid_str ~= '' and pid_str:match('^%d+$') then
        os.execute('kill -TERM ' .. pid_str .. ' 2>/dev/null')
    end
end

function conky_mouse_hook(event)
    if type(event) ~= 'table' then return false end
    if event.type == 'button_down' and (event.button == 'left' or event.button == 1 or event.button_code == 1) then
        local now = get_uptime()
        if now - state.last_drag_launch < 0.15 then
            return true
        end
        state.last_drag_launch = now
        local arg_str = ''
        if type(event.x_abs) == 'number' and type(event.y_abs) == 'number' then
            arg_str = string.format(' %d %d', math.floor(event.x_abs + 0.5), math.floor(event.y_abs + 0.5))
        end
        os.execute('/usr/bin/python3 "' .. DRAG_HELPER_SCRIPT .. '"' .. arg_str .. ' >/tmp/conky-drag.log 2>&1 </dev/null &')
        return true
    end
    return false
end

function conky_draw_dashboard()
    if conky_window == nil then return end

    local updates = tonumber(conky_parse('${updates}')) or 0
    if updates ~= state.last_updates then
        state.last_updates = updates
        update_sensors()
    end

    local cs = cairo_xlib_surface_create(
        conky_window.display,
        conky_window.drawable,
        conky_window.visual,
        conky_window.width,
        conky_window.height
    )
    local cr = cairo_create(cs)

    local ok, err = pcall(render_dashboard, cr)
    if not ok then
        io.stderr:write('[dashboard.lua] render error: ' .. tostring(err) .. '\n')
    end

    cairo_destroy(cr)
    cairo_surface_destroy(cs)
end
