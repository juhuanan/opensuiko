-- teo_trigger_test.lua: walk hero from right toward Teo, watch for auto-dialog
-- Based on user intel: approach from right, dialog opens automatically, no button press

local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/teo_trigger'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

-- From walkthrough.lua - pad input method
-- We need to replicate the tap() function
local frame = 0
local queue = {}
local done = false
local loaded = false

-- Pad state - PCSX-Redux Lua API for pad input
-- Walkthrough uses: PCSX.setPadInput? Let's check what it actually uses
-- For now, try direct memory write to pad area

local function after(n, fn) queue[#queue + 1] = { at = frame + n, fn = fn } end
local function wait(n, next) after(n, next) end

local function tap(btn, hold, next)
    PAD.setOverride(btn)
    wait(hold, function()
        PAD.clearOverride(btn)
        wait(10, next)
    end)
end

-- Hold a direction for N frames (for walking)
local function hold_dir(btn, n, next)
    PAD.setOverride(btn)
    wait(n, function()
        PAD.clearOverride(btn)
        wait(10, next)
    end)
end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    for i = #queue, 1, -1 do
        if queue[i].at <= frame then
            local fn = queue[i].fn
            table.remove(queue, i)
            fn()
        end
    end
    
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        if not ok then done = true; PCSX.quit(0) return end
        
        -- After load, walk RIGHT first (to get to right side), then LEFT toward Teo
        -- User intel: hero approaches Teo from the RIGHT
        wait(60, function()
            PCSX.log('teo_trigger: walking RIGHT to get to right side')
            -- Walk right for 120 frames (2 seconds)
            hold_dir(B.RIGHT, 120, function()
                PCSX.log('teo_trigger: now walking LEFT toward Teo')
                -- Take screenshot before walking left
                local ok, ss = pcall(PCSX.GPU.takeScreenShot)
                if ok and ss and ss.data then
                    local wf = Support.File.open(OUT .. '_before_left.raw', 'TRUNCATE')
                    wf:writeMoveSlice(ss.data)
                    wf:close()
                end
                -- Walk left for 180 frames (3 seconds) - should pass Teo's position
                hold_dir(B.LEFT, 180, function()
                    PCSX.log('teo_trigger: finished walking, taking screenshot')
                    local ok2, ss2 = pcall(PCSX.GPU.takeScreenShot)
                    if ok2 and ss2 and ss2.data then
                        local wf2 = Support.File.open(OUT .. '_after_left.raw', 'TRUNCATE')
                        wf2:writeMoveSlice(ss2.data)
                        wf2:close()
                    end
                    done = true
                    PCSX.quit(0)
                end)
            end)
        end)
    end
    
    if frame > 600 then
        done = true
        PCSX.quit(0)
    end
end)
