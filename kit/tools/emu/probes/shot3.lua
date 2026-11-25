-- shot3.lua — screenshot the three palace fixtures to map the palace layout.
local OUTDIR  = (os.getenv('SUIKODEN_OUT') or '/tmp/s3/s3.csv'):match('^(.*)/[^/]*$')
local SHOTDIR = OUTDIR .. '/shots'
os.execute('mkdir -p "' .. SHOTDIR .. '"')
local FIX = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures/'
local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if not ok or not ss or not ss.data then return end
    local wf = Support.File.open(string.format('%s/s3_%s.raw', SHOTDIR, tag), 'TRUNCATE')
    wf:writeMoveSlice(ss.data); wf:close()
    local mf = io.open(string.format('%s/s3_%s.meta', SHOTDIR, tag), 'w')
    if mf then mf:write(string.format('width=%s height=%s bpp=%s\n', tostring(ss.width), tostring(ss.height), tostring(ss.bpp))); mf:close() end
    PCSX.log('s3: shot ' .. tag)
end
local function load(name)
    local f = Support.File.open(FIX .. name .. '.pcsxstate')
    if f then pcall(function() PCSX.loadSaveState(f) end); f:close() end
    PCSX.log('s3: loaded ' .. name)
end
local frame, done = 0, false
VsyncListener = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 30 then load('ingame')
    elseif frame == 100 then shot('ingame')
    elseif frame == 140 then load('hallway')
    elseif frame == 210 then shot('hallway')
    elseif frame == 250 then load('bedroom2')
    elseif frame == 320 then shot('bedroom2')
    elseif frame == 360 then done = true; PCSX.quit(0) end
end)
_G.S3_ANCHOR = VsyncListener
