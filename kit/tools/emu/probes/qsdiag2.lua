-- qsdiag.lua: does queue_shift (0x800C71B0) actually execute per-frame in idle?
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/qs.csv'
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
        local addrs = {0x800C8BBC, 0x800C8BCC, 0x800C8BDC, 0x800C8C74, 0x800C8B70}
        for _, a in ipairs(addrs) do
            local ok, bp = pcall(PCSX.addBreakpoint, a, 'Exec', 4, function()
                log('exec', string.format('%#x', a))
            end)
            if ok and bp then ANCH[a] = bp; log('armed', string.format('%#x', a))
            else log('bp_fail', string.format('%#x', a)) end
        end
        return
    end
    if not loaded then return end
    if frame >= 200 then done = true; logf:close(); PCSX.quit(0) end
end)
_G.QS_ANCHOR = vl
_G.QS_ANCHORS = ANCH
log('start', 'qsdiag')
