-- framediag.lua: which per-frame area functions actually run in the idle palace state?
-- Counts Exec hits on AreaSystem_Frame, Area_RequestNext, queue_shift, dispatcher.
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/fd.csv'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local frame = 0
local logf = assert(io.open(OUT, 'w'))
local function log(e, d)
    logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or '')))
    logf:flush()
end

local ANCH = {}
local hits = {}
local function count(label, addr)
    hits[label] = 0
    local ok, bp = pcall(PCSX.addBreakpoint, addr, 'Exec', 4, function()
        hits[label] = hits[label] + 1
    end)
    if ok and bp then ANCH[label] = bp else log('bp_fail', label) end
end

local loaded = false
local done = false
local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        count('AreaSystem_Frame', 0x800C8B70)
        count('Area_RequestNext', 0x800C6440)
        count('queue_shift', 0x800C71B0)
        count('dispatcher', 0x800C7A24)
        count('loader41', 0x800C7E10)
        log('armed', 'ok')
        return
    end
    if not loaded then return end
    if frame % 120 == 0 then
        local parts = {}
        for k, v in pairs(hits) do parts[#parts+1] = k .. '=' .. v end
        log('hits', table.concat(parts, ' '))
    end
    if frame >= 700 then done = true; logf:close(); PCSX.quit(0) end
end)
_G.FD_ANCHOR = vl
_G.FD_ANCHORS = ANCH
log('start', 'framediag')
