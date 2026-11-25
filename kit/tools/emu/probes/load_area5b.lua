-- load_area5b.lua: set PENDING, REQ, and RES all to 5

local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/load5b'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

local frame = 0
local state = 0
local done = false
local last_sm = -1
local last_res = -1

local PENDING_IDX = 0x801790B8
local REQ_FLAG = 0x80179BEB
local RES_IDX = 0x80179BF3
local SM_STATE = 0x80179C04
local AREA_MODE = 0x80179CB8

local function rb(addr) return RAM[addr - 0x80000000] end
local function wb(addr, v) RAM[addr - 0x80000000] = v end

local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if ok and ss and ss.data then
        local wf = Support.File.open(OUT .. '_' .. tag .. '.raw', 'TRUNCATE')
        wf:writeMoveSlice(ss.data)
        wf:close()
        PCSX.log('load5b: screenshot ' .. tag)
    end
end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if state >= 2 then
        local sm = rb(SM_STATE)
        local res = rb(RES_IDX)
        if sm ~= last_sm or res ~= last_res then
            PCSX.log(string.format('load5b: f=%d SM=0x%02X RES=%d REQ=0x%02X MODE=0x%02X',
                frame, sm, res, rb(REQ_FLAG), rb(AREA_MODE)))
            last_sm, last_res = sm, res
        end
    end
    
    if state == 0 and frame == 60 then
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        if not ok then done = true; PCSX.quit(0) return end
        shot('before')
        state = 1
    elseif state == 1 and frame == 120 then
        PCSX.log('load5b: setting PENDING=5, REQ=5, RES=5')
        wb(PENDING_IDX, 5)
        wb(REQ_FLAG, 5)
        wb(RES_IDX, 5)
        state = 2
    elseif state == 2 and frame == 900 then
        shot('after')
        PCSX.log(string.format('load5b: end RES=%d SM=0x%02X', rb(RES_IDX), rb(SM_STATE)))
        done = true
        PCSX.quit(0)
    elseif frame > 1200 then
        done = true
        PCSX.quit(0)
    end
end)
