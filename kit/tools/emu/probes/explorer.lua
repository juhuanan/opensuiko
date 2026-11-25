-- explorer.lua
--
-- Scripted-movement explorer for building the save-state network.
-- Loads fixtures/ingame.pcsxstate, executes a movement script, watches
-- MAIN.EXE's loader state machine for area-load activity, screenshots
-- periodically, optionally saves a state at the end.
--
-- Env:
--   SUIKODEN_SCRIPT    "BTN:frames,BTN:frames,..." e.g. "DOWN:600,LEFT:200"
--                      BTN in UP/DOWN/LEFT/RIGHT/CROSS/CIRCLE/START...
--   SUIKODEN_SHOT_EVERY screenshot cadence in frames (default 150, 0=off)
--   SUIKODEN_SAVESTATE   path to write final save state (default: none)
--   SUIKODEN_OUT / SUIKODEN_FRAMES / SUIKODEN_FIXDIR as usual.

local ffi = require('ffi')
local bit = require('bit')

local OUT      = os.getenv('SUIKODEN_OUT') or '/tmp/explorer.csv'
local FRAMES   = tonumber(os.getenv('SUIKODEN_FRAMES') or '20000')
local OUTDIR   = OUT:match('^(.*)/[^/]*$')
local SHOTDIR  = OUTDIR .. '/shots'
local FIXDIR   = (os.getenv('SUIKODEN_FIXDIR') or (OUTDIR .. '/fixtures'))
local START_STATE = os.getenv('SUIKODEN_START_STATE') or (FIXDIR .. '/ingame.pcsxstate')
local SCRIPT   = os.getenv('SUIKODEN_SCRIPT') or ''
local SHOT_EVERY = tonumber(os.getenv('SUIKODEN_SHOT_EVERY') or '150')
local SAVE_PATH  = os.getenv('SUIKODEN_SAVESTATE') or ''
local IDLE = tonumber(os.getenv('SUIKODEN_IDLE') or '0')  -- extra idle frames after script, before save/finish
os.execute('mkdir -p "' .. SHOTDIR .. '" "' .. FIXDIR .. '"')

local RAM = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u32(addr)
    return tonumber(RAM[bit.rshift(bit.band(addr, 0x1FFFFFFF), 2)])
end
local function u8(addr)
    local w = u32(bit.band(addr, 0xFFFFFFFC))
    return bit.band(bit.rshift(w, bit.band(addr, 3) * 8), 0xFF)
end

local LOADER_STATE = 0x80179C04  -- 41-state machine state byte
local SECTOR_WIN   = 0x80179CE8  -- LBA window derived by state-9 handler

local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

-- parse "DOWN:600,LEFT:200" -> {{btn='DOWN',frames=600},...}
local moves = {}
for chunk in SCRIPT:gmatch('[^,]+') do
    local btn, n = chunk:match('^%s*([A-Za-z0-9_]+)%s*:%s*(%d+)%s*$')
    if btn and n then moves[#moves + 1] = { btn = btn, frames = tonumber(n) } end
end

local frame = 0
local logf = assert(io.open(OUT, 'w'))
logf:write('frame,event,detail\n')
local function log(event, detail)
    logf:write(string.format('%d,%s,%s\n', frame, event, tostring(detail or '')))
    logf:flush()
end

local shot_n = 0
local function shot(tag)
    shot_n = shot_n + 1
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if not ok or not ss or not ss.data then log('shot_fail', tag); return end
    local path = string.format('%s/ex_%03d_%s.raw', SHOTDIR, shot_n, tag)
    local wf = Support.File.open(path, 'TRUNCATE')
    wf:writeMoveSlice(ss.data)
    wf:close()
    log('shot', string.format('%s lstate=%d', tag, u8(LOADER_STATE)))
end

local done = false
local function finish(msg)
    if done then return end
    done = true
    log('finish', msg)
    logf:close()
    PCSX.quit(0)
end

local function save_state_ffi(path)
    log('save_state', path)
    local ok, err = pcall(function()
        local ss = PCSX.createSaveState()
        local size = ss.size
        local data = ffi.cast('const char*', ss.data)
        local f = assert(io.open(path, 'wb'))
        local CHUNK = 1024 * 1024
        local offset = 0
        while offset < size do
            local n = math.min(CHUNK, size - offset)
            f:write(ffi.string(data + offset, n))
            offset = offset + n
        end
        f:close()
        log('save_bytes', tostring(size))
    end)
    if not ok then log('save_failed', tostring(err)) end
end

-- movement driver
local mi = 1            -- current move index
local mleft = 0         -- frames left in current move
local cur_btn = nil
local function drive()
    if mi > #moves then
        if cur_btn then PAD.clearOverride(cur_btn); cur_btn = nil end
        return
    end
    if mleft <= 0 then
        if cur_btn then PAD.clearOverride(cur_btn) end
        cur_btn = B[moves[mi].btn]
        if not cur_btn then
            log('bad_button', moves[mi].btn)
            mi = mi + 1
            return
        end
        mleft = moves[mi].frames
        PAD.setOverride(cur_btn)
        log('move_start', string.format('%s %df', moves[mi].btn, mleft))
    end
    mleft = mleft - 1
    if mleft <= 0 then
        log('move_end', moves[mi].btn)
        mi = mi + 1
    end
end

local loaded = false
local script_done = false
local save_wait = 0
local last_state = -1
local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1

    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        local ok, err = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        log('load_result', string.format('ok=%s err=%s', tostring(ok), tostring(err)))
        if not ok then finish('ABORT: load failed') return end
        shot('start')
    end

    if loaded then
        local st = u8(LOADER_STATE)
        if st ~= last_state then
            local extra = ''
            if st == 9 then
                extra = string.format(' win=%08X+%08X', u32(SECTOR_WIN), u32(SECTOR_WIN + 4))
            end
            log('lstate', string.format('%d->%d%s', last_state, st, extra))
            last_state = st
        end
        drive()
        if SHOT_EVERY > 0 and frame % SHOT_EVERY == 0 then shot('t' .. frame) end
    end

    if loaded and mi > #moves then
        -- script done: clear any override FIRST, settle, then save, so the
        -- saved pad state is neutral (a save taken while an override is
        -- active restores with that button stuck held).
        if not script_done then
            script_done = true
            if cur_btn then PAD.clearOverride(cur_btn); cur_btn = nil end
            log('input', 'overrides cleared, settling 30f')
            save_wait = 30 + IDLE
        end
    end
    if script_done then
        save_wait = save_wait - 1
        if save_wait <= 0 then
            if SAVE_PATH ~= '' then
                shot('presave')
                save_state_ffi(SAVE_PATH)
            else
                shot('end')
            end
            finish('script complete')
            return
        end
    end
    if frame >= FRAMES then finish('frame budget exhausted') end
end)
_G.EXPLORER_ANCHOR = vl
log('start', 'explorer running script=' .. SCRIPT)
