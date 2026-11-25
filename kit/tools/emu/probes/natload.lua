-- natload.lua: trace the NATURAL palace load during MAIN.EXE boot.
-- Runs the proven walkthrough input sequence, then instruments the
-- MAIN.EXE area loader (0x800C7E10 state machine) per-frame to capture
-- exactly how a natural load terminates.
--
-- Logs: loader state 0x80179C04, cursor 0x80179CE8, BF3/BF4, resume flag
-- 0x80179C90, saved cursor 0x80179C98, 0x80179C0C/0x80179C0E, gate 0x80179CF8,
-- entry+6/+8 for the active index.
local ffi = require('ffi')
local bit = require('bit')

local OUT     = os.getenv('SUIKODEN_OUT') or '/tmp/natload.csv'
local OUTDIR  = OUT:match('^(.*)/[^/]*$')
local SHOTDIR = OUTDIR .. '/shots'
os.execute('mkdir -p "' .. SHOTDIR .. '"')

local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local RAMW = ffi.cast('uint32_t *', PCSX.getMemPtr())
local RAMH = ffi.cast('uint16_t *', PCSX.getMemPtr())
local function u8(a) return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) end
local function u16(a) return tonumber(RAMH[bit.rshift(bit.band(a, 0x1FFFFFFF), 1)]) end
local function u32(a) return tonumber(RAMW[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)]) end
local function u32safe(a)
    local ok, v = pcall(u32, a)
    return ok and v or 0
end

-- walkthrough input machinery (proven sequence)
local CB_PTR = 0x800B1938
local FMV_CB   = 0x80017BE8
local TITLE_CB = 0x80018488
local MENU_CB  = 0x80016530
local RAM32 = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u32r(addr) return tonumber(RAM32[bit.rshift(bit.band(addr, 0x1FFFFFFF), 2)]) end
local function cb() local ok, v = pcall(u32r, CB_PTR); return ok and v or 0 end
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local frame = 0
local queue = {}
local logf = assert(io.open(OUT, 'w'))
logf:write('frame,event,detail\n')
local function log(event, detail)
    logf:write(string.format('%d,%s,%s\n', frame, event, tostring(detail or '')))
    logf:flush()
end
local function after(n, fn) queue[#queue + 1] = { at = frame + n, fn = fn } end
local function wait(n, next) after(n, next) end
local function tap(btn, hold, next)
    PAD.setOverride(btn)
    wait(hold, function() PAD.clearOverride(btn); wait(10, next) end)
end
local done = false
local function finish(msg)
    if done then return end
    done = true
    log('finish', msg)
    logf:close()
    PCSX.quit(0)
end
local function wait_until(cond, T, ok_fn, timeout_fn)
    local t = 0
    local function tick()
        if done then return end
        t = t + 1
        local okc, res = pcall(cond)
        if okc and res then ok_fn()
        elseif t >= T then timeout_fn()
        else wait(1, tick) end
    end
    tick()
end
local function press_confirm(btn, desc, confirm, next)
    local tries = 0
    local function attempt()
        tries = tries + 1
        tap(btn, 12, function()
            wait_until(confirm, 900, next, function()
                if tries < 2 then wait(120, attempt)
                else finish('ABORT: ' .. desc) end
            end)
        end)
    end
    attempt()
end

-- loader monitor addresses (MAIN.EXE region)
local A_BF3, A_BF4 = 0x80179BF3, 0x80179BF4
local A_LS, A_CUR = 0x80179C04, 0x80179CE8
local A_RFLG, A_SAVCUR = 0x80179C90, 0x80179C98
local A_C0C, A_C0E, A_CF8 = 0x80179C0C, 0x80179C0E, 0x80179CF8
local A_ETAB = 0x80164E68

local function entry_field(idx, off)
    return u16(A_ETAB + idx * 12 + off)
end

local mon_active = false
local last = {}
local function mkey()
    return string.format('%d|%d|%d|%d|%d|%d|%d|%d|%d',
        u8(A_BF3), u8(A_BF4), u8(A_LS), u32safe(A_CUR),
        u8(A_RFLG), u32safe(A_SAVCUR), u16(A_C0C), u16(A_C0E), u8(A_CF8))
end
local idle_frames = 0
local saw_load = false
local mon_start = 0

local function loader_monitor()
    -- called every vsync once MAIN.EXE may be up
    local k = mkey()
    if k ~= last.k then
        local idx = u8(A_BF3)
        local detail = string.format(
            'bf3=%d bf4=%d ls=%d cur=%d rflg=%d savcur=%d c0c=%d c0e=%d cf8=%d e6=%d e8=%d',
            u8(A_BF3), u8(A_BF4), u8(A_LS), u32safe(A_CUR),
            u8(A_RFLG), u32safe(A_SAVCUR), u16(A_C0C), u16(A_C0E), u8(A_CF8),
            entry_field(idx, 6), entry_field(idx, 8))
        log('load', detail)
        last.k = k
    end
    local active = (u8(A_BF3) ~= 0) or (u8(A_LS) ~= 0)
    if active then saw_load = true; idle_frames = 0
    elseif saw_load then
        idle_frames = idle_frames + 1
        if idle_frames == 1 then
            log('load_end', string.format(
                'bf3=%d ls=%d cur=%d rflg=%d savcur=%d c0c=%d cf8=%d',
                u8(A_BF3), u8(A_LS), u32safe(A_CUR),
                u8(A_RFLG), u32safe(A_SAVCUR), u16(A_C0C), u8(A_CF8)))
        end
        if idle_frames > 600 then
            log('terminated', 'loader idle 600f after natural load')
            -- screenshot the room
            local ok, ss = pcall(PCSX.GPU.takeScreenShot)
            if ok and ss and ss.data then
                local wf = Support.File.open(SHOTDIR .. '/nat_room.raw', 'TRUNCATE')
                wf:writeMoveSlice(ss.data); wf:close()
                local mf = io.open(SHOTDIR .. '/nat_room.meta', 'w')
                if mf then mf:write(string.format('width=%s height=%s bpp=%s\n',
                    tostring(ss.width), tostring(ss.height), tostring(ss.bpp))); mf:close() end
            end
            finish('natural load traced')
        end
    end
    if frame - mon_start > 30000 then
        finish('monitor timeout')
    end
end

-- phases (from proven walkthrough)
local function p_monitor()
    log('monitor_start', 'watching MAIN.EXE loader')
    mon_start = frame
    mon_active = true
end
local function p_after_yes()
    log('loading', 'MAIN.EXE chain-boot; starting loader monitor')
    wait(400, p_monitor)  -- give MAIN.EXE a moment to load
end
local function p_okprompt()
    tap(B.CROSS, 12, function() wait(800, p_after_yes) end)
end
local function p_nameentry()
    tap(B.CROSS, 12, function()
        wait(400, function()
            tap(B.START, 12, function() wait(600, p_okprompt) end)
        end)
    end)
end
local function p_startmenu()
    wait(500, function()
        tap(B.UP, 12, function()
            wait(200, function()
                tap(B.CROSS, 12, function() wait(600, p_nameentry) end)
            end)
        end)
    end)
end
local function p_boot()
    wait_until(function() return frame > 3500 and cb() == FMV_CB end, 20000,
        function()
            press_confirm(B.START, 'fmv-skip', function() return cb() == TITLE_CB end,
                function()
                    wait(600, function()
                        press_confirm(B.START, 'title', function() return cb() == MENU_CB end, p_startmenu)
                    end)
                end)
        end,
        function() finish('ABORT: FMV not seen') end)
end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    for i = #queue, 1, -1 do
        if queue[i].at <= frame then
            local item = table.remove(queue, i)
            local ok, err = pcall(item.fn)
            if not ok then log('queue_error', tostring(err)) end
        end
    end
    if mon_active then
        local ok, err = pcall(loader_monitor)
        if not ok then log('mon_error', tostring(err)) end
    end
    if frame >= 60000 then finish('frame budget exhausted') end
end)
_G.NL_ANCHOR = vl
_G.NL_PAD = PAD
log('start', 'natload running')
p_boot()
