-- shottest.lua: minimal screenshot test with explicit errors.
local OUT = '/tmp/shottest/shottest.csv'
os.execute('mkdir -p /tmp/shottest/shots')
local logf = assert(io.open(OUT, 'w'))
local function log(m) logf:write(m .. '\n'); logf:flush() end

local frame = 0
local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    frame = frame + 1
    if frame == 60 then
        log('frame 60: attempting screenshot')
        local ok, ss = pcall(PCSX.GPU.takeScreenShot)
        log('pcall ok=' .. tostring(ok))
        if ok then
            log('ss=' .. tostring(ss))
            if ss then
                log('ss.data=' .. tostring(ss.data))
                log('ss.width=' .. tostring(ss.width))
            end
        else
            log('error: ' .. tostring(ss))
        end
        if ok and ss and ss.data then
            local wf = Support.File.open('/tmp/shottest/shots/test.raw', 'TRUNCATE')
            log('file open=' .. tostring(wf))
            if wf then
                wf:writeMoveSlice(ss.data)
                wf:close()
                log('write done')
            end
        end
        logf:close()
        PCSX.quit(0)
    end
end)
_G.SHOTTEST_ANCHOR = vl
log('start')
