-- test_save.lua: minimal test of saveSaveState
local frame = 0
local done = false

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 100 then
        PCSX.log('test: attempting to open file')
        local sf = Support.File.open('/tmp/test_state.pcsxstate', 'w')
        if sf then
            PCSX.log('test: file opened, calling saveSaveState')
            local ok, err = pcall(function() PCSX.saveSaveState(sf) end)
            PCSX.log('test: saveSaveState pcall ok=' .. tostring(ok) .. ' err=' .. tostring(err))
            sf:close()
            PCSX.log('test: file closed')
        else
            PCSX.log('test: FAILED to open file')
        end
        done = true
        PCSX.quit(0)
    end
end)
