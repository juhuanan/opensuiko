-- play16_north.lua: stay in north zone, approach Teo from west, mash all facings.
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/play16/play16.csv'
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
        local path = string.format('%s/p16_%02d_%s.raw', SHOTDIR, shot_n, tag)
        local wf = Support.File.open(path, 'TRUNCATE')
        wf:writeMoveSlice(ss.data); wf:close()
        local mf = io.open(string.format('%s/p16_%02d_%s.meta', SHOTDIR, shot_n, tag), 'w')
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
local function mash(remaining, next)
    if remaining <= 0 then next(); return end
    mash_n = mash_n + 1
    tap(B.CIRCLE, 12, function()
        shot('mash' .. mash_n)
        wait(25, function() mash(remaining - 1, next) end)
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
                    -- west 45f to (160,130)
                    move(B.LEFT, 45, 'w1', function()
                        -- face south, mash 4
                        tap(B.DOWN, 4, function()
                            mash(4, function()
                                -- west 60f more to (140,130)
                                move(B.LEFT, 60, 'w2', function()
                                    tap(B.DOWN, 4, function()
                                        mash(4, function()
                                            -- south 30f to (140,140)
                                            move(B.DOWN, 30, 's1', function()
                                                -- face south, mash 6
                                                tap(B.DOWN, 4, function()
                                                    mash(6, function()
                                                        -- face west, mash 6
                                                        tap(B.LEFT, 4, function()
                                                            mash(6, function()
                                                                -- face east, mash 4
                                                                tap(B.RIGHT, 4, function()
                                                                    mash(4, function()
                                                                        shot('end')
                                                                        finish('done')
                                                                    end)
                                                                end)
                                                            end)
                                                        end)
                                                    end)
                                                end)
                                            end)
                                        end)
                                    end)
                                end)
                            end)
                        end)
                    end)
                end)
            end)
        end)
    end
    if frame > 15000 then finish('budget') end
end)
_G.P16_A = vl; _G.P16_P = PAD
log('start', 'play16')
