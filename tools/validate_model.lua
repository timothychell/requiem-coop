-- Read-only comparison in mirror/echo mode, with a dressed puppet present.
local player=sdk.get_managed_singleton('app.CharacterManager'):call('get_PlayerContextFast'):call('get_GameObject')
local puppet,visual
for i=1,100 do
    local name,value=debug.getupvalue(_G.__requiem_coop_debug,i)
    if not name then break end
    if name=='puppet' then puppet=value elseif name=='visual' then visual=value end
end
assert(puppet and visual,'Start mirror/echo mode and wait for the puppet')
local passed,failures,details=0,{},{}
local function check(value,message)
    if value then passed=passed+1 else failures[#failures+1]=message end
end
local function children(go)
    local list={}
    local c=go:call('get_Transform'):call('get_Child')
    while c do local g=c:call('get_GameObject');list[g:call('get_Name')]=g;c=c:call('get_Next') end
    return list
end
local function resource(component,getter)
    local h=component:call(getter)
    return h and h:call('get_ResourcePath')
end
local source_parts,target_parts=children(player),children(puppet.go)
local ds=sdk.typeof('via.motion.DummySkeleton')
check(resource(player:call('getComponent(System.Type)',ds),'get_SkeletonResourceHandle')==
    resource(puppet.go:call('getComponent(System.Type)',ds),'get_SkeletonResourceHandle'),'root skeleton differs')
for name,go in pairs(source_parts) do
    local mesh=go:call('getComponent(System.Type)',sdk.typeof('via.render.Mesh'))
    local path=mesh and resource(mesh,'getMesh')
    if path and path:sub(1,13):lower()=='character/ch/' then
        local target=target_parts[name]
        check(target~=nil,'missing body part '..name)
        local tm=target and target:call('getComponent(System.Type)',sdk.typeof('via.render.Mesh'))
        if tm then
            check(resource(tm,'getMesh')==path,'mesh differs: '..name)
            check(resource(tm,'get_Material')==resource(mesh,'get_Material'),'material differs: '..name)
            check(target:call('get_DrawSelf'),'body part hidden: '..name)
            check(target:call('get_UpdateSelf'),'body part updates disabled: '..name)
            local ext=tm:call('get_WorldAABB'):call('getExtent')
            check(math.min(ext.x,ext.y,ext.z)>=0 and math.max(ext.x,ext.y,ext.z)<3,'invalid/stretched render bounds: '..name)
            local n=mesh:call('getPartsEnableCount')
            for i=0,math.min(n,1024)-1 do check(mesh:call('getPartsEnable',i)==tm:call('getPartsEnable',i),'submesh mask differs: '..name..':'..i) end
            details[#details+1]={part=name,mesh=path,extent={ext.x,ext.y,ext.z}}
            local source_children,target_children=children(go),children(target)
            for hair_name,hair_go in pairs(source_children) do
                local hair=hair_go:call('getComponent(System.Type)',sdk.typeof('via.render.Strands'))
                if hair then
                    local th=target_children[hair_name]
                    local strands=th and th:call('getComponent(System.Type)',sdk.typeof('via.render.Strands'))
                    check(strands~=nil,'strand component missing: '..hair_name)
                    if strands then
                        check(resource(strands,'get_Strand')==resource(hair,'get_Strand'),'hair strand asset differs')
                        check(resource(strands,'get_Material')==resource(hair,'get_Material'),'hair material differs')
                        for _,prop in ipairs(visual.hair_props) do
                            local ok,v=pcall(hair.call,hair,'get_'..prop)
                            if ok then check(strands:call('get_'..prop)==v,'hair setting differs: '..prop) end
                        end
                        local dyn=th:call('getComponent(System.Type)',sdk.typeof('via.dynamics.GpuStrandsDynamics'))
                        local sd=hair_go:call('getComponent(System.Type)',sdk.typeof('via.dynamics.GpuStrandsDynamics'))
                        check(dyn and dyn:call('get_Initialized'),'hair simulation uninitialized')
                        local count=sd and sd:call('get_StrandCount') or 0
                        -- First-person source hair can be culled/uninitialized.
                        -- A visible third-person copy must still initialize.
                        check(dyn and (count==0 and dyn:call('get_StrandCount')>0 or dyn:call('get_StrandCount')==count),'simulation strand count differs')
                    end
                end
            end
        end
    end
end
return {passed=passed,failures=failures,parts=details,model_error=visual.error}
