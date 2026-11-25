-- find_door.lua: wander palace systematically, watch for area change
local ffi = require('ffi')
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

local frame = 0
local done = false
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local function rb(a) return RAM[a - 0x80000000] end
local function rl(a)
    local o = a - 0x80000000
    return RAM[o] + RAM[o+1]*256 + RAM[o+2]*65536 + RAM[o+3]*16777216
end
local function log(m) PCSX.log('door: ' .. m) end

-- Movement pattern: try each direction for a while
-- We'll do: UP 4s, RIGHT 4s, DOWN 4s, LEFT 4s, repeat
local directions = {B.UP, B.RIGHT, B.DOWN, B.LEFT}
local dir_names = {"UP", "RIGHT", "DOWN", "LEFT"}
local current_dir = 1
local dir_start_frame = 0
local last_idx = 4

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if frame == 30 then
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        log('Palace loaded, starting search')
        dir_start_frame = frame
        PAD.setOverride(directions[current_dir])
    elseif frame > 30 then
        -- Check for area change every frame
        local idx = rb(0x80179BF3)
        if idx ~= last_idx then
            log(string.format('AREA CHANGE! %d -> %d at frame %d', last_idx, idx, frame))
            log(string.format('.8ptr=0x%08X', rl(0x8017BFC0)))
            PAD.clearOverride(directions[current_dir])
            done = true
            PCSX.quit(0)
            return
        end
        
        -- Change direction every 240 frames (4 seconds)
        if frame >= dir_start_frame + 240 then
            PAD.clearOverride(directions[current_dir])
            current_dir = current_dir % 4 + 1
            log(string.format('Changing to %s', dir_names[current_dir]))
            PAD.setOverride(directions[current_dir])
            dir_start_frame = frame
        end
    end
    
    if frame > 3000 then
        log('No door found in 3000 frames')
        PAD.clearOverride(directions[current_dir])
        done = true
        PCSX.quit(0)
    end
end)
