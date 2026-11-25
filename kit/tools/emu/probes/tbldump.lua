-- tbldump.lua: dump the live master-dispatch table at 0x800C0D50.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/td.csv'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local RAMW = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u32(a) return tonumber(RAMW[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)]) end
local frame = 0
local logf = assert(io.open(OUT, 'w'))
local function log(e, d)
    logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or '')))
    logf:flush()
end
local loaded, done = false, false
local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 90 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        return
    end
    if not loaded then return end
    if frame == 150 then
        for i = 0, 11 do
            log('tbl', string.format('[%d] = %#x', i, u32(0x800C0D50 + i * 4)))
        end
        -- also dump the trampoline targets: what does 0x800C8BBC jump to?
        log('tramp0', string.format('%#x', u32(0x800C8BBC)))
        log('tramp1', string.format('%#x', u32(0x800C8BCC)))
        done = true; logf:close(); PCSX.quit(0)
    end
end)
_G.TD_ANCHOR = vl
log('start', 'tbldump')
