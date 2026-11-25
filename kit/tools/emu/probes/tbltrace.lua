-- tbltrace.lua: natural boot, catch WHO sets the draw-list table pointer
-- (0x8017BF98) and WHO writes the table contents.
-- Two-phase: write-bp on pointer var -> on next VSync read new table addr
-- -> arm write-bp on table base. One-shot each, log writer PCs.
local ffi = require('ffi')
local bit = require('bit')

local OUT     = os.getenv('SUIKODEN_OUT') or '/tmp/tt/tt.csv'
local OUTDIR  = OUT:match('^(.*)/[^/]*$')
os.execute('mkdir -p "' .. OUTDIR .. '"')

local CB_PTR = 0x800B1938
local FMV_CB   = 0x80017BE8
local TITLE_CB = 0x80018488
local MENU_CB  = 0x80016530
local TBLPTR = 0x8017BF98

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

local ptr_bp_fired = false
local tbl_bp_armed = false
local tbl_bp_fired = false
local pending_tbl_arm = false
local tbl_addr = 0

local function arm_table_bp(addr)
    if tbl_bp_armed then return end
    tbl_bp_armed = true
    tbl_addr = addr
    local ok, bp = pcall(PCSX.addBreakpoint, addr, 'Write', 4, 'tblwrite', function(acc, w)
        if tbl_bp_fired then return end
        tbl_bp_fired = true
        local r = regs()
        local pc = greg(r, 'pc')
        local ra = greg(r, 'ra')
        log('tbl_first_write', string.format('pc=%08x ra=%08x addr=%08x', pc, ra, norm(acc)))
    end)
    log('bp', string.format('tblwrite %s addr=%08x', ok and 'armed' or 'FAILED', norm(addr)))
    _G.TT_BP2 = bp
end

local CRT0 = 0x801479A8
local mainexe = false

local function arm_crt0()
    local ok, bp = pcall(PCSX.addBreakpoint, CRT0, 'Exec', 4, 'crt0', function()
        if mainexe then return end
        mainexe = true
        log('mainexe_entry', string.format('frame=%d', frame))
        -- NOTE: do NOT arm_ptr_bp() here: addBreakpoint from inside a bp
        -- handler silently fails. The VSync loop arms it next frame.
    end)
    log('bp', 'crt0 ' .. (ok and 'armed' or 'FAILED'))
    _G.TT_BP0 = bp
end

local function arm_ptr_bp()
    local ok, bp = pcall(PCSX.addBreakpoint, TBLPTR, 'Write', 4, 'tblptr', function(acc, w)
        if ptr_bp_fired then return end
        ptr_bp_fired = true
        local r = regs()
        local pc = greg(r, 'pc')
        local ra = greg(r, 'ra')
        log('ptr_write', string.format('pc=%08x ra=%08x', pc, ra))
        pending_tbl_arm = true
    end)
    log('bp', 'tblptr ' .. (ok and 'armed' or 'FAILED'))
    _G.TT_BP1 = bp
end

-- input phases (from findbuilder.lua)
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
            wait_until(confirm, 900, function() next() end,
                function()
                    if tries < 2 then wait(120, attempt)
                    else finish('ABORT: ' .. desc) end
                end)
        end)
    end
    attempt()
end
local function p_inroom()
    log('final', string.format('ptr_bp=%s tbl_bp=%s tbl_addr=%08x', tostring(ptr_bp_fired), tostring(tbl_bp_fired), norm(tbl_addr)))
    finish('trace complete')
end
local function p_after_yes()
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

local arm_t = 0
local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    arm_t = arm_t + 1
    if arm_t == 60 then arm_crt0() end
    if mainexe and not _G.TT_PTR_ARMED then
        _G.TT_PTR_ARMED = true
        arm_ptr_bp()
    end
    -- after ptr write, read the new table addr on next vsync and arm table bp
    if pending_tbl_arm then
        pending_tbl_arm = false
        local ok, v = pcall(u32, TBLPTR)
        if ok and v ~= 0 then
            log('tbl_ptr_value', string.format('%08x', norm(v)))
            arm_table_bp(norm(v))
        else
            log('tbl_ptr_value', 'zero-or-fail')
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
ANCHORS = {}
ANCHORS[#ANCHORS + 1] = vl
_G.TT_PAD = PAD
log('start', 'tbltrace running')
p_boot()
