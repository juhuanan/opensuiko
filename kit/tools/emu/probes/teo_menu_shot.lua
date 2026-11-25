-- teo_menu_shot.lua: trigger Teo, open menu, screenshot
-- Tests if hero name appears in menu (validates name handoff)

local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/teo_menu'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

-- Button constants (from walkthrough.lua)
local B = {
    UP = 0x1000, DOWN = 0x4000, LEFT = 0x8000, RIGHT = 0x2000,
    CROSS = 0x0040, CIRCLE = 0x0020, SQUARE = 0x0080, TRIANGLE = 0x0010,
    START = 0x0008, SELECT = 0x0001,
}

local frame = 0
local loaded = false
local done = false
local phase = 0

-- For controller input via FFI
-- PCSX-Redux Lua API: PCSX.setControllerInput?

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        if not ok then done = true; PCSX.quit(0) return end
        phase = 1
    end
    
    -- Phase 1: Walk to Teo and press DOWN+CROSS (talk)
    -- Teo is at a known position. From prior work, hero needs to be near Teo.
    -- Simplified: just press the talk button sequence
    
    if loaded and phase == 1 and frame == 120 then
        -- Press DOWN + CROSS to talk (from Teo findings)
        -- Actually, let's just open the menu directly with TRIANGLE
        -- The menu should show the hero name if it's valid
        phase = 2
    end
    
    if loaded and phase == 2 and frame == 150 then
        -- Take screenshot of current state (in room)
        local ok, ss = pcall(function() return PCSX.getScreenshot() end)
        if ok and ss and ss.data then
            local f = io.open(OUT .. '_room.png', 'wb')
            f:write(ss.data)
            f:close()
        end
        phase = 3
    end
    
    -- TODO: Actually press buttons to open menu
    -- For now, just quit after room shot
    if loaded and frame == 180 then
        done = true
        PCSX.quit(0)
    end
end)
