-- Development probe, executed through requiem_bridge.lua; never loaded by autorun.
-- probe_action is supplied by Invoke-AnimationProbe.ps1.
local KEY = '__requiem_native_animation_probe'
local function cleanup()
    local p = _G[KEY]
    if p and p.go and p.go:call('get_Valid') then
        sdk.find_type_definition('via.GameObject'):get_method('destroy(via.GameObject)'):call(nil, p.go)
    end
    _G[KEY] = nil
end

if probe_action == 'cleanup' then
    cleanup()
    return { cleaned = true }
end

if probe_action == 'start' then
    cleanup()
    local cm = sdk.get_managed_singleton('app.CharacterManager')
    local ctx = cm and cm:call('get_PlayerContextFast')
    local player = ctx and ctx:call('get_GameObject')
    assert(player and player:call('get_Valid'), 'Load a playable scene first')
    local source = player:call('getComponent(System.Type)', sdk.typeof('via.motion.Motion'))
    local skeleton = player:call('getComponent(System.Type)', sdk.typeof('via.motion.DummySkeleton'))
    assert(source and skeleton, 'Player animation/skeleton unavailable')
    local src_layer
    for i = 0, source:call('getLayerCount') - 1 do
        local l = source:call('getLayer', i)
        if l and l:call('get_EndFrame') > 2 then src_layer = l; break end
    end
    assert(src_layer, 'No multi-frame player animation is active')
    local bank, motion_id = src_layer:call('get_MotionBankID'), src_layer:call('get_MotionID')
    local go = sdk.find_type_definition('via.GameObject'):get_method('create(System.String, via.Folder)')
        :call(nil, 'coop_native_animation_probe', player:call('get_Folder')):add_ref()
    local p = { go = go, bank = bank, motion_id = motion_id, started = os.clock(), samples = 0 }
    _G[KEY] = p -- retain for cleanup even if a later assertion fails
    go:call('set_DrawSelf', false)
    local ds = go:call('createComponent(System.Type)', sdk.typeof('via.motion.DummySkeleton'))
    ds:call('set_SkeletonResourceHandle', skeleton:call('get_SkeletonResourceHandle'))
    local m = go:call('createComponent(System.Type)', sdk.typeof('via.motion.Motion'))
    p.motion = m:add_ref()
    m:call('set_MotionBankAsset', source:call('get_MotionBankAsset'))
    m:call('set_TargetBankType', source:call('get_TargetBankType'))
    m:call('setupMotionBank')
    m:call('setLayerCount', 1)
    p.layer = sdk.create_instance('via.motion.TreeLayer'):add_ref()
    m:call('setLayer', 0, p.layer)
    p.layer:call('changeLocalBankType', src_layer:call('get_MotionBankType'))
    p.layer:call('changeMotion(System.UInt32, System.UInt32, System.Single)', bank, motion_id, 0.0)
    p.layer:call('set_Speed', 1.0)
    p.layer:call('set_BlendRate', 1.0)
end

local p = assert(_G[KEY], 'Start the probe first')
assert(p.go:call('get_Valid'), 'Probe was unloaded; start again')
local js = p.go:call('get_Transform'):call('get_Joints')
local pose, max_delta = {}, 0
for i = 0, js:get_size() - 1 do
    local j = js:get_element(i)
    local r = j:call('get_LocalRotation')
    local q = { r.x, r.y, r.z, r.w }
    pose[i + 1] = q
    if p.pose then
        local prev = p.pose[i + 1]
        if prev then
            local dot = math.abs(q[1]*prev[1] + q[2]*prev[2] + q[3]*prev[3] + q[4]*prev[4])
            max_delta = math.max(max_delta, 1 - math.min(1, dot))
        end
    end
end
local frame, end_frame = p.layer:call('get_Frame'), p.layer:call('get_EndFrame')
local result = {
    bank = p.bank, motion_id = p.motion_id, frame = frame, end_frame = end_frame,
    joints = js:get_size(), elapsed = os.clock() - p.started,
    frame_changed = p.frame ~= nil and math.abs(frame - p.frame) > 0.001,
    pose_changed = p.pose ~= nil and max_delta > 0.00001,
    max_rotation_delta = max_delta, sample = p.samples,
    dynamic_banks_copied = false,
}
p.pose, p.frame, p.samples = pose, frame, p.samples + 1
return result
