-- overlay_load.lua
-- Trace Suikoden's overlay/CD loading path at runtime.
--
-- Breakpoints:
--   0x8001B5C8(overlay_id)  - LBA table lookup (344-entry table at 0x8004500C)
--   0x8001B6FC(desc, dest)  - issues the CD read; desc -> {size@+0, lba@+4}
--   0x8001B308(overlay_id)  - 6-slot allocator/loader
--
-- Logs one CSV row per load issued: frame, func, overlay_id/size/lba/dest.
--
-- Env:
--   SUIKODEN_OUT     output CSV path (default: /tmp/overlay_load.csv)
--   SUIKODEN_FRAMES  vsync budget before auto-quit (default: 7200)

local ffi = require('ffi')
local bit = require('bit')

local OUT    = os.getenv('SUIKODEN_OUT') or '/tmp/overlay_load.csv'
local FRAMES = tonumber(os.getenv('SUIKODEN_FRAMES') or '7200')

ANCHORS = ANCHORS or {}
local RAM = ffi.cast('uint32_t *', PCSX.getMemPtr())

local function u32(addr)
    -- KSEG0/KSEG1 -> physical
    local phys = bit.band(addr, 0x1FFFFFFF)
    return tonumber(RAM[bit.rshift(phys, 2)])
end

local function norm(v) return bit.band(tonumber(v) or 0, 0xFFFFFFFF) end

local fh = assert(io.open(OUT, 'w'))
fh:write('frame,func,overlay_id,desc,size,lba,dest,ra\n')

local frames = 0
local loads = 0

local function regs()
    local r = PCSX.getRegisters()
    local gpr = r.GPR and r.GPR.n or nil
    local function g(name)
        if gpr then
            local ok, v = pcall(function() return gpr[name] end)
            if ok then return norm(v) end
        end
        return 0
    end
    return { pc = norm(r.pc), a0 = g('a0'), a1 = g('a1'), a2 = g('a2'), a3 = g('a3'), ra = g('ra') }
end

local function log_load(func, ov_id, desc)
    local r = regs()
    local size, lba = 0, 0
    if desc ~= 0 then
        local ok, s = pcall(u32, desc)
        if ok then size = s end
        local ok2, l = pcall(u32, desc + 4)
        if ok2 then lba = l end
    end
    fh:write(string.format('%d,%s,%d,0x%08X,0x%X,%d,0x%08X,0x%08X\n',
        frames, func, ov_id or -1, desc or 0, size, lba, r.a1, r.ra))
    fh:flush()
    loads = loads + 1
end

local function arm(addr, kind, label, cb)
    local bp = PCSX.addBreakpoint(addr, 'Exec', 4, label, function()
        local ok, err = pcall(cb)
        if not ok then PCSX.log('overlay_load: breakpoint error: ' .. tostring(err)) end
    end)
    ANCHORS[#ANCHORS + 1] = bp
    PCSX.log('overlay_load: armed ' .. label .. string.format(' @0x%08X', addr))
end

arm(0x8001B5C8, 'Exec', 'overlay lookup', function()
    local r = regs()
    log_load('lookup', r.a0, 0)
end)

arm(0x8001B6FC, 'Exec', 'cd read issue', function()
    local r = regs()
    log_load('cdread', -1, r.a0)
end)

arm(0x8001B308, 'Exec', 'slot allocator', function()
    local r = regs()
    log_load('alloc', r.a0, 0)
end)

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    frames = frames + 1
    if frames >= FRAMES then
        fh:close()
        PCSX.log(string.format('overlay_load: done, frames=%d loads=%d -> %s', frames, loads, OUT))
        PCSX.quit(0)
    end
end)
ANCHORS[#ANCHORS + 1] = vl
PCSX.log('overlay_load: tracing, out=' .. OUT)
