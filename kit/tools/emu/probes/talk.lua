-- talk.lua: try talking to the guard NPC. From the hallway state, face
-- different directions and press CROSS, screenshotting for dialogue boxes.
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/talk.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
local SHOTDIR = OUTDIR .. '/shots'
local FIXDIR = (os.getenv('SUIKODEN_FIXDIR') or (OUTDIR .. '/fixtures'))
local START_STATE = os.getenv('SUIKODEN_START_STATE') or (FIXDIR .. '/ingame.pcsxstate')
os.execute('mkdir -p "' .. SHOTDIR .. '"')

local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

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
    local path = string.format('%s/talk_%03d_%s.raw', SHOTDIR, shot_n, tag)
    local wf = Support.File.open(path, 'TRUNCATE')
    wf:writeMoveSlice(ss.data); wf:close()
    log('shot', tag)
end

local done = false
local loaded = false
-- sequence of (direction tap to face, then CROSS)
local seq = {
    { face = 'DOWN',  hold = 30 },
    { face = 'LEFT',  hold = 30 },
    { face = 'RIGHT', hold = 30 },
    { face = 'UP',    hold = 30 },
}
local si = 1
local sub = 0  -- 0=face, 1=cross, 2=wait
local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        log('load', tostring(ok))
        shot('start')
    end
    if loaded and si <= #seq then
        sub = sub + 1
        local s = seq[si]
        if sub == 1 then
            PAD.setOverride(B[s.face])
            log('face', s.face)
        elseif sub == s.hold then
            PAD.clearOverride(B[s.face])
        elseif sub == s.hold + 10 then
            PAD.setOverride(B.CROSS)
            log('talk', 'CROSS facing ' .. s.face)
        elseif sub == s.hold + 22 then
            PAD.clearOverride(B.CROSS)
            shot('after_' .. s.face)
        elseif sub >= s.hold + 120 then
            si = si + 1
            sub = 0
        end
    end
    if loaded and si > #seq then
        shot('end')
        done = true; logf:close(); PCSX.quit(0)
    end
    if frame > 3000 then done = true; logf:close(); PCSX.quit(0) end
end)
_G.TALK_ANCHOR = vl
log('start', 'talk test')
