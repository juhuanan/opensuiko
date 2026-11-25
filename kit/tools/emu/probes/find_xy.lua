-- find_xy.lua: isolate X (RIGHT only) and Y (UP only)
local ffi = require('ffi')
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

local frame = 0
local done = false
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local function log(m) PCSX.log('fxy: ' .. m) end

local function snap_fast(base, size)
    local o = base - 0x80000000
    local buf = ffi.new('uint8_t[?]', size)
    ffi.copy(buf, RAM + o, size)
    return buf
end

local s_up1, s_up2, s_right1, s_right2
local BASE = 0x80170000
local SIZE = 0x10000

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if frame == 30 then
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
    elseif frame == 60 then
        s_up1 = snap_fast(BASE, SIZE)
        PAD.setOverride(B.UP)
    elseif frame == 170 then
        PAD.clearOverride(B.UP)
        s_up2 = snap_fast(BASE, SIZE)
        -- Reload to reset position
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
    elseif frame == 200 then
        s_right1 = snap_fast(BASE, SIZE)
        PAD.setOverride(B.RIGHT)
    elseif frame == 310 then
        PAD.clearOverride(B.RIGHT)
        s_right2 = snap_fast(BASE, SIZE)
        log('Analyzing...')
        
        -- Y candidates: changed in UP (s_up1!=s_up2), NOT in RIGHT (s_right1==s_right2)
        log('--- Y candidates (UP only) ---')
        local yc = 0
        for i = 0, SIZE - 2, 2 do
            local u1 = s_up1[i] + s_up1[i+1]*256
            local u2 = s_up2[i] + s_up2[i+1]*256
            local r1 = s_right1[i] + s_right1[i+1]*256
            local r2 = s_right2[i] + s_right2[i+1]*256
            if u1 ~= u2 and r1 == r2 then
                local d = u2 - u1
                if math.abs(d) < 500 and math.abs(d) > 5 then
                    yc = yc + 1
                    if yc <= 15 then
                        log(string.format('  0x%08X: %d -> %d (d %d)', BASE+i, u1, u2, d))
                    end
                end
            end
        end
        log('Y total: ' .. yc)
        
        -- X candidates: changed in RIGHT, NOT in UP
        log('--- X candidates (RIGHT only) ---')
        local xc = 0
        for i = 0, SIZE - 2, 2 do
            local u1 = s_up1[i] + s_up1[i+1]*256
            local u2 = s_up2[i] + s_up2[i+1]*256
            local r1 = s_right1[i] + s_right1[i+1]*256
            local r2 = s_right2[i] + s_right2[i+1]*256
            if r1 ~= r2 and u1 == u2 then
                local d = r2 - r1
                if math.abs(d) < 500 and math.abs(d) > 5 then
                    xc = xc + 1
                    if xc <= 15 then
                        log(string.format('  0x%08X: %d -> %d (d %d)', BASE+i, r1, r2, d))
                    end
                end
            end
        end
        log('X total: ' .. xc)
        
        done = true
        PCSX.quit(0)
    elseif frame > 500 then
        done = true
        PCSX.quit(0)
    end
end)
