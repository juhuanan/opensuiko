-- entrywriter.lua: find who writes to parsed entries (0x80179F08) in ingame state.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/ew/ew.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
os.execute('mkdir -p "' .. OUTDIR .. '"')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'

local frame = 0
local done, loaded = false, false
local logf = assert(io.open(OUT, 'w'))
local function log(e, d) logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or ''))); logf:flush() end

local hits = 0
local MAX_HITS = 30
local seen_pcs = {}

local function arm_bp()
    local ok, bp = pcall(PCSX.addBreakpoint, 0x80179F08, 'Write', 4, 'entries_write', function(addr, width)
        if hits >= MAX_HITS then return end
        hits = hits + 1
        local ok2, r = pcall(PCSX.getRegisters)
        local pc = 0
        if ok2 and r then pc = bit.band(tonumber(r.GPR.n.pc), 0xFFFFFFFF) end
        if not seen_pcs[pc] then
            seen_pcs[pc] = 0
            log('write_pc', string.format('pc=%08x addr=%08x w=%d', pc, addr, width))
        end
        seen_pcs[pc] = seen_pcs[pc] + 1
    end)
    if not ok then log('bp_fail', 'entries') else log('bp_ok', 'entries armed') end
    _G.EW_BP = bp
end

local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(FIXDIR .. '/ingame.pcsxstate')
        pcall(function() PCSX.loadSaveState(f) end); f:close()
        log('loaded', 'ingame')
        arm_bp()
        return
    end
    if not loaded then return end
    if frame >= 600 then
        log('summary', 'done')
        for pc, c in pairs(seen_pcs) do
            log('pcsum', string.format('%08x x%d', pc, c))
        end
        done = true; logf:close(); PCSX.quit(0)
    end
end)
_G.EW_ANCHOR = vl
log('start', 'entrywriter')
