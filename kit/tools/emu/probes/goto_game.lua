-- goto_game.lua
--
-- Loads fixtures/ingame.pcsxstate (captured in the starting room after
-- New Game) and verifies the game is alive: VSync advances, screenshot
-- taken. Run from a clean emulator start; no walkthrough needed.

local OUT     = os.getenv('SUIKODEN_OUT') or '/tmp/goto_game.csv'
local FRAMES  = tonumber(os.getenv('SUIKODEN_FRAMES') or '3000')
local OUTDIR  = OUT:match('^(.*)/[^/]*$')
local SHOTDIR = OUTDIR .. '/shots'
local FIXDIR  = (os.getenv('SUIKODEN_FIXDIR') or (OUTDIR .. '/fixtures'))
os.execute('mkdir -p "' .. SHOTDIR .. '"')
local STATE_PATH = FIXDIR .. '/ingame.pcsxstate'

local frame = 0
local logf = assert(io.open(OUT, 'w'))
local function log(event, detail)
    logf:write(string.format('%d,%s,%s\n', frame, event, tostring(detail or '')))
    logf:flush()
    PCSX.log(string.format('gg: [%d] %s %s', frame, event, tostring(detail or '')))
end

local done = false
local function finish(msg)
    if done then return end
    done = true
    log('finish', msg)
    logf:close()
    PCSX.quit(0)
end

local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if not ok or not ss or not ss.data then log('shot_fail', tag); return end
    local path = string.format('%s/gg_%s.raw', SHOTDIR, tag)
    local wf = Support.File.open(path, 'TRUNCATE')
    wf:writeMoveSlice(ss.data)
    wf:close()
    local mf = io.open(string.format('%s/gg_%s.meta', SHOTDIR, tag), 'w')
    if mf then
        mf:write(string.format('width=%s height=%s bpp=%s\n', tostring(ss.width), tostring(ss.height), tostring(ss.bpp)))
        mf:close()
    end
    log('shot', tag)
end

local loaded = false
local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        log('load_try', STATE_PATH)
        local f = Support.File.open(STATE_PATH)
        if not f then
            log('load_fail', 'cannot open state file')
            finish('ABORT: no state file')
            return
        end
        local ok, err = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        log('load_result', string.format('ok=%s err=%s', tostring(ok), tostring(err)))
        if not ok then finish('ABORT: loadSaveState failed') return end
        shot('after_load')
    end
    if frame == 660 and loaded then
        -- 600 frames after load: game should be alive and animating
        shot('verify')
        log('verify', 'vsync advanced 600f post-load')
        finish('state reloaded and alive')
    end
    if frame >= FRAMES then finish('frame budget exhausted') end
end)
_G.GG_ANCHOR = vl
log('start', 'goto_game running')
