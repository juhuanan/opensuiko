-- capture_cave.lua: load save, wait for stable, screenshot and save state
local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/cave'
local SAVE_STATE_PATH = os.getenv('SUIKODEN_SAVE_STATE') or '/tmp/cave_state.pcsxstate'
local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

local frame = 0
local state = 0
local done = false
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if ok and ss and ss.data then
        local wf = Support.File.open(OUT .. '_' .. tag .. '.raw', 'TRUNCATE')
        wf:writeMoveSlice(ss.data)
        wf:close()
        PCSX.log('cave: screenshot ' .. tag)
    end
end

local hold_until = 0
local held_btn = 0

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if held_btn ~= 0 and frame >= hold_until then
        PAD.clearOverride(held_btn)
        held_btn = 0
    end
    
    if state == 0 and frame == 300 then
        PCSX.log('cave: START at title')
        held_btn = B.START; hold_until = frame + 10; PAD.setOverride(B.START)
        state = 1
    elseif state == 1 and frame == 400 then
        PCSX.log('cave: DOWN to Continue')
        held_btn = B.DOWN; hold_until = frame + 10; PAD.setOverride(B.DOWN)
        state = 2
    elseif state == 2 and frame == 450 then
        held_btn = B.CROSS; hold_until = frame + 10; PAD.setOverride(B.CROSS)
        state = 3
    elseif state == 3 and frame == 600 then
        PCSX.log('cave: CROSS to load save')
        held_btn = B.CROSS; hold_until = frame + 10; PAD.setOverride(B.CROSS)
        state = 4
    elseif state == 4 and frame == 1200 then
        -- In game, wait for stable
        local res_idx = RAM[0x80179BF3 - 0x80000000]
        local seq = RAM[0x80179C02 - 0x80000000]
        PCSX.log(string.format('cave: RES_IDX=%d SEQ=%d', res_idx, seq))
        shot('cave_area')
        state = 5
    elseif state == 5 and frame == 1500 then
        -- Save state
        local f = Support.File.open(SAVE_STATE_PATH, 'TRUNCATE')
        pcall(function() PCSX.saveSaveState(f) end)
        f:close()
        PCSX.log('cave: save state written to ' .. SAVE_STATE_PATH)
        shot('cave_area2')
        done = true
        PCSX.quit(0)
    elseif frame > 1800 then
        done = true
        PCSX.quit(0)
    end
end)
