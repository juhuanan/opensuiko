-- idle.lua: load a state and observe with NO input. Screenshots + coords.
-- Detects scripted sequences / auto-movement / dialogue.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/idle.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
local SHOTDIR = OUTDIR .. '/shots'
local FIXDIR = (os.getenv('SUIKODEN_FIXDIR') or (OUTDIR .. '/fixtures'))
local START_STATE = os.getenv('SUIKODEN_START_STATE') or (FIXDIR .. '/ingame.pcsxstate')
local FRAMES = tonumber(os.getenv('SUIKODEN_FRAMES') or '3000')
os.execute('mkdir -p "' .. SHOTDIR .. '"')

local RAM = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u32(a) return tonumber(RAM[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)]) end
local function u16(a)
    local w = u32(bit.band(a, 0xFFFFFFFC))
    return bit.band(bit.rshift(w, bit.band(a, 2) * 8), 0xFFFF)
end
local function s16(v) if v >= 32768 then return v - 65536 end return v end

local frame = 0
local logf = assert(io.open(OUT, 'w'))
local shot_n = 0
local function shot(tag)
    shot_n = shot_n + 1
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if not ok or not ss or not ss.data then return end
    local path = string.format('%s/idle_%03d_%s.raw', SHOTDIR, shot_n, tag)
    local wf = Support.File.open(path, 'TRUNCATE')
    wf:writeMoveSlice(ss.data); wf:close()
    logf:write(string.format('%d,shot,%s,x=%d,y=%d\n', frame, tag,
        s16(u16(0x8017C008)), s16(u16(0x8017C010))))
    logf:flush()
end

local done = false
local loaded = false
local lastx, lasty = 0, 0
local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        lastx, lasty = s16(u16(0x8017C008)), s16(u16(0x8017C010))
        shot('loaded')
    end
    if loaded then
        local x, y = s16(u16(0x8017C008)), s16(u16(0x8017C010))
        if x ~= lastx or y ~= lasty then
            logf:write(string.format('%d,automove,%d,%d -> %d,%d\n', frame, lastx, lasty, x, y))
            logf:flush()
            lastx, lasty = x, y
        end
        if frame % 600 == 0 then shot('t' .. frame) end
    end
    if frame >= FRAMES then
        shot('end'); done = true; logf:close(); PCSX.quit(0)
    end
end)
_G.IDLE_ANCHOR = vl
