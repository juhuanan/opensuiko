-- trace_commit2.lua: set CD ready flag, trace commit
local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/trace2'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())
local frame = 0
local state = 0
local done = false
local hit_count = 0

local function rb(addr) return RAM[addr - 0x80000000] end
local function wb(addr, v) RAM[addr - 0x80000000] = v end
local function rw(addr) return ffi.cast('uint32_t *', PCSX.getMemPtr())[ math.floor((addr - 0x80000000) / 4) ] end
local function ww(addr, v) ffi.cast('uint32_t *', PCSX.getMemPtr())[ math.floor((addr - 0x80000000) / 4) ] = v end

local bp_ok, bp = pcall(PCSX.addBreakpoint, 0x800C85C4, 'Exec', 4, 'commit_hit', function()
    hit_count = hit_count + 1
    if hit_count <= 3 then
        PCSX.log(string.format('trace2: HIT #%d RES=%d SM=0x%02X CD_FLAG=%d',
            hit_count, rb(0x80179BF3), rb(0x80179C04), rw(0x801787C4)))
    end
end)

-- Breakpoint at end of commit (where it sets state to 10)
local bp2_ok, bp2 = pcall(PCSX.addBreakpoint, 0x800C86D8, 'Exec', 4, 'commit_done', function()
    PCSX.log(string.format('trace2: COMMIT COMPLETED, setting state, RES=%d', rb(0x80179BF3)))
end)

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if state == 0 and frame == 60 then
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        if not ok then done = true; PCSX.quit(0) return end
        state = 1
    elseif state == 1 and frame == 120 then
        PCSX.log('trace2: setting CD ready flag 0x801787C4=1')
        ww(0x801787C4, 1)
        wb(0x80179C04, 8)
        wb(0x80179BF3, 5)
        state = 2
    elseif state == 2 and frame == 600 then
        PCSX.log(string.format('trace2: done hits=%d RES=%d SM=0x%02X',
            hit_count, rb(0x80179BF3), rb(0x80179C04)))
        done = true
        PCSX.quit(0)
    elseif frame > 900 then
        done = true
        PCSX.quit(0)
    end
end)
