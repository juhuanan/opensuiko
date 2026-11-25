-- load_area5.lua: use the actual load mechanism with correct index value
-- 0x801790B8 = pending index, 0x80179BEB = request (holds index, not just flag)

local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/load5'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

local frame = 0
local state = 0
local done = false
local last_sm = -1
local last_mode = -1
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
        PCSX.log('load5: screenshot ' .. tag)
    end
end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if state >= 2 then
        local sm = rb(SM_STATE)
        local mode = rb(AREA_MODE)
        local res = rb(RES_IDX)
        if sm ~= last_sm or mode ~= last_mode or res ~= last_res then
            PCSX.log(string.format('load5: f=%d SM=0x%02X MODE=0x%02X RES=%d REQ=0x%02X',
                frame, sm, mode, res, rb(REQ_FLAG)))
            last_sm, last_mode, last_res = sm, mode, res
            -- Screenshot on RES change (new area loading)
            if res ~= 4 and res ~= last_res then
                shot('new_area_' .. res)
            end
        end
    end
    
    if state == 0 and frame == 60 then
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        if not ok then done = true; PCSX.quit(0) return end
        PCSX.log(string.format('load5: start RES=%d SM=0x%02X', rb(RES_IDX), rb(SM_STATE)))
        shot('before')
        state = 1
    elseif state == 1 and frame == 120 then
        -- Set pending index to 5 (AREAA_1.8)
        -- AND set REQ_FLAG to 5 (the index, not just 1)
        -- This mimics what 0x800C6440 does: copies pending -> flag
        PCSX.log('load5: requesting area 5 (AREAA_1.8) via 0x801790B8 and 0x80179BEB')
        wb(PENDING_IDX, 5)
        wb(REQ_FLAG, 5)
        state = 2
    elseif state == 2 and frame == 900 then
        -- 13 seconds for load
        shot('after')
        PCSX.log(string.format('load5: end RES=%d SM=0x%02X REQ=0x%02X',
            rb(RES_IDX), rb(SM_STATE), rb(REQ_FLAG)))
        done = true
        PCSX.quit(0)
    elseif frame > 1200 then
        done = true
        PCSX.quit(0)
    end
end)
