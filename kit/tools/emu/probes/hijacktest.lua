-- hijacktest.lua: Test PC hijack to setup fn 0x80132044 from ingame state.
-- No streaming. Just call setup(a0=2), run frames, screenshot.
-- If palace rebuilds/unchanged: hijack works. If crash: convention wrong.
local ffi = require('ffi')
local bit = require('bit')

local OUT     = os.getenv('SUIKODEN_OUT') or '/tmp/hj/hj.csv'
local OUTDIR  = OUT:match('^(.*)/[^/]*$')
os.execute('mkdir -p "' .. OUTDIR .. '"')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'

local SETUP_FN = 0x80132044
local SAFE_RA  = 0x800C8C74

local frame = 0
local logf = assert(io.open(OUT, 'w'))
local function log(e, d)
    logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or '')))
    logf:flush()
end
local done = false
local function finish(msg)
    if done then return end
    done = true
    log('finish', msg)
    logf:close()
    PCSX.quit(0)
end

local phase = 0
local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and phase == 0 then
        phase = 1
        local f = Support.File.open(FIXDIR .. '/ingame.pcsxstate')
        pcall(function() PCSX.loadSaveState(f) end); f:close()
        log('state', 'ingame loaded')
    elseif frame == 120 and phase == 1 then
        phase = 2
        -- Hijack PC to setup fn
        local ok, r = pcall(PCSX.getRegisters)
        if ok and r and r.GPR and r.GPR.n then
            local ok2, err = pcall(function()
                r.GPR.n.a0 = 2
                r.GPR.n.ra = SAFE_RA
                -- Try to set PC: check field name
                if r.pc then
                    r.pc = SETUP_FN
                    log('hijack', 'set r.pc')
                elseif r.GPR.n.pc then
                    r.GPR.n.pc = SETUP_FN
                    log('hijack', 'set r.GPR.n.pc')
                else
                    log('hijack', 'NO PC FIELD FOUND')
                    -- dump keys
                    local ks = {}
                    for k, _ in pairs(r) do ks[#ks+1] = k end
                    log('regs_keys', table.concat(ks, ','))
                end
                PCSX.setRegisters(r)
            end)
            if not ok2 then log('hijack', 'FAILED: ' .. tostring(err)) end
        else
            log('hijack', 'getRegisters failed')
        end
    elseif frame == 600 and phase == 2 then
        phase = 3
        log('screenshot', 'taking shot')
        -- screenshot via Lua? Check if PCSX.screenshot exists
        local ok, err = pcall(function()
            if PCSX.screenshot then
                PCSX.screenshot(OUTDIR .. '/hijacktest.png')
                log('shot', 'ok')
            else
                log('shot', 'PCSX.screenshot not available')
            end
        end)
        if not ok then log('shot', 'err: ' .. tostring(err)) end
        finish('done')
    end
    if frame >= 2000 then finish('frame budget') end
end)
_HJ_ANCH = vl
log('start', 'hijacktest running')
