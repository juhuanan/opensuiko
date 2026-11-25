-- find_pos.lua: diff RAM while hero moves to locate X/Y position
local ffi = require('ffi')
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/findpos'
local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

local frame = 0
local done = false
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local function log(m) PCSX.log('findpos: ' .. m) end

-- Snapshot a RAM region into a Lua string
local function snap(base, size)
    local o = base - 0x80000000
    local t = {}
    for i = 0, size - 1 do
        t[i+1] = string.char(RAM[o + i])
    end
    return table.concat(t)
end

local snap1, snap2, snap3
-- Focus on 0x80170000-0x80180000 (64KB, likely game state)
local BASE = 0x80170000
local SIZE = 0x10000

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if frame == 30 then
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        log('Palace loaded')
    elseif frame == 90 then
        snap1 = snap(BASE, SIZE)
        log('Snapshot 1 taken (before move)')
        PAD.setOverride(B.UP)
    elseif frame == 270 then
        -- After 3s moving UP
        PAD.clearOverride(B.UP)
        snap2 = snap(BASE, SIZE)
        log('Snapshot 2 taken (after UP)')
        PAD.setOverride(B.RIGHT)
    elseif frame == 450 then
        -- After 3s moving RIGHT
        PAD.clearOverride(B.RIGHT)
        snap3 = snap(BASE, SIZE)
        log('Snapshot 3 taken (after RIGHT)')
        
        -- Find bytes that changed in both moves (likely position)
        -- and changed by small amounts
        local candidates = {}
        for i = 1, SIZE do
            local b1 = snap1:byte(i)
            local b2 = snap2:byte(i)
            local b3 = snap3:byte(i)
            -- Changed in both moves
            if b1 ~= b2 and b2 ~= b3 then
                local addr = BASE + i - 1
                table.insert(candidates, string.format('0x%08X: %02X->%02X->%02X', addr, b1, b2, b3))
            end
        end
        log(string.format('Found %d bytes changed in both moves', #candidates))
        -- Log first 40
        for i = 1, math.min(40, #candidates) do
            log('  ' .. candidates[i])
        end
        
        -- Also find 16-bit words that changed
        log('--- 16-bit words changed in both ---')
        local wcount = 0
        for i = 1, SIZE - 1, 2 do
            local w1 = snap1:byte(i) + snap1:byte(i+1)*256
            local w2 = snap2:byte(i) + snap2:byte(i+1)*256
            local w3 = snap3:byte(i) + snap3:byte(i+1)*256
            if w1 ~= w2 and w2 ~= w3 and math.abs(w2-w1) < 1000 and math.abs(w3-w2) < 1000 then
                wcount = wcount + 1
                if wcount <= 20 then
                    log(string.format('  0x%08X: %d -> %d -> %d', BASE+i-1, w1, w2, w3))
                end
            end
        end
        log(string.format('Found %d 16-bit candidates', wcount))
        
        done = true
        PCSX.quit(0)
    elseif frame > 600 then
        done = true
        PCSX.quit(0)
    end
end)
