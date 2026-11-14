-- State v2 header: exact equivalence with v1 decoding, size, fallback and fuzzing.
-- Pure codec test on the real source; no engine state is touched.
local source=assert(protocol_source):gsub('\r\n','\n')
local function between(a,b)local i=assert(source:find(a,1,true));local j=assert(source:find(b,i+#a,true));return source:sub(i,j-1)end
local prefix="local cfg={native_animation=true,mirror_test=false};local link={mode='test'};local now=os.clock\n"..
 between('local function fnv32(','-- quaternion components')..between('local function q16(','-- quaternion product')..
 between('local anim = ','---------------------------------------------------------------------------\n-- local state capture')
local api=assert(load(prefix..between('local STATE_HEAD = ','-- joint names travel once')..
 '\nreturn {pack=pack_state,unpack=unpack_state,anim=anim}','state-v2'))()
local A=api.anim
local passed,mutations,rejected=0,0,0
local function check(ok,why)passed=passed+1;assert(ok,why)end
local seed=0x51A7E2
local function rand(n)seed=(seed*1664525+1013904223)&0xFFFFFFFF;return seed%n end
local function same(a,b,path)
 if type(a)~='table' then check(a==b or (a~=a and b~=b),'v1/v2 differ at '..path..': '..tostring(a)..' vs '..tostring(b));return end
 check(type(b)=='table','v1/v2 shape differs at '..path)
 for k,v in pairs(a)do same(v,b[k],path..'.'..tostring(k))end
 for k in pairs(b)do check(a[k]~=nil,'v2 has extra field '..path..'.'..tostring(k))end
end
local function sync_defs()
 for id,bytes in pairs(A.header_local)do if not A.header_ready[id] then A.event('shdef',id..':'..A.hex(bytes));A.event('shack',tostring(id))end end
 for id,bytes in pairs(A.layout_local)do if not A.layout_ready[id] then A.event('aldef',id..':'..A.hex(bytes));A.event('alack',tostring(id))end end
end
A.peer_version=1
local sizes={v1=0,v2=0,n=0,yaw=0}
local native_cached={}
for case=1,600 do
 local native=case%3==0
 local yaw=case%2==0
 local h=rand(62832)/10000
 local st={seq=case*7,t=(123456+case*33)/1000,sk=4321,kind='cp_A100',mm=200,mp=4,area='Chap'..(case%5+1)..'_01',
  pos={rand(100000)/64-700,rand(1000)/64,rand(100000)/64-700},q={},lp={}}
 st.rot=yaw and {0,math.sin(h/2),0,math.cos(h/2)} or {0.05,math.sin(h/2),0.03,math.cos(h/2)}
 if case%2==0 then st.lp.root={0,rand(100)/100,0}end;if case%5==0 then st.lp.Hip={0,0.75,rand(10)/100}end
 if native then
  st.an={id=99,layers={{slot=0,bank=100,motion=case%9,bank_type=-1,mask=0,mask_mode=0,blend_mode=0,namespace=0,base=0,wrap=2,frame=case/3,speed=1,weight=1,ending=600},
   {slot=2,bank=100,motion=40,bank_type=-1,mask=3,mask_mode=1,blend_mode=0,namespace=0,base=0,wrap=0,frame=1.5,speed=1,weight=case%4==0 and .5 or 1,ending=90}}}
 else for _=1,rand(80)+1 do local x,y,z=rand(2000)/2000-.5,rand(2000)/2000-.5,0;local l=math.sqrt(x*x+y*y+z*z+1);for _,v in ipairs({x/l,y/l,z/l,1/l})do st.q[#st.q+1]=v end end end
 A.header_peer=case%4~=1;A.bone_peer=true;A.compact_peer=true
 A.state2_peer=false;api.pack(st);sync_defs()
 local v1=api.pack(st)
 A.state2_peer=true
 local v2=api.pack(st)
 check(string.unpack('<I4',v2)&0x80000000~=0,'v2 marker missing')
 check(string.unpack('<I4',v1)&0x80000000==0,'v1 carries v2 marker')
 local d1,d2=api.unpack(v1),api.unpack(v2)
 same(d1,d2,'state')
 check(d2.t==st.t,'v2 time not exact')
 sizes.v1,sizes.v2,sizes.n=sizes.v1+#v1,sizes.v2+#v2,sizes.n+1
 if yaw then sizes.yaw=sizes.yaw+1 end
 if native and A.header_peer and yaw and #st.an.layers==2 and not st.lp.Hip then native_cached[#native_cached+1]={#v1,#v2} end
 check(not pcall(api.unpack,v2..'x'),'trailing v2 accepted')
 if case%17==0 then for cut=0,#v2-1 do check(not pcall(api.unpack,v2:sub(1,cut)),'v2 truncation accepted')end end
 for _=1,6 do
  local at=rand(#v2)+1;local m=v2:sub(1,at-1)..string.char(rand(256))..v2:sub(at+1)
  local ok,d=pcall(api.unpack,m);mutations=mutations+1
  if not ok then rejected=rejected+1 else check(A.valid_transform(d.pos,d.rot) and A.finite(d.t,1e10) and #d.q<=4096,'v2 mutation escaped validation')end
 end
end
-- Fallbacks: non-millisecond time or an old peer keep the v1 format exactly.
A.state2_peer=true
local odd={seq=5,t=1/3,sk=1,kind='cp_A100',mm=200,mp=4,area='Chap1_01',pos={1,2,3},rot={0,0,0,1},q={0,0,0,1},lp={}}
local fb=api.pack(odd);check(string.unpack('<I4',fb)&0x80000000==0,'non-ms time did not fall back to v1')
check(api.unpack(fb).t==odd.t,'fallback time changed')
A.state2_peer=false;A.peer='x';local old=api.pack({seq=6,t=2,sk=1,kind='cp_A100',mm=200,mp=4,area='a',pos={1,2,3},rot={0,0,0,1},q={0,0,0,1},lp={}})
check(string.unpack('<I4',old)&0x80000000==0,'old peer received v2')
-- Reserved v2 flag bits are rejected.
A.state2_peer=true
local base=api.pack({seq=7,t=3,sk=1,kind='cp_A100',mm=200,mp=4,area='a',pos={1,2,3},rot={0,0,0,1},q={0,0,0,1},lp={}})
for _,fl in ipairs({64,128})do local m=base:sub(1,12)..string.char(base:byte(13)|fl)..base:sub(14);check(not pcall(api.unpack,m),'reserved v2 flag accepted')end
local nc=native_cached[1]
return {passed=passed,cases=sizes.n,avg_v1_bytes=sizes.v1/sizes.n,avg_v2_bytes=sizes.v2/sizes.n,
 cached_native_v1=nc and nc[1],cached_native_v2=nc and nc[2],mutations=mutations,rejected=rejected}
