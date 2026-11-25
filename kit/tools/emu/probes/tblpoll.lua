-- tblpoll.lua: natural boot, POLL (no write bps) for table ptr + table content writer.
-- Catches: setupdisp a0, ptr write (via poll), first table content change (via poll).
-- For table WRITER pc: use a one-shot EXEC bp on... we poll, so we get the frame.
-- Then to get the writer PC, we do a second run with an exec bp... (for now: just confirm fill timing)
local ffi = require('ffi')
local bit = require('bit')

local OUT     = os.getenv('SUIKODEN_OUT') or '/tmp/tp/tp.csv'
local OUTDIR  = OUT:match('^(.*)/[^/]*$')
os.execute('mkdir -p "' .. OUTDIR .. '"')

local CB_PTR   = 0x800B1938
local FMV_CB   = 0x80017BE8
local TITLE_CB = 0x80018488
local MENU_CB  = 0x80016530
local CRT0     = 0x801479A8
local SETUPDISP = 0x80131624
local SETUPTAB  = 0x8017DA94
local TBLPTR    = 0x8017BF98

local RAM  = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u32(addr)
    local ok, v = pcall(function() return RAM[bit.rshift(bit.band(addr, 0x1FFFFFFF), 2)] end)
    return ok and tonumber(v) or 0
end
local function cb() return u32(CB_PTR) end
local function norm(v) return bit.band(tonumber(v) or 0, 0xFFFFFFFF) end

local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local frame = 0
local queue = {}
local logf = assert(io.open(OUT, 'w'))
local function log(e, d)
    logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or '')))
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

local mainexe = false
local setup_a0, setup_fn = nil, nil
local ptr_seen, tbl_addr = false, 0
local tbl_filled = false

local function arm_setup_bp()
    local ok, bp = pcall(PCSX.addBreakpoint, SETUPDISP, 'Exec', 4, 'setupdisp', function()
        if setup_a0 then return end
        local r = regs()
        setup_a0 = greg(r, 'a0')
        local ra = greg(r, 'ra')
        setup_fn = 0
        if setup_a0 < 16 then setup_fn = norm(u32(SETUPTAB + setup_a0 * 4)) end
        log('setupdisp', string.format('a0=%d ra=%08x setupfn=%08x', setup_a0, ra, setup_fn))
    end)
    log('bp', 'setupdisp ' .. (ok and 'armed' or 'FAILED'))
    _G.TP_BP1 = bp
end

local function arm_crt0()
    local ok, bp = pcall(PCSX.addBreakpoint, CRT0, 'Exec', 4, 'crt0', function()
        if mainexe then return end
        mainexe = true
        log('mainexe_entry', string.format('frame=%d', frame))
    end)
    log('bp', 'crt0 ' .. (ok and 'armed' or 'FAILED'))
    _G.TP_BP0 = bp
end

-- input phases (same as setupidx)
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
        log('press', desc)
        tap(btn, 12, function()
            wait_until(confirm, 900, function() log('confirmed', desc); next() end,
                function()
                    if tries < 2 then wait(120, attempt)
                    else finish('ABORT: ' .. desc) end
                end)
        end)
    end
    attempt()
end
local function p_after_yes()
    -- poll for table fill; quit when filled or timeout
    wait(9000, function() finish('poll timeout: tbl_filled=' .. tostring(tbl_filled)) end)
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
            press_confirm(B.START, 'fmv-skip', function() return cb() == TITLE_CB end,
                function()
                    wait(600, function()
                        press_confirm(B.START, 'title-start', function() return cb() == MENU_CB end, p_startmenu)
                    end)
                end)
        end,
        function() finish('ABORT: FMV phase not seen') end)
end

local arm_t = 0
local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    arm_t = arm_t + 1
    if arm_t == 60 then arm_crt0() end
    if mainexe and not _G.TP_SETUP_ARMED then
        _G.TP_SETUP_ARMED = true
        arm_setup_bp()
    end
    -- poll table ptr + contents
    if mainexe and not ptr_seen then
        local p = norm(u32(TBLPTR))
        if p ~= 0 then
            ptr_seen = true
            tbl_addr = p
            log('ptr_poll', string.format('tbl=%08x', p))
        end
    end
    if ptr_seen and not tbl_filled and tbl_addr ~= 0 then
        -- check first 4 words of table
        local w0 = norm(u32(tbl_addr))
        local w1 = norm(u32(tbl_addr + 4))
        local w2 = norm(u32(tbl_addr + 8))
        local w3 = norm(u32(tbl_addr + 12))
        if w0 ~= 0 or w1 ~= 0 or w2 ~= 0 or w3 ~= 0 then
            tbl_filled = true
            log('tbl_fill', string.format('w0=%08x w1=%08x w2=%08x w3=%08x', w0, w1, w2, w3))
            finish('table filled')
        end
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
_TP_ANCH = vl
_G.TP_PAD = PAD
log('start', 'tblpoll running')
p_boot()
