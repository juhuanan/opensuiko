-- dump_cave_mem.lua: load save, dump memory state (no save state)
local ffi = require('ffi')
local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

local frame = 0
local state = 0
local done = false
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local function rb(a) return RAM[a - 0x80000000] end
local function rw(a) 
    return RAM[a - 0x80000000] + RAM[a - 0x80000000 + 1] * 256
end
local function rl(a)
    local o = a - 0x80000000
    return RAM[o] + RAM[o+1]*256 + RAM[o+2]*65536 + RAM[o+3]*16777216
end

local function log(tag, msg)
    PCSX.log('dump: [' .. tag .. '] ' .. msg)
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
        held_btn = B.START; hold_until = frame + 10; PAD.setOverride(B.START)
        state = 1
    elseif state == 1 and frame == 400 then
        held_btn = B.DOWN; hold_until = frame + 10; PAD.setOverride(B.DOWN)
        state = 2
    elseif state == 2 and frame == 450 then
        held_btn = B.CROSS; hold_until = frame + 10; PAD.setOverride(B.CROSS)
        state = 3
    elseif state == 3 and frame == 600 then
        held_btn = B.CROSS; hold_until = frame + 10; PAD.setOverride(B.CROSS)
        state = 4
    elseif state == 4 and frame == 1500 then
        -- Dump memory state
        log('res', string.format('RES_IDX (0x80179BF3) = %d', rb(0x80179BF3)))
        log('res', string.format('SEQ (0x80179C02) = %d', rb(0x80179C02)))
        log('res', string.format('SM (0x80179C04) = 0x%02X', rb(0x80179C04)))
        log('res', string.format('.8 ptr (0x8017BFC0) = 0x%08X', rl(0x8017BFC0)))
        log('res', string.format('table ptr (0x8017BF98) = 0x%08X', rl(0x8017BF98)))
        
        local idx = rb(0x80179BF3)
        local entry = 0x80164E68 + idx * 12
        log('res', string.format('res[%d] entry at 0x%08X: LBA=0x%08X', idx, entry, rl(entry)))
        
        -- Dump first few bytes of .8 data if pointer is valid
        local ptr = rl(0x8017BFC0)
        if ptr >= 0x80000000 and ptr < 0x80200000 then
            local o = ptr - 0x80000000
            log('data', string.format('.8 data first 16 bytes: %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X',
                RAM[o], RAM[o+1], RAM[o+2], RAM[o+3], RAM[o+4], RAM[o+5], RAM[o+6], RAM[o+7],
                RAM[o+8], RAM[o+9], RAM[o+10], RAM[o+11], RAM[o+12], RAM[o+13], RAM[o+14], RAM[o+15]))
        end
        
        done = true
        PCSX.quit(0)
    elseif frame > 1800 then
        done = true
        PCSX.quit(0)
    end
end)
