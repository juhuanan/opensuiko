-- dump24.lua: dump the 24-byte parsed table from palace state
-- Targeted probe for .8 payload analysis

local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/dump24.txt'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local RAM = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u32(a) return tonumber(RAM[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)]) end
local function u16(a)
    local w = u32(bit.band(a, 0xFFFFFFFC))
    local shift = bit.band(a, 2) * 8
    return bit.band(bit.rshift(w, shift), 0xFFFF)
end
local function u8(a)
    local w = u32(bit.band(a, 0xFFFFFFFC))
    return bit.band(bit.rshift(w, bit.band(a, 3) * 8), 0xFF)
end

local frame = 0
local loaded = false
local done = false
local logf = assert(io.open(OUT, 'w'))

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        logf:write(string.format('load ok=%s\n', tostring(ok)))
        if not ok then done = true; logf:close(); PCSX.quit(0) return end
    end
    
    if loaded and frame == 90 then
        done = true
        -- Read table pointer at 0x8017BF98
        local tbl_ptr = u32(0x8017BF98)
        logf:write(string.format('tbl_ptr=0x%08X\n', tbl_ptr))
        
        if tbl_ptr == 0 or tbl_ptr < 0x80000000 or tbl_ptr > 0x80200000 then
            logf:write('ERROR: invalid pointer\n')
        else
            -- Dump first 15 entries
            logf:write('entries:\n')
            for i = 0, 14 do
                local base = tbl_ptr + i*24
                local tag = u16(base + 4)
                local bytes = {}
                for j = 0, 23 do
                    bytes[#bytes+1] = string.format('%02X', u8(base + j))
                end
                logf:write(string.format('  [%2d] 0x%08X tag=0x%04X %s\n', 
                    i, base, tag, table.concat(bytes, '')))
            end
        end
        
        logf:close()
        PCSX.quit(0)
    end
end)
