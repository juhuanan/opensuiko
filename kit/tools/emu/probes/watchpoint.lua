-- watchpoint.lua
-- Generic write-watchpoint probe. Answers "what writes ADDRESS?"
--
-- Static analysis found no writes to 0x8009F6F8 (the 0x80031EE8
-- dispatcher's backing data), so the writer must live in an overlay or
-- be reached indirectly. This probe catches it live.
--
-- The debug hook runs BEFORE the store, so the value read from RAM at
-- hit time is the PRE-store (old) value. Call context (pc, ra, and the
-- 8 words around sp) is logged for the first N hits.
--
-- Env:
--   SUIKODEN_ADDR    watch address (default: 0x8009F6F8)
--   SUIKODEN_WIDTH   watch width 1/2/4 (default: 4)
--   SUIKODEN_OUT     output CSV path (default: /tmp/watchpoint.csv)
--   SUIKODEN_DETAIL  first-N call-context dump path (default: /tmp/watchpoint.detail.txt)
--   SUIKODEN_MAXHITS quit after this many hits, 0 = no limit (default: 50)
--   SUIKODEN_FRAMES  vsync budget before auto-quit (default: 14400)

local ffi = require('ffi')
local bit = require('bit')

local ADDR    = tonumber(os.getenv('SUIKODEN_ADDR') or '0x8009F6F8')
local WIDTH   = tonumber(os.getenv('SUIKODEN_WIDTH') or '4')
local OUT     = os.getenv('SUIKODEN_OUT') or '/tmp/watchpoint.csv'
local DETAIL  = os.getenv('SUIKODEN_DETAIL') or '/tmp/watchpoint.detail.txt'
local MAXHITS = tonumber(os.getenv('SUIKODEN_MAXHITS') or '50')
local FRAMES  = tonumber(os.getenv('SUIKODEN_FRAMES') or '14400')

ANCHORS = ANCHORS or {}
local RAM = ffi.cast('uint32_t *', PCSX.getMemPtr())
local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())

local function phys(addr) return bit.band(addr, 0x1FFFFFFF) end
local function norm(v) return bit.band(tonumber(v) or 0, 0xFFFFFFFF) end

local function read_mem(addr, width)
    local p = phys(addr)
    if width == 4 then return tonumber(ffi.cast('uint32_t *', RAMB + p)[0]) end
    if width == 2 then return tonumber(ffi.cast('uint16_t *', RAMB + p)[0]) end
    return tonumber(RAMB[p])
end

local fh = assert(io.open(OUT, 'w'))
fh:write('hit,frame,addr,width,old_value,pc,ra\n')
local dfh = assert(io.open(DETAIL, 'w'))

local frames, hits = 0, 0

local bp = PCSX.addBreakpoint(ADDR, 'Write', WIDTH, 'watchpoint', function(acc_addr, acc_width)
    local ok, err = pcall(function()
        hits = hits + 1
        local old = read_mem(ADDR, WIDTH)
        local r = PCSX.getRegisters()
        local gpr = r.GPR and r.GPR.n
        local function g(name)
            if gpr then
                local ok2, v = pcall(function() return gpr[name] end)
                if ok2 then return norm(v) end
            end
            return 0
        end
        local pc, ra, sp = norm(r.pc), g('ra'), g('sp')
        fh:write(string.format('%d,%d,0x%08X,%d,0x%X,0x%08X,0x%08X\n',
            hits, frames, norm(acc_addr), acc_width or 0, old, pc, ra))
        fh:flush()
        PCSX.log(string.format('watchpoint: hit #%d frame=%d addr=0x%08X old=0x%X pc=0x%08X ra=0x%08X',
            hits, frames, norm(acc_addr), old, pc, ra))
        if hits <= 5 then
            dfh:write(string.format('--- hit %d frame %d pc=0x%08X ra=0x%08X old=0x%X ---\n',
                hits, frames, pc, ra, old))
            dfh:write('stack @sp:\n')
            for i = 0, 7 do
                local ok3, w = pcall(read_mem, sp + i * 4, 4)
                dfh:write(string.format('  sp+0x%02X: 0x%08X\n', i * 4, ok3 and w or 0))
            end
            dfh:flush()
        end
        if MAXHITS > 0 and hits >= MAXHITS then
            fh:close() dfh:close()
            PCSX.log('watchpoint: hit cap reached, quitting')
            PCSX.quit(0)
        end
    end)
    if not ok then PCSX.log('watchpoint: error: ' .. tostring(err)) end
end)
ANCHORS[#ANCHORS + 1] = bp

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    frames = frames + 1
    if frames >= FRAMES then
        fh:close() dfh:close()
        PCSX.log(string.format('watchpoint: done, frames=%d hits=%d -> %s', frames, hits, OUT))
        PCSX.quit(0)
    end
end)
ANCHORS[#ANCHORS + 1] = vl

PCSX.log(string.format('watchpoint: watching writes to 0x%08X width %d, out=%s',
    ADDR, WIDTH, OUT))
