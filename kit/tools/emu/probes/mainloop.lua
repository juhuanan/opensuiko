-- mainloop.lua
-- Trace the self-replacing per-frame callback at 0x800B1938.
--
-- Every vsync, reads the callback pointer; logs each transition
-- (old -> new). A Write breakpoint on the pointer additionally captures
-- the writer PC/RA and the pre-store value (the debug hook runs before
-- the store, so the in-RAM value at hit time is the OLD value).
--
-- Closes the runtime question: what are the callback transitions
-- through 0x800B1938 during boot -> title?
--
-- Env:
--   SUIKODEN_OUT     output CSV path (default: /tmp/mainloop.csv)
--   SUIKODEN_FRAMES  vsync budget before auto-quit (default: 7200)

local ffi = require('ffi')
local bit = require('bit')

local OUT    = os.getenv('SUIKODEN_OUT') or '/tmp/mainloop.csv'
local FRAMES = tonumber(os.getenv('SUIKODEN_FRAMES') or '7200')
local CB_PTR = 0x800B1938

ANCHORS = ANCHORS or {}
local RAM = ffi.cast('uint32_t *', PCSX.getMemPtr())

local function u32(addr)
    local phys = bit.band(addr, 0x1FFFFFFF)
    return tonumber(RAM[bit.rshift(phys, 2)])
end

local function norm(v) return bit.band(tonumber(v) or 0, 0xFFFFFFFF) end

local fh = assert(io.open(OUT, 'w'))
fh:write('frame,event,old,new,writer_pc,writer_ra\n')

local frames = 0
local last = nil
local transitions = 0

local function cur()
    local ok, v = pcall(u32, CB_PTR)
    if ok then return v end
    return 0
end

local function note(event, old, new, wpc, wra)
    fh:write(string.format('%d,%s,0x%08X,0x%08X,0x%08X,0x%08X\n',
        frames, event, old or 0, new or 0, wpc or 0, wra or 0))
    fh:flush()
    transitions = transitions + 1
    PCSX.log(string.format('mainloop: [%d] %s 0x%08X -> 0x%08X', frames, event, old or 0, new or 0))
end

-- writer capture: pre-store value is still in RAM when the hook fires
local wbp = PCSX.addBreakpoint(CB_PTR, 'Write', 4, 'callback pointer write', function()
    local ok, err = pcall(function()
        local old = cur()
        local r = PCSX.getRegisters()
        local gpr = r.GPR and r.GPR.n
        local ra = 0
        if gpr then
            local ok2, v = pcall(function() return gpr['ra'] end)
            if ok2 then ra = norm(v) end
        end
        local wpc = norm(r.pc)
        -- re-read after: the store may have completed by the time we return,
        -- so poll once more on the next vsync; for now record old + writer
        note('write', old, 0, wpc, ra)
        last = nil -- force the vsync sampler to re-log the new value
    end)
    if not ok then PCSX.log('mainloop: write-bp error: ' .. tostring(err)) end
end)
ANCHORS[#ANCHORS + 1] = wbp

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    frames = frames + 1
    local v = cur()
    if last == nil then
        note('sample', v, v, 0, 0)
    elseif v ~= last then
        note('transition', last, v, 0, 0)
    end
    last = v
    if frames >= FRAMES then
        fh:close()
        PCSX.log(string.format('mainloop: done, frames=%d transitions=%d -> %s', frames, transitions, OUT))
        PCSX.quit(0)
    end
end)
ANCHORS[#ANCHORS + 1] = vl
PCSX.log('mainloop: tracing 0x800B1938, out=' .. OUT)
