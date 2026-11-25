-- capture_cave2.lua: load save, wait for stable, screenshot and save state (fixed)
local ffi = require('ffi')
local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

local frame = 0
local state = 0
local done = false
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local function log(tag, msg)
    PCSX.log('cave2: [' .. tag .. '] ' .. msg)
end

local hold_until = 0
local held_btn = 0

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if held_btn ~= 0 and frame >= hold_until then
        PAD.clearOverride(held_btn)
        held_btn = 0
    end
    
    if state == 0 and frame == 300 then
        log('phase', 'START at title')
        held_btn = B.START; hold_until = frame + 10; PAD.setOverride(B.START)
        state = 1
    elseif state == 1 and frame == 400 then
        log('phase', 'DOWN to Continue')
        held_btn = B.DOWN; hold_until = frame + 10; PAD.setOverride(B.DOWN)
        state = 2
    elseif state == 2 and frame == 450 then
        held_btn = B.CROSS; hold_until = frame + 10; PAD.setOverride(B.CROSS)
        state = 3
    elseif state == 3 and frame == 600 then
        log('phase', 'CROSS to load save')
        held_btn = B.CROSS; hold_until = frame + 10; PAD.setOverride(B.CROSS)
        state = 4
    elseif state == 4 and frame == 1500 then
        -- In game, dump info
        local res_idx = RAM[0x80179BF3 - 0x80000000]
        local seq = RAM[0x80179C02 - 0x80000000]
        log('info', string.format('RES_IDX=%d SEQ=%d', res_idx, seq))
        state = 5
    elseif state == 5 and frame == 1800 then
        -- Save state using relative path (like working probes)
        log('phase', 'saving state')
        local sf = Support.File.open('kit/tools/emu/fixtures/cave.pcsxstate', 'w')
        if sf then 
            pcall(function() PCSX.saveSaveState(sf) end)
            sf:close()
            log('saved', 'cave.pcsxstate')
        else
            log('error', 'failed to open file')
        end
        done = true
        PCSX.quit(0)
    elseif frame > 2100 then
        log('error', 'timeout')
        done = true
        PCSX.quit(0)
    end
end)
