-- Requiem Co-op 0.11.0-preview: cutscene start barrier (all players start together),
-- native Co-op entry and lobby in the game's title menu,
-- native playback of dynamic (first-person) motion banks,
-- performance pass (cached engine handles, native accessory constraint, staggered scans)
-- and a negotiated lossless v2 state header.
-- State and reliable events use the coopnet in-memory bridge (transport v5).
-- The original JSON state files remain a fallback for older plugins.
--
-- UI: REFramework menu (Insert) > Script Generated UI > Requiem Co-op

local OUT_FILE, IN_FILE, LINK_FILE, CFG_FILE = "coop_out.json", "coop_in.json", "coop_link.json", "coop_config.json"

local cfg = {
    enabled = true,
    mirror_test = false,   -- offline test: puppet copies YOU with a delay, no network needed
    name_tag = true,
    window_key = 0x75,     -- F6 toggles the co-op window
    allow_debug_requests = false,  -- let the host ask this game for a (read-only) status report
    last_ip = "",
    send_hz = 30,
    interp_ms = 60,        -- fixed playback delay (only used when auto_interp is off)
    auto_interp = true,    -- size the playback delay from the measured connection quality
    native_animation = true, -- negotiated; unsupported animation states fall back to bones
    stale_after = 3.0,     -- seconds without data before the puppet hides
}
do
    local saved = json.load_file(CFG_FILE)
    if type(saved) == "table" then for k, v in pairs(saved) do if cfg[k] ~= nil then cfg[k] = v end end end
end
local function save_cfg() json.dump_file(CFG_FILE, cfg) end

-- Joints whose local position matters (everything else uses rotations only)
local POS_JOINTS = { root = true, Hip = true }

local GO_TD       = sdk.find_type_definition("via.GameObject")
local GO_CREATE   = GO_TD:get_method("create(System.String, via.Folder)")
local GO_DESTROY  = GO_TD:get_method("destroy(via.GameObject)")
local T_DUMMYSKEL = sdk.typeof("via.motion.DummySkeleton")
local T_MOTION    = sdk.typeof("via.motion.Motion")
-- Hot-path methods resolved once. A string-dispatched obj:call("name") looks the
-- method up on every call; measured in-game this is ~3x slower for joint reads.
local JM = { T_MESH = sdk.typeof("via.render.Mesh"), T_STRANDS = sdk.typeof("via.render.Strands"),
    T_SHADOW_ITEM = sdk.typeof("app.FPSShadowItemObject") }
do
    local tj, tt = sdk.find_type_definition("via.Joint"), sdk.find_type_definition("via.Transform")
    JM.get_lr, JM.set_lr = tj:get_method("get_LocalRotation"), tj:get_method("set_LocalRotation")
    JM.get_lp, JM.set_lp = tj:get_method("get_LocalPosition"), tj:get_method("set_LocalPosition")
    JM.get_p, JM.get_r = tj:get_method("get_Position"), tj:get_method("get_Rotation")
    JM.set_p, JM.set_r = tj:get_method("set_Position"), tj:get_method("set_Rotation")
    JM.tr_set_parent = tt:get_method("set_Parent")
    JM.tr_set_same = tt:get_method("set_SameJointsConstraint")
end
local MONTAGE_TD  = sdk.find_type_definition("app.MontageID")
local KIND_TD     = sdk.find_type_definition("app.CharacterKindID")
local REQ_MONTAGE = "requestInstantiateMontage(via.GameObject, app.CharacterKindID, app.MontageID, System.Action`1<app.MontageManager.Results>, System.Boolean, System.Int32, System.Boolean)"

local status = "starting"
local enemy_hooks = {}   -- filled in by the enemy sync section further down
local session, torch
-- per-frame cost of this script (ms), shown in the debug snapshot
local prof = { late = 0, late_max = 0, frame = 0, frame_max = 0, sections = {} }
local function prof_add(key, ms)
    local p = prof.sections[key] or { avg = 0, max = 0, total = 0, count = 0 }
    p.avg = p.avg * 0.95 + ms * 0.05
    if ms > p.max then p.max = ms end
    p.total,p.count=p.total+ms,p.count+1
    prof.sections[key] = p
end
local function prof_late(started)
    local ms=(os.clock()-started)*1000
    prof.late=prof.late*.95+ms*.05;prof.late_max=math.max(prof.late_max,ms)
    prof_add('late_total',ms)
end
-- generation guard: if the script is loaded again, older copies switch themselves off
_G.__requiem_coop_gen = (_G.__requiem_coop_gen or 0) + 1
local GEN = _G.__requiem_coop_gen
local function alive() return _G.__requiem_coop_gen == GEN end
local link = {}
local now = os.clock

---------------------------------------------------------------------------
-- small math helpers (quaternions as {x,y,z,w})
---------------------------------------------------------------------------
local function r4(v) return math.floor(v * 10000 + 0.5) / 10000 end
local function r3(v) return math.floor(v * 1000 + 0.5) / 1000 end

-- 32-bit FNV-1a, used to tag a joint-name list so it only has to be sent once
local function fnv32(str)
    local h = 2166136261
    for i = 1, #str do h = ((h ~ str:byte(i)) * 16777619) & 0xFFFFFFFF end
    return h
end

-- quaternion components (-1..1) <-> int16
local function q16(x)
    local v = math.floor(x * 32767 + 0.5)
    if v > 32767 then v = 32767 elseif v < -32767 then v = -32767 end
    return v
end
local function uq16(v) return v / 32767 end

-- quaternion product a*b (x,y,z,w)
local function qmul(ax, ay, az, aw, bx, by, bz, bw)
    return aw * bx + ax * bw + ay * bz - az * by,
           aw * by - ax * bz + ay * bw + az * bx,
           aw * bz + ax * by - ay * bx + az * bw,
           aw * bw - ax * bx - ay * by - az * bz
end

local function nlerp(ax, ay, az, aw, bx, by, bz, bw, t)
    if ax * bx + ay * by + az * bz + aw * bw < 0 then bx, by, bz, bw = -bx, -by, -bz, -bw end
    local x, y, z, w = ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t, aw + (bw - aw) * t
    local l = math.sqrt(x * x + y * y + z * z + w * w)
    if l < 1e-6 then return bx, by, bz, bw end
    return x / l, y / l, z / l, w / l
end

-- rotate vector v by quaternion q
local function qrot(qx, qy, qz, qw, vx, vy, vz)
    local tx = 2 * (qy * vz - qz * vy)
    local ty = 2 * (qz * vx - qx * vz)
    local tz = 2 * (qx * vy - qy * vx)
    return vx + qw * tx + (qy * tz - qz * ty),
           vy + qw * ty + (qz * tx - qx * tz),
           vz + qw * tz + (qx * ty - qy * tx)
end

---------------------------------------------------------------------------
-- game access
---------------------------------------------------------------------------
local function get_player()
    local cm = sdk.get_managed_singleton("app.CharacterManager")
    if not cm then return nil end
    local ctx = cm:call("get_PlayerContextFast")
    if not ctx then return nil end
    local go = ctx:call("get_GameObject")
    if not go or not go:call("get_Valid") then return nil end
    return cm, ctx, go
end

local function area_of(go)
    local f = go:call("get_Folder")
    local path = f and f:call("get_Path") or ""
    return path:match("^[^/]+/([^/]+)") or path
end

local kind_cache = {}
local function find_kind(name)
    if kind_cache[name] then return kind_cache[name] end
    local vals = KIND_TD:get_method("get_Values"):call(nil)
    for i = 0, vals:call("get_Count") - 1 do
        local v = vals:call("get_Item", i)
        if v:call("ToString") == name then kind_cache[name] = v; return v end
    end
end

local function for_descendants(tr, fn)
    local c = tr:call("get_Child")
    while c do
        fn(c:call("get_GameObject"))
        for_descendants(c, fn)
        c = c:call("get_Next")
    end
end

---------------------------------------------------------------------------
-- Native animation extension. The v5 transport stays compatible: new peers
-- negotiate this extension and acknowledge resource setup before bones stop.
-- Complex blend trees/dynamic motions retain the existing bone fallback.
---------------------------------------------------------------------------
local anim = { MOD_VERSION = "0.11.0-preview", version = 1, peer_version = 0, descriptors = {}, remote = {}, ready = {},
    resources = {}, capture_cache = {}, last_announce = -100, bytes = 0, mode = "bones", error = "" }
function anim.finite(x,limit) return type(x)=='number' and x==x and math.abs(x)<(limit or 1e7) end
function anim.valid_transform(p,r)
    for i=1,3 do if not anim.finite(p[i]) then return false end end
    local n=0;for i=1,4 do if not anim.finite(r[i],2) then return false end;n=n+r[i]*r[i] end
    return n>0.25 and n<2.25
end
anim.layer_format = "<BI4I4i4I4BBI4IBffff"
anim.layout_format = "<BI4I4i4I4BBI4IBf"
anim.layout_local, anim.layout_remote, anim.layout_ready, anim.layout_sent, anim.layout_requested = {}, {}, {}, {}, {}

function anim.hex(bytes) return (bytes:gsub('.', function(c) return string.format('%02x', c:byte()) end)) end
function anim.unhex(text)
    assert(#text % 2 == 0 and not text:find('[^0-9a-f]'), 'invalid layout encoding')
    return (text:gsub('..', function(x) return string.char(tonumber(x, 16)) end))
end
-- Lossless relative to the existing int16 quaternion format: omit only exact
-- default components. Every packet remains independently decodable.
function anim.pack_bones(qi)
    if #qi > 0 and (anim.bone_peer or link.mode == 'echo') then
        local masks, values = {}, {}
        for first = 1, #qi, 8 do
            local mask = 0
            for bit = 0, math.min(7, #qi - first) do
                local index = first + bit
                if qi[index] ~= (index % 4 == 0 and 32767 or 0) then
                    mask = mask | (1 << bit); values[#values + 1] = qi[index]
                end
            end
            masks[#masks + 1] = string.char(mask)
        end
        if #masks + #values * 2 < #qi * 2 then
            local tail = #values > 0 and string.pack('<' .. string.rep('h', #values), table.unpack(values)) or ''
            return table.concat(masks) .. tail, true
        end
    end
    return #qi > 0 and string.pack('<' .. string.rep('h', #qi), table.unpack(qi)) or '', false
end
function anim.unpack_bones(bytes, at, count, sparse)
    assert(count <= 1024, 'too many pose joints')
    local q, components = {}, count * 4
    if sparse then
        assert(count > 0, 'empty sparse pose')
        local mask
        mask, at = string.unpack('c' .. ((components + 7) // 8), bytes, at)
        if count % 2 ~= 0 then assert(mask:byte(#mask) & 0xF0 == 0, 'invalid sparse padding') end
        local indices = {}
        for i = 1, components do
            if mask:byte((i - 1) // 8 + 1) & (1 << ((i - 1) % 8)) ~= 0 then indices[#indices + 1] = i end
            q[i] = i % 4 == 0 and 1 or 0
        end
        if #indices > 0 then
            local values = table.pack(string.unpack('<' .. string.rep('h', #indices), bytes, at))
            for i, index in ipairs(indices) do q[index] = uq16(values[i]) end
            at = values[#indices + 1]
        end
    elseif components > 0 then
        local values = table.pack(string.unpack('<' .. string.rep('h', components), bytes, at))
        for i = 1, components do q[i] = uq16(values[i]) end
        at = values[components + 1]
    end
    for first=1,components,4 do
        local n=q[first]^2+q[first+1]^2+q[first+2]^2+q[first+3]^2
        assert(n>0.25 and n<2.25,'invalid pose rotation')
    end
    return q, at
end

anim.header_format = '<I4s1i2i2s1'
anim.header_local, anim.header_remote, anim.header_ready, anim.header_sent, anim.header_requested, anim.header_keys = {}, {}, {}, {}, {}, {}
function anim.send_header(id)
    if anim.header_local[id] and anim.emit then
        anim.emit('shdef:' .. id .. ':' .. anim.hex(anim.header_local[id])); anim.header_sent[id] = now()
    end
end
function anim.header(st)
    if not (anim.header_peer or link.mode == 'echo') then return nil end
    local bytes = string.pack(anim.header_format, st.sk, st.kind or '', st.mm or 0, st.mp or 0, st.area or '')
    local id = anim.header_keys[bytes] or fnv32(bytes)
    if anim.header_local[id] and anim.header_local[id] ~= bytes then return nil end
    anim.header_keys[bytes], anim.header_local[id] = id, bytes
    if link.mode == 'echo' then
        anim.header_remote[id] = { sk = st.sk, kind = st.kind, mm = st.mm, mp = st.mp, area = st.area }
        anim.header_ready[id] = true
    end
    if anim.header_ready[id] then return id end
    if not anim.header_sent[id] or now() - anim.header_sent[id] > 0.5 then anim.send_header(id) end
end
function anim.batch(records, enabled)
    if not enabled then return records end
    local result, group, size = {}, {}, 4
    local function flush()
        if #group == 1 then result[#result + 1] = group[1]
        elseif #group > 1 then
            local parts = { '\0B1' .. string.char(#group) }
            for _, packet in ipairs(group) do parts[#parts + 1] = string.pack('<s2', packet) end
            result[#result + 1] = table.concat(parts)
        end
        group, size = {}, 4
    end
    for _, packet in ipairs(records) do
        if #packet + 6 > 1150 then
            flush(); result[#result + 1] = packet
        else
            if size + #packet + 2 > 1150 or #group == 32 then flush() end
            group[#group + 1], size = packet, size + #packet + 2
        end
    end
    flush()
    return result
end
function anim.unbatch(bytes)
    assert(#bytes <= 1150 and bytes:sub(1, 3) == '\0B1', 'invalid enemy batch')
    local count = bytes:byte(4)
    assert(count and count >= 2 and count <= 32, 'invalid enemy batch count')
    local records, at = {}, 5
    for _ = 1, count do
        local packet
        packet, at = string.unpack('<s2', bytes, at)
        assert(#packet > 0 and packet:byte(1) ~= 0, 'nested/empty enemy batch')
        records[#records + 1] = packet
    end
    assert(at == #bytes + 1, 'trailing enemy batch data')
    return records
end
function anim.valid_layer(l)
    return l.slot < 16 and l.wrap <= 4 and l.frame == l.frame and math.abs(l.frame) < 1e7
        and l.speed == l.speed and math.abs(l.speed) <= 100 and l.weight >= 0 and l.weight <= 1
        and l.ending >= 0 and l.ending < 1e7
end
function anim.send_layout(id)
    local bytes = anim.layout_local[id]
    if bytes and anim.emit then anim.emit('aldef:' .. id .. ':' .. anim.hex(bytes)); anim.layout_sent[id] = now() end
end
function anim.compact(a)
    local records, ready = {}, true
    for _, l in ipairs(a.layers) do
        local bytes = string.pack(anim.layout_format, l.slot, l.bank, l.motion, l.bank_type, l.mask,
            l.mask_mode, l.blend_mode, l.namespace, l.base, l.wrap, l.ending)
        local id = fnv32(bytes)
        if anim.layout_local[id] and anim.layout_local[id] ~= bytes then return nil end
        anim.layout_local[id] = bytes
        if link.mode == 'echo' then
            anim.event('aldef', id .. ':' .. anim.hex(bytes))
            anim.layout_ready[id] = true
        end
        if not anim.layout_ready[id] then
            ready = false
            if not anim.layout_sent[id] or now() - anim.layout_sent[id] > 0.5 then anim.send_layout(id) end
        end
        local flags = (l.speed ~= 1 and 1 or 0) | (l.weight ~= 1 and 2 or 0)
        local record = string.pack('<I4Bf', id, flags, l.frame)
        if flags & 1 ~= 0 then record = record .. string.pack('<f', l.speed) end
        if flags & 2 ~= 0 then record = record .. string.pack('<f', l.weight) end
        records[#records + 1] = record
    end
    if ready then return string.pack('<c4I4B', 'AN02', a.id, #a.layers) .. table.concat(records) end
end

-- Resolve reflected methods once. Looking them up by string on every layer,
-- every snapshot costs more than the animation data itself.
function anim.accessors(type_name)
    return setmetatable({}, { __index = function(t, name)
        local td, method = sdk.find_type_definition(type_name), nil
        while td and not method do method = td:get_method(name); td = td:get_parent_type() end
        assert(method, "missing animation API " .. type_name .. "::" .. name)
        local call = function(object, ...) return method:call(object, ...) end
        rawset(t, name, call)
        return call
    end })
end
anim.motion_api = anim.accessors("via.motion.Motion")
anim.layer_api = anim.accessors("via.motion.TreeLayer")
anim.node_api = anim.accessors("via.motion.MotionNodeCtrl")

function anim.asset_path(path, prefix, suffix)
    return type(path) == "string" and #path < 240 and not path:find("..", 1, true)
        and path:sub(1, #prefix):lower() == prefix:lower()
        and path:sub(-#suffix):lower() == suffix:lower() and not path:find("[|\r\n]")
end

-- First-person and context animations live in dynamic motion banks (e.g.
-- ch0200FPS.motbank, bank ID 900). Without them the puppet cannot play those
-- layers and falls back to bone streaming. Encoded as an optional fifth
-- descriptor field so peers that predate it reject the descriptor and keep
-- receiving bones, exactly as before. Empty entries keep slot indices.
anim.dyn_api = anim.accessors("via.motion.DynamicMotionBank")
function anim.dynamic_desc(motion)
    local n = anim.motion_api.getDynamicMotionBankCount(motion)
    if n == 0 then return "" end
    if n > 8 then return nil end
    local D, parts = anim.dyn_api, {}
    for i = 0, n - 1 do
        local d = anim.motion_api.getDynamicMotionBank(motion, i)
        if not d then parts[#parts + 1] = ""
        else
            if D.get_MotionList(d) then return nil end
            local h = D.get_MotionBank(d)
            local p = h and h:call("get_ResourcePath")
            if not anim.asset_path(p, "Animation/", ".motbank") or p:find("[,;]") then return nil end
            local flags = (D.get_OverwriteBankID(d) and 1 or 0) | (D.get_OverwriteBankType(d) and 2 or 0)
                | (D.get_OverwriteBankTypeMaskBit(d) and 4 or 0)
            parts[#parts + 1] = table.concat({ p, D.get_Priority(d), D.get_Order(d), flags,
                D.get_BankID(d), D.get_BankType(d), D.get_BankTypeMaskBit(d) }, ",")
        end
    end
    return table.concat(parts, ";")
end
function anim.parse_dynamic(text)
    if not text then return nil end
    local list, n = {}, 0
    for entry in (text .. ";"):gmatch("([^;]*);") do
        n = n + 1
        if n > 8 then return false end
        if entry == "" then list[n] = false
        else
            local p, prio, order, flags, id, bt, mask = entry:match("^([^,]+),(%-?%d+),(%-?%d+),(%d),(%d+),(%d+),(%d+)$")
            if not p or not anim.asset_path(p, "Animation/", ".motbank") then return false end
            prio, order, flags, id, bt, mask = tonumber(prio), tonumber(order), tonumber(flags), tonumber(id), tonumber(bt), tonumber(mask)
            if math.abs(prio) > 0x7FFFFFFF or math.abs(order) > 0x7FFFFFFF or flags > 7
                or id > 0xFFFFFFFF or bt > 0xFFFFFFFF or mask > 0xFFFFFFFF then return false end
            list[n] = { path = p, priority = prio, order = order, flags = flags, bank = id, type = bt, mask = mask }
        end
    end
    return list
end

function anim.capture(go)
    if not cfg.native_animation then return nil end
    local address = go:get_address()
    local cached = anim.capture_cache[address]
    if cached and (not cached.motion or not cached.skeleton or (cached.motion and not cached.motion:call("get_Valid"))
        or (cached.skeleton and not cached.skeleton:call("get_Valid"))) then cached = nil end
    if not cached then
        cached = { motion = go:call("getComponent(System.Type)", T_MOTION),
            skeleton = go:call("getComponent(System.Type)", T_DUMMYSKEL) }
        anim.capture_cache[address] = cached
    end
    cached.touched = now()
    local motion, ds = cached.motion, cached.skeleton
    if not motion or not ds then return nil end
    if math.abs(anim.motion_api.get_PlaySpeed(motion) - 1) > 0.00001 then return nil end
    local count = anim.motion_api.getLayerCount(motion)
    if count < 1 or count > 16 then return nil end
    local target = anim.motion_api.get_TargetBankType(motion)
    -- The bank/skeleton getters allocate a fresh holder wrapper on every call
    -- (get_MotionBankAsset measured 0.2-0.76 ms in-game) and their addresses are not
    -- stable identities. They only change with the character/costume, so re-read the
    -- descriptor once a second, or at once when the layer count or bank type changes.
    local t0 = now()
    if cached.d_count ~= count or cached.d_target ~= target or t0 - (cached.res_t or -100) >= 1 then
        local bank, skeleton = anim.motion_api.get_MotionBankAsset(motion), ds:call("get_SkeletonResourceHandle")
        local bp, sp = bank and bank:call("get_ResourcePath"), skeleton and skeleton:call("get_ResourcePath")
        cached.d_count, cached.d_target, cached.res_t = count, target, t0
        local dyn = anim.dynamic_desc(motion)
        local desc = (dyn and anim.asset_path(bp, "Animation/", ".motbank") and anim.asset_path(sp, "Character/", ".refskel"))
            and table.concat({ target, count, bp, sp }, "|") .. (dyn ~= "" and "|" .. dyn or "") or nil
        if desc ~= cached.d_desc then cached.d_desc, cached.d_id = desc, desc and fnv32(desc) or nil end
    end
    local id = cached.d_id
    if not id then return nil end
    anim.descriptors[id] = cached.d_desc
    local layers, statics, t = {}, cached.statics or {}, now()
    cached.statics = statics
    local L = anim.layer_api
    for i = 0, count - 1 do
        local l = anim.motion_api.getLayer(motion, i)
        local weight = l and L.get_Enabled(l) and L.get_BlendRate(l) or 0
        if weight < 0 or weight > 1 then return nil end
        if weight > 0.0001 then
            local n = L.get_HighestWeightMotionNode(l)
            if n then
                -- A single highest-weight node cannot describe a blend tree.
                if L.getMotionNodeCount(l) ~= 1 or anim.node_api.get_DynamicMotion(n) then return nil end
                local mid, bid = L.get_MotionID(l), L.get_MotionBankID(l)
                -- Layer settings are re-read whenever the motion changes and at least every 0.5 s.
                local c = statics[i]
                if not c or c.layer ~= l:get_address() or c.mid ~= mid or c.bid ~= bid or t - c.t > 0.5 then
                    c = { layer = l:get_address(), mid = mid, bid = bid, t = t, ending = L.get_EndFrame(l),
                        bank_type = L.get_MotionBankType(l), mask = L.get_JointMaskID(l),
                        mask_mode = L.get_JointMaskIDMode(l), blend_mode = L.get_BlendMode(l),
                        namespace = L.get_JointNameSpaceHash(l), base = L.get_BaseLayerNo(l), wrap = L.get_WrapMode(l) }
                    statics[i] = c
                end
                if c.ending <= 0 then return nil end
                if mid ~= 0xFFFFFFFF then
                    layers[#layers + 1] = { slot = i, bank = bid, motion = mid,
                        bank_type = c.bank_type, mask = c.mask, mask_mode = c.mask_mode, blend_mode = c.blend_mode,
                        namespace = c.namespace, base = c.base, wrap = c.wrap, frame = L.get_Frame(l),
                        speed = L.get_Speed(l), weight = weight, ending = c.ending }
                end
            end
        end
    end
    if #layers == 0 then return nil end
    return { id = id, layers = layers }
end

function anim.pack(a)
    if anim.compact_peer or link.mode == 'echo' then
        local compact = anim.compact(a)
        if compact then return compact end
    end
    local parts = { string.pack("<c4I4B", "AN01", a.id, #a.layers) }
    for _, l in ipairs(a.layers) do
        parts[#parts + 1] = string.pack(anim.layer_format, l.slot, l.bank, l.motion, l.bank_type,
            l.mask, l.mask_mode, l.blend_mode, l.namespace, l.base, l.wrap,
            l.frame, l.speed, l.weight, l.ending)
    end
    return table.concat(parts)
end

function anim.unpack(bytes, at)
    local magic, id, n
    magic, id, n, at = string.unpack("<c4I4B", bytes, at)
    assert((magic == "AN01" or magic == "AN02") and n > 0 and n <= 16, "invalid animation extension")
    local a, seen = { id = id, layers = {} }, {}
    for _ = 1, n do
        if magic == 'AN02' then
            local token, flags, frame
            token, flags, frame, at = string.unpack('<I4Bf', bytes, at)
            assert(flags & ~3 == 0, 'invalid compact animation flags')
            local layout = anim.layout_remote[token]
            if not layout then
                if anim.emit and (not anim.layout_requested[token] or now() - anim.layout_requested[token] > 0.5) then
                    anim.layout_requested[token] = now(); anim.emit('alreq:' .. token)
                end
                error('unknown animation layout')
            end
            local l = {}
            for k, v in pairs(layout) do l[k] = v end
            l.frame, l.speed, l.weight = frame, 1, 1
            if flags & 1 ~= 0 then l.speed, at = string.unpack('<f', bytes, at) end
            if flags & 2 ~= 0 then l.weight, at = string.unpack('<f', bytes, at) end
            assert(anim.valid_layer(l) and not seen[l.slot], 'invalid compact animation layer')
            seen[l.slot] = true
            a.layers[#a.layers + 1] = l
        else
        local slot, bank, mid, bt, mask, mm, bm, ns, base, wrap, frame, speed, weight, ending
        slot, bank, mid, bt, mask, mm, bm, ns, base, wrap, frame, speed, weight, ending, at = string.unpack(anim.layer_format, bytes, at)
        assert(slot < 16 and not seen[slot] and wrap <= 4 and frame == frame and math.abs(frame) < 1e7
            and speed == speed and math.abs(speed) <= 100 and weight >= 0 and weight <= 1
            and ending >= 0 and ending < 1e7, "invalid animation layer")
        seen[slot] = true
        a.layers[#a.layers + 1] = { slot = slot, bank = bank, motion = mid, bank_type = bt,
            mask = mask, mask_mode = mm, blend_mode = bm, namespace = ns, base = base,
            wrap = wrap, frame = frame, speed = speed, weight = weight, ending = ending }
        end
    end
    assert(at == #bytes + 1, "trailing animation data")
    return a
end

function anim.resource(path, name)
    local key = name .. ":" .. path
    local entry = anim.resources[key]
    if entry then return entry end
    local resource = sdk.create_resource("via.motion." .. name .. "Resource", path)
    local holder = resource and resource:create_holder("via.motion." .. name .. "ResourceHolder")
    if holder then anim.resources[key] = holder:add_ref() end
    return holder
end

function anim.event(k, v)
    if k == "anver" then
        anim.peer_version = tonumber(v) == 1 and 1 or 0
    elseif k == 'ancompact' then
        anim.compact_peer = v == '2'
    elseif k == 'anbones' then anim.bone_peer = v == '1'
    elseif k == 'anhead' then anim.header_peer = v == '1'
    elseif k == 'enbatch' then anim.batch_peer = v == '1'
    elseif k == 'anstate' then anim.state2_peer = v == '2'
    elseif k == 'shdef' then
        local id, hex = v:match('^(%d+):([0-9a-f]+)$')
        id = tonumber(id)
        if not id or #hex > 1024 or #hex % 2 ~= 0 then return end
        local bytes = anim.unhex(hex)
        if fnv32(bytes) ~= id then return end
        local ok, sk, kind, mm, mp, area, at = pcall(string.unpack, anim.header_format, bytes)
        if not ok or at ~= #bytes + 1 or #kind == 0 or #kind > 96 or #area > 192 then return end
        anim.header_remote[id] = { sk = sk, kind = kind, mm = mm, mp = mp, area = area }
        if anim.emit then anim.emit('shack:' .. id) end
    elseif k == 'shack' then
        local id = tonumber(v)
        if id and anim.header_local[id] then anim.header_ready[id] = true end
    elseif k == 'shreq' then
        local id = tonumber(v)
        if id then
            anim.header_ready[id] = nil
            if not anim.header_sent[id] or now() - anim.header_sent[id] > 0.5 then anim.send_header(id) end
        end
    elseif k == 'aldef' then
        local id, hex = v:match('^(%d+):([0-9a-f]+)$')
        id = tonumber(id)
        if not id or #hex ~= string.packsize(anim.layout_format) * 2 then return end
        local bytes = anim.unhex(hex)
        if fnv32(bytes) ~= id then return end
        local slot, bank, mid, bt, mask, mm, bm, ns, base, wrap, ending = string.unpack(anim.layout_format, bytes)
        local l = { slot = slot, bank = bank, motion = mid, bank_type = bt, mask = mask,
            mask_mode = mm, blend_mode = bm, namespace = ns, base = base, wrap = wrap,
            ending = ending, frame = 0, speed = 1, weight = 1 }
        if not anim.valid_layer(l) then return end
        anim.layout_remote[id] = l
        if anim.emit then anim.emit('alack:' .. id) end
    elseif k == 'alack' then
        local id = tonumber(v)
        if id and anim.layout_local[id] then anim.layout_ready[id] = true end
    elseif k == 'alreq' then
        local id = tonumber(v)
        if id and (not anim.layout_sent[id] or now() - anim.layout_sent[id] > 0.5) then anim.send_layout(id) end
    elseif k == "anres" then
        local id, desc = v:match("^(%d+):(.*)$")
        id = tonumber(id)
        if id and fnv32(desc) == id then
            local bt, count, bank, skel, dyn = desc:match("^(%d+)|(%d+)|([^|]+)|([^|]+)$")
            if not bt then bt, count, bank, skel, dyn = desc:match("^(%d+)|(%d+)|([^|]+)|([^|]+)|([^|]+)$") end
            bt, count, dyn = tonumber(bt), tonumber(count), anim.parse_dynamic(dyn)
            if bt and bt <= 0xFFFFFFFF and count and count >= 1 and count <= 16 and dyn ~= false
                and anim.asset_path(bank, "Animation/", ".motbank") and anim.asset_path(skel, "Character/", ".refskel") then
                anim.remote[id] = { bank = bank, skeleton = skel, target = bt, count = count, dyn = dyn }
            end
        end
    elseif k == "anready" then
        local id = tonumber(v)
        if id and anim.descriptors[id] then anim.ready[id] = now() end
    elseif k == "anfail" then
        anim.ready[tonumber(v) or -1] = nil
    end
end

function anim.tick()
    -- Identity of the partner session only. link.connected is "pose packets in the last 3 s", which
    -- drops at every title screen, cutscene and load; including it re-negotiated everything (and fell
    -- back to bone streaming) after each one. A restarted partner re-requests missing definitions.
    local peer = tostring(link.mode) .. ":" .. tostring(link.peer) .. ":" .. tostring(link.lobby)
    if anim.peer ~= peer then
        anim.peer, anim.peer_version, anim.ready, anim.remote = peer, 0, {}, {}
        anim.compact_peer, anim.layout_ready = false, {}
        anim.header_peer, anim.bone_peer, anim.batch_peer, anim.header_ready = false, false, false, {}
        anim.state2_peer, anim.peer_mod_version = false, nil
        anim.last_announce = -100
    end
    if anim.emit and now() - anim.last_announce >= 2 then
        anim.last_announce = now()
        anim.emit("anver:1")
        anim.emit("ancompact:2")
        anim.emit("anbones:1"); anim.emit("anhead:1"); anim.emit("enbatch:1"); anim.emit("anstate:2")
        anim.emit("modver:" .. anim.MOD_VERSION)
        if anim.peer_version == 1 then
            for id, desc in pairs(anim.descriptors) do anim.emit("anres:" .. id .. ":" .. desc) end
        end
        for address, entry in pairs(anim.capture_cache) do
            if now() - entry.touched > 5 then anim.capture_cache[address] = nil end
        end
    end
end

function anim.can_send(a)
    return a and (cfg.mirror_test or link.mode == 'echo' or anim.peer_version==1)
        and anim.ready[a.id] and now()-anim.ready[a.id]<5
end

-- receiver: keep native playback running between packets. Correct significant
-- phase error, rather than restarting the motion or setting bones every frame.
function anim.apply(target, a, stamp, age)
    local d = anim.remote[a.id]
    if not d and (cfg.mirror_test or link.mode == "echo") then
        anim.event("anres", a.id .. ":" .. (anim.descriptors[a.id] or ""))
        d = anim.remote[a.id]
    end
    if not d then return false, "waiting for animation resources" end
    local m = target.anim_motion or target.go:call("getComponent(System.Type)", T_MOTION)
    if not m then return false, "missing Motion component" end
    target.anim_motion = m
    if target.anim_id ~= a.id then
        local bank = anim.resource(d.bank, "MotionBank")
        local skel = anim.resource(d.skeleton, "Skeleton")
        if not bank or not skel then return false, "loading animation resources" end
        local ds = target.go:call("getComponent(System.Type)", T_DUMMYSKEL)
        if not ds then return false, "missing skeleton" end
        local current_skel = ds:call("get_SkeletonResourceHandle")
        if not current_skel or current_skel:call("get_ResourcePath") ~= d.skeleton then
            ds:call("set_SkeletonResourceHandle", skel)
        end
        local dyn = {}
        for i, e in ipairs(d.dyn or {}) do
            if e then
                local holder = anim.resource(e.path, "MotionBank")
                if not holder then return false, "loading animation resources" end
                local db = sdk.create_instance("via.motion.DynamicMotionBank")
                if not db then return false, "cannot create dynamic motion bank" end
                db = db:add_ref()
                db:call("set_MotionBank", holder)
                db:call("set_Priority", e.priority); db:call("set_Order", e.order)
                db:call("set_OverwriteBankID", e.flags & 1 ~= 0); db:call("set_BankID", e.bank)
                db:call("set_OverwriteBankType", e.flags & 2 ~= 0); db:call("set_BankType", e.type)
                db:call("set_OverwriteBankTypeMaskBit", e.flags & 4 ~= 0); db:call("set_BankTypeMaskBit", e.mask)
                dyn[i] = db
            end
        end
        local n = d.dyn and #d.dyn or 0
        local current_bank = m:call("get_MotionBankAsset")
        if not current_bank or current_bank:call("get_ResourcePath") ~= d.bank or m:call("get_TargetBankType") ~= d.target
            or n > 0 or (target.anim_dyn_n or 0) > 0 then
            m:call("set_MotionBankAsset", bank)
            m:call("set_TargetBankType", d.target)
            m:call("setDynamicMotionBankCount", n)
            for i = 1, n do m:call("setDynamicMotionBank", i - 1, dyn[i]) end
            m:call("setupMotionBank")
        end
        -- Keep the managed instances referenced for as long as the motion uses them.
        target.anim_dyn, target.anim_dyn_n = dyn, n
        m:call("setLayerCount", d.count)
        target.anim_layers, target.anim_id, target.anim_stamp, target.anim_valid = {}, a.id, nil, false
        target.anim_static = {}
        for i = 0, d.count - 1 do
            local l = m:call("getLayer", i)
            if not l then
                l = sdk.create_instance("via.motion.TreeLayer"):add_ref()
                m:call("setLayer", i, l)
            end
            target.anim_layers[i] = l
        end
        -- Resource changes may rebuild the joints. Never keep old joint handles.
        target.map = nil
    end
    if target.anim_enabled ~= true then m:call("set_Enabled", true); target.anim_enabled = true end
    if target.anim_stamp == stamp and target.anim_valid then return true, "native" end
    local active, valid = {}, true
    for _, s in ipairs(a.layers) do
        local l = target.anim_layers[s.slot]
        if not l then return false, "animation slot out of range" end
        if not m:call("hasMotion(System.UInt32, System.UInt32, System.Int32)", s.bank, s.motion, s.bank_type) then
            return false, "animation not available in motion bank"
        end
        active[s.slot] = true
        l:call("set_Enabled", true)
        if target.anim_stamp ~= stamp then
            -- changeLocalBankType restarts the layer's motion, so static settings
            -- are applied only when they change, not on every snapshot.
            local key = string.pack("<i4I4BBI4IB", s.bank_type, s.mask, s.mask_mode, s.blend_mode, s.namespace, s.base, s.wrap)
            if target.anim_static[s.slot] ~= key then
                target.anim_static[s.slot] = key
                l:call("changeLocalBankType", s.bank_type)
                l:call("set_JointMaskID", s.mask)
                l:call("set_JointMaskIDMode", s.mask_mode)
                l:call("set_BlendMode", s.blend_mode)
                l:call("set_JointNameSpaceHash", s.namespace)
                l:call("set_BaseLayerNo", s.base)
                l:call("set_WrapMode", s.wrap)
            end
            l:call("set_BlendRate", s.weight)
            local changed = l:call("get_MotionBankID") ~= s.bank or l:call("get_MotionID") ~= s.motion
            if changed or l:call("get_EndFrame") == 0 then
                l:call("changeMotion(System.UInt32, System.UInt32, System.Single)", s.bank, s.motion, 0.0)
            end
            local frame = s.frame + math.max(0, math.min(age or 0, 0.15)) * 60 * s.speed
            if s.ending > 0 then
                if s.wrap == 2 then frame = frame % s.ending else frame = math.max(0, math.min(s.ending, frame)) end
            end
            if changed or math.abs(l:call("get_Frame") - frame) > 3 then l:call("set_Frame", frame) end
            l:call("set_Speed", s.speed)
        end
        if l:call("get_EndFrame") <= 0 or l:call("get_MotionBankID") ~= s.bank or l:call("get_MotionID") ~= s.motion then valid = false end
    end
    for slot, l in pairs(target.anim_layers) do if not active[slot] then l:call("set_Enabled", false) end end
    target.anim_stamp = stamp
    if not target.map then
        target.map = {}
        local joints = target.tr:call("get_Joints")
        for i = 0, joints:get_size() - 1 do
            local j = joints:get_element(i)
            target.map[j:call("get_Name")] = j
        end
        if not next(target.map) then target.map = nil; valid = false end
    end
    target.anim_valid = valid
    if valid and anim.emit and (not target.anim_ack or now() - target.anim_ack > 1) then
        target.anim_ack = now()
        anim.emit("anready:" .. a.id)
    end
    return valid, valid and "native" or "waiting for motion setup"
end

function anim.try_apply(target, a, stamp, age)
    if not cfg.native_animation then
        if anim.emit and (not target.anim_fail or now() - target.anim_fail > 1) then
            target.anim_fail = now(); anim.emit("anfail:" .. a.id)
        end
        return false
    end
    local ok, result, message = pcall(anim.apply, target, a, stamp, age)
    if not ok or not result then
        if cfg.mirror_test or link.mode=='echo' then anim.ready[a.id]=nil end
        anim.error = tostring(ok and message or result)
        if anim.emit and (not target.anim_fail or now() - target.anim_fail > 1) then
            target.anim_fail = now()
            anim.emit("anfail:" .. a.id)
        end
        return false
    end
    anim.error = ""
    if cfg.mirror_test or link.mode=='echo' then anim.ready[a.id]=now() end
    return true
end

function anim.bones(target, preparing)
    preparing = preparing and cfg.native_animation and true or false
    local m = target.anim_motion or target.go:call("getComponent(System.Type)", T_MOTION)
    target.anim_motion = m
    if m and target.anim_enabled ~= preparing then m:call("set_Enabled", preparing); target.anim_enabled = preparing end
    if not target.map then
        target.map = {}
        local js = target.tr:call("get_Joints")
        for i = 0, js:get_size() - 1 do
            local j = js:get_element(i)
            target.map[j:call("get_Name")] = j
        end
    end
end

---------------------------------------------------------------------------
-- local state capture
---------------------------------------------------------------------------
local visual = { remote = {}, remote_text = {}, resources = {}, last_scan = -100, last_full = -100, error = "" }
visual.mesh_api = anim.accessors("via.render.Mesh")
-- Every costume mesh reports 256 part flags and there is no bulk getter, so a
-- full read is 256 reflected calls per mesh (~0.25 ms). Masks rarely change:
-- serve them from a cache and re-verify at most `mask_budget` meshes per scan,
-- each at most every 3 s. New meshes are always read in full.
visual.mask_cache, visual.mask_budget = {}, 0
function visual.part_mask(mesh, path)
    local key = tostring(mesh:get_address()) .. "|" .. tostring(path)
    local e, t = visual.mask_cache[key], now()
    if e and (t - e.read < 3 or visual.mask_budget <= 0) then e.seen = t; return e.bits, e.count end
    if e then visual.mask_budget = visual.mask_budget - 1 end
    local bits, count = visual.read_mask(mesh)
    visual.mask_cache[key] = { bits = bits, count = count, read = t, seen = t }
    return bits, count
end
-- Per-GameObject facts that do not change while the object lives (name, whether it
-- has a mesh / shadow-proxy / strands component) and resource path strings. Only
-- plain values are cached, never engine handles, and entries expire after 2 s.
visual.nodes = {}
function visual.node(g)
    local a, t = g:get_address(), now()
    local n = visual.nodes[a]
    if not n or t - n.t > 2 then n = { t = t, name = g:call("get_Name") }; visual.nodes[a] = n end
    n.seen = t
    return n
end
function visual.comp(g, n, field, T)
    local has = n[field]
    if has == false then return nil end
    local c = g:call("getComponent(System.Type)", T)
    n[field] = c ~= nil
    return c
end
-- Resource holders come back as a fresh wrapper object from every getter call, so
-- their addresses are not identities and must never be used as cache keys.
function visual.res_path(h)
    return h and h:call("get_ResourcePath") or nil
end
function visual.prune_masks()
    local t = now()
    for _, cache in ipairs({ visual.mask_cache, visual.nodes }) do
        for k, e in pairs(cache) do if t - e.seen > 30 then cache[k] = nil end end
    end
end
function visual.read_mask(mesh)
    local count = visual.mesh_api.getPartsEnableCount(mesh)
    assert(count <= 1024, "unsupported costume submesh count")
    local bytes = {}
    for first = 0, count - 1, 8 do
        local byte = 0
        for bit = 0, math.min(7, count - first - 1) do
            if visual.mesh_api.getPartsEnable(mesh, first + bit) then byte = byte | (1 << bit) end
        end
        bytes[#bytes + 1] = string.char(byte)
    end
    return anim.hex(table.concat(bytes)), count
end
visual.hair_props = { "ConstraintJointName", "RootBlendRate", "Opacity", "VertexLOD", "HairWidthScale",
    "MinimumHairWidth", "MaximumHairWidth", "Melanin", "MelaninRedness", "Roughness", "LongitudinalRoughness",
    "AzimuthalRoughness", "CuticleTiltDegreeSpec", "CuticleTiltAngle", "CuticleTiltDegree", "IOR", "RandomMelanin",
    "RandomRoughness", "TipRate", "TipMelanin", "TipRoughness", "BackScatterScale", "RenderPass", "RenderMethod",
    "LODEnable", "LODFactor", "LODFactorAutoEnable", "LODFactorAutoResolutionEnable" }
function visual.key(st) return tostring(st.kind) .. ":" .. tostring(st.mm) .. ":" .. tostring(st.mp) end
function visual.path(path)
    return type(path) == "string" and #path < 240 and path:sub(1, 10):lower() == "character/"
        and not path:find("..", 1, true) and not path:find("[\r\n]")
end
function visual.resource(path, kind, namespace)
    if not visual.path(path) then return nil end
    namespace = namespace or "via.render."
    local key = namespace .. kind .. ":" .. path
    if visual.resources[key] then return visual.resources[key] end
    local r = sdk.create_resource(namespace .. kind .. "Resource", path)
    local h = r and r:create_holder(namespace .. kind .. "ResourceHolder")
    if h then visual.resources[key] = h:add_ref() end
    return h
end
function visual.scan(go, st)
    local key = visual.key(st)
    local changed = visual.address ~= go:get_address() or visual.key_now ~= key or visual.peer ~= anim.peer
    -- Character/model/peer changes rescan at once; otherwise every 3 s (a full walk
    -- is ~0.7 ms of engine calls even with caches). Part masks refresh on a rolling basis.
    if not changed and now() - visual.last_scan < 3 then return end
    visual.address, visual.key_now, visual.peer, visual.last_scan = go:get_address(), key, anim.peer, now()
    visual.mask_budget = 2
    visual.prune_masks()
    local ds = go:call("getComponent(System.Type)", T_DUMMYSKEL)
    local sk = ds and ds:call("get_SkeletonResourceHandle")
    if not sk then return end
    local scale = go:call("get_Transform"):call("get_LocalScale")
    local recipe = { key = key, skeleton = sk:call("get_ResourcePath"), scale = { scale.x, scale.y, scale.z }, parts = {} }
    local child = go:call("get_Transform"):call("get_Child")
    while child do
        local g = child:call("get_GameObject")
        local node = visual.node(g)
        local mesh = visual.comp(g, node, "mesh", JM.T_MESH)
        local mh = mesh and mesh:call("getMesh")
        local path = visual.res_path(mh)
        if path and path:sub(1, 13):lower() == "character/ch/" then
            local mat = mesh:call("get_Material")
            local bits, count = visual.part_mask(mesh, path)
            local part = { name = node.name, mesh = path, material = visual.res_path(mat), bits = bits, bit_count = count }
            local c = child:call("get_Child")
            while c do
                local hairgo = c:call("get_GameObject")
                local hair = visual.comp(hairgo, visual.node(hairgo), "strands", JM.T_STRANDS)
                if hair then
                    local sh, sm = hair:call("get_Strand"), hair:call("get_Material")
                    local dyn = hairgo:call("getComponent(System.Type)", sdk.typeof("via.dynamics.GpuStrandsDynamics"))
                    local binding = dyn and dyn:call("get_StrandBindingData")
                    local binder = hairgo:call("getComponent(System.Type)", sdk.typeof("app.MontageStrandsDynamicsBinder"))
                    part.hair = { name = hairgo:call("get_Name"), strand = sh and sh:call("get_ResourcePath"),
                        material = sm and sm:call("get_ResourcePath"), binding = binding and binding:call("get_ResourcePath"),
                        bind_target = binder and binder:call("get_BindTargetName"), props = {} }
                    if not visual.hair_getters then
                        visual.hair_getters = {}
                        local td = sdk.find_type_definition("via.render.Strands")
                        for _, prop in ipairs(visual.hair_props) do visual.hair_getters[prop] = td:get_method("get_" .. prop) or false end
                    end
                    for _, prop in ipairs(visual.hair_props) do
                        local getter = visual.hair_getters[prop]
                        local ok, value = false, nil
                        if getter then ok, value = pcall(getter.call, getter, hair) end
                        if ok and (type(value) == "number" or type(value) == "boolean" or type(value) == "string") then part.hair.props[prop] = value end
                    end
                end
                c = c:call("get_Next")
            end
            recipe.parts[#recipe.parts + 1] = part
        end
        child = child:call("get_Next")
    end
    local text = json.dump_string(recipe)
    if (cfg.mirror_test or link.mode == "echo") and visual.remote_text[key] ~= text then
        visual.remote[key], visual.remote_text[key] = recipe, text
    end
    if changed or text ~= visual.text or now() - visual.last_full > 10 then
        visual.text, visual.last_full = text, now()
        if visual.emit then visual.emit("model:" .. text) end
    end
end
function visual.receive(text)
    if #text > 32000 then return end
    local d = json.load_string(text)
    if type(d) ~= "table" or type(d.key) ~= "string" or #d.key > 120 or not visual.path(d.skeleton)
        or type(d.parts) ~= "table" or #d.parts > 32 then return end
    if visual.remote_text[d.key] == text then return end
    for _, part in ipairs(d.parts) do
        if type(part.name) ~= "string" or #part.name > 80 or not visual.path(part.mesh)
            or not visual.path(part.material) or type(part.bits) ~= "string" or type(part.bit_count) ~= "number"
            or part.bit_count < 0 or part.bit_count > 1024 or part.bit_count % 1 ~= 0
            or #part.bits ~= ((part.bit_count + 7) // 8) * 2 or part.bits:find('[^0-9a-f]') then return end
        if part.hair then
            local h = part.hair
            if type(h.name) ~= "string" or #h.name > 120 or not visual.path(h.strand) or not visual.path(h.material)
                or type(h.props) ~= "table" or (h.binding and not visual.path(h.binding)) then return end
        end
    end
    visual.remote[d.key], visual.remote_text[d.key] = d, text
end
function visual.apply(target)
    for _, entry in ipairs(target.hair_dynamics or {}) do
        if not entry.component:call("get_Initialized") and now() - entry.last_reset > 0.5 then
            entry.component:call("ResetSimulation"); entry.last_reset = now()
        end
    end
    local d = visual.remote[visual.key(target)]
    if not d or target.visual_applied == d then return end
    local parts = {}
    target.hair_dynamics = {}
    local child = target.tr:call("get_Child")
    while child do local g = child:call("get_GameObject"); parts[g:call("get_Name")] = g; child = child:call("get_Next") end
    for _, part in ipairs(d.parts) do
        local go = parts[part.name]
        local mesh = go and go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
        if not mesh then return end -- montage is still being assembled
        local mh, mat = mesh:call("getMesh"), mesh:call("get_Material")
        if not mh or mh:call("get_ResourcePath") ~= part.mesh then mesh:call("setMesh", visual.resource(part.mesh, "Mesh")) end
        if not mat or mat:call("get_ResourcePath") ~= part.material then mesh:call("set_Material", visual.resource(part.material, "MeshMaterial")) end
        local mask = anim.unhex(part.bits)
        for i = 0, part.bit_count - 1 do
            visual.mesh_api.setPartsEnable(mesh, i, mask:byte(i // 8 + 1) & (1 << (i % 8)) ~= 0)
        end
        if part.hair then
            local h = part.hair
            local ct = go:call("get_Transform"):call("get_Child")
            local hairgo
            while ct do local g = ct:call("get_GameObject"); if g:call("get_Name") == h.name then hairgo = g; break end; ct = ct:call("get_Next") end
            local hair = hairgo and hairgo:call("getComponent(System.Type)", sdk.typeof("via.render.Strands"))
            if not hair then return end
            local current_strand, current_material = hair:call("get_Strand"), hair:call("get_Material")
            local strand_changed = not current_strand or current_strand:call("get_ResourcePath") ~= h.strand
            if strand_changed then hair:call("set_Strand", visual.resource(h.strand, "Strands")) end
            if not current_material or current_material:call("get_ResourcePath") ~= h.material then
                hair:call("set_Material", visual.resource(h.material, "MeshMaterial"))
            end
            for _, prop in ipairs(visual.hair_props) do
                if h.props[prop] ~= nil then pcall(hair.call, hair, "set_" .. prop, h.props[prop]) end
            end
            local dyn = hairgo:call("getComponent(System.Type)", sdk.typeof("via.dynamics.GpuStrandsDynamics"))
            if dyn then
                local current_binding = dyn:call("get_StrandBindingData")
                if h.binding and (not current_binding or current_binding:call("get_ResourcePath") ~= h.binding) then
                    dyn:call("set_StrandBindingData", visual.resource(h.binding, "StrandsBinding"))
                end
                if h.bind_target and parts[h.bind_target] then
                    local ref = ValueType.new(sdk.find_type_definition("via.GameObjectRef"))
                    ref:call(".ctor(via.GameObject)", parts[h.bind_target])
                    dyn:call("set_BindingGameObject", ref)
                end
                if strand_changed or not dyn:call("get_Initialized") then dyn:call("ResetSimulation") end
                target.hair_dynamics[#target.hair_dynamics + 1] = { component = dyn, last_reset = now() }
            end
        end
    end
    if type(d.scale) == "table" and #d.scale == 3 then target.tr:call("set_LocalScale", Vector3f.new(d.scale[1], d.scale[2], d.scale[3])) end
    target.visual_applied = d
end
local local_cache = { addr = nil, joints = nil, names = nil }

local function capture_local(ctx, go)
    local gaddr = go:get_address()
    if local_cache.addr ~= gaddr then
        local tr = go:call("get_Transform")
        local js = tr:call("get_Joints")
        local joints, names = {}, {}
        for i = 0, js:get_size() - 1 do
            local j = js:get_element(i)
            joints[#joints + 1] = j
            names[#names + 1] = j:call("get_Name")
        end
        local_cache = { addr = gaddr, tr = tr, joints = joints, names = names, sk = fnv32(table.concat(names, ",")) }
    end
    local tr = local_cache.tr
    local p, r = tr:call("get_Position"), tr:call("get_Rotation")
    local c0 = os.clock()
    local ok_anim, a = pcall(anim.capture, go)
    local c1 = os.clock()
    if not ok_anim then anim.error = tostring(a); a = nil end
    local native = anim.can_send(a)
    local q, lp = {}, {}
    if not native then
        local get_lr, get_lp, names, k = JM.get_lr, JM.get_lp, local_cache.names, 0
        for i, j in ipairs(local_cache.joints) do
            local lr = get_lr:call(j)
            q[k + 1] = r4(lr.x); q[k + 2] = r4(lr.y); q[k + 3] = r4(lr.z); q[k + 4] = r4(lr.w); k = k + 4
            local n = names[i]
            if POS_JOINTS[n] then
                local l = get_lp:call(j)
                lp[n] = { r3(l.x), r3(l.y), r3(l.z) }
            end
        end
    end
    local c2 = os.clock()
    local mid = ctx:call("get_MontageID")
    local st = {
        v = 1,
        kind = ctx:call("get_KindID"):call("ToString"),
        mm = mid:call("get_ModelID"), mp = mid:call("get_PresetID"),
        area = area_of(go),
        pos = { r3(p.x), r3(p.y), r3(p.z) },
        rot = { r4(r.x), r4(r.y), r4(r.z), r4(r.w) },
        sk = local_cache.sk,
        q = q, lp = lp, an = a,
    }
    local c3 = os.clock()
    local ok_visual, error_visual = pcall(visual.scan, go, st)
    if not ok_visual then visual.error = tostring(error_visual) end
    local c4 = os.clock()
    prof_add("cap_anim", (c1 - c0) * 1000); prof_add("cap_bones", (c2 - c1) * 1000)
    prof_add("cap_meta", (c3 - c2) * 1000); prof_add("cap_scan", (c4 - c3) * 1000)
    return st
end

---------------------------------------------------------------------------
-- puppet
---------------------------------------------------------------------------
local puppet_fail = nil  -- { kind, until }: the partner's character couldn't be built here; don't retry constantly
local puppet = nil   -- { go, tr, kind, mm, mp, area, state, t0, map = {name->joint}, cur = {...} }

local function destroy_puppet()
    if torch then torch.clear() end
    if puppet and puppet.weps then
        for _, e in pairs(puppet.weps) do pcall(function() GO_DESTROY:call(nil, e.go) end) end
    end
    if puppet and puppet.go then
        pcall(function() if puppet.go:call("get_Valid") then GO_DESTROY:call(nil, puppet.go) end end)
    end
    puppet = nil
end

local function create_puppet(cm, pgo, st)
    local kind = find_kind(st.kind)
    if not kind then status = "unknown partner character " .. tostring(st.kind); return end
    local recipe = visual.remote[visual.key(st)]
    local skeleton = recipe and anim.resource(recipe.skeleton, "Skeleton")
    if not skeleton and st.an and anim.remote[st.an.id] then skeleton = anim.resource(anim.remote[st.an.id].skeleton, "Skeleton") end
    if not skeleton then
        local _, ctx = get_player()
        if ctx and ctx:call("get_KindID"):call("ToString") == st.kind then
            local ds = pgo:call("getComponent(System.Type)", T_DUMMYSKEL)
            skeleton = ds and ds:call("get_SkeletonResourceHandle")
        end
    end
    if not skeleton then status = "waiting for partner's model resources"; return end
    local go = GO_CREATE:call(nil, "coop_partner", pgo:call("get_Folder"))
    if not go then status = "could not create puppet object"; return end
    go = go:add_ref()
    local tr = go:call("get_Transform")
    tr:call("set_Position", Vector3f.new(st.pos[1], st.pos[2], st.pos[3]))
    tr:call("set_Rotation", Quaternion.new(st.rot[4], st.rot[1], st.rot[2], st.rot[3]))
    local ds = go:call("createComponent(System.Type)", T_DUMMYSKEL)
    ds:call("set_SkeletonResourceHandle", skeleton)
    go:call("createComponent(System.Type)", T_MOTION)
    local mid = ValueType.new(MONTAGE_TD)
    mid:set_field("<ModelID>k__BackingField", st.mm or 100)
    mid:set_field("<PresetID>k__BackingField", st.mp or 1)
    cm:call(REQ_MONTAGE, go, kind, mid, nil, false, 0, false)
    puppet = { go = go, tr = tr, kind = st.kind, mm = st.mm, mp = st.mp, area = st.area, folder = pgo:call("get_Folder"),
               player_addr = pgo:get_address(), state = "dressing", t0 = now(), map = nil, cur = nil, visible = nil }
    status = "dressing puppet (" .. st.kind .. ")"
end

-- Once the montage parts exist, finish the already assigned sender skeleton.
local function finish_puppet(pgo)
    local n = 0
    for_descendants(puppet.tr, function() n = n + 1 end)
    if n == 0 then
        if now() - puppet.t0 > 10 then
            puppet_fail = { kind = puppet.kind, ["until"] = now() + 30 }
            destroy_puppet()
        end
        return
    end
    local ds = puppet.go:call("getComponent(System.Type)", T_DUMMYSKEL)
    if not ds then ds = puppet.go:call("createComponent(System.Type)", T_DUMMYSKEL) end
    if not ds then status = "partner skeleton not ready"; return end
    local js = puppet.tr:call("get_Joints")
    if not js or js:get_size() == 0 then return end -- try again next frame
    puppet.map = {}
    for i = 0, js:get_size() - 1 do
        local j = js:get_element(i)
        puppet.map[j:call("get_Name")] = j
    end
    -- Preserve complete costume meshes. Free simulation on a manually moved
    -- ghost is unsafe; keep the rendered jacket and its native skinning instead.
    puppet.hidden, puppet.base_draw = {}, {}
    for_descendants(puppet.tr, function(g)
        local arr = g:call("get_Components")
        for i = 0, arr:get_size() - 1 do
            local comp = arr:get_element(i)
            local cn = comp:get_type_definition():get_full_name()
            if cn == "via.motion.Chain2" or cn == "app.ActorChain2" or cn == "app.CharacterChainMoveController"
                or cn == "via.dynamics.GpuCloth" or cn == "app.ActorGpuCloth"
                or cn:find("JacketMeshPartsController") or cn:find("JacketBlendShapeController") then
                pcall(comp.call, comp, "set_Enabled", false)
            end
        end
        puppet.base_draw[g:get_address()] = g:call("get_DrawSelf")
        local gt = g:call("get_Transform")
        local mesh = g:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
        local mh = mesh and mesh:call("getMesh")
        -- Montage objects initially arrive with DrawSelf off. Do not latch that
        -- loading state as permanent invisibility for costume parts or strands.
        if (gt:call("get_Parent") == puppet.tr and mh and mh:call("get_ResourcePath"):sub(1, 13):lower() == "character/ch/")
            or g:call("getComponent(System.Type)", sdk.typeof("via.render.Strands")) then
            puppet.base_draw[g:get_address()] = true
        end
        -- Disabling the chain wrapper can disable the entire body-part object.
        -- Mesh skinning and strand hair still need their normal update passes.
        g:call("set_UpdateSelf", true)
    end)
    puppet.state = "ready"
    puppet.visible = nil
    status = "partner puppet ready"
end

local function set_puppet_visible(v)
    if puppet.visible == v then return end
    puppet.visible = v
    puppet.go:call("set_DrawSelf", v)
    if puppet.weps then for _, e in pairs(puppet.weps) do e.draw = nil; pcall(e.go.call, e.go, "set_DrawSelf", v) end end
    local hidden = puppet.hidden or {}
    for_descendants(puppet.tr, function(g)
        local hide = hidden[g:get_address()]
        if not hide then
            -- children of a hidden part (e.g. its shadow mesh) stay hidden too
            local par = g:call("get_Transform"):call("get_Parent")
            hide = par and hidden[par:call("get_GameObject"):get_address()]
        end
        local base = puppet.base_draw and puppet.base_draw[g:get_address()]
        g:call("set_DrawSelf", v and not hide and base ~= false)
    end)
end

---------------------------------------------------------------------------
-- partner state intake
---------------------------------------------------------------------------
local partner = nil        -- latest packet
local partner_names = nil  -- joint names for partner.q (sent periodically)
local partner_sk = nil
local partner_rx_time = -1000
local mirror_queue = {}

local snaps = {}           -- recent partner snapshots, oldest first
local clock_offset = nil  -- estimate of (our clock - partner clock)
-- connection quality, measured from the partner's packets
local net = { jitter = 0.01, interval = 1 / 30, delay = 0.06, last_t = nil, count = 0, rate = 0, rate_t = 0, extrapolating = false }

local function accept_packet(st, recv_time)
    if type(st) ~= "table" or type(st.q) ~= "table" or type(st.pos) ~= "table" or type(st.t) ~= "number" then return end
    if st.names then partner_names, partner_sk = st.names, st.sk end
    if partner and (st.t <= partner.t or st.kind ~= partner.kind) then
        if st.t <= partner.t - 1 or st.kind ~= partner.kind then snaps = {}; clock_offset = nil else return end
    end
    partner = st
    partner_rx_time = recv_time
    if enemy_hooks.packet_in then pcall(enemy_hooks.packet_in, st) end
    -- clock offset: track the fastest delivery, slowly relax upwards (handles drift/jitter)
    local off = recv_time - st.t
    if not clock_offset or off < clock_offset then clock_offset = off
    else clock_offset = clock_offset + (off - clock_offset) * 0.01 end
    -- jitter: how late this packet is compared with the fastest one; interval: sender's spacing
    local late = off - clock_offset
    net.jitter = net.jitter * 0.9 + late * 0.1
    if net.last_t and st.t > net.last_t then net.interval = net.interval * 0.9 + (st.t - net.last_t) * 0.1 end
    net.last_t = st.t
    net.count = net.count + 1
    if recv_time - net.rate_t >= 1 then net.rate, net.count, net.rate_t = net.count, 0, recv_time end
    -- playback delay that just covers the measured spacing + jitter (or the fixed one from Options)
    if cfg.auto_interp then
        local want = net.interval * 1.5 + net.jitter * 2.5
        net.delay = math.max(0.035, math.min(0.25, net.delay + (want - net.delay) * 0.05))
    else
        net.delay = cfg.interp_ms / 1000
    end
    snaps[#snaps + 1] = st
    if #snaps > 32 then table.remove(snaps, 1) end
end

local last_in_seq = -1
local function poll_partner_file()
    local st = json.load_file(IN_FILE)
    if type(st) ~= "table" then return end
    if st.seq == last_in_seq then return end
    last_in_seq = st.seq
    accept_packet(st, now())
end

---------------------------------------------------------------------------
-- network protocol v5: compact binary packets through the plugin's in-memory bridge (coopnet.*)
-- Falls back to the old JSON files if the plugin is too old to have the bridge.
---------------------------------------------------------------------------
local function use_bridge()
    return type(coopnet) == "table" and coopnet.version ~= nil and coopnet.version() >= 5
end

local STATE_HEAD = "<I4dI4s1i2i2s1fffhhhhB"
-- State v2 (negotiated with "anstate:2"; lossless against v1's wire values):
--   seq|0x80000000 u32, time u32 ms, sk/header id u32, flags u8,
--   [kind s1, mm i2, mp i2, area s1 unless header-cached], pos fff,
--   root rotation hhhh, or hh (y,w) with flag 8 when x and z quantize to 0.
-- os.clock() is clock()/1000, so whole milliseconds reproduce the same double.
-- v1 seq never reaches 2^31, so the top bit identifies v2 packets.
anim.STATE2_HEAD, anim.STATE2_BIT = "<I4I4I4B", 0x80000000
local function pack_state(st)
    local qi = {}
    for i = 1, #st.q do qi[i] = q16(st.q[i]) end
    local lr = st.lp and st.lp.root
    local lh = st.lp and st.lp.Hip
    local extension = st.an and (anim.peer_version == 1 or link.mode == "echo") and anim.pack(st.an)
    local bone_data, sparse = anim.pack_bones(qi)
    local header = anim.header(st)
    local flags = (lr and 1 or 0) | (lh and 2 or 0) | (extension and 4 or 0) | (sparse and 16 or 0) | (header and 32 or 0)
    local rx, ry, rz, rw = q16(st.rot[1]), q16(st.rot[2]), q16(st.rot[3]), q16(st.rot[4])
    local ms = math.floor(st.t * 1000 + 0.5)
    local parts
    -- (whole-millisecond check keeps v2 exact for any caller-supplied time)
    if (anim.state2_peer or link.mode == "echo") and st.seq < anim.STATE2_BIT and ms >= 0 and ms <= 0xFFFFFFFF
        and ms / 1000 == st.t then
        local yaw = rx == 0 and rz == 0
        flags = flags | (yaw and 8 or 0)
        parts = { string.pack(anim.STATE2_HEAD, st.seq | anim.STATE2_BIT, ms, header or st.sk, flags) }
        if not header then
            parts[#parts + 1] = string.pack("<s1i2i2s1", st.kind or "", st.mm or 0, st.mp or 0, st.area or "")
        end
        parts[#parts + 1] = yaw and string.pack("<fffhh", st.pos[1], st.pos[2], st.pos[3], ry, rw)
            or string.pack("<fffhhhh", st.pos[1], st.pos[2], st.pos[3], rx, ry, rz, rw)
    else
        parts = { string.pack(STATE_HEAD, st.seq, st.t, header or st.sk, header and "" or st.kind or "",
            header and 0 or st.mm or 0, header and 0 or st.mp or 0, header and "" or st.area or "",
            st.pos[1], st.pos[2], st.pos[3], rx, ry, rz, rw, flags) }
    end
    if lr then parts[#parts + 1] = string.pack("<fff", lr[1], lr[2], lr[3]) end
    if lh then parts[#parts + 1] = string.pack("<fff", lh[1], lh[2], lh[3]) end
    parts[#parts + 1] = string.pack("<H", #qi // 4)
    parts[#parts + 1] = bone_data
    if extension then parts[#parts + 1] = extension end
    local bytes = table.concat(parts)
    anim.bytes = #bytes
    anim.last_sparse, anim.last_header = sparse, header ~= nil
    return bytes
end

local function unpack_state(b)
    assert(type(b)=='string' and #b<=16384,'invalid player packet size')
    local seq, t, sk, kind, mm, mp, area, px, py, pz, ra, rb, rc, rd, flags, at
    if #b >= 4 and string.unpack("<I4", b) & anim.STATE2_BIT ~= 0 then
        local ms
        seq, ms, sk, flags, at = string.unpack(anim.STATE2_HEAD, b)
        seq, t = seq & ~anim.STATE2_BIT, ms / 1000
        assert(flags & ~63 == 0, 'invalid player header')
        if flags & 32 ~= 0 then kind, mm, mp, area = "", 0, 0, ""
        else kind, mm, mp, area, at = string.unpack("<s1i2i2s1", b, at) end
        if flags & 8 ~= 0 then
            px, py, pz, rb, rd, at = string.unpack("<fffhh", b, at); ra, rc = 0, 0
        else
            px, py, pz, ra, rb, rc, rd, at = string.unpack("<fffhhhh", b, at)
        end
    else
        seq, t, sk, kind, mm, mp, area, px, py, pz, ra, rb, rc, rd, flags, at = string.unpack(STATE_HEAD, b)
        assert(flags & ~55 == 0 and anim.finite(t,1e10),'invalid player header')
    end
    local st = { v = 5, seq = seq, t = t, sk = sk, kind = kind, mm = mm, mp = mp, area = area,
        pos = { px, py, pz }, rot = { uq16(ra), uq16(rb), uq16(rc), uq16(rd) }, lp = {} }
    if flags & 32 ~= 0 then
        local h = anim.header_remote[sk]
        if not h then
            if anim.emit and (not anim.header_requested[sk] or now() - anim.header_requested[sk] > 0.5) then
                anim.header_requested[sk] = now(); anim.emit('shreq:' .. sk)
            end
            error('unknown state header')
        end
        st.sk, st.kind, st.mm, st.mp, st.area = h.sk, h.kind, h.mm, h.mp, h.area
    end
    assert(#st.kind>0 and #st.kind<=80 and not st.kind:find('[%c]') and not st.area:find('[%c]')
        and anim.valid_transform(st.pos,st.rot),'invalid player transform')
    local x, y, z
    if flags & 1 ~= 0 then x, y, z, at = string.unpack("<fff", b, at); assert(anim.finite(x) and anim.finite(y) and anim.finite(z),'invalid root offset');st.lp.root = { x, y, z } end
    if flags & 2 ~= 0 then x, y, z, at = string.unpack("<fff", b, at); assert(anim.finite(x) and anim.finite(y) and anim.finite(z),'invalid hip offset');st.lp.Hip = { x, y, z } end
    local n
    n, at = string.unpack("<H", b, at)
    st.q, at = anim.unpack_bones(b, at, n, flags & 16 ~= 0)
    if flags & 4 ~= 0 then st.an = anim.unpack(b, at) else assert(at==#b+1,'trailing player data') end
    assert(n > 0 or st.an, "empty pose without animation")
    return st
end

-- joint names travel once per skeleton (reliable event "nm:<hash>:a,b,c"); ask again if unknown
local names_by_sk = {}
local names_sent_sk, names_sent_t = nil, 0
local names_asked = {}
local net_events = {}   -- events from the partner, handled by the lobby code

local function bridge_event(text)
    if use_bridge() then pcall(coopnet.send_event, text) end
end
anim.emit = bridge_event
visual.emit = bridge_event

local function announce_names(force)
    if not (local_cache and local_cache.names and local_cache.sk) then return end
    if not force and names_sent_sk == local_cache.sk and now() - names_sent_t < 10 then return end
    names_sent_sk, names_sent_t = local_cache.sk, now()
    bridge_event("nm:" .. local_cache.sk .. ":" .. table.concat(local_cache.names, ","))
end

---------------------------------------------------------------------------
-- held weapons: each game announces the weapon objects drawn on its player (name, hand joint,
-- mesh + material paths, offset); the partner's puppet gets copies pinned to its own joints
---------------------------------------------------------------------------
local WEP_HZ = 2
local wep = { last_sig = nil, last_send = 0, last_full = 0, res = {}, last_hello=-100 }
local partner_weps = nil

local function scan_local_weapons(pgo)
    local list,entries = {},{}
    visual.mask_budget = 2
    local root=pgo:call("get_Transform")
    local visited=0
    local function visit(c,path,depth)
        if depth>12 or visited>256 or #entries>=24 then return end
        local g=c:call('get_GameObject');local node=visual.node(g);local name=node.name;visited=visited+1
        -- DrawSelf on a shadow child does not make its hidden inventory parent
        -- visible. Shadow proxies must never become standalone equipment.
        if not g:call('get_DrawSelf') or name=='Shadow' or name=='ShadowBody'
            or visual.comp(g,node,'shadow',JM.T_SHADOW_ITEM) then return end
        path=path=='' and name or path..'/'..name
        do
            local mesh = visual.comp(g, node, 'mesh', JM.T_MESH)
            if mesh and mesh:call('get_Enabled') then
                local okm, mp = pcall(function() return visual.res_path(mesh:call("getMesh")) end)
                local okt, tp = pcall(function() return visual.res_path(mesh:call("get_Material")) end)
                if okm and type(mp) == "string" and mp:sub(1,13):lower()=="character/wp/" then
                    local anchor,joint,pj=c,nil,nil
                    while anchor and anchor~=root do
                        local name=anchor:call("get_ParentJoint")
                        if name and name~="" then joint=root:call("getJointByName",name);if joint then pj=name;break end end
                        anchor=anchor:call("get_Parent")
                    end
                    local js=c:call('get_Joints')
                    local skin=not joint and js and js:get_size()>0
                    if skin then pj='root';joint=root end
                    if joint and okt and visual.path(tp) then
                        local p,r=c:call('get_Position'),c:call('get_Rotation')
                        local jp,jr=joint:call('get_Position'),joint:call('get_Rotation')
                        local x,y,z=qrot(-jr.x,-jr.y,-jr.z,jr.w,p.x-jp.x,p.y-jp.y,p.z-jp.z)
                        local qx,qy,qz,qw=qmul(-jr.x,-jr.y,-jr.z,jr.w,r.x,r.y,r.z,r.w)
                        local scale=c:call('get_LocalScale');local bits,count=visual.part_mask(mesh,mp)
                        local w={name=path,joint=pj,mesh=mp,mat=tp,lp={r3(x),r3(y),r3(z)},lr={r4(qx),r4(qy),r4(qz),r4(qw)},
                            scale={scale.x,scale.y,scale.z},bits=bits,bit_count=count,skin=skin or false}
                        if skin then
                            local motion=g:call('getComponent(System.Type)',T_MOTION)
                            local bank=motion and motion:call('get_MotionBankAsset')
                            local layer=motion and motion:call('getLayer',0)
                            if bank and layer then
                                w.motion={path=bank:call('get_ResourcePath'),target=motion:call('get_TargetBankType'),
                                    bank=layer:call('get_MotionBankID'),id=layer:call('get_MotionID'),kind=layer:call('get_MotionBankType'),
                                    wrap=layer:call('get_WrapMode'),speed=layer:call('get_Speed')}
                            end
                        else
                            list[#list + 1] = string.format("%s|%s|%s|%s|%.3f,%.3f,%.3f|%.4f,%.4f,%.4f,%.4f", path,pj,mp,tp,x,y,z,qx,qy,qz,qw)
                        end
                        entries[#entries+1]=w
                    end
                end
            end
        end
        local child=c:call('get_Child')
        while child do visit(child,path,depth+1);child=child:call('get_Next') end
    end
    local child=root:call('get_Child')
    while child do visit(child,'',1);child=child:call('get_Next')end
    table.sort(entries,function(a,b)return a.name<b.name end)
    return table.concat(list, ";"),entries
end

local function announce_weapons(pgo, force)
    if not force and now() - wep.last_send < 1 / WEP_HZ then return end
    wep.last_send = now()
    local peer=tostring(link.mode)..':'..tostring(link.peer)..':'..tostring(link.lobby)
    if wep.peer~=peer then wep.peer=peer;wep.peer_v1=false;wep.remote_v1=false;wep.last_json=nil;wep.last_hello=-100 end
    if now()-wep.last_hello>2 then bridge_event('equipver:1');wep.last_hello=now() end
    local sig,entries = scan_local_weapons(pgo)
    local text=json.dump_string({version=1,items=entries})
    if force or text~=wep.last_json or now() - wep.last_full > 5 then
        wep.last_sig,wep.last_json,wep.last_full=sig,text,now()
        if wep.peer_v1 then bridge_event('equip1:'..text) else bridge_event("wp:" .. sig) end
    end
end

function wep.decode(text)
    assert(type(text)=='string' and #text<=32000,'invalid equipment packet size')
    local d=json.load_string(text)
    assert(type(d)=='table' and d.version==1 and (d.items==nil or type(d.items)=='table'),'invalid equipment recipe')
    local out,seen={},{}
    for _,w in ipairs(d.items or {})do
        assert(#out<24 and type(w)=='table' and type(w.name)=='string' and #w.name>0 and #w.name<=160 and not seen[w.name],'invalid equipment name')
        assert(type(w.joint)=='string' and #w.joint<=80 and anim.asset_path(w.mesh,'Character/','.mesh')
            and anim.asset_path(w.mat,'Character/','.mdf2'),'invalid equipment resource')
        assert(type(w.lp)=='table' and type(w.lr)=='table' and anim.valid_transform(w.lp,w.lr)
            and math.abs(w.lp[1])+math.abs(w.lp[2])+math.abs(w.lp[3])<20,'invalid equipment offset')
        assert(type(w.scale)=='table' and #w.scale==3,'invalid equipment scale')
        for _,v in ipairs(w.scale)do assert(anim.finite(v,10) and v>0,'invalid equipment scale')end
        assert(type(w.skin)=='boolean' and type(w.bit_count)=='number' and w.bit_count%1==0 and w.bit_count>=0 and w.bit_count<=1024
            and type(w.bits)=='string' and #w.bits==((w.bit_count+7)//8)*2 and not w.bits:find('[^0-9a-f]'),'invalid equipment mask')
        if w.motion then
            local m=w.motion
            assert(w.skin and type(m)=='table' and anim.asset_path(m.path,'Animation/','.motbank'),'invalid accessory motion')
            for _,k in ipairs({'target','bank','id','kind','wrap'})do assert(anim.finite(m[k],0x100000001) and m[k]%1==0,'invalid accessory motion ID')end
            assert(m.wrap>=0 and m.wrap<=4 and anim.finite(m.speed,101),'invalid accessory speed')
        end
        seen[w.name]=true;out[#out+1]=w
    end
    return out
end

local function parse_weapons(sig)
    local list = {}
    for entry in (sig .. ";"):gmatch("([^;]*);") do
        local name, joint, mesh, mat, lp, lr = entry:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
        if name and mesh and mesh ~= "" then
            local x, y, z = lp:match("^([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)$")
            local qx, qy, qz, qw = lr:match("^([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)$")
            list[#list + 1] = { name = name, joint = joint, mesh = mesh, mat = mat,
                lp = { tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0 },
                lr = { tonumber(qx) or 0, tonumber(qy) or 0, tonumber(qz) or 0, tonumber(qw) or 1 } }
        end
    end
    return list
end

local function res_holder(kind, path)
    local key = kind .. ":" .. path
    local h = wep.res[key]
    if h == nil then
        local r = sdk.create_resource("via.render." .. kind .. "Resource", path)
        h = r and r:create_holder("via.render." .. kind .. "ResourceHolder"):add_ref() or false
        wep.res[key] = h
    end
    return h or nil
end

local function split_csv(str)
    local out = {}
    for item in str:gmatch("[^,]+") do out[#out + 1] = item end
    return out
end

local function net_poll()
    if not use_bridge() then return false end
    local ok, items = pcall(coopnet.poll)
    if not ok or type(items) ~= "table" then return true end
    for _, it in ipairs(items) do
        if it.k == "S" then
            local okU, st = pcall(unpack_state, it.d)
            if okU and st then
                if it.e then
                    st.echo = true
                    names_by_sk[st.sk] = names_by_sk[st.sk] or (local_cache and local_cache.names)
                    if wep.last_json and visual.echo_weapons ~= wep.last_json then
                        visual.echo_weapons = wep.last_json
                        partner_weps = wep.decode(wep.last_json)
                    end
                end
                local nm = names_by_sk[st.sk]
                if nm then
                    st.names = nm
                elseif not names_asked[st.sk] or now() - names_asked[st.sk] > 1 then
                    names_asked[st.sk] = now()
                    bridge_event("nmreq:" .. st.sk)
                end
                accept_packet(st, now())
            end
        elseif it.k == "N" then
            if torch and it.d:sub(1,3)=="\0L1" then
                local ok_t,error_t=pcall(torch.receive,it.d);if not ok_t then torch.error=tostring(error_t) end
            elseif enemy_hooks.recv then pcall(enemy_hooks.recv, it.d) end
        elseif it.k == "E" then
            if not it.e then net_events[#net_events + 1] = it.d end
        end
    end
    return true
end

---------------------------------------------------------------------------
-- apply partner pose to puppet (snapshot interpolation)
---------------------------------------------------------------------------
local function lerp(a, b, f) return a + (b - a) * f end

local function apply_partner()
    if not (partner and puppet and puppet.state == "ready" and clock_offset) then return end
    -- which moment of the partner's timeline to show
    local rt = now() - clock_offset - net.delay
    local a, b = snaps[1], snaps[#snaps]
    for i = #snaps, 1, -1 do
        if snaps[i].t <= rt then a = snaps[i]; b = snaps[i + 1] or snaps[i]; break end
    end
    local f = 0
    if b.t > a.t then f = math.max(0, math.min(1, (rt - a.t) / (b.t - a.t))) end
    -- drop snapshots we will never need again
    while #snaps > 2 and snaps[2].t < rt - 0.5 do table.remove(snaps, 1) end

    local px, py, pz = lerp(a.pos[1], b.pos[1], f), lerp(a.pos[2], b.pos[2], f), lerp(a.pos[3], b.pos[3], f)
    -- late packet: keep moving along the last known velocity for a moment instead of freezing
    net.extrapolating = false
    local newest, prev = snaps[#snaps], snaps[#snaps - 1]
    if a == newest and prev and rt > newest.t and newest.t > prev.t
        and (newest.pos[1]-prev.pos[1])^2 + (newest.pos[2]-prev.pos[2])^2 + (newest.pos[3]-prev.pos[3])^2 <= 25 then
        local ext = math.min(rt - newest.t, 0.15)
        local dt_s = newest.t - prev.t
        px = newest.pos[1] + (newest.pos[1] - prev.pos[1]) / dt_s * ext
        py = newest.pos[2] + (newest.pos[2] - prev.pos[2]) / dt_s * ext
        pz = newest.pos[3] + (newest.pos[3] - prev.pos[3]) / dt_s * ext
        net.extrapolating = true
    end
    local dx, dy, dz = b.pos[1] - a.pos[1], b.pos[2] - a.pos[2], b.pos[3] - a.pos[3]
    if dx * dx + dy * dy + dz * dz > 25 then px, py, pz = b.pos[1], b.pos[2], b.pos[3] end -- teleport: don't slide
    local rx, ry, rz, rw = nlerp(a.rot[1], a.rot[2], a.rot[3], a.rot[4], b.rot[1], b.rot[2], b.rot[3], b.rot[4], f)
    if b.echo then -- echo/mirror tests: stand 1.5m to the side instead of inside you
        local sx, _, sz = qrot(rx, ry, rz, rw, 1, 0, 0)
        px, pz = px - sx * 1.5, pz - sz * 1.5
    end
    puppet.cur = { pos = { px, py, pz } }
    puppet.tr:call("set_Position", Vector3f.new(px, py, pz))
    puppet.tr:call("set_Rotation", Quaternion.new(rw, rx, ry, rz))

    local pose = rt < b.t and a or b
    if pose.an then
        local played = anim.try_apply(puppet, pose.an, pose.seq, rt - pose.t)
        if #pose.q == 0 then
            anim.mode = played and "native" or "waiting for native motion"
            return
        end
    end
    anim.mode = "bones"
    anim.bones(puppet, pose.an ~= nil)
    if #a.q ~= #b.q then a, b, f = pose, pose, 0 end
    if not (partner_names and partner_sk == partner.sk and #a.q == #partner_names * 4 and #b.q == #a.q) then return end
    local qa, qb, map, set_lr = a.q, b.q, puppet.map, JM.set_lr
    -- Bone fallback runs every frame; skip work when nothing moved since last frame.
    -- (Only while the Motion component is off; otherwise it rewrites the bones each frame.)
    if not puppet.anim_enabled and puppet.bone_a == a and puppet.bone_b == b and puppet.bone_f == f
        and puppet.bone_map == map then return end
    puppet.bone_a, puppet.bone_b, puppet.bone_f, puppet.bone_map = a, b, f, map
    for i, name in ipairs(partner_names) do
        local j = map[name]
        if j then
            local k = (i - 1) * 4
            local x, y, z, w = nlerp(qa[k + 1], qa[k + 2], qa[k + 3], qa[k + 4], qb[k + 1], qb[k + 2], qb[k + 3], qb[k + 4], f)
            set_lr:call(j, Quaternion.new(w, x, y, z))
        end
    end
    if b.lp then
        for name, l in pairs(b.lp) do
            local j = map[name]
            local la = a.lp and a.lp[name] or l
            if j then JM.set_lp:call(j, Vector3f.new(lerp(la[1], l[1], f), lerp(la[2], l[2], f), lerp(la[3], l[3], f))) end
        end
    end
end

local function apply_partner_weapons()
    if not (puppet and puppet.state == "ready" and puppet.map) then return end
    puppet.weps = puppet.weps or {}
    local keep = {}
    for _, w in ipairs(partner_weps or {}) do
        keep[w.name] = true
        local e = puppet.weps[w.name]
        local recipe=e and e.w==w and e.recipe or json.dump_string(w)
        if e and e.recipe~=recipe then
            pcall(function() GO_DESTROY:call(nil, e.go) end)
            puppet.weps[w.name] = nil
            e = nil
        end
        if not e then
            local mh = res_holder("Mesh", w.mesh)
            if mh then
                local go = GO_CREATE:call(nil, "coop_partner_" .. w.name, puppet.folder)
                if go then
                    go = go:add_ref()
                    local mesh = go:call("createComponent(System.Type)", sdk.typeof("via.render.Mesh"))
                    mesh:call("setMesh", mh)
                    local th = w.mat ~= "" and res_holder("MeshMaterial", w.mat)
                    if th then mesh:call("set_Material", th) end
                    e = { go = go, tr = go:call("get_Transform"), mesh = w.mesh,recipe=recipe,w=w }
                    if w.scale then e.tr:call('set_LocalScale',Vector3f.new(table.unpack(w.scale))) end
                    if w.bits then
                        local mask=anim.unhex(w.bits)
                        for i=0,w.bit_count-1 do visual.mesh_api.setPartsEnable(mesh,i,mask:byte(i//8+1)&(1<<(i%8))~=0)end
                    end
                    if w.skin and w.motion then
                        local s=w.motion
                        local motion=go:call('createComponent(System.Type)',T_MOTION)
                        motion:call('set_MotionBankAsset',anim.resource(s.path,'MotionBank'))
                        motion:call('set_TargetBankType',s.target);motion:call('setupMotionBank');motion:call('setLayerCount',1)
                        local layer=motion:call('getLayer',0)
                        if not layer then layer=sdk.create_instance('via.motion.TreeLayer'):add_ref();motion:call('setLayer',0,layer)end
                        layer:call('changeLocalBankType',s.kind);layer:call('changeMotion(System.UInt32, System.UInt32, System.Single)',s.bank,s.id,0.0)
                        layer:call('set_WrapMode',s.wrap);layer:call('set_Speed',s.speed)
                    end
                    puppet.weps[w.name] = e
                end
            end
        end
        if e then
            e.w=w
            -- Skinned accessories (Grace's backpack) are driven on the real player by the
            -- engine: child transform + SameJointsConstraint. Do the same on the puppet
            -- instead of copying ~90 joints through Lua every frame.
            if w.skin and e.native == nil then
                e.native = pcall(function()
                    JM.tr_set_parent:call(e.tr, puppet.tr)
                    JM.tr_set_same:call(e.tr, true)
                    e.tr:call("set_LocalPosition", Vector3f.new(w.lp[1], w.lp[2], w.lp[3]))
                    e.tr:call("set_LocalRotation", Quaternion.new(w.lr[4], w.lr[1], w.lr[2], w.lr[3]))
                end) and e.tr:call("get_SameJointsConstraint") == true
            end
            local j = w.skin and puppet.tr or puppet.map[w.joint]
            if j and not (w.skin and e.native) then
                local jp, jr = JM.get_p:call(j), JM.get_r:call(j)
                local ox, oy, oz = qrot(jr.x, jr.y, jr.z, jr.w, w.lp[1], w.lp[2], w.lp[3])
                local rx, ry, rz, rw = qmul(jr.x, jr.y, jr.z, jr.w, w.lr[1], w.lr[2], w.lr[3], w.lr[4])
                e.tr:call("set_Position", Vector3f.new(jp.x + ox, jp.y + oy, jp.z + oz))
                e.tr:call("set_Rotation", Quaternion.new(rw, rx, ry, rz))
                if w.skin then
                    local joints=e.tr:call('get_Joints')
                    if not e.bind or (joints and joints:get_size() or 0)~=e.joint_count or e.root_map~=puppet.map then
                        e.bind={};e.joint_count=joints and joints:get_size() or 0;e.root_map=puppet.map
                        for i=0,e.joint_count-1 do
                            local target=joints:get_element(i);local source=puppet.map[target:call('get_Name')]
                            if source then e.bind[#e.bind+1]={source,target}end
                        end
                    end
                    -- Fallback only: keep the accessory's own skeleton and native pose;
                    -- shared body joints follow the character.
                    local get_p,get_r,set_p,set_r=JM.get_p,JM.get_r,JM.set_p,JM.set_r
                    for _,pair in ipairs(e.bind)do
                        set_p:call(pair[2],get_p:call(pair[1]))
                        set_r:call(pair[2],get_r:call(pair[1]))
                    end
                end
            end
            local draw = (j and puppet.visible) and true or false
            if e.draw ~= draw then e.go:call("set_DrawSelf", draw); e.draw = draw end
        end
    end
    for name, e in pairs(puppet.weps) do
        if not keep[name] then
            pcall(function() GO_DESTROY:call(nil, e.go) end)
            puppet.weps[name] = nil
        end
    end
end

---------------------------------------------------------------------------
-- main loop
---------------------------------------------------------------------------
local out_seq = 0
local last_send = 0
local last_link_read = 0
local last_frame = now()
local last_state = nil
local was_active=false

re.on_pre_application_entry("LateUpdateBehavior", function()
    if not alive() then if puppet then destroy_puppet() end return end
    local p0 = os.clock()
    pcall(net_poll)
    prof_add("net_poll", (os.clock() - p0) * 1000)
    local t = now()
    local dt = math.min(t - last_frame, 0.1)
    last_frame = t
    if not cfg.enabled then
        if puppet then destroy_puppet() end
        prof_late(p0)
        return
    end
    local active=cfg.mirror_test or link.mode=='echo' or (link.peer and link.peer~='' and
        (link.mode=='steam_host' or link.mode=='steam_join' or link.mode=='udp_host' or link.mode=='udp_join'))
    if not active then
        if puppet then destroy_puppet() end
        if was_active and enemy_hooks.tick then pcall(enemy_hooks.tick,dt,{0,0,0}) end
        was_active=false;status='waiting for partner data';prof_late(p0)
        return
    end
    was_active=true
    local ok, err = pcall(function()
        anim.tick()
        local cm, ctx, pgo = get_player()
        if not cm then
            if puppet then puppet = nil end -- level unloading; the object goes with its folder
            status = "waiting for player"
            return
        end
        if torch then
            local ptc = os.clock()
            local ok_t,error_t=pcall(torch.send,pgo)
            prof_add("torch_send", (os.clock() - ptc) * 1000)
            if not ok_t then torch.error=tostring(error_t) end
        end

        -- 1. send our state
        if t - last_send >= 1 / cfg.send_hz then
            last_send = t
            local pc = os.clock()
            local st = capture_local(ctx, pgo)
            prof_add("capture", (os.clock() - pc) * 1000)
            out_seq = out_seq + 1
            st.seq = out_seq
            st.t = t
            if not use_bridge() and out_seq % 40 == 1 then st.names = local_cache.names end
            last_state = st
            if cfg.mirror_test then
                if not visual.last_weapons or t - visual.last_weapons > 1 / WEP_HZ then
                    visual.last_weapons = t
                    local sig,entries=scan_local_weapons(pgo)
                    wep.last_sig=sig;wep.last_json=json.dump_string({version=1,items=entries})
                    partner_weps=wep.decode(wep.last_json)
                end
                -- feed ourselves back with a 0.1s delay (pretend network latency)
                local copy = {}
                for k, v in pairs(st) do copy[k] = v end
                copy.names = local_cache.names
                copy.echo = true
                mirror_queue[#mirror_queue + 1] = { t = t + 0.1, st = copy }
            else
                if enemy_hooks.packet_out then pcall(enemy_hooks.packet_out, st) end
                if use_bridge() then
                    pcall(coopnet.send_state, pack_state(st))
                    announce_names(false)
                else
                    json.dump_file(OUT_FILE, st)   -- old plugin: file exchange
                end
            end
        end

        -- Equipment scan (~0.7 ms at 2 Hz) runs on frames that did not capture/send a
        -- state, so the two costs never stack into one long frame.
        if last_send ~= t and not cfg.mirror_test and use_bridge() then pcall(announce_weapons, pgo, false) end

        -- 2. receive partner state
        if cfg.mirror_test then
            while mirror_queue[1] and mirror_queue[1].t <= t do
                accept_packet(table.remove(mirror_queue, 1).st, t)
            end
        elseif not use_bridge() then
            poll_partner_file()
        end

        -- 3. manage the puppet
        local fresh = partner and (t - partner_rx_time) < cfg.stale_after
        local my_area = area_of(pgo)
        if puppet then
            local gone = not puppet.go:call("get_Valid")
            local changed = fresh and (partner.kind ~= puppet.kind or partner.mm ~= puppet.mm or partner.mp ~= puppet.mp)
            if gone or puppet.player_addr ~= pgo:get_address() or changed then
                if not gone then destroy_puppet() else puppet = nil end
            end
        end
        local blocked = puppet_fail and partner and puppet_fail.kind == partner.kind and now() < puppet_fail["until"]
        if not puppet and fresh and not blocked then create_puppet(cm, pgo, partner) end
        if blocked and not puppet then
            status = "partner's character (" .. tostring(partner.kind) .. ") isn't loaded in this part of the game"
        end
        if puppet and puppet.state == "dressing" then finish_puppet(pgo) end
        if puppet and puppet.state == "ready" then
            local cinematic=session and session.hide_puppet()
            local show = fresh and partner.area == my_area and not cinematic
            set_puppet_visible(show and true or false)
            if show then
                local pv = os.clock()
                local ok_visual, error_visual = pcall(visual.apply, puppet)
                if not ok_visual then visual.error = tostring(error_visual) end
                local pa = os.clock()
                apply_partner()
                local pw = os.clock()
                local ok_w,error_w=pcall(apply_partner_weapons)
                if not ok_w then visual.error=tostring(error_w) end
                local pe = os.clock()
                prof_add("visual_apply", (pa - pv) * 1000); prof_add("pose_apply", (pw - pa) * 1000)
                prof_add("equipment_apply", (pe - pw) * 1000)
                status = "partner connected"
            elseif fresh then
                status = "partner is in another area (" .. tostring(partner.area) .. ")"
            else
                status = "partner data stale"
            end
            local ptn = os.clock()
            if torch then pcall(torch.apply,puppet,show and true or false) end
            prof_add("torch_apply", (os.clock() - ptn) * 1000)
        elseif not fresh then
            status = cfg.mirror_test and "mirror test starting" or "waiting for partner data"
        end

        -- 4. enemies
        if enemy_hooks.tick then
            local pe = os.clock()
            local pp = pgo:call("get_Transform"):call("get_Position")
            enemy_hooks.tick(dt, { pp.x, pp.y, pp.z })
            prof_add("enemies_apply", (os.clock() - pe) * 1000)
        end
    end)
    if not ok then status = "error: " .. tostring(err) end
    prof_late(p0)
end)

---------------------------------------------------------------------------
-- UI: commands to the network plugin + co-op window
---------------------------------------------------------------------------
local CMD_FILE = "coop_cmd.json"
local cmd_id = math.floor(os.time() % 100000) * 100
local ip_input = cfg.last_ip
local show_window = false
local window_forced = false  -- auto-shown on the title screen
local key_was_down = false

-- the plugin reads one command file per frame, so queue them and write one per frame
local cmd_queue = {}
local function send_cmd(cmd, arg)
    if cmd == "event" and use_bridge() then
        pcall(coopnet.send_event, arg or "")
        return
    end
    cmd_queue[#cmd_queue + 1] = { cmd = cmd, arg = arg or "" }
end
local function flush_cmd()
    local c = table.remove(cmd_queue, 1)
    if not c then return end
    cmd_id = cmd_id + 1
    json.dump_file(CMD_FILE, { id = cmd_id, cmd = c.cmd, arg = c.arg })
end

local function plugin_alive()
    return link.plugin and link.updated and (os.time() - link.updated) < 3
end

---------------------------------------------------------------------------
local lobby = { me_ready = false, partner_ready = false, partner_seen = -1000, evt_seen = nil, last_announce = 0,
    self_call = false, pending_menu = nil, pending_newgame = nil, pending_newgame_until = 0, msg = "" }

-- save sync: the joiner's game loads whatever the host loads
--   host:   picks a save on the title screen -> we send that slot's file to the partner.
--           (mid-game join: partner asks -> we save into spare slot 100 -> send that.)
--   joiner: plugin swaps the host's file into the SAME slot number (backing up ours), then we switch
--           to the host's Steam ID as the decryption key, press Continue for the player, and point
--           that load at the host's slot. Once the game starts, our key and our own file go back.
---------------------------------------------------------------------------
local COOP_CAT, COOP_OFS, COOP_ID = 6, 0, 100   -- spare slot (app.SaveSlotCategory.UserDefine_Game_0), file data100Slot.bin
local GAME_CATS = { [2] = true, [3] = true, [6] = true, [7] = true }  -- story save categories Continue looks at
local NULLABLE_SAVE = sdk.find_type_definition("System.Nullable`1<app.SavedataSaveRequestArgs>")
local sync = {
    req_seen = nil, rx_seen = nil,       -- last seen counters from the plugin
    pending_req = false,                 -- host: asked while we were on the title screen
    saving_since = nil,                  -- host: when we started writing the co-op slot
    host_sent = false,                   -- host: already shared the save we're loading
    armed = nil,                         -- joiner: { seed, cat, ofs, auto } once the host's save arrived
    prep_until = nil,                    -- joiner: waiting for the slot rescan before pressing Continue
    loading = false,                     -- joiner: our redirected load is running
    load_started = nil,
    msg = "",
}
local seed_override = nil

local function save_service() return sdk.get_managed_singleton("app.SaveServiceManager") end
local function is_host() return link.mode == "steam_host" or link.mode == "udp_host" end
local function is_joiner() return link.mode == "steam_join" or link.mode == "udp_join" end

local function set_seed(seed)
    seed_override = seed
    local sv = save_service()
    if sv then sv:call("requestReloadEncryptionSettings") end
end

local function rescan_slots()
    local sv = save_service()
    if not sv then return end
    sv:set_field("_IsDirtySaveSlotInfoDict", true)
    pcall(sv.call, sv, "refreshSaveSlotInfo")
    pcall(sv.call, sv, "reloadSaveSlotInfo")
end

local function slot_id_of(cat, ofs)
    local sv = save_service()
    local ds = sv and sv:call("enumerateSaveSlotDetails")
    if not ds then return nil end
    for i = 0, ds:get_size() - 1 do
        local d = ds:get_element(i)
        local a = d and d:get_field("_SlotAddress")
        if a and a:get_field("_Category") == cat and a:get_field("_SlotOffset") == ofs then return a:get_field("_SlotId") end
    end
end

local function title_flow()
    local sm = sdk.get_native_singleton("via.SceneManager")
    local scene = sm and sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    local arr = scene and scene:call("findComponents(System.Type)", sdk.typeof("app.TitleFlowController"))
    return arr and arr:get_size() > 0 and arr:get_element(0) or nil
end

local function joiner_abort(why)
    sync.loading, sync.prep_until, sync.armed = false, nil, nil
    set_seed(nil)
    send_cmd("restore_slot")
    rescan_slots()
    sync.msg = why
end

-- only one copy of each hook per game session, even if this script is hot-reloaded
if not _G.__requiem_coop_save_hooks then
    _G.__requiem_coop_save_hooks = true
    sdk.hook(sdk.find_type_definition("app.SaveEncryptionOperatorApp"):get_method("get_EncryptionSeed"),
        nil,
        function(ret)
            local h = _G.__requiem_coop_save
            local s = h and h.seed()
            if s then return sdk.to_ptr(s) end
            return ret
        end)
    sdk.hook(sdk.find_type_definition("app.SaveServiceManager"):get_method(
            "requestLoadCore(app.SaveSlotCategory, System.Int32, System.Nullable`1<app.SavedataLoadRequestArgs>)"),
        function(args)
            local h = _G.__requiem_coop_save
            if h then pcall(h.on_load, args) end
        end, nil)
    sdk.hook(sdk.find_type_definition("app.LevelFlowManager"):get_method("requestStartFlow"),
        function(args)
            local h = _G.__requiem_coop_save
            if h then pcall(h.on_start_flow) end
        end, nil)
end

_G.__requiem_coop_save = {
    seed = function() return alive() and seed_override or nil end,
    on_load = function(args)
        if not alive() then return end
        local cat = sdk.to_int64(args[3]) & 0xFFFFFFFF
        local ofs = sdk.to_int64(args[4]) & 0xFFFFFFFF
        if sync.loading and sync.armed then
            -- joiner: whatever Continue picked, load the host's slot instead. Only now switch to the
            -- host's key: Continue has already read our system save (it needs our own key for that),
            -- and the slot file itself is read later, in the background.
            if GAME_CATS[cat] then
                args[3] = sdk.to_ptr(sync.armed.cat)
                args[4] = sdk.to_ptr(sync.armed.ofs)
                sync.redirected = true
                if seed_override ~= sync.armed.seed then set_seed(sync.armed.seed) end
            end
            return
        end
        -- host: the player picked a save on the title screen; share it
        if is_host() and not sync.host_sent and GAME_CATS[cat] then
            local id = slot_id_of(cat, ofs)
            if id and id >= 0 then
                sync.host_sent = true
                send_cmd("send_slot", string.format("%d,%d,%d,1", cat, ofs, id))
                sync.msg = "Sending this save to your partner..."
            end
        end
    end,
    on_start_flow = function()
        if not alive() then return end
        sync.host_sent = false
        if sync.loading then
            sync.loading, sync.armed, sync.ingame, sync.jump_at, sync.redirect_grace = false, nil, false, nil, nil
            set_seed(nil)            -- back to our own key before anything gets saved
            send_cmd("restore_slot") -- and our own file back into that slot
            sync.msg = "Loaded the host's game."
        end
    end,
}

local function host_start_save()
    local sv = save_service()
    sync.pending_req = false
    local ok = sv and pcall(function()
        sv:call("requestSave(app.SaveSlotCategory, System.Int32, System.Nullable`1<app.SavedataSaveRequestArgs>)",
            COOP_CAT, COOP_OFS, ValueType.new(NULLABLE_SAVE))
    end)
    if ok then
        sync.saving_since = now()
        sync.msg = "Saving your game for your partner..."
    else
        sync.msg = "Couldn't save for your partner."
    end
end

local function save_sync_tick()
    if not plugin_alive() then return end
    local in_game = get_player() ~= nil

    -- host: partner asked for our current game (they joined while we're playing)
    local req = link.save_req_seq or 0
    if sync.req_seen == nil then sync.req_seen = req end
    if req > sync.req_seen then
        sync.req_seen = req
        if in_game then host_start_save()
        else sync.pending_req = true; sync.msg = "Your partner is waiting - load a save and it'll load for them too." end
    end
    if sync.pending_req and in_game then host_start_save() end
    if sync.saving_since and now() - sync.saving_since > 1.5 then
        local sv = save_service()
        if sv and not sv:call("get_IsBusy") then
            sync.saving_since = nil
            send_cmd("send_slot", string.format("%d,%d,%d,1", COOP_CAT, COOP_OFS, COOP_ID))
            sync.msg = "Sent your game to your partner."
        end
    end

    -- joiner: the host's save arrived
    local rx = link.save_rx_seq or 0
    if sync.rx_seen == nil then sync.rx_seen = rx end
    if rx > sync.rx_seen then
        sync.rx_seen = rx
        local seed = math.tointeger(tonumber(link.save_seed or ""))
        if seed and link.mode ~= "echo" then
            sync.armed = { seed = seed, cat = link.save_cat, ofs = link.save_ofs }
            sync.msg = "Host's save received - loading it..."
        elseif link.mode == "echo" then
            send_cmd("restore_slot")
            sync.msg = "Echo test: save transfer worked (not loading it - it's your own game)."
        end
    end

    -- joiner on the game-over screen: the host continued -> run our Continue, pointed at their save
    if sync.armed and not sync.loading and _G.__requiem_coop_go and _G.__requiem_coop_go.phase() ~= 0 then
        if _G.__requiem_coop_go.continue_with_host_save() then
            sync.loading, sync.redirected, sync.ingame = true, false, true
            sync.load_started = now()
            sync.redirect_grace = 15   -- the game-over screen fades before it loads
            sync.msg = "Loading the host's game..."
        end
    -- joiner, already playing: load the host's save in place, then restart the level from it
    elseif sync.armed and in_game and not sync.loading then
        local sv = save_service()
        sync.loading, sync.redirected, sync.ingame = true, false, true
        sync.load_started = now()
        local nul = ValueType.new(sdk.find_type_definition("System.Nullable`1<app.SavedataLoadRequestArgs>"))
        pcall(function()
            sv:call("requestLoad(app.SaveSlotCategory, System.Int32, System.Nullable`1<app.SavedataLoadRequestArgs>)",
                sync.armed.cat, sync.armed.ofs, nul)
        end)
        sync.jump_at = now() + 1.0
        sync.msg = "The host loaded a save - reloading..."
    end
    if sync.jump_at and now() >= sync.jump_at then
        sync.jump_at = nil
        local lfm = sdk.get_managed_singleton("app.LevelFlowManager")
        if lfm then pcall(lfm.call, lfm, "requestGameJump") end
    end

    -- joiner: on the title screen with the host's save ready -> press Continue for the player
    if sync.armed and not in_game and not sync.loading then
        if not sync.prep_until then
            sync.prep_until = now() + 1.0
            sync.msg = "Joining the host's game..."
        elseif now() >= sync.prep_until then
            local tf = title_flow()
            if tf and tf:get_field("_CurrPhase") == 7 then  -- title menu is up and accepting input
                sync.prep_until = nil
                sync.loading = true
                sync.redirected = false
                sync.load_started = now()
                lobby.self_call = true
                tf:call("onContinue")
                sync.msg = "Loading the host's game..."
            end
        end
    end
    -- the player is in the world: the host's save has been read, so put our key and our file back.
    -- (requestStartFlow doesn't fire on every load path, so don't rely on it alone.)
    -- (in-game reloads wait for requestStartFlow instead: the player exists the whole time)
    if sync.loading and sync.redirected and in_game and not sync.ingame then
        _G.__requiem_coop_save.on_start_flow()
    end
    if sync.loading and sync.ingame and now() - sync.load_started > 60 then
        _G.__requiem_coop_save.on_start_flow()
    end
    if sync.loading and not sync.redirected and now() - sync.load_started > (sync.redirect_grace or 3) then
        joiner_abort("Couldn't start loading - you need at least one save of your own for joining to work.")
    elseif sync.loading and not sync.ingame and not in_game and now() - sync.load_started > 120 then
        joiner_abort("Loading the host's game timed out - try again.")
    end
end

---------------------------------------------------------------------------
-- ready-up: in a session, New Game / Continue / Load Game on the title screen only go through
-- once both players are ready. The partner's game then follows by itself:
--   New Game  -> partner starts a new game on the same difficulty
--   Continue / Load Game -> partner loads the same save (see save sync above)
---------------------------------------------------------------------------
local DIFF_TD = sdk.find_type_definition("app.GameDifficultyID")

local function in_session() return is_host() or is_joiner() end
local function partner_present() return cfg.enabled and in_session() and link.peer ~= nil and link.peer ~= "" end

local function announce_ready()
    send_cmd("event", "ready:" .. (lobby.me_ready and "1" or "0"))
    lobby.last_announce = now()
end

local function find_difficulty(name)
    local vals = DIFF_TD:get_method("get_Values"):call(nil)
    for i = 0, vals:call("get_Count") - 1 do
        local v = vals:call("get_Item", i)
        if v:call("ToString") == name then return v end
    end
end

local function start_newgame(diff_name)
    local tf = title_flow()
    if get_player() ~= nil or not tf then
        lobby.msg = "The host started a new game - go to the title screen, then ask them to start again."
        return true
    end
    if tf:get_field("_CurrPhase") ~= 7 then return false end  -- menu busy; try again next frame
    local diff = find_difficulty(diff_name)
    local dm = sdk.get_managed_singleton("app.GameDifficultyManager")
    if not (diff and dm) then lobby.msg = "Unknown difficulty " .. tostring(diff_name); return true end
    dm:call("setNewGameDifficulty", diff)
    lobby.self_call = true
    tf:call("onNewGame")
    lobby.msg = "Starting a new game with the host..."
    return true
end

local function handle_event(e)
    local k, v = e:match("^(%w+):(.*)$")
    if session and (k=="session3" or k=="cin3" or k=="cinreq3" or k=="cinvote3" or k=="cinack3"
        or k=="flow3" or k=="rpc3" or k=="rpcreq3" or k=="rpcrepair3") then
        if #v<=65536 then
            local ok_s,error_s=pcall(session.handle,k,json.load_string(v))
            if not ok_s then session.error=tostring(error_s) end
        end
        return
    elseif k=="torchOff3" and torch and session then
        local d=json.load_string(v)
        if type(d)=="table" and d.epoch==session.peer_epoch then torch.off(d.seq) end
        return
    end
    if k == "anver" or k == "anres" or k == "anready" or k == "anfail" or k == "ancompact"
        or k == "aldef" or k == "alack" or k == "alreq" or k == "anbones" or k == "anhead"
        or k == "shdef" or k == "shack" or k == "shreq" or k == "enbatch" or k == "anstate" then
        anim.event(k, v)
    elseif k == "modver" then
        anim.peer_mod_version = type(v) == "string" and #v <= 32 and v or "?"
    elseif k == "model" then
        visual.receive(v)
    elseif k == "ready" then
        lobby.partner_ready = (v == "1")
        lobby.partner_seen = now()
    elseif k == "go" then
        if _G.__requiem_coop_go then _G.__requiem_coop_go.event(v) end
    elseif k == "mc" then
        local h = _G.__requiem_coop_mirror
        if h then h.event(v) end
    elseif k=='equipver' then
        if v=='1' and not wep.peer_v1 then wep.peer_v1=true;wep.last_json=nil end
    elseif k=='equip1' then
        local ok_e,data=pcall(wep.decode,v)
        if ok_e then partner_weps=data;wep.remote_v1=true else visual.error=tostring(data) end
    elseif k == "wp" then
        if not wep.remote_v1 then partner_weps = parse_weapons(v) end
    elseif k == "wpreq" then
        local _, _, pgo = get_player()
        if pgo then pcall(announce_weapons, pgo, true) end
    elseif k == "nm" then
        local sk, list = v:match("^(%d+):(.*)$")
        if sk then names_by_sk[tonumber(sk)] = split_csv(list) end
    elseif k == "nmreq" then
        announce_names(true)
    elseif k == "eo" or k == "eoall" or k == "enm" or k == "enmreq" then
        if enemy_hooks.event then enemy_hooks.event(k, v) end
    elseif k == "dbgreq" then
        local report
        if cfg.allow_debug_requests then
            local ok, d = pcall(_G.__requiem_coop_debug)
            report = ok and d or { error = tostring(d) }
            report.enemy_list = enemy_hooks.details and select(2, pcall(enemy_hooks.details)) or nil
            report.time = os.time()
        else
            report = { denied = true }
        end
        local ok, js = pcall(json.dump_string, report)
        send_cmd("event", "dbg:" .. (ok and js or '{"error":"could not encode report"}'))
    elseif k == "dbg" then
        local ok, d = pcall(json.load_string, v)
        json.dump_file("coop_partner_debug.json", ok and d or { raw = v })
        lobby.msg = (ok and d and d.denied) and "Your partner hasn't allowed debug requests (Options)."
            or "Partner debug info saved to reframework/data/coop_partner_debug.json"
    elseif k == "ed" then
        if enemy_hooks.damage then enemy_hooks.damage(v) end
    elseif k == "it" or k == "gm" or k == "pause" or k == "dr" then
        local h = _G.__requiem_coop_world
        if h then h.event(k, v) end
    elseif k == "cs" or k == "csend" or k == "skip" then
        local h = _G.__requiem_coop_cs
        if h then h.event(k, v) end
    elseif k == "newgame" and is_joiner() then
        lobby.pending_newgame = v
        lobby.pending_newgame_until = now() + 15
    end
end

if not _G.__requiem_coop_gate_hooks then
    _G.__requiem_coop_gate_hooks = true
    local td = sdk.find_type_definition("app.TitleFlowController")
    for _, name in ipairs({ "onNewGame", "onContinue", "onLoadGame" }) do
        sdk.hook(td:get_method(name), function(args)
            local h = _G.__requiem_coop_lobby
            if h then
                local ok, block = pcall(h.gate, name, sdk.to_managed_object(args[2]))
                if ok and block then return sdk.PreHookResult.SKIP_ORIGINAL end
            end
        end, nil)
    end
end

_G.__requiem_coop_lobby = {
    -- returns true to cancel the title menu action
    gate = function(name, tf)
        if not alive() then return false end
        if lobby.self_call then lobby.self_call = false; return false end  -- the mod itself pressed it
        if not in_session() then return false end
        local why
        if is_joiner() then
            why = "The host starts the game - it'll start here automatically."
        elseif partner_present() and not (lobby.me_ready and lobby.partner_ready) then
            why = (not lobby.me_ready) and "Tick Ready first (F6)." or "Waiting for your partner to ready up."
        end
        if why then
            lobby.pending_menu = tf   -- bring the title menu back next frame
            lobby.msg = why
            if not (lobby.menu and lobby.menu.behavior) then show_window = true end
            return true
        end
        -- host going ahead with a partner: a new game has to be mirrored explicitly
        if name == "onNewGame" and partner_present() then
            local dm = sdk.get_managed_singleton("app.GameDifficultyManager")
            local id = dm and dm:get_field("_DifficultyID")
            if id then send_cmd("event", "newgame:" .. id:call("ToString")) end
            lobby.msg = "Starting - your partner's game is starting too."
        end
        return false
    end,
}

local function lobby_tick()
    if lobby.pending_menu then
        local tf = lobby.pending_menu
        lobby.pending_menu = nil
        pcall(tf.call, tf, "transitPhase", 6)  -- SetupTitleMenu
    end
    if not in_session() then
        lobby.me_ready, lobby.partner_ready, lobby.evt_seen = false, false, nil
        net_events = {}
        return
    end
    while #net_events > 0 do
        pcall(handle_event, table.remove(net_events, 1))
    end
    local evs = link.events or {}   -- old plugin (file exchange)
    if lobby.evt_seen == nil then
        lobby.evt_seen = 0
        for _, e in ipairs(evs) do lobby.evt_seen = math.max(lobby.evt_seen, e.s or 0) end
    end
    for _, e in ipairs(evs) do
        if (e.s or 0) > lobby.evt_seen then
            lobby.evt_seen = e.s
            pcall(handle_event, e.e or "")
        end
    end
    if lobby.pending_newgame then
        if start_newgame(lobby.pending_newgame) or now() > lobby.pending_newgame_until then lobby.pending_newgame = nil end
    end
    if not partner_present() or now() - lobby.partner_seen > 10 then lobby.partner_ready = false end
    if partner_present() and now() - lobby.last_announce > 3 then announce_ready() end
    -- once the game is running, everyone is un-readied for next time
    if get_player() ~= nil and lobby.me_ready then
        lobby.me_ready = false
        announce_ready()
    end
end

local function draw_ready_ui()
    if not in_session() then return end
    imgui.separator()
    if get_player() == nil then
        local c, v = imgui.checkbox("Ready", lobby.me_ready)
        if c then lobby.me_ready = v; announce_ready() end
        imgui.same_line()
    end
    if partner_present() then
        imgui.text_colored(lobby.partner_ready and "Partner: READY" or "Partner: not ready",
            lobby.partner_ready and 0xFF60FF60 or 0xFF8080FF)
    else
        imgui.text("Partner: not connected yet")
    end
    if is_host() and partner_present() then
        if imgui.button("Get partner's debug info") then
            send_cmd("event", "dbgreq:1")
            lobby.msg = "Asking your partner's game for debug info..."
        end
    end
    if is_host() then
        imgui.text("When you're both ready, choose New Game, Continue or Load Game.")
        imgui.text("Your partner's game follows automatically.")
    else
        imgui.text("Tick Ready, then wait - the host starts the game for both of you.")
    end
    if lobby.msg ~= "" then imgui.text_colored(lobby.msg, 0xFF80E0FF) end
end

---------------------------------------------------------------------------
-- shared world: items picked up and locks opened by one player are applied in the other's game.
-- Inventories stay separate - only the world is shared. Changes to objects the other player
-- hasn't loaded yet are remembered and applied when that object streams in.
---------------------------------------------------------------------------
local doors = { list = nil, last_list = 0, sent = {}, remote = {}, last_tick = 0 }  -- shared door angles (see doors_tick)
local world = {
    items_taken = {},      -- guid -> true: picked up by someone, hide it everywhere
    item_seen = {},        -- guid -> last IsSpawn we saw
    gm = {},               -- guid -> { ["Type.Field"] = value } changes from the partner
    gm_last = {},          -- guid -> { ["Type.Field"] = value } last values we saw
    cores = nil, core_i = 0, last_core_list = 0,
    last_item_scan = 0,
}
-- which gimmick state fields are shared (whitelist: writing others can break live gimmicks)
local GM_FIELDS = {
    ["app.structure.GmLockData"] = { "_UnlockCount" },
    ["app.structure.GmBaseData"] = { "_IsLock" },
}

local function guid_of(cid)
    local ok, s = pcall(function() return cid:get_field("_RawID"):call("ToString") end)
    return ok and s or nil
end

local function current_scene()
    local sm = sdk.get_native_singleton("via.SceneManager")
    return sm and sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
end

local function hide_item(ic)
    local ctx = ic:get_field("_Context")
    if ctx and ctx:call("get_IsSpawn") then
        ctx:call("set_IsSpawn", false)
        pcall(ic.call, ic, "updateSpawnStatus")
    end
end

local function items_tick()
    if now() - world.last_item_scan < 0.5 then return end
    world.last_item_scan = now()
    local scene = current_scene()
    local arr = scene and scene:call("findComponents(System.Type)", sdk.typeof("app.ItemCore"))
    if not arr then return end
    for i = 0, arr:get_size() - 1 do
        local ic = arr:get_element(i)
        if ic and not ic:get_field("_IsDynamicInstance") then          -- box drops etc. are per-player
            local ctx = ic:get_field("_Context")
            local id = guid_of(ic:get_field("_ContextID"))
            if ctx and id then
                local spawn = ctx:call("get_IsSpawn")
                if world.items_taken[id] then
                    if spawn then hide_item(ic) end
                elseif world.item_seen[id] == true and spawn == false then
                    world.items_taken[id] = true                       -- we picked it up
                    send_cmd("event", "it:" .. id)
                end
                world.item_seen[id] = spawn
            end
        end
    end
end

local function sd_of(core, tn)
    local ctx = core:get_field("_Context")
    local sdc = ctx and ctx:get_field("_SDC")
    local list = sdc and sdc:get_field("_Structures")
    if not list then return nil end
    for j = 0, list:call("get_Count") - 1 do
        local sd = list:call("get_Item", j)
        if sd and sd:get_type_definition():get_full_name() == tn then return sd end
    end
end

-- Per-gimmick handles (GUID string, structure objects, field keys) resolved once.
-- Re-resolving them for 12 gimmicks every frame measured 0.44 ms/frame in-game;
-- reading cached handles is ~0.02 ms. The cache lives exactly as long as the core
-- list it came from (rebuilt every 2 s), so no handle outlives the original design.
function world.gimmick_entry(core)
    local addr = core:get_address()
    local e = world.core_cache[addr]
    if e then return e end
    e = { id = guid_of(core:get_field("_ContextID")), fields = {} }
    if e.id then
        for tn, fields in pairs(GM_FIELDS) do
            local sd = sd_of(core, tn)
            if sd then
                local short = tn:gsub("^app%.structure%.", "")
                for _, f in ipairs(fields) do e.fields[#e.fields + 1] = { sd = sd, f = f, key = short .. "." .. f } end
            end
        end
    end
    world.core_cache[addr] = e
    return e
end

local function gimmicks_tick()
    -- refresh the list of loaded gimmicks every 2 s, check ~12 of them per frame
    if not world.cores or now() - world.last_core_list > 2 then
        local scene = current_scene()
        local arr = scene and scene:call("findComponents(System.Type)", sdk.typeof("app.GimmickCore"))
        world.cores = {}
        if arr then for i = 0, arr:get_size() - 1 do world.cores[#world.cores + 1] = arr:get_element(i) end end
        world.core_cache = {}
        world.last_core_list = now()
        world.core_i = 0
    end
    local n = #world.cores
    for _ = 1, math.min(12, n) do
        world.core_i = world.core_i % n + 1
        local core = world.cores[world.core_i]
        local ok = pcall(function()
            local e = world.gimmick_entry(core)
            local id = e.id
            if not id then return end
            local last = world.gm_last[id]
            local remote = world.gm[id]
            local fresh = last == nil
            last = last or {}
            for _, x in ipairs(e.fields) do
                local sd, f, key = x.sd, x.f, x.key
                local v = sd:get_field(f)
                if remote and remote[key] ~= nil and remote[key] ~= v then
                    sd:set_field(f, remote[key])               -- partner changed it
                    pcall(sd.call, sd, "onDirty")
                    v = remote[key]
                elseif not fresh and last[key] ~= nil and last[key] ~= v then
                    send_cmd("event", string.format("gm:%s:%s=%s", id, key, tostring(v)))  -- we changed it
                end
                last[key] = v
            end
            world.gm_last[id] = last
        end)
        if not ok then world.cores = nil; world.core_cache = nil; return end   -- object went away; rebuild next frame
    end
end

---------------------------------------------------------------------------
-- pause: opening the pause menu pauses the partner's game too
---------------------------------------------------------------------------
local pause = { remote = false, pm_type = nil, msg = "" }

local function pause_type()
    if pause.pm_type then return pause.pm_type end
    local vals = sdk.find_type_definition("app.PauseType"):get_method("get_Values"):call(nil)
    for i = 0, vals:call("get_Count") - 1 do
        local v = vals:call("get_Item", i)
        if v:call("ToString") == "StopUpdate" then pause.pm_type = v:add_ref(); return pause.pm_type end
    end
end

local function pause_call(name)
    local pm = sdk.get_managed_singleton("app.PauseManager")
    local t = pause_type()
    if not (pm and t) then return end
    for _, m in ipairs(sdk.find_type_definition("app.PauseManager"):get_methods()) do
        if m:get_name() == name and #m:get_param_types() == 4 then
            local pts = m:get_param_types()
            pcall(function() m:call(pm, t, "RequiemCoop", ValueType.new(pts[3]), ValueType.new(pts[4])) end)
            return
        end
    end
end

local function set_remote_pause(on)
    if pause.remote == on then return end
    pause.remote = on
    pause_call(on and "requestPause" or "requestResume")
    pause.msg = on and ((link.peer ~= "" and link.peer or "Your partner") .. " has paused the game") or ""
end

if not _G.__requiem_coop_pause_hooks then
    _G.__requiem_coop_pause_hooks = true
    local td = sdk.find_type_definition("app.PauseManager")
    for _, name in ipairs({ "requestPause", "requestResume" }) do
        for _, m in ipairs(td:get_methods()) do
            if m:get_name() == name then
                sdk.hook(m, function(args)
                    local h = _G.__requiem_coop_world
                    if h then
                        local ok, label = pcall(function() return sdk.to_managed_object(args[4]):call("ToString") end)
                        if ok then pcall(h.on_pause, name == "requestPause", label) end
                    end
                end, nil)
            end
        end
    end
end

-- move our player to where the partner was (cutscenes)
local function warp_player(x, y, z, qx, qy, qz, qw)
    local cm = sdk.get_managed_singleton("app.CharacterManager")
    local ctx = cm and cm:call("get_PlayerContextFast")
    if not ctx then return false end
    local kind = ctx:call("get_KindID"):call("ToString")
    local cid
    local h = cm:call("get_PlayerContextIDHolder")
    for i = 0, h:call("get_Count") - 1 do
        local r = h:call("get_Item", i)
        local target=r:get_field("_BindTarget")
        if type(target)~="string" and target then target=target:call("ToString") end
        if target == kind then cid = r:call("get_ContextID") end
    end
    if not cid then return false end
    local sig = "requestWarp(app.ContextID, System.Nullable`1<via.vec3>, System.Nullable`1<via.Quaternion>)"
    local pts = sdk.find_type_definition("app.CharacterManager"):get_method(sig):get_param_types()
    local np, nr = ValueType.new(pts[2]), ValueType.new(pts[3])
    np:set_field("_HasValue", true); np:set_field("_Value", Vector3f.new(x, y, z))
    if qw then nr:set_field("_HasValue", true); nr:set_field("_Value", Quaternion.new(qw, qx, qy, qz)) end
    return pcall(function() cm:call(sig, cid, np, nr) end)
end

_G.__requiem_coop_world = {
    on_pause = function(paused, label)
        if not alive() or label ~= "GuiPauseMenuController" then return end   -- only the pause menu
        if partner_present() then send_cmd("event", "pause:" .. (paused and "1" or "0")) end
    end,
    event = function(k, v)
        if k == "it" then
            world.items_taken[v] = true
            world.last_item_scan = 0
        elseif k == "gm" then
            local id, key, val = v:match("^([^:]+):([^=]+)=(.*)$")
            if not id then return end
            if val == "true" then val = true elseif val == "false" then val = false else val = tonumber(val) end
            world.gm[id] = world.gm[id] or {}
            world.gm[id][key] = val
        elseif k == "pause" then
            set_remote_pause(v == "1")
        elseif k == "dr" then
            local id, a = v:match("^([^=]+)=([%-%d%.]+)$")
            if id then doors.remote[id] = { a = tonumber(a), applied = false } end
        end
    end,
}

-- doors: they're physics objects you push, so we share each door's angle while it moves
local DOOR_LOCK_MODE = 3   -- app.GmDoorV3.ActionType.Lock: never force a locked door

local function doors_tick()
    if now() - doors.last_tick < 0.1 then return end
    doors.last_tick = now()
    if not doors.list or now() - doors.last_list > 2 then
        doors.list = {}
        doors.last_list = now()
        local scene = current_scene()
        local arr = scene and scene:call("findComponents(System.Type)", sdk.typeof("app.GmDoorV3"))
        if arr then
            for i = 0, arr:get_size() - 1 do
                local d = arr:get_element(i)
                local core = d and d:call("get_GameObject"):call("getComponent(System.Type)", sdk.typeof("app.GimmickCore"))
                local id = core and guid_of(core:get_field("_ContextID"))
                if id then doors.list[#doors.list + 1] = { door = d:add_ref(), id = id } end
            end
        end
    end
    for _, e in ipairs(doors.list) do
        local ok = pcall(function()
            local d, id = e.door, e.id
            if d:get_field("_CurrActionType") == DOOR_LOCK_MODE then return end
            local angle = d:get_field("_CurrAngle")
            local r = doors.remote[id]
            local sent = doors.sent[id]
            if r and not r.applied then
                -- the partner moved this door
                d:set_field("_TargetAngle", r.a)
                d:set_field("_CurrAngle", r.a)
                r.applied = true
                doors.sent[id] = r.a
            elseif sent == nil then
                doors.sent[id] = angle                      -- first look at this door
            elseif math.abs(angle - sent) > 2 then
                doors.sent[id] = angle                      -- we moved it
                send_cmd("event", string.format("dr:%s=%.1f", id, angle))
            end
        end)
        if not ok then doors.list = nil; return end
    end
end

local function world_tick()
    if not partner_present() then
        if pause.remote then set_remote_pause(false) end   -- never leave someone frozen
        return
    end
    if get_player() == nil then return end
    pcall(items_tick)
    pcall(gimmicks_tick)
    pcall(doors_tick)
end

local function draw_world_overlay()
    if pause.msg == "" then return end
    pcall(draw.text, pause.msg, 40, 70, 0xFFFFFFFF)
end

---------------------------------------------------------------------------
-- call mirror: story progress, flags, objectives, lights, documents...
--   When one game makes one of these calls, the other game makes the same call with the same
--   arguments. Only while both players are in the same chapter (so nobody's story gets
--   pushed into a state it can't be in), and never echoed back.
---------------------------------------------------------------------------
local MIRROR = {
    { "app.LevelFlowManager", "requestChangeProgressiveNumber(System.UInt32, System.Int32)", { "u32", "i32" } },
    { "app.LevelFlowManager", "setProgressiveNumber(System.UInt32, System.Int32)", { "u32", "i32" } },
    { "app.LevelFlowManager", "requestResetProgressiveNumber(System.UInt32)", { "u32" } },
    { "app.LevelFlowGroupManager", "requestLock(app.LevelFlowGroup, System.UInt32)", { "u32", "u32" } },
    { "app.LevelFlowGroupManager", "requestUnlock(app.LevelFlowGroup, System.UInt32)", { "u32", "u32" } },
    { "app.LevelFlowGroupManager", "setEnable(app.LevelFlowGroup, System.Boolean)", { "u32", "bool" } },
    { "app.GimmickManager", "enableGlobalBitFlags(app.GimmickUtil.GlobalBitFlag)", { "u32" } },
    { "app.GimmickManager", "enableGlobalBitFlags2(app.GimmickUtil.GlobalBitFlag2)", { "u32" } },
    { "app.EventSaveManager", "entryEndTimelineEvent(app.TimelineEventDefine.ID, System.Int32)", { "i32", "i32" } },
    { "app.ObjectiveManager", "requestSetObjective(app.ObjectiveID, System.Boolean)", { "name:app.ObjectiveID", "bool" } },
    { "app.ObjectiveManager", "requestAchieveObjective(app.ObjectiveID, System.Boolean)", { "name:app.ObjectiveID", "bool" } },
    { "app.ObjectiveManager", "requestAbandonObjective(app.ObjectiveID, System.Boolean)", { "name:app.ObjectiveID", "bool" } },
    { "app.ObjectiveManager", "requestCountObjective(app.ObjectiveID, System.Boolean, System.Boolean)", { "name:app.ObjectiveID", "bool", "bool" }, true },
    { "app.LevelDestinationManager", "requestDestination(app.NameHash, System.Boolean)", { "namehash", "bool" } },
    { "app.LevelDestinationManager", "requestAchieve(app.NameHash)", { "namehash" } },
    { "app.LightManager", "requestEnableGroup(app.LightGroupID)", { "name:app.LightGroupID" } },
    { "app.LightManager", "requestDisableGroup(app.LightGroupID)", { "name:app.LightGroupID" } },
    { "app.FileManager", "notifyAcquired(app.FileID, System.Boolean, app.FileAcquireOptionBit)", { "name:app.FileID", "bool", "u32" } },
    -- Append only: existing event indices remain stable across previews.
    { "app.LevelFlowManager", "requestStopProgressive(System.UInt32)", { "u32" } },
    { "app.LevelFlowManager", "resetFlow(System.UInt32)", { "u32" } },
    { "app.LevelFlowGroupManager", "requestLock(app.LevelFlowGroup, System.UInt32, System.Single)", { "u32", "u32", "f32" } },
    { "app.LightManager", "requestLightTimelineEffectPlay(app.LightTimelineEffectID)", { "name:app.LightTimelineEffectID" } },
    { "app.LightManager", "changeDayLight(app.DayLightSets)", { "i32" } },
    { "app.MainGameFlowManager", "setEndingBranchIndex(System.UInt32)", { "u32" } },
    { "app.MainGameFlowManager", "setBattleReady(System.Boolean)", { "bool" } },
    { "app.QuestManager", "addEnabledQuestGroup(app.QuestGroup)", { "name:app.QuestGroup" }, true },
    { "app.QuestManager", "notifyOccurred(app.OccurrenceEventArgs)", { "occurrence" }, true },
}
local mirror = { applying = false, sent = 0, applied = 0, skipped = 0, installed = 0, missing = {}, value_cache = {} }

local function chapter_of(area) return area and area:match("^(Chap%d+)") or area end

local function mirror_allowed()
    if not partner_present() or not partner or not last_state then return false end
    return chapter_of(partner.area) == chapter_of(last_state.area)
end

local function encode_arg(kind, a)
    local v = sdk.to_int64(a)
    if kind == "u32" then return tostring(v & 0xFFFFFFFF) end
    if kind == "i32" then v = v & 0xFFFFFFFF; if v >= 0x80000000 then v = v - 0x100000000 end; return tostring(v) end
    if kind == "bool" then return ((v & 0xFF) ~= 0) and "1" or "0" end
    if kind=='f32' then
        local f=string.unpack('<f',string.pack('<I4',v&0xFFFFFFFF))
        if not anim.finite(f,1e5) or f<0 then return end
        return string.format('%.9g',f)
    end
    local o = sdk.to_managed_object(a)
    if not o then return nil end
    if kind=='occurrence' then local id=o:get_field('ID');return id and id:call('ToString') end
    if kind == "namehash" then return tostring(o:get_field("_Hash")) end
    return o:call("ToString")     -- name:<type>
end

local function named_value(tn, name)
    local cache = mirror.value_cache[tn]
    if not cache then
        cache = {}
        local vals = sdk.find_type_definition(tn):get_method("get_Values"):call(nil)
        for i = 0, vals:call("get_Count") - 1 do
            local v = vals:call("get_Item", i)
            cache[v:call("ToString")] = v:add_ref()
        end
        mirror.value_cache[tn] = cache
    end
    return cache[name]
end

local function decode_arg(kind, s)
    if kind == "u32" or kind == "i32" then
        local v=math.tointeger(tonumber(s));if not v then return end
        if kind=='u32' then return v>=0 and v<=0xFFFFFFFF and v or nil end
        return v>=-0x80000000 and v<=0x7FFFFFFF and v or nil
    end
    if kind == "bool" then if s=='1' then return true elseif s=='0' then return false end;return end
    if kind=='f32' then local v=tonumber(s);return anim.finite(v,1e5) and v>=0 and v or nil end
    if kind=='occurrence' then
        local id=named_value('app.OccurrenceID',s);if not id then return end
        local args=sdk.create_instance('app.OccurrenceEventArgs'):add_ref()
        args:call('.ctor(app.OccurrenceID)',id);return args
    end
    if kind == "namehash" then
        local hash=math.tointeger(tonumber(s));if not hash or hash<0 or hash>0xFFFFFFFF then return end
        local nh = sdk.create_instance("app.NameHash") or sdk.create_instance("app.NameHash", true)
        nh = nh:add_ref()
        nh:set_field("_Hash", hash)
        return nh
    end
    local tn = kind:match("^name:(.+)$")
    return tn and named_value(tn, s) or nil
end

if false and not _G.__requiem_coop_mirror_hooks then -- legacy hot-reload hooks dispatch to a no-op below
    _G.__requiem_coop_mirror_hooks = true
    for i, m in ipairs(MIRROR) do
        local method = sdk.find_type_definition(m[1]) and sdk.find_type_definition(m[1]):get_method(m[2])
        if method then
            sdk.hook(method, function(args)
                local h = _G.__requiem_coop_mirror
                if h then pcall(h.on_call, i, args) end
            end, nil)
        end
    end
end

_G.__requiem_coop_mirror = {
    on_call = function() end,
    intercept = function(i, args)
        if not alive() or mirror.applying then return end
        if not mirror_allowed() then mirror.skipped = mirror.skipped + 1; return end
        -- Counts and occurrence notifications are consequences of the host's
        -- story simulation. Replaying the same local consequence on the client
        -- must not request another increment on the host.
        if session and session.cap and is_joiner() and MIRROR[i][4] then return true end
        if i==2 and is_joiner() and session and session.cap then
            local id=sdk.to_int64(args[3])&0xFFFFFFFF
            local value=sdk.to_int64(args[4])&0xFFFFFFFF;if value>=0x80000000 then value=value-0x100000000 end
            local expected=mirror.authorized and mirror.authorized[id]
            if expected and ((expected.allowed and expected.allowed[value] and now()<expected.allowed[value])
                or (expected.reset and now()<expected.until_time)) then return false end
        end
        local m = MIRROR[i]
        local parts = {}
        for k, kind in ipairs(m[3]) do
            local v = encode_arg(kind, args[k + 2])
            if v == nil then return end
            parts[k] = v
        end
        if session and session.cap then
            if (i==1 or i==2) and is_joiner() then
                mirror.pending_requests=mirror.pending_requests or {}
                local key=i..":"..table.concat(parts,"|")
                if mirror.pending_requests[key] and now()-mirror.pending_requests[key]<0.25 then return true end
                mirror.pending_requests[key]=now()
            end
            mirror.sent=mirror.sent+1
            return session.mirror_call(i,parts)==true
        end
        mirror.sent = mirror.sent + 1
        bridge_event("mc:" .. i .. ":" .. table.concat(parts, "|"))
    end,
    event = function(v)
        if session and session.cap then return end
        local i, rest = v:match("^(%d+):(.*)$")
        local m = i and MIRROR[tonumber(i)]
        if not m or not mirror_allowed() then mirror.skipped = mirror.skipped + 1; return end
        local obj = sdk.get_managed_singleton(m[1])
        if not obj then return end
        local vals, k = {}, 0
        for piece in (rest .. "|"):gmatch("([^|]*)|") do
            k = k + 1
            local dv = decode_arg(m[3][k], piece)
            if dv == nil then return end
            vals[k] = dv
        end
        mirror.applying = true
        local ok = pcall(function() obj:call(m[2], table.unpack(vals, 1, k)) end)
        mirror.applying = false
        if ok then mirror.applied = mirror.applied + 1 end
    end,
}

do
    local installed=_G.__requiem_coop_mirror_hooks_v2 or {};_G.__requiem_coop_mirror_hooks_v2=installed
    for i,m in ipairs(MIRROR) do
        local td=sdk.find_type_definition(m[1]);local method=td and td:get_method(m[2])
        local key=m[1].."::"..m[2]
        if method then
            mirror.installed=mirror.installed+1
            if not installed[key] then
                sdk.hook(method,function(args)
                    local h=_G.__requiem_coop_mirror
                    if h then
                        local ok,block=pcall(h.intercept,i,args)
                        if not ok then mirror.error=tostring(block) end
                        if ok and block then return sdk.PreHookResult.SKIP_ORIGINAL end
                    end
                end,nil)
                installed[key]=true
            end
        else mirror.missing[#mirror.missing+1]=key end
    end
end

---------------------------------------------------------------------------
-- game over: either player dying / failing ends the run for both, and the host's choice is
-- what both games do. The partner's own Continue / Retry / Load Game are held until the
-- host's save arrives, then Continue runs redirected to that save (same path as joining).
---------------------------------------------------------------------------
local GO_PHASE = { Wait = 0, Init = 2, WaitSelect = 3, ContinueStart = 4, RetryStart = 7, LoadGameStart = 10 }
local gameover = { active = false, self_call = false, remote = false, holding = false, msg = "", applied = 0, sent = 0 }

local function gameover_mgr() return sdk.get_managed_singleton("app.GameOverManager") end
local function gameover_phase()
    local gm = gameover_mgr()
    return gm and gm:get_field("_CurrPhase") or 0
end

if not _G.__requiem_coop_go_hooks then
    _G.__requiem_coop_go_hooks = true
    local td = sdk.find_type_definition("app.GameOverManager")
    sdk.hook(td:get_method("transitPhase(app.GameOverManager.Phase)"), function(args)
        local h = _G.__requiem_coop_go
        if h then
            local ok, block = pcall(h.on_phase, sdk.to_managed_object(args[2]), sdk.to_int64(args[3]) & 0xFF)
            if ok and block then return sdk.PreHookResult.SKIP_ORIGINAL end
        end
    end, nil)
end

_G.__requiem_coop_go = {
    -- returns true to hold the phase change
    on_phase = function(gm, phase)
        if not alive() then return false end
        if phase == GO_PHASE.Wait then
            gameover.active, gameover.holding, gameover.msg = false, false, ""
            return false
        end
        if not partner_present() then return false end
        if phase == GO_PHASE.Init then
            gameover.active = true
            if not gameover.remote then
                gameover.sent = gameover.sent + 1
                bridge_event("go:" .. tostring(gm:get_field("_GameOverType") or 0))
                gameover.msg = is_host() and "Game over for both of you - choose Continue to bring you both back."
                    or "Game over for both of you - waiting for the host to continue."
            end
            gameover.remote = false
            return false
        end
        if phase == GO_PHASE.ContinueStart or phase == GO_PHASE.RetryStart or phase == GO_PHASE.LoadGameStart then
            if gameover.self_call then gameover.self_call = false; return false end
            if is_joiner() then
                gameover.holding = true
                gameover.msg = "Waiting for the host to continue..."
                return true
            end
        end
        return false
    end,
    event = function(v)
        local gm = gameover_mgr()
        if not gm or gameover.active or gameover_phase() ~= GO_PHASE.Wait then return end
        gameover.remote = true
        local ok = pcall(function() gm:call("requestGameOver(app.GameOverManager.GameOverType)", tonumber(v) or 0) end)
        if ok then gameover.applied = gameover.applied + 1 else gameover.remote = false end
        gameover.msg = ((link.peer ~= "" and link.peer) or "Your partner") .. " died - "
            .. (is_host() and "choose Continue to bring you both back." or "waiting for the host to continue.")
    end,
    -- joiner: the host's save arrived while we're on the game-over screen -> Continue with it
    continue_with_host_save = function()
        local gm = gameover_mgr()
        if not gm or gameover_phase() ~= GO_PHASE.WaitSelect then return false end
        gameover.self_call, gameover.holding = true, false
        local ok = pcall(gm.call, gm, "transitPhase(app.GameOverManager.Phase)", GO_PHASE.ContinueStart)
        if ok then gameover.msg = "Loading the host's game..." else gameover.self_call = false end
        return ok
    end,
    phase = gameover_phase,
}

local function draw_gameover_overlay()
    if gameover.msg == "" or gameover_phase() == GO_PHASE.Wait then return end
    pcall(draw.text, gameover.msg, 40, 100, 0xFFFFFFFF)
end

---------------------------------------------------------------------------
-- cutscene sync
--   * when either player's game starts a cutscene, the partner's game plays the same one
--     (only possible when both are in the same area - the cutscene has to be loaded)
--   * while both are watching the same cutscene, skipping needs BOTH players to hold skip:
--     the first skip is held back until the partner skips too, then both skip together
--   * a cutscene we already watched together is skipped automatically if our own game
--     reaches its trigger later
---------------------------------------------------------------------------
local MED_PLAY = "play(app.TimelineEventDefine.ID, System.Int32, System.String, System.Boolean, System.Nullable`1<app.TimelineEventMediatorRequestArgs>, System.Nullable`1<app.TimelineEventMediatorRequestArgs>)"
local NUL_MED = sdk.find_type_definition("System.Nullable`1<app.TimelineEventMediatorRequestArgs>")
local cs = {
    current = nil, seen_playing = false, started = 0,   -- the cutscene our game is showing
    remote = nil, remote_area = nil,                    -- the cutscene the partner is showing
    synced = {},                                        -- ids we watched because the partner triggered them
    autoskip = nil,
    partner_skip = {},                                  -- id -> partner has held skip
    held_entry = nil, held_id = nil,                    -- our own skip request, held until the partner skips
    self_play = false, self_skip = false,
    queue = nil,                                        -- { id, until } partner cutscene to start when we can
    msg = "",
}

local function mediator() return sdk.get_managed_singleton("app.TimelineEventMediator") end

local function my_area()
    local _, _, pgo = get_player()
    return pgo and area_of(pgo) or nil
end

local function play_remote_cutscene(id)
    local med = mediator()
    if not med then return false end
    if med:call("get_IsPlayingCutScene") then return false end  -- wait for the current one to end
    cs.self_play = true
    local ok = pcall(function()
        med:call(MED_PLAY, id, 0, "RequiemCoop", false, ValueType.new(NUL_MED), ValueType.new(NUL_MED))
    end)
    if not ok then cs.self_play = false end
    cs.synced[id] = true
    return true
end

local function release_held_skip()
    if not cs.held_entry then return end
    local entry = cs.held_entry
    cs.held_entry, cs.held_id = nil, nil
    cs.self_skip = true
    local aem = sdk.get_managed_singleton("app.AppEventManager")
    pcall(function() aem:call("request", entry) end)
    cs.msg = ""
end

if false and not _G.__requiem_coop_cs_hooks then -- superseded by reflected session hooks
    _G.__requiem_coop_cs_hooks = true
    sdk.hook(sdk.find_type_definition("app.TimelineEventMediator"):get_method(
            "playImpl(app.TimelineEventDefine.ID, System.Int32, System.String, System.Nullable`1<app.TimelineEventMediatorRequestArgs>, System.Nullable`1<app.TimelineEventMediatorRequestArgs>, System.Boolean)"),
        function(args)
            local h = _G.__requiem_coop_cs
            if h then pcall(h.on_play, sdk.to_int64(args[3]) & 0xFFFFFFFF) end
        end, nil)
    sdk.hook(sdk.find_type_definition("app.AppEventManager"):get_method("request(app.AppEventDefine.RequestEntry)"),
        function(args)
            local h = _G.__requiem_coop_cs
            if h then
                local ok, block = pcall(h.on_request, sdk.to_managed_object(args[3]))
                if ok and block then return sdk.PreHookResult.SKIP_ORIGINAL end
            end
        end, nil)
end

_G.__requiem_coop_cs = {
    -- a cutscene is starting in our game
    on_play = function(id)
        if not alive() then return end
        cs.current, cs.seen_playing, cs.started = id, false, now()
        cs.partner_skip[id] = nil
        if cs.self_play then cs.self_play = false; return end     -- we started it for the partner
        if cs.synced[id] then cs.autoskip = id; return end        -- already watched it together
        if partner_present() then
            local _, _, pgo = get_player()
            local where = ""
            if pgo then
                local tr = pgo:call("get_Transform")
                local p, r = tr:call("get_Position"), tr:call("get_Rotation")
                where = string.format(":%.3f,%.3f,%.3f:%.4f,%.4f,%.4f,%.4f", p.x, p.y, p.z, r.x, r.y, r.z, r.w)
            end
            send_cmd("event", "cs:" .. id .. ":" .. tostring(my_area()) .. where)
        end
    end,
    -- every AppEventManager request; returns true to hold it back
    on_request = function(entry)
        if not alive() or not entry then return false end
        if entry:get_field("<Type>k__BackingField") ~= 6 then return false end   -- 6 = skip
        local ident = entry:get_field("<Identifier>k__BackingField")
        if not ident or ident:get_field("_Kind") ~= 1 then return false end      -- 1 = timeline cutscene
        local id = ident:get_field("_ID")
        if cs.self_skip then cs.self_skip = false; return false end
        if not partner_present() or cs.remote ~= id then return false end          -- partner isn't watching it
        send_cmd("event", "skip:" .. id)
        if cs.partner_skip[id] then return false end                                -- partner already held skip
        cs.held_entry = entry:add_ref()
        cs.held_id = id
        cs.msg = "Waiting for your partner to skip (1/2)"
        return true
    end,
    event = function(k, v)
        if k == "cs" then
            local id, area, pos, rot = v:match("^(%d+):([^:]*):?([^:]*):?([^:]*)$")
            id = tonumber(id)
            if not id then return end
            local where = nil
            local x, y, z = (pos or ""):match("^([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)$")
            if x then
                local qx, qy, qz, qw = (rot or ""):match("^([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)$")
                where = { tonumber(x), tonumber(y), tonumber(z), tonumber(qx), tonumber(qy), tonumber(qz), tonumber(qw) }
            end
            cs.remote, cs.remote_area = id, area
            if cs.current == id then return end                       -- we're already watching it
            if get_player() and area == my_area() then
                cs.queue = { id = id, ["until"] = now() + 20, where = where }
            else
                cs.msg = "Your partner is watching a cutscene in " .. tostring(area)
            end
        elseif k == "csend" then
            local id = tonumber(v)
            if cs.remote == id then cs.remote = nil end
            if cs.msg:find("^Your partner is watching") then cs.msg = "" end
        elseif k == "skip" then
            local id = tonumber(v)
            if not id then return end
            cs.partner_skip[id] = true
            if cs.held_id == id then release_held_skip()
            elseif cs.current == id then cs.msg = "Your partner wants to skip - hold skip to skip together (1/2)" end
        end
    end,
}

local function cutscene_tick()
    local med = mediator()
    if not med then return end
    local playing = med:call("get_IsPlayingCutScene")
    if cs.current then
        if playing then cs.seen_playing = true end
        if (cs.seen_playing and not playing) or (not cs.seen_playing and now() - cs.started > 15) then
            if partner_present() then send_cmd("event", "csend:" .. cs.current) end
            cs.partner_skip[cs.current] = nil
            cs.current, cs.held_entry, cs.held_id = nil, nil, nil
            if cs.msg:find("skip") then cs.msg = "" end
        end
    end
    if cs.autoskip and playing and med:call("get_IsSkippable") then
        cs.autoskip = nil
        cs.self_skip = true
        pcall(med.call, med, "skip(System.Object)", med)
    end
    if cs.queue then
        if now() > cs.queue["until"] then cs.queue = nil
        else
            -- first bring our player to where the partner triggered it, then play it
            if cs.queue.where and not cs.queue.warped then
                cs.queue.warped = true
                warp_player(table.unpack(cs.queue.where))
            elseif play_remote_cutscene(cs.queue.id) then cs.queue = nil end
        end
    end
    -- partner left the session mid-cutscene: don't keep our skip hostage
    if cs.held_entry and not partner_present() then release_held_skip() end
end

local function draw_cutscene_overlay()
    if cs.msg == "" then return end
    local med = mediator()
    if not (med and med:call("get_IsPlayingCutScene")) and not cs.msg:find("^Your partner is watching") then return end
    pcall(draw.text, cs.msg, 40, 40, 0xFFFFFFFF)
end

---------------------------------------------------------------------------
-- enemy sync
--   Each enemy is run by ONE game at a time (its "owner"): the game of the player it's closest to.
--   The host decides ownership and sends it with its state. The owner's AI chases/attacks its own
--   player for real; the other game switches its copy's brain + animation off and drives it from
--   the owner's pose, so both players see the same enemy doing the same thing.
--   Damage dealt to an enemy you don't own is sent to the owner, who applies it.
---------------------------------------------------------------------------
local EN_RANGE = 35          -- only sync enemies within this distance of the other player
local EN_HZ = 10             -- enemy updates per second
local OWN_MARGIN = 5.0       -- ownership switches when the other player is this much closer...
local OWN_HOLD = 2.0         -- ...for this long (handing over restarts the enemy's AI, so keep it rare)
-- parts of an enemy that make it act on its own; switched off while the other game owns it
local EN_DISABLE = { "ThinkDriver$", "ActionDriver$", "AttackDamageDriver$", "TargetSensor$", "NavigationSupporter$",
    "FindStateController$", "OutOfAreaDriver$", "^via%.motion%.MotionFsm2$", "^via%.motion%.Motion$",
    "^via%.physics%.CharacterController$" }

local en = {
    list = {}, last_list = 0,           -- id -> { ctx, go, tr, kind, joints, names }
    owner = {}, pending = {},           -- host: id -> "h"/"j", id -> { to, since }
    puppets = {},                       -- id -> { disabled = {comp...}, cur = {...}, hp_set = n }
    remote = {}, remote_names = {},     -- id -> latest state from the owner; kind -> joint names
    last_send = 0, names_sent = 0,
    eo_remote = {},                     -- joiner: ownership as announced by the host
    eo_sent = {}, eo_all_t = 0,         -- host: what we last announced
    names_sent_sk = {}, names_asked = {},
    damage_sent = 0, msg = "",
}

local function en_id(ctx)
    local ok, s = pcall(function() return ctx:get_field("<ID>k__BackingField"):get_field("_RawID"):call("ToString") end)
    return ok and s or nil
end

local function my_role() return is_host() and "h" or "j" end

local function dist3(a, b) local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]; return math.sqrt(dx * dx + dy * dy + dz * dz) end

local function refresh_enemy_list()
    if now() - en.last_list < 0.5 then return end
    en.last_list = now()
    local cm = sdk.get_managed_singleton("app.CharacterManager")
    local seen = {}
    -- enemies and NPCs share CharacterContext (same ID / HitPoint), so both go through here
    for _, getter in ipairs({ "getSpawnedEnemyContextRefList", "getSpawnedNPCContextRefList" }) do
    local list = cm and cm:call(getter)
    if list then
        for i = 0, list:call("get_Count") - 1 do
            local ctx = list:call("get_Item", i)
            local id = ctx and en_id(ctx)
            local go = ctx and ctx:call("get_GameObject")
            if id and go and go:call("get_Valid") then
                seen[id] = true
                local e = en.list[id]
                if not e or e.addr ~= go:get_address() then
                    local tr = go:call("get_Transform")
                    local joints, names = {}, {}
                    local js = tr:call("get_Joints")
                    for j = 0, js:get_size() - 1 do
                        local jt = js:get_element(j)
                        joints[#joints + 1] = jt
                        names[#names + 1] = jt:call("get_Name")
                    end
                    e = { ctx = ctx:add_ref(), go = go, addr = go:get_address(), tr = tr, kind = ctx:call("get_KindID"):call("ToString"), joints = joints, names = names }
                    e.by_name = {}
                    for k, n in ipairs(names) do e.by_name[n] = joints[k] end
                    en.list[id] = e
                end
            end
        end
    end
    end
    for id in pairs(en.list) do
        if not seen[id] then en.list[id] = nil; en.puppets[id] = nil end
    end
end

local function hitpoint(e) return e.ctx:get_field("<HitPoint>k__BackingField") end

-- who runs this enemy right now ("h" = host's game, "j" = joiner's game)
local function owner_of(id)
    if is_host() then return en.owner[id] or "h" end
    return en.eo_remote[id] or "j"
end

local function set_puppet(id, e, on)
    local p = en.puppets[id]
    if on and not p then
        p = { disabled = {}, go = e.go, tr = e.tr }
        local arr = e.go:call("get_Components")
        for i = 0, arr:get_size() - 1 do
            local c = arr:get_element(i)
            local tn = c:get_type_definition():get_full_name()
            for _, pat in ipairs(EN_DISABLE) do
                if tn:find(pat) then
                    local ok, enabled = pcall(c.call, c, "get_Enabled")
                    if ok and enabled then
                        pcall(c.call, c, "set_Enabled", false)
                        p.disabled[#p.disabled + 1] = c:add_ref()
                    end
                    break
                end
            end
        end
        local hp = hitpoint(e)
        p.hp_set = hp and hp:call("get_CurrentHitPoint") or nil
        en.puppets[id] = p
    elseif not on and p then
        for _, c in ipairs(p.disabled) do pcall(c.call, c, "set_Enabled", true) end
        if p.anim_id then
            e.joints, e.names, e.by_name = {}, {}, {}
            local js = e.tr:call("get_Joints")
            for i = 0, js:get_size() - 1 do
                local j = js:get_element(i)
                local name = j:call("get_Name")
                e.joints[#e.joints + 1], e.names[#e.names + 1], e.by_name[name] = j, name, j
            end
            e.sk = nil
        end
        en.puppets[id] = nil
    end
end

-- host: decide who runs each enemy
local function update_ownership(my_pos)
    if not is_host() then return end
    local ppos = partner and partner.pos
    for id, e in pairs(en.list) do
        local p = e.tr:call("get_Position")
        local ep = { p.x, p.y, p.z }
        local dh = dist3(ep, my_pos)
        local dj = ppos and dist3(ep, ppos) or 1e9
        local cur = en.owner[id] or "h"
        local want = cur
        if cur == "h" and dj + OWN_MARGIN < dh then want = "j" end
        if cur == "j" and dh + OWN_MARGIN < dj then want = "h" end
        if want ~= cur then
            local pend = en.pending[id]
            if not pend or pend.to ~= want then en.pending[id] = { to = want, since = now() }
            elseif now() - pend.since >= OWN_HOLD then en.owner[id] = want; en.pending[id] = nil end
        else
            en.pending[id] = nil
        end
    end
end

-- send: ownership changes (host, reliable events) + one compact packet per enemy we run (15 Hz)
local ENEMY_HEAD = "<s1s1I4fffhhhhi4BB"
local function enemy_state_for_packet(st)
    if session and session.hide_puppet() then return end
    if not partner_present() or not use_bridge() then return end
    if is_host() then
        local all = {}
        for id in pairs(en.list) do
            local o = owner_of(id)
            all[#all + 1] = id .. "=" .. o
            if en.eo_sent[id] ~= o then
                en.eo_sent[id] = o
                bridge_event("eo:" .. id .. "=" .. o)
            end
        end
        if now() - en.eo_all_t > 3 and #all > 0 then
            en.eo_all_t = now()
            bridge_event("eoall:" .. table.concat(all, ";"))
        end
    end
    if now() - en.last_send < 1 / EN_HZ then return end
    en.last_send = now()
    local ppos = partner and partner.pos
    local packets = {}
    for id, e in pairs(en.list) do
        if owner_of(id) == my_role() then
            local p = e.tr:call("get_Position")
            if not ppos or dist3({ p.x, p.y, p.z }, ppos) < EN_RANGE then
                e.sk = e.sk or fnv32(table.concat(e.names, ","))
                if not en.names_sent_sk[e.sk] then
                    en.names_sent_sk[e.sk] = true
                    bridge_event("enm:" .. e.sk .. ":" .. table.concat(e.names, ","))
                end
                local r = e.tr:call("get_Rotation")
                local ok_anim, animation = pcall(anim.capture, e.go)
                if not ok_anim then animation = nil end
                local extension = animation and anim.peer_version == 1 and anim.pack(animation)
                local native = extension and anim.can_send(animation)
                local qi = {}
                for _, j in ipairs(native and {} or e.joints) do
                    local lr = j:call("get_LocalRotation")
                    qi[#qi + 1] = q16(lr.x); qi[#qi + 1] = q16(lr.y); qi[#qi + 1] = q16(lr.z); qi[#qi + 1] = q16(lr.w)
                end
                local hp = hitpoint(e)
                local hpv = hp and hp:call("get_CurrentHitPoint") or -1
                local dead = (hp and hp:call("get_IsDead")) and 1 or 0
                local jr, jh = not native and e.by_name["root"], not native and e.by_name["Hip"]
                local bone_data, sparse = anim.pack_bones(qi)
                local flags = (jr and 1 or 0) | (jh and 2 or 0) | (extension and 4 or 0) | (anim.peer_version == 1 and 8 or 0) | (sparse and 16 or 0)
                local parts = { string.pack(ENEMY_HEAD, id, e.kind, e.sk, p.x, p.y, p.z, q16(r.x), q16(r.y), q16(r.z), q16(r.w), hpv, dead, flags) }
                for _, j in ipairs({ jr or false, jh or false }) do
                    if j then local l = j:call("get_LocalPosition"); parts[#parts + 1] = string.pack("<fff", l.x, l.y, l.z) end
                end
                parts[#parts + 1] = string.pack("<H", #qi // 4)
                parts[#parts + 1] = bone_data
                if flags & 8 ~= 0 then parts[#parts + 1] = string.pack("<d", now()) end
                if extension then parts[#parts + 1] = extension end
                packets[#packets + 1] = table.concat(parts)
            end
        end
    end
    local batches = anim.batch(packets, anim.batch_peer)
    en.tx_states, en.tx_packets, en.tx_bytes = #packets, #batches, 0
    for _, packet in ipairs(batches) do
        en.tx_bytes = en.tx_bytes + #packet
        pcall(coopnet.send_enemy, packet)
    end
end

-- receive: one enemy packet from its owner
local function enemy_recv(b)
    assert(type(b)=='string' and #b<=16384,'invalid enemy packet size')
    if b:byte(1) == 0 then
        for _, packet in ipairs(anim.unbatch(b)) do pcall(enemy_recv, packet) end
        return
    end
    local id, kind, sk, px, py, pz, ra, rb, rc, rd, hpv, dead, flags, at = string.unpack(ENEMY_HEAD, b)
    local s = { id = id, k = kind, sk = sk, p = { px, py, pz }, r = { uq16(ra), uq16(rb), uq16(rc), uq16(rd) },
        hp = hpv >= 0 and hpv or nil, dead = dead == 1, lp = {}, t = now() }
    assert(#id>0 and #kind>0 and #kind<=80 and flags & ~31==0 and dead<=1
        and anim.valid_transform(s.p,s.r),'invalid enemy header')
    local x, y, z
    if flags & 1 ~= 0 then x, y, z, at = string.unpack("<fff", b, at); assert(anim.finite(x) and anim.finite(y) and anim.finite(z),'invalid enemy root');s.lp.root = { x, y, z } end
    if flags & 2 ~= 0 then x, y, z, at = string.unpack("<fff", b, at); assert(anim.finite(x) and anim.finite(y) and anim.finite(z),'invalid enemy hip');s.lp.Hip = { x, y, z } end
    local n
    n, at = string.unpack("<H", b, at)
    s.q, at = anim.unpack_bones(b, at, n, flags & 16 ~= 0)
    if flags & 8 ~= 0 then
        s.sent_t, at = string.unpack("<d", b, at)
        if s.sent_t ~= s.sent_t or math.abs(s.sent_t) > 1e10 then return end
    end
    if flags & 4 ~= 0 then s.an = anim.unpack(b, at) else assert(at==#b+1,'trailing enemy data') end
    if n == 0 and not s.an then return end
    local previous = en.remote[id]
    if previous and s.sent_t and previous.sent_t then
        -- The peer's clock restarts with its game. A stale prior session must
        -- not make every packet from the restarted process look out of order.
        if s.sent_t <= previous.sent_t then
            if now() - previous.t < 2 then return end
            previous = nil
        end
    end
    if previous and s.sent_t and previous.sent_t then
        local gap = s.sent_t - previous.sent_t
        s.teleport = dist3(s.p, previous.p) > 5
        if not s.teleport and gap <= 0.5 then
            s.velocity = {}
            for i = 1, 3 do s.velocity[i] = (s.p[i] - previous.p[i]) / gap end
        end
    end
    en.remote[id] = s
    if not en.remote_names[sk] and (not en.names_asked[sk] or now() - en.names_asked[sk] > 1) then
        en.names_asked[sk] = now()
        bridge_event("enmreq:" .. sk)
    end
end

local function enemy_event(k, v)
    if k == "eo" then
        local id, o = v:match("^([^=]+)=(%a)$")
        if id then en.eo_remote[id] = o end
    elseif k == "eoall" then
        for id, o in v:gmatch("([^=;]+)=(%a)") do en.eo_remote[id] = o end
    elseif k == "enm" then
        local sk, list = v:match("^(%d+):(.*)$")
        if sk then en.remote_names[tonumber(sk)] = split_csv(list) end
    elseif k == "enmreq" then
        local want = tonumber(v)
        for _, e in pairs(en.list) do
            e.sk = e.sk or fnv32(table.concat(e.names, ","))
            if e.sk == want then bridge_event("enm:" .. e.sk .. ":" .. table.concat(e.names, ",")); break end
        end
    end
end

-- (old JSON path: no longer used)
local function enemy_state_from_packet(st) end

-- non-owner: make our copy look exactly like the owner's
local function apply_remote_enemies(dt)
    local a = 1 - math.exp(-14 * dt)
    for id, e in pairs(en.list) do
        local remote_owned = partner_present() and owner_of(id) ~= my_role()
        local s = en.remote[id]
        if remote_owned and s and now() - s.t < 2 then
            set_puppet(id, e, true)
            local p = en.puppets[id]
            -- position / facing (smoothed; snap if far)
            local cur = p.cur
            if not cur or (s.teleport and p.last_state ~= s) or dist3(cur.pos, s.p) > 5 then cur = { pos = { s.p[1], s.p[2], s.p[3] }, rot = { s.r[1], s.r[2], s.r[3], s.r[4] }, q = {} }; p.cur = cur end
            p.last_state = s
            local age = math.max(0, math.min(now() - s.t, 0.15))
            for i = 1, 3 do
                local predicted = s.p[i] + (s.velocity and s.velocity[i] or 0) * age
                cur.pos[i] = cur.pos[i] + (predicted - cur.pos[i]) * a
            end
            cur.rot[1], cur.rot[2], cur.rot[3], cur.rot[4] = nlerp(cur.rot[1], cur.rot[2], cur.rot[3], cur.rot[4], s.r[1], s.r[2], s.r[3], s.r[4], a)
            e.tr:call("set_Position", Vector3f.new(cur.pos[1], cur.pos[2], cur.pos[3]))
            e.tr:call("set_Rotation", Quaternion.new(cur.rot[4], cur.rot[1], cur.rot[2], cur.rot[3]))
            -- pose
            if s.an then
                anim.try_apply(p, s.an, s.sent_t or s.t, age)
            end
            if #s.q > 0 then
                anim.bones(p, s.an ~= nil)
                e.by_name = p.map
            end
            local names = en.remote_names[s.sk]
            if #s.q > 0 and names and #names * 4 == #s.q then
                for i, n in ipairs(names) do
                    local j = e.by_name[n]
                    if j then
                        local k = (i - 1) * 4
                        local c = cur.q[n]
                        local tx, ty, tz, tw = s.q[k + 1], s.q[k + 2], s.q[k + 3], s.q[k + 4]
                        if c then tx, ty, tz, tw = nlerp(c[1], c[2], c[3], c[4], tx, ty, tz, tw, a) end
                        cur.q[n] = { tx, ty, tz, tw }
                        j:call("set_LocalRotation", Quaternion.new(tw, tx, ty, tz))
                    end
                end
                if s.lp then
                    for n, l in pairs(s.lp) do
                        local j = e.by_name[n]
                        if j then j:call("set_LocalPosition", Vector3f.new(l[1], l[2], l[3])) end
                    end
                end
            end
            -- health: follow the owner; anything we knocked off since is our damage -> send it over
            local hp = hitpoint(e)
            if hp and s.hp then
                local local_hp = hp:call("get_CurrentHitPoint")
                if p.hp_set and local_hp < p.hp_set then
                    local dmg = p.hp_set - local_hp
                    send_cmd("event", "ed:" .. id .. ":" .. dmg)
                    en.damage_sent = en.damage_sent + dmg
                    p.hp_set = local_hp
                elseif local_hp ~= s.hp and (not p.hp_set or s.hp < p.hp_set or local_hp > s.hp) then
                    pcall(hp.call, hp, "set_CurrentHitPoint", s.hp)
                    -- remember what actually stuck: our copy may clamp it (different max HP),
                    -- and that must not be mistaken for damage we dealt
                    p.hp_set = hp:call("get_CurrentHitPoint")
                end
            end
        else
            -- we run it (or the owner stopped sending): give it its brain back
            if en.puppets[id] then set_puppet(id, e, false) end
        end
    end
end

-- owner: the partner hit one of our enemies
local function apply_enemy_damage(v)
    local id, dmg = v:match("^([^:]+):(%d+)$")
    dmg = tonumber(dmg)
    local e = id and en.list[id]
    if not (e and dmg and dmg > 0) then return end
    local hp = hitpoint(e)
    if hp and not hp:call("get_IsDead") then
        local ok = pcall(hp.call, hp, "addDamageHitPoint", dmg, false, false)
        if not ok then pcall(hp.call, hp, "set_CurrentHitPoint", math.max(0, hp:call("get_CurrentHitPoint") - dmg)) end
    end
end

local function enemies_tick(dt, my_pos)
    if en.peer ~= anim.peer then en.peer = anim.peer; en.remote = {} end
    pcall(refresh_enemy_list)
    if session and session.hide_puppet() then
        for id,e in pairs(en.list) do if en.puppets[id] then set_puppet(id,e,false) end end
        return
    end
    pcall(update_ownership, my_pos)
    local ok, err = pcall(apply_remote_enemies, dt)
    if not ok then en.msg = "enemy sync error: " .. tostring(err) end
    if not partner_present() then
        for id, e in pairs(en.list) do if en.puppets[id] then set_puppet(id, e, false) end end
    end
end

enemy_hooks.packet_out = enemy_state_for_packet
enemy_hooks.packet_in = enemy_state_from_packet
enemy_hooks.recv = enemy_recv
enemy_hooks.event = enemy_event
enemy_hooks.tick = enemies_tick
enemy_hooks.damage = apply_enemy_damage
enemy_hooks.details = function()
    local out = {}
    local _, _, pgo = get_player()
    local pp = pgo and pgo:call("get_Transform"):call("get_Position")
    for id, e in pairs(en.list) do
        local p = e.tr:call("get_Position")
        local hp = hitpoint(e)
        out[#out + 1] = { id = id, kind = e.kind, owner = owner_of(id), puppet = en.puppets[id] ~= nil,
            remote_state = en.remote[id] ~= nil, joints = #e.joints,
            hp = hp and hp:call("get_CurrentHitPoint"), dead = hp and hp:call("get_IsDead"),
            pos = { r3(p.x), r3(p.y), r3(p.z) },
            dist = pp and math.floor(dist3({ p.x, p.y, p.z }, { pp.x, pp.y, pp.z }) * 10) / 10 }
    end
    return out
end
enemy_hooks.stats = function()
    local n, pup, rem = 0, 0, 0
    for _ in pairs(en.list) do n = n + 1 end
    for _ in pairs(en.puppets) do pup = pup + 1 end
    for _ in pairs(en.remote) do rem = rem + 1 end
    return { enemies = n, puppets = pup, remote_states = rem, damage_sent = en.damage_sent, msg = en.msg,
        states_per_tick = en.tx_states, messages_per_tick = en.tx_packets, payload_bytes_per_tick = en.tx_bytes }
end

local function draw_panel()
    local c, v
    if not plugin_alive() then
        imgui.text_colored("Network plugin not running.", 0xFF4040FF)
        imgui.text("Install requiem_coop_net.dll into reframework/plugins and restart the game.")
    else
        local st = link.state or "?"
        local col = link.connected and 0xFF60FF60 or 0xFFFFFFFF
        imgui.text("Signed in as: " .. tostring(link.me ~= "" and link.me or "(Steam unavailable)"))
        imgui.text_colored("Session: " .. st, col)
        if link.peer and link.peer ~= "" then imgui.text("Partner: " .. link.peer) end
        if link.error and link.error ~= "" then imgui.text_colored(link.error, 0xFF4040FF) end
        if link.mode ~= "none" then
            imgui.text(string.format("Traffic: %s in / %s out per second", tostring(link.rx_rate), tostring(link.tx_rate)))
        end
        imgui.separator()
        if link.mode == "none" then
            if imgui.button("Host co-op (Steam)") then cfg.mirror_test = false; save_cfg(); send_cmd("steam_host") end
            imgui.same_line()
            imgui.text("then invite a friend from the Steam overlay")
            local friends = link.friends or {}
            local listed = 0
            for _, f in ipairs(friends) do
                if f.lobby and f.lobby ~= "0" then
                    listed = listed + 1
                    if imgui.button("Join " .. f.name .. "##" .. f.id) then
                        cfg.mirror_test = false; save_cfg(); send_cmd("steam_join", f.lobby)
                    end
                end
            end
            if listed == 0 then imgui.text("No friends hosting right now. (Accepting a Steam invite also works.)") end
            if imgui.tree_node("Direct IP (no Steam)") then
                if imgui.button("Host on UDP 27777") then cfg.mirror_test = false; save_cfg(); send_cmd("udp_host", "27777") end
                c, v = imgui.input_text("Host IP", ip_input); if c then ip_input = v end
                imgui.same_line()
                if imgui.button("Join IP") and ip_input ~= "" then
                    cfg.mirror_test = false; cfg.last_ip = ip_input; save_cfg(); send_cmd("udp_join", ip_input)
                end
                imgui.tree_pop()
            end
            if imgui.button("Solo network test (echo)") then cfg.mirror_test = false; save_cfg(); send_cmd("echo") end
        else
            if link.mode == "steam_host" and link.lobby ~= "" then
                if imgui.button("Invite friend") then send_cmd("invite") end
                imgui.same_line()
            end
            if imgui.button("Leave session") then send_cmd("leave") end
            -- joiner: join a host who is already playing
            if is_joiner() then
                imgui.separator()
                if sync.armed or sync.loading then
                    imgui.text_colored(sync.loading and "Loading the host's game..." or "Joining the host's game...", 0xFF60FF60)
                    if not sync.loading and imgui.button("Cancel") then joiner_abort("Cancelled.") end
                elseif get_player() == nil then
                    if imgui.button("Host is already playing - join them now") then
                        send_cmd("request_save")
                        sync.msg = "Asking the host for their game..."
                    end
                end
            elseif link.mode == "echo" then
                if imgui.button("Test save transfer (echo)") then send_cmd("request_save") end
            end
            draw_ready_ui()
            if cs.msg ~= "" then imgui.text_colored("Cutscene: " .. cs.msg, 0xFF80E0FF) end
            if link.save_state and link.save_state ~= "" then imgui.text("Transfer: " .. link.save_state) end
            if sync.msg ~= "" then imgui.text_colored(sync.msg, 0xFF80E0FF) end
        end
    end
    imgui.separator()
    if partner then
        imgui.text(string.format("Connection: %d updates/s, jitter %d ms, smoothing %d ms%s", net.rate,
            math.floor(net.jitter * 1000 + 0.5), math.floor(net.delay * 1000 + 0.5), net.extrapolating and " (predicting)" or ""))
        imgui.text("Partner animation: " .. anim.mode)
        if link.mode ~= "echo" and anim.peer_mod_version ~= anim.MOD_VERSION then
            imgui.text_colored("Partner mod version: " .. (anim.peer_mod_version or "older than 0.9.0")
                .. " (you have " .. anim.MOD_VERSION .. "). Install the same release on both PCs.", 0xFF60A0FF)
        end
        imgui.text(string.format("Story sync: %d sent, %d applied", mirror.sent, mirror.applied))
        if session and partner_present() then
            if not session.cap then imgui.text_colored("Update both PCs to 0.8.0-preview for mission/cutscene sync.",0xFF60A0FF)
            elseif session.error~="" then imgui.text_colored(session.error,0xFF4040FF)
            else imgui.text("Cutscenes follow the host; both players must agree to skip.") end
        end
        if torch and torch.error~="" then imgui.text_colored("Partner torch: "..torch.error,0xFF4040FF) end
    end
    imgui.text("In game: " .. status .. "    (Requiem Co-op " .. anim.MOD_VERSION .. ")")
    if partner then
        imgui.text(string.format("Partner character: %s  area=%s  (%.1fs ago)", tostring(partner.kind),
            tostring(partner.area), now() - partner_rx_time))
    end
    if imgui.tree_node("Options") then
        c, v = imgui.checkbox("Enabled", cfg.enabled); if c then cfg.enabled = v; save_cfg() end
        c, v = imgui.checkbox("Show name tag", cfg.name_tag); if c then cfg.name_tag = v; save_cfg() end
        c, v = imgui.checkbox("Let the host request debug info from me", cfg.allow_debug_requests)
        if c then cfg.allow_debug_requests = v; save_cfg() end
        c, v = imgui.checkbox("Automatic smoothing (recommended)", cfg.auto_interp); if c then cfg.auto_interp = v; save_cfg() end
        c, v = imgui.checkbox("Native animation (experimental, with bone fallback)", cfg.native_animation)
        if c then cfg.native_animation = v; save_cfg() end
        if not cfg.auto_interp then
            c, v = imgui.slider_int("Interpolation delay (ms)", cfg.interp_ms, 20, 200); if c then cfg.interp_ms = v; save_cfg() end
        end
        c, v = imgui.checkbox("Mirror test (offline: puppet copies you)", cfg.mirror_test)
        if c then cfg.mirror_test = v; partner = nil; snaps = {}; clock_offset = nil; mirror_queue = {}; destroy_puppet(); save_cfg() end
        if imgui.button("Rebuild puppet") then destroy_puppet() end
        imgui.tree_pop()
    end
    imgui.text("F6: show/hide this window")
end

re.on_frame(function()
    if not alive() then return end
    local f0 = os.clock()
    local t = now()
    if t - last_link_read > 0.25 then
        last_link_read = t
        local l = json.load_file(LINK_FILE)
        if type(l) == "table" then link = l end
    end
    local okS, errS = pcall(save_sync_tick)
    if not okS then sync.msg = "save sync error: " .. tostring(errS) end
    local okL, errL = pcall(lobby_tick)
    if not okL then lobby.msg = "lobby error: " .. tostring(errL) end
    local okC, errC = pcall(function() if session then session.tick() else cutscene_tick() end end)
    if not okC then
        cs.msg = "cutscene sync error: " .. tostring(errC)
        if session then session.error=cs.msg;session.message=cs.msg end
    end
    if session and session.message and session.message~="" then pcall(draw.text,session.message,40,40,0xFFFFFFFF)
    else pcall(draw_cutscene_overlay) end
    local pw = os.clock()
    local okW, errW = pcall(world_tick)
    if not okW then pause.msg = "world sync error: " .. tostring(errW) end
    prof_add("world", (os.clock() - pw) * 1000)
    local fms = (os.clock() - f0) * 1000
    prof.frame = prof.frame * 0.95 + fms * 0.05
    if fms > prof.frame_max then prof.frame_max = fms end
    pcall(draw_world_overlay)
    pcall(draw_gameover_overlay)
    flush_cmd()

    -- F6 toggles the window; it opens by itself on the title screen until a session starts
    local down = reframework:is_key_down(cfg.window_key)
    if down and not key_was_down then show_window = not show_window; window_forced = false end
    key_was_down = down
    local on_title = get_player() == nil
    -- the native title-menu lobby replaces the auto-shown window; F6 still opens it
    local auto = on_title and (link.mode == nil or link.mode == "none") and not window_forced
        and not (lobby.menu and lobby.menu.behavior)
    if (show_window or auto) then
        imgui.set_next_window_size(Vector2f.new(460, 0), 4 --[[FirstUseEver]])
        if imgui.begin_window("Requiem Co-op", true, 0) then
            local okP, errP = pcall(draw_panel)
            if not okP then imgui.text_colored("UI error: " .. tostring(errP), 0xFF4040FF) end
            imgui.end_window()
        else
            -- closed with the X
            show_window = false
            window_forced = true
            imgui.end_window()
        end
    end

    if cfg.enabled and cfg.name_tag and puppet and puppet.visible and puppet.cur then
        local p = puppet.cur.pos
        local label = cfg.mirror_test and "Partner (mirror test)" or ((link.peer and link.peer ~= "") and link.peer or "Partner")
        pcall(draw.world_text, label, Vector3f.new(p[1], p[2] + 2.0, p[3]), 0xFF80FF80)
    end
end)

re.on_draw_ui(function()
    if not alive() then return end
    if not imgui.tree_node("Requiem Co-op") then return end
    local okP, errP = pcall(draw_panel)
    if not okP then imgui.text_colored("UI error: " .. tostring(errP), 0xFF4040FF) end
    imgui.tree_pop()
end)

re.on_script_reset(function() destroy_puppet() end)

-- read-only status snapshot, handy for bug reports and debugging from other scripts
_G.__requiem_coop_enemy_details = function() return enemy_hooks.details and enemy_hooks.details() or {} end
_G.__requiem_coop_debug = function()
    return {
        gen = GEN, status = status, cfg = cfg, link = link,
        puppet = puppet and { state = puppet.state, kind = puppet.kind, visible = puppet.visible,
            joints = puppet.map and #puppet.tr:call("get_Joints") or 0,
            pos = puppet.cur and puppet.cur.pos or nil } or nil,
        partner = partner and { kind = partner.kind, area = partner.area, age = now() - partner_rx_time,
            names = partner_names and #partner_names or 0, sk_match = partner_sk == partner.sk } or nil,
        mine = last_state and { kind = last_state.kind, area = last_state.area, pos = last_state.pos } or nil,
        cutscene = session and {current=session.cin.id,phase=session.cin.phase,active=session.cin.active,
            token=session.cin.token,cap=session.cap,message=session.message,error=session.error,stats=session.stats}
            or { current = cs.current, remote = cs.remote, held = cs.held_id, msg = cs.msg },
        torch = torch and {error=torch.error,remote_lights=torch.remote and #torch.remote or 0} or nil,
        prof = prof,
        animation = { mode = anim.mode, peer_version = anim.peer_version, error = anim.error,
            compact = anim.compact_peer or link.mode == "echo",
            sparse_bones = anim.bone_peer or link.mode == "echo", cached_header = anim.header_peer or link.mode == "echo",
            using_sparse_bones = anim.last_sparse, using_cached_header = anim.last_header,
            state_bytes = anim.bytes, native_candidate = last_state and last_state.an ~= nil,
            layers = last_state and last_state.an and #last_state.an.layers or 0,
            sending_bones = last_state and #last_state.q > 0 },
        model = { error = visual.error, matched = puppet and puppet.visual_applied ~= nil },
        weapons = { partner_listed = partner_weps and #partner_weps or 0,
            on_puppet = (function() local n = 0; if puppet and puppet.weps then for _ in pairs(puppet.weps) do n = n + 1 end end; return n end)(),
            mine = wep.last_sig },
        gameover = { active = gameover.active, holding = gameover.holding, phase = gameover_phase(), sent = gameover.sent, applied = gameover.applied, msg = gameover.msg },
        net = net,
        mirror = { sent = mirror.sent, applied = mirror.applied, skipped = mirror.skipped,
            installed=mirror.installed,missing=mirror.missing,error=mirror.error },
        enemies = enemy_hooks.stats and enemy_hooks.stats() or nil,
        world = (function()
            local it, seen, gl = 0, 0, 0
            for _ in pairs(world.items_taken) do it = it + 1 end
            for _ in pairs(world.item_seen) do seen = seen + 1 end
            for _ in pairs(world.gm_last) do gl = gl + 1 end
            return { items_taken = it, items_tracked = seen, gimmicks_tracked = gl, cores = world.cores and #world.cores or 0,
                pause_remote = pause.remote, pause_msg = pause.msg }
        end)(),
        sync = { armed = sync.armed and true or false, loading = sync.loading, prep = sync.prep_until, msg = sync.msg,
            host_sent = sync.host_sent, seed_override = seed_override and tostring(seed_override) or nil },
    }
end

-- Session v3 owns cinematic decisions and repairs registered mission progress.
-- Keep engine callbacks in a library, rather than duplicating game controllers.
do
    local module_name="require.requiem_coop_session"
    package.loaded[module_name]=nil
    local Session=require(module_name)
    local function apply_rpc(index,encoded)
        local m=MIRROR[index]
        if not m or not mirror_allowed() or #encoded~=#m[3] then return false end
        local obj=sdk.get_managed_singleton(m[1]);if not obj then return false end
        local vals={}
        for i,kind in ipairs(m[3]) do
            if type(encoded[i])~="string" or #encoded[i]>2048 then return false end
            local value=decode_arg(kind,encoded[i]);if value==nil then return false end;vals[i]=value
        end
        mirror.authorized=mirror.authorized or {}
        if index==1 or index==2 then
            local expected=mirror.authorized[vals[1]]
            if expected and expected.value==vals[2] and now()<expected.until_time then return true end
            if obj:call("getProgressiveNumber",vals[1])==vals[2] then return true end
            local allowed=expected and expected.allowed or {}
            allowed[vals[2]]=now()+3
            mirror.authorized[vals[1]]={value=vals[2],allowed=allowed,until_time=now()+3}
        elseif index==3 or index==20 then mirror.authorized[vals[1]]={reset=true,until_time=now()+3} end
        mirror.applying=true
        local ok,value=pcall(function()
            -- Setting the counter directly can bypass mission-node execution.
            -- Networked setters are normalized to the game's queued transition.
            if index==1 or index==2 then return obj:call("requestChangeProgressiveNumber(System.UInt32, System.Int32)",vals[1],vals[2]) end
            return obj:call(m[2],table.unpack(vals,1,#m[3]))
        end)
        mirror.applying=false
        if ok and value~=false then mirror.applied=mirror.applied+1;return true end
        if session then session.error=tostring(value) end
        return false
    end
    local function progress()
        local chapter=chapter_of(my_area());if not chapter then return end
        local fm=sdk.get_managed_singleton("app.LevelFlowManager")
        local dict=fm and fm:get_field("_ProgressiveNumberList");if not dict then return end
        local entries=dict:get_field("_entries");if not entries then return end
        local values,seen={},{}
        -- _entries includes unused capacity. Public lookups avoid copying free
        -- slots as spurious flow zero entries, including after dictionary edits.
        for i=0,math.min(dict:get_field("_count"),entries:get_size())-1 do
            local e=entries:get_element(i);local key=e and e:get_field("key")
            if type(key)=="number" and not seen[key] and dict:call("ContainsKey",key) then
                seen[key]=true;values[#values+1]={key,dict:call("get_Item",key)}
            end
        end
        table.sort(values,function(a,b)return a[1]<b[1]end)
        return values,chapter
    end
    local function apply_progress(d)
        if chapter_of(my_area())~=d.chapter then return 0,#d.values end
        local fm=sdk.get_managed_singleton("app.LevelFlowManager")
        local dict=fm and fm:get_field("_ProgressiveNumberList");if not dict then return 0,#d.values end
        mirror.authorized=mirror.authorized or {}
        local applied,remaining=0,0
        for _,p in ipairs(d.values) do
            if not dict:call("ContainsKey",p[1]) then remaining=remaining+1
            elseif dict:call("get_Item",p[1])~=p[2] then
                local expected=mirror.authorized[p[1]]
                if not expected or expected.value~=p[2] or now()>=expected.until_time then
                    local allowed=expected and expected.allowed or {}
                    allowed[p[2]]=now()+3
                    mirror.authorized[p[1]]={value=p[2],allowed=allowed,until_time=now()+3}
                    mirror.applying=true
                    local ok=pcall(fm.call,fm,"requestChangeProgressiveNumber(System.UInt32, System.Int32)",p[1],p[2])
                    mirror.applying=false
                    if ok then applied=applied+1 end
                end
                remaining=remaining+1
            end
        end
        return applied,remaining
    end
    local env={epoch=tostring(os.time()).."-"..GEN,now=now,connected=partner_present,
        role=function()return is_host() and "host" or "client"end,
        peer=function()return tostring(link.mode)..":"..tostring(link.peer)..":"..tostring(link.lobby)end,
        send=function(k,data)bridge_event(k..":"..json.dump_string(data))end,
        area=my_area,scene=current_scene,apply_rpc=apply_rpc,progress=progress,apply_progress=apply_progress,max_rpc=#MIRROR,
        progress_signature=function(values,chapter)return fnv32(chapter..json.dump_string(values))end,
        where=function()
            local _,_,go=get_player();if not go then return end
            local tr=go:call("get_Transform");local p,r=tr:call("get_Position"),tr:call("get_Rotation")
            return {p.x,p.y,p.z,r.x,r.y,r.z,r.w}
        end,
        warp=function(where)
            if type(where)~="table" or #where~=7 then return false end
            for _,v in ipairs(where) do if type(v)~="number" or v~=v or math.abs(v)>1e7 then return false end end
            return warp_player(table.unpack(where))
        end}
    session=Session.new(Session.engine(env))
    torch=Session.torch({now=now,qrot=qrot,qmul=qmul,
        peer=function()return env.peer()..":"..tostring(session.peer_epoch)end,
        enabled=function()return cfg.mirror_test or link.mode=="echo" or (partner_present() and session.cap)end,
        stream=function()return fnv32(session.epoch)end,
        peer_stream=function()return fnv32((cfg.mirror_test or link.mode=="echo") and session.epoch or session.peer_epoch or "")end,
        send=function(bytes)
            if cfg.mirror_test or link.mode=="echo" then torch.receive(bytes)
            elseif use_bridge() then coopnet.send_enemy(bytes) end
        end,
        off=function(seq)bridge_event("torchOff3:"..json.dump_string({seq=seq,epoch=session.epoch}))end,
        create=function(name,folder)return GO_CREATE:call(nil,name,folder):add_ref()end,
        destroy=function(go)if go and go:call("get_Valid") then GO_DESTROY:call(nil,go)end end})
end

-- Native title menu: a "Co-op" entry in the game's own menu that opens a co-op lobby built from
-- the same menu rows. Engine hooks are registered once per game session and dispatch to the
-- current script copy, so hot reloads replace the implementation.
do
    local module_name = "require.requiem_coop_menu"
    package.loaded[module_name] = nil
    local ok_m, Menu = pcall(require, module_name)
    if ok_m then
        local menu
        menu = Menu.new({
            now = now, lobby = lobby, link = function() return link end, plugin_alive = plugin_alive,
            in_session = in_session, is_host = is_host, partner_present = partner_present, get_player = get_player,
            host = function() cfg.mirror_test = false; save_cfg(); send_cmd("steam_host") end,
            join = function(id) cfg.mirror_test = false; save_cfg(); send_cmd("steam_join", id) end,
            invite = function() send_cmd("invite") end,
            leave = function() send_cmd("leave") end,
            toggle_ready = function() lobby.me_ready = not lobby.me_ready; announce_ready() end,
            start = function() menu.to_main_story("Choose New Game, Continue or Load Game - your partner's game follows.") end,
            can_join_running = function() return is_joiner() and not (sync.armed or sync.loading) end,
            join_running = function() send_cmd("request_save"); sync.msg = "Asking the host for their game..."; menu.say(sync.msg) end,
            coop_label = function()
                if is_host() then return partner_present() and "Co-op  (Partner joined)" or "Co-op  (Hosting)" end
                if is_joiner() then return "Co-op  (Joined)" end
                return "Co-op"
            end,
            coop_guide = function()
                if in_session() then return "Open the co-op lobby: ready up, invite or leave." end
                return "Play the story together with a friend over Steam."
            end,
        })
        lobby.menu = menu
        local last_msg, last_sync = lobby.msg, sync.msg
        re.on_pre_application_entry("LateUpdateBehavior", function()
            if not alive() then return end
            if lobby.msg ~= last_msg then last_msg = lobby.msg; menu.say(lobby.msg) end
            if sync.msg ~= last_sync then last_sync = sync.msg; menu.say(sync.msg) end
            if not menu.behavior then return end
            local t0 = os.clock()
            local ok_t, err_t = pcall(menu.tick)
            if not ok_t then menu.error = tostring(err_t) end
            prof_add("title_menu", (os.clock() - t0) * 1000)
        end)
        -- hook bodies live here (reloadable); the engine hooks below only forward their args
        local function mine(args)
            local this = sdk.to_managed_object(args[2])
            return this and menu.behavior and this:get_address() == menu.behavior:get_address() and this or nil
        end
        _G.__requiem_coop_title_menu = {
            menu = menu,
            update_items = function(args)
                if not alive() then return end
                local ok, arr = pcall(menu.on_update_items, sdk.to_managed_object(args[2]), sdk.to_managed_object(args[3]))
                if ok and arr then args[3] = sdk.to_ptr(arr) elseif not ok then menu.error = tostring(arr) end
            end,
            decided = function(args)
                if not alive() then return end
                local this = mine(args)
                if not this then return end
                local ok, skip = pcall(menu.on_decided, this, sdk.to_managed_object(args[3]))
                if not ok then menu.error = tostring(skip) end
                return ok and skip
            end,
            canceled = function(args)
                if not alive() then return end
                local this = mine(args)
                local ok, skip = pcall(menu.on_canceled, this)
                return this and ok and skip
            end,
        }
    else
        lobby.menu_error = tostring(Menu)
    end
end
do
    -- Real input never calls onSelectItemDecided/onSelectItemCanceled: the scroll-list helper invokes
    -- compiler-generated callbacks registered in setupScrollListHelper (verified in-game: b__9_0 =
    -- decided -> TitleFlowController.on*, b__9_1 = canceled, b__9_2 = cursor moved, b__9_3 = list
    -- update). Both the callbacks and the named methods are hooked; neither calls the other.
    local TITLE_MENU_TD = sdk.find_type_definition("app.UI1010GuiBehavior")
    local function callback(index)
        for _, m in ipairs(TITLE_MENU_TD:get_methods()) do
            if m:get_name() == "<setupScrollListHelper>b__9_" .. index then return m end
        end
    end
    local function forward(name)
        return function(args)
            local h = _G.__requiem_coop_title_menu
            local ok, skip = pcall(function() return h and h[name](args) end)
            if ok and skip then return sdk.PreHookResult.SKIP_ORIGINAL end
        end
    end
    if TITLE_MENU_TD and not _G.__requiem_coop_title_menu_hooks then
        _G.__requiem_coop_title_menu_hooks = true
        sdk.hook(TITLE_MENU_TD:get_method("updateItems"), forward("update_items"), nil)
        sdk.hook(TITLE_MENU_TD:get_method("onSelectItemDecided"), forward("decided"), nil)
        sdk.hook(TITLE_MENU_TD:get_method("onSelectItemCanceled"), forward("canceled"), nil)
    end
    if TITLE_MENU_TD and not _G.__requiem_coop_title_menu_hooks2 then
        _G.__requiem_coop_title_menu_hooks2 = true
        local decided, canceled = callback(0), callback(1)
        if decided then sdk.hook(decided, forward("decided"), nil) end
        if canceled then sdk.hook(canceled, forward("canceled"), nil) end
    end
    if lobby.menu then lobby.menu.decide_method = TITLE_MENU_TD and callback(0) end
end
_G.__requiem_coop_menu = nil   -- disables hooks left by 0.9.0 development builds
-- Read-only handles for the in-game benchmark (tools/bench_perf.lua). Nothing calls these.
_G.__requiem_coop_internals = { capture_local = capture_local, visual = visual, anim = anim, wep = wep,
    scan_local_weapons = scan_local_weapons, pack_state = pack_state, unpack_state = unpack_state,
    get_player = get_player, area_of = area_of, local_cache = function() return local_cache end,
    puppet = function() return puppet end, prof = prof }
