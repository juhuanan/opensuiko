-- findbuilder.lua: natural-boot scene-builder trace.
-- Drives the full walkthrough (boot -> FMV skip -> title -> New Game ->
-- name "A" -> Yes), then traces WHICH code builds the visible scene:
--   * tag dispatcher 0x800C4FE0: tag histogram (who processes .8 records)
--   * drawlist_a_build 0x80137514 / drawlist_c_build 0x80137A90: caller ra
--   * draw dispatch 0x80131B90: per-frame hit counter
--   * master 1 0x800C6174: caller ra
--   * entries region 0x80179F08 (8KB): FNV hash every 300f after MAIN.EXE entry
local ffi = require('ffi')
local bit = require('bit')

local OUT     = os.getenv('SUIKODEN_OUT') or '/tmp/fb/fb.csv'
local OUTDIR  = OUT:match('^(.*)/[^/]*$')
local SHOTDIR = OUTDIR .. '/shots'
os.execute('mkdir -p "' .. SHOTDIR .. '"')

local CB_PTR = 0x800B1938
local FMV_CB   = 0x80017BE8
local TITLE_CB = 0x80018488
local MENU_CB  = 0x80016530
local CRT0     = 0x801479A8
local TAGDISP  = 0x800C4FE0
local BLDA     = 0x80137514
local BLDC     = 0x80137A90
local DRAWDISP = 0x80131B90
local MASTER1  = 0x800C6174
local ENTRIES  = 0x80179F08
local ENTRIES_LEN = 8192

local RAM  = ffi.cast('uint32_t *', PCSX.getMemPtr())
local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local function u32(addr) return tonumber(RAM[bit.rshift(bit.band(addr, 0x1FFFFFFF), 2)]) end
local function cb() local ok, v = pcall(u32, CB_PTR); return ok and v or 0 end
local function norm(v) return bit.band(tonumber(v) or 0, 0xFFFFFFFF) end

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

-- ---- scene-builder watchers ----
local tag_hist = {}
local disp_hits = 0
local DISP_CAP = 20000
local blda_hits, bldc_hits, m1_hits = 0, 0, 0
local blda_ra, bldc_ra, m1_ra = {}, {}, {}
local drawdisp_hits = 0
local mainexe_entered = false
local last_hash = 0
local hash_log_n = 0

local function fnv_region(base, len)
    local h = 0x811C9DC5
    local p = bit.band(base, 0x1FFFFFFF)
    for i = 0, len - 1 do
        h = bit.bxor(h, tonumber(RAMB[p + i]))
        h = bit.band(h * 0x01000193, 0xFFFFFFFF)
    end
    return h
end

local function regs()
    local ok, r = pcall(PCSX.getRegisters)
    if not ok or not r then return nil end
    return r
end
local function greg(r, name)
    if r and r.GPR and r.GPR.n then
        local ok, v = pcall(function() return r.GPR.n[name] end)
        if ok then return norm(v) end
    end
    return 0
end

local function arm_watchers()
    -- tag dispatcher: histogram
    local ok, bp = pcall(PCSX.addBreakpoint, TAGDISP, 'Exec', 4, 'tagdisp', function()
        if disp_hits >= DISP_CAP then return end
        disp_hits = disp_hits + 1
        local r = regs()
        local tag = bit.band(greg(r, 'a0'), 0xFFFF)
        tag_hist[tag] = (tag_hist[tag] or 0) + 1
    end)
    log('bp', 'tagdisp ' .. (ok and 'armed' or 'FAILED'))
    _G.FB_BP1 = bp
    -- drawlist_a_build: caller
    local ok2, bp2 = pcall(PCSX.addBreakpoint, BLDA, 'Exec', 4, 'blda', function()
        if blda_hits >= 20 then return end
        blda_hits = blda_hits + 1
        local r = regs()
        local ra = greg(r, 'ra')
        blda_ra[ra] = (blda_ra[ra] or 0) + 1
        log('blda', string.format('hit=%d ra=%08x', blda_hits, ra))
    end)
    log('bp', 'blda ' .. (ok2 and 'armed' or 'FAILED'))
    _G.FB_BP2 = bp2
    -- drawlist_c_build: caller
    local ok3, bp3 = pcall(PCSX.addBreakpoint, BLDC, 'Exec', 4, 'bldc', function()
        if bldc_hits >= 20 then return end
        bldc_hits = bldc_hits + 1
        local r = regs()
        local ra = greg(r, 'ra')
        bldc_ra[ra] = (bldc_ra[ra] or 0) + 1
        log('bldc', string.format('hit=%d ra=%08x', bldc_hits, ra))
    end)
    log('bp', 'bldc ' .. (ok3 and 'armed' or 'FAILED'))
    _G.FB_BP3 = bp3
    -- draw dispatch: counter only
    local ok4, bp4 = pcall(PCSX.addBreakpoint, DRAWDISP, 'Exec', 4, 'drawdisp', function()
        drawdisp_hits = drawdisp_hits + 1
    end)
    log('bp', 'drawdisp ' .. (ok4 and 'armed' or 'FAILED'))
    _G.FB_BP4 = bp4
    -- master 1: caller
    local ok5, bp5 = pcall(PCSX.addBreakpoint, MASTER1, 'Exec', 4, 'master1', function()
        if m1_hits >= 10 then return end
        m1_hits = m1_hits + 1
        local r = regs()
        local ra = greg(r, 'ra')
        m1_ra[ra] = (m1_ra[ra] or 0) + 1
        log('master1', string.format('hit=%d ra=%08x', m1_hits, ra))
    end)
    log('bp', 'master1 ' .. (ok5 and 'armed' or 'FAILED'))
    _G.FB_BP5 = bp5
    last_hash = fnv_region(ENTRIES, ENTRIES_LEN)
    log('entries_hash', string.format('initial=%08x', last_hash))
end

local function arm_crt0()
    local ok, bp = pcall(PCSX.addBreakpoint, CRT0, 'Exec', 4, 'crt0', function()
        if mainexe_entered then return end
        mainexe_entered = true
        log('mainexe_entry', string.format('frame=%d', frame))
        arm_watchers()
    end)
    log('bp', 'crt0 ' .. (ok and 'armed' or 'FAILED'))
    _G.FB_BP0 = bp
end

local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if not ok or not ss or not ss.data then log('shot_fail', tag); return end
    local path = string.format('%s/fb_%s.raw', SHOTDIR, tag)
    local wf = Support.File.open(path, 'TRUNCATE')
    wf:writeMoveSlice(ss.data); wf:close()
    local mf = io.open(string.format('%s/fb_%s.meta', SHOTDIR, tag), 'w')
    if mf then
        mf:write(string.format('width=%s height=%s bpp=%s\n', tostring(ss.width), tostring(ss.height), tostring(ss.bpp)))
        mf:close()
    end
    log('shot', tag)
end

-- ---- input phases (from walkthrough.lua) ----
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
            wait_until(confirm, 900, function() log('confirmed', desc); next() end,
                function()
                    if tries < 2 then log('retry', desc); wait(120, attempt)
                    else finish('ABORT: ' .. desc) end
                end)
        end)
    end
    attempt()
end

local function p_inroom()
    shot('inroom')
    -- final report
    log('report', string.format('disp_hits=%d drawdisp_hits=%d', disp_hits, drawdisp_hits))
    -- tag histogram: top tags
    local tags = {}
    for t, c in pairs(tag_hist) do tags[#tags+1] = {t, c} end
    table.sort(tags, function(a, b) return a[2] > b[2] end)
    for i = 1, math.min(25, #tags) do
        log('taghist', string.format('%04x x%d', tags[i][1], tags[i][2]))
    end
    log('report', string.format('distinct_tags=%d', #tags))
    for ra, c in pairs(blda_ra) do log('blda_callers', string.format('ra=%08x x%d', ra, c)) end
    for ra, c in pairs(bldc_ra) do log('bldc_callers', string.format('ra=%08x x%d', ra, c)) end
    for ra, c in pairs(m1_ra) do log('m1_callers', string.format('ra=%08x x%d', ra, c)) end
    finish('trace complete')
end

local function p_after_yes()
    log('loading', 'waiting 6000f (CRT0 watcher armed at boot)')
    wait(6000, function() p_inroom() end)
end

local function p_okprompt()
    tap(B.CROSS, 12, function() wait(800, function() p_after_yes() end) end)
end
local function p_nameentry()
    tap(B.CROSS, 12, function()
        wait(400, function()
            tap(B.START, 12, function() wait(600, function() p_okprompt() end) end)
        end)
    end)
end
local function p_startmenu()
    wait(500, function()
        tap(B.UP, 12, function()
            wait(200, function()
                tap(B.CROSS, 12, function() wait(600, function() p_nameentry() end) end)
            end)
        end)
    end)
end
local function p_boot()
    wait_until(function() return frame > 3500 and cb() == FMV_CB end, 20000,
        function()
            press_confirm(B.START, 'fmv-skip-START', function() return cb() == TITLE_CB end,
                function()
                    wait(600, function()
                        press_confirm(B.START, 'title-START', function() return cb() == MENU_CB end, p_startmenu)
                    end)
                end)
        end,
        function() finish('ABORT: FMV phase not seen') end)
end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    -- entries-region hash sampling after MAIN.EXE entry
    if mainexe_entered and frame % 300 == 0 then
        local h = fnv_region(ENTRIES, ENTRIES_LEN)
        if h ~= last_hash then
            hash_log_n = hash_log_n + 1
            log('entries_hash', string.format('changed %08x -> %08x', last_hash, h))
            last_hash = h
        end
    end
    if mainexe_entered and frame % 1200 == 0 then
        log('progress', string.format('disp=%d drawdisp=%d blda=%d bldc=%d m1=%d',
            disp_hits, drawdisp_hits, blda_hits, bldc_hits, m1_hits))
    end
    for i = #queue, 1, -1 do
        if queue[i].at <= frame then
            local item = table.remove(queue, i)
            local ok, err = pcall(item.fn)
            if not ok then log('queue_error', tostring(err)) end
        end
    end
    if frame >= 30000 then finish('frame budget exhausted') end
end)
ANCHORS = {}
ANCHORS[#ANCHORS + 1] = vl
_G.FB_PAD = PAD
log('start', 'findbuilder running')
-- arm CRT0 watcher EARLY: MAIN.EXE entry happens fast after Yes (~6800f),
-- well before p_after_yes (~7500f)
local _arm_t = 0
local vl2 = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    _arm_t = _arm_t + 1
    if _arm_t == 60 then
        log('boot', 'arming CRT0 watcher early')
        arm_crt0()
    end
end)
ANCHORS[#ANCHORS + 1] = vl2
p_boot()
