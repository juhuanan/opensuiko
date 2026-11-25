-- grid_search.lua: systematic grid search for exits
local ffi = require('ffi')
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/grid'
local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

local frame = 0
local done = false
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local function rb(a) return RAM[a - 0x80000000] end
local function rw(a)
    local o = a - 0x80000000
    return RAM[o] + RAM[o+1]*256
end
local function log(m) PCSX.log('grid: ' .. m) end

local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if ok and ss and ss.data then
        local wf = Support.File.open(OUT .. '_' .. tag .. '.raw', 'TRUNCATE')
        if wf then wf:writeMoveSlice(ss.data); wf:close() end
    end
end

-- Grid pattern: move in expanding squares
-- We'll do a sequence of moves
local moves = {}
-- Build a spiral: right 2s, down 2s, left 4s, up 4s, right 6s, etc.
local dirs = {B.RIGHT, B.DOWN, B.LEFT, B.UP}
local dir_names = {"RIGHT", "DOWN", "LEFT", "UP"}
local steps = {120, 120, 240, 240, 360, 360, 480, 480}  -- frames per leg

local move_idx = 1
local move_start = 0
local last_idx = 4

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if frame == 30 then
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        log('Palace loaded, starting grid search')
        log(string.format('Start Y=%d', rw(0x8017C010)))
        shot('00_start')
        move_start = frame
        PAD.setOverride(dirs[1])
    elseif frame > 30 then
        -- Check for transition
        local idx = rb(0x80179BF3)
        if idx ~= last_idx then
            log(string.format('TRANSITION! %d -> %d at frame %d', last_idx, idx, frame))
            PAD.clearOverride(dirs[(move_idx-1) % 4 + 1])
            shot('99_transition')
            done = true
            PCSX.quit(0)
            return
        end
        
        -- Advance move
        if move_idx <= #steps and frame >= move_start + steps[move_idx] then
            PAD.clearOverride(dirs[(move_idx-1) % 4 + 1])
            move_idx = move_idx + 1
            if move_idx <= #steps then
                local d = (move_idx-1) % 4 + 1
                log(string.format('Leg %d: %s for %d frames (Y=%d)', 
                    move_idx, dir_names[d], steps[move_idx], rw(0x8017C010)))
                PAD.setOverride(dirs[d])
                move_start = frame
            else
                log('Grid complete, no transition')
                log(string.format('Final Y=%d', rw(0x8017C010)))
                shot('98_end')
                done = true
                PCSX.quit(0)
            end
        end
    end
    
    if frame > 5000 then
        log('Timeout')
        done = true
        PCSX.quit(0)
    end
end)
