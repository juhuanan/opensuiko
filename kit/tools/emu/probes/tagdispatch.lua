-- tagdispatch.lua: hijack per-frame callback to dispatch 0x02xx tag once.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/td/td.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
os.execute('mkdir -p "' .. OUTDIR .. '"')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'

local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local RAMW = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u8(a) return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) end
local function w8(a, v) RAMB[bit.band(a, 0x1FFFFFFF)] = v end
local function w32(a, v) RAMW[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)] = v end
local function u32(a) return tonumber(RAMW[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)]) end

local STUB = 0x800B0000
local FLAG = 0x800B0100
local CB_PTR = 0x8017DA90
local DISP = 0x800C4FE0
local ORIG_CB = 0x800C98F0
local TAG = 0x020C  -- real tag from SHIRO1.8

local frame = 0
local done, loaded = false, false
local logf = assert(io.open(OUT, 'w'))
local function log(e, d) logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or ''))); logf:flush() end

local function write_stub()
    -- MIPS assembly (see comments in task)
    local insns = {
        0x3C08800B, -- lui $t0, 0x800B
        0x8D090100, -- lw $t1, 0x0100($t0)
        0x1520000C, -- bne $t1, $zero, restore (offset 12)
        0x00000000, -- nop
        0x34090001, -- ori $t1, $zero, 1
        0xAD090100, -- sw $t1, 0x0100($t0)
        0x27BDFFF8, -- addiu $sp, $sp, -8
        0xAFBF0004, -- sw $ra, 4($sp)
        0x3404020C, -- ori $a0, $zero, 0x020C
        0x3C19800C, -- lui $t9, 0x800C
        0x37394FE0, -- ori $t9, $t9, 0x4FE0
        0x0320F809, -- jalr $t9
        0x00000000, -- nop
        0x8FBF0004, -- lw $ra, 4($sp)
        0x27BD0008, -- addiu $sp, $sp, 8
        -- restore:
        0x3C19800C, -- lui $t9, 0x800C
        0x373998F0, -- ori $t9, $t9, 0x98F0
        0x03200008, -- jr $t9
        0x00000000, -- nop
    }
    for i, v in ipairs(insns) do
        w32(STUB + (i-1)*4, v)
    end
    w32(FLAG, 0)
    log('stub', string.format('written, orig_cb=%08x', u32(CB_PTR)))
    -- hijack
    w32(CB_PTR, STUB)
    log('hijack', 'callback redirected to stub')
end

local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(FIXDIR .. '/ingame.pcsxstate')
        pcall(function() PCSX.loadSaveState(f) end); f:close()
        log('loaded', 'ingame')
        write_stub()
        return
    end
    if not loaded then return end
    if frame == 120 then
        log('flag', string.format('flag=%d', u32(FLAG)))
        -- restore original callback
        w32(CB_PTR, ORIG_CB)
        log('restore', 'callback restored')
    end
    if frame == 600 then
        log('done', string.format('bf1tag=%d', u8(0x80179BF1)))
        done = true; logf:close(); PCSX.quit(0)
    end
end)
_G.TD_ANCHOR = vl
log('start', 'tagdispatch tag=020C')
