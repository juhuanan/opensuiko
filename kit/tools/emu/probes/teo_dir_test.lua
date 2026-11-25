-- teo_dir_test.lua: position hero, press RIGHT (direction toward Teo) to talk
-- Talk dispatcher 0x8012C868 uses input masked by 0xF000 (directions)

local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/teo_dir'
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

local function hold_dir(btn, n, next)
    PAD.setOverride(btn)
    wait(n, function()
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
        PCSX.log('teo_dir: screenshot ' .. tag)
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
            PCSX.log('teo_dir: walking RIGHT to position near Teo')
            -- Walk right to get close to Teo (but not past him)
            hold_dir(B.RIGHT, 90, function()
                shot('positioned')
                PCSX.log('teo_dir: tapping RIGHT to talk (Teo is to the right)')
                -- Tap RIGHT (direction toward Teo) to initiate talk
                -- The dispatcher masks by 0xF000, so direction buttons trigger it
                tap(B.RIGHT, 12, function()
                    wait(120, function()
                        shot('after_tap')
                        PCSX.log('teo_dir: checking for dialog')
                        wait(180, function()
                            shot('dialog_check')
                            done = true
                            PCSX.quit(0)
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
