-- trampoline.lua: Write MIPS trampoline to RAM, patch per-frame callback to invoke setup(2).
-- Tests if we can drive the scene pipeline manually.
-- Trampoline at 0x801FE000:
--   addiu $sp, $sp, -8
--   sw $ra, 4($sp)
--   addiu $a0, $zero, 2
--   jal 0x80132044
--   nop
--   lw $ra, 4($sp)
--   addiu $sp, $sp, 8
--   jr $ra
--   nop
local ffi = require('ffi')
local bit = require('bit')

local OUT     = os.getenv('SUIKODEN_OUT') or '/tmp/tr/tr.csv'
local OUTDIR  = OUT:match('^(.*)/[^/]*$')
os.execute('mkdir -p "' .. OUTDIR .. '"')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'

local TRAMP_ADDR = 0x801FE000
local CB_SLOT    = 0x8017DA90
local SETUP_FN   = 0x80132044

local RAMW = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function w32(addr, v)
    RAMW[bit.rshift(bit.band(addr, 0x1FFFFFFF), 2)] = bit.band(v, 0xFFFFFFFF)
end
local function u32(addr)
    local ok, v = pcall(function() return RAMW[bit.rshift(bit.band(addr, 0x1FFFFFFF), 2)] end)
    return ok and tonumber(v) or 0
end
local function norm(v) return bit.band(tonumber(v) or 0, 0xFFFFFFFF) end

-- MIPS trampoline words
local tramp = {
    0x27BDFFF8,  -- addiu $sp, $sp, -8
    0xAFBF0004,  -- sw $ra, 4($sp)
    0x24040002,  -- addiu $a0, $zero, 2
    0x0C04C811,  -- jal 0x80132044
    0x00000000,  -- nop
    0x8FBF0004,  -- lw $ra, 4($sp)
    0x27BD0008,  -- addiu $sp, $sp, 8
    0x03E00008,  -- jr $ra
    0x00000000,  -- nop
}

local frame = 0
local logf = assert(io.open(OUT, 'w'))
local function log(e, d)
    logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or '')))
    logf:flush()
end
local done = false
local function finish(msg)
    if done then return end
    done = true
    log('finish', msg)
    logf:close()
    PCSX.quit(0)
end

local orig_cb = 0
local phase = 0
local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and phase == 0 then
        phase = 1
        local f = Support.File.open(FIXDIR .. '/ingame.pcsxstate')
        pcall(function() PCSX.loadSaveState(f) end); f:close()
        log('state', 'ingame loaded')
    elseif frame == 120 and phase == 1 then
        phase = 2
        -- Write trampoline
        for i, w in ipairs(tramp) do
            w32(TRAMP_ADDR + (i-1)*4, w)
        end
        log('tramp', 'written to ' .. string.format('%08x', TRAMP_ADDR))
        -- Verify
        local v = norm(u32(TRAMP_ADDR))
        log('verify', string.format('first word=%08x (expect 27bdfff8)', v))
        -- Save and patch callback
        orig_cb = norm(u32(CB_SLOT))
        log('cb', string.format('original=%08x', orig_cb))
        w32(CB_SLOT, TRAMP_ADDR)
        log('cb', 'patched to trampoline')
    elseif frame == 180 and phase == 2 then
        phase = 3
        -- Restore callback
        w32(CB_SLOT, orig_cb)
        log('cb', 'restored to ' .. string.format('%08x', orig_cb))
    elseif frame == 600 and phase == 3 then
        phase = 4
        log('shot', 'taking screenshot')
        local ok, ss = pcall(PCSX.GPU.takeScreenShot)
        if ok and ss and ss.data then
            local wf = Support.File.open(OUTDIR .. '/trampoline.raw', 'TRUNCATE')
            wf:writeMoveSlice(ss.data); wf:close()
            local mf = io.open(OUTDIR .. '/trampoline.meta', 'w')
            if mf then mf:write(string.format('width=%s height=%s bpp=%s\n',
                tostring(ss.width), tostring(ss.height), tostring(ss.bpp))); mf:close() end
            log('shot', 'saved')
        else
            log('shot', 'FAILED')
        end
        finish('done')
    end
    if frame >= 2000 then finish('frame budget') end
end)
_TR_ANCH = vl
log('start', 'trampoline running')
