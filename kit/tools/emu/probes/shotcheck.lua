-- shotcheck.lua: load a save state, wait, take a screenshot.
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/sc.csv'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local frame = 0
local logf = assert(io.open(OUT, 'w'))
local function log(e, d)
    logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or '')))
    logf:flush()
end
local loaded, done = false, false
local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 30 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        log('load', tostring(ok))
        return
    end
    if not loaded then return end
    if frame == 150 then
        -- screenshot via PCSX API if available
        local ok = pcall(function()
            -- try the screenshot function
            if PCSX.takeScreenshot then
                PCSX.takeScreenshot(OUT .. '.png')
                log('shot', 'taken')
            else
                log('shot', 'no API')
            end
        end)
        if not ok then log('shot', 'failed') end
        done = true; logf:close(); PCSX.quit(0)
    end
end)
_G.SC_ANCHOR = vl
log('start', 'shotcheck')
