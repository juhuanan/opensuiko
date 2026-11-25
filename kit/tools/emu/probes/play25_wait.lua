-- play25_wait.lua: wait 2 min, then go to Teo and press X.
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/play25/play25.csv'
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
        local path = string.format('%s/p25_%02d_%s.raw', SHOTDIR, shot_n, tag)
        local wf = Support.File.open(path, 'TRUNCATE')
        wf:writeMoveSlice(ss.data); wf:close()
        local mf = io.open(string.format('%s/p25_%02d_%s.meta', SHOTDIR, shot_n, tag), 'w')
        if mf then mf:write('width=320 height=240 bpp=BPP_16\n'); mf:close() end
    end
    log('shot', tag)
end
local function tap(btn, hold, next)
    PAD.setOverride(btn)
    wait(hold, function() PAD.clearOverride(btn); wait(8, next) end)
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
            shot('t0')
            log('phase', 'waiting 7200f')
            wait(7200, function()
                shot('after_wait')
                log('phase', 'going to Teo')
                -- UP 110f, LEFT 100f (to adjacent)
                PAD.setOverride(B.UP)
                wait(110, function()
                    PAD.clearOverride(B.UP)
                    PAD.setOverride(B.LEFT)
                    wait(100, function()
                        PAD.clearOverride(B.LEFT)
                        shot('at_teo')
                        tap(B.LEFT, 4, function()
                            -- single clean X press, wait 3 sec
                            tap(B.CROSS, 15, function()
                                wait(180, function()
                                    shot('after_x')
                                    finish('done')
                                end)
                            end)
                        end)
                    end)
                end)
            end)
        end)
    end
    if frame > 20000 then finish('budget') end
end)
_G.P25_A = vl; _G.P25_P = PAD
log('start', 'play25')
