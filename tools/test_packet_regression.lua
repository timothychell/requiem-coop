-- Deterministic fixtures/fuzzing of actual source codecs; no engine mutations.
local source=assert(protocol_source):gsub('\r\n','\n')
local function between(a,b)local i=assert(source:find(a,1,true));local j=assert(source:find(b,i+#a,true));return source:sub(i,j-1)end
local prefix="local cfg={native_animation=true,mirror_test=false};local link={mode='test'};local now=os.clock\n"..
 between('local function fnv32(','-- quaternion components')..between('local function q16(','-- quaternion product')..
 between('local anim = ','---------------------------------------------------------------------------\n-- local state capture')
local state_code=between('local STATE_HEAD = ','-- joint names travel once')
local api=assert(load(prefix..state_code..'\nreturn {pack=pack_state,unpack=unpack_state,anim=anim}','regression-codecs'))()
local enemy_head=assert(source:match('local ENEMY_HEAD = [^\n]+'))..'\n'
local enemy=assert(load(prefix..'local en={remote={},remote_names={},names_asked={}};local bridge_event=function()end\n'..enemy_head..
 between('local function dist3(','local function refresh_enemy_list')..between('local function enemy_recv(b)','local function enemy_event')..
 '\nreturn {recv=enemy_recv,states=en.remote}','regression-enemy'))()
local passed,mutations,rejected=0,0,0
local function check(ok,why)passed=passed+1;assert(ok,why)end
local seed=0x3C190A21
local function rand(n)seed=(seed*1664525+1013904223)&0xFFFFFFFF;return seed%n end
local function f32(x)return (string.unpack('<f',string.pack('<f',x)))end
local function replace(s,at,bytes)return s:sub(1,at-1)..bytes..s:sub(at+#bytes)end
local function bad(bytes,why)check(not pcall(api.unpack,bytes),why)end
api.anim.peer_version=1
for case=1,500 do
 local native=case%4==0
 local st={seq=case,t=case/30,sk=4321,kind='cp_A100',mm=200,mp=4,area='Chap'..(case%7+1)..'_01',
  pos={rand(10000)/64,rand(10000)/64,rand(10000)/64},rot={0,0,0,1},q={},lp={}}
 if case%2==0 then st.lp.root={0,1,0}end;if case%3==0 then st.lp.Hip={0,0.75,0}end
 if native then
  st.an={id=123,layers={{slot=0,bank=100,motion=case%20,bank_type=-1,mask=0,mask_mode=0,blend_mode=0,
    namespace=0,base=0,wrap=2,frame=case/3,speed=case%2==0 and 1 or .5,weight=1,ending=600}}}
 else
  for _=1,rand(128)+1 do
   local x=rand(32768)/32767;local y=rand(32768)/32767;local z=rand(32768)/32767;local w=1
   if case%2==0 then x,y,z=0,0,0 end
   local length=math.sqrt(x*x+y*y+z*z+w*w)
   for _,v in ipairs({x/length,y/length,z/length,w/length})do st.q[#st.q+1]=v end
  end
 end
 api.anim.header_peer=case%2==0;api.anim.bone_peer=case%3~=0;api.anim.compact_peer=case%2==0
 local raw=api.pack(st)
 -- Simulate reliable definitions arriving, independently of unreliable poses.
 for id,bytes in pairs(api.anim.header_local)do if not api.anim.header_ready[id] then api.anim.event('shdef',id..':'..api.anim.hex(bytes));api.anim.event('shack',tostring(id))end end
 for id,bytes in pairs(api.anim.layout_local)do if not api.anim.layout_ready[id] then api.anim.event('aldef',id..':'..api.anim.hex(bytes));api.anim.event('alack',tostring(id))end end
 local bytes=api.pack(st);local decoded=api.unpack(bytes)
 check(decoded.seq==st.seq and decoded.kind==st.kind and decoded.area==st.area,'random header round trip')
 for i=1,3 do check(decoded.pos[i]==f32(st.pos[i]),'position precision')end
 check(#decoded.q==#st.q,'random pose length')
 for i,v in ipairs(st.q)do check(decoded.q[i]==math.floor(v*32767+.5)/32767,'quaternion precision')end
 if native then check(decoded.an.layers[1].frame==f32(st.an.layers[1].frame),'native frame precision')end
 bad(bytes..'extra','trailing state accepted')
 if case%11==0 then for cut=0,#bytes-1 do bad(bytes:sub(1,cut),'random truncation accepted')end end
 for _=1,4 do
  local at=rand(#bytes)+1;local mutated=replace(bytes,at,string.char(rand(256)))
  local ok,d=pcall(api.unpack,mutated);mutations=mutations+1
  if not ok then rejected=rejected+1 else
   check(api.anim.valid_transform(d.pos,d.rot) and api.anim.finite(d.t,1e10) and #d.q<=4096,'mutation escaped validation')
  end
 end
end
api.anim.header_peer=false;api.anim.bone_peer=false;api.anim.compact_peer=false
local fixture={seq=1,t=1,sk=1,kind='cp_A100',mm=200,mp=4,area='Chap1_01',pos={1,2,3},rot={0,0,0,1},q={0,0,0,1},lp={}}
local bytes=api.pack(fixture)
local head={string.unpack('<I4dI4s1i2i2s1fffhhhhB',bytes)};local at=head[#head]
for _,flag in ipairs({8,64,128,255})do bad(replace(bytes,at-1,string.char(flag)),'reserved player flags accepted')end
bad(replace(bytes,5,string.pack('<d',0/0)),'NaN time accepted')
bad(replace(bytes,5,string.pack('<d',math.huge)),'infinite time accepted')
bad(replace(bytes,at-21,string.pack('<f',0/0)),'NaN position accepted')
bad(replace(bytes,at-21,string.pack('<f',math.huge)),'infinite position accepted')
bad(replace(bytes,at-9,string.rep('\0',8)),'zero root quaternion accepted')
bad(replace(bytes,#bytes-7,string.rep('\0',8)),'zero bone quaternion accepted')
local e=string.pack('<s1s1I4fffhhhhi4BBHhhhh','enemy','em0000',1,0,0,0,0,0,0,32767,100,0,0,1,0,0,0,32767)
enemy.recv(e);check(enemy.states.enemy~=nil,'enemy fixture rejected')
local old=enemy.states.enemy
for _,bad_packet in ipairs({e..'x',replace(e,1,'\0'),replace(e,#e-7,string.rep('\0',8))})do
 pcall(enemy.recv,bad_packet);check(enemy.states.enemy==old,'malformed enemy changed state')
end
for cut=0,#e-1 do pcall(enemy.recv,e:sub(1,cut));check(enemy.states.enemy==old,'truncated enemy changed state')end
local equip=assert(load(prefix..'local wep={}\n'..between('function wep.decode(text)','local function parse_weapons')..'\nreturn wep','equipment-regression'))()
local w={name='cp_A1_Bag_Exclusive',joint='root',mesh='Character/wp/wp35/3542/00/wp3542_00.mesh',mat='Character/wp/wp35/3542/00/wp3542_00.mdf2',
 lp={0,0,0},lr={0,0,0,1},scale={1,1,1},skin=true,bits='ff',bit_count=8,
 motion={path='Animation/wp/wp35/wp3542/motbank/wp3542.motbank',target=-1,bank=0,id=0,kind=-1,wrap=0,speed=1}}
local function packet(items)return json.dump_string({version=1,items=items})end
check(#equip.decode(packet({w}))==1,'skinned backpack recipe rejected')
check(#equip.decode(packet({}))==0,'equipment off rejected')
check(not pcall(equip.decode,packet({w,w})),'duplicate equipment names accepted')
local saved=w.mesh;w.mesh='Character/../../game.mesh';check(not pcall(equip.decode,packet({w})),'equipment traversal accepted');w.mesh=saved
w.lr={0,0,0,0};check(not pcall(equip.decode,packet({w})),'equipment zero quaternion accepted');w.lr={0,0,0,1}
w.scale={1,-1,1};check(not pcall(equip.decode,packet({w})),'negative scale accepted');w.scale={1,1,1}
w.bit_count=9;check(not pcall(equip.decode,packet({w})),'short equipment mask accepted');w.bit_count=8
w.motion.path='Character/not-animation.mesh';check(not pcall(equip.decode,packet({w})),'invalid accessory animation accepted')
return {passed=passed,valid_random_states=500,byte_mutations=mutations,rejected_mutations=rejected,engine_mutations=false}
