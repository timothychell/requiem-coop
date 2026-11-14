-- Runs in stock Lua 5.4 or via the in-game bridge. No game objects are touched.
local root = '' -- run stock Lua from the source root, or supply protocol_source via the bridge
local source = protocol_source
if not source then
    local f = assert(io.open(root .. 'mod/reframework/autorun/requiem_coop.lua', 'rb'))
    source = f:read('*a'); f:close()
end
source = source:gsub('\r\n', '\n')
local function between(first, last)
    local a = assert(source:find(first, 1, true))
    local b = assert(source:find(last, a + #first, true))
    return source:sub(a, b - 1)
end
local prefix = [[
local cfg={mirror_test=false,native_animation=true}
local link={mode='test'}
local now=os.clock
]] .. between('local function fnv32(', '-- quaternion components') ..
between('local function q16(', '-- quaternion product') ..
between('local anim = ', '---------------------------------------------------------------------------\n-- local state capture')
local codecs = between('local STATE_HEAD = ', '-- joint names travel once')
local api = assert(load(prefix .. codecs .. '\nreturn {anim=anim,pack=pack_state,unpack=unpack_state,fnv32=fnv32}', 'protocol-test'))()
local a = { id=123, layers={
    {slot=0,bank=100,motion=7007,bank_type=0,mask=0,mask_mode=0,blend_mode=0,namespace=0,base=0,
        wrap=2,frame=31.25,speed=1,weight=1,ending=238},
    {slot=4,bank=100,motion=6000,bank_type=0,mask=201,mask_mode=0,blend_mode=1,namespace=2,base=0,
        wrap=0,frame=0,speed=0.5,weight=0.75,ending=1}
}}
local checked = 0
local function check(value, message) checked=checked+1; assert(value,message) end
local packed = api.anim.pack(a)
local decoded = api.anim.unpack(packed,1)
check(decoded.id==a.id and #decoded.layers==2,'animation header round trip')
for i,l in ipairs(a.layers) do
    for key,v in pairs(l) do check(decoded.layers[i][key]==v,'layer field '..key) end
end
for i=0,#packed-1 do check(not pcall(api.anim.unpack,packed:sub(1,i),1),'truncation accepted') end
check(not pcall(api.anim.unpack,packed..'x',1),'trailing byte accepted')
local saved=a.layers[1].slot; a.layers[1].slot=16
check(not pcall(api.anim.unpack,api.anim.pack(a),1),'invalid layer index accepted'); a.layers[1].slot=saved
a.layers[2].slot=0
check(not pcall(api.anim.unpack,api.anim.pack(a),1),'duplicate layer accepted'); a.layers[2].slot=4
local state={seq=12,t=99.5,sk=4321,kind='cp_A000',mm=100,mp=1,area='Chap3_10',
    pos={1,2,3},rot={0,0,0,1},q={0,0,0,1},lp={root={0,1,0}}}
local legacy=api.pack(state)
local old=api.unpack(legacy)
check(#old.q==4 and old.an==nil and old.lp.root[2]==1,'legacy state round trip')
state.an=a; api.anim.peer_version=0
check(api.pack(state)==legacy,'unnegotiated peer received extension')
api.anim.peer_version=1
local hybrid=api.unpack(api.pack(state))
check(#hybrid.q==4 and hybrid.an.id==123,'hybrid state round trip')
state.q={};state.lp={}
local native=api.pack(state)
local new=api.unpack(native)
check(#new.q==0 and new.an.id==123 and new.seq==12,'native state round trip')
for i=0,#native-1 do check(not pcall(api.unpack,native:sub(1,i)),'truncated native state accepted') end
check(#native < #legacy+100,'unexpected native state overhead')
check(not api.anim.can_send(a),'unacknowledged resource accepted')
api.anim.event('anver','1');api.anim.event('anready','123')
check(not api.anim.can_send(a),'unknown descriptor acknowledgement accepted')
api.anim.descriptors[123]='test';api.anim.event('anready','123')
check(api.anim.can_send(a),'valid acknowledgement rejected')
api.anim.ready[123]=os.clock()-6
check(not api.anim.can_send(a),'expired acknowledgement accepted')
api.anim.event('anready','123')
api.anim.event('anfail','123');check(not api.anim.can_send(a),'fallback request ignored')
check(api.anim.asset_path('Animation/ch/a.motbank','Animation/','.motbank'),'valid asset path rejected')
check(not api.anim.asset_path('Animation/../a.motbank','Animation/','.motbank'),'asset traversal accepted')
state.an=nil;state.q={};state.lp={root={0,0,0},Hip={0,1,0}}
for _=1,84 do for _,v in ipairs({0,0,0,1}) do state.q[#state.q+1]=v end end
local full_bones=api.pack(state)
check(#api.unpack(full_bones).q==336,'84-joint round trip')
local enemy_stub = [[
local en={remote={},remote_names={},names_asked={}}
local bridge_event=function() end
]]
local enemy_head = assert(source:match('local ENEMY_HEAD = [^\n]+')) .. '\n'
local enemy_api = assert(load(prefix .. enemy_stub .. enemy_head ..
    between('local function dist3(', 'local function refresh_enemy_list') ..
    between('local function enemy_recv(b)', 'local function enemy_event') ..
    '\nreturn {recv=enemy_recv,states=en.remote,anim=anim}', 'enemy-protocol-test'))()
local function enemy_packet(sent,px,native_mode,id)
    local flags=native_mode and 12 or 1
    local bytes=string.pack('<s1s1I4fffhhhhi4BB',id or 'enemy-1','em0000',4321,px,2,3,0,0,0,32767,100,0,flags)
    if native_mode then
        return bytes .. string.pack('<Hd',0,sent) .. api.anim.pack(a)
    end
    return bytes .. string.pack('<fffHhhhh',0,1,0,1,0,0,0,32767)
end
enemy_api.recv(enemy_packet(10,0,true))
check(enemy_api.states['enemy-1'].an.id==123 and #enemy_api.states['enemy-1'].q==0,'native enemy decode')
enemy_api.recv(enemy_packet(10.1,1,true))
check(math.abs(enemy_api.states['enemy-1'].velocity[1]-10)<0.001,'enemy velocity estimation')
local latest=enemy_api.states['enemy-1']
enemy_api.recv(enemy_packet(9,100,true))
check(enemy_api.states['enemy-1']==latest,'out-of-order enemy state accepted')
enemy_api.recv(enemy_packet(10.2,100,true))
check(enemy_api.states['enemy-1'].teleport and not enemy_api.states['enemy-1'].velocity,'enemy teleport predicted as movement')
enemy_api.states['enemy-1'].t=os.clock()-3
enemy_api.recv(enemy_packet(0.1,101,true))
check(enemy_api.states['enemy-1'].sent_t==0.1,'restarted peer clock rejected')
enemy_api.recv(enemy_packet(11,100,false))
check(#enemy_api.states['enemy-1'].q==4 and enemy_api.states['enemy-1'].lp.root[2]==1,'legacy enemy decode')
local enemy_native=enemy_packet(12,0,true)
for i=0,#enemy_native-1 do
    enemy_api.states['enemy-1']=nil
    pcall(enemy_api.recv,enemy_native:sub(1,i))
    check(enemy_api.states['enemy-1']==nil,'truncated enemy state accepted')
end
-- Fixed layer configuration travels reliably once. Compact snapshots preserve
-- the exact float32 phase/speed/weight values used by AN01; no quantization.
state.q={};state.lp={};state.an=a
api.anim.compact_peer=true
local awaiting=api.pack(state)
check(awaiting:find('AN01',1,true)~=nil,'compact sent before layout acknowledgement')
for id,bytes in pairs(api.anim.layout_local) do
    api.anim.event('aldef',id..':'..api.anim.hex(bytes))
    api.anim.event('alack',tostring(id))
end
local compact=api.pack(state)
check(compact:find('AN02',1,true)~=nil,'compact packet not selected')
local compact_state=api.unpack(compact)
for i,l in ipairs(a.layers) do
    for key,value in pairs(l) do check(compact_state.an.layers[i][key]==value,'compact field '..key) end
end
check(#compact < #native,'compact packet did not shrink')
for i=0,#compact-1 do check(not pcall(api.unpack,compact:sub(1,i)),'truncated compact packet accepted') end
local saved_layouts=api.anim.layout_remote;api.anim.layout_remote={}
local requests={};api.anim.emit=function(message) requests[#requests+1]=message end
check(not pcall(api.unpack,compact),'undefined compact layout accepted')
check(#requests==1 and requests[1]:match('^alreq:'),'missing layout did not request repair')
pcall(api.unpack,compact)
check(#requests==1,'missing layout repair was not throttled')
api.anim.emit=nil
api.anim.layout_remote=saved_layouts
api.anim.compact_peer=false
a.layers[1].frame=23.1234567
local float32=api.unpack(api.pack(state)).an.layers[1].frame
api.anim.compact_peer=true
check(api.unpack(api.pack(state)).an.layers[1].frame==float32,'compact frame lost float32 precision')
-- Sparse bone components retain the exact int16 values, including the sign of w.
api.anim.bone_peer=true
for joints=1,17 do
    local qi={}
    for i=1,joints*4 do qi[i]=i%4==0 and 32767 or 0 end
    qi[2]=-123;qi[#qi]=-32767
    local encoded,sparse=api.anim.pack_bones(qi)
    check(sparse,'sparse pose not selected')
    local q,next_at=api.anim.unpack_bones(encoded,1,joints,true)
    check(next_at==#encoded+1,'sparse end offset')
    for i,v in ipairs(qi) do check(q[i]==v/32767,'sparse component changed') end
    for cut=0,#encoded-1 do check(not pcall(api.anim.unpack_bones,encoded:sub(1,cut),1,joints,true),'truncated sparse pose accepted') end
end
local dense={};for i=1,336 do dense[i]=i end
local dense_bytes,dense_sparse=api.anim.pack_bones(dense)
check(not dense_sparse and #dense_bytes==672,'dense pose expanded')
check(not pcall(api.anim.unpack_bones,'\240',1,1,true),'nonzero sparse padding accepted')
check(not pcall(api.anim.unpack_bones,'',1,0,true),'empty sparse pose accepted')
state.an=nil;state.q=protocol_pose or {}
if #state.q==0 then for _=1,84 do for _,v in ipairs({0,0,0,1}) do state.q[#state.q+1]=v end end end
state.lp={root={0,0,0},Hip={0,1,0}}
api.anim.bone_peer=false
local captured_raw=api.pack(state)
local captured_expected=api.unpack(captured_raw)
api.anim.bone_peer=true
local captured_sparse=api.pack(state)
local captured_new=api.unpack(captured_sparse)
check(#captured_sparse<#captured_raw,'captured pose did not shrink')
for i,v in ipairs(captured_expected.q) do check(captured_new.q[i]==v,'captured pose changed') end
-- Header caching is acknowledged first and includes the full area/appearance identity.
api.anim.header_peer=true
check(api.pack(state)==captured_sparse,'cached header used before acknowledgement')
for id,bytes in pairs(api.anim.header_local) do
    api.anim.event('shdef',id..':'..api.anim.hex(bytes));api.anim.event('shack',tostring(id))
end
local cached=api.pack(state)
local restored=api.unpack(cached)
for _,key in ipairs({'sk','kind','mm','mp','area','seq','t'}) do check(restored[key]==state[key],'header field changed: '..key) end
check(#cached==#captured_sparse-#state.kind-#state.area,'header saving mismatch')
for cut=0,#cached-1 do check(not pcall(api.unpack,cached:sub(1,cut)),'truncated cached/sparse state accepted') end
local headers=api.anim.header_remote;api.anim.header_remote={}
local repairs={};api.anim.emit=function(s) repairs[#repairs+1]=s end
check(not pcall(api.unpack,cached),'unknown header accepted')
check(#repairs==1 and repairs[1]:match('^shreq:'),'header repair missing')
pcall(api.unpack,cached);check(#repairs==1,'header repair not throttled')
api.anim.emit=nil;api.anim.header_remote=headers
local records={};for i=1,12 do records[i]=string.rep(string.char(64+i),150) end
check(#api.anim.batch(records,false)==12,'unnegotiated enemy batching')
local batches=api.anim.batch(records,true)
check(#batches==2,'enemy batching did not reduce datagrams')
local index=0
for _,batch in ipairs(batches) do
    check(#batch<=1150,'batch exceeded limit')
    for _,record in ipairs(api.anim.unbatch(batch)) do index=index+1;check(record==records[index],'batch record changed') end
    for cut=0,#batch-1 do check(not pcall(api.anim.unbatch,batch:sub(1,cut)),'truncated enemy batch accepted') end
end
local large=string.rep('Q',2000)
check(api.anim.batch({large},true)[1]==large,'oversize enemy packet modified')
check(api.anim.batch({records[1]},true)[1]==records[1],'single enemy packet expanded')
check(not pcall(api.anim.unbatch,'\0B1\2\3\0\0B1\1\0X'),'nested enemy batch accepted')
api.anim.compact_peer=false
local actual_batch=api.anim.batch({enemy_packet(20,1,true,'enemy-a'),enemy_packet(20,2,true,'enemy-b')},true)
enemy_api.recv(actual_batch[1])
check(enemy_api.states['enemy-a'] and enemy_api.states['enemy-b'],'enemy batch receive integration')
local sparse_enemy=string.pack('<s1s1I4fffhhhhi4BB','sparse-enemy','em0000',4321,0,0,0,0,0,0,32767,90,0,16)
    ..string.pack('<H',1)..'\0'
enemy_api.recv(sparse_enemy)
check(enemy_api.states['sparse-enemy'] and enemy_api.states['sparse-enemy'].q[4]==1,'enemy sparse receive integration')
local native_state={seq=12,t=99.5,sk=4321,kind=state.kind,mm=100,mp=1,area=state.area,pos={1,2,3},rot={0,0,0,1},q={},lp={},an=a}
api.anim.compact_peer=true
local smaller_native=api.pack(native_state)
check(api.unpack(smaller_native).an.id==a.id,'cached header/native integration')
check(#smaller_native==#compact-#state.kind-#state.area,'cached native size mismatch')
local function benchmark(optimized)
    api.anim.bone_peer,api.anim.header_peer=optimized,optimized
    local start=os.clock()
    for _=1,200 do api.unpack(api.pack(state)) end
    return (os.clock()-start)*1000/200
end
local legacy_ms,optimized_ms=benchmark(false),benchmark(true)
-- Dynamic motion banks (first-person banks) ride in an optional fifth descriptor field.
local fps='Animation/ch/ch02/ch0200/motbank/ch0200FPS.motbank'
local dyn_text=fps..',1,1,0,0,0,0;;Animation/ch/ch02/ch0200/motbank/ch0200L2FPS.motbank,-2,0,7,900,4294967295,3'
local dyn=api.anim.parse_dynamic(dyn_text)
check(#dyn==3 and dyn[2]==false and dyn[1].path==fps and dyn[1].priority==1 and dyn[1].order==1,'dynamic bank parse')
check(dyn[3].priority==-2 and dyn[3].flags==7 and dyn[3].bank==900 and dyn[3].type==4294967295 and dyn[3].mask==3,'dynamic bank fields')
check(api.anim.parse_dynamic(nil)==nil,'missing dynamic field')
for _,bad in ipairs({fps..',1,1,8,0,0,0', fps..',1,1,0,0,0', 'Character/x.motbank,0,0,0,0,0,0', 'Animation/../x.motbank,0,0,0,0,0,0',
    fps..',1,1,0,4294967296,0,0', fps..',99999999999,1,0,0,0,0', string.rep(';',8), fps..',1,1,0,0,0,0,extra'}) do
    check(api.anim.parse_dynamic(bad)==false,'invalid dynamic bank accepted: '..bad)
end
local base_desc='0|9|Animation/ch/ch02/ch0200/motbank/ch0200.motbank|Character/ch/ch02/ch02.refskel'
for _,case in ipairs({{base_desc,true,0},{base_desc..'|'..dyn_text,true,3},{base_desc..'|'..fps..',1,1,9,0,0,0',false},{base_desc..'|',false}}) do
    local id=api.fnv32(case[1]); api.anim.remote[id]=nil
    api.anim.event('anres',id..':'..case[1])
    local r=api.anim.remote[id]
    check((r~=nil)==case[2],'descriptor acceptance '..case[1])
    if r then check(#(r.dyn or {})==case[3],'descriptor dynamic count') end
end
api.anim.header_peer,api.anim.bone_peer,api.anim.batch_peer=true,true,true
api.anim.tick()
check(not api.anim.header_peer and not api.anim.bone_peer and not api.anim.batch_peer,'peer change did not reset capabilities')
return {passed=checked,native_bytes=#native,legacy_84_joint_bytes=#full_bones,
    compact_bytes=#compact,cached_native_bytes=#smaller_native,captured_bone_bytes=#captured_raw,
    sparse_bone_bytes=#captured_sparse,cached_sparse_bone_bytes=#cached,
    enemy_datagrams_before=12,enemy_datagrams_after=#batches,
    legacy_codec_ms=legacy_ms,optimized_codec_ms=optimized_ms,
    reduction_percent=100*(1-#smaller_native/#full_bones),layer_bytes=#packed}
