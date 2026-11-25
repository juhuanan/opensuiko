-- mapper.lua
--
-- Coordinate-guided exploration. Logs hero/camera X/Y (0x8017C008/0x8017C010)
-- and loader state every 15 frames while running a movement script.
-- Used to map walkable areas and find exits/transitions numerically.
--
-- Env: SUIKODEN_SCRIPT, SUIKODEN_START_STATE, SUIKODEN_SAVESTATE,
--      SUIKODEN_IDLE, SUIKODEN_OUT, SUIKODEN_FRAMES, SUIKODEN_FIXDIR.

local ffi = require('ffi')
local bit = require('bit')

local OUT      = os.getenv('SUIKODEN_OUT') or '/tmp/mapper.csv'
local FRAMES   = tonumber(os.getenv('SUIKODEN_FRAMES') or '20000')
local OUTDIR   = OUT:match('^(.*)/[^/]*$')
local SHOTDIR  = OUTDIR .. '/shots'
local FIXDIR   = (os.getenv('SUIKODEN_FIXDIR') or (OUTDIR .. '/fixtures'))
local START_STATE = os.getenv('SUIKODEN_START_STATE') or (FIXDIR .. '/ingame.pcsxstate')
local SCRIPT   = os.getenv('SUIKODEN_SCRIPT') or ''
local SAVE_PATH  = os.getenv('SUIKODEN_SAVESTATE') or ''
local IDLE = tonumber(os.getenv('SUIKODEN_IDLE') or '0')
local SHOT_EVERY = tonumber(os.getenv('SUIKODEN_SHOT_EVERY') or '0')
os.execute('mkdir -p "' .. SHOTDIR .. '" "' .. FIXDIR .. '"')

local RAM = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u32(addr)
    return tonumber(RAM[bit.rshift(bit.band(addr, 0x1FFFFFFF), 2)])
end
local function u16(addr)
    local w = u32(bit.band(addr, 0xFFFFFFFC))
    return bit.band(bit.rshift(w, bit.band(addr, 2) * 8), 0xFFFF)
end
local function s16(v) if v >= 32768 then return v - 65536 end return v end
local function u8(addr)
    local w = u32(bit.band(addr, 0xFFFFFFFC))
    return bit.band(bit.rshift(w, bit.band(addr, 3) * 8), 0xFF)
end

local HERO_X = 0x8017C008
local HERO_Y = 0x8017C010
local LOADER_STATE = 0x80179C04
local SECTOR_WIN   = 0x80179CE8

local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local moves = {}
for chunk in SCRIPT:gmatch('[^,]+') do
    local btn, n = chunk:match('^%s*([A-Za-z0-9_]+)%s*:%s*(%d+)%s*$')
    if btn and n then moves[#moves + 1] = { btn = btn, frames = tonumber(n) } end
end

local frame = 0
local logf = assert(io.open(OUT, 'w'))
logf:write('frame,x,y,lstate,event,detail\n')
local function log(event, detail)
    logf:write(string.format('%d,%d,%d,%d,%s,%s\n', frame,
        s16(u16(HERO_X)), s16(u16(HERO_Y)), u8(LOADER_STATE),
        event, tostring(detail or '')))
    logf:flush()
end

local shot_n = 0
local function shot(tag)
    shot_n = shot_n + 1
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if not ok or not ss or not ss.data then return end
    local path = string.format('%s/map_%03d_%s.raw', SHOTDIR, shot_n, tag)
    local wf = Support.File.open(path, 'TRUNCATE')
    wf:writeMoveSlice(ss.data); wf:close()
    log('shot', tag)
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

local mi = 1
local mleft = 0
local cur_btn = nil
local function drive()
    if mi > #moves then
        if cur_btn then PAD.clearOverride(cur_btn); cur_btn = nil end
        return
    end
    if mleft <= 0 then
        if cur_btn then PAD.clearOverride(cur_btn) end
        cur_btn = B[moves[mi].btn]
        if not cur_btn then log('bad_button', moves[mi].btn); mi = mi + 1; return end
        mleft = moves[mi].frames
        PAD.setOverride(cur_btn)
        log('move_start', string.format('%s %df', moves[mi].btn, mleft))
    end
    mleft = mleft - 1
    if mleft <= 0 then log('move_end', moves[mi].btn); mi = mi + 1 end
end

local loaded = false
local script_done = false
local save_wait = 0
local last_state = -1
local last_win = 0
local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1

    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        local ok, err = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        log('load_result', string.format('ok=%s', tostring(ok)))
        if not ok then finish('ABORT: load failed') return end
        last_win = u32(SECTOR_WIN)
    end

    if loaded then
        local st = u8(LOADER_STATE)
        local win = u32(SECTOR_WIN)
        -- log loader transitions and sector-window jumps
        if st ~= last_state then
            local extra = ''
            if st == 9 then extra = string.format(' win=%08X', win) end
            log('lstate', string.format('%d->%d%s', last_state, st, extra))
            last_state = st
        elseif st == 9 and win ~= last_win then
            -- window advanced while staying in state 9: real streaming
            log('win', string.format('%08X->%08X', last_win, win))
            last_win = win
        end
        -- periodic position sample
        if frame % 15 == 0 then log('pos', '') end

        drive()
        if SHOT_EVERY > 0 and frame % SHOT_EVERY == 0 then shot('t' .. frame) end

        if mi > #moves and not script_done then
            script_done = true
            if cur_btn then PAD.clearOverride(cur_btn); cur_btn = nil end
            save_wait = 30 + IDLE
            log('input', 'script done, settling')
        end
        if script_done then
            save_wait = save_wait - 1
            if save_wait <= 0 then
                if SAVE_PATH ~= '' then save_state_ffi(SAVE_PATH) end
                finish('script complete')
                return
            end
        end
    end
    if frame >= FRAMES then finish('frame budget exhausted') end
end)
_G.MAPPER_ANCHOR = vl
log('start', 'mapper script=' .. SCRIPT)
