-- play5_verifypos.lua: verify position candidates by walking UP then RIGHT.
-- Logs candidate values every 20 frames.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/play5/play5.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
os.execute('mkdir -p "' .. OUTDIR .. '"')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'

local RAM = ffi.cast('uint32_t *', PCSX.getMemPtr())
local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local function u16(a) return tonumber(RAM[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)]) end
-- careful: u16 via uint32 array reads the wrong half; use byte pointer instead
local function h(a)
    local o = bit.band(a, 0x1FFFFFFF)
    return tonumber(RAMB[o]) + tonumber(RAMB[o+1]) * 256
end

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

local CANDS = { 0x80176FFC, 0x8017C008, 0x8017C010, 0x8017C018, 0x8017BD8A, 0x80179DE0, 0x80176FF0, 0x80177000 }
local function snap(tag)
    local parts = {}
    for _, a in ipairs(CANDS) do
        parts[#parts+1] = string.format('%08X=%d', a, h(a))
    end
    log('pos', tag .. ' ' .. table.concat(parts, ' '))
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
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        wait(60, function()
            snap('t0')
            log('phase', 'UP 200f')
            PAD.setOverride(B.UP)
            local n = 0
            local function uptick()
                n = n + 1
                snap('up' .. n)
                if n >= 10 then
                    PAD.clearOverride(B.UP)
                    log('phase', 'RIGHT 200f')
                    PAD.setOverride(B.RIGHT)
                    local m = 0
                    local function rtick()
                        m = m + 1
                        snap('right' .. m)
                        if m >= 10 then
                            PAD.clearOverride(B.RIGHT)
                            snap('end')
                            finish('done')
                        else wait(20, rtick) end
                    end
                    wait(20, rtick)
                else wait(20, uptick) end
            end
            wait(20, uptick)
        end)
    end
    if frame > 4000 then finish('budget') end
end)
_G.P5_ANCHOR = vl
_G.P5_PAD = PAD
log('start', 'play5_verifypos')
