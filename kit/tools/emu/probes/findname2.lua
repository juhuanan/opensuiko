-- findname2.lua: broader search for hero name
-- Search entire RAM for name patterns

local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/findname2.txt'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

local frame = 0
local loaded = false
local done = false
local logf = assert(io.open(OUT, 'w'))

local function get_ram_addr(psx_addr)
    return bit.band(psx_addr, 0x1FFFFF)
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
        
        -- Strategy: Look for the name entry buffer
        -- The name "A" was entered. It might be stored as:
        -- 1. "A\x00" (null-terminated)
        -- 2. "\x01A" (length-prefixed)
        -- 3. "A       " (space-padded to 8-10 chars)
        
        logf:write('Searching for name patterns in 0x80000000-0x80200000...\n')
        
        -- Search for length-prefixed: 0x01 0x41
        local found_len = {}
        for psx = 0x80000000, 0x801FFFFF - 4, 1 do
            local off = get_ram_addr(psx)
            if RAM[off] == 0x01 and RAM[off+1] == 0x41 then
                -- Check if followed by null or end
                if RAM[off+2] == 0x00 then
                    table.insert(found_len, psx)
                    if #found_len >= 10 then break end
                end
            end
            -- Avoid infinite loop, break periodically
            if psx % 0x100000 == 0 then
                -- Yield? Can't really yield in this context
            end
        end
        
        logf:write(string.format('Length-prefixed (\\x01A\\x00): %d found\n', #found_len))
        for i, addr in ipairs(found_len) do
            logf:write(string.format('  0x%08X\n', addr))
        end
        
        -- Search for space-padded: "A" + 7 spaces (0x20)
        -- This is common for RPG name entry (8-char field)
        logf:write('\nSearching for space-padded...\n')
        local found_pad = 0
        for psx = 0x80000000, 0x801FFFFF - 16, 1 do
            local off = get_ram_addr(psx)
            if RAM[off] == 0x41 then
                local is_pad = true
                for j = 1, 7 do
                    if RAM[off+j] ~= 0x20 and RAM[off+j] ~= 0x00 then
                        is_pad = false
                        break
                    end
                end
                if is_pad then
                    -- Check it's not code (look for non-ASCII around)
                    found_pad = found_pad + 1
                    if found_pad <= 5 then
                        logf:write(string.format('  0x%08X\n', psx))
                    end
                    if found_pad >= 20 then break end
                end
            end
        end
        logf:write(string.format('Space-padded: %d found\n', found_pad))
        
        logf:close()
        PCSX.quit(0)
    end
end)
