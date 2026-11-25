-- jaldiag.lua: do the state-8/state-9 CD-read jal sites get reached?
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/jd.csv'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local frame = 0
local logf = assert(io.open(OUT, 'w'))
local function log(e, d)
    logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or '')))
    logf:flush()
end
local ANCH = {}
local loaded, done = false, false
local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        local sites = {
            [0x800C84F8] = 'st8_jal_site',
            [0x800C8468] = 'st8_worker_entry',
            [0x800C849C] = 'st8_cf8_check',
            [0x800C84B0] = 'st8_work_path',
            [0x800C850C] = 'st8_skip_path',
            [0x800C8628] = 'st9_jal_site',
            [0x800C85C4] = 'st9_worker_entry',
            [0x80162FE4] = 'cdxfer_entry',
        }
        for a, name in pairs(sites) do
            local ok, bp = pcall(PCSX.addBreakpoint, a, 'Exec', 4, function()
                log('hit', name)
            end)
            if ok and bp then ANCH[a] = bp else log('bp_fail', name) end
        end
        return
    end
    if not loaded then return end
    if frame >= 400 then done = true; logf:close(); PCSX.quit(0) end
end)
_G.JD_ANCHOR = vl
_G.JD_ANCHORS = ANCH
log('start', 'jaldiag')
