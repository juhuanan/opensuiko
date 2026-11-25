-- time_load.lua: use wall-clock time for delays, not frames
local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/tload'
local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

local start_time = os.clock()
local phase = 0
local done = false
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local function rb(a) return RAM[a - 0x80000000] end
local function log(m) PCSX.log(string.format('tload [%.1fs]: %s', os.clock() - start_time, m)) end

local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if ok and ss and ss.data then
        local wf = Support.File.open(OUT .. '_' .. tag .. '.raw', 'TRUNCATE')
        if wf then wf:writeMoveSlice(ss.data); wf:close() end
    end
end

local hold_until = 0
local held = 0

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    
    local elapsed = os.clock() - start_time
    
    if held ~= 0 and elapsed >= hold_until then
        PAD.clearOverride(held)
        held = 0
    end
    
    local function press(btn, dur)
        dur = dur or 0.2
        held = btn
        hold_until = elapsed + dur
        PAD.setOverride(btn)
    end
    
    if phase == 0 and elapsed >= 75 then
        -- 75 seconds for boot (generous)
        log('Pressing START at title')
        shot('01_title')
        press(B.START)
        phase = 1
    elseif phase == 1 and elapsed >= 78 then
        log('DOWN to Continue')
        shot('02_menu')
        press(B.DOWN)
        phase = 2
    elseif phase == 2 and elapsed >= 79 then
        press(B.CROSS)
        phase = 3
    elseif phase == 3 and elapsed >= 82 then
        log('CROSS to load save')
        shot('03_savelist')
        press(B.CROSS)
        phase = 4
    elseif phase == 4 and elapsed >= 90 then
        local idx = rb(0x80179BF3)
        log(string.format('RES_IDX=%d', idx))
        shot('04_ingame')
        phase = 5
    elseif phase == 5 and elapsed >= 95 then
        shot('05_final')
        log('Done')
        done = true
        PCSX.quit(0)
    elseif elapsed > 120 then
        log('Timeout')
        done = true
        PCSX.quit(1)
    end
end)
