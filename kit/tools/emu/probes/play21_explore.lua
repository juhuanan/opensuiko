-- play21_explore.lua: walk SOUTH from start to find the exit/door.
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/play21/play21.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
local SHOTDIR = OUTDIR .. '/shots'
os.execute('mkdir -p "' .. SHOTDIR .. '"')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON
local frame = 0
local queue = {}
local logf = assert(io.open(OUT, 'w'))
local function log(e, d) logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or ''))); logf:flush() end
local function after(n, fn) queue[#queue + 1] = { at = frame + n, fn = fn } end
local function wait(n, next) after(n, next) end
local shot_n = 0
local function shot(tag)
    shot_n = shot_n + 1
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if ok and ss and ss.data then
        local path = string.format('%s/p21_%02d_%s.raw', SHOTDIR, shot_n, tag)
        local wf = Support.File.open(path, 'TRUNCATE')
        wf:writeMoveSlice(ss.data); wf:close()
        local mf = io.open(string.format('%s/p21_%02d_%s.meta', SHOTDIR, shot_n, tag), 'w')
        if mf then mf:write('width=320 height=240 bpp=BPP_16\n'); mf:close() end
    end
    log('shot', tag)
end
local done = false
local function finish(msg)
    if done then return end
    done = true
    log('finish', msg); logf:close(); PCSX.quit(0)
end
local loaded = false
local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    for i = #queue, 1, -1 do
        if queue[i].at <= frame then
            local item = table.remove(queue, i)
            pcall(item.fn)
        end
    end
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(FIXDIR .. '/ingame.pcsxstate')
        pcall(function() PCSX.loadSaveState(f) end); f:close()
        wait(60, function()
            shot('start')
            PAD.setOverride(B.DOWN)
            local k = 0
            local function step()
                k = k + 1
                shot('south' .. k)
                wait(100, function()
                    if k >= 6 then
                        PAD.clearOverride(B.DOWN)
                        shot('end_south')
                        -- now try EAST
                        PAD.setOverride(B.RIGHT)
                        local j = 0
                        local function esteps()
                            j = j + 1
                            shot('east' .. j)
                            wait(100, function()
                                if j >= 4 then
                                    PAD.clearOverride(B.RIGHT)
                                    shot('end')
                                    finish('done')
                                else esteps() end
                            end)
                        end
                        esteps()
                    else step() end
                end)
            end
            wait(30, step)
        end)
    end
    if frame > 15000 then finish('budget') end
end)
_G.P21_A = vl; _G.P21_P = PAD
log('start', 'play21')
