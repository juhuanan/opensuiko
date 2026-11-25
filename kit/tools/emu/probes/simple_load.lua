-- simple_load.lua: minimal loader, long boot wait
local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/sload'
local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

local frame = 0
local done = false
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local function rb(a) return RAM[a - 0x80000000] end
local function log(m) PCSX.log('sload: ' .. m) end

local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if ok and ss and ss.data then
        local wf = Support.File.open(OUT .. '_' .. tag .. '.raw', 'TRUNCATE')
        if wf then wf:writeMoveSlice(ss.data); wf:close() end
    end
end

local held = 0
local hold_until = 0

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if held ~= 0 and frame >= hold_until then
        PAD.clearOverride(held)
        held = 0
    end
    
    local function press(btn)
        held = btn
        hold_until = frame + 12
        PAD.setOverride(btn)
    end
    
    -- Boot: wait 5000 frames
    if frame == 5000 then
        log('START at title')
        shot('01_title')
        press(B.START)
    elseif frame == 5200 then
        log('DOWN to Continue')
        shot('02_menu')
        press(B.DOWN)
    elseif frame == 5300 then
        press(B.CROSS)
    elseif frame == 5500 then
        log('CROSS to load')
        shot('03_savelist')
        press(B.CROSS)
    elseif frame == 6200 then
        local idx = rb(0x80179BF3)
        log(string.format('RES_IDX=%d', idx))
        shot('04_ingame')
    elseif frame == 6500 then
        shot('05_final')
        log('done')
        done = true
        PCSX.quit(0)
    elseif frame > 7000 then
        done = true
        PCSX.quit(0)
    end
end)
