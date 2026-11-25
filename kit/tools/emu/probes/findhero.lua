-- findhero.lua: diff RAM to find hero position address
-- Dump RAM, move right, dump again, the changed X is the hero

local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/findhero'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local frame = 0
local queue = {}
local done = false
local loaded = false
local dump1 = nil

local function after(n, fn) queue[#queue + 1] = { at = frame + n, fn = fn } end
local function wait(n, next) after(n, next) end

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
            -- Dump 1: before movement
            PCSX.log('findhero: dumping RAM before')
            local f1 = io.open(OUT .. '_before.bin', 'wb')
            f1:write(ffi.string(RAM, 0x200000))
            f1:close()
            
            -- Hold RIGHT for 60 frames
            PCSX.log('findhero: holding RIGHT')
            PAD.setOverride(B.RIGHT)
            wait(60, function()
                PAD.clearOverride(B.RIGHT)
                wait(30, function()
                    -- Dump 2: after movement
                    PCSX.log('findhero: dumping RAM after')
                    local f2 = io.open(OUT .. '_after.bin', 'wb')
                    f2:write(ffi.string(RAM, 0x200000))
                    f2:close()
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
