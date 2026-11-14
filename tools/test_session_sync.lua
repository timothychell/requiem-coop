-- Read-only two-endpoint simulation; never starts a real cinematic or changes
-- a real mission. Run through the bridge with session_source set (see
-- tools/Run-Tests.ps1), or with stock Lua 5.4 from the repository root.
local M=assert(session_source and load(session_source,'requiem_coop_session')
    or loadfile('mod/reframework/autorun/require/requiem_coop_session.lua'))()
local passed=0
local function check(ok,message)passed=passed+1;assert(ok,message)end
local function copy(v)if type(v)~='table' then return v end;local t={};for k,x in pairs(v)do t[k]=copy(x)end;return t end
local function pair(opts)
    opts=opts or {}
    local clock=0;local wire={};local endpoints={};local actors={}
    for _,role in ipairs({'host','client'})do
        local actor={playing=false,id=nil,skips=0,plays=0,can_skip=true,rpcs={},chapter='Chap2',flow=0,online=true}
        actors[role]=actor
        local E={epoch=role..'-epoch',now=function()return clock end,connected=function()return actor.online end,
            tracks=opts[role..'_tracks'],
            role=function()return role end,peer=function()return role..'-peer'end,
            send=function(k,d)wire[#wire+1]={from=role,k=k,d=copy(d)}end,
            area=function()if opts.no_area then return nil end;return 'Chap2_10'end,where=function()if opts.no_area then return nil end;return{0,0,0,0,0,0,1}end,
            playing=function()return actor.playing end,current_id=function()return actor.id end,
            can_skip=function()return actor.can_skip end,warp=function()return true end,
            play=function(id,flow,args)
                if endpoints[role].begin(id,flow,args) then return true end
                actor.plays=actor.plays+1;actor.args=args
                if actor.delay then actor.start_at=clock+actor.delay;actor.loading_id=id;return true end
                actor.id=id;actor.playing=true;return true
            end,
            skip=function()actor.skips=actor.skips+1;actor.playing=false;return true end,
            apply_rpc=function(i,args)if actor.reject_rpc then return false end;actor.rpcs[#actor.rpcs+1]={i,args};actor.flow=actor.flow+1;return true end,
            progress=function()return{{123,actor.flow}},actor.chapter end,
            progress_signature=function(v,c)return c..':'..v[1][2]end,
            apply_progress=function(d)
                if d.chapter~=actor.chapter then return 0,#d.values end
                actor.flow=d.values[1][2];return 1,0
            end}
        endpoints[role]=M.new(E)
    end
    local function flush()
        local n=0
        while #wire>0 do n=n+1;assert(n<1000,'message loop');local msg=table.remove(wire,1)
            endpoints[msg.from=='host' and 'client' or 'host'].handle(msg.k,msg.d)
        end
    end
    local function tick(dt)
        clock=clock+(dt or 0.1)
        for _,ac in pairs(actors) do if ac.start_at and clock>=ac.start_at then ac.start_at=nil;ac.playing=true;ac.id=ac.loading_id end end
        endpoints.host.tick();endpoints.client.tick();flush()
    end
    tick();tick()
    check(endpoints.host.cap and endpoints.client.cap,'capability handshake')
    return endpoints.host,endpoints.client,actors,tick,flush,wire,function()return clock end
end
do
    local h,c,a,tick,flush=pair()
    h.begin(101,2,{auto=true});a.host.id=101;a.host.playing=true;flush()
    for _=1,20 do tick();if a.client.playing then break end end   -- includes the post-warp grace
    check(a.client.playing and a.client.id==101,'host start did not play on client')
    check(c.hide_puppet(),'cinematic puppet not hidden')
    check(h.request_skip(),'host skip was not held')
    flush();tick()
    check(a.host.skips==0 and a.client.skips==0,'one vote skipped the scene')
    check(c.request_skip(),'client skip was not held')
    flush();tick();tick()
    check(a.host.skips==1 and a.client.skips==1,'host commit did not skip both')
    for _=1,20 do tick()end
    check(a.host.skips==1 and a.client.skips==1,'commit replay skipped twice')
    check(not c.hide_puppet(),'puppet remained hidden after finish')
end
do
    local h,c,a,tick,flush=pair()
    h.begin(102,0);a.host.id=102;a.host.playing=true;flush()
    h.request_skip();c.request_skip();flush();tick()
    check(a.host.skips==0,'host skipped before client readiness')
    for _=1,30 do tick();if a.host.skips==1 and a.client.skips==1 then break end end
    check(a.host.skips==1 and a.client.skips==1,'early votes were lost')
end
do
    local h,c,a,tick,flush=pair()
    h.begin(103,0);a.host.id=103;a.host.playing=true;flush()
    for _=1,20 do tick();if a.client.playing then break end end
    check(a.client.playing,'client never started the host scene')
    a.host.playing=false;tick();tick()
    check(not a.client.playing and a.client.skips==1,'host natural end left client watching')
    local old=c.last_host_seq
    c.handle('cin3',{epoch=h.epoch,seq=old-1,token='old',id=999,flow=0,area='Chap2_10',phase='play'})
    check(c.cin.id==103,'stale cinematic state accepted')
end
do
    local h,c,a,tick,flush=pair()
    check(c.begin(104,7,{auto=true,end_callback='local-callback'}),'autonomous client scene was not deferred')
    flush()
    for _=1,6 do tick()end
    check(a.host.id==104 and a.client.id==104,'client request did not go through host')
    check(a.client.args and a.client.args.end_callback=='local-callback','deferred callback lost')
end
do
    local h,c,a,tick,flush,wire=pair()
    h.mirror_call(1,{'5','10'});h.mirror_call(2,{'5','11'})
    wire[1],wire[2]=wire[2],wire[1]
    flush();tick()
    check(#a.client.rpcs==2,'ordered mission journal failed')
    check(a.client.rpcs[1][1]==1 and a.client.rpcs[2][1]==2,'mission events applied out of order')
    c.mirror_call(3,{'5'})
    wire[#wire+1]=copy(wire[#wire])
    flush();tick()
    check(#a.host.rpcs==1,'duplicate client mission request applied twice')
end
do
    local h,c,a,tick,flush=pair()
    a.host.flow=42
    for _=1,25 do tick()end
    check(a.client.flow==42,'periodic mission reconciliation failed')
    local old=c.last_progress_seq
    c.handle('flow3',{epoch=h.epoch,seq=old-1,chapter='Chap2',values={{123,0}},rpc_seq=0})
    tick();check(a.client.flow==42,'old mission snapshot accepted')
end
do
    local h,c,a,tick,flush,wire=pair()
    h.mirror_call(1,{'5','10'})
    for i=#wire,1,-1 do if wire[i].k=='rpc3' then table.remove(wire,i) end end
    for _=1,30 do tick()end
    check(#a.client.rpcs==1,'heartbeat did not repair a missing final mission event')
end
do
    local h,c,a,tick,flush=pair()
    h.begin(106,0);a.host.playing=true;a.host.id=106;flush()
    a.client.playing=true;a.client.id=999
    for _=1,10 do tick()end
    check(not h.cin.peer_ready,'unrelated client scene acknowledged the host scene')
end
do
    local h,c,a,tick,flush=pair()
    a.host.reject_rpc=true;c.mirror_call(2,{'5','10'});flush();tick()
    check(#a.host.rpcs==0,'unready host applied request')
    a.host.reject_rpc=false;tick();tick()
    check(#a.host.rpcs==1 and #a.client.rpcs==1,'temporarily unready host lost requested mission event')
end
do
    local h,c,a,tick,flush=pair()
    c.handle('rpc3',{epoch=h.epoch,seq=1,index=0,args={'5'}})
    check(next(c.rpc_pending)==nil,'invalid RPC index occupied the ordered queue')
    c.handle('flow3',{epoch=h.epoch,seq=999,chapter='Chap2',values={{123,5}},rpc_seq=0/0})
    check(c.last_progress_seq~=999,'NaN journal barrier accepted')
    h.mirror_call(1,{'5','10'});flush();tick()
    check(#a.client.rpcs==1,'valid event blocked after malformed event')
end
do
    local h,c,a,tick,flush=pair()
    h.begin(105,0);a.host.playing=true;a.host.id=105;flush()
    for _=1,4 do tick()end
    a.client.can_skip=false
    for _=1,6 do tick()end
    h.request_skip();c.request_skip();flush();tick()
    check(a.host.skips==0,'commit ignored peer non-skippable state')
    a.client.can_skip=true
    for _=1,10 do tick()end
    check(a.host.skips==1 and a.client.skips==1,'skippable transition did not release votes')
end
do
    -- Real session: reading the host's timelines threw ("get_size is not callable"), the cin3
    -- start was never sent and the client sat on a black screen.
    local h,c,a,tick,flush=pair({host_tracks=function() error("method 'get_size' is not callable (a nil value)") end})
    check(c.begin(107,0,{auto=false,end_callback='cb'}),'client scene was not deferred')
    flush()
    for _=1,6 do tick()end
    check(a.host.id==107 and a.client.playing and a.client.id==107,'host track error blocked the client cutscene')
end
do
    -- Host never answers the request: the client plays the held scene itself, with its callbacks.
    local h,c,a,tick,flush,wire=pair()
    check(c.begin(108,3,{auto=false,end_callback='cb108'}),'client scene was not deferred')
    for i=#wire,1,-1 do if wire[i].k=='cinreq3' then table.remove(wire,i) end end
    for _=1,50 do tick()end
    check(not a.client.playing,'client released the held scene too early')
    for _=1,60 do tick()end
    check(a.client.playing and a.client.id==108 and a.client.args.end_callback=='cb108','held scene never played locally')
    -- the host reaches the same scene late: the client must not play it again
    a.client.playing=false
    h.begin(108,3);a.host.id=108;a.host.playing=true;flush()
    for _=1,6 do tick()end
    check(a.client.plays==1,'late host start replayed the scene on the client')
end
do
    -- Connection lost while a scene is held: play it immediately.
    local h,c,a,tick,flush,wire=pair()
    check(c.begin(109,0,{}),'client scene was not deferred')
    for i=#wire,1,-1 do if wire[i].k=='cinreq3' then table.remove(wire,i) end end
    a.client.online=false;tick()
    check(a.client.playing and a.client.id==109,'held scene not released after disconnect')
end
do
    -- Real session: a New Game's opening cinematic runs before any player exists, so area() is nil.
    -- The client rejected every host cin3 (no area string): it never saw the host's scene, played
    -- its own after the fallback, and the two skip votes never matched.
    local h,c,a,tick,flush=pair({no_area=true})
    h.begin(110000,0);a.host.id=110000;a.host.playing=true;flush()
    for _=1,4 do tick()end
    check(c.cin.token==h.cin.token,'client ignored host cinematic without an area')
    check(a.client.playing and a.client.id==110000,'area-less host cinematic did not play on client')
    for _=1,4 do tick()end
    check(h.cin.peer_ready,'client never acknowledged the area-less cinematic')
    h.request_skip();c.request_skip();flush()
    for _=1,6 do tick()end
    check(a.host.skips==1 and a.client.skips==1,'skip votes did not commit without an area')
end
do
    -- Real session: the host was halfway through 111000 when the partner's game reached the trigger.
    -- The partner must play it natively at once, not hold it waiting for the host.
    local h,c,a,tick,flush=pair()
    h.begin(111000,0);a.host.id=111000;a.host.playing=true;flush()
    a.client.delay=3   -- keep the client from being started by the host before its own trigger
    tick()
    check(not c.begin(111000,0,{end_callback='native-cb'}),'client held a scene the host is already playing')
    check(c.pending==nil and c.queue.play==nil,'client kept a request for a scene the host is playing')
end
do
    -- Loading takes seconds: the client must request the host's scene once, not every packet.
    local h,c,a,tick,flush=pair()
    a.client.delay=4
    h.begin(111001,0);a.host.id=111001;a.host.playing=true;flush()
    for _=1,80 do tick()end
    check(a.client.plays==1,'client re-requested a loading cutscene ('..a.client.plays..' requests)')
    check(a.client.playing and a.client.id==111001,'loading cutscene never started on client')
    for _=1,6 do tick()end
    check(h.cin.peer_ready,'client did not acknowledge after loading')
end
local t=0
local torch=M.torch({now=function()return t end,peer_stream=function()return 123 end})
local records={{kind=1,p={0.1,0.2,0.3},q={0,0,0,1},radius=20,cone=45,falloff=0.5,intensity=1000,color={1,0.9,0.8}},
    {kind=2,p={0,0,0},q={0,0,0,1},radius=3,cone=0,falloff=0,intensity=5,color={1,1,1}}}
local bytes=torch.pack(7,records,123)
local seq,decoded,stream=torch.unpack(bytes)
check(seq==7 and stream==123 and #decoded==2,'torch round trip')
check(decoded[1].radius==20 and decoded[1].intensity==1000,'torch light parameters changed')
torch.receive(bytes);check(torch.remote_seq==7,'torch receive')
torch.receive(torch.pack(6,{},123));check(#torch.remote==2,'stale torch packet accepted')
torch.receive(torch.pack(8,{},124));check(#torch.remote==2,'wrong torch stream accepted')
torch.off(8);check(#torch.remote==0,'reliable torch off ignored')
for i=0,#bytes-1 do check(not pcall(torch.unpack,bytes:sub(1,i)),'truncated torch packet accepted')end
check(not pcall(torch.unpack,bytes..'x'),'trailing torch payload accepted')
local invalid=copy(records);invalid[1].q={0,0,0,0}
check(not pcall(torch.unpack,torch.pack(9,invalid,123)),'zero torch quaternion accepted')
return {passed=passed,torch_two_lights_bytes=#bytes}
