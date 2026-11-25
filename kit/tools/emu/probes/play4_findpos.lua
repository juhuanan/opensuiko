-- play4_findpos.lua: find hero position vars via RAM diff.
-- Dump RAM 0x80160000-0x80180000 at 3 times: start, after RIGHT 120f, after DOWN 120f.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/play4/play4.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
os.execute('mkdir -p "' .. OUTDIR .. '"')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'

local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local frame = 0
local queue = {}
local logf = assert(io.open(OUT, 'w'))
logf:write('frame,event,detail\n')
local function log(e, d)
    logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or '')))
    logf:flush()
end
local function after(n, fn) queue[#queue + 1] = { at = frame + n, fn = fn } end
local function wait(n, next) after(n, next) end
local done = false
local function finish(msg)
    if done then return end
    done = true
    log('finish', msg)
    logf:close()
    PCSX.quit(0)
end

local function dump(tag)
    local base = 0x80160000
    local size = 0x20000
    local f = assert(io.open(string.format('%s/ram_%s.bin', OUTDIR, tag), 'wb'))
    local CHUNK = 65536
    local off = 0
    while off < size do
        local n = math.min(CHUNK, size - off)
        f:write(ffi.string(RAMB + bit.band(base + off, 0x1FFFFFFF), n))
        off = off + n
    end
    f:close()
    log('dump', tag)
end

local loaded = false
local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    for i = #queue, 1, -1 do
        if queue[i].at <= frame then
            local item = table.remove(queue, i)
            local ok, err = pcall(item.fn)
            if not ok then log('queue_error', tostring(err)) end
        end
    end
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(FIXDIR .. '/ingame.pcsxstate')
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        log('load', 'ok=' .. tostring(ok))
        wait(60, function()
            dump('t0')
            PAD.setOverride(B.RIGHT)
            wait(120, function()
                PAD.clearOverride(B.RIGHT)
                dump('t1_right')
                PAD.setOverride(B.DOWN)
                wait(120, function()
                    PAD.clearOverride(B.DOWN)
                    dump('t2_down')
                    finish('dumps done')
                end)
            end)
        end)
    end
    if frame > 3000 then finish('budget') end
end)
_G.P4_ANCHOR = vl
_G.P4_PAD = PAD
log('start', 'play4_findpos')
