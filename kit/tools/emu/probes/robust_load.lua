-- robust_load.lua: load save with state detection, not fixed frames
local ffi = require('ffi')
local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

local frame = 0
local phase = 0
local done = false
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local function rb(a) return RAM[a - 0x80000000] end
local function log(tag, msg) PCSX.log('robust: [' .. tag .. '] ' .. msg) end

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
    
    -- Phase 0: Wait for boot (frame 300), press START
    if phase == 0 and frame >= 300 then
        log('phase', 'pressing START at title')
        press(B.START)
        phase = 1
        phase_frame = frame
    -- Phase 1: Wait 60 frames, press DOWN (to Continue)
    elseif phase == 1 and frame >= phase_frame + 60 then
        log('phase', 'pressing DOWN to Continue')
        press(B.DOWN)
        phase = 2
        phase_frame = frame
    -- Phase 2: Wait 30 frames, press CROSS (select Continue)
    elseif phase == 2 and frame >= phase_frame + 30 then
        log('phase', 'pressing CROSS (Continue)')
        press(B.CROSS)
        phase = 3
        phase_frame = frame
    -- Phase 3: Wait 120 frames, press CROSS (load save)
    elseif phase == 3 and frame >= phase_frame + 120 then
        log('phase', 'pressing CROSS (load save file)')
        press(B.CROSS)
        phase = 4
        phase_frame = frame
    -- Phase 4: Wait for RES_IDX to become non-zero (save loaded)
    elseif phase == 4 then
        local idx = rb(0x80179BF3)
        if idx ~= 0 then
            log('success', string.format('Save loaded! RES_IDX=%d at frame %d', idx, frame))
            phase = 5
            phase_frame = frame
        elseif frame >= phase_frame + 600 then
            log('error', 'Timeout waiting for save to load')
            done = true
            PCSX.quit(1)
        end
    -- Phase 5: Wait 120 frames for stable, then dump
    elseif phase == 5 and frame >= phase_frame + 120 then
        local idx = rb(0x80179BF3)
        log('result', string.format('Final RES_IDX=%d', idx))
        done = true
        PCSX.quit(0)
    elseif frame > 3000 then
        log('error', 'Global timeout')
        done = true
        PCSX.quit(1)
    end
end)
