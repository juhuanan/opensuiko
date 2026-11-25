-- trigger_load2.lua: try correct request addresses
local ffi = require('ffi')
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

local frame = 0
local done = false

local function rb(a) return RAM[a - 0x80000000] end
local function wb(a, v) RAM[a - 0x80000000] = v end
local function log(m) PCSX.log('trig2: ' .. m) end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if frame == 30 then
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
    elseif frame == 60 then
        log(string.format('Before: RES_IDX=%d', rb(0x80179BF3)))
        -- Try the documented request path:
        -- Case 0 reads from 0x80179BEC/0x80179C0A
        wb(0x80179BEC, 5)  -- request area 5
        wb(0x80179BEB, 1)  -- request flag
        log('Wrote 5 to 0x80179BEC, 1 to 0x80179BEB')
    elseif frame == 120 then
        log(string.format('After 1s: RES_IDX=%d REQ=%d', rb(0x80179BF3), rb(0x80179BEB)))
    elseif frame == 600 then
        log(string.format('After 9s: RES_IDX=%d REQ=%d SEQ=%d', 
            rb(0x80179BF3), rb(0x80179BEB), rb(0x80179C02)))
        done = true
        PCSX.quit(0)
    elseif frame > 900 then
        done = true
        PCSX.quit(0)
    end
end)
