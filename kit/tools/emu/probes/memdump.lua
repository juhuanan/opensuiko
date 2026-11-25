-- memdump.lua
-- Dump PSX main-RAM regions to binary files at a trigger point.
--
-- Default trigger: one-shot Exec breakpoint on the game entry point
-- 0x800241C4 (from the BIOS boot log), then dump and quit.
-- Alternative: dump after N vsyncs (SUIKODEN_DUMP_AT_FRAME > 0).
--
-- Env:
--   SUIKODEN_OUTDIR        directory for dumps (default: /tmp/memdump)
--   SUIKODEN_REGIONS       comma list start:length in hex, e.g.
--                          "0x80010000:0x90800,0x800B0000:0x10000"
--                          (default: whole 2MB RAM "0x80000000:0x200000")
--   SUIKODEN_DUMP_AT_FRAME dump after this many vsyncs instead of at
--                          entry (default: 0 = entry breakpoint)

local ffi = require('ffi')
local bit = require('bit')

local OUTDIR  = os.getenv('SUIKODEN_OUTDIR') or '/tmp/memdump'
local REGIONS = os.getenv('SUIKODEN_REGIONS') or '0x80000000:0x200000'
local ATFRAME = tonumber(os.getenv('SUIKODEN_DUMP_AT_FRAME') or '0')

ANCHORS = ANCHORS or {}
local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())

os.execute('mkdir -p "' .. OUTDIR .. '"')

local function dump(tag)
    for spec in string.gmatch(REGIONS, '[^,]+') do
        local s, l = string.match(spec, '(0x%x+):(0x%x+)')
        local start, len = tonumber(s), tonumber(l)
        local phys = bit.band(start, 0x1FFFFFFF)
        local name = string.format('%s/ram_%08X_%X.bin', OUTDIR, start, len)
        local fh = assert(io.open(name, 'wb'))
        -- copy in 64KB chunks to keep the FFI string conversion small
        local off = 0
        while off < len do
            local n = math.min(0x10000, len - off)
            fh:write(ffi.string(RAMB + phys + off, n))
            off = off + n
        end
        fh:close()
        PCSX.log(string.format('memdump: [%s] wrote %s (%d bytes)', tag, name, len))
    end
end

local frames = 0
local done = false
local function finish(tag)
    if done then return end
    done = true
    dump(tag)
    PCSX.log('memdump: done -> ' .. OUTDIR)
    PCSX.quit(0)
end

if ATFRAME > 0 then
    local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
        frames = frames + 1
        if frames >= ATFRAME then finish('frame' .. frames) end
    end)
    ANCHORS[#ANCHORS + 1] = vl
    PCSX.log('memdump: will dump at frame ' .. ATFRAME)
else
    local bp = PCSX.addBreakpoint(0x800241C4, 'Exec', 4, 'game entry dump', function()
        finish('entry')
        return false
    end)
    ANCHORS[#ANCHORS + 1] = bp
    PCSX.log('memdump: armed at game entry 0x800241C4')
end
