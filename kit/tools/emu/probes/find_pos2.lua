-- find_pos2.lua: smaller region, faster snap
local ffi = require('ffi')
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

local frame = 0
local done = false
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local function log(m) PCSX.log('fp2: ' .. m) end

-- Use FFI to copy memory fast
local function snap_fast(base, size)
    local o = base - 0x80000000
    local buf = ffi.new('uint8_t[?]', size)
    ffi.copy(buf, RAM + o, size)
    return buf
end

local s1, s2, s3
local BASE = 0x80170000
local SIZE = 0x10000

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if frame == 30 then
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        log('loaded frame=' .. frame)
    elseif frame == 90 then
        s1 = snap_fast(BASE, SIZE)
        log('snap1 frame=' .. frame)
        PAD.setOverride(B.UP)
    elseif frame == 200 then
        PAD.clearOverride(B.UP)
        s2 = snap_fast(BASE, SIZE)
        log('snap2 frame=' .. frame)
        PAD.setOverride(B.RIGHT)
    elseif frame == 310 then
        PAD.clearOverride(B.RIGHT)
        s3 = snap_fast(BASE, SIZE)
        log('snap3, analyzing...')
        
        local count = 0
        for i = 0, SIZE - 2, 2 do
            local w1 = s1[i] + s1[i+1]*256
            local w2 = s2[i] + s2[i+1]*256
            local w3 = s3[i] + s3[i+1]*256
            -- Changed in UP move (w1!=w2) and RIGHT move (w2!=w3)
            -- Small deltas (position-like)
            if w1 ~= w2 and w2 ~= w3 then
                local d1 = math.abs(w2 - w1)
                local d2 = math.abs(w3 - w2)
                if d1 < 500 and d2 < 500 and d1 > 0 and d2 > 0 then
                    count = count + 1
                    if count <= 25 then
                        log(string.format('  0x%08X: %d -> %d -> %d (d %d,%d)', 
                            BASE+i, w1, w2, w3, w2-w1, w3-w2))
                    end
                end
            end
        end
        log('total candidates: ' .. count)
        done = true
        PCSX.quit(0)
    elseif frame > 500 then
        log('timeout frame=' .. frame)
        done = true
        PCSX.quit(0)
    end
end)
