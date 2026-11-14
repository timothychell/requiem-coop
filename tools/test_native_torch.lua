-- Local, temporary light objects only. No player input, mission or cutscene is changed.
local key='__requiem_native_torch_test'
local action=torch_test_action or 'sample'
local function get_torch()
    for i=1,100 do local n,v=debug.getupvalue(_G.__requiem_coop_debug,i);if not n then break end;if n=='torch' then return v end end
end
local destroy=sdk.find_type_definition('via.GameObject'):get_method('destroy(via.GameObject)')
local function cleanup()
    local t=_G[key]
    if t then
        t.torch.clear()
        t.torch.remote,t.torch.remote_seq,t.torch.received,t.torch.owner=t.saved.remote,t.saved.seq,t.saved.received,t.saved.owner
        if t.go:call('get_Valid') then destroy:call(nil,t.go) end
        _G[key]=nil
    end
end
if action=='cleanup' then cleanup();return {cleaned=true}end
if action=='create' then
    cleanup()
    local d=_G.__requiem_coop_debug();assert(not d.link.connected and (not d.link.peer or d.link.peer==''),'Active peer; no test injection')
    local torch=assert(get_torch(),'Torch adapter missing')
    local env
    for i=1,30 do local n,v=debug.getupvalue(torch.receive,i);if not n then break end;if n=='E' then env=v end end
    assert(env)
    local player=sdk.get_managed_singleton('app.CharacterManager'):call('get_PlayerContextFast'):call('get_GameObject')
    local create=sdk.find_type_definition('via.GameObject'):get_method('create(System.String, via.Folder)')
    local go=create:call(nil,'coop_torch_test',player:call('get_Folder')):add_ref()
    local tr=go:call('get_Transform');local pt=player:call('get_Transform')
    tr:call('set_Position',pt:call('get_Position'));tr:call('set_Rotation',pt:call('get_Rotation'))
    local t={go=go,torch=torch,saved={remote=torch.remote,seq=torch.remote_seq,received=torch.received,owner=torch.owner},
        target={go=go,tr=tr,folder=player:call('get_Folder')}}
    _G[key]=t
    torch.remote_seq=-1
    local records={{kind=1,p={0,1.5,0},q={0,0,0,1},radius=20,cone=45,falloff=0.5,intensity=1000,color={1,0.95,0.85}},
        {kind=2,p={0,1.5,0},q={0,0,0,1},radius=2,cone=0,falloff=0,intensity=10,color={1,0.95,0.85}}}
    torch.receive(torch.pack(10,records,env.peer_stream()))
    torch.apply(t.target,true)
    t.source_capture_count=#torch.capture(player)
end
local t=assert(_G[key],'Create the test first')
local out={lights={},source_capture_count=t.source_capture_count}
for _,item in pairs(t.torch.lights) do
    out.lights[#out.lights+1]={kind=item.kind,enabled=item.light:call('get_Enabled'),radius=item.light:call('get_Radius'),intensity=item.light:call('get_Intensity')}
end
return out
