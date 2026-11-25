-- paddiag.lua: report what the game sees on the pad after loading a state.
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/paddiag.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
local FIXDIR = (os.getenv('SUIKODEN_FIXDIR') or (OUTDIR .. '/fixtures'))
local START_STATE = os.getenv('SUIKODEN_START_STATE') or (FIXDIR .. '/ingame.pcsxstate')
os.execute('mkdir -p "' .. OUTDIR .. '"')

local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON
local NAMES = { 'UP','DOWN','LEFT','RIGHT','CROSS','CIRCLE','SQUARE','TRIANGLE','START','SELECT','L1','R1','L2','R2' }

local frame = 0
local logf = assert(io.open(OUT, 'w'))
local function held()
    local t = {}
    for _, n in ipairs(NAMES) do
        local ok, v = pcall(function() return PAD.getButton(B[n]) end)
        if ok and v then t[#t+1] = n end
    end
    return table.concat(t, '+')
end

local done = false
local loaded = false
local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        local ok, err = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        logf:write(string.format('60,load,ok=%s\n', tostring(ok)))
    end
    if loaded and frame % 60 == 0 then
        logf:write(string.format('%d,held,%s\n', frame, held()))
        logf:flush()
    end
    if frame >= 400 then done = true; logf:close(); PCSX.quit(0) end
end)
_G.PADDIAG_ANCHOR = vl
