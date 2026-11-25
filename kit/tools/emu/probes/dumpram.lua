-- dumpram.lua: dump 2MB PS1 RAM to file for offline analysis

local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/ram.bin'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

local frame = 0
local loaded = false
local done = false

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        if not ok then done = true; PCSX.quit(0) return end
    end
    
    if loaded and frame == 90 then
        done = true
        -- Dump 2MB RAM (0x80000000 - 0x80200000)
        local f = assert(io.open(OUT, 'wb'))
        -- PCSX.getMemPtr() returns pointer to 0x80000000
        local chunk = ffi.string(RAM, 0x200000)
        f:write(chunk)
        f:close()
        PCSX.quit(0)
    end
end)
