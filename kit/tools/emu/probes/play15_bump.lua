-- play15_bump.lua: diagonal into Teo via alternating DOWN/LEFT, then mash.
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/play15/play15.csv'
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
        local path = string.format('%s/p15_%02d_%s.raw', SHOTDIR, shot_n, tag)
        local wf = Support.File.open(path, 'TRUNCATE')
        wf:writeMoveSlice(ss.data); wf:close()
        local mf = io.open(string.format('%s/p15_%02d_%s.meta', SHOTDIR, shot_n, tag), 'w')
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
local mash_n = 0
local function mash(remaining, next)
    if remaining <= 0 then next(); return end
    mash_n = mash_n + 1
    tap(B.CIRCLE, 12, function()
        if mash_n % 3 == 0 then shot('mash' .. mash_n) end
        wait(20, function() mash(remaining - 1, next) end)
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
            PAD.setOverride(B.UP)
            wait(420, function()
                PAD.clearOverride(B.UP)
                shot('at_teo')
                wait(25, function()
                    -- move to (160,130)
                    PAD.setOverride(B.LEFT)
                    wait(45, function()
                        PAD.clearOverride(B.LEFT)
                        -- diagonal: alternate DOWN 12f / LEFT 12f, 10 iterations
                        local iter = 0
                        local function diag()
                            iter = iter + 1
                            PAD.setOverride(B.DOWN)
                            wait(12, function()
                                PAD.clearOverride(B.DOWN)
                                PAD.setOverride(B.LEFT)
                                wait(12, function()
                                    PAD.clearOverride(B.LEFT)
                                    if iter % 3 == 0 then shot('diag' .. iter) end
                                    wait(10, function()
                                        if iter >= 10 then
                                            shot('at_bump')
                                            wait(25, function()
                                                mash(15, function()
                                                    shot('end')
                                                    finish('done')
                                                end)
                                            end)
                                        else diag() end
                                    end)
                                end)
                            end)
                        end
                        diag()
                    end)
                end)
            end)
        end)
    end
    if frame > 12000 then finish('budget') end
end)
_G.P15_A = vl; _G.P15_P = PAD
log('start', 'play15')
