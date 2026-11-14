local player = sdk.get_managed_singleton('app.CharacterManager'):call('get_PlayerContextFast'):call('get_GameObject')
local puppet
for i=1,100 do
    local name,value=debug.getupvalue(_G.__requiem_coop_debug,i)
    if not name then break end
    if name=='puppet' then puppet=value end
end
local function inspect(go)
    local tr=go:call('get_Transform')
    local p=tr:call('get_Position')
    local out={name=go:call('get_Name'),parts={},root_joints=tr:call('get_Joints'):get_size()}
    local function visit(g,path)
        local t=g:call('get_Transform')
        local joints=t:call('get_Joints')
        local entry={name=path,components={},joints=joints and joints:get_size() or 0,draw=g:call('get_DrawSelf')}
        local arr=g:call('get_Components')
        for i=0,arr:get_size()-1 do entry.components[#entry.components+1]=arr:get_element(i):get_type_definition():get_full_name() end
        local mesh=g:call('getComponent(System.Type)',sdk.typeof('via.render.Mesh'))
        if mesh then
            local mh,mat=mesh:call('getMesh'),mesh:call('get_Material')
            entry.mesh=mh and mh:call('get_ResourcePath')
            entry.material=mat and mat:call('get_ResourcePath')
            entry.shared=mesh:call('get_SharedSkeleton')
            entry.external=mesh:call('get_SkeletonSharedExternal')
            entry.ready=mesh:call('get_ReadyToDraw')
            entry.enabled=mesh:call('get_Enabled')
            local aabb=mesh:call('get_WorldAABB')
            local center,extent=aabb:call('getCenter'),aabb:call('getExtent')
            entry.bounds={center={center.x,center.y,center.z},extent={extent.x,extent.y,extent.z}}
        end
        entry.far_joints={}
        for i=0,(joints and joints:get_size() or 0)-1 do
            local j=joints:get_element(i)
            local jp=j:call('get_Position')
            local distance=math.sqrt((jp.x-p.x)^2+(jp.y-p.y)^2+(jp.z-p.z)^2)
            entry.max_joint_distance=math.max(entry.max_joint_distance or 0,distance)
            if distance>4 and #entry.far_joints<12 then entry.far_joints[#entry.far_joints+1]={name=j:call('get_Name'),distance=distance} end
        end
        out.parts[#out.parts+1]=entry
        local child=t:call('get_Child')
        while child do
            local cg=child:call('get_GameObject')
            visit(cg,path..'/'..cg:call('get_Name'))
            child=child:call('get_Next')
        end
    end
    visit(go,go:call('get_Name'))
    return out
end
return {player=inspect(player),puppet=puppet and inspect(puppet.go),reference_api=H.methods('via.GameObjectRef')}
