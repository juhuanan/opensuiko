-- exithunt.lua: walk hero in pattern, watch for 0x03xx dispatcher calls.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/eh/eh.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
os.execute('mkdir -p "' .. OUTDIR .. '"')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'

local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local frame = 0
local done, loaded = false, false
local logf = assert(io.open(OUT, 'w'))
local function log(e, d) logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or ''))); logf:flush() end

local found_exit = false
local function arm_bp()
    local ok, bp = pcall(PCSX.addBreakpoint, 0x800C4FE0, 'Exec', 4, 'dispatcher', function()
        local ok2, r = pcall(PCSX.getRegisters)
        if ok2 and r then
            local tag = bit.band(tonumber(r.GPR.n.a0), 0xFFFF)
            if bit.band(tag, 0xFF00) == 0x0300 then
                log('EXIT_TAG', string.format('tag=%04x', tag))
                found_exit = true
            end
        end
    end)
    if not ok then log('bp_fail', 'dispatcher') else log('bp_ok', 'dispatcher armed') end
    _G.EH_BP = bp
end

-- Walk pattern: up, right, down, left, repeating, with pauses
local dirs = {B.UP, B.RIGHT, B.DOWN, B.LEFT}
local dir_idx = 1
local steps_in_dir = 0
local MAX_STEPS = 180  -- 3 seconds per direction

local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(FIXDIR .. '/bedroom2.pcsxstate')
        pcall(function() PCSX.loadSaveState(f) end); f:close()
        log('loaded', 'hallway, starting walk')
        arm_bp()
        PAD.setOverride(dirs[dir_idx])
        return
    end
    if not loaded then return end
    if found_exit then
        PAD.clearOverride(dirs[dir_idx])
        log('done', 'exit found!')
        done = true; logf:close(); PCSX.quit(0)
        return
    end
    steps_in_dir = steps_in_dir + 1
    if steps_in_dir >= MAX_STEPS then
        PAD.clearOverride(dirs[dir_idx])
        dir_idx = dir_idx + 1
        if dir_idx > #dirs then
            log('done', 'full cycle, no exit')
            done = true; logf:close(); PCSX.quit(0)
            return
        end
        steps_in_dir = 0
        PAD.setOverride(dirs[dir_idx])
        log('dir', string.format('now %d', dir_idx))
    end
    if frame >= 3000 then
        PAD.clearOverride(dirs[dir_idx])
        log('done', 'timeout')
        done = true; logf:close(); PCSX.quit(0)
    end
end)
_G.EH_ANCHOR = vl
log('start', 'exithunt')
