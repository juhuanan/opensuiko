-- load_gf05.lua: load the GameFAQs first save with proper timing
local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/gf05'
local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

local frame = 0
local phase = 0
local done = false
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local function rb(a) return RAM[a - 0x80000000] end

local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if ok and ss and ss.data then
        local wf = Support.File.open(OUT .. '_' .. tag .. '.raw', 'TRUNCATE')
        if wf then
            wf:writeMoveSlice(ss.data)
            wf:close()
            PCSX.log('gf05: screenshot ' .. tag)
        end
    end
end

local hold_until = 0
local held_btn = 0
local phase_frame = 0

local function press(btn)
    held_btn = btn
    hold_until = frame + 10
    PAD.setOverride(btn)
end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if held_btn ~= 0 and frame >= hold_until then
        PAD.clearOverride(held_btn)
        held_btn = 0
    end
    
    -- Wait for full boot (1000 frames)
    if phase == 0 and frame >= 1000 then
        PCSX.log('gf05: pressing START')
        shot('title')
        press(B.START)
        phase = 1
        phase_frame = frame
    elseif phase == 1 and frame >= phase_frame + 120 then
        PCSX.log('gf05: pressing DOWN')
        shot('mainmenu')
        press(B.DOWN)
        phase = 2
        phase_frame = frame
    elseif phase == 2 and frame >= phase_frame + 60 then
        press(B.CROSS)
        phase = 3
        phase_frame = frame
    elseif phase == 3 and frame >= phase_frame + 180 then
        PCSX.log('gf05: pressing CROSS to load')
        shot('saveselect')
        press(B.CROSS)
        phase = 4
        phase_frame = frame
    elseif phase == 4 and frame >= phase_frame + 400 then
        local idx = rb(0x80179BF3)
        PCSX.log(string.format('gf05: RES_IDX=%d', idx))
        shot('ingame')
        phase = 5
        phase_frame = frame
    elseif phase == 5 and frame >= phase_frame + 200 then
        shot('ingame2')
        PCSX.log('gf05: done')
        done = true
        PCSX.quit(0)
    elseif frame > 4000 then
        PCSX.log('gf05: timeout')
        done = true
        PCSX.quit(0)
    end
end)
