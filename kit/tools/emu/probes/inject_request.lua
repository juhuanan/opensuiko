-- inject_request.lua: set 0x80179BEB=5, let the 8-case sequencer drive it
local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/inject'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())
local frame = 0
local state = 0
local done = false
local last_seq = -1
local last_sm = -1

local function rb(addr) return RAM[addr - 0x80000000] end
local function wb(addr, v) RAM[addr - 0x80000000] = v end

local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if ok and ss and ss.data then
        local wf = Support.File.open(OUT .. '_' .. tag .. '.raw', 'TRUNCATE')
        wf:writeMoveSlice(ss.data)
        wf:close()
        PCSX.log('inject: screenshot ' .. tag)
    end
end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    -- Monitor the 8-case sequencer (0x80179C02) and CD state machine (0x80179C04)
    if state >= 2 then
        local seq = rb(0x80179C02)
        local sm = rb(0x80179C04)
        if seq ~= last_seq or sm ~= last_sm then
            PCSX.log(string.format('inject: f=%d SEQ=%d SM=0x%02X REQ_BEB=0x%02X REQ_BEC=0x%02X RES=%d',
                frame, seq, sm, rb(0x80179BEB), rb(0x80179BEC), rb(0x80179BF3)))
            last_seq, last_sm = seq, sm
        end
    end
    
    if state == 0 and frame == 60 then
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        if not ok then done = true; PCSX.quit(0) return end
        PCSX.log(string.format('inject: start SEQ=%d SM=0x%02X', rb(0x80179C02), rb(0x80179C04)))
        shot('before')
        state = 1
    elseif state == 1 and frame == 120 then
        -- Inject request for area 5 at the START of the chain
        PCSX.log('inject: setting 0x80179BEB=5 (request byte)')
        wb(0x80179BEB, 5)
        state = 2
    elseif state == 2 and frame == 1200 then
        shot('after')
        PCSX.log(string.format('inject: end SEQ=%d SM=0x%02X RES=%d',
            rb(0x80179C02), rb(0x80179C04), rb(0x80179BF3)))
        done = true
        PCSX.quit(0)
    elseif frame > 1500 then
        done = true
        PCSX.quit(0)
    end
end)
