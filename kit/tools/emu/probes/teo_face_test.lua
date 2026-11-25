-- teo_face_test.lua: face right toward Teo, then talk
-- Hero must be FACING Teo for the hit test to find him

local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/teo_face'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local frame = 0
local queue = {}
local done = false
local loaded = false

local function after(n, fn) queue[#queue + 1] = { at = frame + n, fn = fn } end
local function wait(n, next) after(n, next) end

local function tap(btn, hold, next)
    PAD.setOverride(btn)
    wait(hold, function()
        PAD.clearOverride(btn)
        wait(10, next)
    end)
end

local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if ok and ss and ss.data then
        local wf = Support.File.open(OUT .. '_' .. tag .. '.raw', 'TRUNCATE')
        wf:writeMoveSlice(ss.data)
        wf:close()
        PCSX.log('teo_face: screenshot ' .. tag)
    end
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
        
        wait(60, function()
            -- Step 1: Tap RIGHT briefly to face right (toward Teo)
            -- Do NOT hold, just tap to change facing
            PCSX.log('teo_face: tapping RIGHT to face Teo')
            tap(B.RIGHT, 6, function()
                wait(30, function()
                    shot('facing_right')
                    -- Step 2: Now tap RIGHT again to trigger talk
                    -- Hero is now facing right, Teo is to the right
                    PCSX.log('teo_face: tapping RIGHT again to talk')
                    tap(B.RIGHT, 12, function()
                        wait(120, function()
                            shot('after_talk')
                            wait(180, function()
                                shot('final')
                                done = true
                                PCSX.quit(0)
                            end)
                        end)
                    end)
                end)
            end)
        end)
    end
    
    if frame > 900 then
        done = true
        PCSX.quit(0)
    end
end)
