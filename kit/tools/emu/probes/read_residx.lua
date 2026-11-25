-- read_residx.lua: wait for manual (X11) save load, then read RES_IDX
local ffi = require('ffi')
local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

PCSX.log('readres: waiting 240s for X11 load...')
local start = os.time()
while os.time() - start < 240 do
    -- Busy wait (not ideal, but works without Vsync)
end

local res_idx = RAM[0x80179BF3 - 0x80000000]
local mode = RAM[0x80179CB8 - 0x80000000]
local seq = RAM[0x80179C02 - 0x80000000]

PCSX.log(string.format('readres: RES_IDX=%d MODE=%d SEQ=%d', res_idx, mode, seq))

-- Dump resource table entry for this index
local tbl_base = 0x80164E68 - 0x80000000
local entry_off = tbl_base + res_idx * 12
local w0 = ffi.cast('uint32_t *', RAM + entry_off)[0]
PCSX.log(string.format('readres: table[%d] w0=0x%X (LBA %d)', res_idx, w0, w0))

PCSX.log('readres: done')
