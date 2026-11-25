-- menu_submenu.lua: open menu, select Item, screenshot contents

local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/menusub'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local frame = 0
local state = 0
local done = false

local function press(btn, hold_frames)
    PAD.setOverride(btn)
    return hold_frames
end

local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if ok and ss and ss.data then
        local wf = Support.File.open(OUT .. '_' .. tag .. '.raw', 'TRUNCATE')
        wf:writeMoveSlice(ss.data)
        wf:close()
        PCSX.log('menusub: screenshot ' .. tag)
    end
end

local hold_until = 0
local next_state = 0

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    -- Handle button hold release
    if hold_until > 0 and frame >= hold_until then
        PAD.clearOverride(B.SQUARE)
        PAD.clearOverride(B.CROSS)
        PAD.clearOverride(B.DOWN)
        PAD.clearOverride(B.CIRCLE)
        hold_until = 0
        state = next_state
    end
    
    if state == 0 and frame == 60 then
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        if not ok then done = true; PCSX.quit(0) return end
        state = 1
    elseif state == 1 and frame == 120 then
        -- Open menu with SQUARE
        PCSX.log('menusub: opening menu')
        PAD.setOverride(B.SQUARE)
        hold_until = frame + 12
        next_state = 2
        state = 99  -- wait for release
    elseif state == 2 and frame == 180 then
        shot('menu_main')
        -- Select first option (Item) with CROSS
        PCSX.log('menusub: selecting Item')
        PAD.setOverride(B.CROSS)
        hold_until = frame + 12
        next_state = 3
        state = 99
    elseif state == 3 and frame == 250 then
        shot('menu_item')
        PCSX.log('menusub: item submenu should be open')
        -- Go back with CIRCLE
        PAD.setOverride(B.CIRCLE)
        hold_until = frame + 12
        next_state = 4
        state = 99
    elseif state == 4 and frame == 320 then
        shot('menu_back')
        -- Navigate down to Strength and select
        PAD.setOverride(B.DOWN)
        hold_until = frame + 12
        next_state = 5
        state = 99
    elseif state == 5 and frame == 380 then
        PAD.setOverride(B.CROSS)
        hold_until = frame + 12
        next_state = 6
        state = 99
    elseif state == 6 and frame == 450 then
        shot('menu_strength')
        PCSX.log('menusub: strength submenu')
        done = true
        PCSX.quit(0)
    elseif frame > 900 then
        done = true
        PCSX.quit(0)
    end
end)
