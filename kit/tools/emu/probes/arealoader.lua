-- arealoader.lua: trace area-load state machine when requesting a new area
-- Watches 0x80179C04 (state) through the load

local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/areaload'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())
local u32 = ffi.cast('uint32_t *', PCSX.getMemPtr())

local frame = 0
local state = 0
local done = false
local last_sm_state = -1
local last_mode = -1

-- State variable addresses (from docs)
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
        PCSX.log('areaload: screenshot ' .. tag)
    end
end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    -- Monitor state machine every frame after trigger
    if state >= 2 then
        local sm = rb(SM_STATE)
        local mode = rb(AREA_MODE)
        local req = rb(REQ_FLAG)
        if sm ~= last_sm_state or mode ~= last_mode then
            PCSX.log(string.format('areaload: frame %d SM_STATE=0x%02X AREA_MODE=0x%02X REQ=%d', 
                frame, sm, mode, req))
            last_sm_state = sm
            last_mode = mode
        end
    end
    
    if state == 0 and frame == 60 then
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        if not ok then done = true; PCSX.quit(0) return end
        PCSX.log(string.format('areaload: loaded, current SM=0x%02X MODE=0x%02X', 
            rb(SM_STATE), rb(AREA_MODE)))
        shot('before')
        state = 1
    elseif state == 1 and frame == 120 then
        -- Request area 5 (AREAA_1.8)
        PCSX.log('areaload: requesting area 5 (AREAA_1.8)')
        wb(PENDING_IDX, 5)
        wb(REQ_FLAG, 1)
        -- Also set RES_IDX? The doc says Area_RequestNext copies PENDING -> flag
        -- Let's call the request function directly? For now just set the flag
        state = 2
    elseif state == 2 and frame == 600 then
        -- After 8 seconds, screenshot the result
        shot('after_load')
        PCSX.log(string.format('areaload: final SM=0x%02X MODE=0x%02X REQ=%d RES_IDX=%d', 
            rb(SM_STATE), rb(AREA_MODE), rb(REQ_FLAG), rb(RES_IDX)))
        done = true
        PCSX.quit(0)
    elseif frame > 900 then
        done = true
        PCSX.quit(0)
    end
end)
