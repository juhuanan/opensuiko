-- load_save2.lua: corrected timing for slow boot
local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/loadsave3'
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
        if wf then wf:writeMoveSlice(ss.data); wf:close() end
        PCSX.log('ls2: screenshot ' .. tag)
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
    
    local function press(btn)
        held_btn = btn
        hold_until = frame + 15
        PAD.setOverride(btn)
    end
    
    if state == 0 and frame == 3200 then
        PCSX.log('ls2: pressing START at title')
        shot('01_title')
        press(B.START)
        state = 1
    elseif state == 1 and frame == 3400 then
        PCSX.log('ls2: DOWN to Continue')
        shot('02_menu')
        press(B.DOWN)
        state = 2
    elseif state == 2 and frame == 3500 then
        press(B.CROSS)
        state = 3
    elseif state == 3 and frame == 3750 then
        PCSX.log('ls2: CROSS to load save')
        shot('03_savelist')
        press(B.CROSS)
        state = 4
    elseif state == 4 and frame == 4300 then
        PCSX.log('ls2: in game')
        shot('04_ingame')
        local res_idx = RAM[0x80179BF3 - 0x80000000]
        PCSX.log(string.format('ls2: RES_IDX=%d', res_idx))
        state = 5
    elseif state == 5 and frame == 4600 then
        shot('05_final')
        PCSX.log('ls2: done')
        done = true
        PCSX.quit(0)
    elseif frame > 5500 then
        PCSX.log('ls2: timeout')
        done = true
        PCSX.quit(0)
    end
end)
