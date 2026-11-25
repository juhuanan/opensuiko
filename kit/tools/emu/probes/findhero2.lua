-- findhero2.lua: simpler state machine for RAM diff

local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/findhero'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local frame = 0
local state = 0
local done = false

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if state == 0 and frame == 60 then
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        if not ok then done = true; PCSX.quit(0) return end
        state = 1
    elseif state == 1 and frame == 120 then
        -- Dump before
        local f1 = io.open(OUT .. '_before.bin', 'wb')
        f1:write(ffi.string(RAM, 0x200000))
        f1:close()
        PCSX.log('findhero2: dumped before, holding RIGHT')
        PAD.setOverride(B.RIGHT)
        state = 2
    elseif state == 2 and frame == 180 then
        -- Stop, dump after
        PAD.clearOverride(B.RIGHT)
        local f2 = io.open(OUT .. '_after.bin', 'wb')
        f2:write(ffi.string(RAM, 0x200000))
        f2:close()
        PCSX.log('findhero2: dumped after')
        done = true
        PCSX.quit(0)
    elseif frame > 600 then
        done = true
        PCSX.quit(0)
    end
end)
