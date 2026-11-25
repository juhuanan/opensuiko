-- teleport.lua: teleport to a different area by writing the area index
-- and triggering the loader.
--
-- Env: SUIKODEN_TARGET_IDX (area index), SUIKODEN_START_STATE (required)
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/teleport.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
local SHOTDIR = OUTDIR .. '/shots'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local TARGET = tonumber(os.getenv('SUIKODEN_TARGET_IDX') or '5')
local SETTLE = tonumber(os.getenv('SUIKODEN_SETTLE') or '600')
os.execute('mkdir -p "' .. SHOTDIR .. '"')

local RAM = ffi.cast('uint32_t *', PCSX.getMemPtr())
local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local function u32(a) return tonumber(RAM[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)]) end
local function u8(a) return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) end
local function w8(a, v) RAMB[bit.band(a, 0x1FFFFFFF)] = v end

local frame = 0
local logf = assert(io.open(OUT, 'w'))
local function log(e, d)
    logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or '')))
    logf:flush()
end

local shot_n = 0
local function shot(tag)
    shot_n = shot_n + 1
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if not ok or not ss or not ss.data then return end
    local path = string.format('%s/tp_%03d_%s.raw', SHOTDIR, shot_n, tag)
    local wf = Support.File.open(path, 'TRUNCATE')
    wf:writeMoveSlice(ss.data); wf:close()
    log('shot', tag)
end

local done = false
local loaded = false
local triggered = false
local last_state = -1
local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        log('load', tostring(ok))
        if not ok then done = true; logf:close(); PCSX.quit(0) return end
        log('before', string.format('idx=%d flag=%d state=%d',
            u8(0x80179BF3), u8(0x80179BEB), u8(0x80179C04)))
        shot('before')
    end
    if loaded and not triggered and frame >= 90 then
        triggered = true
        -- Write target index to pending and resource index, then set flag
        w8(0x801790B8, TARGET)
        w8(0x80179BF3, TARGET)
        w8(0x80179BEB, 1)
        log('trigger', string.format('target=%d', TARGET))
    end
    if triggered then
        local st = u8(0x80179C04)
        if st ~= last_state then
            log('lstate', string.format('%d->%d idx=%d', last_state, st, u8(0x80179BF3)))
            last_state = st
        end
        -- After settle frames, screenshot and finish
        if frame >= 90 + SETTLE then
            log('after', string.format('idx=%d flag=%d state=%d',
                u8(0x80179BF3), u8(0x80179BEB), u8(0x80179C04)))
            shot('after')
            done = true; logf:close(); PCSX.quit(0)
        end
    end
    if frame > 5000 then done = true; logf:close(); PCSX.quit(0) end
end)
_G.TP_ANCHOR = vl
log('start', 'target=' .. TARGET)
