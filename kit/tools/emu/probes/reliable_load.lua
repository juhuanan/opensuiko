-- reliable_load.lua: wait for boot, load save, verify
-- Usage: SUIKODEN_OUT=/tmp/out SUIKODEN_SAVE=<mcd path> run.sh ...
local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/reliable'
local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

local frame = 0
local phase = 0
local done = false
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local function rb(a) return RAM[a - 0x80000000] end
local function log(tag, msg) PCSX.log('rload: [' .. tag .. '] ' .. msg) end

local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if ok and ss and ss.data then
        local wf = Support.File.open(OUT .. '_' .. tag .. '.raw', 'TRUNCATE')
        if wf then wf:writeMoveSlice(ss.data); wf:close() end
    end
end

local hold_until = 0
local held_btn = 0
local phase_frame = 0

local function press(btn, dur)
    dur = dur or 10
    held_btn = btn
    hold_until = frame + dur
    PAD.setOverride(btn)
end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if held_btn ~= 0 and frame >= hold_until then
        PAD.clearOverride(held_btn)
        held_btn = 0
    end
    
    -- Phase 0: Wait 3500 frames for guaranteed boot (58 sec)
    if phase == 0 and frame >= 3500 then
        log('boot', 'Assuming title screen, pressing START')
        shot('01_title')
        press(B.START)
        phase = 1
        phase_frame = frame
    -- Phase 1: Main menu, press DOWN to Continue
    elseif phase == 1 and frame >= phase_frame + 180 then
        log('menu', 'Pressing DOWN')
        shot('02_menu')
        press(B.DOWN)
        phase = 2
        phase_frame = frame
    -- Phase 2: Select Continue
    elseif phase == 2 and frame >= phase_frame + 60 then
        log('menu', 'Pressing CROSS (Continue)')
        press(B.CROSS)
        phase = 3
        phase_frame = frame
    -- Phase 3: Save list, press CROSS to load
    elseif phase == 3 and frame >= phase_frame + 240 then
        log('menu', 'Pressing CROSS (load save)')
        shot('03_savelist')
        press(B.CROSS)
        phase = 4
        phase_frame = frame
    -- Phase 4: Wait for load, check RES_IDX
    elseif phase == 4 and frame >= phase_frame + 600 then
        local idx = rb(0x80179BF3)
        log('load', string.format('RES_IDX=%d', idx))
        shot('04_ingame')
        if idx ~= 0 then
            log('load', 'SUCCESS - save loaded')
        else
            log('load', 'WARNING - RES_IDX still 0')
        end
        phase = 5
        phase_frame = frame
    -- Phase 5: Final screenshot
    elseif phase == 5 and frame >= phase_frame + 180 then
        shot('05_final')
        log('done', 'Finished')
        done = true
        PCSX.quit(0)
    elseif frame > 5000 then
        log('error', 'Timeout')
        done = true
        PCSX.quit(1)
    end
end)
