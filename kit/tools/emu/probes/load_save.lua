-- load_save.lua: boot, go to Continue, load the save, screenshot the result
local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/loadsave'
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
        PCSX.log('loadsave: screenshot ' .. tag)
    end
end

local function press(btn, frames)
    PAD.setOverride(btn)
    return frames
end

local hold_until = 0
local held_btn = 0

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    -- Release button after hold period
    if held_btn ~= 0 and frame >= hold_until then
        PAD.clearOverride(held_btn)
        held_btn = 0
    end
    
    if state == 0 and frame == 300 then
        -- Boot done, at title screen. Press START.
        PCSX.log('loadsave: pressing START at title')
        held_btn = B.START
        hold_until = frame + 10
        PAD.setOverride(B.START)
        state = 1
    elseif state == 1 and frame == 400 then
        -- At main menu (New Game / Continue). Press DOWN to select Continue, then CROSS.
        PCSX.log('loadsave: selecting Continue')
        held_btn = B.DOWN
        hold_until = frame + 10
        PAD.setOverride(B.DOWN)
        state = 2
    elseif state == 2 and frame == 450 then
        held_btn = B.CROSS
        hold_until = frame + 10
        PAD.setOverride(B.CROSS)
        state = 3
    elseif state == 3 and frame == 600 then
        -- At save file selection. Press CROSS to load first save.
        PCSX.log('loadsave: loading save file')
        shot('save_select')
        held_btn = B.CROSS
        hold_until = frame + 10
        PAD.setOverride(B.CROSS)
        state = 4
    elseif state == 4 and frame == 900 then
        -- Should be in game now. Screenshot.
        PCSX.log('loadsave: in game, taking screenshot')
        shot('loaded_game')
        -- Log current area info
        local res_idx = RAM[0x80179BF3 - 0x80000000]
        PCSX.log(string.format('loadsave: RES_IDX=%d', res_idx))
        state = 5
    elseif state == 5 and frame == 1200 then
        shot('loaded_game2')
        PCSX.log('loadsave: done')
        done = true
        PCSX.quit(0)
    elseif frame > 1500 then
        PCSX.log('loadsave: timeout')
        done = true
        PCSX.quit(0)
    end
end)
