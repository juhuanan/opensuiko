-- trans5.lua: Self-unpatching trampoline calls transition initiator 0x800C6374(a0=5).
-- Then restores the per-frame callback. Game should naturally transition to area 5.
local ffi = require('ffi')
local bit = require('bit')
local OUT     = os.getenv('SUIKODEN_OUT') or '/tmp/trans/trans.csv'
local OUTDIR  = OUT:match('^(.*)/[^/]*$')
os.execute('mkdir -p "' .. OUTDIR .. '"')
local SHOTDIR = OUTDIR .. '/shots'
os.execute('mkdir -p "' .. SHOTDIR .. '"')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'
local TRAMP_ADDR = 0xA01FE000
local CB_SLOT    = 0x8017DA90
local ORIG_CB    = 0x800C98F0
local RAMW = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function w32(addr, v)
    RAMW[bit.rshift(bit.band(addr, 0x1FFFFFFF), 2)] = bit.band(v, 0xFFFFFFFF)
end
local function u32(addr)
    local ok, v = pcall(function() return RAMW[bit.rshift(bit.band(addr, 0x1FFFFFFF), 2)] end)
    return ok and tonumber(v) or 0
end
local function norm(v) return bit.band(tonumber(v) or 0, 0xFFFFFFFF) end
-- Self-unpatching trampoline:
--   call 0x800C6374(5); *(0x8017DA90) = 0x800C98F0; return
local tramp = {
    0x27BDFFF8,  -- addiu $sp, $sp, -8
    0xAFBF0004,  -- sw $ra, 4($sp)
    0x24040005,  -- addiu $a0, $zero, 5
    0x3C19800C,  -- lui $t9, 0x800C
    0x37296374,  -- ori $t9, $t9, 0x6374  ($t9 = 0x800C6374)
    0x0320F809,  -- jalr $t9
    0x00000000,  -- nop
    0x3C188018,  -- lui $t8, 0x8018
    0x2718DA90,  -- addiu $t8, $t8, -0x2570 ($t8 = 0x8017DA90)
    0x3C19800C,  -- lui $t9, 0x800C
    0x372998F0,  -- ori $t9, $t9, 0x98F0 ($t9 = 0x800C98F0)
    0xAF190000,  -- sw $t9, 0($t8)
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
    if done then return end done = true
    log('finish', msg); logf:close(); PCSX.quit(0)
end
local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if not ok or not ss or not ss.data then log('shot', tag .. ' FAILED'); return end
    local wf = Support.File.open(string.format('%s/trans_%s.raw', SHOTDIR, tag), 'TRUNCATE')
    wf:writeMoveSlice(ss.data); wf:close()
    local mf = io.open(string.format('%s/trans_%s.meta', SHOTDIR, tag), 'w')
    if mf then mf:write(string.format('width=%s height=%s bpp=%s\n',
        tostring(ss.width), tostring(ss.height), tostring(ss.bpp))); mf:close() end
    log('shot', tag .. ' saved')
end
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
        for i, w in ipairs(tramp) do w32(TRAMP_ADDR + (i-1)*4, w) end
        w32(CB_SLOT, TRAMP_ADDR)
        log('cb', 'patched to self-unpatching trampoline')
        shot('before')
    elseif frame == 240 and phase == 2 then
        phase = 3
        -- Trampoline should have run and unpatched itself. Verify.
        local cb = norm(u32(CB_SLOT))
        log('cb', string.format('now=%08x (expect 800c98f0)', cb))
        shot('after_trigger')
    elseif frame == 3000 and phase == 3 then
        phase = 4
        shot('transition_3000f')
        finish('done')
    end
    if frame >= 8000 then finish('frame budget') end
end)
_TR5_ANCH = vl
log('start', 'trans5 running')
