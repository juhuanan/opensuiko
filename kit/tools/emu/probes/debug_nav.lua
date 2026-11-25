-- debug_nav.lua: screenshot each navigation step
local ffi = require('ffi')

local frame = 0
local phase = 0
local done = false
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if ok and ss and ss.data then
        -- Use TRUNCATE like the working load_save.lua
        local wf = Support.File.open('/tmp/nav_' .. tag .. '.raw', 'TRUNCATE')
        if wf then
            wf:writeMoveSlice(ss.data)
            wf:close()
            PCSX.log('nav: screenshot ' .. tag)
        else
            PCSX.log('nav: FAILED to open file for ' .. tag)
        end
    end
end

local hold_until = 0
local held_btn = 0
local phase_frame = 0

local function press(btn)
    held_btn = btn
    hold_until = frame + 8
    PAD.setOverride(btn)
end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if held_btn ~= 0 and frame >= hold_until then
        PAD.clearOverride(held_btn)
        held_btn = 0
    end
    
    if phase == 0 and frame >= 300 then
        shot('01_title')
        press(B.START)
        phase = 1
        phase_frame = frame
    elseif phase == 1 and frame >= phase_frame + 90 then
        shot('02_mainmenu')
        press(B.DOWN)
        phase = 2
        phase_frame = frame
    elseif phase == 2 and frame >= phase_frame + 30 then
        shot('03_after_down')
        press(B.CROSS)
        phase = 3
        phase_frame = frame
    elseif phase == 3 and frame >= phase_frame + 120 then
        shot('04_after_cross')
        press(B.CROSS)
        phase = 4
        phase_frame = frame
    elseif phase == 4 and frame >= phase_frame + 180 then
        shot('05_final')
        done = true
        PCSX.quit(0)
    elseif frame > 2000 then
        done = true
        PCSX.quit(0)
    end
end)
