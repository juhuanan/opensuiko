-- timeline.lua
-- Ground truth: boot with NO input. Every 300 vsync events, log cb and
-- take a screenshot. Run 9000 frames. Maps the no-input timeline.

local ffi = require('ffi')
local bit = require('bit')

local OUT     = os.getenv('SUIKODEN_OUT') or '/tmp/timeline.csv'
local FRAMES  = tonumber(os.getenv('SUIKODEN_FRAMES') or '9000')
local OUTDIR  = OUT:match('^(.*)/[^/]*$')
local SHOTDIR = OUTDIR .. '/shots'
os.execute('mkdir -p "' .. SHOTDIR .. '"')

local CB_PTR = 0x800B1938
local RAM = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u32(addr)
    return tonumber(RAM[bit.rshift(bit.band(addr, 0x1FFFFFFF), 2)])
end
local function cb() local ok, v = pcall(u32, CB_PTR); return ok and v or 0 end

local frame = 0
local logf = assert(io.open(OUT, 'w'))
local function log(msg)
    logf:write(string.format('%d,%s\n', frame, msg))
    logf:flush()
    PCSX.log(string.format('tl: [%d] %s', frame, msg))
end

local n = 0
local function shot()
    n = n + 1
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if not ok or not ss or not ss.data then
        log(string.format('shot %d FAILED cb=0x%08X', n, cb()))
        return
    end
    local path = string.format('%s/tl_%03d.raw', SHOTDIR, n)
    local wf = Support.File.open(path, 'TRUNCATE')
    wf:writeMoveSlice(ss.data)
    wf:close()
    local mf = io.open(string.format('%s/tl_%03d.meta', SHOTDIR, n), 'w')
    if mf then
        mf:write(string.format('width=%s height=%s bpp=%s\n', tostring(ss.width), tostring(ss.height), tostring(ss.bpp)))
        mf:close()
    end
    log(string.format('shot %d cb=0x%08X', n, cb()))
end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    frame = frame + 1
    if frame % 300 == 0 then
        shot()
    end
    if frame >= FRAMES then
        log('done')
        logf:close()
        PCSX.quit(0)
    end
end)
_G.TL_ANCHOR = vl
log('start')
