-- play22_short.lua: from start, go north SHORTER distance (don't overshoot Teo).
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/play22/play22.csv'
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
        local path = string.format('%s/p22_%02d_%s.raw', SHOTDIR, shot_n, tag)
        local wf = Support.File.open(path, 'TRUNCATE')
        wf:writeMoveSlice(ss.data); wf:close()
        local mf = io.open(string.format('%s/p22_%02d_%s.meta', SHOTDIR, shot_n, tag), 'w')
        if mf then mf:write('width=320 height=240 bpp=BPP_16\n'); mf:close() end
    end
    log('shot', tag)
end
local function tap(btn, hold, next)
    PAD.setOverride(btn)
    wait(hold, function() PAD.clearOverride(btn); wait(8, next) end)
end
local function move(btn, frames, tag, next)
    PAD.setOverride(btn)
    wait(frames, function() PAD.clearOverride(btn); shot(tag); wait(25, next) end)
end
local done = false
local function finish(msg)
    if done then return end
    done = true
    log('finish', msg); logf:close(); PCSX.quit(0)
end
local mash_n = 0
local function mash(btn, remaining, next)
    if remaining <= 0 then next(); return end
    mash_n = mash_n + 1
    tap(btn, 12, function()
        shot('mash' .. mash_n)
        wait(25, function() mash(btn, remaining - 1, next) end)
    end)
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
            -- north 110f (to Teo's y), west 100f (to near Teo's x)
            move(B.UP, 110, 'north', function()
                move(B.LEFT, 100, 'west', function()
                    -- face WEST toward Teo, mash CROSS
                    tap(B.LEFT, 4, function()
                        shot('face_w')
                        mash(B.CROSS, 12, function()
                            -- face NORTH, mash CROSS
                            tap(B.UP, 4, function()
                                mash(B.CROSS, 8, function()
                                    shot('end')
                                    finish('done')
                                end)
                            end)
                        end)
                    end)
                end)
            end)
        end)
    end
    if frame > 12000 then finish('budget') end
end)
_G.P22_A = vl; _G.P22_P = PAD
log('start', 'play22')
