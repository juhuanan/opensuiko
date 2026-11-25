-- bootscene.lua: boot via walkthrough, capture first write to parsed entries.
-- Uses the walkthrough steps: skip FMV, title, New Game, name "A", confirm.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/bs/bs.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
os.execute('mkdir -p "' .. OUTDIR .. '"')

local frame = 0
local done = false
local logf = assert(io.open(OUT, 'w'))
local function log(e, d) logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or ''))); logf:flush() end

local write_pc = nil
local function arm_bp()
    local ok, bp = pcall(PCSX.addBreakpoint, 0x80179F08, 'Write', 4, 'entries_write', function(addr, width)
        if write_pc then return end
        local ok2, r = pcall(PCSX.getRegisters)
        if ok2 and r then
            write_pc = bit.band(tonumber(r.GPR.n.pc), 0xFFFFFFFF)
            log('first_write', string.format('pc=%08x addr=%08x w=%d', write_pc, addr, width))
        end
    end)
    if not ok then log('bp_fail', 'entries') else log('bp_ok', 'entries armed') end
    _G.BS_BP = bp
end

-- Simple walkthrough: press buttons at intervals
-- This is a simplified version; the real walkthrough is complex.
-- For now, just boot and wait, arm the breakpoint early.
local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 then
        log('boot', 'arming breakpoint')
        arm_bp()
        return
    end
    if write_pc and frame % 600 == 0 then
        log('status', string.format('write_pc=%08x', write_pc))
    end
    if frame >= 7200 then
        log('done', write_pc and string.format('pc=%08x', write_pc) or 'no write seen')
        done = true; logf:close(); PCSX.quit(0)
    end
end)
_G.BS_ANCHOR = vl
log('start', 'bootscene')
