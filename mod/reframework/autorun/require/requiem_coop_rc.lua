-- Requiem Co-op — remote control (DEBUG BUILDS ONLY).
--
-- This module does NOT exist in a release package (package.ps1 excludes it unless -Debug),
-- and the main script only wires it in when the file is present. A release client therefore
-- has no code path that runs anything a host sends.
--
-- What it does: lets the HOST drive a connected CLIENT's REFramework the same way the local dev
-- bridge drives the local game — run arbitrary Lua in the client's REFramework Lua state, read its
-- state, write files into the client's reframework/data, and hot-reload Lua on the client.
--
-- Consent: the client must tick "Allow host remote control" (cfg.allow_remote_control). Until then
-- every host request is answered with {denied=true} and nothing runs. While it is on, the co-op
-- window shows a visible "HOST REMOTE CONTROL ENABLED" banner. Set DEFAULT_ALLOW=true below only
-- for your own throwaway debug builds if you want it on without ticking the box.
--
-- Wire format (reliable text events, chunked; piece ~40 KB):
--   host -> client:  rcexec:<hdr>\n<piece>     run Lua, reply rcres
--                    rcfile:<hdr>\n<b64piece>  write bytes to a path under the client's game folder
--                    rcload:<ticket>\t<relpath> dofile() a path on the client, reply rcres
--   client -> host:  rcres:<ticket>\t<json>    result of exec/load ({ok,value}|{err}|{denied})
--                    rcack:<ticket>\t<json>    result of a file write ({ok,path}|{err}|{denied})
--  <hdr> = "ticket\tseq\ttotal[\textra]"  (extra = relpath for rcfile)

local M = { CLIENT = false, pending = {}, results = {}, rx = {}, banner = false }

local DEFAULT_ALLOW = false      -- client side: start opted-out (host control requires consent)
local PIECE = 40000              -- max characters of payload per reliable event
local RESULT_TTL = 120           -- seconds a finished result is kept for the host to read
local MAX_ASSEMBLE = 8 * 1024 * 1024

local ctx                        -- { cfg, emit(text), now(), serialize(v,depth), data_dir, game_dir }

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64enc(data)
    local out, n = {}, #data
    local byte, char, sub = string.byte, string.char, string.sub
    local i = 1
    while i <= n do
        local a, b, c = byte(data, i), byte(data, i + 1), byte(data, i + 2)
        local t = a * 65536 + (b or 0) * 256 + (c or 0)
        local s = sub(B64, math.floor(t / 262144) % 64 + 1, math.floor(t / 262144) % 64 + 1)
                .. sub(B64, math.floor(t / 4096) % 64 + 1, math.floor(t / 4096) % 64 + 1)
                .. (b and sub(B64, math.floor(t / 64) % 64 + 1, math.floor(t / 64) % 64 + 1) or "=")
                .. (c and sub(B64, t % 64 + 1, t % 64 + 1) or "=")
        out[#out + 1] = s
        i = i + 3
    end
    return table.concat(out)
end
local B64D = {}; for i = 1, #B64 do B64D[string.byte(B64, i)] = i - 1 end
local function b64dec(data)
    local byte, char, floor = string.byte, string.char, math.floor
    -- keep only alphabet chars (drops '=', whitespace); decode 4 sextets -> 3 bytes, bounded
    local c, nc = {}, 0
    for i = 1, #data do local v = B64D[byte(data, i)]; if v then nc = nc + 1; c[nc] = v end end
    local out, no, i = {}, 0, 1
    while i <= nc do
        local c1, c2, c3, c4 = c[i], c[i + 1], c[i + 2], c[i + 3]
        if not c2 then break end
        no = no + 1; out[no] = char((c1 * 4 + floor(c2 / 16)) % 256)
        if c3 then
            no = no + 1; out[no] = char(((c2 % 16) * 16 + floor(c3 / 4)) % 256)
            if c4 then no = no + 1; out[no] = char(((c3 % 4) * 64 + c4) % 256) end
        end
        i = i + 4
    end
    return table.concat(out)
end

-- plain-data serializer for results (depth-limited; userdata/engine objects -> describe)
local function describe(v) return (ctx and ctx.serialize) and ctx.serialize(v, 2) or tostring(v) end

local function new_ticket()
    M._seq = (M._seq or 0) + 1
    return string.format("%d_%d", math.floor((ctx and ctx.now() or os.clock()) * 1000) % 1000000000, M._seq)
end

-- split a payload into <= PIECE chunks and emit each with a header
local function emit_chunked(prefix, ticket, extra, payload)
    local total = math.max(1, math.ceil(#payload / PIECE))
    if total > 4096 then return false end
    for seq = 1, total do
        local piece = payload:sub((seq - 1) * PIECE + 1, seq * PIECE)
        local hdr = ticket .. "\t" .. seq .. "\t" .. total .. (extra and ("\t" .. extra) or "")
        ctx.emit(prefix .. ":" .. hdr .. "\n" .. piece)
    end
    return true
end

-- reassemble incoming chunks; returns payload,extra when the last piece arrives
local function assemble(kind, body)
    local nl = body:find("\n", 1, true)
    if not nl then return nil end
    local hdr, piece = body:sub(1, nl - 1), body:sub(nl + 1)
    local ticket, seq, total, extra = hdr:match("^([^\t]+)\t(%d+)\t(%d+)\t?(.*)$")
    if not ticket then return nil end
    seq, total = tonumber(seq), tonumber(total)
    local key = kind .. "/" .. ticket
    local r = M.rx[key]
    if not r then r = { parts = {}, got = 0, total = total, size = 0, t = ctx.now(), extra = extra }; M.rx[key] = r end
    if not r.parts[seq] then
        r.parts[seq] = piece; r.got = r.got + 1; r.size = r.size + #piece
        if r.size > MAX_ASSEMBLE then M.rx[key] = nil; return "err", ticket, "payload too large" end
    end
    if r.got < r.total then return nil end
    M.rx[key] = nil
    return "done", ticket, table.concat(r.parts), r.extra
end

-- forget stale partial transfers and old results
local function gc()
    local t = ctx.now()
    for k, r in pairs(M.rx) do if t - r.t > 30 then M.rx[k] = nil end end
    for id, r in pairs(M.results) do if r.done and t - r.done_at > RESULT_TTL then M.results[id] = nil end end
end

---------------------------------------------------------------------------
-- client side: run what the host asked (only when consented)
---------------------------------------------------------------------------
local function allowed() return ctx.cfg.allow_remote_control == true end

local function run_lua(code)
    local env = setmetatable({ log = function(...)
        local p = {}; for _, x in ipairs({ ... }) do p[#p + 1] = tostring(x) end
        M._log = M._log or {}; M._log[#M._log + 1] = table.concat(p, " ")
    end }, { __index = _G })
    M._log = {}
    local chunk, cerr = load(code, "rc", "t", env)
    if not chunk then return { err = "compile: " .. tostring(cerr) } end
    local ok, ret = xpcall(chunk, function(e)
        return (debug and debug.traceback) and debug.traceback(tostring(e), 2) or tostring(e)
    end)
    if not ok then return { err = ret, log = M._log } end
    local okS, val = pcall(describe, ret)
    return { ok = true, value = okS and val or ("<serialize error> " .. tostring(val)), log = M._log }
end

-- write bytes to a path under the client's game folder. Rejects absolute paths and "..".
-- Tries the requested relative path; if the engine sandbox refuses it, falls back to
-- reframework/data/<basename> and reports which path was actually written.
local function write_file(relpath, bytes)
    if type(relpath) ~= "string" or relpath == "" then return { err = "no path" } end
    if relpath:find("^%a:[\\/]") or relpath:find("^[\\/]") or relpath:find("%.%.") then
        return { err = "path must be relative and stay inside the game folder" }
    end
    relpath = relpath:gsub("\\", "/")
    local tried = {}
    local function try(p)
        tried[#tried + 1] = p
        local ok = pcall(function()
            if fs and fs.write then fs.write(p, bytes) else error("no fs.write") end
        end)
        return ok
    end
    -- fs.write is rooted at reframework/data; strip a leading reframework/data/ if present,
    -- otherwise write under data/_deploy/ mirroring the requested path so nothing escapes.
    local p = relpath:gsub("^reframework/data/", "")
    if p == relpath then p = "_deploy/" .. relpath end
    if try(p) then return { ok = true, path = "reframework/data/" .. p, note = "written under reframework/data" } end
    local base = relpath:match("[^/]+$") or "deploy.bin"
    if try("_deploy/" .. base) then return { ok = true, path = "reframework/data/_deploy/" .. base } end
    return { err = "could not write file (engine sandbox)", tried = tried }
end

---------------------------------------------------------------------------
-- event entry point (called by the main script's router)
---------------------------------------------------------------------------
function M.event(k, v)
    gc()
    if k == "rcexec" then
        local st, ticket, payload = assemble("exec", v)
        if st == "err" then ctx.emit("rcres:" .. ticket .. "\t" .. '{"err":"' .. payload .. '"}'); return end
        if st ~= "done" then return end
        local reply
        if not allowed() then reply = { denied = true }
        else reply = run_lua(payload) end
        local ok, js = pcall(json.dump_string, reply)
        emit_chunked("rcres", ticket, nil, (ok and js or '{"err":"encode failed"}'))
    elseif k == "rcload" then
        local ticket, relpath = v:match("^([^\t]+)\t(.*)$")
        if not ticket then return end
        local reply
        if not allowed() then reply = { denied = true }
        else
            local ok, err = pcall(function() return dofile(relpath) end)
            reply = ok and { ok = true, value = describe(err) } or { err = tostring(err) }
        end
        local ok2, js = pcall(json.dump_string, reply)
        ctx.emit("rcres:" .. ticket .. "\t" .. (ok2 and js or '{"err":"encode failed"}'))
    elseif k == "rcfile" then
        local st, ticket, payload, relpath = assemble("file", v)
        if st == "err" then ctx.emit("rcack:" .. ticket .. "\t" .. '{"err":"' .. payload .. '"}'); return end
        if st ~= "done" then return end
        local reply
        if not allowed() then reply = { denied = true }
        else
            local okD, bytes = pcall(b64dec, payload)
            reply = okD and write_file(relpath, bytes) or { err = "bad base64" }
        end
        local ok, js = pcall(json.dump_string, reply)
        ctx.emit("rcack:" .. ticket .. "\t" .. (ok and js or '{"err":"encode failed"}'))
    elseif k == "rcres" or k == "rcack" then
        -- host side: a reply to one of our requests
        local st, ticket, payload
        if k == "rcres" then st, ticket, payload = assemble("res", v) else
            local tk, js = v:match("^([^\t]+)\t(.*)$"); st, ticket, payload = tk and "done" or nil, tk, js
        end
        if st ~= "done" then return end
        local ok, d = pcall(json.load_string, payload)
        M.results[ticket] = { done = true, done_at = ctx.now(), reply = ok and d or { err = "bad reply", raw = payload } }
    end
end

---------------------------------------------------------------------------
-- host side: public API (the dev bridge / MCP server calls these)
---------------------------------------------------------------------------
function M.exec_peer(code)
    local ticket = new_ticket()
    M.results[ticket] = { started_at = ctx.now() }
    if not emit_chunked("rcexec", ticket, nil, tostring(code or "")) then
        M.results[ticket] = { done = true, done_at = ctx.now(), reply = { err = "code too large" } }
    end
    return ticket
end

function M.deploy_peer(relpath, bytes)
    local ticket = new_ticket()
    M.results[ticket] = { started_at = ctx.now() }
    if not emit_chunked("rcfile", ticket, relpath, b64enc(bytes or "")) then
        M.results[ticket] = { done = true, done_at = ctx.now(), reply = { err = "file too large" } }
    end
    return ticket
end

-- convenience for the MCP server: bytes arrive as base64 inside a bridge command
function M.deploy_peer_b64(relpath, b64)
    return M.deploy_peer(relpath, b64dec(b64 or ""))
end

function M.reload_peer(relpath)
    local ticket = new_ticket()
    M.results[ticket] = { started_at = ctx.now() }
    ctx.emit("rcload:" .. ticket .. "\t" .. tostring(relpath or ""))
    return ticket
end

-- host side: poll a ticket. { pending=true } | { done=true, ... reply fields ... }
function M.result(ticket)
    local r = M.results[ticket]
    if not r then return { error = "unknown ticket" } end
    if not r.done then return { pending = true, age = ctx.now() - (r.started_at or ctx.now()) } end
    local out = { done = true }
    for key, val in pairs(r.reply or {}) do out[key] = val end
    return out
end

function M.init(context)
    ctx = context
    if ctx.cfg.allow_remote_control == nil then ctx.cfg.allow_remote_control = DEFAULT_ALLOW end
    return M
end

return M
