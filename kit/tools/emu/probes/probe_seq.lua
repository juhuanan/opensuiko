-- probe_seq.lua: check sequencer state and try to advance it
local ffi = require('ffi')
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

local frame = 0
local done = false

local function rb(a) return RAM[a - 0x80000000] end
local function wb(a, v) RAM[a - 0x80000000] = v end
local function log(m) PCSX.log('seq: ' .. m) end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if frame == 30 then
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
    elseif frame == 60 then
        log(string.format('SEQ (0x80179C02) = %d', rb(0x80179C02)))
        log(string.format('REQ (0x80179BEB) = %d', rb(0x80179BEB)))
        log(string.format('PENDING (0x801790B8) = %d', rb(0x801790B8)))
        log(string.format('MODE (0x80179CB8) = %d', rb(0x80179CB8)))
        log(string.format('SM (0x80179C04) = %d', rb(0x80179C04)))
        -- Try setting SEQ to 0 and REQ to 1
        wb(0x801790B8, 5)
        wb(0x80179BEB, 1)
        wb(0x80179C02, 0)
        log('Set PENDING=5, REQ=1, SEQ=0')
    elseif frame == 120 then
        log(string.format('After: SEQ=%d REQ=%d RES_IDX=%d', 
            rb(0x80179C02), rb(0x80179BEB), rb(0x80179BF3)))
    elseif frame == 600 then
        log(string.format('Final: SEQ=%d REQ=%d RES_IDX=%d', 
            rb(0x80179C02), rb(0x80179BEB), rb(0x80179BF3)))
        done = true
        PCSX.quit(0)
    elseif frame > 900 then
        done = true
        PCSX.quit(0)
    end
end)
