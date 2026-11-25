-- boot_check.lua: just boot and screenshot
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/bootchk'
local start = os.clock()
local done = false

local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if ok and ss and ss.data then
        local wf = Support.File.open(OUT .. '_' .. tag .. '.raw', 'TRUNCATE')
        if wf then wf:writeMoveSlice(ss.data); wf:close() end
        PCSX.log('bootchk: screenshot ' .. tag)
    end
end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    local e = os.clock() - start
    if e >= 90 then
        shot('90s')
        done = true
        PCSX.quit(0)
    end
end)
