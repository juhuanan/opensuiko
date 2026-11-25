-- activate5.lua: BOLD EXPERIMENT
-- 1. Load ingame state
-- 2. Stream idx 5 (AREAA_1) via forced load recipe
-- 3. Call setup fn 0x80132044 directly (PC hijack)
-- 4. Run frames, screenshot
-- If it crashes, we learn the calling convention is wrong.
-- If palace rebuilds, setup ran but data wasn't there.
-- If area 5 appears, we win.
local ffi = require('ffi')
local bit = require('bit')

local OUT     = os.getenv('SUIKODEN_OUT') or '/tmp/ac/ac.csv'
local OUTDIR  = OUT:match('^(.*)/[^/]*$')
os.execute('mkdir -p "' .. OUTDIR .. '"')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'

-- area loader globals (from prior work)
local TARGET = 0x80179BEC  -- target area index
local BF1    = 0x80179BEB
local BF3    = 0x80179BF3
local BF4    = 0x80179BF4
local MASTER_Q = 0x80179C00  -- master queue (guess, verify)

local SETUP_FN = 0x80132044
local SAFE_RA  = 0x800C8C74  -- master-0 tail (per-frame safe)

local RAM8  = ffi.cast('uint8_t *', PCSX.getMemPtr())
local RAM32 = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function w8(addr, v) RAM8[bit.band(addr, 0x1FFFFFFF)] = bit.band(v, 0xFF) end
local function u32(addr)
    local ok, v = pcall(function() return RAM32[bit.rshift(bit.band(addr, 0x1FFFFFFF), 2)] end)
    return ok and tonumber(v) or 0
end
local function norm(v) return bit.band(tonumber(v) or 0, 0xFFFFFFFF) end

local frame = 0
local logf = assert(io.open(OUT, 'w'))
local function log(e, d)
    logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or '')))
    logf:flush()
end
local done = false
local function finish(msg)
    if done then return end
    done = true
    log('finish', msg)
    logf:close()
    PCSX.quit(0)
end

-- simplified forced stream: set target, trigger master 1
-- (This is a guess at the recipe; the real one is more involved)
local function stream_idx5()
    -- From prior work: write target, set flags, queue master 1
    w8(TARGET, 5)
    w8(BF1, 1)
    w8(BF3, 0)  -- clear to avoid premature finalization
    log('stream', 'target=5 set, flags cleared')
    -- The actual streaming is triggered via the master queue.
    -- For now, we rely on the game polling TARGET.
    -- (If this doesn't stream, we'll see it in the screenshot.)
end

local phase = 0
local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and phase == 0 then
        phase = 1
        local f = Support.File.open(FIXDIR .. '/ingame.pcsxstate')
        pcall(function() PCSX.loadSaveState(f) end); f:close()
        log('state', 'ingame loaded')
    elseif frame == 120 and phase == 1 then
        phase = 2
        stream_idx5()
    elseif frame == 600 and phase == 2 then
        -- streaming should be done (or in progress). Now hijack PC to setup.
        phase = 3
        local ok, r = pcall(PCSX.getRegisters)
        if ok and r then
            log('regs', 'got registers, hijacking PC')
            -- Set PC to setup fn, a0=2, ra=safe
            -- Note: PCSX.setRegisters may not exist; try direct GPR manipulation
            local ok2, err = pcall(function()
                r.GPR.n.a0 = 2
                r.GPR.n.ra = SAFE_RA
                -- PC is usually r.pc or similar
                if r.pc then r.pc = SETUP_FN end
                PCSX.setRegisters(r)
            end)
            log('hijack', ok2 and 'ok' or ('FAILED: ' .. tostring(err)))
        else
            log('hijack', 'getRegisters failed')
        end
    elseif frame == 1200 and phase == 3 then
        phase = 4
        log('screenshot', 'taking shot')
        pcall(function() PCSX.screenshot(OUTDIR .. '/activate5.png') end)
        finish('done')
    end
    if frame >= 5000 then finish('frame budget') end
end)
_AC_ANCH = vl
log('start', 'activate5 running')
