-- menu_explore.lua: press SQUARE to open command menu, screenshot it

local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/menu'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local frame = 0
local state = 0
local done = false

local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if ok and ss and ss.data then
        local wf = Support.File.open(OUT .. '_' .. tag .. '.raw', 'TRUNCATE')
        wf:writeMoveSlice(ss.data)
        wf:close()
        PCSX.log('menu: screenshot ' .. tag)
    end
end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if state == 0 and frame == 60 then
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        if not ok then done = true; PCSX.quit(0) return end
        shot('ingame')
        state = 1
    elseif state == 1 and frame == 120 then
        PCSX.log('menu: pressing SQUARE (command menu)')
        PAD.setOverride(B.SQUARE)
        state = 2
    elseif state == 2 and frame == 132 then
        PAD.clearOverride(B.SQUARE)
        state = 3
    elseif state == 3 and frame == 180 then
        shot('menu_open')
        PCSX.log('menu: menu should be open')
        -- Try pressing DOWN to navigate
        PAD.setOverride(B.DOWN)
        state = 4
    elseif state == 4 and frame == 192 then
        PAD.clearOverride(B.DOWN)
        state = 5
    elseif state == 5 and frame == 240 then
        shot('menu_nav')
        done = true
        PCSX.quit(0)
    elseif frame > 600 then
        done = true
        PCSX.quit(0)
    end
end)
