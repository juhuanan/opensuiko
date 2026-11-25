-- walkthrough6.lua (FINAL)
--
-- Full path to in-game save state:
--   boot -> FMV (frame 3500) -> START (skip) -> title (0x80018488) ->
--   verify rendered -> START -> menu (0x80016530) -> UP (New game) ->
--   CROSS -> name entry -> CROSS (A) -> START (confirm) -> OK? ->
--   CROSS (Yes) -> MAIN.EXE loads ("NOW LOADING") -> in-game room ->
--   save state via FFI.
--
-- Key lessons baked in:
--   * 0x80017BE8 = logo/FMV player; any button skips to title.
--   * 0x80018488 = title "PRESS START"; START -> menu.
--   * 0x80016530 = start menu AND name entry (cb doesn't change).
--   * Menu cursor defaults to "Continue game"; UP -> "New game".
--   * Name entry: CROSS appends highlighted letter, START confirms.
--   * "Yes" triggers MAIN.EXE chain-boot (size 0xB8800, LBA 17977).
--   * After MAIN.EXE loads, 0x800B1938 is garbage; use timing.
--   * Save via FFI (ss.data + ss.size), NOT writeMoveSlice (broken >4KB).

local ffi = require('ffi')
local bit = require('bit')

local OUT     = os.getenv('SUIKODEN_OUT') or '/tmp/walkthrough6.csv'
local FRAMES  = tonumber(os.getenv('SUIKODEN_FRAMES') or '40000')
local OUTDIR  = OUT:match('^(.*)/[^/]*$')
local SHOTDIR = OUTDIR .. '/shots'
local FIXDIR  = (os.getenv('SUIKODEN_FIXDIR') or (OUTDIR .. '/fixtures'))
os.execute('mkdir -p "' .. SHOTDIR .. '" "' .. FIXDIR .. '"')
local STATE_PATH = FIXDIR .. '/ingame.pcsxstate'

local CB_PTR = 0x800B1938
local FMV_CB   = 0x80017BE8
local TITLE_CB = 0x80018488
local MENU_CB  = 0x80016530

local RAM = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u32(addr)
    return tonumber(RAM[bit.rshift(bit.band(addr, 0x1FFFFFFF), 2)])
end
local function cb() local ok, v = pcall(u32, CB_PTR); return ok and v or 0 end

local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local ffi = require("ffi")
local RAM = ffi.cast("uint8_t *", PCSX.getMemPtr())
local frame = 0
local queue = {}
local logf = assert(io.open(OUT, 'w'))
logf:write('frame,event,detail\n')
local function log(event, detail)
    logf:write(string.format('%d,%s,%s\n', frame, event, tostring(detail or '')))
    logf:flush()
    PCSX.log(string.format('wt6: [%d] %s %s', frame, event, tostring(detail or '')))
end
local function after(n, fn) queue[#queue + 1] = { at = frame + n, fn = fn } end
local function wait(n, next) after(n, next) end

local shot_n = 0
local function shot(tag)
    shot_n = shot_n + 1
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if not ok or not ss or not ss.data then log('shot_fail', tag); return end
    local path = string.format('%s/w6_%03d_%s.raw', SHOTDIR, shot_n, tag)
    local wf = Support.File.open(path, 'TRUNCATE')
    wf:writeMoveSlice(ss.data)
    wf:close()
    local mf = io.open(string.format('%s/w6_%03d_%s.meta', SHOTDIR, shot_n, tag), 'w')
    if mf then
        mf:write(string.format('width=%s height=%s bpp=%s\n', tostring(ss.width), tostring(ss.height), tostring(ss.bpp)))
        mf:close()
    end
    log('shot', string.format('%s cb=0x%08X', tag, cb()))
end

local function tap(btn, hold, next)
    PAD.setOverride(btn)
    wait(hold, function()
        PAD.clearOverride(btn)
        wait(10, next)
    end)
end

local done = false
local function finish(msg)
    if done then return end
    done = true
    log('finish', msg)
    logf:close()
    PCSX.quit(0)
end

local function save_state_ffi()
    log('save_state', STATE_PATH)
    local ok, err = pcall(function()
        local ss = PCSX.createSaveState()
        local size = ss.size
        local data = ffi.cast('const char*', ss.data)
        local f = assert(io.open(STATE_PATH, 'wb'))
        local CHUNK = 1024 * 1024
        local offset = 0
        while offset < size do
            local n = math.min(CHUNK, size - offset)
            f:write(ffi.string(data + offset, n))
            offset = offset + n
        end
        f:close()
        log('save_bytes', tostring(size))
    end)
    if not ok then
        log('save_failed', tostring(err))
    else
        local f = io.open(STATE_PATH, 'rb')
        local sz = f and f:seek('end') or -1
        if f then f:close() end
        log('save_filesize', tostring(sz))
    end
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
        log('press', string.format('%s try%d', desc, tries))
        tap(btn, 12, function()
            wait_until(confirm, 900, function()
                log('confirmed', desc)
                next()
            end, function()
                if tries < 2 then
                    log('retry', desc)
                    wait(120, attempt)
                else
                    shot('abort')
                    finish('ABORT: ' .. desc .. ' had no effect')
                end
            end)
        end)
    end
    attempt()
end

-- phases
local function p_inroom()
    shot('inroom')
    save_state_ffi()
    finish('in gameplay room, state saved')
end

local function p_after_yes()
    local dumpf = io.open(os.getenv("SUIKODEN_OUT") .. "_premainexe.bin", "wb")
    if dumpf then
        dumpf:write(ffi.string(RAM, 0x200000))
        dumpf:close()
        log("dump", "RAM dumped before MAIN.EXE load")
    end
    -- MAIN.EXE chain-boots here. Wait through "NOW LOADING" into the room.
    -- (wt8: room visible ~4100f after Yes; use 5500 for margin.)
    log('loading', 'waiting 5500f for MAIN.EXE boot')
    shot('nowloading')
    wait(5500, function() p_inroom() end)
end

local function p_okprompt()
    shot('okprompt')
    log('press', 'okprompt-CROSS (Yes)')
    tap(B.CROSS, 12, function()
        wait(800, function() p_after_yes() end)
    end)
end

local function p_nameentry()
    shot('nameentry')
    log('press', 'nameentry-CROSS (enter A)')
    tap(B.CROSS, 12, function()
        wait(400, function()
            shot('name_A')
            log('press', 'nameentry-START (confirm name)')
            tap(B.START, 12, function()
                wait(600, function() p_okprompt() end)
            end)
        end)
    end)
end

local function p_startmenu()
    wait(500, function()
        shot('startmenu')
        tap(B.UP, 12, function()
            wait(200, function()
                shot('menu_up')
                log('press', 'menu-NewGame CROSS')
                tap(B.CROSS, 12, function()
                    wait(600, function() p_nameentry() end)
                end)
            end)
        end)
    end)
end

local function p_boot()
    wait_until(function() return frame > 3500 and cb() == FMV_CB end, 20000,
        function()
            log('fmv_playing', 'pressing START to skip')
            shot('fmv')
            press_confirm(B.START, 'fmv-skip-START', function() return cb() == TITLE_CB end,
                function()
                    wait(600, function()
                        shot('title')
                        log('press', 'title-START')
                        press_confirm(B.START, 'title-START', function() return cb() == MENU_CB end, p_startmenu)
                    end)
                end)
        end,
        function() shot('abort'); finish('ABORT: FMV phase not seen') end)
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
    if frame >= FRAMES then finish('frame budget exhausted') end
end)
ANCHORS = {}
ANCHORS[#ANCHORS + 1] = vl
_G.WT6_PAD = PAD
log('start', 'walkthrough6 running')
p_boot()
