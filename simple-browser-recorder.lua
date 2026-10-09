-- Castika Simple Browser Recorder (Lua Script)
-- v1.1.0 - 2026-10-09
-- Copyright (c) 2026 Castika
-- Licensed under the Apache License, Version 2.0
-- https://github.com/castika-code/simple-browser-recorder

obs = obslua

local TAG = "[YT Embed Rec]"
local SCRIPT_VERSION = "v1.1.0 - 2026-10-09"
local TICK_MS = 100
local EVENT_POLL_EVERY = 1
local DELIVERY_MS = 21 + 160 + (EVENT_POLL_EVERY * TICK_MS) + 107
local OVERSCAN_PX = 140
local UNMASK_DEADLINE_MS = 3000
-- YouTube draws its centre control on any player activity
local RUNUP_SEC = 5
local PLAYING_FALLBACK_MS = 6000 + (RUNUP_SEC * 1000) + UNMASK_DEADLINE_MS + 4000
local UNMASK_WAIT_MS = 6000
local PORT_WAIT_MS = 8000

local TICK_WARN_MS = 50
local TICK_GUARD = { halt_ms = 1000, hits = 3, ui_ms = 1500 }

-- per Lua 5.1 ref: package.config holds the separator
local PLAT = { sep = (package.config or "\\"):sub(1, 1) }
PLAT.win = (PLAT.sep == "\\")

local BEAT_CHECK_EVERY = 10
local BEAT_STALE_MS    = 12000
local BEAT_SETTLE_MS   = 30000
local BEAT_MAX_RECOVER = 3

local STOP_REASON = {
    scene = "scene transition",
    ended = "video ended",
    out   = "out-point reached",
}

local OUT_TAIL_MS = 300

-- libobs mixes to MAX_AUDIO_MIXES tracks and an audio encoder draws from exactly one
local MAX_AUDIO_MIXES = 6
local REC_MIX_IDX = MAX_AUDIO_MIXES - 1
local REC_MIX_BIT = math.floor(2 ^ REC_MIX_IDX)
local AUD_RESTORE_MS = 1500

local PRIME_WAIT_MS = 4000
local FAIL_CARD_MS = 30000

local cfg = {
    enabled         = true,

    fit_canvas      = true,
    res_mode        = "canvas",
    custom_h        = 1080,
    fps             = 0,

    yt_url          = "",

    max_duration_sec = 7200,

    rec_sound       = "source",

    cr_on           = false,
    cr_mode         = "yh",
    cr_text         = "",
    cr_face         = "Arial",
    cr_size         = 36,
    cr_bold         = false,
    cr_color        = 0xFFFFFFFF,
    cr_bg           = 0x8C000000,
    cr_pos          = "bl",
    cr_voff         = 0,

    loop_mode       = false,
    update_check    = true,
    auto_convert    = true,
    stop_delay_ms   = 2000,
}

local st = {
    timer_on        = false,
    tick_count      = 0,

    halted          = nil,
    tick_fn         = nil,
    slow_worst      = 0,
    slow_said       = {},
    slow_hits       = 0,
    cfg_roots       = nil,
    trim_want       = nil,
    trim_busy       = nil,
    hk_id           = nil,
    hk_fn           = nil,

    prev_active     = nil,
    we_record       = false,
    pending_stop    = nil,
    pending_reason  = nil,
    remaining_ms    = nil,
    playing_wait_ms = nil,
    unmask_wait_ms  = nil,

    nonce           = "0",
    last_seq        = 0,
    seq_at_activate = 0,
    preview_warned_nonce = nil,
    foreign_nonce_logged = nil,

    ended_nonce     = nil,
    ended_refused_nonce = nil,

    server_launched = false,
    relaunch_ms     = nil,
    health_ms       = nil,
    launch_want     = false,
    launch_id       = nil,
    owner_n         = 0,

    create_want     = false,
    create_want_logged = nil,
    create_busy     = false,

    last_beat       = nil,
    beat_stale_ms   = 0,
    beat_dead       = false,
    beat_recover_n  = 0,
    beat_since_recover_ms = nil,
    beat_gave_up    = false,
    beat_deferred   = false,

    port            = nil,
    last_port       = nil,
    port_wait_ms    = nil,
    port_wait_logged = nil,

    apply_pending   = false,
    go_written      = nil,
    bail_warned     = nil,
    convert_fail    = nil,
    height_warned   = nil,
    video_id        = "",
    video_w         = nil,
    video_h         = nil,
    cr_handle       = nil,
    cr_handle_warned = nil,
    probe_asked_for = nil,
    aspect_warned_for = nil,
    url_time_sec    = nil,
    url_time_id     = nil,
    runup_logged    = nil,

    url_warned      = nil,
    yt_url_applied  = nil,
    range_warned_for = nil,
    ctl_shown_nonce = nil,

    ctl_audio       = false,

    live_edge       = false,
    live_edge_said  = nil,
    stale_said      = nil,

    prog_scene      = nil,
    prog_prev_scene = nil,
    prog_away_scene = nil,
    ret_scene       = nil,
    ret_armed       = nil,
    ret_said        = nil,

    in_sec          = nil,
    out_sec         = nil,
    out_warned_for  = nil,

    rec_card_off    = nil,
    rec_card_t0     = nil,
    rec_card_dead   = nil,
    rec_card_txt    = nil,
    rec_card_n      = nil,
    fail_card_ms    = nil,

    ev_off          = 0,
    url_live        = nil,

    hv_view         = nil,
    hv_video        = nil,
    hv_output       = nil,
    hv_venc         = nil,
    hv_aenc         = nil,
    hv_running      = false,
    hv_stop_ms      = nil,
    hv_frames_ms    = nil,
    hv_api_warned   = nil,

    prime_phase     = nil,
    prime_ms        = nil,
    prime_tries     = 0,
    prime_bad       = nil,
    fe_ours         = nil,
    fe_stop_asked   = nil,

    aud_saved       = nil,
    aud_on          = nil,
    aud_delay_ms    = nil,
    aud_delay_why   = nil,

    upd_at          = nil,
    upd_tag         = nil,
    upd_ver         = nil,
    upd_told        = nil,
    upd_busy_ms     = nil,
    upd_force       = nil,
    upd_fail_at     = nil,
    upd_fail_said   = nil,

    hv_size         = nil,
}

local script_settings = nil

-- OBS shows and raises the script log window at LOG_WARNING or more severe
local function log(fmt, ...)
    local msg = (select("#", ...) > 0) and string.format(fmt, ...) or fmt
    obs.script_log(obs.LOG_INFO, TAG .. " " .. msg)
end

local function logw(fmt, ...)
    local msg = (select("#", ...) > 0) and string.format(fmt, ...) or fmt
    obs.script_log(obs.LOG_WARNING, TAG .. " " .. msg)
end

local function now_ms()
    if obs.os_gettime_ns == nil then return nil end
    local ok, ns = pcall(obs.os_gettime_ns)
    if not ok or type(ns) ~= "number" then return nil end
    return ns / 1000000
end

local function halt(where, err)
    if st.halted then return end
    st.halted = where or "an entry point"
    logw("HALTED in %s: %s", st.halted, tostring(err))
    logw("Every entry point of this script now returns at once and the 100ms timer is off, so this is printed one time instead of ten times a second. Nothing else in OBS is affected and a take already recorded is already on disk. Reload the script to run it again - the line above carries the stack, so send it along with the OBS log.")
    if st.tick_fn then pcall(obs.timer_remove, st.tick_fn) end
end

-- per obs-scripting-lua.h: errors recur
local function guard(where, fn, arg, strict)
    if st.halted then return nil end
    local tb = (debug and debug.traceback) or tostring
    local t0 = now_ms()
    local ok, res = xpcall(function() return fn(arg) end, tb)
    if not ok then
        halt(where, res)
        return nil
    end
    local ms = t0 and (now_ms() - t0) or nil
    if not ms then return res end
    if ms > st.slow_worst then st.slow_worst = ms end
    if strict then
        if ms >= TICK_GUARD.halt_ms then
            st.slow_hits = st.slow_hits + 1
            if st.slow_hits >= TICK_GUARD.hits then
                halt(where, string.format(
                    "it blocked for %.0fms, and that is %d passes in a row. One pass is budgeted %dms and it runs on the thread OBS draws with, so OBS was frozen for that long each time. One slow pass can be the disk, or the machine coming back from sleep with a pass still open; this many in a row is a blocking call.",
                    ms, st.slow_hits, TICK_MS))
                return nil
            end
        else
            st.slow_hits = 0
        end
    end
    if ms <= (strict and TICK_WARN_MS or TICK_GUARD.ui_ms) then return res end
    if st.slow_said[where] then return res end
    st.slow_said[where] = true
    if strict then
        log("%s took %.0fms against a %dms budget. Worst seen so far %.0fms. This is printed once for each entry point. It is a warning, not a failure, and nothing has been stopped: it is logged at INFO so it does not force this window open, because the frames it costs land inside the masked head and never reach a file. A hardware encoder being created at the start of a take is the ordinary cause.",
            where, ms, TICK_MS, st.slow_worst)
    else
        log("%s took %.0fms. It does not run on the render thread, so there is no frame budget and nothing was dropped, but it runs where OBS draws its menus and OBS could not answer for that long. Reported once, well past anything normal: loading this script and opening its settings are expected to take a moment.",
            where, ms)
    end
    return res
end

local function hv_active()
    return st.hv_running and st.hv_output ~= nil
end

local function recording_now()
    if obs.obs_frontend_recording_active() then return true end
    return hv_active()
end

local function our_take_now()
    if hv_active() then return true end
    if st.we_record and obs.obs_frontend_recording_active() then return true end
    return false
end

local function foreign_output_now()
    local rec = false
    if obs.obs_frontend_recording_active and obs.obs_frontend_recording_active() then
        rec = not (st.fe_ours or st.fe_stop_asked)
    end
    local str = false
    if obs.obs_frontend_streaming_active and obs.obs_frontend_streaming_active() then
        str = true
    end
    return rec, str
end

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- a reader sees only what the appending process has flushed, so the last line can be partial
local function read_file_tail(path, off)
    local f = io.open(path, "rb")
    if not f then return nil, 0 end
    local size = f:seek("end")
    if not size then f:close() return nil, 0 end
    off = tonumber(off) or 0
    local reset = (off < 0) or (off > size)
    if reset then off = 0 end
    f:seek("set", off)
    local data = f:read("*a") or ""
    f:close()
    local tail = data:match("[\r\n][^\r\n]*$")
    if not tail then return "", off, reset end
    local cut = #data - #tail + 1
    return data:sub(1, cut), off + cut, reset
end

local function write_file(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

local function remove_quiet(path)
    if path and path ~= "" then os.remove(path) end
end

local function join(dir, name)
    dir = trim(dir):gsub("[\\/]+$", "")
    return dir .. PLAT.sep .. name
end

local function default_work_dir()
    local base
    if PLAT.win then
        base = os.getenv("TEMP")
        if not base or base == "" then base = os.getenv("TMP") end
        if not base or base == "" then base = "C:\\Windows\\Temp" end
    else
        base = os.getenv("TMPDIR")
        if not base or base == "" then base = "/tmp" end
    end
    return join(base, "obs-yt-embed-recorder")
end

local function paths()
    local d = default_work_dir()
    return {
        dir    = d,
        html   = join(d, "yt_player.html"),
        ps1    = join(d, "yt_server.ps1"),
        pl     = join(d, "yt_server.pl"),
        vbs    = join(d, "yt_launch.vbs"),
        events = join(d, "yt_events.txt"),
        stop   = join(d, "yt_stop.flag"),
        slog   = join(d, "yt_server.log"),
        port   = join(d, "yt_port.txt"),
        beat   = join(d, "yt_beat.txt"),
        probe_req = join(d, "yt_probe_req.txt"),
        update_req = join(d, "yt_update_req.txt"),
        go     = join(d, "yt_go.flag"),
        ctl    = join(d, "yt_ctl.flag"),
        owner  = join(d, "yt_owner.txt"),
    }
end

local function extract_youtube_id(url)
    url = trim(url)
    if url == "" then return nil end
    local pats = {
        "[?&]v=([%w_%-]+)",
        "youtu%.be/([%w_%-]+)",
        "/embed/([%w_%-]+)",
        "/shorts/([%w_%-]+)",
        "/live/([%w_%-]+)",
        "/v/([%w_%-]+)",
    }
    for _, p in ipairs(pats) do
        local id = url:match(p)
        if id and #id >= 10 then return id end
    end
    if #url == 11 and url:match("^[%w_%-]+$") then return url end
    return nil
end

local function num_str(v)
    v = tonumber(v) or 0
    if v < 0 then v = 0 end
    if v == math.floor(v) then return string.format("%d", v) end
    return (string.format("%.3f", v):gsub("0+$", ""):gsub("%.$", ""))
end

local function url_enc(s)
    return (tostring(s or ""):gsub("[^A-Za-z0-9%-_%.~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- OBS colour is 0xAABBGGRR; OBS Lua 5.1 has no bitwise operators
local function rgba_hex(v)
    v = math.floor(tonumber(v) or 0)
    local r = v % 256
    local g = math.floor(v / 256) % 256
    local b = math.floor(v / 65536) % 256
    local a = math.floor(v / 16777216) % 256
    return string.format("%02x%02x%02x%02x", r, g, b, a)
end

local function parse_time_param(url)
    url = trim(url)
    if url == "" then return nil end
    local raw = url:match("[?&#]t=([%w%.]+)") or url:match("[?&#]start=([%w%.]+)")
    if not raw then return nil end

    local plain = raw:match("^(%d+%.?%d*)$") or raw:match("^(%d+%.?%d*)[sS]$")
    if plain then return tonumber(plain) end

    local total, matched = 0, false
    local h = raw:match("^(%d+)[hH]")
    if h then total = total + tonumber(h) * 3600 matched = true end
    local m = raw:match("(%d+)[mM]")
    if m then total = total + tonumber(m) * 60 matched = true end
    local s = raw:match("(%d+%.?%d*)[sS]")
    if s then total = total + tonumber(s) matched = true end
    if matched then return total end
    return nil
end

local PLAYER_HTML = [==[
<!doctype html>
<html><head><meta charset="utf-8"><title>OBS YouTube Player</title>
<style>
  html,body{margin:0;padding:0;width:100%;height:100%;background:#000;overflow:hidden}
  #win{position:absolute;top:0;left:0;right:0;bottom:0;overflow:hidden;
       background:#000}
  #player{position:absolute;left:0;top:0;width:100%;height:100%;border:0;
          pointer-events:none}

  #cred{position:absolute;z-index:5;display:none;max-width:76%;box-sizing:border-box;
        pointer-events:none;line-height:1.3;white-space:pre-wrap;
        overflow-wrap:break-word;word-break:break-word;border-radius:.18em;
        padding:.22em .5em}
  /* a CSS transition is read from the after-change computed style */
  #mask{position:absolute;top:0;left:0;right:0;bottom:0;background:#000;z-index:10;
        opacity:1;transition:none}
  #mask.off{opacity:0;transition:none}
  #prep{position:absolute;left:0;right:0;top:50%;transform:translateY(-50%);
        display:none;text-align:center;color:#fff;pointer-events:none;
        font-family:Arial,Helvetica,sans-serif}
  #prepmsg{font-size:22px;opacity:.85}
  #prepnum{font-size:64px;font-weight:bold;line-height:1.25}

  #ctl{position:absolute;left:0;top:0;right:0;bottom:0;z-index:20;display:none;
       pointer-events:none;font-family:Arial,Helvetica,sans-serif;font-size:30px;
       color:#e6eaef}
  #ctlpanel{position:absolute;left:0;right:0;bottom:0;background:#1b1f25;
            border-top:2px solid #2b3138;padding:.4em .5em .5em;
            pointer-events:auto;display:flex;flex-direction:column;gap:.4em}

  #ctlread{display:flex;flex-wrap:wrap;gap:.4em}
  #ctlread>div{background:#15181c;border-radius:.3em;padding:.25em .5em;
               flex:1 1 7em;min-width:0}
  .ctllab{display:block;font-size:.62em;color:#8b96a3;letter-spacing:.14em;
          font-weight:bold;white-space:nowrap}
  .ctlbig{font-size:1.25em;font-weight:bold;line-height:1.15;
          font-family:Consolas,monospace;white-space:nowrap;overflow:hidden;
          text-overflow:ellipsis}
  #ctlrin .ctllab,#ctlrin .ctlbig{color:#5bc8a6}
  #ctlrout .ctllab,#ctlrout .ctlbig{color:#e0a04a}

  #ctlsl{position:relative;height:2.6em;margin:0 .7em;touch-action:none}
  #ctlsl .ctltrk{position:absolute;top:50%;left:0;right:0;height:.4em;
                 margin-top:-.2em;background:#262c33;border-radius:.2em}
  #ctlband{position:absolute;top:50%;height:.4em;margin-top:-.2em;
           background:#5bc8a62e;border-top:.14em solid #5bc8a6;
           border-bottom:.14em solid #5bc8a6}
  #ctlsl .ctlh{position:absolute;top:50%;width:.95em;height:2.1em;
               margin-top:-1.05em;margin-left:-.475em;border-radius:.18em;
               cursor:ew-resize;box-shadow:0 .08em .3em #000a}
  #ctlhi{background:#5bc8a6} #ctlho{background:#e0a04a}
  #ctlsl .ctlh::after{content:"";position:absolute;left:50%;top:50%;width:.12em;
               height:.8em;margin:-.4em 0 0 -.06em;background:#0007;
               border-radius:.06em}
  #ctlsl .ctlh.ctldrag{outline:.14em solid #fff7}
  #ctlph.ctldrag{outline:.14em solid #fff7;width:.3em;margin-left:-.15em}
  #ctlph{position:absolute;top:50%;width:.16em;height:2.5em;margin-top:-1.25em;
         margin-left:-.08em;background:#fff;border-radius:.08em;
         box-shadow:0 0 .3em #000c;pointer-events:none}
  #ctlph::before{content:"";position:absolute;left:50%;top:-.3em;
         margin-left:-.3em;border:.3em solid transparent;border-top-color:#fff}
  #ctlkeys{display:flex;justify-content:space-between;align-items:center;
           gap:1.2em;font-size:.6em;color:#8b96a3;letter-spacing:.06em;
           margin:.15em .9em .1em}
  #ctlkdrag,#ctlkplay{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  #ctlkplay{flex:0 0 auto}
  #ctlkeys b{display:inline-block;font-weight:700;letter-spacing:.1em;
             margin-left:.6em;padding:.16em .45em;border-radius:.35em;
             border:.1em solid transparent;line-height:1.15;
             vertical-align:middle}
  #ctlkeys b i{font-style:normal;opacity:.55;margin-right:.3em}
  .ctlki{color:#5bc8a6} .ctlko{color:#e0a04a} .ctlkp{color:#e8edf2}
  #ctlkeys b.ctlkon i{opacity:1}
  #ctlkfree.ctlkon,#ctlkph.ctlkon{background:#e8edf224;border-color:#e8edf2}
  #ctlkin.ctlkon{background:#5bc8a62e;border-color:#5bc8a6}
  #ctlkout.ctlkon{background:#e0a04a2e;border-color:#e0a04a}
  #ctlhk{font-size:.56em;color:#7c8794;letter-spacing:.06em;line-height:1.5;
         margin:0 .9em .3em;text-align:left}
  #ctlhk b{font-weight:700;color:#9aa6b3;letter-spacing:.09em}
  #ctlupd{display:none;font-size:.6em;font-weight:700;letter-spacing:.06em;
          line-height:1.4;margin:0 .9em .3em;padding:.35em .6em;
          border:.1em solid #4d93d6;border-radius:.3em;background:#4d93d62e;
          color:#9fcdf5;text-align:left}
  #ctlsl.ctlaim{cursor:crosshair}
  #ctlsl .ctlh.ctlarm{outline:.16em solid #fff;outline-offset:.08em;z-index:4}
  #ctlsl.ctlwait{opacity:.4}
  #ctlsl.ctlwait #ctlph{display:none}

  .ctlrow{display:flex;flex-wrap:wrap;align-items:flex-start;gap:.28em 0}
  .ctlgap{flex:0 0 auto;width:1.5em}
  .ctlgrp{flex:1 1 13em;min-width:0;display:flex;flex-direction:column;
          gap:.28em}
  .ctlbtns{display:flex;flex-wrap:wrap;gap:.22em}
  #ctltake{margin-bottom:.1em}
  #ctltake .ctlbtns{flex:1 1 auto}
  #ctl #ctltake button{flex:1 1 auto;min-height:1.7em;padding:0}
  #ctl #ctltake button svg{width:1.2em;height:1.2em}
  #ctl button#ctltin{background:#5bc8a62e;color:#5bc8a6}
  #ctl button#ctltout{background:#e0a04a2e;color:#e0a04a}
  .ctlul{height:.22em;border-radius:.11em;background:#8b96a3}
  .ctlgrp.ctli .ctlul{background:#5bc8a6}
  .ctlgrp.ctlo .ctlul{background:#e0a04a}

  #ctl button{background:#2a3038;color:#e6eaef;border:0;border-radius:.3em;
              cursor:pointer;font-family:Arial,Helvetica,sans-serif;
              font-size:.7em;min-height:3.8em;min-width:0;padding:0 .4em;
              flex:1 1 3.2em;display:inline-flex;align-items:center;
              justify-content:center;gap:.25em;
              transition:background .06s linear}
  #ctl button:active,#ctl button.ctlpress{background:#4d93d6}
  #ctl button.ctlon{background:#4d93d6;color:#06121d}
  #ctl button.ctlgo{background:#2e7d4f;flex:0 0 14.6em;width:14.6em;
              max-width:100%}
  #ctl button.ctlgo.ctlbad{background:#a3333a}
  #ctl button svg{width:1.45em;height:1.45em;flex:0 0 auto;stroke:currentColor;
              fill:none;stroke-width:2.4;stroke-linecap:round;
              stroke-linejoin:round}
  #ctl button em{font-style:normal;font-size:.9em;white-space:nowrap}
  .ctlgrp.ctli button,.ctlgrp.ctlo button{flex-direction:column;gap:.1em;
              min-height:4.6em;padding:.3em .15em}
  .ctlgrp.ctli button svg,.ctlgrp.ctlo button svg{width:2.1em;height:2.1em}
  .ctlgrp.ctli button em,.ctlgrp.ctlo button em{font-size:.64em;line-height:1;
              letter-spacing:.04em}
  #ctl button#ctlhin.ctlon{background:#5bc8a6}
  #ctl button#ctlhout.ctlon{background:#e0a04a}
  #ctl button#ctlhin.ctldim{background:#5bc8a63d;color:#9fe3cd}
  #ctl button#ctlhout.ctldim{background:#e0a04a3d;color:#f0cf9b}
  #ctlmk{position:absolute;display:none;align-items:center;
         justify-content:center;pointer-events:none;font-weight:bold;
         line-height:1;white-space:nowrap;color:#36e2ff;
         text-shadow:0 0 .12em #000,0 .05em .2em #000}
  #ctlmark{text-align:right;color:#8b96a3;opacity:.75;line-height:1.45}
  #ctlmark b{display:block;font-size:.5em;font-weight:600;letter-spacing:.14em;
             text-transform:uppercase}
  #ctlmark i{display:block;font-style:normal;font-size:.45em;
             letter-spacing:.04em;opacity:.8}
</style></head>
<body>
<div id="win"><div id="player"></div><div id="cred"><span id="credt"></span></div></div>
<div id="mask"><div id="prep"><div id="prepmsg"></div><div id="prepnum"></div></div></div>
<div id="ctl">
  <div id="ctlmk"></div>
  <div id="ctlpanel">
    <div id="ctlread">
      <div><b class="ctllab">PLAYER IS AT</b>
        <span class="ctlbig" id="ctlnow">--.---</span></div>
      <div id="ctlrin"><b class="ctllab">IN</b>
        <span class="ctlbig" id="ctlvin">--.---</span></div>
      <div id="ctlrout"><b class="ctllab">OUT</b>
        <span class="ctlbig" id="ctlvout">--.---</span></div>
      <div><b class="ctllab">RANGE</b>
        <span class="ctlbig" id="ctlvlen">--.---</span></div>
    </div>
    <div id="ctlsl">
      <div class="ctltrk"></div>
      <div id="ctlband" style="left:0%;width:100%"></div>
      <div class="ctlh" id="ctlhi" aria-label="IN" style="left:0%"></div>
      <div class="ctlh" id="ctlho" aria-label="OUT" style="left:100%"></div>
      <div id="ctlph" aria-label="playhead" style="left:0%"></div>
    </div>
    <div class="ctlrow" id="ctltake">
      <div class="ctlgrp">
        <div class="ctlbtns">
          <button id="ctltin" aria-label="take the playhead position as IN"><svg viewBox="0 0 24 24"><path d="M12 4v11"/><path d="M7 10l5 5 5-5"/><path d="M4 20h16"/></svg></button>
        </div>
      </div>
      <div class="ctlgap"></div>
      <div class="ctlgrp">
        <div class="ctlbtns">
          <button id="ctltout" aria-label="take the playhead position as OUT"><svg viewBox="0 0 24 24"><path d="M12 4v11"/><path d="M7 10l5 5 5-5"/><path d="M4 20h16"/></svg></button>
        </div>
      </div>
    </div>
    <div class="ctlrow">
      <div class="ctlgrp ctli">
        <div class="ctlbtns">
          <button id="ctlim1" data-n="in,-1" aria-label="IN -1s"><svg viewBox="0 0 24 24"><path d="M19 12H5"/><path d="M11 6l-6 6 6 6"/></svg><em>1S</em></button>
          <button id="ctlimf10" data-n="in,-10f" aria-label="IN -10 frames"><svg viewBox="0 0 24 24"><path d="M11 6l-6 6 6 6"/><path d="M18 6l-6 6 6 6"/></svg><em>10F</em></button>
          <button id="ctlimf1" data-n="in,-1f" aria-label="IN -1 frame"><svg viewBox="0 0 24 24"><path d="M15 6l-6 6 6 6"/></svg><em>1F</em></button>
          <button id="ctlhin" aria-label="go to IN and zoom the slider to the range"><svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="6"/><path d="M15.5 15.5L20.5 20.5"/></svg><em>ZOOM</em></button>
          <button id="ctlipf1" data-n="in,1f" aria-label="IN +1 frame"><svg viewBox="0 0 24 24"><path d="M9 6l6 6-6 6"/></svg><em>1F</em></button>
          <button id="ctlipf10" data-n="in,10f" aria-label="IN +10 frames"><svg viewBox="0 0 24 24"><path d="M6 6l6 6-6 6"/><path d="M13 6l6 6-6 6"/></svg><em>10F</em></button>
          <button id="ctlip1" data-n="in,1" aria-label="IN +1s"><svg viewBox="0 0 24 24"><path d="M5 12h14"/><path d="M13 6l6 6-6 6"/></svg><em>1S</em></button>
        </div>
        <div class="ctlul"></div>
      </div>
      <div class="ctlgap"></div>
      <div class="ctlgrp ctlo">
        <div class="ctlbtns">
          <button id="ctlom1" data-n="out,-1" aria-label="OUT -1s"><svg viewBox="0 0 24 24"><path d="M19 12H5"/><path d="M11 6l-6 6 6 6"/></svg><em>1S</em></button>
          <button id="ctlomf10" data-n="out,-10f" aria-label="OUT -10 frames"><svg viewBox="0 0 24 24"><path d="M11 6l-6 6 6 6"/><path d="M18 6l-6 6 6 6"/></svg><em>10F</em></button>
          <button id="ctlomf1" data-n="out,-1f" aria-label="OUT -1 frame"><svg viewBox="0 0 24 24"><path d="M15 6l-6 6 6 6"/></svg><em>1F</em></button>
          <button id="ctlhout" aria-label="go to OUT and zoom the slider to the range"><svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="6"/><path d="M15.5 15.5L20.5 20.5"/></svg><em>ZOOM</em></button>
          <button id="ctlopf1" data-n="out,1f" aria-label="OUT +1 frame"><svg viewBox="0 0 24 24"><path d="M9 6l6 6-6 6"/></svg><em>1F</em></button>
          <button id="ctlopf10" data-n="out,10f" aria-label="OUT +10 frames"><svg viewBox="0 0 24 24"><path d="M6 6l6 6-6 6"/><path d="M13 6l6 6-6 6"/></svg><em>10F</em></button>
          <button id="ctlop1" data-n="out,1" aria-label="OUT +1s"><svg viewBox="0 0 24 24"><path d="M5 12h14"/><path d="M13 6l6 6-6 6"/></svg><em>1S</em></button>
        </div>
        <div class="ctlul"></div>
      </div>
    </div>
    <div class="ctlrow">
      <div class="ctlgrp">
        <div class="ctlbtns">
          <button id="ctlpp" aria-label="play / pause"><svg viewBox="0 0 24 24"><path d="M7 4l13 8-13 8z"/></svg><em>PREVIEW</em></button>
        </div>
      </div>
      <div class="ctlgap"></div>
      <div class="ctlgrp">
        <div class="ctlbtns">
          <button id="ctlprange" aria-label="range: confine playback to the in-out range"><svg viewBox="0 0 24 24"><path d="M4 4v16"/><path d="M20 4v16"/><path d="M8 12h.01"/><path d="M12 12h.01"/><path d="M16 12h.01"/></svg></button>
          <button id="ctlloop" class="ctlon" aria-label="loop: at the end, start again instead of stopping"><svg viewBox="0 0 24 24"><path d="M4 12V9a3 3 0 013-3h13"/><path d="M17 3l3 3-3 3"/><path d="M20 12v3a3 3 0 01-3 3H4"/><path d="M7 21l-3-3 3-3"/></svg></button>
          <button id="ctlmute" aria-label="sound"><svg viewBox="0 0 24 24"><path d="M5 9v6h4l5 4V5L9 9z"/><path d="M17 9a4 4 0 010 6"/></svg></button>
          <button id="ctlconfirm" class="ctlgo" aria-label="confirm to OBS"><svg viewBox="0 0 24 24"><path d="M5 13l4 4L19 7"/></svg><em>CONFIRM TO OBS</em></button>
        </div>
      </div>
    </div>
    <div id="ctlkeys">
      <div id="ctlkdrag">CLICK THE BAR TO MOVE:
        <b id="ctlkfree" class="ctlkp"><i>1</i> NORMAL</b>
        <b id="ctlkin" class="ctlki"><i>2</i> IN</b>
        <b id="ctlkout" class="ctlko"><i>3</i> OUT</b>
        <b id="ctlkph" class="ctlkp"><i>4</i> PLAYHEAD</b></div>
      <div id="ctlkplay"><b class="ctlkp"><i>SPACE</i> PLAY / PAUSE</b></div>
    </div>
    <div id="ctlhk">OPEN THIS WINDOW INSTANTLY FROM A HOTKEY -
      ASSIGN ONE IN OBS <b>SETTINGS &gt; HOTKEYS</b> UNDER
      <b>CASTIKA - OPEN THE TRIM CONTROLS</b></div>
    <div id="ctlupd"></div>
    <div id="ctlmark"><b>Castika Simple Browser Recorder</b>
      <i>Copyright (c) 2026 Castika - Licensed under the Apache License, Version 2.0</i></div>
  </div>
</div>
<script>
(function(){
  var qs = new URLSearchParams(location.search);
  var VID    = qs.get('v') || '';
  var NONCE  = qs.get('nonce') || '0';
  var START  = parseFloat(qs.get('start') || '0');
  if (!(START >= 0)) { START = 0; }
  var GATE   = parseFloat(qs.get('gate') || '0');
  if (!(GATE > 0)) { GATE = 0; }
  if (GATE <= START) { GATE = 0; }
  var OUT    = parseFloat(qs.get('out') || '0');
  if (!(OUT > 0)) { OUT = 0; }
  if (GATE > 0 && OUT > 0 && OUT <= GATE) { OUT = 0; }
  var OVER   = parseInt(qs.get('overscan') || '140', 10);
  if (!(OVER >= 0)) { OVER = 140; }
  var VW     = parseInt(qs.get('vw') || '0', 10);
  var VH     = parseInt(qs.get('vh') || '0', 10);
  if (!(VW > 0)) { VW = 0; }
  if (!(VH > 0)) { VH = 0; }
  var FPS    = parseFloat(qs.get('fps') || '30');
  if (!(FPS >= 1)) { FPS = 30; }
  var RUNUP  = parseFloat(qs.get('runup') || '5');
  if (!(RUNUP > 0)) { RUNUP = 5; }
  var T0     = parseFloat(qs.get('t') || '0');
  if (!(T0 >= 0)) { T0 = 0; }
  var TIN    = parseFloat(qs.get('tin') || '0');
  if (!(TIN > 0)) { TIN = 0; }
  var TOUT   = parseFloat(qs.get('tout') || '0');
  if (!(TOUT > 0)) { TOUT = 0; }
  if (TOUT > 0 && TOUT <= TIN) { TOUT = 0; }
  var UPDTAG = qs.get('upd') || '';
  if (!/^v\d{1,9}(\.\d{1,9}){1,3}$/.test(UPDTAG)) { UPDTAG = ''; }
  var FR     = 1 / FPS;
  var LOOP   = qs.get('loop') !== '0';
  var CR_ON   = qs.get('cr') === '1';
  var CR_MODE = qs.get('crm') || 'yh';
  var CR_TEXT = qs.get('crt') || '';
  var CR_HAND = qs.get('crh') || '';
  var CR_FACE = qs.get('crf') || '';
  var CR_SIZE = parseInt(qs.get('crs') || '36', 10);
  if (!(CR_SIZE >= 6)) { CR_SIZE = 36; }
  if (CR_SIZE > 400) { CR_SIZE = 400; }
  var CR_BOLD = qs.get('crb') === '1';
  var CR_FG   = qs.get('crc') || 'ffffffff';
  var CR_BG   = qs.get('crg') || '8c000000';
  var CR_POS  = qs.get('crp') || 'bl';
  var CR_OFF  = parseFloat(qs.get('cro') || '0');
  if (!(CR_OFF >= 0)) { CR_OFF = 0; }
  if (CR_OFF > 45) { CR_OFF = 45; }
  var GO_POLL_MS = 250;
  var GO_STOP_MS = 1500;
  var GO_STOP_N = 2;
  var TAKE_SAFETY_MS = 15000;
  var REC_HEAD_SEC = 0.5;
  var UNMASK_DEADLINE_MS = 3000;

  var mask = document.getElementById('mask');
  var win = document.getElementById('win');
  var prep = document.getElementById('prep');
  var prepmsg = document.getElementById('prepmsg');
  var prepnum = document.getElementById('prepnum');
  var cred = document.getElementById('cred');
  var credt = document.getElementById('credt');
  var crLast = null;
  var player = null;
  var sawPlaying = false, reportedEnd = false, autoplayRetried = false;
  var endMasked = false;
  var unmasked = false;
  var unmutedOnce = false;
  var runupTimer = null;
  var recAsked = false, recAskedW = 0;
  var lastT = 0;
  var adReported = false;
  var goSeen = false;
  var goTimer = null, goBusy = false, goErrReported = false;
  var goZeroN = 0, goZeroSince = 0;
  var playbackAsked = false, safetyArmed = false, playerReady = false;
  var ctlOn = false, ctlDead = false, ctlRaf = null;
  var ctlIn = 0, ctlOut = -1;
  var ctlPos = 0;
  var ctlLoop = true, ctlRange = false;
  var ctlPlaying = false, ctlMuted = true, ctlState = -99;
  var ctlLitPP = null, ctlLitRG = null, ctlLitLP = null;
  var ctlDrag = false, ctlDragPlay = false, ctlSeekMs = 0, ctlMoved = false;
  var ctlSeeded = false;
  var ctlMode = 'free';
  var ctlPrevAt = 0, ctlPrevWho = '', ctlPrevEnd = -1, ctlPrevBack = -1;
  var ctlWantT = -1, ctlWantMs = 0;
  var ctlPrevFrom = -1;
  var ctlKickAt = 0, ctlKickOn = false, ctlDurTold = false;
  var ctlZoom = '';
  var ctlZA = -1, ctlZB = -1;
  var ctlLitZI = null, ctlLitZO = null;
  var ctlMkTxt = '', ctlMkUntil = 0, ctlMkArmI = true, ctlMkArmO = true;
  var ctlMkLit = '', ctlMkPhase = '', ctlMkPlayAfter = false, ctlMkMutedBy = false;
  var CTLMKMS = 1000, CTLMKNEAR = 0.75, CTLMKH = 0.14;
  var CTLZMPCT = 0.08, CTLZMMIN = 0.4, CTLENDGAP = 0.12;
  var CTLPANELMAX = 0.4;
  var CTLPANELMIN = 0.9;
  var ctlGridSaid = '';
  var CTLKICKMS = 900;
  var CTLPREVMS = 400, CTLPREVSEC = 2;
  var CTLSEEKTOL = 0.75, CTLSEEKMS = 1500;
  var curPad = OVER, curIW = 0, curIH = 0;

  // re-setting the iframe size attributes re-layouts even with identical numbers
  var layoutLocked = false;
  var lastGeoEl = null, lastGeo = '';

  // YouTube pins its chrome to the iframe edges and scales it with player height
  function applyOverscan(){
    if (layoutLocked) return;
    if (!win) return;
    var el = document.getElementById('player');
    if (!el) return;
    var w = win.clientWidth;
    var h = win.clientHeight;
    if (!(w > 0 && h > 0)) return;

    var P = Math.max(OVER, Math.round(h * 0.13));

    var rw = w;
    var a = (VW > 0 && VH > 0) ? (VW / VH) : 0;
    if (a > 0) {
      var want = Math.round(h * a);
      if (want >= 16 && want < w) { rw = want; }
    }
    var rh = h + 2 * P;
    var left = Math.round((w - rw) / 2);

    curPad = P; curIW = rw; curIH = rh;

    var geo = left + ',' + (-P) + ',' + rw + ',' + rh;
    if (el === lastGeoEl && geo === lastGeo) { return; }
    lastGeoEl = el;
    lastGeo = geo;

    try {
      el.style.position = 'absolute';
      el.style.left = left + 'px';
      el.style.top = (-P) + 'px';
      el.style.width = rw + 'px';
      el.style.height = rh + 'px';
      el.style.border = '0';
      el.style.pointerEvents = 'none';
    } catch (x) {}
    try { el.setAttribute('width', String(rw)); } catch (x) {}
    try { el.setAttribute('height', String(rh)); } catch (x) {}
  }
  window.addEventListener('resize', applyOverscan);

  function crRGBA(h, dflt){
    if (!/^[0-9a-fA-F]{8}$/.test(h)) { h = dflt; }
    var r = parseInt(h.substr(0, 2), 16);
    var g = parseInt(h.substr(2, 2), 16);
    var b = parseInt(h.substr(4, 2), 16);
    var a = parseInt(h.substr(6, 2), 16);
    return 'rgba(' + r + ',' + g + ',' + b + ',' + (a / 255).toFixed(3) + ')';
  }

  function crFamily(f){
    var out = '';
    for (var i = 0; i < f.length; i++) {
      var c = f.charAt(i);
      if (c !== '"' && c !== "'" && c !== '\\' && c !== ';'
          && c !== '<' && c !== '>' && c !== '{' && c !== '}') { out += c; }
    }
    out = out.replace(/^\s+/, '').replace(/\s+$/, '');
    if (out === '') { return 'Arial,Helvetica,sans-serif'; }
    return '"' + out + '",Arial,Helvetica,sans-serif';
  }

  function crAuthor(){
    try {
      var d = player ? player.getVideoData() : null;
      if (d && d.author) { return String(d.author); }
    } catch (x) {}
    return '';
  }

  function crPlat(s){
    if (s === '') { return ''; }
    return 'YouTube ' + s;
  }

  function crLabel(){
    if (CR_MODE === 'x') { return CR_TEXT; }
    if (CR_MODE === 'c') { return crAuthor(); }
    if (CR_MODE === 'yc') { return crPlat(crAuthor()); }
    if (CR_MODE === 'yh') { return crPlat(CR_HAND !== '' ? CR_HAND : crAuthor()); }
    if (CR_HAND !== '') { return CR_HAND; }
    return crAuthor();
  }

  function crPlace(){
    if (!cred || !win) { return; }
    var W = win.clientWidth, H = win.clientHeight;
    if (!(W > 0 && H > 0)) { return; }
    var ins = Math.round(H * 0.035);
    var off = Math.round(H * CR_OFF / 100);
    var atTop = (CR_POS === 'tl' || CR_POS === 'tr');
    var atLeft = (CR_POS === 'tl' || CR_POS === 'bl');
    try {
      cred.style.left = atLeft ? (ins + 'px') : 'auto';
      cred.style.right = atLeft ? 'auto' : (ins + 'px');
      cred.style.top = atTop ? ((ins + off) + 'px') : 'auto';
      cred.style.bottom = atTop ? 'auto' : ((ins + off) + 'px');
      cred.style.textAlign = atLeft ? 'left' : 'right';
    } catch (x) {}
  }

  function crInit(){
    if (!CR_ON || !cred) { return; }
    try {
      cred.style.fontFamily = crFamily(CR_FACE);
      cred.style.fontSize = CR_SIZE + 'px';
      cred.style.fontWeight = CR_BOLD ? 'bold' : 'normal';
      cred.style.color = crRGBA(CR_FG, 'ffffffff');
      cred.style.background = crRGBA(CR_BG, '8c000000');
    } catch (x) {}
    crPlace();
  }

  function crPaint(){
    if (!CR_ON || !cred || !credt) { return; }
    if (layoutLocked) { return; }
    var txt = crLabel();
    if (txt === crLast) { return; }
    crLast = txt;
    try {
      credt.textContent = txt;
      cred.style.display = (txt === '') ? 'none' : 'block';
    } catch (x) {}
    crPlace();
  }
  window.addEventListener('resize', crPlace);

  var report = (function(){
    var RETRY_EVERY_MS = 400;
    var RETRY_TRIES = 12;
    var RETRY_WINDOW_MS = 5000;
    var QMAX = 24;
    var q = [];
    var busy = false;

    function pump(){
      if (busy) { return; }
      var it = q[0];
      if (!it) { return; }
      if (it.tries >= RETRY_TRIES || Date.now() >= it.dead) {
        q.shift();
        pump();
        return;
      }
      it.tries++;
      busy = true;
      var settled = false;
      function finish(ok){
        if (settled) { return; }
        settled = true;
        busy = false;
        if (ok) {
          if (q[0] === it) { q.shift(); }
          pump();
        } else {
          setTimeout(pump, RETRY_EVERY_MS);
        }
      }
      var f = null;
      try { f = fetch(it.u, { cache:'no-store', keepalive:true }); } catch (e) { f = null; }
      if (f && typeof f.then === 'function') {
        try {
          f.then(function(r){
            var s = 0;
            try { s = (r && r.status) ? r.status : 0; } catch (x) { s = 0; }
            finish(s < 400);
          }, function(){ finish(false); });
        } catch (e2) { finish(false); }
        return;
      }
      try { var img = new Image(); img.src = it.u + '&_=' + Date.now(); } catch (e3) {}
      finish(true);
    }

    return function(type, extra){
      var u = '/__event?type=' + encodeURIComponent(type)
            + '&nonce=' + encodeURIComponent(NONCE)
            + '&id=' + encodeURIComponent(VID);
      if (extra) u += extra;
      while (q.length >= QMAX) { q.shift(); }
      q.push({ u: u, tries: 0, dead: Date.now() + RETRY_WINDOW_MS });
      pump();
      try { console.log('[YTEmbedRec] ' + type + (extra || '')); } catch (e) {}
    };
  })();

  function showMask(){ mask.classList.remove('off'); }
  function hideMask(){ if (endMasked) return; mask.classList.add('off'); }

  function unmuteForRecording(via){
    if (unmutedOnce || reportedEnd) return;
    var ok = false;
    try { player.unMute(); ok = true; } catch (x) {}
    if (!ok) return;
    unmutedOnce = true;
    report('unmuted', '&via=' + via);
  }

  function setPrep(msg, num){
    if (recAsked) { return; }
    try {
      if (prep) prep.style.display = 'block';
      if (prepmsg) prepmsg.textContent = msg;
      if (prepnum) prepnum.textContent = num;
    } catch (x) {}
  }
  function clearPrep(){
    try {
      if (prepmsg) prepmsg.textContent = '';
      if (prepnum) prepnum.textContent = '';
      if (prep) prep.style.display = 'none';
    } catch (x) {}
  }
  function stopRunupWatch(){
    if (runupTimer !== null) {
      try { cancelAnimationFrame(runupTimer); } catch (x) {}
      runupTimer = null;
    }
  }

  var posT = -1, posW = 0;
  var rateT = -1, rateW = 0, rateV = 1;
  var frameSec = 1 / 60, gapMs = 0;
  var frameN = 0, frameAcc = 0, gapN = 0, gapAcc = 0, lastFrameW = 0;

  function sampleAt(now){
    if (lastFrameW > 0) {
      var fd = now - lastFrameW;
      if (fd > 0 && fd < 200) {
        frameAcc += fd; frameN++;
        if (frameN >= 240) { frameAcc = frameAcc / 2; frameN = frameN / 2; }
        frameSec = (frameAcc / frameN) / 1000;
      }
    }
    lastFrameW = now;
    var t = -1;
    try { t = player.getCurrentTime(); } catch (x) { return; }
    if (!(t >= 0)) { return; }
    if (t === posT) { return; }
    if (posT >= 0) {
      var gw = now - posW;
      if (gw > 0 && gw < 2000) {
        gapAcc += gw; gapN++;
        if (gapN >= 120) { gapAcc = gapAcc / 2; gapN = gapN / 2; }
        gapMs = gapAcc / gapN;
      }
    }
    if (rateT < 0) { rateT = t; rateW = now; }
    else if ((now - rateW) >= 500) {
      var dv = t - rateT, dw = (now - rateW) / 1000;
      if (dw > 0) {
        var r = dv / dw;
        if (r > 0.25 && r < 4) { rateV = r; }
      }
      rateT = t; rateW = now;
    }
    posT = t; posW = now;
  }

  function estAt(now){
    if (posT < 0) { return -1; }
    var since = now - posW;
    var stall = Math.max(120, 3 * (gapMs || 40));
    if (since > stall) { return posT; }
    return posT + rateV * since / 1000;
  }

  function leadSec(){ return rateV * frameSec; }

  var outRaf = null;

  function outTick(now){
    outRaf = null;
    if (reportedEnd || !player) { return; }
    sampleAt(now);
    var est = estAt(now);
    if (est >= 0 && (est + leadSec()) >= OUT) {
      markEnded('outpoint');
      return;
    }
    outRaf = requestAnimationFrame(outTick);
  }

  function beginOutWatch(){
    if (!(OUT > 0) || reportedEnd || outRaf !== null) { return; }
    outRaf = requestAnimationFrame(outTick);
  }

  var ctlWired = false, ctlDurV = 0;
  var ctlConfirmHold = 0, ctlConfirmMsg = '', ctlConfirmBad = false;
  var ctlConfirmLast = '';

  function ctlE(id){ return document.getElementById(id); }
  function ctlFmt(v){
    if (!(v >= 0)) { return '--.---'; }
    var m = Math.floor(v / 60), s = v - m * 60;
    return m + ':' + (s < 10 ? '0' : '') + s.toFixed(3);
  }
  function ctlAt(){
    if (!player) { return -1; }
    try {
      var t = player.getCurrentTime();
      if (!(t >= 0)) { return -1; }
      return (t < FR) ? 0 : t;
    } catch (x) { return -1; }
  }

  function ctlOutV(){
    if (ctlOut >= 0) { return ctlOut; }
    return (ctlDurV > 0) ? ctlDurV : 0;
  }
  function ctlSeedOut(){
    if (ctlOut < 0 && ctlDurV > 0) { ctlOut = ctlDurV; }
  }
  function ctlClamp(v, lo, hi){
    if (!(v >= lo)) { v = lo; }
    if (v > hi) { v = hi; }
    if (!(v >= 0)) { v = 0; }
    return v;
  }
  function ctlZFit(){
    var dur = (ctlDurV > 0) ? ctlDurV : 0;
    var i = (ctlIn > 0) ? ctlIn : 0;
    var o = ctlOutV();
    if (!(o > i)) { o = i; }
    var m = (o - i) * CTLZMPCT;
    if (!(m >= CTLZMMIN)) { m = CTLZMMIN; }
    var a = i - m;
    var b = o + m;
    if (a < 0) { a = 0; }
    if (b > dur) { b = dur; }
    return { a: a, b: b };
  }

  function ctlZSeed(){
    var f = ctlZFit();
    ctlZA = f.a;
    ctlZB = f.b;
  }

  function ctlZHold(){
    if (!(ctlZB > ctlZA)) { return false; }
    if (ctlDrag) { return true; }
    var i = (ctlIn > 0) ? ctlIn : 0;
    var o = ctlOutV();
    if (i < ctlZA || i > ctlZB) { return false; }
    if (o < ctlZA || o > ctlZB) { return false; }
    return true;
  }

  function ctlZDrop(){
    ctlZA = -1;
    ctlZB = -1;
  }

  function ctlWin(){
    var dur = (ctlDurV > 0) ? ctlDurV : 0;
    if (!(dur > 0)) { return { a: 0, b: 0, w: 0 }; }
    if (ctlZoom !== 'in' && ctlZoom !== 'out') { return { a: 0, b: dur, w: dur }; }
    if (!ctlZHold()) { ctlZSeed(); }
    if (!(ctlZB > ctlZA)) { return { a: 0, b: dur, w: dur }; }
    return { a: ctlZA, b: ctlZB, w: ctlZB - ctlZA };
  }
  function ctlPct(t){
    var w = ctlWin();
    if (!(w.w > 0)) { return 0; }
    var p = ((t - w.a) / w.w) * 100;
    if (!(p >= 0)) { p = 0; }
    if (p > 100) { p = 100; }
    return p;
  }

  function ctlSendPair(){
    var i = (ctlIn > 0) ? ctlIn : 0;
    var o = ctlOutV();
    if (!(o > 0) || (ctlDurV > 0 && o >= ctlDurV - FR * 0.5)) { o = 0; }
    return { i: i, o: o };
  }

  function ctlSeekTo(t){
    if (!player) { return; }
    if (t < 0) { t = 0; }
    if (ctlDurV > 0 && t > ctlDurV - CTLENDGAP) { t = ctlDurV - CTLENDGAP; }
    ctlWantT = t;
    try { ctlWantMs = Date.now(); } catch (x) { ctlWantMs = 0; }
    try { player.seekTo(t, true); } catch (x) {}
  }

  function ctlSettled(a){
    if (!(ctlWantT >= 0)) { return true; }
    if (Math.abs(a - ctlWantT) <= CTLSEEKTOL) { ctlWantT = -1; return true; }
    var now3 = 0;
    try { now3 = Date.now(); } catch (x) { ctlWantT = -1; return true; }
    if (!ctlWantMs || now3 - ctlWantMs > CTLSEEKMS) { ctlWantT = -1; return true; }
    return false;
  }
  function ctlPause(){
    if (!player) { return; }
    try { player.pauseVideo(); } catch (x) {}
    ctlPlaying = false;
  }
  function ctlPlay(){
    if (!player) { return; }
    try { player.playVideo(); } catch (x) {}
    ctlPlaying = true;
  }

  function ctlSeedRange(){
    ctlIn = (TIN > 0) ? TIN : 0;
    ctlOut = (TOUT > 0) ? TOUT : -1;
  }

  function ctlConfirmPaint(){
    var b = ctlE('ctlconfirm');
    if (!b) { return; }
    var now = 0;
    try { now = Date.now(); } catch (x) { now = 0; }
    var txt, bad;
    if (ctlConfirmMsg !== '' && now < ctlConfirmHold) {
      txt = ctlConfirmMsg;
      bad = ctlConfirmBad;
    } else {
      ctlConfirmMsg = '';
      bad = (ctlIn > 0 && ctlIn < RUNUP);
      txt = bad ? 'CONFIRM - NO RUN-UP' : 'CONFIRM TO OBS';
    }
    var key = (bad ? '1' : '0') + txt;
    if (key === ctlConfirmLast) { return; }
    ctlConfirmLast = key;
    try {
      b.querySelector('em').textContent = txt;
      b.classList.toggle('ctlbad', bad);
    } catch (x) {}
  }
  function ctlUpdPaint(){
    var el = ctlE('ctlupd');
    if (!el || UPDTAG === '') { return; }
    try {
      el.textContent = 'UPDATE AVAILABLE - ' + UPDTAG + ' IS OUT - GITHUB.COM/CASTIKA-CODE/SIMPLE-BROWSER-RECORDER';
      el.style.display = 'block';
    } catch (x) {}
  }
  function ctlConfirmFlash(msg, bad){
    ctlConfirmMsg = msg;
    ctlConfirmBad = bad;
    try { ctlConfirmHold = Date.now() + 2500; } catch (x) { ctlConfirmHold = 0; }
    ctlConfirmPaint();
  }

  function ctlGcd(a, b){
    a = Math.abs(a);
    b = Math.abs(b);
    while (b > 0) { var r = a % b; a = b; b = r; }
    return a;
  }

  function ctlLattice(n1, n2, n3, lo, hi, want){
    var g = ctlGcd(ctlGcd(n1, n2), n3), best = 0, bd = 1e9;
    if (!(g > 0)) { return 0; }
    var m = ((n1 / g) % 2 === 1 || (n2 / g) % 2 === 1) ? 2 : 1;
    for (var k = Math.max(1, Math.ceil(lo * g / m - 1e-9)); k < 1000000; k++) {
      var t = k * m / g;
      if (t > hi + 1e-9) { break; }
      if (Math.abs(t - want) < bd) { bd = Math.abs(t - want); best = t; }
      if (t > want) { break; }
    }
    return best;
  }

  function ctlPanelNow(px){
    try {
      ctlE('ctl').style.fontSize = px + 'px';
      return ctlE('ctlpanel').offsetHeight || 0;
    } catch (x) { return 0; }
  }

  function ctlPanelFit(fs, ph, room){
    if (ph <= room) { return true; }
    var f = Math.floor(fs * (room - 2) / (ph - 2) * 20) / 20;
    for (var i = 0; i < 80 && f >= fs * CTLPANELMIN && f >= 8; i++) {
      var p = ctlPanelNow(f);
      if (p > 0 && p <= room) {
        if (Math.abs((p - 2) / f - (ph - 2) / fs) <= 0.25) { return true; }
        break;
      }
      f -= 0.05;
    }
    ctlPanelNow(fs);
    return false;
  }

  function layoutCtl(){
    if (!ctlOn) { return; }
    var ctl = ctlE('ctl'), panel = ctlE('ctlpanel');
    if (!ctl || !panel || !win) { return; }
    var W = 0, H = 0;
    try {
      W = document.documentElement.clientWidth || 0;
      H = document.documentElement.clientHeight || 0;
    } catch (x) {}
    if (!(W > 16 && H > 16)) { return; }
    // OBS's Interact window scales the whole page to fit its own size
    var fs = Math.round(Math.min(W, H) / 36);
    if (!(fs >= 10)) { fs = 10; }
    try { ctl.style.fontSize = fs + 'px'; } catch (x) {}
    var ph = 0;
    try { ph = panel.offsetHeight || 0; } catch (x) {}
    var cap = Math.round(H * CTLPANELMAX);
    for (var pi = 0; pi < 4 && cap > 0 && ph > cap && fs > 8; pi++) {
      fs = Math.floor(fs * cap / ph);
      if (!(fs >= 8)) { fs = 8; }
      try { ctl.style.fontSize = fs + 'px'; } catch (x) {}
      try { ph = panel.offsetHeight || 0; } catch (x) {}
    }
    var g = Math.max(6, Math.round(fs * 0.4));
    var bw = W - 2 * g;
    var bh = H - ph - 2 * g;
    if (!(bw > 16)) { bw = 16; }
    if (!(bh > 16)) { bh = 16; }
    var s = Math.min(bw / W, bh / H, 2 / 3);
    if (!(s > 0)) { s = 1; }
    var dpr = 1;
    try { dpr = window.devicePixelRatio || 1; } catch (x) {}
    if (!(dpr >= 0.25 && dpr <= 16)) { dpr = 1; }
    var ew = W, eh = H, eo = 0, et = 0;
    try {
      var pe = ctlE('player');
      if (pe && pe.offsetWidth > 16 && pe.offsetHeight > 16) {
        ew = pe.offsetWidth; eh = pe.offsetHeight;
        eo = pe.offsetLeft; et = pe.offsetTop;
      }
    } catch (x) {}
    var sx = s, sy = s, tx = 0, ty = 0, t = 0, u = 0, whole = false;
    var tc = 2 * dpr / 3 + 1e-9, lo = s * dpr - 1 / H;
    for (var wi = 0; wi < 4 && !whole; wi++) {
      t = ctlLattice(H, eh, et, lo, tc, lo);
      if (!(t > 0)) { break; }
      u = ctlLattice(W, ew, eo, t * 0.99, Math.min(t * 1.01, tc, bw * dpr / W), t);
      if (u > 0 && ctlPanelFit(fs, ph, H - 2 * g - Math.round(t * H) / dpr)) { whole = true; }
      lo = t + 1e-6;
    }
    if (whole) {
      sx = u / dpr;
      sy = t / dpr;
      tx = Math.round((W * dpr - u * W) / 2) / dpr;
      ty = Math.round(g * dpr) / dpr;
    } else {
      var nw = 2 * Math.floor(s * ew * dpr / 2 + 1e-6);
      var nh = 2 * Math.floor(s * eh * dpr / 2 + 1e-6);
      if (nw >= 16 && nh >= 16) {
        sx = nw / (ew * dpr);
        sy = nh / (eh * dpr);
      }
      tx = (Math.round((W - sx * W) / 2 * dpr + sx * eo * dpr) - sx * eo * dpr) / dpr;
      ty = (Math.round(g * dpr + sy * et * dpr) - sy * et * dpr) / dpr;
      var gk = W + 'x' + H + '@' + dpr + ':' + ew + ',' + eh + ',' + eo + ',' + et;
      if (ctlGridSaid !== gk) {
        ctlGridSaid = gk;
        report('ctl_grid', '&w=' + W + '&h=' + H + '&dpr=' + dpr);
      }
    }
    try {
      win.style.transformOrigin = '0 0';
      win.style.transform = 'translate(' + tx + 'px,' + ty + 'px) scale(' + sx + ',' + sy + ')';
    } catch (x) {}
    try {
      var mk = ctlE('ctlmk');
      if (mk) {
        var mf = Math.round(sy * H * CTLMKH);
        if (!(mf >= 8)) { mf = 8; }
        mk.style.left = (Math.round(tx * dpr) / dpr) + 'px';
        mk.style.top = (Math.round(ty * dpr) / dpr) + 'px';
        mk.style.width = (Math.round(sx * W * dpr) / dpr) + 'px';
        mk.style.height = (Math.round(sy * H * dpr) / dpr) + 'px';
        mk.style.fontSize = mf + 'px';
      }
    } catch (x) {}
  }
  window.addEventListener('resize', layoutCtl);
  try {
    new MutationObserver(layoutCtl).observe(win, { childList: true, subtree: true,
      attributes: true, attributeFilter: ['style', 'width', 'height'] });
  } catch (x) {}

  function ctlBtnPaint(){
    var pp = ctlPlaying;
    try {
      if (pp !== ctlLitPP) {
        ctlLitPP = pp;
        ctlE('ctlpp').classList.toggle('ctlon', pp);
        ctlE('ctlpp').querySelector('svg').innerHTML = pp
          ? '<path d="M8 5v14"/><path d="M16 5v14"/>'
          : '<path d="M7 4l13 8-13 8z"/>';
      }
      if (ctlRange !== ctlLitRG) {
        ctlLitRG = ctlRange;
        ctlE('ctlprange').classList.toggle('ctlon', ctlRange);
      }
      if (ctlLoop !== ctlLitLP) {
        ctlLitLP = ctlLoop;
        ctlE('ctlloop').classList.toggle('ctlon', ctlLoop);
      }
      var zon = (ctlZoom === 'in' || ctlZoom === 'out');
      var ki = (ctlZoom === 'in') ? 2 : (zon ? 1 : 0);
      var ko = (ctlZoom === 'out') ? 2 : (zon ? 1 : 0);
      if (ki !== ctlLitZI) {
        ctlLitZI = ki;
        ctlE('ctlhin').classList.toggle('ctlon', ki === 2);
        ctlE('ctlhin').classList.toggle('ctldim', ki === 1);
      }
      if (ko !== ctlLitZO) {
        ctlLitZO = ko;
        ctlE('ctlhout').classList.toggle('ctlon', ko === 2);
        ctlE('ctlhout').classList.toggle('ctldim', ko === 1);
      }
    } catch (x) {}
  }

  function ctlMkPaint(){
    var mk = ctlE('ctlmk');
    if (!mk) { return; }
    var on = ctlOn && !ctlDead && !goSeen && ctlMkTxt !== '';
    if (on && ctlMkPhase === '') {
      var now = 0;
      try { now = Date.now(); } catch (x) { now = 0; }
      if (now >= ctlMkUntil) { ctlMkTxt = ''; on = false; }
    }
    var key = on ? ctlMkTxt : '';
    if (key === ctlMkLit) { return; }
    ctlMkLit = key;
    try {
      mk.textContent = key;
      mk.style.display = on ? 'flex' : 'none';
    } catch (x) {}
  }

  function ctlMkClear(){
    ctlMkTxt = '';
    ctlMkUntil = 0;
    ctlMkArmI = true;
    ctlMkArmO = true;
    ctlMkPhase = '';
    ctlMkPlayAfter = false;
    ctlMkMute(false);
    ctlMkPaint();
  }

  function ctlMkMute(on){
    if (!player) { return; }
    if (on) {
      if (ctlMkMutedBy || ctlMuted) { return; }
      try { player.mute(); } catch (x) {}
      ctlMkMutedBy = true;
      return;
    }
    if (!ctlMkMutedBy) { return; }
    ctlMkMutedBy = false;
    if (ctlMuted) { return; }
    try { player.unMute(); } catch (x) {}
  }

  function ctlMkBegin(phase, playAfter){
    if (!ctlOn || ctlDead || goSeen) { return; }
    ctlMkMute(true);
    ctlMkPhase = phase;
    ctlMkPlayAfter = playAfter ? true : false;
    ctlMkTxt = (phase === 'start') ? 'Start Point' : 'End Point';
    try { ctlMkUntil = Date.now() + CTLMKMS; } catch (x) { ctlMkUntil = 0; }
  }

  function ctlMkStep(){
    if (ctlMkPhase === '') { return; }
    var now = 0;
    try { now = Date.now(); } catch (x) { now = 0; }
    if (now < ctlMkUntil) { return; }
    if (ctlMkPhase === 'end') {
      ctlMkPhase = '';
      ctlPos = ctlIn;
      ctlSeekTo(ctlIn);
      if (ctlLoop) { ctlMkBegin('start', true); }
      else { ctlMkTxt = ''; ctlMkMute(false); }
      return;
    }
    ctlMkPhase = '';
    ctlMkTxt = '';
    ctlMkMute(false);
    if (ctlMkPlayAfter) {
      ctlMkPlayAfter = false;
      ctlPlay();
    }
  }

  function ctlMkFire(txt){
    if (!ctlOn || ctlDead || goSeen) { return; }
    ctlMkTxt = txt;
    try { ctlMkUntil = Date.now() + CTLMKMS; } catch (x) { ctlMkUntil = 0; }
  }

  function ctlSyncPlay(ps){
    if (!ctlPlaying && ps === 1) { ctlPause(); }
  }

  function ctlMkWatch(a){
    if (!(a >= 0) || !(ctlDurV > 0)) { return; }
    var i = (ctlIn > 0) ? ctlIn : 0;
    var o = ctlOutV();
    var hi = (a >= i - FR * 0.5) && (a <= i + CTLMKNEAR);
    var ho = (o > i) && (a >= o - FR * 0.5) && (a <= o + CTLMKNEAR);
    if (!hi) { ctlMkArmI = true; }
    if (!ho) { ctlMkArmO = true; }
    if (!ctlPlaying || ctlRange || ctlMkPhase !== '') { return; }
    if (hi && ctlMkArmI) { ctlMkArmI = false; ctlMkFire('Start Point'); }
    if (ho && ctlMkArmO) { ctlMkArmO = false; ctlMkFire('End Point'); }
  }

  function ctlPaint(){
    var a = ctlAt();
    if (!ctlDrag && a >= 0 && ctlSettled(a)) { ctlPos = a; }
    ctlMkWatch(a);
    var o = ctlOutV();
    ctlBtnPaint();
    try {
      ctlE('ctlnow').textContent = (a >= 0) ? ctlFmt(a) : '--.---';
      ctlE('ctlvin').textContent = ctlFmt(ctlIn);
      ctlE('ctlvout').textContent = ctlFmt(ctlOut);
      ctlE('ctlvlen').textContent = !(ctlDurV > 0) ? 'WAIT'
        : ((o > ctlIn) ? ((o - ctlIn).toFixed(3) + 's') : 'INVALID');
      ctlE('ctlsl').classList.toggle('ctlwait', !(ctlDurV > 0));
      if (ctlDurV > 0) {
        ctlE('ctlph').style.left = ctlPct(ctlPos) + '%';
        ctlE('ctlhi').style.left = ctlPct(ctlIn) + '%';
        ctlE('ctlho').style.left = ctlPct(o) + '%';
        var bd = ctlE('ctlband');
        bd.style.left = ctlPct(ctlIn) + '%';
        bd.style.width = (ctlPct(o) - ctlPct(ctlIn)) + '%';
      }
    } catch (x) {}
    ctlMkPaint();
  }

  function ctlKick(){
    if (ctlDurV > 0 || ctlKickOn || !player) { return; }
    if (ctlKickAt === 0) { return; }
    var now = 0;
    try { now = Date.now(); } catch (x) { return; }
    if (now - ctlKickAt < CTLKICKMS) { return; }
    ctlKickOn = true;
    ctlMkMute(true);
    try { player.playVideo(); } catch (x) {}
  }

  function ctlKickDone(){
    ctlKickOn = false;
    ctlKickAt = 0;
    try { player.pauseVideo(); } catch (x) {}
    ctlPlaying = false;
    ctlMkMute(false);
  }

  function ctlDurEdge(){
    ctlSeedOut();
    if (ctlKickOn) { ctlKickDone(); }
    if (!ctlSeeded) {
      ctlSeeded = true;
      ctlPos = (ctlIn > 0) ? ctlIn : 0;
      ctlSeekTo(ctlPos);
    }
    if (!ctlDurTold) {
      ctlDurTold = true;
      report('ready', '&dur=' + ctlDurV);
    }
    ctlConfirmPaint();
  }

  function ctlInRange(){
    var a = ctlAt();
    var at = (a >= 0) ? a : ctlPos;
    var o = ctlOutV();
    if (!(o > ctlIn)) { return false; }
    return at >= ctlIn && at < o;
  }

  function ctlToggle(){
    if (!player || !(ctlDurV > 0)) { return; }
    ctlPrevStop();
    try {
      if (ctlPlaying) { player.pauseVideo(); ctlPlaying = false; }
      else if (ctlRange && !ctlInRange()) {
        ctlPos = ctlIn;
        ctlSeekTo(ctlIn);
        player.pauseVideo();
        ctlPlaying = false;
        ctlMkBegin('start', true);
      } else {
        player.playVideo();
        ctlPlaying = true;
      }
    } catch (x) {}
    ctlPaint();
  }

  function ctlHome(){
    return ctlRange ? ctlIn : 0;
  }

  function ctlOnEnded(){
    ctlPrevStop();
    if (!ctlPlaying) { ctlPause(); return; }
    var h = ctlHome();
    ctlSeekTo(h);
    ctlPos = h;
    if (ctlLoop) { ctlPlay(); return; }
    ctlPause();
  }

  function ctlTick(now){
    ctlRaf = null;
    if (!ctlOn) { return; }
    if (player) {
      var d0 = ctlDurV;
      try { ctlDurV = player.getDuration() || 0; } catch (x) {}
      ctlSeedOut();
      if (!(d0 > 0) && ctlDurV > 0) { ctlDurEdge(); } else { ctlKick(); }
      var ps = -99;
      try { ps = player.getPlayerState(); } catch (x) { ps = -99; }
      if (ps !== ctlState) {
        ctlState = ps;
        if (ps === 0) { ctlOnEnded(); }
      }
      ctlSyncPlay(ps);
      ctlPrevStep();
      if (ctlRange && ctlPlaying && ctlMkPhase === '' && ctlPrevEnd < 0) {
        var a2 = ctlAt();
        var o2 = ctlOutV();
        if (a2 >= 0 && o2 > ctlIn && a2 >= o2) {
          ctlPause();
          ctlPos = o2;
          ctlSeekTo(o2);
          ctlMkBegin('end', false);
        }
      }
      ctlMkStep();
    }
    ctlPaint();
    ctlConfirmPaint();
    ctlRaf = requestAnimationFrame(ctlTick);
  }

  function ctlMove(which, d){
    var dur = (ctlDurV > 0) ? ctlDurV : 0;
    if (!(dur > 0)) { return -1; }
    var cur;
    if (which === 'in') {
      cur = ctlClamp(ctlIn + d, 0, ctlOutV() - FR);
      ctlIn = cur;
    } else {
      cur = ctlClamp(ctlOutV() + d, Math.min(dur, ctlIn + FR), dur);
      ctlOut = cur;
    }
    ctlPause();
    ctlMkClear();
    ctlPos = cur;
    ctlSeekTo(cur);
    return cur;
  }

  function ctlNudge(which, d){
    if (ctlMove(which, d) < 0) { return; }
    ctlPrevArm(which);
    ctlConfirmPaint();
    ctlPaint();
  }

  function ctlTake(which){
    if (!(ctlDurV > 0)) { return; }
    var a = ctlAt();
    var at = (a >= 0) ? a : ctlPos;
    ctlPause();
    ctlMkClear();
    ctlSetBy(which, at, true);
    ctlPrevArm(which);
    ctlConfirmPaint();
    ctlPaint();
  }

  function ctlPrevArm(which){
    ctlPrevEnd = -1;
    ctlPrevBack = -1;
    ctlPrevWho = which;
    try { ctlPrevAt = Date.now(); } catch (x) { ctlPrevAt = 0; }
  }

  function ctlPrevRun(from, end, back){
    if (from < 0) { from = 0; }
    if (end > ctlDurV) { end = ctlDurV; }
    if (!(end > from)) { return false; }
    ctlPrevEnd = end;
    ctlPrevBack = back;
    ctlPrevFrom = from;
    ctlPos = from;
    ctlSeekTo(from);
    return true;
  }

  function ctlPrevStep(){
    if (ctlPrevFrom >= 0) {
      var a5 = ctlAt();
      if (a5 >= 0 && ctlSettled(a5)) {
        ctlPrevFrom = -1;
        ctlPlay();
      }
      return;
    }
    if (ctlPrevEnd >= 0) {
      var a3 = ctlAt();
      if (a3 >= 0 && a3 >= ctlPrevEnd) {
        var back = ctlPrevBack;
        ctlPause();
        ctlPrevStop();
        if (back >= 0) { ctlPos = back; ctlSeekTo(back); }
      }
      return;
    }
    if (!ctlPrevAt || !(ctlDurV > 0)) { return; }
    var now2 = 0;
    try { now2 = Date.now(); } catch (x) { return; }
    if (now2 - ctlPrevAt < CTLPREVMS) { return; }
    ctlPrevAt = 0;
    if (ctlPrevWho === 'out') {
      var o = ctlOutV();
      ctlPrevRun(o - CTLPREVSEC, o, o);
    } else {
      var i = (ctlIn > 0) ? ctlIn : 0;
      ctlPrevRun(i, i + CTLPREVSEC, i);
    }
  }

  function ctlGoMark(which){
    var dur = (ctlDurV > 0) ? ctlDurV : 0;
    if (!(dur > 0)) { return; }
    ctlPause();
    ctlMkClear();
    ctlZoom = (ctlZoom === which) ? '' : which;
    ctlZDrop();
    var t = (which === 'in') ? ((ctlIn > 0) ? ctlIn : 0) : ctlOutV();
    ctlPos = t;
    ctlSeekTo(t);
    ctlConfirmPaint();
    ctlPaint();
  }

  function ctlFollow(t, force){
    ctlPos = t;
    ctlPaint();
    var now = 0;
    try { now = Date.now(); } catch (x) { now = 0; }
    // one seekTo on the embed is a range request and a decoder reset
    if (!force && now - ctlSeekMs < 120) { return; }
    ctlSeekMs = now;
    ctlSeekTo(t);
  }

  function ctlTAt(ev){
    var sl = ctlE('ctlsl');
    if (!sl || !(ctlDurV > 0)) { return -1; }
    var r = sl.getBoundingClientRect();
    if (!(r.width > 0)) { return -1; }
    var w = ctlWin();
    if (!(w.w > 0)) { return -1; }
    var x = ev.clientX - r.left;
    if (!(x >= 0)) { x = 0; }
    if (x > r.width) { x = r.width; }
    return w.a + (x / r.width) * w.w;
  }

  function ctlMarkOf(who){
    if (who === 'in') { return (ctlIn > 0) ? ctlIn : 0; }
    if (who === 'out') { return ctlOutV(); }
    return ctlPos;
  }

  function ctlGoTo(t){
    ctlPause();
    ctlMkClear();
    ctlPos = t;
    ctlSeekTo(t);
    ctlPaint();
  }

  function ctlSetMode(who){
    if (who !== 'in' && who !== 'out' && who !== 'ph') { who = 'free'; }
    ctlMode = who;
    ctlModePaint();
    if (!(ctlDurV > 0)) { return; }
    if (who === 'in' || who === 'out') { ctlGoTo(ctlMarkOf(who)); }
  }

  function ctlPrevStop(){
    ctlPrevAt = 0;
    ctlPrevEnd = -1;
    ctlPrevBack = -1;
    ctlPrevFrom = -1;
  }

  function ctlModePaint(){
    try {
      ['free', 'in', 'out', 'ph'].forEach(function(k){
        ctlE('ctlk' + k).classList.toggle('ctlkon', ctlMode === k);
      });
      ctlE('ctlhi').classList.toggle('ctlarm', ctlMode === 'in');
      ctlE('ctlho').classList.toggle('ctlarm', ctlMode === 'out');
      ctlE('ctlsl').classList.toggle('ctlaim', ctlMode !== 'free');
    } catch (x) {}
  }

  function ctlSetBy(who, t, fin){
    if (who === 'in') {
      ctlIn = ctlClamp(t, 0, ctlOutV() - FR);
      ctlFollow(ctlIn, fin);
      return;
    }
    if (who === 'out') {
      var dur = (ctlDurV > 0) ? ctlDurV : 0;
      ctlOut = ctlClamp(t, Math.min(dur, ctlIn + FR), dur);
      ctlFollow(ctlOut, fin);
      return;
    }
    ctlPos = ctlClamp(t, 0, (ctlDurV > 0) ? ctlDurV : 0);
    ctlFollow(ctlPos, fin);
  }

  function ctlGrab(el, who, ev, hold){
    if (!(ctlDurV > 0)) { return; }
    var lit = (who === 'pos') ? ctlE('ctlph') : ctlE(who === 'in' ? 'ctlhi' : 'ctlho');
    try { el.setPointerCapture(ev.pointerId); } catch (x) {}
    try { lit.classList.add('ctldrag'); } catch (x) {}
    ctlDrag = true;
    ctlPrevStop();
    ctlDragPlay = ctlPlaying;
    ctlPause();
    ctlMkClear();
    if (hold) { ctlGoTo(ctlMarkOf(who)); }
    else { ctlSetBy(who, ctlTAt(ev), false); }
    var move = function(e){
      var t = ctlTAt(e);
      if (!(t >= 0)) { return; }
      ctlMoved = true;
      ctlSetBy(who, t, false);
    };
    var done = false;
    var off = function(){
      if (done) { return; }
      done = true;
      try { lit.classList.remove('ctldrag'); } catch (x) {}
      el.removeEventListener('pointermove', move);
      el.removeEventListener('pointerup', up);
      el.removeEventListener('pointercancel', up);
      el.removeEventListener('lostpointercapture', off);
      try { window.removeEventListener('pointerup', off); } catch (x) {}
      try { window.removeEventListener('pointercancel', off); } catch (x) {}
      ctlDrag = false;
      ctlMoved = false;
      ctlConfirmPaint();
      if (ctlDragPlay) { ctlPlay(); }
    };
    var up = function(e){
      if (done) { return; }
      var t = ctlTAt(e);
      if (t >= 0 && !(hold && !ctlMoved)) { ctlSetBy(who, t, true); }
      off();
    };
    el.addEventListener('pointermove', move);
    el.addEventListener('pointerup', up);
    el.addEventListener('pointercancel', up);
    el.addEventListener('lostpointercapture', off);
    try { window.addEventListener('pointerup', off); } catch (x) {}
    try { window.addEventListener('pointercancel', off); } catch (x) {}
    try { ev.preventDefault(); } catch (x) {}
  }


  function ctlBind(id, fn){
    var el = ctlE(id);
    if (!el) { return; }
    try {
      el.addEventListener('click', function(ev){
        el.classList.add('ctlpress');
        setTimeout(function(){
          try { el.classList.remove('ctlpress'); } catch (x) {}
        }, 140);
        fn(ev);
        try { ctlE('ctlpp').focus(); } catch (x) {}
      });
    } catch (x) {}
  }

  function ctlKey(ev){
    if (!ctlOn || ctlDead) { return; }
    var k = '';
    try { k = ev.key || ''; } catch (x) { return; }
    if (k === '1' || k === 'Escape') { ctlSetMode('free'); return; }
    if (k === '2') { ctlSetMode('in'); return; }
    if (k === '3') { ctlSetMode('out'); return; }
    if (k === '4') { ctlSetMode('ph'); return; }
    if (k !== ' ' && k !== 'Spacebar') { return; }
    try { ev.preventDefault(); } catch (x) {}
    ctlToggle();
  }

  function ctlWire(){
    if (ctlWired) { return; }
    ctlWired = true;
    try { window.addEventListener('keydown', ctlKey); } catch (x) {}
    ctlModePaint();

    try {
      var nb = document.querySelectorAll('#ctl button[data-n]');
      for (var i = 0; i < nb.length; i++) {
        (function(el){
          var a = String(el.getAttribute('data-n')).split(',');
          var who = a[0], d = a[1];
          var amt = (d.slice(-1) === 'f')
            ? parseFloat(d.slice(0, -1)) * FR : parseFloat(d);
          ctlBind(el.id, function(){ ctlNudge(who, amt); });
        })(nb[i]);
      }
    } catch (x) {}

    try {
      var sl = ctlE('ctlsl');
      sl.addEventListener('pointerdown', function(ev){
        var who = 'pos', onh = false;
        try {
          onh = !!(ev.target && ev.target.classList
                   && ev.target.classList.contains('ctlh'));
        } catch (x) { onh = false; }
        if (ctlMode === 'in' || ctlMode === 'out') {
          who = ctlMode;
          onh = false;
        } else if (ctlMode === 'free' && onh) {
          who = (ev.target.id === 'ctlhi') ? 'in' : 'out';
        }
        ctlGrab(sl, who, ev, onh);
      });
    } catch (x) {}

    ctlBind('ctltin', function(){ ctlTake('in'); });
    ctlBind('ctltout', function(){ ctlTake('out'); });

    ctlBind('ctlloop', function(){
      ctlLoop = !ctlLoop;
      ctlPaint();
    });

    ctlBind('ctlpp', function(){ ctlToggle(); });
    ctlBind('ctlmute', function(){
      if (!player) { return; }
      try {
        ctlMkMutedBy = false;
        if (ctlMuted) { player.unMute(); ctlMuted = false; }
        else { player.mute(); ctlMuted = true; }
      } catch (x) {}
      try { ctlE('ctlmute').classList.toggle('ctlon', !ctlMuted); } catch (x) {}
    });
    ctlBind('ctlprange', function(){
      ctlRange = !ctlRange;
      if (ctlRange && ctlPlaying) {
        ctlPos = ctlIn;
        ctlSeekTo(ctlIn);
      }
      ctlPaint();
    });
    ctlBind('ctlhin', function(){ ctlGoMark('in'); });
    ctlBind('ctlhout', function(){ ctlGoMark('out'); });

    ctlBind('ctlconfirm', function(){
      var pr = ctlSendPair();
      var i = pr.i, o = pr.o;
      if (o > 0 && o <= i) {
        ctlConfirmFlash('SEND FAILED - PRESS AGAIN', true);
        return;
      }
      var u = '/__event?type=trim&in=' + i.toFixed(3) + '&out=' + o.toFixed(3);
      var f = null;
      try { f = fetch(u, { cache:'no-store' }); } catch (e) { f = null; }
      if (f && typeof f.then === 'function') {
        f.then(function(r){
          var s = 0;
          try { s = (r && r.status) ? r.status : 0; } catch (x) { s = 0; }
          if (s < 400) { ctlConfirmFlash('SENT', false); }
          else { ctlConfirmFlash('SEND FAILED - PRESS AGAIN', true); }
        }, function(){ ctlConfirmFlash('SEND FAILED - PRESS AGAIN', true); });
      } else {
        ctlConfirmFlash('SEND FAILED - PRESS AGAIN', true);
      }
    });

  }

  function showCtl(){
    if (ctlDead || goSeen || ctlOn) { return; }
    var ctl = ctlE('ctl');
    if (!ctl) { return; }
    ctlOn = true;
    try { ctl.style.display = 'block'; } catch (x) {}
    ctlWire();
    ctlSeedRange();
    ctlConfirmPaint();
    ctlUpdPaint();
    try { ctlDurV = player ? (player.getDuration() || 0) : 0; } catch (x) {}
    ctlSeedOut();
    ctlPaint();
    layoutCtl();
    if (!ctlSeeded && ctlIn > 0 && ctlDurV > 0) {
      ctlSeeded = true;
      ctlPos = ctlIn;
      ctlSeekTo(ctlIn);
    }
    if (!(ctlDurV > 0)) {
      try { ctlKickAt = Date.now(); } catch (x) { ctlKickAt = 0; }
    }
    report('ctl_on', '&t=' + T0.toFixed(3) + '&mark=' + ctlIn.toFixed(3));
    if (ctlRaf === null) { ctlRaf = requestAnimationFrame(ctlTick); }
  }

  function hideCtl(why){
    ctlDead = true;
    var was = ctlOn;
    ctlOn = false;
    ctlKickAt = 0;
    ctlPrevStop();
    if (ctlKickOn) { ctlKickOn = false; ctlMkMute(false); }
    if (ctlRaf !== null) {
      try { cancelAnimationFrame(ctlRaf); } catch (x) {}
      ctlRaf = null;
    }
    try {
      var ctl = ctlE('ctl');
      if (ctl) { ctl.style.display = 'none'; }
    } catch (x) {}
    try {
      if (win) { win.style.transform = ''; win.style.transformOrigin = ''; }
    } catch (x) {}
    if (was) { report('ctl_off', '&why=' + why); }
  }

  function assertCtlDown(where){
    if (!ctlOn) { return; }
    report('ctl_leak', '&at=' + where);
    hideCtl('leak');
  }

  function finishPrep(via){
    if (unmasked || reportedEnd) return;
    unmasked = true;
    assertCtlDown('finishPrep');
    stopRunupWatch();
    clearPrep();
    applyOverscan();
    layoutLocked = true;
    unmuteForRecording(via);
    hideMask();
    var at = 0;
    try { at = player.getCurrentTime() || 0; } catch (x) {}
    var vx = '&at=' + at.toFixed(3) + '&via=' + via;
    if (recAsked) {
      var hm = -1;
      try { hm = Math.round(performance.now() - recAskedW); } catch (x) {}
      vx += '&head=' + hm;
    }
    report('visible', vx);
    beginOutWatch();
  }

  function runupTick(now){
    runupTimer = null;
    if (unmasked || reportedEnd) { return; }
    if (!player) { runupTimer = requestAnimationFrame(runupTick); return; }
    if (!isRealVideo()) {
      setPrep('Waiting for ad to finish', '');
      if (!adReported) { adReported = true; report('ad_playing'); }
      runupTimer = requestAnimationFrame(runupTick);
      return;
    }
    sampleAt(now);
    var est = estAt(now);
    if (est < 0) { runupTimer = requestAnimationFrame(runupTick); return; }
    var next = est + leadSec();

    if (!recAsked && GATE > 0 && next >= (GATE - REC_HEAD_SEC)) {
      recAsked = true;
      recAskedW = now;
      clearPrep();
      assertCtlDown('recstart');
      report('recstart', '&at=' + est.toFixed(3)
                         + '&head=' + REC_HEAD_SEC.toFixed(3));
    }

    if (next >= GATE) {
      finishPrep('runup');
      return;
    }

    if (recAsked && (now - recAskedW) >= UNMASK_DEADLINE_MS) {
      finishPrep('deadline');
      return;
    }

    setPrep('Preparing to record', String(Math.ceil(GATE - est)));
    runupTimer = requestAnimationFrame(runupTick);
  }

  function beginRunup(){
    if (unmasked || reportedEnd || runupTimer !== null) return;
    setPrep('Preparing to record', String(Math.ceil(GATE - START)));
    runupTimer = requestAnimationFrame(runupTick);
  }

  function killCaptions(){
    if (!player) return;
    try { player.unloadModule('captions'); } catch (x) {}
    try { player.unloadModule('cc'); } catch (x) {}
    try { player.setOption('captions', 'track', {}); } catch (x) {}
    try { player.setOption('cc', 'track', {}); } catch (x) {}
  }

  function isRealVideo(){
    try {
      var vd = player.getVideoData();
      if (vd && vd.video_id) return vd.video_id === VID;
    } catch (x) {}
    return true;
  }

  function markEnded(why){
    if (!goSeen) return;
    if (reportedEnd) return;
    reportedEnd = true;
    endMasked = true;
    showMask();
    try { player.mute(); player.pauseVideo(); } catch (x) {}
    var endAt = 0;
    try { endAt = player.getCurrentTime() || 0; } catch (x) {}
    report('ended', '&why=' + encodeURIComponent(why) + '&at=' + endAt.toFixed(3));
  }

  function tryStartPlayback(){
    if (sawPlaying || !player) return;
    if (!goSeen) return;
    var s;
    try { s = player.getPlayerState(); } catch (x) { return; }
    if (s !== YT.PlayerState.PLAYING) return;

    if (!isRealVideo()) {
      if (!adReported) { adReported = true; report('ad_playing'); }
      return;
    }

    sawPlaying = true;
    var dur = 0;
    try { dur = player.getDuration() || 0; } catch (x) {}
    applyOverscan();
    report('playing', '&dur=' + dur + '&over=' + OVER
                      + '&pad=' + curPad + '&iw=' + curIW + '&ih=' + curIH);
    var kc = setInterval(killCaptions, 400);
    setTimeout(function(){ clearInterval(kc); }, 8000);
    killCaptions();
    beginRunup();
  }

  function stopGoPoll(){
    if (goTimer) { try { clearInterval(goTimer); } catch (x) {} goTimer = null; }
  }

  function armSafety(){
    if (safetyArmed) return;
    safetyArmed = true;
    setTimeout(function(){
      if (reportedEnd || !player) return;
      unmuteForRecording('safety');
      finishPrep('safety');
    }, TAKE_SAFETY_MS);
  }

  function maybeStartPlayback(){
    if (!goSeen || !playerReady || playbackAsked || reportedEnd) return;
    if (!player) return;
    playbackAsked = true;
    try { player.playVideo(); } catch (x) {}
    setTimeout(function(){
      if (sawPlaying || !player || autoplayRetried) return;
      var s;
      try { s = player.getPlayerState(); } catch (x) { return; }
      if (s === YT.PlayerState.PLAYING || s === YT.PlayerState.BUFFERING) return;
      autoplayRetried = true;
      report('autoplay_retry_muted');
      try { player.mute(); player.playVideo(); } catch (x) {}
    }, 4000);
  }

  function onGo(){
    if (goSeen) return;
    goSeen = true;
    hideCtl('gate');
    report('go');
    showMask();
    armSafety();
    maybeStartPlayback();
  }

  function goStop(){
    if (!goSeen || reportedEnd) return;
    markEnded('offprog');
    stopGoPoll();
  }

  function goTick(){
    if (reportedEnd) { stopGoPoll(); return; }
    if (goBusy) { return; }
    goBusy = true;
    var done = false;
    function settle(txt){
      if (done) { return; }
      done = true;
      goBusy = false;
      var yes = !!(txt && String(txt).indexOf('go=1') >= 0);
      var no  = !!(txt && String(txt).indexOf('go=0') >= 0);
      var ctl = !!(txt && String(txt).indexOf('ctl=1') >= 0);
      if (!goSeen) {
        if (yes) { onGo(); return; }
        if (ctl) { showCtl(); }
        return;
      }
      if (yes || !no) { goZeroN = 0; goZeroSince = 0; return; }
      if (goZeroN < 1) { goZeroSince = Date.now(); }
      goZeroN++;
      if (goZeroN >= GO_STOP_N && (Date.now() - goZeroSince) >= GO_STOP_MS) {
        goStop();
      }
    }
    var f = null;
    try {
      f = fetch('/__go?nonce=' + encodeURIComponent(NONCE), { cache:'no-store' });
    } catch (e) { f = null; }
    if (!(f && typeof f.then === 'function')) { settle(null); return; }
    try {
      f.then(function(r){
        var s = 0;
        try { s = (r && r.status) ? r.status : 0; } catch (x) { s = 0; }
        if (s !== 200) {
          if (s >= 400 && !goErrReported) {
            goErrReported = true;
            report('go_unavailable', '&st=' + s);
          }
          settle(null);
          return;
        }
        var p = null;
        try { p = r.text(); } catch (x) { p = null; }
        if (p && typeof p.then === 'function') {
          p.then(function(t){ settle(t); }, function(){ settle(null); });
        } else {
          settle(null);
        }
      }, function(){ settle(null); });
    } catch (e2) { settle(null); }
  }

  window.onYouTubeIframeAPIReady = function(){
    var pv = {
      autoplay: 0, controls: 0, disablekb: 1, fs: 0, rel: 0, mute: 1,
      modestbranding: 1, playsinline: 1, iv_load_policy: 3,
      // playerVars.start is an integer; a fractional value is truncated
      cc_load_policy: 0, start: Math.floor(START)
    };
    if (LOOP) { pv.loop = 1; pv.playlist = VID; }

    player = new YT.Player('player', {
      videoId: VID,
      playerVars: pv,
      events: {
        onReady: function(e){
          applyOverscan();
          killCaptions();
          var dur = 0;
          try { dur = e.target.getDuration() || 0; } catch (x) {}
          report('ready', '&dur=' + dur);
          crPaint();
          playerReady = true;
          maybeStartPlayback();
        },
        onStateChange: function(e){
          applyOverscan();
          crPaint();
          if (e.data === YT.PlayerState.PLAYING) {
            tryStartPlayback();
          } else if (e.data === YT.PlayerState.ENDED) {
            markEnded('state');
          }
        },
        // YouTube rejects a null origin (file://, data:) with error 153
        onError: function(e){
          report('error', '&code=' + e.data);
        }
      }
    });
  };

  setInterval(function(){
    if (!player) return;

    if (!sawPlaying) {
      tryStartPlayback();
      if (!sawPlaying && !adReported && !isRealVideo()) {
        adReported = true;
        report('ad_playing');
      }
      return;
    }
    if (reportedEnd) return;
    if (!unmasked) return;

    try {
      var d = player.getDuration() || 0;
      var t = player.getCurrentTime() || 0;
      if (d <= 0) return;

      if (LOOP) {
        if (t >= d - 0.25) { markEnded('tailpos'); return; }
        if (lastT >= d - 2.0 && t < 1.0 && lastT > 1.0) {
          markEnded('loopwrap'); return;
        }
      } else {
        if (t >= d - 0.3) {
          var s = player.getPlayerState();
          if (s !== YT.PlayerState.PLAYING && s !== YT.PlayerState.BUFFERING) {
            markEnded('tailcheck'); return;
          }
        }
      }
      lastT = t;
    } catch (x) {}
  }, 200);

  if (!VID) { report('bad_param', '&which=v'); }
  applyOverscan();
  report('loaded', '&over=' + OVER + '&pad=' + curPad
                   + '&vw=' + VW + '&vh=' + VH);

  hideMask();
  crInit();
  goTick();
  goTimer = setInterval(goTick, GO_POLL_MS);

  if (VID) {
    try {
      fetch('/__probe?v=' + encodeURIComponent(VID), { cache:'no-store', keepalive:true });
    } catch (e) {}
  }
})();
</script>
<script src="https://www.youtube.com/iframe_api"></script>
</body></html>
]==]

local SERVER_PL = [==[
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use Getopt::Long qw(GetOptions);
use Time::HiRes qw(time);
use POSIX qw(strftime);
use File::Spec;
use File::Basename qw(basename);
use Cwd qw(abs_path);

my $PreferredPort = 0;
my ($PortFile, $Events, $Stop, $Log, $Beat) = ('', '', '', '', '');
my ($ProbeReq, $Go, $Ctl, $Owner, $OwnerId) = ('', '', '', '', '');
my $Root = '.';
my $OwnerGoneSec = 20;
my $MaxHours = 12;
my $ProbeOnly = 0;
my $Vid = '';
my $UpdateReq = '';
my $UpdateOnly = 0;

GetOptions(
  'PreferredPort=i' => \$PreferredPort,
  'PortFile=s'      => \$PortFile,
  'Root=s'          => \$Root,
  'Events=s'        => \$Events,
  'Stop=s'          => \$Stop,
  'Log=s'           => \$Log,
  'Beat=s'          => \$Beat,
  'ProbeReq=s'      => \$ProbeReq,
  'Go=s'            => \$Go,
  'Ctl=s'           => \$Ctl,
  'Owner=s'         => \$Owner,
  'OwnerId=s'       => \$OwnerId,
  'OwnerGoneSec=i'  => \$OwnerGoneSec,
  'MaxHours=i'      => \$MaxHours,
  'ProbeOnly'       => \$ProbeOnly,
  'Vid=s'           => \$Vid,
  'UpdateReq=s'     => \$UpdateReq,
  'UpdateOnly'      => \$UpdateOnly,
) or die "bad arguments\n";

$Root = abs_path($Root) || $Root;
sub under { return File::Spec->catfile($Root, $_[0]); }
$Events   = under('yt_events.txt')  unless $Events;
$Stop     = under('yt_stop.flag')   unless $Stop;
$Log      = under('yt_server.log')  unless $Log;
$PortFile = under('yt_port.txt')    unless $PortFile;
$Beat     = under('yt_beat.txt')    unless $Beat;
$ProbeReq = under('yt_probe_req.txt') unless $ProbeReq;
$UpdateReq = under('yt_update_req.txt') unless $UpdateReq;
$Go       = under('yt_go.flag')     unless $Go;
$Ctl      = under('yt_ctl.flag')    unless $Ctl;
$Owner    = under('yt_owner.txt')   unless $Owner;

my $SelfPath = abs_path($0) || $0;

sub say_log {
  my ($m) = @_;
  my $line = strftime('%H:%M:%S', localtime) . " $m";
  if (open(my $fh, '>>', $Log)) { print $fh "$line\n"; close $fh; }
}

sub slurp {
  my ($path) = @_;
  open(my $fh, '<', $path) or return undef;
  local $/;
  my $data = <$fh>;
  close $fh;
  return defined($data) ? $data : '';
}

sub spit {
  my ($path, $data) = @_;
  open(my $fh, '>', $path) or return 0;
  print $fh $data;
  close $fh;
  return 1;
}

sub trim { my $s = defined($_[0]) ? $_[0] : ''; $s =~ s/^\s+//; $s =~ s/\s+$//; return $s; }

my $lastBeat = 0;
sub beat {
  my ($force) = @_;
  my $now = time();
  return if !$force && ($now - $lastBeat) < 2;
  $lastBeat = $now;
  spit($Beat, sprintf('%.0f', $now * 10000000));
}

sub eventsHighWater {
  my $txt = slurp($Events);
  return 0 unless defined $txt;
  my $hi = 0;
  while ($txt =~ /seq=(\d+)/g) { $hi = $1 if $1 > $hi; }
  return $hi;
}

my $seq = 0;
sub nextSeq {
  my $hi = eventsHighWater();
  if ($hi > $seq) {
    $seq = $hi;
    say_log("seq bumped to $hi - another writer is ahead");
  }
  $seq++;
  return $seq;
}

sub appendEvent {
  my ($payload) = @_;
  for my $try (1 .. 4) {
    my $n = nextSeq();
    my $t = strftime('%H:%M:%S', localtime) . sprintf('.%03d', (time() - int(time())) * 1000);
    if (open(my $fh, '>>', $Events)) {
      print $fh "seq=$n t=$t $payload\n";
      close $fh;
      return 1;
    }
    select(undef, undef, undef, 0.04);
  }
  say_log("append failed after 4 tries: $payload");
  return 0;
}

sub goodVid { return defined($_[0]) && $_[0] =~ /^[A-Za-z0-9_\-]{6,24}$/; }

sub spawnProbe {
  my ($vid) = @_;
  unless (goodVid($vid)) {
    say_log('probe skipped (no usable video id)');
    return;
  }
  my $pid = fork();
  if (!defined $pid) {
    say_log("probe worker could not be spawned for $vid");
    appendEvent("type=probe&err=1&pv=$vid");
    return;
  }
  if ($pid == 0) {
    exec($^X, $SelfPath, '-ProbeOnly', '-Vid', $vid, '-Root', $Root,
         '-Events', $Events, '-Log', $Log);
    exit 127;
  }
  say_log("probe worker spawned for $vid");
}

sub checkProbeRequest {
  return unless $ProbeReq;
  return unless -e $ProbeReq;
  my $vid = trim(slurp($ProbeReq));
  unlink($ProbeReq);
  if (goodVid($vid)) {
    say_log("probe requested by file: $vid");
    spawnProbe($vid);
  } else {
    say_log('probe request file ignored (no usable video id)');
  }
}

sub spawnUpdate {
  my $pid = fork();
  if (!defined $pid) {
    say_log('update worker could not be spawned');
    appendEvent('type=update&err=1');
    return;
  }
  if ($pid == 0) {
    exec($^X, $SelfPath, '-UpdateOnly', '-Root', $Root,
         '-Events', $Events, '-Log', $Log);
    exit 127;
  }
  say_log('update worker spawned');
}

sub checkUpdateRequest {
  return unless $UpdateReq;
  return unless -e $UpdateReq;
  unlink($UpdateReq);
  say_log('update check requested by file');
  spawnUpdate();
}

sub goAnswer {
  my ($want) = @_;
  return 'go=0' unless $Go;
  my $w = trim($want);
  return 'go=0' if $w eq '' || $w eq '0';
  return 'go=0' unless -e $Go;
  my $have = trim(slurp($Go));
  return 'go=0' if $have eq '' || $have eq '0';
  return 'go=1' if $have eq $w;
  return 'go=0';
}

sub ctlAnswer {
  my ($want) = @_;
  return '' unless $Ctl;
  my $w = trim($want);
  return '' if $w eq '' || $w eq '0';
  return '' unless -e $Ctl;
  my $have = trim(slurp($Ctl));
  return '' if $have eq '' || $have eq '0';
  return '' if $have ne $w;
  unlink($Ctl) or return '';
  say_log('control layer armed once and the flag spent');
  return '&ctl=1';
}

my $ownerVal = '';
my $ownerAt = time();
my $ownerGone = 0;
sub ownerLost {
  return '' unless $OwnerId;
  my $now = time();
  my $txt = '';
  if (-e $Owner) {
    my $raw = slurp($Owner);
    return '' unless defined $raw;
    $txt = trim($raw);
  }
  if ($txt ne '') {
    my $id = $txt;
    $id =~ s/[\r\n].*$//s;
    $id = trim($id);
    if ($id ne $OwnerId) {
      return 'another OBS now owns the work folder, so this older server is standing down instead of appending to a shared event file beside it';
    }
  }
  if ($txt ne $ownerVal) {
    $ownerVal = $txt;
    $ownerAt = $now;
    return '';
  }
  if (($now - $ownerAt) >= $OwnerGoneSec) {
    return "the OBS that started this server stopped writing its owner file $OwnerGoneSec seconds ago, so that OBS is gone and this server is ending itself";
  }
  return '';
}

sub fetch_url {
  my ($url) = @_;
  my $pid = open(my $fh, '-|', 'curl', '-sS', '--max-time', '4', '--', $url);
  return '' unless $pid;
  local $/;
  my $body = <$fh>;
  close $fh;
  return defined($body) ? $body : '';
}

sub fetch_release {
  my $pid = open(my $fh, '-|', 'curl', '-sS', '--max-time', '8',
                 '-A', 'simple-browser-recorder-update-check', '--',
                 'https://api.github.com/repos/castika-code/simple-browser-recorder/releases/latest');
  return '' unless $pid;
  local $/;
  my $body = <$fh>;
  close $fh;
  return defined($body) ? $body : '';
}

if ($ProbeOnly) {
  $seq = 0;
  my $tag = goodVid($Vid) ? "&pv=$Vid" : '';
  my ($pw, $ph) = (0, 0);
  if (goodVid($Vid)) {
    my $body = fetch_url("https://www.youtube.com/watch?v=$Vid");
    while ($body =~ /"width":(\d+),"height":(\d+)/g) {
      my ($w2, $h2) = ($1, $2);
      if (($w2 * $h2) > ($pw * $ph)) { ($pw, $ph) = ($w2, $h2); }
    }
  }
  my $ah = '';
  if (goodVid($Vid)) {
    my $inner = "https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3D$Vid";
    my $body = fetch_url("https://www.youtube.com/oembed?url=$inner&format=json");
    if ($body =~ m{"author_url"\s*:\s*"[^"]*?youtube\.com\\?/\@([A-Za-z0-9_.\-]{1,40})}) {
      $ah = '@' . $1;
    }
  }
  my $ahq = ($ah ne '') ? "&ah=$ah" : '';
  if ($ah ne '') { say_log("probe worker: channel handle $ah"); }
  else { say_log('probe worker: no channel handle (best-effort, the name is used)'); }
  if ($pw > 0 && $ph > 0) {
    appendEvent("type=probe&w=$pw&h=$ph$tag$ahq");
    say_log("probe worker: native size $pw x $ph");
  } else {
    appendEvent("type=probe&err=1$tag$ahq");
    say_log('probe worker: native size not found (best-effort, ignored)');
  }
  exit 0;
}

if ($UpdateOnly) {
  $seq = 0;
  my $tag = '';
  my $body = fetch_release();
  if ($body !~ /"(?:draft|prerelease)"\s*:\s*true/
      && $body =~ /"tag_name"\s*:\s*"([A-Za-z0-9._\-]{1,32})"/) {
    $tag = $1;
  }
  if ($tag ne '') {
    appendEvent("type=update&tag=$tag");
    say_log("update worker: latest release $tag");
  } else {
    appendEvent('type=update&err=1');
    say_log('update worker: no usable answer (best-effort, ignored)');
  }
  exit 0;
}

unlink($Stop)     if -e $Stop;
unlink($PortFile) if -e $PortFile;
unlink($Beat)     if -e $Beat;

my @cands;
push @cands, $PreferredPort if $PreferredPort > 0;
push @cands, 20000 + int(rand(28000)) for (1 .. 30);

my @socks;
my $Port = 0;
for my $c (@cands) {
  my $s4 = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => $c,
                                 Listen => 16, Proto => 'tcp', ReuseAddr => 1);
  next unless $s4;
  @socks = ($s4);
  $Port = $c;
  my $s6 = eval {
    require IO::Socket::IP;
    IO::Socket::IP->new(LocalHost => '::1', LocalPort => $c, Listen => 16,
                        Proto => 'tcp', ReuseAddr => 1, V6Only => 1);
  };
  push @socks, $s6 if $s6;
  last;
}

if (!@socks) { say_log('BIND FAILED (no free port)'); exit 1; }
say_log('listening on both 127.0.0.1 and ::1') if @socks > 1;

my $portWritten = 0;
for my $pt (1 .. 4) {
  if (spit($PortFile, "$Port")) { $portWritten = 1; last; }
  say_log("port file write failed (try $pt of 4): $!");
  select(undef, undef, undef, 0.1);
}
if (!$portWritten) {
  say_log("PORT FILE NOT WRITTEN after 4 tries: $PortFile");
  say_log("Lua cannot learn port $Port, so no page URL can be built. This listener stays up; Lua's heartbeat watchdog is the only remaining exit.");
}
beat(1);
say_log("listening on http://localhost:$Port/  root=$Root");

my %types = (
  '.html' => 'text/html; charset=utf-8',
  '.js'   => 'application/javascript; charset=utf-8',
  '.css'  => 'text/css; charset=utf-8',
  '.json' => 'application/json; charset=utf-8',
);

$seq = eventsHighWater();
say_log("event sequence seeded at $seq");

my $deadline = time() + ($MaxHours * 3600);
my $sel = IO::Select->new(@socks);
$SIG{CHLD} = 'IGNORE';
$SIG{PIPE} = 'IGNORE';

sub unescape {
  my ($s) = @_;
  $s =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
  return $s;
}

sub qparam {
  my ($query, $name) = @_;
  for my $kv (split(/&/, $query)) {
    my $eq = index($kv, '=');
    next unless $eq > 0;
    next unless substr($kv, 0, $eq) eq $name;
    return unescape(substr($kv, $eq + 1));
  }
  return '';
}

sub respond {
  my ($cl, $code, $ctype, $body) = @_;
  my %msg = (200 => 'OK', 204 => 'No Content', 404 => 'Not Found');
  my $head = "HTTP/1.1 $code " . ($msg{$code} || 'OK') . "\r\n"
           . "Cache-Control: no-store\r\n"
           . "Connection: close\r\n";
  if ($code == 204) {
    $head .= "\r\n";
    $body = '';
  } else {
    $head .= "Content-Type: $ctype\r\n"
           . 'Content-Length: ' . length($body) . "\r\n\r\n";
  }
  print $cl $head . $body;
}

my $houseKeep = sub {
  beat(0);
  checkProbeRequest();
  return 'stop' if -e $Stop;
  checkUpdateRequest();
  my $lost = ownerLost();
  if ($lost ne '') { say_log("exiting: $lost"); $ownerGone = 1; return 'owner'; }
  if (time() > $deadline) { say_log('max lifetime reached'); return 'deadline'; }
  return '';
};

my $quit = 0;
while (!$quit) {
  last if $houseKeep->() ne '';
  my @ready = $sel->can_read(0.4);
  if (!@ready) {
    last if $houseKeep->() ne '';
    next;
  }
  for my $lsn (@ready) {
    my $cl = $lsn->accept() or next;
    $cl->autoflush(1);
    my $line = <$cl>;
    if (!defined $line) { close $cl; next; }
    while (my $h = <$cl>) { last if $h =~ /^\r?\n$/; }
    my ($target) = $line =~ m{^\S+\s+(\S+)};
    $target = '/' unless defined $target;
    my ($path, $query) = split(/\?/, $target, 2);
    $path = unescape(defined($path) ? $path : '/');
    $query = '' unless defined $query;

    if ($path eq '/__event') {
      appendEvent($query);
      respond($cl, 204);
    }
    elsif ($path eq '/__go') {
      my $want = qparam($query, 'nonce');
      my $ans = goAnswer($want) . ctlAnswer($want);
      respond($cl, 200, 'text/plain; charset=utf-8', $ans);
    }
    elsif ($path eq '/__probe') {
      respond($cl, 204);
      close $cl;
      spawnProbe(qparam($query, 'v'));
      next;
    }
    elsif ($path eq '/__quit') {
      say_log('quit requested');
      respond($cl, 200, 'text/plain; charset=utf-8', '');
      close $cl;
      $quit = 1;
      last;
    }
    else {
      my $rel = $path;
      $rel =~ s{^/+}{};
      $rel = 'yt_player.html' if $rel eq '';
      my $full = File::Spec->catfile($Root, $rel);
      my $okf = 0;
      if (-f $full) {
        my $resolved = abs_path($full) || '';
        $okf = 1 if index($resolved, $Root) == 0;
      }
      if ($okf) {
        my $bytes = '';
        if (open(my $fh, '<', $full)) { binmode $fh; local $/; $bytes = <$fh>; close $fh; }
        $bytes = '' unless defined $bytes;
        my $ext = ($full =~ /(\.[A-Za-z0-9]+)$/) ? lc($1) : '';
        respond($cl, 200, $types{$ext} || 'application/octet-stream', $bytes);
      } else {
        respond($cl, 404, 'text/plain; charset=utf-8', 'not found');
      }
    }
    close $cl;
  }
}

close($_) for @socks;

if (-e $Stop) {
  say_log("removing work folder in a few seconds: $Root");
  my $pid = fork();
  if (defined $pid && $pid == 0) {
    sleep 2;
    if (-e $Stop && basename($Root) eq 'obs-yt-embed-recorder') {
      system('rm', '-rf', '--', $Root);
    }
    exit 0;
  }
} elsif ($ownerGone) {
  say_log('work folder kept: this server ended itself, so it deletes nothing that the next OBS will want');
  unlink($Beat) if -e $Beat;
} else {
  say_log('work folder kept: a newer server owns it');
  unlink($Beat) if -e $Beat;
}
say_log('stopped');
]==]

local SERVER_PS1 = [==[
param(
  [int]$PreferredPort = 0,
  [string]$PortFile = '',
  [string]$Root = '.',
  [string]$Events = '',
  [string]$Stop = '',
  [string]$Log = '',
  [string]$Beat = '',
  [string]$ProbeReq = '',
  [string]$Go = '',
  [string]$Ctl = '',
  [string]$Owner = '',
  [string]$OwnerId = '',
  [int]$OwnerGoneSec = 20,
  [int]$MaxHours = 12,
  [switch]$ProbeOnly,
  [string]$Vid = '',
  [string]$UpdateReq = '',
  [switch]$UpdateOnly
)

$Root = (Resolve-Path -LiteralPath $Root).Path
if (-not $Events)   { $Events   = Join-Path $Root 'yt_events.txt' }
if (-not $Stop)     { $Stop     = Join-Path $Root 'yt_stop.flag' }
if (-not $Log)      { $Log      = Join-Path $Root 'yt_server.log' }
if (-not $PortFile) { $PortFile = Join-Path $Root 'yt_port.txt' }
if (-not $Beat)     { $Beat     = Join-Path $Root 'yt_beat.txt' }
if (-not $ProbeReq) { $ProbeReq = Join-Path $Root 'yt_probe_req.txt' }
if (-not $UpdateReq) { $UpdateReq = Join-Path $Root 'yt_update_req.txt' }
if (-not $Go)       { $Go       = Join-Path $Root 'yt_go.flag' }
if (-not $Ctl)      { $Ctl      = Join-Path $Root 'yt_ctl.flag' }
if (-not $Owner)    { $Owner    = Join-Path $Root 'yt_owner.txt' }

$script:SelfPath = $PSCommandPath
if (-not $script:SelfPath) { $script:SelfPath = $MyInvocation.MyCommand.Definition }

function say($m) {
  $line = "$((Get-Date).ToString('HH:mm:ss')) $m"
  try { Add-Content -LiteralPath $Log -Value $line -Encoding utf8 } catch {}
}

$script:lastBeat = [DateTime]::MinValue
function beat($force) {
  if (-not $force -and ((Get-Date) - $script:lastBeat).TotalSeconds -lt 2) { return }
  $script:lastBeat = Get-Date
  try {
    Set-Content -LiteralPath $Beat -Value ([DateTime]::UtcNow.Ticks) -Encoding ascii
  } catch {}
}

function eventsHighWater() {
  $hi = 0
  try {
    if ($Events -and (Test-Path -LiteralPath $Events)) {
      $txt = [System.IO.File]::ReadAllText($Events)
      foreach ($m in [regex]::Matches($txt, 'seq=(\d+)')) {
        $v = 0
        if ([int]::TryParse($m.Groups[1].Value, [ref]$v)) {
          if ($v -gt $hi) { $hi = $v }
        }
      }
    }
  } catch { return 0 }
  return $hi
}

function nextSeq() {
  $hi = eventsHighWater
  if ($hi -gt $script:seq) {
    $script:seq = $hi
    say "seq bumped to $hi - another writer is ahead"
  }
  $script:seq++
  return $script:seq
}

function appendEvent($payload) {
  for ($try = 0; $try -lt 4; $try++) {
    $n = nextSeq
    $line = "seq=$n t=$((Get-Date).ToString('HH:mm:ss.fff')) $payload"
    try {
      # Add-Content opens the file for writing, so a concurrent writer throws
      Add-Content -LiteralPath $Events -Value $line -Encoding utf8
      return $true
    } catch {
      Start-Sleep -Milliseconds 40
    }
  }
  say "append failed after 4 tries: $payload"
  return $false
}

function spawnProbe($vid) {
  if ($vid -notmatch '^[A-Za-z0-9_\-]{6,24}$') {
    say 'probe skipped (no usable video id)'
    return
  }
  $launched = $false
  try {
    $pargs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
             $script:SelfPath + '" -ProbeOnly -Vid ' + $vid +
             ' -Root "' + $Root + '" -Events "' + $Events +
             '" -Log "' + $Log + '"'
    Start-Process -WindowStyle Hidden -FilePath 'powershell.exe' `
      -ArgumentList $pargs -ErrorAction Stop
    $launched = $true
    say "probe worker spawned for $vid"
  } catch {
    $launched = $false
  }
  if (-not $launched) {
    say "probe worker could not be spawned for $vid"
    [void](appendEvent "type=probe&err=1&pv=$vid")
  }
}

function checkProbeRequest() {
  if (-not $ProbeReq) { return }
  $vid = ''
  try {
    if (-not (Test-Path -LiteralPath $ProbeReq)) { return }
    $vid = ([string][System.IO.File]::ReadAllText($ProbeReq)).Trim()
    Remove-Item -LiteralPath $ProbeReq -Force
  } catch {
    try { Remove-Item -LiteralPath $ProbeReq -Force } catch {}
    return
  }
  if ($vid -match '^[A-Za-z0-9_\-]{6,24}$') {
    say "probe requested by file: $vid"
    spawnProbe $vid
  } else {
    say 'probe request file ignored (no usable video id)'
  }
}

function spawnUpdate() {
  $launched = $false
  try {
    $uargs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
             $script:SelfPath + '" -UpdateOnly -Root "' + $Root +
             '" -Events "' + $Events + '" -Log "' + $Log + '"'
    Start-Process -WindowStyle Hidden -FilePath 'powershell.exe' `
      -ArgumentList $uargs -ErrorAction Stop
    $launched = $true
    say 'update worker spawned'
  } catch {
    $launched = $false
  }
  if (-not $launched) {
    say 'update worker could not be spawned'
    [void](appendEvent 'type=update&err=1')
  }
}

function checkUpdateRequest() {
  if (-not $UpdateReq) { return }
  try {
    if (-not (Test-Path -LiteralPath $UpdateReq)) { return }
    Remove-Item -LiteralPath $UpdateReq -Force
  } catch {
    try { Remove-Item -LiteralPath $UpdateReq -Force } catch {}
    return
  }
  say 'update check requested by file'
  spawnUpdate
}

function goAnswer($want) {
  try {
    if (-not $Go) { return 'go=0' }
    if (-not $want) { return 'go=0' }
    $w = ([string]$want).Trim()
    if ($w -eq '' -or $w -eq '0') { return 'go=0' }
    if (-not (Test-Path -LiteralPath $Go)) { return 'go=0' }
    $have = ([string][System.IO.File]::ReadAllText($Go)).Trim()
    if ($have -eq '' -or $have -eq '0') { return 'go=0' }
    if ($have -eq $w) { return 'go=1' }
    return 'go=0'
  } catch {
    return 'go=0'
  }
}

function ctlAnswer($want) {
  try {
    if (-not $Ctl) { return '' }
    if (-not $want) { return '' }
    $w = ([string]$want).Trim()
    if ($w -eq '' -or $w -eq '0') { return '' }
    if (-not (Test-Path -LiteralPath $Ctl)) { return '' }
    $have = ([string][System.IO.File]::ReadAllText($Ctl)).Trim()
    if ($have -eq '' -or $have -eq '0') { return '' }
    if ($have -ne $w) { return '' }
    try { Remove-Item -LiteralPath $Ctl -Force } catch { return '' }
    say 'control layer armed once and the flag spent'
    return '&ctl=1'
  } catch {
    return ''
  }
}

$script:ownerVal = ''
$script:ownerAt = Get-Date
$script:ownerGone = $false
function ownerLost() {
  if (-not $OwnerId) { return '' }
  $now = Get-Date
  $txt = ''
  try {
    if (Test-Path -LiteralPath $Owner) {
      $txt = ([string][System.IO.File]::ReadAllText($Owner)).Trim()
    }
  } catch {
    return ''
  }
  if ($txt -ne '') {
    $id = ([string][regex]::Match($txt, '^[^\r\n]*').Value).Trim()
    if ($id -ne $OwnerId) {
      return 'another OBS now owns the work folder, so this older server is standing down instead of appending to a shared event file beside it'
    }
  }
  if ($txt -ne $script:ownerVal) {
    $script:ownerVal = $txt
    $script:ownerAt = $now
    return ''
  }
  if (($now - $script:ownerAt).TotalSeconds -ge $OwnerGoneSec) {
    return "the OBS that started this server stopped writing its owner file $OwnerGoneSec seconds ago, so that OBS is gone and this server is ending itself"
  }
  return ''
}

if ($ProbeOnly) {
  $ProgressPreference = 'SilentlyContinue'
  $script:seq = 0
  $tag = ''
  if ($Vid -match '^[A-Za-z0-9_\-]{6,24}$') { $tag = "&pv=$Vid" }
  $pw = 0
  $ph = 0
  try {
    if ($Vid -match '^[A-Za-z0-9_\-]{6,24}$') {
      # -TimeoutSec bounds only the wait for response headers
      $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 4 `
             -Uri "https://www.youtube.com/watch?v=$Vid"
      foreach ($m in [regex]::Matches([string]$r.Content, '"width":(\d+),"height":(\d+)')) {
        $w2 = 0
        $h2 = 0
        if ([int]::TryParse($m.Groups[1].Value, [ref]$w2) -and
            [int]::TryParse($m.Groups[2].Value, [ref]$h2)) {
          if (($w2 * $h2) -gt ($pw * $ph)) { $pw = $w2; $ph = $h2 }
        }
      }
    }
  } catch {
    $pw = 0
    $ph = 0
  }
  $ah = ''
  try {
    if ($Vid -match '^[A-Za-z0-9_\-]{6,24}$') {
      $inner = [System.Uri]::EscapeDataString("https://www.youtube.com/watch?v=$Vid")
      $o = Invoke-WebRequest -UseBasicParsing -TimeoutSec 4 `
             -Uri "https://www.youtube.com/oembed?url=$inner&format=json"
      $m2 = [regex]::Match([string]$o.Content,
              '"author_url"\s*:\s*"[^"]*?youtube\.com\\?/@([A-Za-z0-9_.\-]{1,40})')
      if ($m2.Success) { $ah = '@' + $m2.Groups[1].Value }
    }
  } catch {
    $ah = ''
  }
  $ahq = ''
  if ($ah -ne '') { $ahq = "&ah=$ah" }
  if ($ah -ne '') { say "probe worker: channel handle $ah" }
  else { say 'probe worker: no channel handle (best-effort, the name is used)' }
  try {
    if ($pw -gt 0 -and $ph -gt 0) {
      [void](appendEvent "type=probe&w=$pw&h=$ph$tag$ahq")
      say "probe worker: native size $pw x $ph"
    } else {
      [void](appendEvent "type=probe&err=1$tag$ahq")
      say 'probe worker: native size not found (best-effort, ignored)'
    }
  } catch {
    try { [void](appendEvent "type=probe&err=1$tag$ahq") } catch {}
  }
  exit 0
}

if ($UpdateOnly) {
  $script:seq = 0
  $tag = ''
  try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    Add-Type -AssemblyName System.Net.Http
    $hc = New-Object System.Net.Http.HttpClient
    $hc.Timeout = [TimeSpan]::FromSeconds(8)
    $hc.DefaultRequestHeaders.UserAgent.ParseAdd('simple-browser-recorder-update-check')
    $body = [string]$hc.GetStringAsync('https://api.github.com/repos/castika-code/simple-browser-recorder/releases/latest').GetAwaiter().GetResult()
    if (-not [regex]::IsMatch($body, '"(draft|prerelease)"\s*:\s*true')) {
      $m = [regex]::Match($body, '"tag_name"\s*:\s*"([A-Za-z0-9._-]{1,32})"')
      if ($m.Success) { $tag = $m.Groups[1].Value }
    }
  } catch {
    $tag = ''
  }
  try {
    if ($tag -ne '') {
      [void](appendEvent "type=update&tag=$tag")
      say "update worker: latest release $tag"
    } else {
      [void](appendEvent 'type=update&err=1')
      say 'update worker: no usable answer (best-effort, ignored)'
    }
  } catch {
    try { [void](appendEvent 'type=update&err=1') } catch {}
  }
  exit 0
}

if (Test-Path -LiteralPath $Stop)     { Remove-Item -LiteralPath $Stop -Force }
if (Test-Path -LiteralPath $PortFile) { Remove-Item -LiteralPath $PortFile -Force }
if (Test-Path -LiteralPath $Beat)     { Remove-Item -LiteralPath $Beat -Force }

$candidates = New-Object System.Collections.ArrayList
if ($PreferredPort -gt 0) { [void]$candidates.Add([int]$PreferredPort) }
$rand = New-Object System.Random
for ($i = 0; $i -lt 30; $i++) { [void]$candidates.Add([int]$rand.Next(20000, 48000)) }

$listener = $null
$Port = 0
foreach ($c in $candidates) {
  # HttpListener serves requests on one thread
  $l = New-Object System.Net.HttpListener
  # http://localhost:<port>/ is the only prefix that needs no urlacl
  $l.Prefixes.Add("http://localhost:$c/")
  try {
    $l.Start()
    $listener = $l
    $Port = $c
    break
  } catch {
    try { $l.Close() } catch {}
  }
}

if (-not $listener) { say 'BIND FAILED (no free port)'; exit 1 }

$portWritten = $false
for ($pt = 1; $pt -le 4; $pt++) {
  try {
    Set-Content -LiteralPath $PortFile -Value "$Port" -Encoding ascii -ErrorAction Stop
    $portWritten = $true
    break
  } catch {
    say "port file write failed (try $pt of 4): $($_.Exception.Message)"
    Start-Sleep -Milliseconds 100
  }
}
if (-not $portWritten) {
  say "PORT FILE NOT WRITTEN after 4 tries: $PortFile"
  say "Lua cannot learn port $Port, so no page URL can be built. This listener stays up; Lua's heartbeat watchdog is the only remaining exit."
}
beat $true
say "listening on http://localhost:$Port/  root=$Root"

$types = @{
  '.html' = 'text/html; charset=utf-8'
  '.js'   = 'application/javascript; charset=utf-8'
  '.css'  = 'text/css; charset=utf-8'
  '.json' = 'application/json; charset=utf-8'
}

$seq = 0
$seq = eventsHighWater
say "event sequence seeded at $seq"

$deadline = (Get-Date).AddHours($MaxHours)

function houseKeep() {
  beat $false
  checkProbeRequest
  if (Test-Path -LiteralPath $Stop) { return 'stop' }
  checkUpdateRequest
  $lost = ownerLost
  if ($lost -ne '') { say "exiting: $lost"; $script:ownerGone = $true; return 'owner' }
  if ((Get-Date) -gt $script:deadline) { say 'max lifetime reached'; return 'deadline' }
  return ''
}

while ($true) {
  if ((houseKeep) -ne '') { break }
  $task = $listener.GetContextAsync()
  $got = $false
  while ($true) {
    if ($task.AsyncWaitHandle.WaitOne(400)) { $got = $true; break }
    if ((houseKeep) -ne '') { break }
  }
  if (-not $got) { break }

  $ctx = $task.Result
  $req = $ctx.Request
  $res = $ctx.Response
  $path = [System.Uri]::UnescapeDataString($req.Url.AbsolutePath)
  try { $res.Headers.Add('Cache-Control', 'no-store') } catch {}

  if ($path -eq '/__event') {
    $q = $req.Url.Query
    if ($q.StartsWith('?')) { $q = $q.Substring(1) }
    [void](appendEvent $q)
    $res.StatusCode = 204
  }
  elseif ($path -eq '/__go') {
    $want = ''
    try {
      $q3 = $req.Url.Query
      if ($q3.StartsWith('?')) { $q3 = $q3.Substring(1) }
      foreach ($kv in $q3.Split('&')) {
        $eq = $kv.IndexOf('=')
        if ($eq -gt 0 -and $kv.Substring(0, $eq) -eq 'nonce') {
          $want = [System.Uri]::UnescapeDataString($kv.Substring($eq + 1))
        }
      }
    } catch { $want = '' }
    $ans = (goAnswer $want) + (ctlAnswer $want)
    try {
      $res.StatusCode = 200
      $res.ContentType = 'text/plain; charset=utf-8'
      $gb = [System.Text.Encoding]::ASCII.GetBytes($ans)
      $res.ContentLength64 = $gb.Length
      $res.OutputStream.Write($gb, 0, $gb.Length)
    } catch {}
  }
  elseif ($path -eq '/__probe') {
    $res.StatusCode = 204
    try { $res.Close() } catch {}
    $vid = ''
    try {
      $q2 = $req.Url.Query
      if ($q2.StartsWith('?')) { $q2 = $q2.Substring(1) }
      foreach ($kv in $q2.Split('&')) {
        $eq = $kv.IndexOf('=')
        if ($eq -gt 0 -and $kv.Substring(0, $eq) -eq 'v') {
          $vid = [System.Uri]::UnescapeDataString($kv.Substring($eq + 1))
        }
      }
    } catch { $vid = '' }
    spawnProbe $vid
  }
  elseif ($path -eq '/__quit') {
    say 'quit requested'
    $res.StatusCode = 200
    try { $res.Close() } catch {}
    break
  }
  else {
    $rel = $path.TrimStart('/')
    if ($rel -eq '') { $rel = 'yt_player.html' }
    $full = Join-Path $Root $rel
    $ok = $false
    if (Test-Path -LiteralPath $full -PathType Leaf) {
      $resolved = [System.IO.Path]::GetFullPath($full)
      if ($resolved.StartsWith($Root)) { $ok = $true }
    }
    if ($ok) {
      $bytes = [System.IO.File]::ReadAllBytes($full)
      $ext = [System.IO.Path]::GetExtension($full).ToLower()
      if ($types[$ext]) { $res.ContentType = $types[$ext] }
      else { $res.ContentType = 'application/octet-stream' }
      $res.ContentLength64 = $bytes.Length
      $res.OutputStream.Write($bytes, 0, $bytes.Length)
    } else {
      $res.StatusCode = 404
    }
  }
  try { $res.Close() } catch {}
}

try { $listener.Stop() } catch {}

if (Test-Path -LiteralPath $Stop) {
  say "removing work folder in a few seconds: $Root"
  try {
    $cleanup = '/c ping -n 3 127.0.0.1 > nul & if exist "' + $Stop +
               '" rmdir /s /q "' + $Root + '"'
    Start-Process -WindowStyle Hidden -FilePath 'cmd.exe' -ArgumentList $cleanup
  } catch {}
} elseif ($script:ownerGone) {
  say 'work folder kept: this server ended itself, so it deletes nothing that the next OBS will want'
  if (Test-Path -LiteralPath $Beat) { try { Remove-Item -LiteralPath $Beat -Force } catch {} }
} else {
  say 'work folder kept: a newer server owns it'
  if (Test-Path -LiteralPath $Beat) { try { Remove-Item -LiteralPath $Beat -Force } catch {} }
}
say 'stopped'
]==]

local function ensure_dir(dir)
    local probe = join(dir, "yt_probe.tmp")
    local function can_write()
        local f = io.open(probe, "wb")
        if not f then return false end
        f:close()
        os.remove(probe)
        return true
    end
    if can_write() then return true end
    if type(dir) == "string" and dir ~= "" then obs.os_mkdirs(dir) end
    return can_write()
end

local function write_assets()
    local p = paths()
    ensure_dir(p.dir)
    if read_file(p.html) ~= PLAYER_HTML then
        if not write_file(p.html, PLAYER_HTML) then
            log("Cannot write the player page: %s", p.html)
            return false
        end
    end
    local sp = PLAT.win and p.ps1 or p.pl
    local sv = PLAT.win and SERVER_PS1 or SERVER_PL
    if read_file(sp) ~= sv then
        if not write_file(sp, sv) then
            log("Cannot write the server script: %s", sp)
            return false
        end
    end
    return true
end

local function close_launch_pipe()
    local pipe = st.launch_pipe
    if not pipe then return end
    st.launch_pipe = nil
    pcall(function() pipe:close() end)
end

local function start_server()
    local p = paths()
    if not write_assets() then return false end

    remove_quiet(p.stop)
    remove_quiet(p.events)
    remove_quiet(p.port)
    remove_quiet(p.beat)
    remove_quiet(p.update_req)
    st.upd_busy_ms = nil
    remove_quiet(p.probe_req)
    st.probe_asked_for = nil
    remove_quiet(p.go)
    st.go_written = nil
    remove_quiet(p.ctl)
    st.ctl_shown_nonce = nil
    write_file(p.slog, "")
    st.last_seq = 0
    st.seq_at_activate = 0
    st.ev_off = 0
    st.port = nil
    st.port_wait_ms = PORT_WAIT_MS
    st.port_wait_logged = nil
    st.last_beat = nil
    st.beat_stale_ms = 0
    st.beat_dead = false
    st.beat_deferred = false

    st.launch_id = tostring(os.time()) .. tostring(math.random(1000, 9999))
    st.owner_n = 0
    write_file(p.owner, st.launch_id .. "\r\n0\r\n")

    local launch
    if PLAT.win then
        local ps_cmd = string.format(
            'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""%s"" ' ..
            '-PreferredPort %d -PortFile ""%s"" -Root ""%s"" -Events ""%s"" ' ..
            '-Stop ""%s"" -Log ""%s"" -Beat ""%s"" -ProbeReq ""%s"" -Go ""%s"" ' ..
            '-Ctl ""%s"" -Owner ""%s"" -OwnerId %s -UpdateReq ""%s""',
            p.ps1, st.last_port or 0, p.port, p.dir, p.events, p.stop, p.slog,
            p.beat, p.probe_req, p.go, p.ctl, p.owner, st.launch_id, p.update_req)
        local vbs = string.format(
            'Set sh = CreateObject("WScript.Shell")\r\nsh.Run "%s", 0, False\r\n', ps_cmd)
        if not write_file(p.vbs, vbs) then
            log("Cannot write the launcher: %s", p.vbs)
            return false
        end
        launch = string.format('wscript.exe //B //Nologo "%s"', p.vbs)
    else
        launch = string.format(
            'nohup perl "%s" -PreferredPort %d -PortFile "%s" -Root "%s" ' ..
            '-Events "%s" -Stop "%s" -Log "%s" -Beat "%s" -ProbeReq "%s" ' ..
            '-Go "%s" -Ctl "%s" -Owner "%s" -OwnerId %s -UpdateReq "%s" >/dev/null 2>&1 &',
            p.pl, st.last_port or 0, p.port, p.dir, p.events, p.stop, p.slog,
            p.beat, p.probe_req, p.go, p.ctl, p.owner, st.launch_id, p.update_req)
    end

    -- per Lua 5.1 ref: io.popen does not wait
    close_launch_pipe()
    local okp, pipe = pcall(io.popen, launch, "r")
    if okp and pipe then
        st.launch_pipe = pipe
    else
        os.execute(launch)
        if not st.popen_said then
            st.popen_said = true
            log("The local server was started the blocking way, because io.popen was refused on this machine. os.execute hands the command to cmd.exe and WAITS for it to exit, and that wait is on the same thread OBS draws its menus with - it is why loading this script can sit for several seconds before the panel comes back. Nothing is wrong with the server; only the launch is slow. io.popen does the same launch without the wait and is tried first.")
        end
    end
    st.server_launched = true
    st.health_ms = 3000
    log("Local server starting (it picks its own port). Folder: %s", p.dir)
    return true
end

local function service_launch()
    if not st.launch_want then return false end
    st.launch_want = false
    return start_server()
end

local function request_launch(why)
    if st.launch_want then return end
    st.launch_want = true
    log("A local server launch is wanted (%s). It is NOT started from this script's 100ms tick: that tick runs on OBS's render thread, where one os.execute - which waits for cmd.exe to exit - was measured at 5,694ms against a 33ms frame budget and took OBS's whole window to 'not responding'. The launch therefore happens on the same thread OBS gives its own menus, at the next frontend event, which any scene change or output start or stop produces. If nothing is happening in OBS at all, switch scenes once, or open and close this script's settings, and it goes immediately.",
        why)
end

local function stop_server()
    local p = paths()
    close_launch_pipe()
    write_file(p.stop, "stop\r\n")
    remove_quiet(p.owner)
    st.launch_id = nil
    st.launch_want = false
    remove_quiet(p.go)
    st.go_written = nil
    remove_quiet(p.ctl)
    st.ctl_shown_nonce = nil
    st.server_launched = false
    st.health_ms = nil
    st.port_wait_ms = nil
    log("Local server stop requested. The owner file is gone with it, so even if that stop file could not be written the server ends itself within its owner grace rather than outliving this OBS.")
end

local function check_server_health()
    local p = paths()
    local slog = read_file(p.slog) or ""
    if slog:find("BIND FAILED", 1, true) then
        log("Local server could not bind a port. Tried 20000-48000. Close whatever is holding the ports and reload the script.")
        log("Server log: %s", trim(slog))
    elseif slog:find("listening on", 1, true) then
        if st.port then
            log("Local server is up on port %d (http://localhost:%d/).",
                st.port, st.port)
        else
            log("Server is up but the port file is not there yet: %s", p.port)
        end
    else
        log("Could not confirm the local server started. The log is empty: %s", p.slog)
        if PLAT.win then
            log("PowerShell execution may be blocked.")
        else
            log("Check that perl is on the PATH: this script launches the local server with it, and macOS ships one at /usr/bin/perl.")
        end
    end
end

local function even_width(x)
    local v = math.floor((tonumber(x) or 0) + 0.5)
    if v % 2 == 1 then v = v + 1 end
    if v < 16 then v = 16 end
    return v
end

local PLAYER_PATH = "/yt_player.html"
local REC_SCENE_NAME  = "Castika Record Browser Scene"
local REC_SOURCE_NAME = "Castika Record Browser Source"

local REC_CARD_NAME = "Castika REC Indicator"
local REC_CARD_POS  = 30
local REC_CARD_IDS  = { "text_gdiplus_v3", "text_gdiplus_v2", "text_ft2_source_v2" }

local function resolve_resolution()
    local bw, bh = 1920, 1080
    local ovi = obs.obs_video_info()
    if obs.obs_get_video_info(ovi) then
        bw, bh = ovi.base_width, ovi.base_height
    end

    if cfg.fit_canvas then return even_width(bw), even_width(bh) end

    local vw = math.floor(tonumber(st.video_w or 0) or 0)
    local vh = math.floor(tonumber(st.video_h or 0) or 0)
    local known = (vw > 0) and (vh > 0)

    if cfg.res_mode ~= "custom" then
        if known then return even_width(vw), even_width(vh) end
        return bw, bh
    end

    local aw, ah = bw, bh
    if known then
        aw, ah = vw, vh
    else
        local src = obs.obs_get_source_by_name(REC_SOURCE_NAME)
        if src then
            local sw = obs.obs_source_get_width(src)
            local sh = obs.obs_source_get_height(src)
            if sw and sh and sw > 0 and sh > 0 then aw, ah = sw, sh end
            obs.obs_source_release(src)
        end
    end

    local h = cfg.custom_h
    if h < 16 then h = 1080 end
    local w = math.floor(h * (aw / ah) + 0.5)
    if w % 2 == 1 then w = w + 1 end
    if w < 16 then w = 16 end
    return w, h
end

-- the browser source FPS field takes integers; NTSC only via fps_num/fps_den
local function rec_fps()
    local want = math.floor(tonumber(cfg.fps or 0) or 0)
    if want > 0 then return want, 1, true end
    local ovi = obs.obs_video_info()
    if obs.obs_get_video_info(ovi) then
        local n = tonumber(ovi.fps_num or 0) or 0
        local d = tonumber(ovi.fps_den or 0) or 0
        if n > 0 and d > 0 then return n, d, false end
    end
    return 30, 1, false
end

local function url_time_now()
    local raw = trim(cfg.yt_url or "")
    if extract_youtube_id(raw) then return parse_time_param(raw) end
    local uid = trim(st.url_time_id or "")
    if uid ~= "" and uid == trim(st.video_id or "") then
        return st.url_time_sec
    end
    return nil
end

local function panel_url_check()
    local raw = trim(cfg.yt_url or "")
    if raw == "" then
        st.url_warned = nil
        return
    end
    if extract_youtube_id(raw) then
        st.url_warned = nil
        return
    end
    if st.url_warned == raw then return end
    st.url_warned = raw
    log("No YouTube video id could be found in the URL in the script panel: %s. Nothing was changed - the video, the browser source's URL, and any take in progress are all exactly as they were. Paste a full link: a watch?v=, a youtu.be/, an /embed/, a /shorts/, or a /live/ form all work, and so does the bare 11-character video id. A &t= and a list= in it are both fine.",
        raw)
end

local function effective_start_sec()
    local i = tonumber(st.in_sec or 0) or 0
    if i > 0 then return i end
    local u = tonumber(url_time_now() or 0) or 0
    if u > 0 then return u end
    return 0
end

local function effective_out_sec()
    local o = tonumber(st.out_sec or 0) or 0
    if o > 0 then return o end
    return 0
end

local function runup_target_sec()
    return effective_start_sec()
end

local function aspect_known()
    return (st.video_w or 0) > 0 and (st.video_h or 0) > 0
end

local function persist_video_aspect()
    if not script_settings then return end
    local vid = st.video_id or ""
    local vw = math.floor(st.video_w or 0)
    local vh = math.floor(st.video_h or 0)
    if obs.obs_data_get_string(script_settings, "video_id") == vid
       and obs.obs_data_get_int(script_settings, "video_w") == vw
       and obs.obs_data_get_int(script_settings, "video_h") == vh then
        return
    end
    obs.obs_data_set_string(script_settings, "video_id", vid)
    obs.obs_data_set_int(script_settings, "video_w", vw)
    obs.obs_data_set_int(script_settings, "video_h", vh)
end

local function request_probe(vid)
    vid = trim(vid or "")
    if vid == "" then return end
    if aspect_known() and st.cr_handle ~= nil then return end
    if st.probe_asked_for == vid then return end
    st.probe_asked_for = vid
    local p = paths()
    ensure_dir(p.dir)
    if write_file(p.probe_req, vid) then
        log("Asked the local server for the video's native size (id: %s) so the page URL can carry its aspect.",
            vid)
    else
        st.probe_asked_for = nil
    end
end

local UPD = { DAY_S = 86400, AGAIN_S = 3600, WAIT_MS = 30000 }

function UPD.parse(s)
    s = trim(s):lower()
    if s:sub(1, 1) == "v" then s = s:sub(2) end
    local parts = {}
    for d in (s .. "."):gmatch("([^.]*)%.") do
        if not d:match("^%d+$") or #d > 9 then return nil end
        parts[#parts + 1] = tonumber(d)
    end
    if #parts < 2 or #parts > 4 then return nil end
    return parts
end

function UPD.cmp(a, b)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return (x < y) and -1 or 1 end
    end
    return 0
end

function UPD.name(parts)
    return "v" .. table.concat(parts, ".")
end

function UPD.newer(tag, running)
    local a = UPD.parse(tag)
    local b = UPD.parse(tostring(running or ""):match("^%S+"))
    if not a or not b then return false end
    return UPD.cmp(a, b) > 0
end

function UPD.banner()
    if not cfg.update_check then return nil end
    if not UPD.newer(st.upd_tag, SCRIPT_VERSION) then return nil end
    return UPD.name(UPD.parse(st.upd_tag))
end

function UPD.load(settings)
    st.upd_at   = obs.obs_data_get_int(settings, "upd_at") or 0
    st.upd_tag  = obs.obs_data_get_string(settings, "upd_tag") or ""
    st.upd_ver  = obs.obs_data_get_string(settings, "upd_ver") or ""
    st.upd_told = obs.obs_data_get_bool(settings, "upd_told")
end

function UPD.save(settings)
    obs.obs_data_set_int(settings, "upd_at", st.upd_at or 0)
    obs.obs_data_set_string(settings, "upd_tag", st.upd_tag or "")
    obs.obs_data_set_string(settings, "upd_ver", st.upd_ver or "")
    obs.obs_data_set_bool(settings, "upd_told", st.upd_told and true or false)
end

function UPD.due(now)
    if not cfg.update_check or not cfg.enabled then return false end
    if st.upd_busy_ms then return false end
    if st.upd_force then return true end
    local f = st.upd_fail_at
    if f and now >= f and now - f < UPD.AGAIN_S then return false end
    if st.upd_ver ~= SCRIPT_VERSION then return true end
    local at = st.upd_at or 0
    return at <= 0 or now < at or now - at >= UPD.DAY_S
end

function UPD.request(now)
    if not st.server_launched or not UPD.due(now) then return false end
    if not write_file(paths().update_req, "1\r\n") then return false end
    st.upd_force = nil
    st.upd_busy_ms = UPD.WAIT_MS
    log("Update check: asking GitHub which release is newest. The local server's own worker asks, as a separate process with its own time limit, so nothing in this script waits on the network. If no answer comes back within %d seconds the request is dropped without a word on screen.",
        UPD.WAIT_MS / 1000)
    return true
end

function UPD.failed(why)
    st.upd_busy_ms = nil
    st.upd_fail_at = os.time()
    if st.upd_fail_said then return end
    st.upd_fail_said = true
    log("Update check: %s. That is not a fault - there may be no network, GitHub may be blocked or limiting requests, or its answer may not have been understood. Nothing is shown anywhere and nothing is changed. It is tried again after an hour at the earliest, and this line is said once per session.",
        why)
end

function UPD.tick()
    st.upd_busy_ms = st.upd_busy_ms - TICK_MS
    if st.upd_busy_ms <= 0 then UPD.failed("no answer arrived in time") end
end

function UPD.answer(line)
    if not cfg.update_check then return end
    local tag = line:match("&tag=([%w%._%-]+)%s*$")
    if line:find("&err=1", 1, true) or not tag then
        UPD.failed("the worker got no usable answer from GitHub")
        return
    end
    st.upd_busy_ms = nil
    st.upd_fail_at = nil
    st.upd_fail_said = nil
    st.upd_at, st.upd_tag, st.upd_ver = os.time(), tag, SCRIPT_VERSION
    if script_settings then UPD.save(script_settings) end
    local parts = UPD.parse(tag)
    if not parts then
        log("Update check: GitHub's newest release is named '%s', which is not a version number, so it is ignored.",
            tag)
    elseif UPD.newer(tag, SCRIPT_VERSION) then
        log("Update check: GitHub's newest release is %s and this is %s, so the trim controls will show a blue banner saying a newer version is out. It appears the next time the controls are opened.",
            UPD.name(parts), SCRIPT_VERSION)
    else
        log("Update check: GitHub's newest release is %s and this is %s, so nothing newer is out and there is no banner. It is asked again in a day, or when this version changes, or when the setting is switched off and on.",
            UPD.name(parts), SCRIPT_VERSION)
    end
end

function UPD.tell()
    if st.upd_told or not cfg.update_check then return end
    st.upd_told = true
    if script_settings then UPD.save(script_settings) end
    log("UPDATE CHECK IS ON, as it is by default. Once a day, and again whenever this script's version changes, the local server asks GitHub (https://api.github.com/repos/castika-code/simple-browser-recorder/releases/latest, a public page) which release is newest, and when that is newer than this one the trim controls show a blue banner saying so. Until this version the only site this script contacted was YouTube. The request carries no video, key or account of yours; GitHub sees this machine's address as any website would. The switch is 'Tell me in the trim controls when a newer version is out' at the bottom of this script's settings: off means no request at all, and off then on again checks at once. This line is said once.")
end

function UPD.switched(was)
    if cfg.update_check == was then return end
    st.upd_busy_ms = nil
    if cfg.update_check then
        st.upd_force = true
        st.upd_fail_at = nil
        st.upd_fail_said = nil
        UPD.tell()
    else
        st.upd_force = nil
        remove_quiet(paths().update_req)
        log("Update check is OFF. No request is made and the trim controls show no banner. Switch it back on and a check is made at once.")
    end
end

local function build_page_url(video_id)
    if not st.port then return nil end
    local gate = runup_target_sec()
    local load_at = 0
    if gate > RUNUP_SEC then load_at = gate - RUNUP_SEC end
    local fnum, fden = rec_fps()
    local u = string.format(
        "http://localhost:%d%s?v=%s&nonce=%s&start=%s&overscan=%d&loop=%d" ..
        "&gate=%s&fps=%s&runup=%d&tin=%s&tout=%s",
        st.port, PLAYER_PATH, video_id, st.nonce,
        num_str(load_at), OVERSCAN_PX, cfg.loop_mode and 1 or 0,
        num_str(gate), num_str(fnum / fden), RUNUP_SEC,
        num_str(effective_start_sec()), num_str(effective_out_sec()))
    if gate > 0 and st.runup_logged ~= gate then
        st.runup_logged = gate
        local runup = gate - load_at
        if runup >= RUNUP_SEC then
            log("In-point %ss: the page is loaded at %ss and plays forward behind the mask, which is cut exactly at %ss. Run-up %ss. No seek is issued anywhere on this path.",
                num_str(gate), num_str(load_at), num_str(gate), num_str(runup))
        else
            log("In-point %ss is below the %ds run-up, so the page is loaded at 0 and gets only %ss of run-up. The mask is still cut exactly at %ss - the POSITION is exact - but there is not enough video in front of it to out-wait YouTube's center overlay, so the overlay will be in the picture at the start of this take. Move the in-point to %ds or later for a clean start.",
                num_str(gate), RUNUP_SEC, num_str(runup), num_str(gate), RUNUP_SEC)
        end
    end
    if aspect_known() then
        u = u .. string.format("&vw=%d&vh=%d", st.video_w, st.video_h)
    end
    local out = effective_out_sec()
    if out > 0 then
        u = u .. string.format("&out=%s", num_str(out))
    end
    local seed = url_time_now()
    if seed and seed > 0 then
        u = u .. string.format("&t=%s", num_str(seed))
    end
    if cfg.cr_on then
        u = u .. string.format(
            "&cr=1&crm=%s&crp=%s&cro=%s&crs=%d&crb=%d&crc=%s&crg=%s",
            url_enc(cfg.cr_mode), url_enc(cfg.cr_pos),
            num_str(cfg.cr_voff or 0), math.floor(cfg.cr_size or 36),
            cfg.cr_bold and 1 or 0,
            rgba_hex(cfg.cr_color), rgba_hex(cfg.cr_bg))
        if trim(cfg.cr_face or "") ~= "" then
            u = u .. "&crf=" .. url_enc(trim(cfg.cr_face))
        end
        if cfg.cr_mode == "x" and trim(cfg.cr_text or "") ~= "" then
            u = u .. "&crt=" .. url_enc(trim(cfg.cr_text))
        end
        if (cfg.cr_mode == "h" or cfg.cr_mode == "yh") and st.cr_handle and st.cr_handle ~= "" then
            u = u .. "&crh=" .. url_enc(st.cr_handle)
        end
    end
    if cfg.update_check then
        local ub = UPD.banner()
        if ub then u = u .. "&upd=" .. url_enc(ub) end
    end
    return u
end

local function find_sceneitem(scene, name)
    local items = obs.obs_scene_enum_items(scene)
    local found = nil
    if items then
        for _, item in ipairs(items) do
            local s = obs.obs_sceneitem_get_source(item)
            if s and obs.obs_source_get_name(s) == name then found = item break end
        end
        if found then obs.obs_sceneitem_addref(found) end
        obs.sceneitem_list_release(items)
    end
    return found
end

local function source_in_current_scene(name)
    if name == "" then return false end
    local scene_src = obs.obs_frontend_get_current_scene()
    if not scene_src then return false end
    local scene = obs.obs_scene_from_source(scene_src)
    local found = false
    if scene then
        if obs.obs_scene_find_source_recursive then
            found = obs.obs_scene_find_source_recursive(scene, name) ~= nil
        else
            local item = find_sceneitem(scene, name)
            if item then
                found = true
                obs.obs_sceneitem_release(item)
            end
        end
    end
    obs.obs_source_release(scene_src)
    return found
end

local function apply_browser_settings(data, page_url, w, h)
    obs.obs_data_set_string(data, "url", page_url)
    obs.obs_data_set_bool(data, "is_local_file", false)
    obs.obs_data_set_int(data, "width", w)
    obs.obs_data_set_int(data, "height", h)
    local fnum, fden, fpinned = rec_fps()
    if fpinned then
        obs.obs_data_set_bool(data, "fps_custom", true)
        obs.obs_data_set_int(data, "fps", math.floor(fnum / fden + 0.5))
    else
        obs.obs_data_set_bool(data, "fps_custom", false)
    end
    obs.obs_data_set_bool(data, "reroute_audio", not st.ctl_audio)
    obs.obs_data_set_bool(data, "shutdown", false)
    obs.obs_data_set_bool(data, "restart_when_active", true)
    obs.obs_data_set_string(data, "css", "")
end

local function request_create(why)
    st.create_want = true
    if st.create_want_logged then return end
    st.create_want_logged = true
    log("The recording scene or its browser source does not exist yet (%s), and neither one is created from this script's 100ms tick. That tick runs on OBS's render thread and holds this script's lock while it runs. obs_scene_create on that thread can never finish: OBS hands the new scene to its Qt UI thread and waits for the answer, the UI thread then announces the scene to every script, and the Lua binding must take this script's lock to deliver that announcement - the lock the tick is holding while it waits. Each side waits for the other and OBS stops drawing. That is why a machine that had never run this script froze the moment a URL was pasted. The scene and the source are created on the UI thread instead: straight away when a setting in this script's panel changes, and otherwise at the next OBS frontend event, which any scene change or output start or stop produces.",
        why or "reason not recorded")
end

local function ensure_rec_source(may_create)
    if obs.obs_scene_create == nil or obs.obs_source_create == nil
       or obs.obs_scene_add == nil then
        log("This OBS build is missing obs_scene_create / obs_source_create / obs_scene_add, so the recording scene and source cannot be created. Create a scene named '%s' with a browser source named '%s' in it by hand.",
            REC_SCENE_NAME, REC_SOURCE_NAME)
        return nil
    end

    local src = obs.obs_get_source_by_name(REC_SOURCE_NAME)
    local made_source = false
    if src then
        if obs.obs_source_get_unversioned_id(src) ~= "browser_source" then
            log("A source named '%s' already exists but it is not a browser source, so it was left strictly alone and this script can do nothing. Rename or remove it and reload the script.",
                REC_SOURCE_NAME)
            obs.obs_source_release(src)
            return nil
        end
    elseif not may_create then
        request_create("the browser source is not there")
        return nil
    else
        local w, h = resolve_resolution()
        local d = obs.obs_data_create()
        apply_browser_settings(d, "", w, h)
        local ok, made = pcall(obs.obs_source_create, "browser_source",
                               REC_SOURCE_NAME, d, nil)
        obs.obs_data_release(d)
        if not ok or not made then
            log("Creating the browser source '%s' failed, so there is nothing to record from.",
                REC_SOURCE_NAME)
            return nil
        end
        src = made
        made_source = true
    end

    local scene_src = obs.obs_get_source_by_name(REC_SCENE_NAME)
    local scene = nil
    if scene_src then
        scene = obs.obs_scene_from_source(scene_src)
        if not scene then
            log("A source named '%s' already exists but it is not a scene, so it was left alone and the recording source may not stay loaded. Rename or remove it.",
                REC_SCENE_NAME)
        end
    elseif not may_create then
        request_create("the recording scene is not there")
    else
        local ok, made = pcall(obs.obs_scene_create, REC_SCENE_NAME)
        if ok and made then
            scene = made
            scene_src = obs.obs_scene_get_source(scene)
            log("Created the scene '%s' with the browser source '%s' in it. THIS IS THE SCENE YOU RECORD FROM: send it to Program and the take starts itself.",
                REC_SCENE_NAME, REC_SOURCE_NAME)
        else
            log("Creating the scene '%s' failed, so the recording source has nowhere to live and may not stay loaded.",
                REC_SCENE_NAME)
        end
    end

    if scene then
        local item = find_sceneitem(scene, REC_SOURCE_NAME)
        if item then
            obs.obs_sceneitem_release(item)
        else
            local ok2, added = pcall(obs.obs_scene_add, scene, src)
            if ok2 and added then
                if obs.obs_sceneitem_set_bounds_type then
                    local cw, ch = 1920, 1080
                    local bovi = obs.obs_video_info()
                    if obs.obs_get_video_info(bovi) then
                        cw, ch = bovi.base_width, bovi.base_height
                    end
                    local pos = obs.vec2(); pos.x, pos.y = 0, 0
                    local b = obs.vec2(); b.x, b.y = cw, ch
                    pcall(obs.obs_sceneitem_set_pos, added, pos)
                    pcall(obs.obs_sceneitem_set_bounds_type, added,
                          obs.OBS_BOUNDS_SCALE_INNER)
                    pcall(obs.obs_sceneitem_set_bounds_alignment, added, 0)
                    pcall(obs.obs_sceneitem_set_bounds, added, b)
                end
            else
                log("Adding '%s' to the scene '%s' failed, so it may not stay loaded between OBS sessions.",
                    REC_SOURCE_NAME, REC_SCENE_NAME)
            end
        end
    end

    if scene_src then obs.obs_source_release(scene_src) end

    if src and scene then
        st.create_want = false
        st.create_want_logged = nil
    end

    if made_source then
        log("Created the browser source '%s'.", REC_SOURCE_NAME)
    end
    return src
end

local function video_id_from_source(name)
    local src = obs.obs_get_source_by_name(name)
    if not src then return nil end
    if obs.obs_source_get_unversioned_id(src) ~= "browser_source" then
        obs.obs_source_release(src)
        return nil
    end
    local sd = obs.obs_source_get_settings(src)
    local url = obs.obs_data_get_string(sd, "url") or ""
    obs.obs_data_release(sd)
    obs.obs_source_release(src)
    return extract_youtube_id(url)
end

local function source_url_now()
    local src = obs.obs_get_source_by_name(REC_SOURCE_NAME)
    if not src then return "" end
    local sd = obs.obs_source_get_settings(src)
    local url = obs.obs_data_get_string(sd, "url") or ""
    obs.obs_data_release(sd)
    obs.obs_source_release(src)
    return url
end

local function panel_url_now()
    if script_settings then
        local s = trim(obs.obs_data_get_string(script_settings, "yt_url") or "")
        if s ~= "" then return s end
    end
    return trim(cfg.yt_url or "")
end

local function resolve_video_id()
    local raw = panel_url_now()
    local vid = extract_youtube_id(raw)
    if vid then return vid, "panel", raw end
    vid = video_id_from_source(REC_SOURCE_NAME)
    if vid then return vid, "source", raw end
    vid = trim(st.video_id or "")
    if vid ~= "" then return vid, "state", raw end
    return nil, nil, raw
end

local function bail(reason, fmt, ...)
    if st.bail_warned ~= reason then
        st.bail_warned = reason
        log(fmt, ...)
    end
    return false
end

local function clear_trim_range()
    local had = (st.in_sec ~= nil) or (st.out_sec ~= nil)
    st.in_sec = nil
    st.out_sec = nil
    st.runup_logged = nil
    st.out_warned_for = nil
    st.range_warned_for = nil
    if script_settings then
        obs.obs_data_set_double(script_settings, "in_sec", -1)
        obs.obs_data_set_double(script_settings, "out_sec", -1)
    end
    return had
end

local function forget_video_state(new_id)
    if trim(new_id or "") == trim(st.video_id or "") then return false end
    st.video_w = nil
    st.video_h = nil
    st.probe_asked_for = nil
    st.aspect_warned_for = nil
    st.cr_handle = nil
    st.cr_handle_warned = nil
    local had_range = clear_trim_range()
    if had_range then
        log("The video changed, so the in and out points were cleared. They were chosen against frames of the previous video and mean nothing in this one - an in-point kept across a video change is how a take ends up running up to a position the new video never reaches. Open the trim control window and choose them again.")
    end
    return true
end

local function panel_intent_check()
    local raw = trim(cfg.yt_url or "")
    local vid = extract_youtube_id(raw)
    if not vid then return end
    local t = parse_time_param(raw)
    local same = (trim(st.url_time_id or "") == vid) and (t == st.url_time_sec)
    if not same then st.runup_logged = nil end
    st.url_time_id = vid
    st.url_time_sec = t
    if script_settings then
        obs.obs_data_set_string(script_settings, "url_time_id", vid)
        obs.obs_data_set_double(script_settings, "url_time_sec", t or -1)
    end
    if same then return end
    if not clear_trim_range() then return end
    log("The URL in the script panel does not carry the v and t the stored in and out points were chosen against, so those points were cleared. A stored range only survives a URL that names the same video AND the same t: either of those changing is an explicit instruction to start somewhere else, and it arrived after the range, so it wins. The take now starts at this t - or at 0 when there is none - and runs to the end of the video. Re-applying the SAME URL changes nothing and keeps the range. Open the trim controls to choose an out-point again.")
end

local function create_or_update_source(may_create)
    if not st.port then
        return bail("noport",
            "No local server port yet. The settings are applied to the source as soon as the port arrives.")
    end

    local name = REC_SOURCE_NAME

    local video_id, id_from, panel_raw = resolve_video_id()
    if not video_id or video_id == "" then
        return bail("novideo",
            "No YouTube URL yet. Paste one into the 'YouTube URL' box in this script's settings panel, or straight into the browser source's own URL field - the box writes into that same field.")
    end
    st.bail_warned = nil
    forget_video_state(video_id)
    st.video_id = video_id
    persist_video_aspect()
    request_probe(video_id)

    st.nonce = tostring(os.time()) .. tostring(math.random(1000, 9999))
    if script_settings then
        obs.obs_data_set_string(script_settings, "nonce", st.nonce)
    end

    local page_url = build_page_url(video_id)
    local w, h = resolve_resolution()

    if aspect_known() then
        st.aspect_warned_for = nil
    elseif st.aspect_warned_for ~= video_id then
        st.aspect_warned_for = video_id
        log("The video's native size is not known yet, so the page URL carries no aspect and the player falls back to a full-width iframe: the top and bottom of the picture may be cropped. It is corrected as soon as the size arrives.")
    end

    local existing = ensure_rec_source(may_create)
    if not existing then return false end

    local data = obs.obs_data_create()
    apply_browser_settings(data, page_url, w, h)
    obs.obs_source_update(existing, data)
    obs.obs_data_release(data)
    obs.obs_source_release(existing)
    st.panel_wrote = nil
    st.url_live = trim(page_url)
    if id_from == "panel" then st.yt_url_applied = panel_raw end
    log("Browser source '%s' updated (id: %s, %dx%d)", name, video_id, w, h)
    return true
end

local function service_create()
    if not st.create_want or st.create_busy then return false end
    if not st.coll_ready then
        local cs = obs.obs_frontend_get_current_scene
            and obs.obs_frontend_get_current_scene()
        if not cs then
            if not st.coll_said then
                st.coll_said = true
                log("The recording scene is NOT being created yet, because OBS has not finished loading its scene collection. A scene created in front of that load does not survive it: OBS then reads the saved collection, finds this name already taken by the one just made, and renames the SAVED one with a ' 2' on the end. That is where a duplicate scene comes from, and why another one appears on every launch after it - the renamed copy is saved in turn and collides again next time. Creation therefore waits until OBS says it has finished loading, which is a fraction of a second away, and then happens by itself with nothing to collide with. This line is said once per session.")
            end
            return false
        end
        obs.obs_source_release(cs)
        st.coll_ready = true
    end
    if not cfg.enabled or recording_now() then return false end
    if not resolve_video_id() then return false end
    st.create_busy = true
    local ok, src = pcall(ensure_rec_source, true)
    st.create_busy = false
    if not ok then error(src, 0) end
    if not src then return false end
    obs.obs_source_release(src)
    st.apply_pending = true
    return true
end

local function ctl_show_hold()
    if st.show_held then return end
    if obs.obs_source_inc_showing == nil then
        log("THE TRIM CONTROLS WILL BE BLANK IN NORMAL MODE on this OBS build: its scripting API has no obs_source_inc_showing, so this script cannot tell OBS the recording source is visible while you trim. OBS's Interact window draws a source but does not mark it visible, and a browser source that is visible nowhere produces no frames - which is a blank window, not a broken page. Turn Studio Mode on and the preview marks it visible for you.")
        return
    end
    local src = obs.obs_get_source_by_name(REC_SOURCE_NAME)
    if not src then return end
    local ok = pcall(obs.obs_source_inc_showing, src)
    obs.obs_source_release(src)
    if not ok then return end
    st.show_held = true
    log("The recording source is marked VISIBLE for the length of this trim session. OBS's Interact window renders a source but never marks it visible, and a browser source that is visible nowhere stops producing frames - which is why the trim controls came up blank in normal mode while Studio Mode drew them perfectly: Studio Mode's preview was doing this job. THIS DOES NOT PUT THE SOURCE ON PROGRAM. It stays off program, the controls keep drawing, and the mark is dropped the moment this source goes live, the controls come down, or the script unloads.")
end

local function ctl_show_drop()
    if not st.show_held then return end
    st.show_held = false
    if obs.obs_source_dec_showing == nil then return end
    local src = obs.obs_get_source_by_name(REC_SOURCE_NAME)
    if not src then return end
    pcall(obs.obs_source_dec_showing, src)
    obs.obs_source_release(src)
end

local function notify(fmt, ...)
    local msg = (select("#", ...) > 0) and string.format(fmt, ...) or fmt
    log("%s", msg)
    return true
end

local function arm_control_layer(video_id)
    if not st.port then
        notify("The trim controls cannot open yet: the local server has not reported its port. Try again in a moment.")
        return nil
    end
    video_id = trim(video_id or "")
    if video_id == "" then video_id = resolve_video_id() or "" end
    if video_id == "" then
        notify("The trim controls have nothing to show: no YouTube video is configured yet. Paste a YouTube URL into this script's settings first.")
        return nil
    end
    if our_take_now() then
        notify("The trim controls cannot open: one of this script's own takes is running. arming them rewrites the page URL, which reloads the source and would interrupt the take. Wait for the take to finish. A recording or a stream of YOUR OWN does not block this - the controls refuse to draw while this source is on Program, so arming them while your own output runs is the safe case and is how you line up the next quote without touching your show.")
        return nil
    end

    local probe = obs.obs_get_source_by_name(REC_SOURCE_NAME)
    if probe then
        local live = obs.obs_source_active(probe)
        obs.obs_source_release(probe)
        if live then
            notify("The trim controls cannot open while '%s' is on PROGRAM. They refuse to draw on a source that is live - that refusal is what keeps them out of every recording. Switch Program to another scene and ask again.",
                REC_SOURCE_NAME)
            return nil
        end
    end

    st.ctl_audio = true
    if not create_or_update_source(true) then
        st.ctl_audio = false
        return nil
    end

    local p = paths()
    ensure_dir(p.dir)
    if not write_file(p.ctl, st.nonce) then
        log("The trim controls could not be armed: the arm file could not be written (%s). The recording page itself was rewritten and is fine; nothing else changed. Check that the work folder is writable and press the button again.",
            p.ctl)
        return nil
    end
    log("Trim controls armed for ONE page load (nonce %s). The page picks the arm up on its next 250ms gate poll and draws them over the picture, with the IN and OUT handles already sitting on the range this script is holding. This source's audio is routed straight out of the browser for this session so the video can be HEARD in preview, where OBS mixes nothing; it goes back into OBS's mixer at the activation edge, before any take. The controls go away on a RELOAD - the arm is one-shot and is already spent - and immediately if this source goes to Program, which is what keeps them out of every recording.",
        st.nonce)
    st.apply_pending = false
    st.ctl_shown_nonce = nil
    ctl_show_hold()

    return obs.obs_get_source_by_name(REC_SOURCE_NAME)
end

local function auto_convert_source_url()
    if not cfg.auto_convert then return end
    local name = REC_SOURCE_NAME
    if not st.port then return end

    local src = obs.obs_get_source_by_name(name)
    if not src then return end
    if obs.obs_source_get_unversioned_id(src) ~= "browser_source" then
        obs.obs_source_release(src)
        return
    end
    local s = obs.obs_source_get_settings(src)
    local url = obs.obs_data_get_string(s, "url") or ""
    obs.obs_data_release(s)
    local on_program = obs.obs_source_active(src)
    obs.obs_source_release(src)

    if url:find(PLAYER_PATH, 1, true) then
        st.convert_fail = nil
        request_probe(extract_youtube_id(url) or st.video_id)
        local cur = tonumber(url:match("localhost:(%d+)") or "")
        if cur and cur ~= st.port and not recording_now() and not on_program then
            log("Source URL port changed from %d to %d. Rewriting the URL.",
                cur, st.port)
            create_or_update_source()
        end
        return
    end
    if trim(url) == "" then return end

    local vid = extract_youtube_id(url)
    if not vid then
        if url:lower():find("youtu", 1, true) and st.convert_fail ~= url then
            st.convert_fail = url
            log("Looks like a YouTube URL but no video id was found: %s", url)
        end
        return
    end

    if recording_now() or on_program then return end

    local typed_here = (st.yt_url_applied ~= nil)
    if st.panel_wrote and trim(url) == st.panel_wrote then
        st.panel_wrote = nil
        typed_here = false
    end
    if trim(url) ~= (st.yt_url_applied or "") then
        st.yt_url_applied = trim(url)
        cfg.yt_url = trim(url)
        if script_settings then
            obs.obs_data_set_string(script_settings, "yt_url", trim(url))
        end
    end
    local t = parse_time_param(url)
    local t_changed = (t ~= st.url_time_sec)
    if t_changed or trim(st.url_time_id or "") ~= vid then
        st.runup_logged = nil
    end
    st.url_time_sec = t
    st.url_time_id = vid
    if script_settings then
        obs.obs_data_set_double(script_settings, "url_time_sec", t or -1)
        obs.obs_data_set_string(script_settings, "url_time_id", vid)
    end
    if typed_here and clear_trim_range() then
        log("A URL was typed straight into the browser source, so the in and out points were cleared. Pasting an address by hand is starting over, and that is true even when it is the same video - the points were chosen against a previous pass and nothing here can tell which frames you still meant. Open the trim controls and choose them again. A URL applied from this script's own panel keeps them, unless its t= changed.")
    elseif t_changed and clear_trim_range() then
        log("The t= in the URL changed, so the in and out points were cleared. A new t is an explicit instruction to start somewhere else, and it arrived after the range that was stored, so it wins: the take now starts at the new t and runs to the end of the video. This is the same whichever way the URL arrived - the script's own panel and an address typed by hand behave alike here - so the start position can never be changed and then silently ignored. Open the trim controls to choose an out-point again.")
    end
    if t then
        log("URL t= detected: %ss. That is the DEFAULT IN-POINT: with no trim range stored, the recording starts there, the page is loaded %ds earlier and plays forward behind the mask, and the trim controls open with the in-mark on it and the out-mark at the end of the video. A range confirmed in the control window outranks it, because that is the later and more explicit choice. Clearing the t from the URL gives the whole video back.",
            num_str(t), RUNUP_SEC)
    end

    st.convert_fail = nil
    forget_video_state(vid)
    st.video_id = vid
    persist_video_aspect()
    log("YouTube URL found on the source. Converting it to an embed (id: %s).", vid)
    request_probe(vid)
    create_or_update_source()
end

local function deliver_panel_url()
    local raw = trim(cfg.yt_url or "")
    if raw == "" then return end
    if raw == (st.yt_url_applied or "") then return end
    if not extract_youtube_id(raw) then return end
    if our_take_now() then return end
    local src = obs.obs_get_source_by_name(REC_SOURCE_NAME)
    if not src then return end
    if obs.obs_source_get_unversioned_id(src) ~= "browser_source" then
        obs.obs_source_release(src)
        return
    end
    -- obs_source_showing is true for Preview too; obs_source_active is not
    if obs.obs_source_active(src) then
        obs.obs_source_release(src)
        return
    end
    local sd = obs.obs_data_create()
    obs.obs_data_set_string(sd, "url", raw)
    obs.obs_source_update(src, sd)
    obs.obs_data_release(sd)
    obs.obs_source_release(src)
    st.yt_url_applied = raw
    st.panel_wrote = raw
    st.url_live = raw
    log("The URL from the script panel was written into the browser source's URL field, which is the one place this script reads the video from: %s",
        raw)
end

local function ctl_layer_up()
    local p = paths()
    if read_file(p.ctl) then return true end
    if st.ctl_shown_nonce and st.ctl_shown_nonce == st.nonce then return true end
    return false
end

local function configured_source_on_program()
    local src = obs.obs_get_source_by_name(REC_SOURCE_NAME)
    if not src then return false end
    local on_program = obs.obs_source_active(src)
    obs.obs_source_release(src)
    return on_program and true or false
end

local HV_EXT = {
    hybrid_mp4     = "mp4",
    hybrid_mov     = "mov",
    fragmented_mp4 = "mp4",
    fragmented_mov = "mov",
    mpegts         = "ts",
    hls            = "m3u8",
}

local function prof_cfg()
    if obs.obs_frontend_get_profile_config == nil then return nil end
    local ok, c = pcall(obs.obs_frontend_get_profile_config)
    if not ok or not c then return nil end
    return c
end

local function cfg_str(c, sec, key)
    if not c or obs.config_get_string == nil then return "" end
    local ok, v = pcall(obs.config_get_string, c, sec, key)
    if not ok or v == nil then return "" end
    return trim(v)
end

local function cfg_int(c, sec, key)
    if not c or obs.config_get_int == nil then return 0 end
    local ok, v = pcall(obs.config_get_int, c, sec, key)
    if not ok then return 0 end
    return math.floor(tonumber(v) or 0)
end

local function out_mode(c)
    local m = cfg_str(c, "Output", "Mode")
    if m == "Advanced" then return "Advanced" end
    return "Simple"
end

local function out_section(c)
    return (out_mode(c) == "Advanced") and "AdvOut" or "SimpleOutput"
end

local function first_track(mask)
    mask = math.floor(tonumber(mask) or 0)
    if mask <= 0 then return nil end
    for i = 0, MAX_AUDIO_MIXES - 1 do
        if math.floor(mask / math.floor(2 ^ i)) % 2 == 1 then return i end
    end
    return nil
end

local AUD_KEY = "isolated_sources"

-- obs_enum_sources and source_list_release are added by the scripting glue, not by SWIG
local function aud_list_sources()
    if obs.obs_enum_sources == nil then return nil end
    local ok, list = pcall(obs.obs_enum_sources)
    if not ok or type(list) ~= "table" then return nil end
    return list
end

local function aud_free_sources(list)
    if not list then return end
    if obs.source_list_release then pcall(obs.source_list_release, list) end
end

local function aud_carries_audio(src)
    if obs.obs_source_get_output_flags == nil then return false end
    local ok, fl = pcall(obs.obs_source_get_output_flags, src)
    if not ok then return false end
    fl = math.floor(tonumber(fl) or 0)
    local bit = math.floor(tonumber(obs.OBS_SOURCE_AUDIO) or 2)
    if bit < 1 then return false end
    return math.floor(fl / bit) % 2 == 1
end

local function aud_mask_of(src)
    if obs.obs_source_get_audio_mixers == nil then return nil end
    local ok, m = pcall(obs.obs_source_get_audio_mixers, src)
    if not ok then return nil end
    m = math.floor(tonumber(m) or 0)
    if m < 0 then return nil end
    return m
end

local function aud_has_rec_mix(mask)
    return math.floor(mask / REC_MIX_BIT) % 2 == 1
end

local function aud_cfg_rec_mix()
    local c = prof_cfg()
    if not c then return false end
    local m = cfg_int(c, out_section(c), "RecTracks")
    if m <= 0 then return false end
    return aud_has_rec_mix(m)
end

local function aud_rec_mix_taken()
    if obs.obs_frontend_get_recording_output == nil
       or obs.obs_output_get_mixers == nil then
        return aud_cfg_rec_mix()
    end
    local out = obs.obs_frontend_get_recording_output()
    if not out then return aud_cfg_rec_mix() end
    local ok, m = pcall(obs.obs_output_get_mixers, out)
    pcall(obs.obs_output_release, out)
    if not ok then return aud_cfg_rec_mix() end
    m = math.floor(tonumber(m) or 0)
    if m <= 0 then return aud_cfg_rec_mix() end
    return aud_has_rec_mix(m)
end

local function aud_write_record()
    if not script_settings then return false end
    if obs.obs_data_array_create == nil or obs.obs_data_set_array == nil then
        return false
    end
    local arr = obs.obs_data_array_create()
    for _, e in ipairs(st.aud_saved or {}) do
        local it = obs.obs_data_create()
        obs.obs_data_set_string(it, "n", e.n)
        obs.obs_data_set_int(it, "m", e.m)
        obs.obs_data_array_push_back(arr, it)
        obs.obs_data_release(it)
    end
    obs.obs_data_set_array(script_settings, AUD_KEY, arr)
    obs.obs_data_array_release(arr)
    return true
end

local function aud_read_record(settings)
    local out = {}
    if not settings or obs.obs_data_get_array == nil then return out end
    local arr = obs.obs_data_get_array(settings, AUD_KEY)
    if not arr then return out end
    local n = math.floor(tonumber(obs.obs_data_array_count(arr)) or 0)
    for i = 0, n - 1 do
        local it = obs.obs_data_array_item(arr, i)
        if it then
            local nm = trim(obs.obs_data_get_string(it, "n") or "")
            local m = math.floor(tonumber(obs.obs_data_get_int(it, "m")) or 0)
            if nm ~= "" and m >= 0 then out[#out + 1] = { n = nm, m = m } end
            obs.obs_data_release(it)
        end
    end
    obs.obs_data_array_release(arr)
    return out
end

local function aud_restore(why, keep_missing)
    st.aud_delay_ms = nil
    st.aud_delay_why = nil
    local saved = st.aud_saved
    if saved == nil or #saved == 0 then
        st.aud_saved = nil
        return 0, 0
    end
    local back, gone, left = 0, 0, {}
    for _, e in ipairs(saved) do
        local src = obs.obs_get_source_by_name(e.n)
        if src then
            pcall(obs.obs_source_set_audio_mixers, src, e.m)
            obs.obs_source_release(src)
            back = back + 1
        else
            gone = gone + 1
            if keep_missing then left[#left + 1] = e end
        end
    end
    st.aud_saved = (#left > 0) and left or nil
    aud_write_record()
    local tail = ""
    if gone > 0 and keep_missing then
        tail = string.format(" %d of them is not in this scene collection under the name its tracks were recorded under, so it is being kept on the record and tried once more at the end of the next take - a collection that had not finished loading is the ordinary reason, and a source that has simply been deleted costs one more attempt and is then dropped.", gone)
    elseif gone > 0 then
        tail = string.format(" %d of them no longer exists under the name its tracks were recorded under, which is not an error and does not hold anything else up: a source deleted or renamed since the take started cannot be put back, and every other one was.", gone)
    end
    log("The %d source(s) whose OBS audio track %d this script switched for the take are back to exactly the tracks you had - %s. That one track was the whole change: no fader was moved, nothing was muted, and the other five tracks carried what they always carry.%s",
        back + gone, MAX_AUDIO_MIXES, why, tail)
    return back, gone
end

local function aud_isolate()
    if st.aud_saved then
        aud_restore("a record from an earlier take was still open when this one started")
    end
    st.aud_on = false
    if cfg.rec_sound ~= "source" then return 0 end
    if obs.obs_frontend_recording_active()
       or (obs.obs_frontend_streaming_active and obs.obs_frontend_streaming_active()) then
        log("NOTHING WAS TAKEN OFF AUDIO TRACK %d FOR THIS TAKE, because a recording or a stream of your own is running. 'Source only' clears every other audio source off that track for the length of a take, and doing that while your own output is running could take the sound out of a track your own output is writing. A take is not supposed to be able to start at all in that state, so this line means one got through: the take is going ahead with OBS's audio mixer exactly as it stands, and your track assignments were left alone.",
            MAX_AUDIO_MIXES)
        return 0
    end
    if obs.obs_source_get_audio_mixers == nil or obs.obs_source_set_audio_mixers == nil then
        log("This OBS build's scripting API has no obs_source_get_audio_mixers and obs_source_set_audio_mixers, so 'Source only' cannot clear audio track %d and this take carries whatever OBS's audio mixer carries - a microphone or a notification CAN land in it. Nothing else about the take changes.",
            MAX_AUDIO_MIXES)
        return 0
    end
    if aud_rec_mix_taken() then
        log("NOTHING WAS TAKEN OFF AUDIO TRACK %d FOR THIS TAKE, because OBS's own recording output is set to use that track - read off that output, or out of your own output settings while that output has no track list yet, rather than assumed. 'Source only' needs track %d to itself, and clearing it would take the sound out of your own recording the moment you start one, so your track assignments were left alone and this take carries whatever OBS's audio mixer carries - a microphone or a notification CAN land in it. Free track %d under Settings -> Output if you want 'Source only' to work.",
            MAX_AUDIO_MIXES, MAX_AUDIO_MIXES, MAX_AUDIO_MIXES)
        return 0
    end
    local list = aud_list_sources()
    if not list then
        log("This OBS build's scripting layer does not provide obs_enum_sources, so the other audio sources cannot be found and 'Source only' cannot clear audio track %d. This take carries whatever OBS's audio mixer carries - a microphone or a notification CAN land in it. Nothing else about the take changes.",
            MAX_AUDIO_MIXES)
        return 0
    end
    local n, ours = 0, false
    for _, src in ipairs(list) do
        local nm = obs.obs_source_get_name(src)
        nm = nm and trim(nm) or ""
        local mask = (nm ~= "" and aud_carries_audio(src)) and aud_mask_of(src) or nil
        if mask then
            local mine = (nm == REC_SOURCE_NAME)
            if mine then ours = true end
            local want = nil
            if mine and not aud_has_rec_mix(mask) then
                want = mask + REC_MIX_BIT
            elseif (not mine) and aud_has_rec_mix(mask) then
                want = mask - REC_MIX_BIT
            end
            if want and pcall(obs.obs_source_set_audio_mixers, src, want) then
                st.aud_saved = st.aud_saved or {}
                st.aud_saved[#st.aud_saved + 1] = { n = nm, m = mask }
                aud_write_record()
                if not mine then n = n + 1 end
            end
        end
    end
    aud_free_sources(list)
    st.aud_on = true
    if not ours then
        log("THIS TAKE WILL HAVE NO SOUND IN IT. 'Source only' records OBS audio track %d and nothing else, and the recording source '%s' is not carrying audio at the moment the take starts, so nothing at all is feeding that track. The picture records normally and the file is playable. This is the setting doing what it says rather than a fault: choose 'Follow OBS audio mixer setting' if you would rather have the mix as it stands, microphone and all.",
            MAX_AUDIO_MIXES, REC_SOURCE_NAME)
    end
    return n
end

local HV_API = {
    "obs_view_create", "obs_view_add2", "obs_view_set_source", "obs_view_remove",
    "obs_view_destroy", "obs_output_create", "obs_output_start",
    "obs_output_stop", "obs_output_active", "obs_output_release",
    "obs_output_get_settings", "obs_output_get_id",
    "obs_output_get_video_encoder", "obs_output_get_audio_encoder",
    "obs_output_set_video_encoder", "obs_output_set_audio_encoder",
    "obs_video_encoder_create", "obs_audio_encoder_create",
    "obs_encoder_set_video", "obs_encoder_set_audio", "obs_encoder_get_id",
    "obs_encoder_get_settings", "obs_encoder_release", "obs_get_video",
    "obs_get_audio", "obs_frontend_get_recording_output",
    "obs_output_get_total_frames", "obs_data_get_json",
    "obs_data_create_from_json",
}

local function hv_api_ok()
    for _, n in ipairs(HV_API) do
        if obs[n] == nil then return false, n end
    end
    return true, nil
end

-- texture encoders may not receive a second view's video
local HV_NONTEX = {
    h264_texture_amf   = "h264_fallback_amf",
    h265_texture_amf   = "h265_fallback_amf",
    av1_texture_amf    = "av1_fallback_amf",
    jim_nvenc          = "ffmpeg_nvenc",
    jim_hevc_nvenc     = "ffmpeg_hevc_nvenc",
    jim_av1            = "ffmpeg_av1_nvenc",
    obs_nvenc_h264_tex = "obs_nvenc_h264_soft",
    obs_nvenc_hevc_tex = "obs_nvenc_hevc_soft",
    obs_nvenc_av1_tex  = "obs_nvenc_av1_soft",
}

-- obs_output_release force-stops a destroying output; there is no obs_video_release
local function hv_release_all()
    local had = st.hv_output or st.hv_view or st.hv_running
    if st.hv_output then
        pcall(obs.obs_output_release, st.hv_output)
        st.hv_output = nil
    end
    if st.hv_venc then
        pcall(obs.obs_encoder_release, st.hv_venc)
        st.hv_venc = nil
    end
    if st.hv_aenc then
        pcall(obs.obs_encoder_release, st.hv_aenc)
        st.hv_aenc = nil
    end
    if st.hv_view then
        pcall(obs.obs_view_set_source, st.hv_view, 0, nil)
        pcall(obs.obs_view_remove, st.hv_view)
        pcall(obs.obs_view_destroy, st.hv_view)
        st.hv_view = nil
    end
    st.hv_video = nil
    st.hv_running = false
    st.hv_stop_ms = nil
    st.hv_frames_ms = nil
    st.hv_size = nil
    if had then
        log("The file is closed and this script's own recording output, its two encoders, and its hidden view are all released. This is the condition the Program return waits for.")
    end
end

local function hv_want_size()
    local src = obs.obs_get_source_by_name(REC_SOURCE_NAME)
    if not src then return nil, nil end
    local w = obs.obs_source_get_width(src)
    local h = obs.obs_source_get_height(src)
    obs.obs_source_release(src)
    w = math.floor(tonumber(w or 0) or 0)
    h = math.floor(tonumber(h or 0) or 0)
    if w < 16 or h < 16 then return nil, nil end
    if w % 2 == 1 then w = w + 1 end
    if h % 2 == 1 then h = h + 1 end
    return w, h
end

local function hv_make_video_encoder(id, settings, label)
    local enc = nil
    local ok, made = pcall(obs.obs_video_encoder_create, id,
                           "castika_rec_v_" .. label, settings, nil)
    if ok and made then enc = made end
    if not enc then
        log("The video encoder '%s' could not be created, so the hidden-view recording path cannot use it (%s attempt).",
            tostring(id), label)
        return nil
    end
    local ok2 = pcall(obs.obs_encoder_set_video, enc, st.hv_video)
    if not ok2 then
        log("Binding the video encoder '%s' to this script's own view failed.", tostring(id))
        pcall(obs.obs_encoder_release, enc)
        return nil
    end
    return enc
end

local HV_VENC_ALIAS = {
    x264        = { "obs_x264" },
    x264_lowcpu = { "obs_x264" },
    qsv         = { "obs_qsv11_v2", "obs_qsv11" },
    qsv_av1     = { "obs_qsv11_av1" },
    amd         = { "h264_texture_amf" },
    amd_hevc    = { "h265_texture_amf" },
    amd_av1     = { "av1_texture_amf" },
    nvenc       = { "obs_nvenc_h264_tex", "jim_nvenc", "ffmpeg_nvenc" },
    nvenc_hevc  = { "obs_nvenc_hevc_tex", "jim_hevc_nvenc", "ffmpeg_hevc_nvenc" },
    nvenc_av1   = { "obs_nvenc_av1_tex", "jim_av1_nvenc", "jim_av1", "ffmpeg_av1_nvenc" },
    apple_h264  = { "com.apple.videotoolbox.videoencoder.ave.avc" },
    apple_hevc  = { "com.apple.videotoolbox.videoencoder.ave.hevc" },
}

local HV_AENC_ALIAS = {
    aac  = { "ffmpeg_aac", "CoreAudio_AAC", "libfdk_aac" },
    opus = { "ffmpeg_opus" },
}

local HV_PRESET_KEY = {
    obs_x264           = { "Preset", "preset" },
    obs_qsv11          = { "QSVPreset", "target_usage" },
    obs_qsv11_v2       = { "QSVPreset", "target_usage" },
    obs_qsv11_av1      = { "QSVPreset", "target_usage" },
    h264_texture_amf   = { "AMDPreset", "preset" },
    h265_texture_amf   = { "AMDPreset", "preset" },
    av1_texture_amf    = { "AMDAV1Preset", "preset" },
    obs_nvenc_h264_tex = { "NVENCPreset2", "preset2" },
    obs_nvenc_hevc_tex = { "NVENCPreset2", "preset2" },
    obs_nvenc_av1_tex  = { "NVENCPreset2", "preset2" },
    jim_nvenc          = { "NVENCPreset2", "preset2" },
    jim_hevc_nvenc     = { "NVENCPreset2", "preset2" },
    jim_av1_nvenc      = { "NVENCPreset2", "preset2" },
    ffmpeg_nvenc       = { "NVENCPreset2", "preset2" },
    ffmpeg_hevc_nvenc  = { "NVENCPreset2", "preset2" },
}

local function hv_info_free(info)
    if not info then return end
    if info.venc_settings then obs.obs_data_release(info.venc_settings) end
    if info.aenc_settings then obs.obs_data_release(info.aenc_settings) end
    if info.out_settings then obs.obs_data_release(info.out_settings) end
    info.venc_settings = nil
    info.aenc_settings = nil
    info.out_settings = nil
end

local function hv_enc_exists(id)
    id = trim(id or "")
    if id == "" then return false end
    if obs.obs_encoder_get_display_name == nil then return true end
    local ok, nm = pcall(obs.obs_encoder_get_display_name, id)
    if not ok or nm == nil or trim(nm) == "" then return false end
    return true
end

local function hv_resolve_enc(raw, alias)
    raw = trim(raw or "")
    if raw == "" or raw == "none" then return nil end
    if hv_enc_exists(raw) then return raw end
    local list = alias[raw]
    if not list then return nil end
    for _, id in ipairs(list) do
        if hv_enc_exists(id) then return id end
    end
    return nil
end

local function obs_config_roots()
    if st.cfg_roots then return st.cfg_roots end
    local out = {}
    if obs.os_get_config_path_ptr then
        local ok, r = pcall(obs.os_get_config_path_ptr, "obs-studio")
        if ok and type(r) == "string" and trim(r) ~= "" then out[#out + 1] = trim(r) end
    end
    local app = os.getenv("APPDATA")
    if PLAT.win and app and trim(app) ~= "" then
        out[#out + 1] = join(trim(app), "obs-studio")
    end
    local home = os.getenv("HOME")
    if not PLAT.win and home and trim(home) ~= "" then
        home = trim(home)
        out[#out + 1] = join(join(join(home, "Library"), "Application Support"),
                             "obs-studio")
        out[#out + 1] = join(join(home, ".config"), "obs-studio")
    end
    st.cfg_roots = out
    return out
end

local function hv_profile_dir(c)
    local names = {}
    if obs.obs_frontend_get_user_config then
        local ok, uc = pcall(obs.obs_frontend_get_user_config)
        if ok and uc then names[#names + 1] = cfg_str(uc, "Basic", "ProfileDir") end
    end
    names[#names + 1] = cfg_str(c, "General", "Name")
    for _, root in ipairs(obs_config_roots()) do
        local base = join(join(root, "basic"), "profiles")
        for _, n in ipairs(names) do
            if n ~= "" and read_file(join(join(base, n), "basic.ini")) then
                return join(base, n)
            end
        end
    end
    return nil
end

local function hv_json_settings(dir, file)
    if not dir then return nil end
    if obs.obs_data_create_from_json_file == nil then return nil end
    local ok, d = pcall(obs.obs_data_create_from_json_file, join(dir, file))
    if not ok or not d then return nil end
    return d
end

local function hv_rec_target(info)
    if obs.obs_frontend_get_current_record_output_path then
        local ok, p = pcall(obs.obs_frontend_get_current_record_output_path)
        if ok and p then info.dir = trim(p) end
    end
    local c = prof_cfg()
    if not c then return end
    local fmt = cfg_str(c, out_section(c), "RecFormat2")
    info.ext = HV_EXT[fmt] or ((fmt ~= "") and fmt or nil)
end

local function hv_out_shell(info)
    local fout = obs.obs_frontend_get_recording_output()
    if not fout then return "obs_frontend_get_recording_output() returned nothing" end
    local oki, oid = pcall(obs.obs_output_get_id, fout)
    if oki and oid then info.out_id = trim(oid) end
    local oks, osd = pcall(obs.obs_output_get_settings, fout)
    if oks and osd then info.out_settings = osd end
    pcall(obs.obs_output_release, fout)
    if not info.out_id or info.out_id == "" then
        return "OBS's own recording output has no id"
    end
    return nil
end

local function hv_simple_vsettings(c, id)
    local rate = cfg_int(c, "SimpleOutput", "VBitrate")
    if rate <= 0 then return nil end
    local d = obs.obs_data_create()
    obs.obs_data_set_string(d, "rate_control", "CBR")
    obs.obs_data_set_int(d, "bitrate", rate)
    local pk = HV_PRESET_KEY[id]
    if pk then
        local pv = cfg_str(c, "SimpleOutput", pk[1])
        if pv ~= "" then obs.obs_data_set_string(d, pk[2], pv) end
    end
    return d
end

local function hv_aenc_settings(rate)
    if rate <= 0 then return nil end
    local d = obs.obs_data_create()
    obs.obs_data_set_int(d, "bitrate", rate)
    return d
end

local function hv_read_config()
    local c = prof_cfg()
    if not c then
        return nil, "this OBS build's scripting API cannot read your profile configuration", true
    end
    local mode = out_mode(c)
    local info = { from = "config" }
    local vraw, araw, tracks, arate = "", "", 0, 0

    if mode == "Advanced" then
        if cfg_str(c, "AdvOut", "RecType") ~= "Standard" then
            return nil, "your Advanced output records through the custom FFmpeg type, which uses no encoder of OBS's own", false
        end
        local jf = "recordEncoder.json"
        vraw = cfg_str(c, "AdvOut", "RecEncoder")
        if vraw == "" or vraw == "none" then
            vraw = cfg_str(c, "AdvOut", "Encoder")
            jf = "streamEncoder.json"
        end
        araw = cfg_str(c, "AdvOut", "RecAudioEncoder")
        if araw == "" or araw == "none" then
            araw = cfg_str(c, "AdvOut", "AudioEncoder")
        end
        tracks = cfg_int(c, "AdvOut", "RecTracks")
        info.venc_id = hv_resolve_enc(vraw, HV_VENC_ALIAS)
        if info.venc_id then
            info.venc_settings = hv_json_settings(hv_profile_dir(c), jf)
            if not info.venc_settings then
                return nil, string.format("your Advanced output's encoder '%s' keeps its settings in %s, which could not be read", info.venc_id, jf), true
            end
        end
        arate = cfg_int(c, "AdvOut",
            "Track" .. tostring((first_track(tracks) or 0) + 1) .. "Bitrate")
    else
        local q = cfg_str(c, "SimpleOutput", "RecQuality")
        if q == "Lossless" then
            return nil, "your Simple output's recording quality is Lossless, which uses no encoder of OBS's own", false
        end
        if q ~= "Stream" then
            return nil, string.format("your Simple output's recording quality is '%s', and OBS holds the encoder settings for that as its own constants rather than as values in your configuration", (q ~= "") and q or "(not set)"), true
        end
        vraw = cfg_str(c, "SimpleOutput", "StreamEncoder")
        araw = cfg_str(c, "SimpleOutput", "StreamAudioEncoder")
        tracks = cfg_int(c, "SimpleOutput", "RecTracks")
        arate = cfg_int(c, "SimpleOutput", "ABitrate")
        info.venc_id = hv_resolve_enc(vraw, HV_VENC_ALIAS)
        if info.venc_id then
            info.venc_settings = hv_simple_vsettings(c, info.venc_id)
            if not info.venc_settings then
                return nil, "your Simple output carries no video bitrate to record at", true
            end
        end
    end

    if not info.venc_id then
        hv_info_free(info)
        return nil, string.format("your %s output's recording encoder is '%s', which this OBS build does not have",
            mode, (vraw ~= "") and vraw or "(not set)"), true
    end

    info.aenc_id = hv_resolve_enc(araw, HV_AENC_ALIAS)
    if info.aenc_id then
        info.aenc_settings = hv_aenc_settings(arate)
        info.aenc_mix = first_track(tracks)
    end

    hv_rec_target(info)
    local shell = hv_out_shell(info)
    if shell then
        hv_info_free(info)
        return nil, shell, true
    end
    return info, nil, true
end

-- obs_output_get_video_encoder returns a borrowed pointer
-- an idle output's path is the previous recording's file
local function hv_read_frontend()
    local fout = obs.obs_frontend_get_recording_output()
    if not fout then
        return nil, "obs_frontend_get_recording_output() returned nothing"
    end
    local info = { from = "output" }
    local ok_id, oid = pcall(obs.obs_output_get_id, fout)
    info.out_id = (ok_id and oid) or nil

    local fv = obs.obs_output_get_video_encoder(fout)
    local fa = obs.obs_output_get_audio_encoder(fout, 0)
    if not fv then
        pcall(obs.obs_output_release, fout)
        return nil, "the frontend recording output has no video encoder yet"
    end
    local okv, vid = pcall(obs.obs_encoder_get_id, fv)
    info.venc_id = (okv and vid) or nil
    local okvs, vs = pcall(obs.obs_encoder_get_settings, fv)
    info.venc_settings = (okvs and vs) or nil
    if fa then
        local oka, aid = pcall(obs.obs_encoder_get_id, fa)
        info.aenc_id = (oka and aid) or nil
        local okas, as = pcall(obs.obs_encoder_get_settings, fa)
        info.aenc_settings = (okas and as) or nil
        local okm, mi = pcall(obs.obs_encoder_get_mixer_index, fa)
        info.aenc_mix = (okm and tonumber(mi)) or nil
    end
    local oko, os_ = pcall(obs.obs_output_get_settings, fout)
    info.out_settings = (oko and os_) or nil
    pcall(obs.obs_output_release, fout)

    if not info.out_id or trim(info.out_id) == "" then
        return nil, "the frontend recording output has no id"
    end
    if not info.venc_id or trim(info.venc_id) == "" then
        hv_info_free(info)
        return nil, "the frontend video encoder has no id"
    end
    hv_rec_target(info)
    return info, nil
end

local function hv_build_out_settings(info)
    local d = nil
    if info.out_settings then
        local okj, js = pcall(obs.obs_data_get_json, info.out_settings)
        if okj and js and trim(js) ~= "" then
            local okc, made = pcall(obs.obs_data_create_from_json, js)
            if okc and made then d = made end
        end
    end
    if not d then
        local okn, made = pcall(obs.obs_data_create)
        if okn and made then d = made end
    end
    if not d then
        return nil, "the recording output's settings could not be copied"
    end
    local old = obs.obs_data_get_string(d, "path") or ""
    if trim(old) == "" then
        old = obs.obs_data_get_string(d, "url") or ""
    end
    local dir, ext = old:match("^(.*)[\\/][^\\/]*%.([%w]+)$")
    if not dir or not ext then
        dir = trim(info.dir or "")
        ext = trim(info.ext or "")
    end
    if dir == "" or ext == "" then
        obs.obs_data_release(d)
        return nil, "no recording folder and file type could be read out of OBS's own output settings"
    end
    local vid = trim(st.video_id or "")
    if vid == "" then vid = "take" end
    local name = string.format("%s/castika_%s_%s.%s", dir, vid,
                               os.date("%Y-%m-%d_%H-%M-%S"), ext)
    obs.obs_data_set_string(d, "path", name)
    return d, name
end

local function hv_make_view(w, h)
    local ovi = obs.obs_video_info()
    -- obslua exports no VIDEO_FORMAT_* or VIDEO_CS_* constants
    if not obs.obs_get_video_info(ovi) then
        return false, "obs_get_video_info() failed"
    end
    ovi.base_width = w
    ovi.base_height = h
    ovi.output_width = w
    ovi.output_height = h
    ovi.fps_num, ovi.fps_den = rec_fps()

    local okv, view = pcall(obs.obs_view_create)
    if not okv or not view then return false, "obs_view_create() failed" end
    st.hv_view = view

    local oka, vid = pcall(obs.obs_view_add2, view, ovi)
    if not oka or not vid then
        return false, "obs_view_add2() gave back no video"
    end
    st.hv_video = vid

    -- obs_view_set_source bumps showing, not active
    local src = obs.obs_get_source_by_name(REC_SOURCE_NAME)
    if not src then return false, "the recording source is gone" end
    local oks = pcall(obs.obs_view_set_source, view, 0, src)
    obs.obs_source_release(src)
    if not oks then return false, "obs_view_set_source() failed" end
    return true, nil
end

local function hv_try(info, venc_id, label)
    st.hv_venc = hv_make_video_encoder(venc_id, info.venc_settings, label)
    if not st.hv_venc then return false, "no video encoder" end

    if info.aenc_id then
        local mix = math.floor(tonumber(info.aenc_mix or 0) or 0)
        if mix < 0 or mix >= MAX_AUDIO_MIXES then mix = 0 end
        if st.aud_on then mix = REC_MIX_IDX end
        local oka, aenc = pcall(obs.obs_audio_encoder_create, info.aenc_id,
                                "castika_rec_a_" .. label, info.aenc_settings,
                                mix, nil)
        if oka and aenc then
            st.hv_aenc = aenc
            local okb, au = pcall(obs.obs_get_audio)
            if okb and au then
                pcall(obs.obs_encoder_set_audio, aenc, au)
            end
            if st.aud_on then
                log("This take's audio is OBS audio track %d and nothing else. REC sound is 'Source only', so every other source that carries audio is off that track until a moment after the file closes: what is in the clip is the recording source, and what is NOT in it is your microphone, your desktop sound and any notification. The encoder is still OBS's own - its id and its settings are read off your recording output - and the track it draws from is the only part this script chose.",
                    mix + 1)
            else
                log("This take's audio is taken from OBS audio track %d, the track OBS's own recording output is set to - read out of your own output settings rather than assumed. REC sound is 'Follow OBS audio mixer setting', so everything routed to that track in Advanced Audio Properties is in the clip, which on a default install includes Desktop Audio and Mic/Aux.",
                    mix + 1)
            end
        else
            log("The audio encoder '%s' could not be cloned, so this take records picture only.",
                tostring(info.aenc_id))
        end
    end

    local osettings, where = hv_build_out_settings(info)
    if not osettings then return false, where end

    local oko, out = pcall(obs.obs_output_create, info.out_id,
                           "castika_rec_out_" .. label, osettings, nil)
    obs.obs_data_release(osettings)
    if not oko or not out then
        return false, "the output '" .. tostring(info.out_id) .. "' could not be created"
    end
    st.hv_output = out

    pcall(obs.obs_output_set_video_encoder, out, st.hv_venc)
    if st.hv_aenc then
        pcall(obs.obs_output_set_audio_encoder, out, st.hv_aenc, 0)
    end

    local okst, started = pcall(obs.obs_output_start, out)
    if not okst or not started then
        local err = nil
        if obs.obs_output_get_last_error then
            local oke, e = pcall(obs.obs_output_get_last_error, out)
            if oke and e and trim(e) ~= "" then err = e end
        end
        return false, string.format("obs_output_start() refused it%s",
            err and (": " .. err) or "")
    end
    log("Recording to %s (%dx%d, encoder '%s', output '%s', %s attempt).",
        where, st.hv_size and st.hv_size.w or 0, st.hv_size and st.hv_size.h or 0,
        tostring(venc_id), tostring(info.out_id), label)
    return true, nil
end

local function hv_drop_output()
    if st.hv_output then
        pcall(obs.obs_output_release, st.hv_output)
        st.hv_output = nil
    end
    if st.hv_venc then
        pcall(obs.obs_encoder_release, st.hv_venc)
        st.hv_venc = nil
    end
    if st.hv_aenc then
        pcall(obs.obs_encoder_release, st.hv_aenc)
        st.hv_aenc = nil
    end
end

local function hv_enc_plan()
    local info, cwhy, primable = hv_read_config()
    if info then return info, nil, true end
    if primable == false then return nil, tostring(cwhy), false end
    local fnfo, fwhy = hv_read_frontend()
    if fnfo then return fnfo, nil, true end
    return nil, string.format("%s, and %s", tostring(cwhy), tostring(fwhy)), true
end

local function hv_start(why)
    if hv_active() then return true end
    if st.hv_view or st.hv_output then
        log("The previous take's output has not finished closing its file yet, so this one could not be started.")
        return false
    end

    local ok, missing = hv_api_ok()
    if not ok then
        if not st.hv_api_warned then
            st.hv_api_warned = true
            log("This OBS build has no %s, so this script cannot record from a view of its own at all. Every take needs that view - it is what gives the file the source's own size and keeps the Program output and the on-screen card out of it - so no take can run on this build.",
                tostring(missing))
        end
        return false
    end

    local w, h = hv_want_size()
    if not w then
        log("The recording source has no size yet, so there was nothing to record (%s). The page has not finished laying itself out; take the source off Program for a moment and put it back.", why)
        return false
    end
    st.hv_size = { w = w, h = h }

    local info, why_not = hv_enc_plan()
    if not info then
        log("The recording encoder could not be assembled (%s).", tostring(why_not))
        st.hv_size = nil
        return false
    end

    local made, mwhy = hv_make_view(w, h)
    if not made then
        log("This script's own recording view could not be built (%s).", tostring(mwhy))
        hv_release_all()
        hv_info_free(info)
        return false
    end

    local label = (info.from == "config") and "configured" or "inherited"
    local started, swhy = hv_try(info, info.venc_id, label)
    if not started then
        log("The %s encoder '%s' would not start against this script's own view (%s).",
            label, tostring(info.venc_id), tostring(swhy))
        hv_drop_output()
        local alt = HV_NONTEX[info.venc_id or ""]
        if alt then
            log("Trying the same vendor's non-texture encoder '%s' instead - a texture encoder takes frames off the GPU through the main render path and may not accept a second view's video.",
                alt)
            started, swhy = hv_try(info, alt, "non-texture")
            if not started then
                log("The non-texture encoder '%s' would not start either (%s).",
                    alt, tostring(swhy))
                hv_drop_output()
            end
        end
    end

    hv_info_free(info)

    if not started then
        log("Nothing this script could build would record from its own view, so there was nothing left to try.")
        hv_release_all()
        return false
    end

    st.hv_running = true
    st.hv_stop_ms = nil
    st.hv_frames_ms = 4000
    return true
end

local function hv_stop()
    if not st.hv_output then
        hv_release_all()
        return
    end
    if st.hv_stop_ms then return end
    pcall(obs.obs_output_stop, st.hv_output)
    st.hv_stop_ms = 15000
end

local function take_refused(detail)
    st.we_record = false
    st.remaining_ms = nil
    st.pending_stop = nil
    st.pending_reason = nil
    st.unmask_wait_ms = nil
    st.fail_card_ms = FAIL_CARD_MS
    aud_restore("no recording was made for this take, so there was nothing for the track isolation to hold")
    log("NO RECORDING WAS MADE FOR THIS TAKE AND NOTHING WAS WRITTEN TO DISK (%s). This is a REFUSAL, not a crash and not anything you did wrong: the only thing this tool makes is a clip at the recording source's own size, with the player's chrome outside the frame and the audio narrowed to one track, and that needs a recording output of this script's own. It could not build one this time, so it stopped rather than quietly hand the take to OBS's own recording - that would have given you a file at the canvas size, with the Program output in it and the audio back to the full mixer, and you would only have found out when you opened it. Losing one take is cheaper than a wrong file mixed in among your quotes. The source has been LEFT ON PROGRAM and the trim range is untouched, so once the cause above is dealt with, take the source off Program for a moment and put it back to run the take again. Starting any recording in OBS yourself, once, also clears the commonest cause of this.",
        detail)
end

local function hv_prime_blocked()
    local rec, str = foreign_output_now()
    if rec then return "a recording of your own is running" end
    if str then return "a stream of your own is running" end
    if obs.obs_frontend_replay_buffer_active
       and obs.obs_frontend_replay_buffer_active() then
        return "your replay buffer is running"
    end
    return nil
end

local function hv_prime_check()
    if st.prime_phase then return end
    if (st.prime_tries or 0) > 0 then return end

    local info, why, primable = hv_read_config()
    if info then
        hv_info_free(info)
        return
    end
    local cwhy = tostring(why)
    local fnfo = hv_read_frontend()
    if fnfo then
        hv_info_free(fnfo)
        return
    end

    st.prime_tries = 1
    if primable == false then
        st.prime_phase = "failed"
        log("THE NEXT TAKE WILL BE REFUSED, and here is the warning ahead of it: %s. This script records through an output of its own so the file is the source's own size with nothing of the Program output in it, and that needs an encoder of OBS's own to clone. The output mode you have chosen does not use one, so there is nothing to clone and no test recording would produce one. Choose a recording quality or type that uses an encoder, under Settings -> Output, and this script works again.",
            cwhy)
        return
    end
    if obs.obs_frontend_recording_start == nil then
        st.prime_phase = "failed"
        log("THE NEXT TAKE WILL BE REFUSED: %s, and this OBS build's scripting API has no obs_frontend_recording_start, so this script cannot make the short test recording that would bring the encoder into existence. Start any recording in OBS yourself, once, and takes work for the rest of this OBS session.",
            cwhy)
        return
    end
    local blocked = hv_prime_blocked()
    if blocked then
        st.prime_phase = "failed"
        log("THE NEXT TAKE WILL BE REFUSED: %s. This script would normally make a short test recording of its own here to bring the encoder into existence, and it did NOT, because %s. Starting a recording while your own output is running is not something this script will ever do. The take will be refused and nothing will be written. Start the next take once your own output has finished.",
            cwhy, blocked)
        return
    end

    st.prime_phase = "wait"
    st.prime_ms = PRIME_WAIT_MS
    st.fe_ours = true
    st.fe_stop_asked = nil
    log("A SHORT TEST RECORDING OF THIS SCRIPT'S OWN IS STARTING NOW, and it is deliberate: %s. OBS does not attach its recording encoder to its recording output until a recording has actually been started once, so on a freshly started OBS there is nothing for this script to clone. Starting one and stopping it again is what brings that encoder into existence, and from then on every take of this session inherits it. This runs HERE, at the moment the source went to Program - in front of the whole %ds run-up and seconds before the page asks for the real recording - so the take's own timing is not touched by it. It stops the instant the encoder appears, which is a fraction of a second, and the mask is still up so the picture in it is black.",
            cwhy, RUNUP_SEC)
    obs.obs_frontend_recording_start()
end

local function hv_prime_poll()
    if st.prime_phase ~= "wait" and st.prime_phase ~= "stop" then return end
    st.prime_ms = (st.prime_ms or 0) - TICK_MS

    if st.prime_phase == "wait" then
        local info = hv_read_frontend()
        if info then
            hv_info_free(info)
            st.prime_phase = "stop"
            st.prime_ms = PRIME_WAIT_MS
            st.fe_stop_asked = true
            if obs.obs_frontend_recording_stop then
                pcall(obs.obs_frontend_recording_stop)
            end
            log("OBS's recording encoder now EXISTS on OBS's recording output - which is the condition this script was waiting for, read directly off that output rather than waited out on a guess - so the test recording has been asked to stop. Takes record from this script's own view from here on.")
        elseif st.prime_ms <= 0 then
            st.prime_phase = "stop"
            st.prime_bad = true
            st.prime_ms = PRIME_WAIT_MS
            st.fe_stop_asked = true
            if obs.obs_frontend_recording_stop then
                pcall(obs.obs_frontend_recording_stop)
            end
            log("THE TEST RECORDING RAN FOR %dms AND OBS STILL PUT NO ENCODER ON ITS RECORDING OUTPUT, so it has been stopped and the next take will be REFUSED rather than written at the wrong size. The usual cause is that the recording could not start at all - no space on the recording drive, a recording folder that is gone or not writable, or an encoder your hardware will not open. Check Settings -> Output and the OBS log just above this line, then reload this script to let it try again.",
                PRIME_WAIT_MS)
        end
        return
    end

    if not obs.obs_frontend_recording_active() then
        st.prime_phase = st.prime_bad and "failed" or "done"
        st.fe_ours = nil
        st.fe_stop_asked = nil
        if st.prime_bad then return end
        local last = ""
        if obs.obs_frontend_get_last_recording then
            local okl, p = pcall(obs.obs_frontend_get_last_recording)
            if okl and p then last = trim(p) end
        end
        log("THE TEST RECORDING IS FINISHED AND IT LEFT A FILE BEHIND, which you did not ask for: %s. That file is this script's litter, not your footage - it is a fraction of a second long and the picture in it is the black mask - and you can delete it whenever you like. THIS SCRIPT DID NOT DELETE IT, on purpose: it sits in your own recording folder alongside your real recordings, nothing in this tool is allowed to delete a file in there, and OBS may still be remuxing it for a moment after it reports the stop. Nothing else of yours was touched: no setting was changed and your recording folder, format and encoder are exactly as you had them.",
            (last ~= "") and last or "OBS did not report the file name, so look for the newest file in your recording folder with this moment's timestamp")
        return
    end
    if st.prime_ms <= 0 then
        st.prime_phase = st.prime_bad and "failed" or "done"
        st.fe_ours = nil
        st.fe_stop_asked = nil
        log("The test recording did not report itself stopped within %dms. OBS closes the file on its own and whatever it wrote is in your recording folder for you to delete. Nothing is held up by this: whether the next take can run is decided by whether the encoder exists, and that is read fresh each time.",
            PRIME_WAIT_MS)
    end
end

local function hv_poll()
    if st.hv_frames_ms and st.hv_output then
        st.hv_frames_ms = st.hv_frames_ms - TICK_MS
        if st.hv_frames_ms <= 0 then
            st.hv_frames_ms = nil
            local okf, n = pcall(obs.obs_output_get_total_frames, st.hv_output)
            local frames = (okf and tonumber(n)) or 0
            if frames <= 0 then
                log("THIS SCRIPT'S OWN RECORDING OUTPUT STARTED AND THEN ENCODED NOTHING - no frame reached it in four seconds - so it is being stopped and this take is over. The file it opened is empty and can be deleted; its name is in the 'Recording to' line above. An empty file is the one outcome this path is not allowed to produce silently, so this line exists to make it loud.")
                hv_stop()
                take_refused("this script's own recording output encoded no frame at all in its first four seconds")
            end
        end
    end

    if st.hv_stop_ms then
        st.hv_stop_ms = st.hv_stop_ms - TICK_MS
        local busy = false
        if st.hv_output then
            local oka, a = pcall(obs.obs_output_active, st.hv_output)
            busy = oka and a and true or false
        end
        if not busy then
            hv_release_all()
        elseif st.hv_stop_ms <= 0 then
            log("This script's recording output did not report itself stopped within 15s, so it is being released anyway. OBS flushes an output it destroys, so the file is closed; the picture was already finished.")
            hv_release_all()
        end
    end
end

-- studio mode renders Program from an obs_scene_duplicate snapshot
local function rec_card_canvas()
    local ovi = obs.obs_video_info()
    if obs.obs_get_video_info(ovi) then
        local w = tonumber(ovi.base_width or 0) or 0
        local h = tonumber(ovi.base_height or 0) or 0
        if w > 0 and h > 0 then return w, h end
    end
    return 1920, 1080
end

local REC_FAIL_TXT =
    "  ! NO RECORDING - TAKE REFUSED  \n" ..
    "  nothing was written to disk  \n" ..
    "  see the script log for why  "

local function rec_card_text()
    local w, h = 0, 0
    if st.hv_size then w, h = st.hv_size.w, st.hv_size.h end
    local fnum, fden = rec_fps()
    return string.format(
        "  * REC   recording in the background  \n" ..
        "  %dx%d  %sfps  \n" ..
        "  this banner is not in the file  ",
        w, h, num_str(fnum / fden))
end

-- text_gdiplus_v3 draws a 27x7 box for text "", not nothing
local function rec_card_look(d, txt, fail)
    local live = (txt ~= "")
    obs.obs_data_set_string(d, "text", txt)
    if fail then
        obs.obs_data_set_int(d, "color", 0xFFFFFFFF)
        obs.obs_data_set_int(d, "bk_color", 0xFF0000FF)
        obs.obs_data_set_int(d, "bk_opacity", 100)
        obs.obs_data_set_bool(d, "outline", true)
        obs.obs_data_set_int(d, "outline_opacity", 100)
        obs.obs_data_set_int(d, "color1", 0xFF0000FF)
        obs.obs_data_set_int(d, "color2", 0xFF0000FF)
        obs.obs_data_set_bool(d, "drop_shadow", true)
        return
    end
    local ink = live and 0xFFFFFFFF or 0x00FFFFFF
    obs.obs_data_set_int(d, "color", ink)
    obs.obs_data_set_int(d, "bk_color", 0xFF000000)
    obs.obs_data_set_int(d, "bk_opacity", live and 70 or 0)
    obs.obs_data_set_bool(d, "outline", live)
    obs.obs_data_set_int(d, "outline_opacity", live and 100 or 0)
    obs.obs_data_set_int(d, "color1", ink)
    obs.obs_data_set_int(d, "color2", ink)
    obs.obs_data_set_bool(d, "drop_shadow", live)
end

local function rec_card_settings(d)
    local _, ch = rec_card_canvas()
    local fs = math.floor(ch / 38)
    if fs < 14 then fs = 14 end
    local f = obs.obs_data_create()
    obs.obs_data_set_string(f, "face", PLAT.win and "Consolas" or "Menlo")
    obs.obs_data_set_int(f, "size", fs)
    obs.obs_data_set_int(f, "flags", 1)
    obs.obs_data_set_string(f, "style", "Bold")
    obs.obs_data_set_obj(d, "font", f)
    obs.obs_data_release(f)
    obs.obs_data_set_int(d, "bk_color", 0xFF000000)
    obs.obs_data_set_int(d, "outline_size", 2)
    obs.obs_data_set_int(d, "outline_color", 0xFF000000)
    rec_card_look(d, "")
end

local function rec_card_view_safe()
    if not st.hv_view then return false, "there is no view" end
    if obs.obs_view_get_source == nil then return true, nil end
    local ok, s = pcall(obs.obs_view_get_source, st.hv_view, 0)
    if not ok or not s then return true, nil end
    local n = obs.obs_source_get_name(s)
    obs.obs_source_release(s)
    if n == REC_SOURCE_NAME then return true, nil end
    return false, tostring(n)
end

local function rec_card_remove()
    st.rec_card_txt = nil
    st.rec_card_n = nil
    local src = obs.obs_get_source_by_name(REC_CARD_NAME)
    if not src then return end
    local scene_src = obs.obs_get_source_by_name(REC_SCENE_NAME)
    if scene_src then
        local scene = obs.obs_scene_from_source(scene_src)
        if scene then
            local item = find_sceneitem(scene, REC_CARD_NAME)
            if item then
                pcall(obs.obs_sceneitem_remove, item)
                obs.obs_sceneitem_release(item)
            end
        end
        obs.obs_source_release(scene_src)
    end
    pcall(obs.obs_source_remove, src)
    obs.obs_source_release(src)
end

local function rec_card_ensure()
    local function id_ok(id)
        if obs.obs_get_source_output_flags == nil then return true end
        local okf, f = pcall(obs.obs_get_source_output_flags, id)
        if not okf then return true end
        return (tonumber(f) or 0) ~= 0
    end
    local src = obs.obs_get_source_by_name(REC_CARD_NAME)
    if src then
        local was = ""
        if obs.obs_source_get_id then
            local oki, v = pcall(obs.obs_source_get_id, src)
            if oki and type(v) == "string" then was = v end
        end
        if was == "" or id_ok(was) then return src end
        obs.obs_source_release(src)
        if st.rec_card_dead ~= was then
            st.rec_card_dead = was
            log("The REC card was standing as a '%s', which THIS OBS does not have. A source whose type is not registered is shown in RED in the Sources list and its properties cannot be opened - that is OBS reporting a missing type, not a fault in the source. It happens when a scene collection written on one platform is opened on another, because the text source differs between them, and it also happened when this script created the card by an id this build does not carry. It is being replaced now with a text source this OBS does have, in the same place, with the same name. Nothing about the recording changes.",
                was)
        end
        rec_card_remove()
    end
    if st.rec_card_off then return nil end
    if obs.obs_source_create == nil or obs.obs_scene_add == nil then
        st.rec_card_off = true
        return nil
    end
    local d = obs.obs_data_create()
    rec_card_settings(d)
    local made = nil
    for _, id in ipairs(REC_CARD_IDS) do
        if not made and id_ok(id) then
            local ok, s = pcall(obs.obs_source_create, id, REC_CARD_NAME, d, nil)
            if ok and s then made = s end
        end
    end
    obs.obs_data_release(d)
    if not made then
        st.rec_card_off = true
        log("No text source could be created for the on-screen REC card - none of %s exists in this OBS build - so the card is skipped. Nothing else changes: the recording, its size, its frame rate, and every other behavior are exactly as they would be with the card on.",
            table.concat(REC_CARD_IDS, ", "))
        return nil
    end
    local scene_src = obs.obs_get_source_by_name(REC_SCENE_NAME)
    if not scene_src then
        pcall(obs.obs_source_remove, made)
        obs.obs_source_release(made)
        return nil
    end
    local scene = obs.obs_scene_from_source(scene_src)
    if scene and not find_sceneitem(scene, REC_CARD_NAME) then
        local okadd, item = pcall(obs.obs_scene_add, scene, made)
        if okadd and item then
            local pos = obs.vec2()
            pos.x, pos.y = REC_CARD_POS, REC_CARD_POS
            pcall(obs.obs_sceneitem_set_alignment, item,
                  (tonumber(obs.OBS_ALIGN_TOP) or 4)
                  + (tonumber(obs.OBS_ALIGN_LEFT) or 1))
            pcall(obs.obs_sceneitem_set_pos, item, pos)
            pcall(obs.obs_sceneitem_set_visible, item, true)
            pcall(obs.obs_sceneitem_set_locked, item, true)
            pcall(obs.obs_sceneitem_select, item, false)
        end
    end
    obs.obs_source_release(scene_src)
    return made
end

local function rec_card_report(src)
    local w = math.floor(tonumber(obs.obs_source_get_width(src) or 0) or 0)
    local h = math.floor(tonumber(obs.obs_source_get_height(src) or 0) or 0)
    local idx, n, px, py, shown = 0, 0, 0, 0, false
    local scene_src = obs.obs_get_source_by_name(REC_SCENE_NAME)
    if scene_src then
        local scene = obs.obs_scene_from_source(scene_src)
        if scene then
            local items = obs.obs_scene_enum_items(scene)
            if items then
                n = #items
                for i, item in ipairs(items) do
                    local s = obs.obs_sceneitem_get_source(item)
                    if s and obs.obs_source_get_name(s) == REC_CARD_NAME then
                        idx = i
                        shown = obs.obs_sceneitem_visible(item) and true or false
                        local p = obs.vec2()
                        obs.obs_sceneitem_get_pos(item, p)
                        px = math.floor(tonumber(p.x) or 0)
                        py = math.floor(tonumber(p.y) or 0)
                    end
                end
                obs.sceneitem_list_release(items)
            end
        end
        obs.obs_source_release(scene_src)
    end
    log("The on-screen REC card for this take: text source '%s', rendered %dx%d, scene item %d of %d in '%s', anchored at %d,%d, locked, visible %s. That line is the whole diagnosis if it is not on Program: 0x0 means the text source drew nothing, an index below %d means something in the scene is in front of it, and the position is the card's TOP LEFT corner.",
        tostring(obs.obs_source_get_id(src)), w, h, idx, n, REC_SCENE_NAME,
        px, py, tostring(shown), n)
end

local function rec_card_update()
    local live = st.we_record and hv_active()

    if st.fail_card_ms then
        st.fail_card_ms = st.fail_card_ms - TICK_MS
        local rec, str = foreign_output_now()
        if live or rec or str or st.fail_card_ms <= 0 then
            st.fail_card_ms = nil
            if rec or str then
                log("The red refusal card has been taken off Program because %s started. An indicator of this script's own is never left on screen while an output of yours is running, because it would be in your file. The refusal itself stands and its reason is in the lines above.",
                    rec and "a recording of your own" or "a stream of your own")
            end
        end
    end
    local failing = (st.fail_card_ms ~= nil) and not live

    if st.we_record and not live then
        st.rec_card_t0 = nil
        rec_card_remove()
        return
    end

    if live then
        local safe, who = rec_card_view_safe()
        if not safe then
            st.rec_card_off = true
            st.rec_card_t0 = nil
            rec_card_remove()
            log("THE REC CARD HAS BEEN SWITCHED OFF FOR THIS SESSION because this script's recording view is rendering '%s' and not the browser source '%s'. On that arrangement the card would be INSIDE the recording, which it is never allowed to be. The take itself is untouched. This is a defect in the script, not in anything the operator did.",
                tostring(who), REC_SOURCE_NAME)
            return
        end
        if not st.rec_card_t0 then st.rec_card_t0 = os.time() end
    else
        st.rec_card_t0 = nil
        st.rec_card_n = nil
    end

    local want = live and rec_card_text() or (failing and REC_FAIL_TXT or "")
    local owe_text = (want ~= st.rec_card_txt)
    local owe_report = live and (st.rec_card_n or 0) < 3
    if not owe_text and not owe_report then return end

    local src = rec_card_ensure()
    if not src then return end

    if owe_text then
        st.rec_card_txt = want
        local d = obs.obs_data_create()
        rec_card_look(d, want, failing)
        obs.obs_source_update(src, d)
        obs.obs_data_release(d)
    end

    if live then
        st.rec_card_n = (st.rec_card_n or 0) + 1
        if st.rec_card_n == 3 then pcall(rec_card_report, src) end
    end
    obs.obs_source_release(src)
end

local function studio_mode_on()
    if obs.obs_frontend_preview_program_mode_active == nil then return false end
    if obs.obs_frontend_set_current_preview_scene == nil then return false end
    if obs.obs_frontend_preview_program_trigger_transition == nil then return false end
    local ok, on = pcall(obs.obs_frontend_preview_program_mode_active)
    return (ok and on) and true or false
end

local function program_scene_name()
    local nm = nil
    local cs = obs.obs_frontend_get_current_scene
        and obs.obs_frontend_get_current_scene()
    if cs then
        nm = obs.obs_source_get_name(cs)
        obs.obs_source_release(cs)
    end
    return nm
end

local function note_program_scene(nm)
    if not nm or nm == "" then return end
    if nm ~= st.prog_scene then
        st.prog_prev_scene = st.prog_scene
        st.prog_scene = nm
    end
    if nm ~= REC_SCENE_NAME then st.prog_away_scene = nm end
end

local function latch_program_scene()
    note_program_scene(program_scene_name())
end

local function return_program_scene()
    local want = st.ret_scene
    st.ret_scene = nil
    st.ret_armed = nil
    if not want or want == "" then
        log("THE TAKE HAS ENDED AND PROGRAM WAS NOT RETURNED, because st.ret_scene is empty: no previous scene was latched when this source went to Program, so there is no recorded place to go back to. Switch Program by hand to free the trim button.")
        return
    end
    if want == REC_SCENE_NAME then
        log("THE TAKE HAS ENDED AND PROGRAM WAS NOT RETURNED, because st.ret_scene is '%s' - this script's own scene - and switching it to itself would do nothing. Program was already on this scene when the take began. Switch Program by hand to free the trim button.",
            want)
        return
    end
    local cur = nil
    local cs = obs.obs_frontend_get_current_scene
        and obs.obs_frontend_get_current_scene()
    if cs then
        cur = obs.obs_source_get_name(cs)
        obs.obs_source_release(cs)
    end
    if cur and cur ~= REC_SCENE_NAME then
        log("The take has ended and Program was NOT switched, because it is already off this script's scene and on '%s' - you moved it yourself, which is what ended the take. The latch for '%s' is dropped; nothing is owed.",
            cur, want)
        return
    end
    local rec, str = foreign_output_now()
    if rec or str then
        log("The take has ended, but Program was NOT returned to '%s' because %s is running. Switching Program would be a real transition inside your output, which this script will not do. Switch back by hand when you are ready. THIS IS ABOUT AN OUTPUT OF YOURS AND NEVER ABOUT THE TAKE: a take of this script's own records through an output of its own, and a recording this script has already asked OBS to stop does not count here either, so neither of those can hold Program on this scene.",
            want, rec and "a recording of your own" or "a stream of your own")
        return
    end
    local studio = studio_mode_on()
    if not studio and obs.obs_frontend_set_current_scene == nil then
        log("THE TAKE HAS ENDED AND PROGRAM WAS NOT RETURNED to '%s': this OBS build's scripting API has no obs_frontend_set_current_scene, so this script cannot switch Program at all. Switch it by hand to free the trim button.",
            want)
        return
    end
    local target = obs.obs_get_source_by_name(want)
    if not target then
        log("THE TAKE HAS ENDED AND PROGRAM WAS NOT RETURNED, because the scene '%s' that Program was on before the take no longer exists under that name. Switch Program by hand to free the trim button.",
            want)
        return
    end
    if studio then
        pcall(obs.obs_frontend_set_current_preview_scene, target)
        pcall(obs.obs_frontend_preview_program_trigger_transition)
    else
        pcall(obs.obs_frontend_set_current_scene, target)
    end
    obs.obs_source_release(target)
    if not st.ret_said then
        st.ret_said = true
        log("The take has ended and the file is closed, so Program has been returned to '%s' - the scene it was on immediately before the take. This is what frees the trim button, which refuses to arm while the recording source is on Program. IN STUDIO MODE THIS IS A REAL TRANSITION and it uses whatever transition you have configured, so expect your fade: it is this script switching back, not something going wrong. This line is said once per session.",
            want)
    else
        log("Program returned to '%s' now that the take is finished.", want)
    end
end

local function request_return()
    if st.ret_want then return end
    st.ret_want = true
    st.ret_armed = nil
    if studio_mode_on() then return end
    if st.ret_want_said then return end
    st.ret_want_said = true
    log("Program is owed a return to the scene it was on before the take, and that switch is NOT made from this script's 100ms tick. The tick runs on OBS's render thread and the Lua binding holds this script's lock for the whole of it. obs_frontend_set_current_scene hands the switch to OBS's Qt UI thread over a connection that waits for the answer, and in NORMAL - non-Studio - mode the UI thread announces the change to every script before it answers; the Lua binding cannot deliver that announcement without the lock the tick is still holding. Each side waits for the other and OBS stops drawing, which is the freeze a first-run machine saw. Studio Mode takes a different path inside OBS that announces nothing while the render thread waits, which is the only reason this has never been seen on a machine that runs Studio Mode. The switch is therefore made on the same thread OBS gives its own menus: at the next OBS frontend event, which any scene change or output start or stop produces, or when a setting in this script's panel changes, or the moment the trim button is pressed - which is what the return exists to free. Program can therefore sit on this script's scene for a moment after a take instead of leaving at once. If nothing is happening in OBS at all, switch scenes once or press the trim button and it goes immediately. This line is said once per session.")
end


local function service_return()
    if not st.ret_want or st.ret_busy then return false end
    if st.we_record or st.hv_output or st.hv_view or st.hv_running then
        return false
    end
    st.ret_want = nil
    st.ret_busy = true
    local ok, err = pcall(return_program_scene)
    st.ret_busy = false
    if not ok then error(err, 0) end
    return true
end

local function do_start_recording(why)
    st.playing_wait_ms = nil
    if recording_now() then
        if st.prime_phase == "wait" or st.prime_phase == "stop" then
            take_refused("this script's own short test recording had not finished by the time the page asked for this take")
            return
        end
        log("Already recording. Start request ignored (%s).", why)
        return
    end

    local silenced = aud_isolate()
    if silenced > 0 then
        log("REC sound is 'Source only', so the %d other source(s) that carry audio have OBS audio track %d turned off for the length of this take and turned back on a second or two after the file closes - on a default install that is OBS's own Desktop Audio and Mic/Aux, which belong to no scene. NOTHING IS MUTED AND NO FADER IS MOVED: one track per source is the whole change, and your other tracks carry exactly what they always carried, so your own monitoring and your own recording are unaffected. If you open Advanced Audio Properties during a take you will see track %d unticked on those sources, and it is ticked again on its own. The list of what was changed, each with the tracks it had, is written into this script's settings as each one is changed, so if OBS stops before the restore the next load puts them back and says so.",
            silenced, MAX_AUDIO_MIXES, MAX_AUDIO_MIXES)
    end

    if not hv_start(why) then
        take_refused(why)
        return
    end
    st.fail_card_ms = nil
    st.we_record = true
    st.ret_armed = true
    st.rec_card_t0 = nil
    st.rec_card_n = nil
    if cfg.max_duration_sec > 0 then
        st.remaining_ms = cfg.max_duration_sec * 1000
        log("Recording started (%s). Safety cutoff at %ds.", why, cfg.max_duration_sec)
    else
        st.remaining_ms = nil
        log("Recording started (%s).", why)
    end
end

local function do_stop_recording(reason)
    st.aud_delay_ms = AUD_RESTORE_MS
    st.aud_delay_why = string.format("the take ended (%s), and this ran %dms behind that so the file was closed and finalized before any other audio could reach the track again", reason, AUD_RESTORE_MS)
    st.remaining_ms = nil
    st.rec_card_t0 = nil
    if hv_active() then
        hv_stop()
        st.we_record = false
        log("Recording stopped - %s. The file is being finalized.", reason)
        return
    end
    if not obs.obs_frontend_recording_active() then
        st.we_record = false
        return
    end
    if not st.fe_ours then
        log("This script owns no recording, so it stopped nothing (%s). Whatever OBS still reports here is either a recording the user started, which is left alone, or one this script started and already stopped, which is still finalizing.", reason)
        return
    end
    st.fe_stop_asked = true
    obs.obs_frontend_recording_stop()
    st.we_record = false
    log("Recording stopped (%s).", reason)
end

local function schedule_stop(reason, delay_ms)
    if st.pending_stop then return end
    st.pending_stop = math.max(0, delay_ms or cfg.stop_delay_ms)
    st.pending_reason = reason
end

-- OBS applies an edit made in a source's own properties dialog before any script hears of it
local function watch_source_url()
    if not our_take_now() then return end
    if not st.url_live then return end
    local now_url = trim(source_url_now())
    if now_url == "" or now_url == st.url_live then return end
    st.url_live = now_url
    log("THIS TAKE WAS CUT BECAUSE THE SOURCE'S ADDRESS WAS EDITED WHILE IT WAS RUNNING. The browser source's URL field was changed by hand - in the source's own properties dialog, which is OBS's and not this script's - and OBS reloads the page the instant that is applied, before any script is told. The picture being recorded went away with the old page, so there is nothing left to record and the file ends here. THE FILE IS CLOSED AND PLAYABLE; it is simply shorter than you asked for, and everything up to the edit is intact. This script did not write that URL and will not write the old one back: that would be a second reload and would not return the frames already lost. Nothing is wrong with the tool - start the take again once the address is the one you want.")
    do_stop_recording("the source address was edited during the take")
    st.apply_pending = true
end

local function stale_page_refused(what)
    local key = tostring(what) .. "/" .. tostring(st.nonce)
    if st.stale_said == key then return end
    st.stale_said = key
    log("A '%s' report from the recording page WAS REFUSED AND NO TAKE WAS STARTED. This script has not seen one genuine activation of '%s' since it loaded, so the page that sent that report belongs to an earlier run: it was in the browser source before this script existed, and the nonce it quotes came back out of this script's own settings, which is why its events look like this script's own. A recording window reported by a page nobody put there is the one thing that must never start a take. Nothing was written. Take the source off program for a moment and put it back.",
        tostring(what), REC_SOURCE_NAME)
end

local function open_trim_window()
    local vid = resolve_video_id() or ""
    local src = arm_control_layer(vid)
    if not src then service_return() return true end
    if obs.obs_frontend_open_source_interaction then
        local ok = pcall(obs.obs_frontend_open_source_interaction, src)
        if ok then
            log("Opened OBS's Interact window on '%s'. The trim controls are drawn on top of the recording page there, over the picture itself - they are a layer, not a second page. The IN and OUT handles already sit on the range this script is holding. Choose the points and press CONFIRM TO OBS: that stores the range and leaves the controls up, so you can listen, adjust, and confirm again. They go away on a reload, and immediately if this source goes to Program. If they look too small to read, make the Interact window larger - it scales the whole page.",
                REC_SOURCE_NAME)
        else
            log("obs_frontend_open_source_interaction() failed. Right-click '%s' in OBS and choose Interact instead.",
                REC_SOURCE_NAME)
        end
    else
        log("This OBS build has no obs_frontend_open_source_interaction, so the window cannot be opened from here. Right-click '%s' in OBS and choose Interact.",
            REC_SOURCE_NAME)
    end
    obs.obs_source_release(src)
    service_return()
    return true
end

local function service_trim()
    if not st.trim_want or st.trim_busy then return false end
    if not st.port then
        request_launch("the trim controls were asked for before the server was up")
        return false
    end
    st.trim_want = nil
    st.trim_busy = true
    local ok, err = pcall(open_trim_window)
    st.trim_busy = false
    if not ok then error(err, 0) end
    return true
end

local function poll_events()
    local p = paths()
    local data, nxt, reset = read_file_tail(p.events, st.ev_off)
    if not data then return end
    if reset then
        log("The event file is shorter than what had already been read from it, so it was truncated or rewritten underneath this script. It is being read again from the start. Nothing is replayed: every event up to seq=%d has already been accounted for and is skipped by its sequence number, which is what makes a rewrite recoverable instead of a flood of stale events.",
            st.last_seq)
    end
    st.ev_off = nxt

    for line in data:gmatch("[^\r\n]+") do
        local seq = tonumber(line:match("seq=(%d+)") or "")
        if seq and seq > st.last_seq then
            st.last_seq = seq
            local etype = line:match("type=([%w_]+)")
            local nonce = line:match("nonce=([%w]+)")
            local dur   = tonumber(line:match("dur=([%d%.]+)") or "")
            local code  = line:match("code=(%d+)")

            local fresh = (not nonce or nonce == st.nonce)
                          and seq > st.seq_at_activate
            if nonce and nonce ~= st.nonce and st.foreign_nonce_logged ~= nonce then
                st.foreign_nonce_logged = nonce
                log("Ignoring events tagged with another page load (nonce %s, this script's is %s).",
                    nonce, st.nonce)
            end
            if fresh then
                if etype == "loaded" then
                    log("Page loaded (page report).")
                    st.ended_nonce = nil
                    st.ended_refused_nonce = nil
                    st.ctl_shown_nonce = nil
                elseif etype == "ctl_on" then
                    local tseed = line:match("&mark=([%d%.]+)")
                                  or line:match("&t=([%d%.]+)")
                    st.ctl_shown_nonce = st.nonce
                    log("The trim controls are now drawn on the recording page (opened at %ss). They are a LAYER on that one page, not a second page, and the arm was one-shot: a reload makes them disappear because there is nothing left to consume. Choose IN and OUT and press CONFIRM TO OBS. They also disappear the instant this source goes to Program - that refusal is what keeps them out of every recording.",
                        tseed or "0")
                elseif etype == "ctl_off" then
                    local cwhy = line:match("&why=([%w_]+)") or "?"
                    st.ctl_shown_nonce = nil
                    ctl_show_drop()
                    if cwhy == "gate" then
                        log("The trim controls were taken down because this source went to PROGRAM. The page does that before it asks for anything to play, and it is one-way - the controls cannot come back in this page load even if another arm arrives. Anything you had selected and not confirmed is gone with them.")
                    else
                        log("The trim controls were taken down (%s).", cwhy)
                    end
                elseif etype == "ctl_leak" then
                    local cat = line:match("&at=([%w_]+)") or "?"
                    st.ctl_shown_nonce = nil
                    log("DEFECT: the page reached '%s' with the trim controls still drawn, which must not be possible - the program gate opening takes them down one-way before anything plays. The page's own assert caught it and removed them, so this take is not damaged, but the guarantee that the controls never reach a recording was broken somewhere. Report this line.",
                        cat)
                elseif etype == "ctl_grid" then
                    log("The trim picture could not be placed on whole device pixels at %sx%s (pixel ratio %s): no control-panel height inside its usable range gives a scale that is whole on both axes for this canvas and video, and the picture is not shrunk to make one. It is drawn at its natural size on the nearest scale that keeps the iframe layer whole, so the 1px line across its centre can still show. Said once per size. Informational.",
                        line:match("&w=(%d+)") or "?", line:match("&h=(%d+)") or "?",
                        line:match("&dpr=([%d%.]+)") or "?")
                elseif etype == "go" then
                    log("The page saw the program gate open and started its run-up. Everything before this was the first frame held still and silent in preview.")
                elseif etype == "go_unavailable" then
                    local stt = line:match("st=(%d+)") or "?"
                    log("The page asked the local server whether the source is on program and the server answered %s, which means it is an OLDER server process than the page it served. Nothing will start the take on a clean picture until that server is gone: close OBS and reopen it, or wait for the heartbeat watchdog to replace the server. The %dms activation fallback still records something in the meantime.",
                        stt, PLAYING_FALLBACK_MS)
                elseif etype == "ready" then
                    if dur and dur > 0 then
                        log("Video length: %.1fs (page report, 'ready'). Two of these in a row means the page loaded twice, not that anything was read twice.", dur)
                    end
                    local ov = effective_out_sec()
                    if dur and dur > 0 and ov > 0 and ov >= dur
                       and st.out_warned_for ~= ov then
                        st.out_warned_for = ov
                        log("The out-point is %ss but the video is only %.1fs long, so that position is never reached. This take ends the ordinary way, when the video itself finishes, and the frame-accurate out-point does nothing. Pick an out-point inside the video in the control window.",
                            num_str(ov), dur)
                    end
                    local iv = effective_start_sec()
                    local rkey = num_str(iv) .. "/" .. string.format("%.1f", dur or 0)
                    if dur and dur > 0 and iv > 0 and iv >= dur
                       and st.range_warned_for ~= rkey then
                        st.range_warned_for = rkey
                        log("THE IN-POINT IS OUTSIDE THIS VIDEO: %ss, but the video is only %.1fs long. The page can never reach that position, so the mask never lifts on it and this take will not start the way you asked - what you will see is 'the recording does not start'. The usual cause is an in-point chosen against a DIFFERENT, longer video. Open the trim control window and choose an in-point inside this video.",
                            num_str(iv), dur)
                    end
                elseif etype == "playing" then
                    local over = tonumber(line:match("over=(%d+)") or "")
                    local pad  = tonumber(line:match("pad=(%d+)") or "")
                    local iw   = tonumber(line:match("iw=(%d+)") or "")
                    local ih   = tonumber(line:match("ih=(%d+)") or "")
                    log("Playback started (page report). Player chrome is pushed %dpx off the top and bottom of the captured window%s.",
                        pad or over or OVERSCAN_PX,
                        (iw and ih and iw > 0 and ih > 0)
                            and string.format(" (iframe %dx%d)", iw, ih) or "")
                    if over and over ~= OVERSCAN_PX then
                        log("The page used a %dpx overscan, not this script's %dpx: the source URL is from an older page build. It is rewritten the next time the source is off program and not recording.",
                            over, OVERSCAN_PX)
                    end
                elseif etype == "recstart" then
                    local rat   = line:match("at=([%d%.]+)")
                    local rhead = line:match("head=([%d%.]+)")
                    local rstamp = line:match("^seq=%d+ t=([%d%:%.]+)")
                    log("Recording asked for %ss before the in-point, at position %ss, with the mask still up. Everything from here until the mask lifts is black on purpose: it is where OBS's own recording-start latency goes, so the first frame of CONTENT is the frame the page uncovers and not whichever frame OBS happened to open the file on.",
                        rhead or "?", rat or "?")
                    if not st.live_edge then
                        stale_page_refused("recstart")
                    elseif configured_source_on_program() then
                        st.preview_warned_nonce = nil
                        do_start_recording("in-point lead")
                        if recording_now() then
                            log("DELIVERY FOR THIS TAKE: the page's 'recstart' was appended to the event file at %s on the server's clock, and OBS stamps THIS line as the output opens - the gap between those two times IS the delivery, measured here and not assumed. It was paid for with a %sms head against a %dms worst-case budget. If that gap ever approaches the head, raise REC_HEAD_SEC in PLAYER_HTML; if it stays far below it, the head has room to come down.",
                                rstamp or "(the event line carried no stamp)",
                                rhead and num_str(tonumber(rhead) * 1000) or "?",
                                DELIVERY_MS)
                        end
                        st.unmask_wait_ms = UNMASK_WAIT_MS
                    elseif st.preview_warned_nonce ~= st.nonce then
                        st.preview_warned_nonce = st.nonce
                        log("The in-point lead arrived but the source is not on program output (preview only), so no recording was started. It starts when the source goes live on program.")
                    end
                elseif etype == "visible" then
                    local via = line:match("via=([%w_]+)")
                    local at  = line:match("at=([%d%.]+)")
                    local head = tonumber(line:match("head=(%-?%d+)") or "")
                    st.unmask_wait_ms = nil
                    if via == "safety" then
                        log("The page never reached its normal unmask, so its own last-resort safety net lifted the mask%s. The recording starts on LIVE PICTURE instead of on black, which is what this is for - but it is NOT a clean start: no pre-roll ran, nothing was seeked back, and if an ad was on screen the ad is what gets recorded.",
                            at and (" at " .. at .. "s") or "")
                    elseif via == "deadline" then
                        log("The mask was lifted by its deadline%s, not by reaching the in-point: playback stalled for longer than the page is willing to keep a running recording behind a black rectangle. The content therefore starts at this position and NOT at the in-point, and this take is not frame-accurate. The usual cause is buffering during the run-up.",
                            at and (" at " .. at .. "s") or "")
                    else
                        log("Mask lifted (page report, %s%s). The picture is clean.",
                            via or "unknown",
                            at and (" at " .. at .. "s") or "")
                    end
                    if head then
                        if head < DELIVERY_MS then
                            log("WARNING ON THIS TAKE'S HEAD: only %dms passed between the recording being asked for and the mask lifting, against the %dms this design needs to get the start request delivered. The recording may not have been running yet when the content started, so the first frames of the range can be missing. The usual cause is an in-point so close to the load position that there was no run-up left to ask early in.",
                                head, DELIVERY_MS)
                        else
                            log("Mask lifted %dms after the recording was asked for, so that many milliseconds of black are in front of the content and the first frame of the range is intact.",
                                head)
                        end
                    end
                    if not st.live_edge then
                        stale_page_refused("visible")
                    elseif configured_source_on_program() then
                        st.preview_warned_nonce = nil
                        do_start_recording("recording window open")
                    elseif st.preview_warned_nonce ~= st.nonce then
                        st.preview_warned_nonce = st.nonce
                        log("The recording window opened but the source is not on program output (preview only), so the recording was not started. It starts when the source goes live on program.")
                    end
                elseif etype == "probe" then
                    local perr = line:match("&err=(%d+)")
                    local pw = tonumber(line:match("&w=(%d+)") or "")
                    local ph = tonumber(line:match("&h=(%d+)") or "")
                    local pah = line:match("&ah=(@[%w_%.%-]+)")
                    local pvid = line:match("&pv=([%w_%-]+)")
                    local cur_vid = trim(st.video_id)
                    local wrong_video = (pvid and cur_vid ~= "" and pvid ~= cur_vid)
                                        and true or false
                    if not wrong_video and st.cr_handle == nil then
                        st.cr_handle = pah or ""
                        if st.cr_handle == "" then
                            if st.cr_handle_warned ~= cur_vid then
                                st.cr_handle_warned = cur_vid
                                log("No @handle could be had for this video, so the source credit falls back to the channel's display name. That is the designed fallback and not a fault: a channel that has never claimed a handle has none to report, and an attribution in the wrong shape is still an attribution. Said once per video.")
                            end
                        else
                            log("Channel handle for the source credit: %s. The page draws it, so it is in the recording itself.",
                                st.cr_handle)
                            local su2 = source_url_now()
                            if su2:find(PLAYER_PATH, 1, true)
                               and cur_vid ~= "" and su2:find("v=" .. cur_vid, 1, true)
                               and not su2:find("crh=", 1, true) then
                                st.apply_pending = true
                            end
                        end
                    end
                    if wrong_video then
                        log("A native-size answer arrived for video %s but the current video is %s, so it is ignored.",
                            pvid, cur_vid)
                    elseif perr or not (pw and ph and pw > 0 and ph > 0) then
                        log("Could not determine the video's native size (YouTube's page did not report one). Nothing changes - this line is informational only.")
                    else
                        st.video_w = pw
                        st.video_h = ph
                        st.aspect_warned_for = nil
                        persist_video_aspect()
                        local cw, ch = 1920, 1080
                        local ovi = obs.obs_video_info()
                        if obs.obs_get_video_info(ovi) then
                            cw, ch = ovi.base_width, ovi.base_height
                        end
                        local va = pw / ph
                        local ca = (ch > 0) and (cw / ch) or 0
                        log("Video is %dx%d (%.3f); canvas is %dx%d (%.3f). (native-size probe answer.) Two of these in a row means the size was asked for twice, which a page reload does.",
                            pw, ph, va, cw, ch, ca)
                        if ca > 0 and math.abs(va - ca) / ca > 0.01 then
                            log("The canvas and the video have different shapes. With 'Fit centered to the OBS canvas' on, the file is the canvas size with the video centered inside it and bars on the spare axis; with it off, the file is %dx%d, the video's own size. Either way nothing is cropped and there is nothing to change.",
                                pw, ph)
                        end

                        local su = source_url_now()
                        local vid = trim(st.video_id)
                        if su:find(PLAYER_PATH, 1, true)
                           and vid ~= "" and su:find("v=" .. vid, 1, true)
                           and not su:find("vw=", 1, true) then
                            st.apply_pending = true
                            log("The loaded page URL carries no aspect, so it is rewritten with vw=%d&vh=%d the next time the source is off program and not recording. From then on the page is correct on its first frame.",
                                pw, ph)
                        end
                    end
                elseif etype == "ad_playing" then
                    log("An ad is playing. The mask stays up and nothing is recorded until the real video begins. The run-up clock is suspended while the ad runs and re-arms when the real video resumes, so the full run-up is always played against the real video.")
                elseif etype == "ended" then
                    local why = line:match("why=(%w+)") or "state"
                    if why == "offprog" then
                        log("The source left program output, so the page stopped the take itself: the picture is covered, the player is muted, and playback is paused. That is the contract - preview is the first frame only, held still and silent - and the recording had already been stopped on the deactivation edge. The page does not restart itself: the next take is a fresh page load, exactly as after any other end of take.")
                    elseif why == "outpoint" then
                        local at = line:match("at=([%d%.]+)")
                        log("Out-point reached at %ss: the mask was hard-cut back on, on the frame. The content in the file ends exactly there and everything after it is black, so the %dms tail and OBS's own stop jitter both land outside the content.",
                            at or num_str(effective_out_sec()), OUT_TAIL_MS)
                    else
                        log("End detected (page report, %s).", why)
                    end
                    st.ended_nonce = st.nonce
                    if why == "outpoint" then
                        schedule_stop(STOP_REASON.out, OUT_TAIL_MS)
                    else
                        schedule_stop(STOP_REASON.ended)
                    end
                elseif etype == "error" then
                    if code == "153" then
                        log("YouTube error 153: origin rejected. The local server may not be running, or the source URL is not http://localhost:%s. Take the source off the scene and the script rewrites the URL.",
                            st.port and tostring(st.port) or "(port unknown)")
                    elseif code == "101" or code == "150" then
                        log("YouTube error %s: this video cannot be embedded. Use another video.", tostring(code))
                    else
                        log("YouTube error code %s", tostring(code))
                    end
                elseif etype == "autoplay_retry_muted" then
                    log("Autoplay was blocked, so it retried muted.")
                elseif etype == "unmuted" then
                    local via = line:match("via=([%w_]+)") or "?"
                    if via == "safety" then
                        log("The page's last-resort safety net ran at its own timeout, so the player was unmuted and the take is not silent. If the mask had also never lifted, the next line says so.")
                    end
                elseif etype == "trim" then
                    local ti = tonumber(line:match("&in=([%d%.]+)") or "")
                    local to = tonumber(line:match("&out=([%d%.]+)") or "")
                    st.in_sec  = (ti and ti > 0) and ti or nil
                    st.out_sec = (to and to > 0) and to or nil
                    st.runup_logged = nil
                    st.out_warned_for = nil
                    if script_settings then
                        obs.obs_data_set_double(script_settings, "in_sec",
                            st.in_sec or -1)
                        obs.obs_data_set_double(script_settings, "out_sec",
                            st.out_sec or -1)
                    end
                    log("Trim range confirmed from the control window: in=%ss out=%ss.",
                        st.in_sec and num_str(st.in_sec) or "(not set)",
                        st.out_sec and num_str(st.out_sec) or "(not set)")
                    if st.in_sec and st.in_sec < RUNUP_SEC then
                        log("That in-point is below the %ds run-up, so this take CANNOT start on a clean picture: there is not %ds of video in front of it to run up through, and YouTube's center overlay will still be on screen. The in-point itself is still honored exactly - the page loads at 0 and cuts the mask on the frame at %ss - so the POSITION is accurate and only the picture suffers. Nothing can work around the picture: every alternative is player activity that re-arms the overlay, which is why the old pre-roll-and-seek path was no cleaner here and was 430-450ms late as well.",
                            RUNUP_SEC, RUNUP_SEC, num_str(st.in_sec))
                    end
                    st.apply_pending = true
                    log("This range is stored. The trim controls STAY UP - confirming no longer reloads the page - so you can listen, adjust, and confirm again. The recording page is rewritten with whatever was confirmed last, either as soon as the controls go away or at the latest when this source goes to Program, so no take runs on an old range.")
                elseif etype == "update" then
                    UPD.answer(line)
                elseif etype == "bad_param" then
                    local which = line:match("which=([%w_]+)") or "?"
                    log("The player page loaded with no usable '%s' value in its URL, so nothing can play. The source URL is stale; it is rewritten the next time the source is off program and not recording.",
                        which)
                end
            end
        end
    end
end

local function adopt_existing_events()
    local data = read_file(paths().events)
    if not data or data == "" then return end
    st.ev_off = #data
    local maxseq, n = 0, 0
    for line in data:gmatch("[^\r\n]+") do
        local seq = tonumber(line:match("seq=(%d+)") or "")
        if seq then
            n = n + 1
            if seq > maxseq then maxseq = seq end
        end
    end
    if maxseq > 0 then
        st.last_seq = maxseq
        st.seq_at_activate = maxseq
        log("Event file from the previous run found: %d earlier event(s) skipped (up to seq=%d). SKIPPING IS THE WHOLE POINT OF THIS STEP and it never adopts anything: the file outlives OBS, every line in it was written by a page of an earlier run, and reading them as if they had just arrived is how a script reload would replay an end-of-take or a recording window that nobody asked for. The sequence number is the only thing taken from them. A take needs more than a matching nonce in any case - it needs one genuine activation of the recording source in THIS session - so nothing in this file can start one.",
            n, maxseq)
    end
end

local function tick_body()
    st.tick_count = st.tick_count + 1

    if st.relaunch_ms then
        st.relaunch_ms = st.relaunch_ms - TICK_MS
        if st.relaunch_ms <= 0 then
            st.relaunch_ms = nil
            request_launch("the heartbeat watchdog asked for a restart")
        end
    end

    if st.launch_id and st.tick_count % BEAT_CHECK_EVERY == 0 then
        st.owner_n = (st.owner_n or 0) + 1
        write_file(paths().owner, st.launch_id .. "\r\n" .. st.owner_n .. "\r\n")
    end

    if st.port_wait_ms then
        st.port_wait_ms = st.port_wait_ms - TICK_MS
        local txt = read_file(paths().port)
        local n = txt and tonumber(trim(txt)) or nil
        if n and n > 0 then
            st.port_wait_ms = nil
            st.port_wait_logged = nil
            st.port = n
            st.last_port = n
            if script_settings then
                obs.obs_data_set_int(script_settings, "last_port", n)
            end
            log("Local server port confirmed: %d (http://localhost:%d/)", n, n)
        elseif st.port_wait_ms <= 0 then
            if not st.port_wait_logged then
                st.port_wait_logged = true
                log("Local server never reported a port (%s). It may have failed to start. Check the server log: %s",
                    paths().port, paths().slog)
            end
            if st.server_launched then
                st.port_wait_ms = PORT_WAIT_MS
            else
                st.port_wait_ms = nil
            end
        end
    end

    if st.health_ms then
        st.health_ms = st.health_ms - TICK_MS
        if st.health_ms <= 0 then
            st.health_ms = nil
            check_server_health()
        end
    end

    if st.beat_since_recover_ms then
        st.beat_since_recover_ms = st.beat_since_recover_ms + TICK_MS
    end

    if st.server_launched and not st.relaunch_ms
       and not st.beat_gave_up and st.tick_count % BEAT_CHECK_EVERY == 0 then
        local beat = read_file(paths().beat)
        beat = beat and trim(beat) or ""
        if beat ~= "" and beat ~= st.last_beat then
            st.last_beat = beat
            st.beat_stale_ms = 0
            st.beat_dead = false
            st.beat_deferred = false
            if st.beat_since_recover_ms
               and st.beat_since_recover_ms >= BEAT_SETTLE_MS then
                st.beat_recover_n = 0
                st.beat_since_recover_ms = nil
            end
        else
            st.beat_stale_ms = st.beat_stale_ms + BEAT_CHECK_EVERY * TICK_MS
            if st.beat_stale_ms >= BEAT_STALE_MS then
                if our_take_now() then
                    if not st.beat_deferred then
                        st.beat_deferred = true
                        log("Local server stopped responding. Recovery is deferred because one of this script's own takes is in progress: a restart hands the server a new port, and rewriting the source's URL for it would reload the page and destroy this take's picture. This recording will not stop when the video ends; only the max recording time will stop it. A recording or a stream of your own does not defer this - the server is restarted right away so the tool is not left dead for the length of your show.")
                    end
                elseif not st.beat_dead then
                    st.beat_dead = true
                    if st.beat_since_recover_ms
                       and st.beat_since_recover_ms < BEAT_SETTLE_MS then
                        st.beat_recover_n = st.beat_recover_n + 1
                    else
                        st.beat_recover_n = 1
                    end
                    if st.beat_recover_n > BEAT_MAX_RECOVER then
                        st.beat_gave_up = true
                        log("Could not keep the local server alive (%d failures in a row). Auto-restart stopped. Reload the script.",
                            BEAT_MAX_RECOVER)
                    else
                        log("Local server stopped responding. Restarting it automatically. (%d/%d)",
                            st.beat_recover_n, BEAT_MAX_RECOVER)
                        st.beat_since_recover_ms = 0
                        st.relaunch_ms = 1500
                    end
                end
            end
        end
    end

    hv_prime_poll()

    hv_poll()

    rec_card_update()

    if st.upd_busy_ms then UPD.tick() end

    service_trim()

    if st.ret_armed and not st.we_record and not st.hv_output
       and not st.hv_view and not st.hv_running then
        request_return()
        if st.ret_want and studio_mode_on() then service_return() end
    end

    if st.aud_delay_ms then
        st.aud_delay_ms = st.aud_delay_ms - TICK_MS
        if st.aud_delay_ms <= 0 then
            local why = st.aud_delay_why
            st.aud_delay_ms = nil
            st.aud_delay_why = nil
            aud_restore(why or "the take ended")
        end
    end

    if not cfg.enabled then return end

    if st.tick_count % EVENT_POLL_EVERY == 0 then
        poll_events()
    end

    if st.apply_pending and st.port
       and not recording_now() and not ctl_layer_up() then
        local tgt = obs.obs_get_source_by_name(REC_SOURCE_NAME)
        local live = false
        if tgt then
            live = obs.obs_source_active(tgt)
            obs.obs_source_release(tgt)
        end
        if not live then
            st.apply_pending = false
            create_or_update_source()
        end
    end

    if st.tick_count % 5 == 0 then
        watch_source_url()
        deliver_panel_url()
        auto_convert_source_url()
    end

    latch_program_scene()

    local name = REC_SOURCE_NAME
    local src = obs.obs_get_source_by_name(name)
    local active = (src ~= nil) and obs.obs_source_active(src) or false
    if src then obs.obs_source_release(src) end

    if st.pending_stop and st.pending_reason == STOP_REASON.scene
       and active and source_in_current_scene(name) then
        st.pending_stop = nil
        st.pending_reason = nil
        log("The new scene has the same source. Canceling the recording stop.")
    end

    if st.prev_active == nil then
        if active then
            log("The source '%s' was ALREADY on program when this script loaded. This is NOT treated as an activation, so no recording starts from it: nothing has replaced the page in the browser source, and a page left over from before the reload is in an unknown state - if it had already reached the end it is behind its own end-of-take mask and the picture is BLACK. TAKE THE SOURCE OFF PROGRAM FOR A MOMENT AND PUT IT BACK. That does both things at once: the URL is rewritten and a fresh page loads, and this script gets the genuine activation it starts a take on.",
                name)
        end
    elseif active and not st.prev_active then
        st.live_edge = true
        log("Source activated: '%s'", name)
        if st.ctl_shown_nonce and st.ctl_shown_nonce == st.nonce then
            log("THIS SOURCE WENT TO PROGRAM WITH THE TRIM CONTROLS STILL DRAWN. The page removes them the moment it learns the source is live, which it learns from a poll every 250ms, so they were on the program output for up to about a quarter of a second before they went. No recording this script starts can have captured them - a take begins on the page's own in-point report, which cannot be sent until that same poll has told the page it is live - and the source is set to refresh on activation, so OBS reloads the page here too. Nothing to do; this line exists so the log accounts for what you saw.")
            st.ctl_shown_nonce = nil
        end
        ctl_show_drop()
        st.ret_scene = st.prog_away_scene
        st.ret_armed = nil
        st.ret_want = nil
        if st.ctl_audio or st.apply_pending then
            local owed_audio = st.ctl_audio
            st.ctl_audio = false
            st.apply_pending = false
            create_or_update_source()
            if owed_audio then
                log("The trim session had this source's audio routed straight out of the browser so it could be heard in preview, where OBS mixes nothing. It has been put back into OBS's audio mixer now, at the activation edge - which is in front of the whole run-up, so it is settled long before the recording is even asked for. Re-routing rebuilds this source's mixer entry, so its fader and monitoring choice in Advanced Audio Properties are back at their defaults; that is the cost of hearing the video while trimming.")
            else
                log("The page URL still carried the range from before the last CONFIRM, so it was rewritten here, at the activation edge, before the take. That is one extra page load for this take only - the confirm itself no longer reloads the page, which is what lets the trim controls stay up while you listen and adjust.")
            end
        end
        if st.pending_stop and st.pending_reason == STOP_REASON.ended
           and not recording_now() then
            st.pending_stop = nil
            st.pending_reason = nil
        end
        hv_prime_check()
        st.seq_at_activate = st.last_seq
        st.playing_wait_ms = PLAYING_FALLBACK_MS
    elseif (not active) and st.prev_active then
        log("Source deactivated: '%s'", name)
        st.playing_wait_ms = nil
        st.unmask_wait_ms = nil
        schedule_stop("source deactivated", 0)
    end
    st.prev_active = active

    local go_want = nil
    if active and st.live_edge then
        local n = trim(st.nonce or "")
        if n ~= "" and n ~= "0" then go_want = n end
    end
    if active and not st.live_edge and not st.live_edge_said then
        st.live_edge_said = true
        log("THE PROGRAM GATE IS BEING HELD SHUT for '%s' because this script has not seen one genuine activation of it yet. The source was on program when the script loaded, so whatever page is in it was loaded by an earlier run and this script's own nonce comes back out of its settings - which means an old page and a new one cannot be told apart by their events alone. Holding the gate shut is what stops a leftover page from running itself up and reporting a recording window this script would then record. TAKE THE SOURCE OFF PROGRAM FOR A MOMENT AND PUT IT BACK: that is the activation, and from then on everything behaves normally.",
            name)
    end
    if go_want ~= st.go_written
       or (go_want and st.tick_count % BEAT_CHECK_EVERY == 0) then
        local gp = paths().go
        if go_want then
            if write_file(gp, go_want) then
                st.go_written = go_want
            else
                st.go_written = nil
            end
        else
            remove_quiet(gp)
            st.go_written = nil
        end
    end

    if st.playing_wait_ms then
        st.playing_wait_ms = st.playing_wait_ms - TICK_MS
        if st.playing_wait_ms <= 0 then
            st.playing_wait_ms = nil
            if st.ended_nonce and st.ended_nonce == st.nonce then
                if st.ended_refused_nonce ~= st.nonce then
                    st.ended_refused_nonce = st.nonce
                    log("NO RECORDING WAS STARTED FOR THIS ACTIVATION, and the gap where a take should be is deliberate. The page already in the browser source reported that its take had ENDED, and a page does not restart itself: it is behind its own end-of-take mask with the picture BLACK, the player muted, and playback paused, and it will not report anything again. Recording it would have captured a paused black frame, and nothing would have stopped that recording early - only the maximum recording time would have ended it. TAKE THE SOURCE OFF PROGRAM FOR A MOMENT AND PUT IT BACK: the URL is rewritten while it is off program, a fresh page loads, and that activation records normally. The rewrite is already marked as wanted here, so it happens by itself the moment this source leaves program.")
                end
                st.apply_pending = true
            else
                if st.last_seq > st.seq_at_activate then
                    log("The page never reported that the mask lifted, but it did report other things since this source went live - so the page is running and talking, and the mask itself is what did not come off. Starting the recording on activation instead.")
                else
                    log("The page has reported NOTHING AT ALL since this source went live, so whatever is in the browser source is not talking to this script. This was a genuine activation, so OBS reloaded the source and the page is a new one - which leaves: the local server is not listening (check the server log, %s), or the source URL still carries a port or nonce from an earlier run and was not rewritten, or 'Refresh browser when scene becomes active' has been turned off on the source so the old page was never replaced. Starting the recording on activation anyway.",
                        paths().slog)
                end
                do_start_recording("fallback: activation")
            end
        end
    end

    if st.unmask_wait_ms then
        st.unmask_wait_ms = st.unmask_wait_ms - TICK_MS
        if st.unmask_wait_ms <= 0 then
            st.unmask_wait_ms = nil
            if recording_now() and st.we_record then
                log("NO PICTURE EVER REACHED THIS RECORDING, so it is being stopped instead of left to fill the disk. The page asked for the recording %dms ago with its black mask up - which is the design, the mask is the content boundary - and then never reported that the mask came off. The page guarantees that lift within %dms of asking and has its own last-resort net on top of that, so a silence this long means the page itself stopped running: the browser source was torn down, reloaded, or the local server went away mid-run-up. The file that has been written so far is entirely black. TAKE THE SOURCE OFF PROGRAM FOR A MOMENT AND PUT IT BACK to load a fresh page and record the range properly.",
                    UNMASK_WAIT_MS, 3000)
                do_stop_recording("no picture: the mask never lifted")
                st.apply_pending = true
            end
        end
    end

    if st.remaining_ms and recording_now() then
        st.remaining_ms = st.remaining_ms - TICK_MS
        if st.remaining_ms <= 0 then
            st.remaining_ms = nil
            schedule_stop("max recording time reached")
        end
    end

    if st.pending_stop then
        st.pending_stop = st.pending_stop - TICK_MS
        if st.pending_stop <= 0 then
            local reason = st.pending_reason or "scheduled stop"
            st.pending_stop = nil
            st.pending_reason = nil
            do_stop_recording(reason)
        end
    end
end

local function tick()
    return guard("the 100ms tick", tick_body, nil, true)
end

local function on_frontend_event_body(event)
    if event == obs.OBS_FRONTEND_EVENT_FINISHED_LOADING then
        st.coll_ready = true
    end
    if event ~= obs.OBS_FRONTEND_EVENT_EXIT
       and event ~= obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN then
        service_launch()
        service_create()
        service_return()
        service_trim()
        UPD.request(os.time())
    end
    if event == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED then
        local ours = st.fe_ours or st.fe_stop_asked
        if not ours and not our_take_now() then
            aud_restore("the recording stopped")
            st.we_record = false
            st.remaining_ms = nil
            st.pending_stop = nil
            st.pending_reason = nil
            st.unmask_wait_ms = nil
        end
    elseif event == obs.OBS_FRONTEND_EVENT_SCENE_CHANGED then
        local nowscene = obs.obs_frontend_get_current_scene()
        if nowscene then
            local nm = obs.obs_source_get_name(nowscene)
            obs.obs_source_release(nowscene)
            note_program_scene(nm)
        end
        if st.we_record and recording_now() then
            schedule_stop(STOP_REASON.scene, 0)
        end
    elseif event == obs.OBS_FRONTEND_EVENT_EXIT then
        ctl_show_drop()
        aud_restore("OBS is shutting down")
        hv_stop()
        hv_release_all()
        st.rec_card_t0 = nil
        rec_card_remove()
        stop_server()
        if st.timer_on then
            obs.timer_remove(tick)
            st.timer_on = false
        end
    end
end

local function on_frontend_event(event)
    return guard("a frontend event", on_frontend_event_body, event)
end

function script_description()
    return "Castika Simple Browser Recorder (Lua Script) " .. SCRIPT_VERSION
end

function script_defaults(settings)
    obs.obs_data_set_default_bool(settings, "enabled", true)
    obs.obs_data_set_default_bool(settings, "update_check", true)

    obs.obs_data_set_default_bool(settings, "fit_canvas", true)
    obs.obs_data_set_default_string(settings, "res_mode", "canvas")
    obs.obs_data_set_default_string(settings, "custom_height", "1080")
    obs.obs_data_set_default_int(settings, "fps", 0)

    obs.obs_data_set_default_string(settings, "yt_url", "")

    obs.obs_data_set_default_int(settings, "max_duration_sec", 7200)

    obs.obs_data_set_default_string(settings, "rec_sound", "source")

    obs.obs_data_set_default_bool(settings, "cr_on", false)
    obs.obs_data_set_default_string(settings, "cr_mode", "yh")
    obs.obs_data_set_default_string(settings, "cr_text", "")
    obs.obs_data_set_default_string(settings, "cr_pos", "bl")
    obs.obs_data_set_default_int(settings, "cr_voff", 0)
    obs.obs_data_set_default_int(settings, "cr_color", 0xFFFFFFFF)
    obs.obs_data_set_default_int(settings, "cr_bg", 0x8C000000)
end

local function cap(props, field, text, warn)
    local p = obs.obs_properties_add_text(props, "_cap_" .. field, text, obs.OBS_TEXT_INFO)
    if warn and p and obs.obs_property_text_set_info_type
       and obs.OBS_TEXT_INFO_WARNING then
        pcall(obs.obs_property_text_set_info_type, p, obs.OBS_TEXT_INFO_WARNING)
    end
    return p
end

local GROUP_KEYS = { "grp_src", "grp_pic", "grp_cred", "grp_rec" }

-- obs_properties_get may not recurse into groups
local function find_prop(props, name)
    if not props or not name then return nil end
    local p = obs.obs_properties_get(props, name)
    if p then return p end
    for _, gk in ipairs(GROUP_KEYS) do
        local g = obs.obs_properties_get(props, gk)
        if g then
            local content = obs.obs_property_group_content(g)
            if content then
                p = obs.obs_properties_get(content, name)
                if p then return p end
            end
        end
    end
    return nil
end

local function apply_take_lock(props)
    local locked = our_take_now()
    local function enable(n, on)
        local p = find_prop(props, n)
        if p and obs.obs_property_set_enabled then
            pcall(obs.obs_property_set_enabled, p, on)
        end
    end
    enable("yt_url", not locked)
    enable("btn_open_control", not locked)
    local c = find_prop(props, "_cap_takelock")
    if c then obs.obs_property_set_visible(c, locked) end
    return locked
end

local function refresh_visibility(props, settings)
    if not settings then return true end
    local function vis(n, v)
        local p = find_prop(props, n)
        if p then obs.obs_property_set_visible(p, v) end
        local c = find_prop(props, "_cap_" .. n)
        if c then obs.obs_property_set_visible(c, v) end
    end
    local fit = obs.obs_data_get_bool(settings, "fit_canvas")
    vis("res_mode", not fit)
    vis("custom_height", (not fit)
        and obs.obs_data_get_string(settings, "res_mode") == "custom")
    local cr = obs.obs_data_get_bool(settings, "cr_on")
    vis("cr_mode", cr)
    vis("cr_text", cr
        and obs.obs_data_get_string(settings, "cr_mode") == "x")
    vis("cr_font", cr)
    vis("cr_color", cr)
    vis("cr_bg", cr)
    vis("cr_pos", cr)
    vis("cr_voff", cr)
    return true
end

local function on_prop_modified(props, prop, settings)
    apply_take_lock(props)
    return refresh_visibility(props, settings)
end

local function script_properties_body()
    local props = obs.obs_properties_create()

    obs.obs_properties_add_bool(props, "enabled",
        "Enable script - turning this off ends a take that is in progress")

    local grp = obs.obs_properties_create()

    cap(grp, "yt_url", string.format(
        "Paste a YouTube URL. This script creates the scene '%s'.",
        REC_SCENE_NAME))
    obs.obs_properties_add_text(grp, "yt_url", "",
        obs.OBS_TEXT_DEFAULT)

    obs.obs_properties_add_button(grp, "btn_open_control",
        "Open the trim controls", function(p2, prop)
            guard("the trim button", function()
                st.trim_want = true
                service_trim()
            end)
            return true
        end)

    cap(grp, "btnhelp",
        "Set the in and out points here, then send that scene to Program - the recording starts on its own.",
        true)

    cap(grp, "takelock",
        "A take is running. The URL box and the trim button are locked until it ends, because changing either one reloads the page and would cut the recording. Anything you type here is stored and applied once the take is over. A recording or a stream of your own does not lock this panel.",
        true)

    obs.obs_properties_add_group(props, "grp_src", "RECORDING SOURCE",
        obs.OBS_GROUP_NORMAL, grp)

    local gpic = obs.obs_properties_create()

    local fitc = obs.obs_properties_add_bool(gpic, "fit_canvas",
        "Fit centered to the OBS canvas")
    obs.obs_property_set_modified_callback(fitc, on_prop_modified)

    cap(gpic, "res_mode", "Source resolution")
    local res = obs.obs_properties_add_list(gpic, "res_mode", "",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(res, "Video's native size", "canvas")
    obs.obs_property_list_add_string(res, "Custom", "custom")
    obs.obs_property_set_modified_callback(res, on_prop_modified)

    cap(gpic, "custom_height", "Height")
    local chl = obs.obs_properties_add_list(gpic, "custom_height", "",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(chl, "2160", "2160")
    obs.obs_property_list_add_string(chl, "1440", "1440")
    obs.obs_property_list_add_string(chl, "1080", "1080")
    obs.obs_property_list_add_string(chl, "720", "720")
    obs.obs_property_list_add_string(chl, "480", "480")
    obs.obs_property_list_add_string(chl, "360", "360")
    obs.obs_property_list_add_string(chl, "240", "240")
    obs.obs_property_list_add_string(chl, "144", "144")

    cap(gpic, "fps", "Frame Rate")
    local fpsl = obs.obs_properties_add_list(gpic, "fps", "",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
    obs.obs_property_list_add_int(fpsl, "Follow source", 0)
    obs.obs_property_list_add_int(fpsl, "24", 24)
    obs.obs_property_list_add_int(fpsl, "25", 25)
    obs.obs_property_list_add_int(fpsl, "30", 30)
    obs.obs_property_list_add_int(fpsl, "48", 48)
    obs.obs_property_list_add_int(fpsl, "50", 50)
    obs.obs_property_list_add_int(fpsl, "60", 60)

    cap(gpic, "rec_sound", "REC sound")
    local snd = obs.obs_properties_add_list(gpic, "rec_sound", "",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(snd, "Source only", "source")
    obs.obs_property_list_add_string(snd, "Follow OBS audio mixer setting", "mixer")

    obs.obs_properties_add_group(props, "grp_pic", "Recording output",
        obs.OBS_GROUP_NORMAL, gpic)

    local gcred = obs.obs_properties_create()

    local cron = obs.obs_properties_add_bool(gcred, "cr_on",
        "Show source credit")
    obs.obs_property_set_modified_callback(cron, on_prop_modified)

    cap(gcred, "cr_mode", "Text")
    local crm = obs.obs_properties_add_list(gcred, "cr_mode", "",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(crm, "YouTube @handle", "yh")
    obs.obs_property_list_add_string(crm, "YouTube channel name", "yc")
    obs.obs_property_list_add_string(crm, "@handle", "h")
    obs.obs_property_list_add_string(crm, "Channel name", "c")
    obs.obs_property_list_add_string(crm, "Custom text", "x")
    obs.obs_property_set_modified_callback(crm, on_prop_modified)

    cap(gcred, "cr_text", "Custom text")
    obs.obs_properties_add_text(gcred, "cr_text", "", obs.OBS_TEXT_DEFAULT)

    cap(gcred, "cr_font", "Font")
    obs.obs_properties_add_font(gcred, "cr_font", "")

    cap(gcred, "cr_color", "Text color")
    obs.obs_properties_add_color_alpha(gcred, "cr_color", "")

    cap(gcred, "cr_bg", "Background color")
    obs.obs_properties_add_color_alpha(gcred, "cr_bg", "")

    cap(gcred, "cr_pos", "Position")
    local crp = obs.obs_properties_add_list(gcred, "cr_pos", "",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(crp, "Top left", "tl")
    obs.obs_property_list_add_string(crp, "Top right", "tr")
    obs.obs_property_list_add_string(crp, "Bottom left", "bl")
    obs.obs_property_list_add_string(crp, "Bottom right", "br")

    cap(gcred, "cr_voff", "Vertical offset (% of height)")
    obs.obs_properties_add_int(gcred, "cr_voff", "", 0, 45, 1)

    obs.obs_properties_add_group(props, "grp_cred", "SOURCE CREDIT",
        obs.OBS_GROUP_NORMAL, gcred)

    local grec = obs.obs_properties_create()

    cap(grec, "max_duration_sec", "Max recording time")
    local maxdur = obs.obs_properties_add_list(grec, "max_duration_sec", "",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
    obs.obs_property_list_add_int(maxdur, "Off", 0)
    obs.obs_property_list_add_int(maxdur, "10 min", 600)
    obs.obs_property_list_add_int(maxdur, "30 min", 1800)
    obs.obs_property_list_add_int(maxdur, "1 hour", 3600)
    obs.obs_property_list_add_int(maxdur, "2 hours", 7200)
    obs.obs_property_list_add_int(maxdur, "3 hours", 10800)
    obs.obs_property_list_add_int(maxdur, "6 hours", 21600)

    obs.obs_properties_add_group(props, "grp_rec", "Safety limit",
        obs.OBS_GROUP_NORMAL, grec)

    obs.obs_properties_add_bool(props, "update_check",
        "Tell me in the trim controls when a newer version is out - asks GitHub once a day")

    apply_take_lock(props)
    refresh_visibility(props, script_settings)
    return props
end

local H_MIN, H_MAX, H_FALLBACK = 144, 2160, 1080

local function parse_custom_height(s)
    local raw = tostring(s or "")
    local digits = raw:match("%d+")
    if not digits then
        return H_FALLBACK, true
    end
    local h = tonumber(digits)
    if not h then
        return H_FALLBACK, true
    end
    h = math.floor(h)
    if h < H_MIN then return H_MIN, true end
    if h > H_MAX then return H_MAX, true end
    return h, false
end

local function script_update_body(settings)
    script_settings     = settings

    local was_enabled   = cfg.enabled
    cfg.enabled         = obs.obs_data_get_bool(settings, "enabled")
    if was_enabled and not cfg.enabled then
        if recording_now() then
            if st.we_record then
                do_stop_recording("script disabled")
            else
                log("A recording is running but this script did not start it, so it is left running.")
            end
        end
        st.pending_stop   = nil
        st.pending_reason = nil
        st.playing_wait_ms = nil
        remove_quiet(paths().go)
        st.go_written = nil
        st.rec_card_t0 = nil
        rec_card_remove()
        log("Script disabled. Auto-recording will not run.")
    elseif (not was_enabled) and cfg.enabled then
        st.prev_active    = false
        log("Script enabled.")
    end

    local was_upd       = cfg.update_check
    cfg.update_check    = obs.obs_data_get_bool(settings, "update_check")
    UPD.switched(was_upd)

    cfg.fit_canvas      = obs.obs_data_get_bool(settings, "fit_canvas")
    cfg.res_mode        = obs.obs_data_get_string(settings, "res_mode")

    local raw_h = obs.obs_data_get_string(settings, "custom_height")
    local h, adjusted = parse_custom_height(raw_h)
    cfg.custom_h        = h
    if adjusted then
        if st.height_warned ~= raw_h then
            st.height_warned = raw_h
            log("Height '%s' is not usable; adjusted to %d.",
                tostring(raw_h), h)
        end
    else
        st.height_warned = nil
    end
    cfg.fps             = obs.obs_data_get_int(settings, "fps")

    local was_yt_url    = trim(cfg.yt_url or "")
    cfg.yt_url          = obs.obs_data_get_string(settings, "yt_url") or ""
    local now_yt_url    = trim(cfg.yt_url)
    if now_yt_url ~= was_yt_url then
        st.url_warned   = nil
        st.runup_logged = nil
    end
    panel_url_check()
    panel_intent_check()

    cfg.max_duration_sec   = obs.obs_data_get_int(settings, "max_duration_sec")

    local snd = trim(obs.obs_data_get_string(settings, "rec_sound") or "")
    cfg.rec_sound          = (snd == "mixer") and "mixer" or "source"

    cfg.cr_on           = obs.obs_data_get_bool(settings, "cr_on")
    local crmode = trim(obs.obs_data_get_string(settings, "cr_mode") or "")
    cfg.cr_mode         = (crmode ~= "") and crmode or "yh"
    cfg.cr_text         = obs.obs_data_get_string(settings, "cr_text") or ""
    cfg.cr_pos          = obs.obs_data_get_string(settings, "cr_pos") or "bl"
    cfg.cr_color        = obs.obs_data_get_int(settings, "cr_color")
    cfg.cr_bg           = obs.obs_data_get_int(settings, "cr_bg")
    local voff = obs.obs_data_get_int(settings, "cr_voff") or 0
    if voff < 0 then voff = 0 end
    if voff > 45 then voff = 45 end
    cfg.cr_voff         = voff
    local fo = obs.obs_data_get_obj(settings, "cr_font")
    if fo then
        local face = obs.obs_data_get_string(fo, "face")
        if face and trim(face) ~= "" then cfg.cr_face = trim(face) end
        local fsz = obs.obs_data_get_int(fo, "size")
        if fsz and fsz >= 6 then cfg.cr_size = math.floor(fsz) end
        local fl = obs.obs_data_get_int(fo, "flags") or 0
        cfg.cr_bold = (fl % 2) == 1
        obs.obs_data_release(fo)
    end

    UPD.request(os.time())

    st.apply_pending    = true
    st.create_want      = true

    service_create()
    service_launch()
    service_return()
end

function script_save(settings)
    UPD.save(settings)
    obs.obs_data_set_string(settings, "nonce", st.nonce or "")
    obs.obs_data_set_string(settings, "video_id", st.video_id or "")
    obs.obs_data_set_int(settings, "video_w", st.video_w or 0)
    obs.obs_data_set_int(settings, "video_h", st.video_h or 0)
    obs.obs_data_set_int(settings, "last_port", st.last_port or st.port or 0)
    obs.obs_data_set_double(settings, "url_time_sec", st.url_time_sec or -1)
    obs.obs_data_set_string(settings, "url_time_id", st.url_time_id or "")
    obs.obs_data_set_double(settings, "in_sec", st.in_sec or -1)
    obs.obs_data_set_double(settings, "out_sec", st.out_sec or -1)
    if st.hk_id ~= nil and obs.obs_hotkey_save then
        local oka, arr = pcall(obs.obs_hotkey_save, st.hk_id)
        if oka and arr then
            obs.obs_data_set_array(settings, "trim_hotkey", arr)
            obs.obs_data_array_release(arr)
        end
    end
end

local function script_load_body(settings)
    script_settings = settings
    math.randomseed(os.time())

    local saved = trim(obs.obs_data_get_string(settings, "nonce"))
    if saved ~= "" and saved ~= "0" then
        st.nonce = saved
    else
        st.nonce = tostring(os.time()) .. tostring(math.random(1000, 9999))
        obs.obs_data_set_string(settings, "nonce", st.nonce)
    end

    local font_now = obs.obs_data_get_obj(settings, "cr_font")
    if font_now then
        obs.obs_data_release(font_now)
    else
        local crf = obs.obs_data_create()
        obs.obs_data_set_string(crf, "face", cfg.cr_face)
        obs.obs_data_set_int(crf, "size", cfg.cr_size)
        obs.obs_data_set_int(crf, "flags", 0)
        obs.obs_data_set_string(crf, "style", "Regular")
        obs.obs_data_set_obj(settings, "cr_font", crf)
        obs.obs_data_release(crf)
    end

    adopt_existing_events()

    st.video_id = trim(obs.obs_data_get_string(settings, "video_id"))

    local vw = obs.obs_data_get_int(settings, "video_w") or 0
    local vh = obs.obs_data_get_int(settings, "video_h") or 0
    if vw > 0 and vh > 0 and st.video_id ~= "" then
        st.video_w = math.floor(vw)
        st.video_h = math.floor(vh)
        log("Video aspect restored for id %s: %dx%d. No new lookup is needed.",
            st.video_id, st.video_w, st.video_h)
    end

    local lp = obs.obs_data_get_int(settings, "last_port")
    if lp and lp > 0 then st.last_port = lp end

    local ut = obs.obs_data_get_double(settings, "url_time_sec")
    if ut and ut >= 0 then st.url_time_sec = ut end
    local uid = trim(obs.obs_data_get_string(settings, "url_time_id") or "")
    if uid ~= "" then st.url_time_id = uid end

    cfg.yt_url = obs.obs_data_get_string(settings, "yt_url") or ""

    cfg.update_check = obs.obs_data_get_bool(settings, "update_check")
    UPD.load(settings)

    local isec = obs.obs_data_get_double(settings, "in_sec")
    if isec and isec > 0 then st.in_sec = isec end
    local osec = obs.obs_data_get_double(settings, "out_sec")
    if osec and osec > 0 then st.out_sec = osec end
    if st.in_sec or st.out_sec then
        log("Trim range restored from the previous session: in=%ss out=%ss.",
            st.in_sec and num_str(st.in_sec) or "(not set)",
            st.out_sec and num_str(st.out_sec) or "(not set)")
    end
    panel_intent_check()

    local stale = aud_read_record(settings)
    if #stale > 0 then
        st.aud_saved = stale
        log("THIS SCRIPT STILL HAD AUDIO TRACK %d TURNED OFF ON %d SOURCE(S) FROM A TAKE THAT NEVER ENDED, so they are being put back now, before anything else. OBS stopped between the change and the restore - a crash, a kill, or this script being reloaded mid-take - and this record is the whole reason a source is not left off a track with nothing on screen to explain it. The record goes into this script's settings as each source is changed, and OBS writes that record and every source's track assignment into the same scene collection file in the same save, so the two can never be on disk apart.",
            MAX_AUDIO_MIXES, #stale)
        aud_restore("OBS stopped between the change and the restore, and this was still on record when the script loaded", true)
    end

    latch_program_scene()

    if obs.obs_hotkey_register_frontend then
        st.hk_fn = function(pressed)
            if not pressed then return end
            st.trim_want = true
        end
        local okh, hid = pcall(obs.obs_hotkey_register_frontend,
            "castika_sbr_open_trim", "Castika - open the trim controls", st.hk_fn)
        if okh and hid ~= nil then
            st.hk_id = hid
            local arr = obs.obs_data_get_array(settings, "trim_hotkey")
            if arr then
                pcall(obs.obs_hotkey_load, st.hk_id, arr)
                obs.obs_data_array_release(arr)
            end
            log("A global hotkey 'Castika - open the trim controls' is registered. Set a key for it in OBS under Settings - Hotkeys; it works from anywhere in OBS, not only from this panel. The press itself does nothing but raise a flag: this script's 100ms tick opens the window, because the hotkey callback runs on obs-scripting's own defer thread and is not a safe place to do the work.")
        else
            st.hk_fn = nil
        end
    end

    obs.obs_frontend_add_event_callback(on_frontend_event)
    log("Script loaded: %s (nonce %s).", SCRIPT_VERSION, st.nonce)
    UPD.tell()

    start_server()

    st.tick_fn = tick
    obs.timer_add(tick, TICK_MS)
    st.timer_on = true
end

function script_properties()
    local props = guard("script_properties", script_properties_body)
    if props ~= nil then return props end
    props = obs.obs_properties_create()
    cap(props, "halted", string.format(
        "This script stopped itself in %s. The reason and the stack are in the script log. Reload the script to bring these settings back.",
        tostring(st.halted or "an entry point")), true)
    return props
end

function script_update(settings)
    return guard("script_update", script_update_body, settings)
end

function script_load(settings)
    return guard("script_load", script_load_body, settings)
end

local function script_unload_body()
    ctl_show_drop()
    aud_restore("the script is being unloaded")
    hv_stop()
    hv_release_all()
    st.rec_card_t0 = nil
    rec_card_remove()
    stop_server()
    if st.timer_on then
        obs.timer_remove(tick)
        st.timer_on = false
    end
    obs.obs_frontend_remove_event_callback(on_frontend_event)
    if st.hk_fn and obs.obs_hotkey_unregister then
        pcall(obs.obs_hotkey_unregister, st.hk_fn)
        st.hk_fn = nil
        st.hk_id = nil
    end
end

function script_unload()
    local ok, err = pcall(script_unload_body)
    if not ok then
        logw("script_unload did not finish: %s", tostring(err))
    end
end
