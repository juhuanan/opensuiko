-- shots_along_the_way.lua — one run, two postcards.
-- Boots clean, screenshots the title (~f8600), loads the in-game save
-- state, screenshots the starting room, quits.
local OUTDIR  = (os.getenv('SUIKODEN_OUT') or '/tmp/saw/saw.csv'):match('^(.*)/[^/]*$')
local SHOTDIR = OUTDIR .. '/shots'
os.execute('mkdir -p "' .. SHOTDIR .. '"')
local STATE = (os.getenv('SUIKODEN_FIXDIR') or (OUTDIR .. '/fixtures')) .. '/ingame.pcsxstate'
-- allow override: SUIKODEN_FIXDIR must point at the real fixtures dir
if not Support.File.open(STATE) then
    STATE = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures/ingame.pcsxstate'
end

local frame, done, loaded = 0, false, false
local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if not ok or not ss or not ss.data then return end
    local wf = Support.File.open(string.format('%s/saw_%s.raw', SHOTDIR, tag), 'TRUNCATE')
    wf:writeMoveSlice(ss.data); wf:close()
    local mf = io.open(string.format('%s/saw_%s.meta', SHOTDIR, tag), 'w')
    if mf then mf:write(string.format('width=%s height=%s bpp=%s\n', tostring(ss.width), tostring(ss.height), tostring(ss.bpp))); mf:close() end
    PCSX.log('saw: shot ' .. tag .. ' @' .. frame)
end

VsyncListener = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 8600 then shot('title') end
    if frame == 8700 and not loaded then
        loaded = true
        local f = Support.File.open(STATE)
        if f then pcall(function() PCSX.loadSaveState(f) end) end
    end
    if loaded and frame == 9100 then shot('room'); done = true; PCSX.quit(0) end
end)
