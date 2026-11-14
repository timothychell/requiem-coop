-- In-game micro-benchmark of the mod's per-send work. Read-only: no config, save,
-- mission or network state is changed (visual.scan may emit a model event, which
-- is a no-op without a partner). Run through Invoke-CoopBridge.ps1.
local I = assert(_G.__requiem_coop_internals, 'mod internals not exported')
local cm, ctx, go = I.get_player()
assert(go, 'no player loaded')
local function bench(n, fn)
    fn() -- warm caches
    local t0 = os.clock()
    for _ = 1, n do fn() end
    return (os.clock() - t0) * 1000 / n
end
local r = {}
local cache = I.local_cache()
if not cache.joints then I.capture_local(ctx, go); cache = I.local_cache() end
local joints = cache.joints
r.joint_count = #joints

-- string-dispatched joint reads (what capture_local does today)
r.bones_string_ms = bench(50, function()
    for _, j in ipairs(joints) do local q = j:call('get_LocalRotation') end
end)
local m_lr = sdk.find_type_definition('via.Joint'):get_method('get_LocalRotation')
r.bones_method_ms = bench(50, function()
    for _, j in ipairs(joints) do local q = m_lr:call(j) end
end)
r.anim_capture_ms = bench(50, function() I.anim.capture(go) end)
r.area_of_ms = bench(200, function() I.area_of(go) end)
r.kind_tostring_ms = bench(200, function() ctx:call('get_KindID'):call('ToString') end)
r.capture_local_ms = bench(30, function() I.capture_local(ctx, go) end) -- scan is throttled to 1 Hz inside
r.visual_scan_ms = bench(10, function() I.visual.last_scan = -100; I.visual.scan(go, { kind = 'x', mm = 1, mp = 1 }) end)
r.weapon_scan_ms = bench(10, function() I.scan_local_weapons(go) end)
r.link_json_read_ms = bench(50, function() json.load_file('coop_link.json') end)
local st = I.capture_local(ctx, go); st.seq, st.t = 1, os.clock()
r.pack_state_ms = bench(200, function() I.pack_state(st) end)
r.state_bytes = #I.pack_state(st)
r.native = st.an ~= nil
r.clock_resolution_ms = (function() local a = os.clock(); local b = a; while b == a do b = os.clock() end; return (b - a) * 1000 end)()
return r
