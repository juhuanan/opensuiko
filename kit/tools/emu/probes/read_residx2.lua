-- read_residx2.lua: poll for trigger file, then read memory
local ffi = require('ffi')
local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

PCSX.log('readres2: polling for /tmp/trigger_read...')

local triggered = false
local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if triggered then return end
    local f = io.open('/tmp/trigger_read', 'r')
    if f then
        f:close()
        triggered = true
        os.remove('/tmp/trigger_read')
        
        local res_idx = RAM[0x80179BF3 - 0x80000000]
        local mode = RAM[0x80179CB8 - 0x80000000]
        local seq = RAM[0x80179C02 - 0x80000000]
        PCSX.log(string.format('readres2: RES_IDX=%d MODE=%d SEQ=%d', res_idx, mode, seq))
        
        local tbl_base = 0x80164E68 - 0x80000000
        local entry_off = tbl_base + res_idx * 12
        local w0 = ffi.cast('uint32_t *', RAM + entry_off)[0]
        PCSX.log(string.format('readres2: table[%d] w0=0x%X (LBA %d)', res_idx, w0, w0))
        PCSX.log('readres2: done')
    end
end)
