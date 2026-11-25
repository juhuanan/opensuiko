-- trigger_load.lua: manually trigger area load by writing request flag
local ffi = require('ffi')
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/trig'
local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

local frame = 0
local done = false

local function rb(a) return RAM[a - 0x80000000] end
local function wb(a, v) RAM[a - 0x80000000] = v end
local function rl(a)
    local o = a - 0x80000000
    return RAM[o] + RAM[o+1]*256 + RAM[o+2]*65536 + RAM[o+3]*16777216
end
local function log(m) PCSX.log('trig: ' .. m) end

local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if ok and ss and ss.data then
        local wf = Support.File.open(OUT .. '_' .. tag .. '.raw', 'TRUNCATE')
        if wf then wf:writeMoveSlice(ss.data); wf:close() end
    end
end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if frame == 30 then
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        log(string.format('Palace loaded, RES_IDX=%d', rb(0x80179BF3)))
        shot('00_palace')
    elseif frame == 120 then
        -- Try to request area 5
        -- Write pending index to 0x801790B8
        wb(0x801790B8, 5)
        log('Wrote 5 to 0x801790B8 (pending)')
        -- Set request flag at 0x80179BEB
        wb(0x80179BEB, 1)
        log('Wrote 1 to 0x80179BEB (request)')
    elseif frame == 180 then
        log(string.format('After request: RES_IDX=%d REQ=%d PENDING=%d', 
            rb(0x80179BF3), rb(0x80179BEB), rb(0x801790B8)))
    elseif frame == 600 then
        log(string.format('After 8s: RES_IDX=%d REQ=%d', rb(0x80179BF3), rb(0x80179BEB)))
        log(string.format('.8ptr=0x%08X', rl(0x8017BFC0)))
        shot('01_after')
    elseif frame == 900 then
        log(string.format('Final: RES_IDX=%d', rb(0x80179BF3)))
        shot('02_final')
        done = true
        PCSX.quit(0)
    elseif frame > 1200 then
        done = true
        PCSX.quit(0)
    end
end)
