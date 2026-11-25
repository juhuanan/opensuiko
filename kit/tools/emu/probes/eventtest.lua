-- eventtest.lua: verify createEventListener signature + Exec breakpoint firing.
ANCHORS = {}

local frames = 0
local l = PCSX.Events.createEventListener('GPU::Vsync', function()
    frames = frames + 1
    if frames == 1 or frames % 600 == 0 then
        PCSX.log('vsync frames=' .. frames)
    end
    if frames >= 1800 then
        PCSX.log('eventtest: 1800 vsyncs seen, quitting')
        PCSX.quit(0)
    end
end)
ANCHORS[#ANCHORS + 1] = l
PCSX.log('eventtest: listener armed, waiting')

-- also verify an Exec breakpoint fires: game entry point from boot log
local bp
bp = PCSX.addBreakpoint(0x800241C4, 'Exec', 4, 'game entry', function()
    local regs = PCSX.getRegisters()
    PCSX.log('eventtest: EXEC BREAKPOINT HIT at pc=' .. string.format('0x%08X', bit.band(tonumber(regs.pc), 0xFFFFFFFF)))
    return false -- remove after first hit
end)
ANCHORS.bp = bp
