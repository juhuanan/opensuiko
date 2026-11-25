-- noop.lua: Minimal trampoline (just returns) to test callback patching.
local ffi = require('ffi')
local bit = require('bit')
local OUT     = os.getenv('SUIKODEN_OUT') or '/tmp/noop/noop.csv'
local OUTDIR  = OUT:match('^(.*)/[^/]*$')
os.execute('mkdir -p "' .. OUTDIR .. '"')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'
local TRAMP_ADDR = 0xA01FE000
local CB_SLOT    = 0x8017DA90
local RAMW = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function w32(addr, v)
    RAMW[bit.rshift(bit.band(addr, 0x1FFFFFFF), 2)] = bit.band(v, 0xFFFFFFFF)
end
local function u32(addr)
    local ok, v = pcall(function() return RAMW[bit.rshift(bit.band(addr, 0x1FFFFFFF), 2)] end)
    return ok and tonumber(v) or 0
end
local function norm(v) return bit.band(tonumber(v) or 0, 0xFFFFFFFF) end
-- jr $ra; nop
local tramp = { 0x03E00008, 0x00000000 }
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
local orig_cb, phase, call_count = 0, 0, 0
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
        orig_cb = norm(u32(CB_SLOT))
        w32(CB_SLOT, TRAMP_ADDR)
        log('cb', string.format('patched orig=%08x', orig_cb))
    elseif frame == 600 and phase == 2 then
        phase = 3
        w32(CB_SLOT, orig_cb)
        log('cb', 'restored')
        log('result', 'SURVIVED 480 frames with no-op trampoline')
        finish('done')
    end
    if frame >= 2000 then finish('frame budget') end
end)
_NOOP_ANCH = vl
log('start', 'noop running')
