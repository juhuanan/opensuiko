-- name_handoff.lua: capture RAM after name confirm, before MAIN.EXE clobbers it
-- Based on walkthrough.lua, dumps RAM at the handoff moment

local ffi = require('ffi')
local bit = require('bit')
local OUTDIR = os.getenv('SUIKODEN_OUT') or '/tmp/name_handoff'
local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

-- Button constants
local B = {
    UP = 0x1000, DOWN = 0x4000, LEFT = 0x8000, RIGHT = 0x2000,
    CROSS = 0x0040, CIRCLE = 0x0020, SQUARE = 0x0080, TRIANGLE = 0x0010,
    START = 0x0008, SELECT = 0x0001,
}

local frame = 0
local queue = {}
local done = false
local dumped = false

-- Controller input via pad
-- PCSX-Redux Lua: use PCSX.setPadInput? Let's try the walkthrough's method
-- Walkthrough uses a tap() function - let's replicate it

local pad_state = 0

-- Try to find the pad input method from walkthrough
-- For now, we'll use a simple approach: write directly to pad memory
-- PS1 pad is at 0x1F801040, but PCSX-Redux Lua might have an API

local function after(n, fn) queue[#queue + 1] = { at = frame + n, fn = fn } end
local function wait(n, next) after(n, next) end

local function tap(button, hold, next)
    -- Set button pressed
    pad_state = bit.bor(pad_state, button)
    -- TODO: actually set the pad input
    -- For now, we'll need to find the right API
    wait(hold, function()
        pad_state = bit.band(pad_state, bit.bnot(button))
        wait(10, next)
    end)
end

-- Simplified: we just need to get to name entry and dump
-- Actually, let's do the full walkthrough but dump at the critical moment

local FMV_CB = 0x80018488  -- from emulator.md, but this is the callback addr

local function get_cb()
    -- Read the callback pointer - from walkthrough
    return 0
end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    -- Process queue
    for i = #queue, 1, -1 do
        if queue[i].at <= frame then
            local fn = queue[i].fn
            table.remove(queue, i)
            fn()
        end
    end
    
    -- At frame 6500 (after naming, before MAIN.EXE fully boots), dump RAM
    -- Naming completes around frame 5673 + 400 + 600 + 800 = ~7500?
    -- Let's dump at multiple points to catch the handoff
    
    if frame == 7000 and not dumped then
        dumped = true
        -- Dump RAM to file
        local f = io.open(OUTDIR .. '_f7000.bin', 'wb')
        f:write(ffi.string(RAM, 0x200000))
        f:close()
        PCSX.log('name_handoff: dumped RAM at frame 7000')
    end
    
    if frame == 8000 then
        local f = io.open(OUTDIR .. '_f8000.bin', 'wb')
        f:write(ffi.string(RAM, 0x200000))
        f:close()
        PCSX.log('name_handoff: dumped RAM at frame 8000')
        done = true
        PCSX.quit(0)
    end
end)

-- Start the boot sequence (simplified from walkthrough)
-- We need to actually drive the inputs...
-- This is getting complex. Let me just use the existing walkthrough
-- and add dumps to it.

PCSX.log('name_handoff: probe loaded, but needs walkthrough integration')
-- Quit immediately, we'll integrate differently
done = true
PCSX.quit(0)
