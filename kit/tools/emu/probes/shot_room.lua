-- shot_room.lua — load the in-game save state, screenshot the room, quit.
local OUTDIR  = (os.getenv('SUIKODEN_OUT') or '/tmp/sr/sr.csv'):match('^(.*)/[^/]*$')
local SHOTDIR = OUTDIR .. '/shots'
os.execute('mkdir -p "' .. SHOTDIR .. '"')
local STATE = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures/ingame.pcsxstate'
local frame, done, loaded = 0, false, false
VsyncListener = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 30 and not loaded then
        loaded = true
        local f = Support.File.open(STATE)
        if f then pcall(function() PCSX.loadSaveState(f) end) end
    end
    if loaded and frame == 400 then
        local ok, ss = pcall(PCSX.GPU.takeScreenShot)
        if ok and ss and ss.data then
            local wf = Support.File.open(SHOTDIR .. '/sr_room.raw', 'TRUNCATE')
            wf:writeMoveSlice(ss.data); wf:close()
            local mf = io.open(SHOTDIR .. '/sr_room.meta', 'w')
            if mf then mf:write(string.format('width=%s height=%s bpp=%s\n', tostring(ss.width), tostring(ss.height), tostring(ss.bpp))); mf:close() end
            PCSX.log('sr: shot room @' .. frame)
        end
        done = true; PCSX.quit(0)
    end
end)
