-- nattrans.lua: invoke tag_dispatcher(0x0305) via MIPS stub, let natural flow run.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/nt/nt.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
os.execute('mkdir -p "' .. OUTDIR .. '"')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'
local TARGET = tonumber(os.getenv('SUIKODEN_TARGET_IDX') or '5')
local TAG = 0x0300 + TARGET

local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local RAMW = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u8(a) return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) end
local function w32(a, v) RAMW[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)] = v end

local frame = 0
local done, loaded = false, false
local invoked = false
local logf = assert(io.open(OUT, 'w'))
local function log(e, d) logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or ''))); logf:flush() end

local STUB = 0x800B0000
local DISP = 0x800C4FE0

local function write_stub()
    -- addiu sp,sp,-0x18; sw ra,0x10(sp); li a0,TAG; jal DISP; nop; lw ra; addiu sp; jr ra; nop
    -- li a0,TAG: lui a0,0; ori a0,a0,TAG (TAG < 0x10000)
    local insns = {
        0x27BDFFE8, -- addiu sp,sp,-24
        0xAFBF0010, -- sw ra,16(sp)
        0x3C040000, -- lui a0,0
        0x34840000 + TAG, -- ori a0,a0,TAG
        0x0C000000 + bit.rshift(DISP, 2), -- jal DISP
        0x00000000, -- nop
        0x8FBF0010, -- lw ra,16(sp)
        0x27BD0018, -- addiu sp,sp,24
        0x03E00008, -- jr ra
        0x00000000, -- nop
    }
    for i, v in ipairs(insns) do
        w32(STUB + (i-1)*4, v)
    end
    log('stub', string.format('written at %08x tag=%04x', STUB, TAG))
end

local function arm_invoke_bp()
    local ok, bp = pcall(PCSX.addBreakpoint, 0x800C9440, 'Exec', 4, 'perframe', function()
        if invoked then return end
        invoked = true
        local ok2, r = pcall(PCSX.getRegisters)
        if ok2 and r then
            local orig_pc = bit.band(tonumber(r.GPR.n.pc), 0xFFFFFFFF)
            log('invoke', string.format('orig_pc=%08x redirecting to stub', orig_pc))
            -- Set PC to stub, RA to orig_pc (so stub returns there)
            -- Use setRegisters if available
            local ok3, err = pcall(function()
                local nr = PCSX.getRegisters()
                nr.GPR.n.pc = STUB
                nr.GPR.n.ra = orig_pc
                PCSX.setRegisters(nr)
            end)
            if not ok3 then log('setreg_fail', tostring(err)) end
        end
    end)
    if not ok then log('bp_fail', 'perframe') else log('bp_ok', 'perframe armed') end
    _G.NT_BP = bp
end

local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(FIXDIR .. '/ingame.pcsxstate')
        pcall(function() PCSX.loadSaveState(f) end); f:close()
        log('loaded', string.format('bf3=%d', u8(0x80179BF3)))
        write_stub()
        arm_invoke_bp()
        return
    end
    if not loaded then return end
    if frame % 600 == 0 then
        log('status', string.format('bf1=%d bf3=%d pend=%d', u8(0x80179BEB), u8(0x80179BF3), u8(0x80179BEC)))
    end
    if frame >= 3600 then
        log('done', 'timeout')
        done = true; logf:close(); PCSX.quit(0)
    end
end)
_G.NT_ANCHOR = vl
log('start', string.format('nattrans target=%d tag=%04x', TARGET, TAG))
