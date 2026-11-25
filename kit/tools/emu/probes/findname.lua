-- findname.lua: locate hero name "A" in RAM
-- The walkthrough names hero "A". Let's find where it's stored.

local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/findname.txt'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

local frame = 0
local loaded = false
local done = false
local logf = assert(io.open(OUT, 'w'))

local function get_ram_addr(psx_addr)
    -- PSX RAM is 2MB at 0x80000000, mirrored
    local offset = bit.band(psx_addr, 0x1FFFFF)
    return offset
end

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
        logf:write('Searching for hero name...\n')
        
        -- Search for "A" (0x41) followed by null terminator, in likely regions
        -- Hero name is probably a short string. Let's search RAM for isolated "A\x00"
        -- PSX RAM: 0x80000000 - 0x80200000 (2MB)
        
        local found = {}
        -- Search in chunks to avoid timeout
        -- Focus on 0x80100000 - 0x80200000 (high RAM where save data likely is)
        for psx = 0x80100000, 0x801FFFFF - 16, 1 do
            local off = get_ram_addr(psx)
            -- Check for "A" (0x41) followed by 0x00 (null-terminated single char name)
            -- Or "A" with other patterns
            if RAM[off] == 0x41 then
                -- Check next few bytes for null or space padding
                local b1 = RAM[off+1]
                local b2 = RAM[off+2]
                -- Single char name "A" null-terminated, or "A" + padding
                if b1 == 0x00 then
                    -- Found "A\x00"
                    table.insert(found, psx)
                    if #found >= 20 then break end
                end
            end
        end
        
        logf:write(string.format('Found %d candidates for \"A\\\\x00\":\n', #found))
        for i, addr in ipairs(found) do
            -- Dump 16 bytes around it
            local off = get_ram_addr(addr)
            local bytes = {}
            for j = -8, 15 do
                if off + j >= 0 then
                    bytes[#bytes+1] = string.format('%02X', RAM[off+j])
                end
            end
            logf:write(string.format('  0x%08X: %s\n', addr, table.concat(bytes, ' ')))
        end
        
        -- Also search for the name in Shift-JIS or other encoding?
        -- "A" in ASCII is 0x41. Let's also check for 0x41 in other contexts
        
        logf:close()
        PCSX.quit(0)
    end
end)
