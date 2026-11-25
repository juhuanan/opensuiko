-- trace_commit.lua: breakpoint on 0x800C85C4, trace the load
local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/trace'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())
local frame = 0
local state = 0
local done = false
local hit_count = 0

local function rb(addr) return RAM[addr - 0x80000000] end
local function wb(addr, v) RAM[addr - 0x80000000] = v end

-- Set breakpoint on commit function
local bp_ok, bp = pcall(PCSX.addBreakpoint, 0x800C85C4, 'Exec', 4, 'commit_hit', function()
    hit_count = hit_count + 1
    PCSX.log(string.format('trace: BREAKPOINT HIT #%d at 0x800C85C4, RES_IDX=%d (0x80179BF3)',
        hit_count, rb(0x80179BF3)))
end)
if not bp_ok then
    PCSX.log('trace: failed to set breakpoint')
end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if state == 0 and frame == 60 then
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        if not ok then done = true; PCSX.quit(0) return end
        PCSX.log('trace: state loaded, breakpoint set on 0x800C85C4')
        state = 1
    elseif state == 1 and frame == 120 then
        -- Try to trigger by setting state to 8 (which calls commit)
        PCSX.log('trace: setting SM state to 8 to trigger commit')
        wb(0x80179C04, 8)
        wb(0x80179BF3, 5)  -- RES_IDX = 5
        state = 2
    elseif state == 2 and frame == 600 then
        PCSX.log(string.format('trace: done, hits=%d, RES=%d, SM=0x%02X',
            hit_count, rb(0x80179BF3), rb(0x80179C04)))
        done = true
        PCSX.quit(0)
    elseif frame > 900 then
        done = true
        PCSX.quit(0)
    end
end)
