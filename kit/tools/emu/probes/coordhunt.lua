-- coordhunt.lua: dump full RAM at movement waypoints to find hero X/Y in RAM.
-- Loads clean hallway state, dumps RAM, walks LEFT 300f, dumps, walks RIGHT
-- 300f, dumps, walks UP 300f, dumps, walks DOWN 300f, dumps. Offline diff
-- finds values tracking the hero.
local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/coordhunt.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
local DUMPDIR = OUTDIR .. '/ramdumps'
local FIXDIR = (os.getenv('SUIKODEN_FIXDIR') or (OUTDIR .. '/fixtures'))
local START_STATE = os.getenv('SUIKODEN_START_STATE') or (FIXDIR .. '/ingame.pcsxstate')
os.execute('mkdir -p "' .. DUMPDIR .. '"')

local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local frame = 0
local logf = assert(io.open(OUT, 'w'))
local function log(e, d)
    logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or '')))
    logf:flush()
end

local function dump(tag)
    local path = string.format('%s/ram_%s.bin', DUMPDIR, tag)
    local f = assert(io.open(path, 'wb'))
    f:write(ffi.string(RAM, 2 * 1024 * 1024))
    f:close()
    log('dump', tag)
end

local done = false
local loaded = false
local phase = 0
local phase_start = 0
local function setphase(n, btn, hold, dumptag)
    phase = n
    phase_start = frame
    if btn then PAD.setOverride(btn); log('hold', btn) end
    -- dump happens at END of phase; store tag
    phase_dump = dumptag
    phase_hold = hold
end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        log('load', tostring(ok))
        dump('base')
        setphase(1, B.LEFT, 300, 'left')
    end
    if loaded and phase >= 1 and frame - phase_start >= phase_hold then
        PAD.clearOverride(B.LEFT); PAD.clearOverride(B.RIGHT)
        PAD.clearOverride(B.UP); PAD.clearOverride(B.DOWN)
        dump(phase_dump)
        if phase == 1 then setphase(2, B.RIGHT, 300, 'right')
        elseif phase == 2 then setphase(3, B.UP, 300, 'up')
        elseif phase == 3 then setphase(4, B.DOWN, 300, 'down')
        elseif phase == 4 then
            done = true
            log('finish', 'all dumps taken')
            logf:close()
            PCSX.quit(0)
        end
    end
    if frame > 3000 then done = true; logf:close(); PCSX.quit(0) end
end)
_G.COORDHUNT_ANCHOR = vl
log('start', 'coordhunt')
