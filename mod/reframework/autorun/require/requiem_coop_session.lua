-- Host-authoritative session events. Engine adapters are separate from the
-- state machine so two endpoints can be exercised without playing a cutscene.
local M = {}
local function finite(x) return type(x)=='number' and x==x and math.abs(x)<1e10 end
local function integer(x) return finite(x) and x%1==0 end

function M.new(E)
    local S={epoch=E.epoch,cap=false,peer_epoch=nil,last_hello=-100,last_seen=-100,
        serial=0,tx=0,last_host_seq=-1,queue={},cin={active=false,phase='end'},
        vote_local=false,vote_peer=false,internal_play=0,internal_skip=0,
        last_cin=-100,last_progress=-100,progress_seq=0,last_progress_seq=-1,
        rpc_tx=0,rpc_rx=0,rpc_pending={},rpc_journal={},request_tx=0,request_seen={},request_pending={},
        stats={starts=0,skips=0,repairs=0,flow_applied=0,flow_queued=0},error=''}
    local now=E.now
    local release_pending   -- defined before S.tick; used by S.handle
    local function connected() return E.connected() end
    local function host() return E.role()=='host' end
    -- No player exists during e.g. a New Game's opening cinematic, so the area is nil there. JSON drops
    -- nil fields, and the client rejected every cin3 without an area string (real session: the
    -- partner never saw the host's cutscene, and skip votes never matched). Normalise to ''.
    local function area() return E.area() or '' end
    local function valid_rpc(d)
        if not integer(d.seq) or d.seq<1 or not integer(d.index) or d.index<1 or d.index>(E.max_rpc or 64)
            or type(d.args)~='table' or #d.args>8 then return false end
        for _,v in ipairs(d.args)do if type(v)~='string' or #v>2048 then return false end end
        return true
    end
    local function send(k,d) d.epoch=S.epoch;E.send(k,d) end
    local function cinema_packet()
        S.tx=S.tx+1
        local c=S.cin
        -- Timeline positions are an optional correction. A failure reading them must never
        -- stop the start/end message itself: the client holds its cutscene until it arrives.
        local tracks
        if c.active and E.tracks then
            local ok,value=pcall(E.tracks)
            if ok then tracks=value end
        end
        return {epoch=S.epoch,seq=S.tx,token=c.token,id=c.id,flow=c.flow,area=c.area,
            where=c.where,phase=c.phase,playing=c.active,ready=c.seen or false,
            vote=S.vote_local,auto=c.auto or false,tracks=tracks,barrier=c.barrier or false}
    end
    local function publish() if host() and S.cin.token then E.send('cin3',cinema_packet());S.last_cin=now() end end
    function S.hide_puppet() return S.cin.active or S.queue.play~=nil or (E.playing and E.playing()) or false end
    -- Pause barrier. The game's own play call is NEVER blocked: holding it and playing later broke
    -- story flow in a real session (sequence skipped, input lost). Instead every PC's cutscene starts
    -- for real and is frozen ~0.1 s in ("Waiting for all players..."). When all are frozen, the host
    -- sends "go" and delays its own unfreeze by half the measured round trip, so both resume at the
    -- same moment. Watchdogs guarantee nothing stays frozen.
    local function freeze_local(id) S.freeze={id=id,since=now()} end
    local function unfreeze_local()
        local f=S.freeze;S.freeze=nil;S.release_at=nil
        if f and f.done and E.unfreeze then pcall(E.unfreeze,f.id) end
    end
    local function frozen(id) return S.freeze and S.freeze.id==id and S.freeze.done end
    local function open_barrier(id,flow,where,start_here)
        S.serial=S.serial+1
        S.cin={token=S.epoch..'-'..S.serial,id=id,flow=flow,area=area(),where=where or E.where(),
            phase='prepare',active=true,started=now(),seen=false,barrier=true,start_here=start_here}
        if not start_here then freeze_local(id) end
        S.vote_local,S.vote_peer=false,false
        S.message='Waiting for all players...'
        S.rtt=nil;S.ping_seq=0;S.last_ping=-100
        publish()
    end
    function S.begin(id,flow,pending,playing_now)
        if S.internal_play>0 then return false end
        if not connected() or not S.cap then return false end
        if host() then
            if S.cin.active and S.cin.id==id then
                if S.cin.barrier and S.cin.phase=='prepare' then return false end   -- already in the barrier
                if now()-(S.cin.started or 0)<0.2 then return false end
            end
            if S.peer_barrier and not playing_now then
                open_barrier(id,flow,nil,false)
                S.stats.starts=S.stats.starts+1
                return false
            end
            S.serial=S.serial+1
            S.cin={token=S.epoch..'-'..S.serial,id=id,flow=flow,area=area(),where=E.where(),
                phase='prepare',active=true,started=now(),seen=false,auto=pending and pending.auto or false}
            S.vote_local,S.vote_peer=false,false;S.stats.starts=S.stats.starts+1
            S.message=''
            publish();return false
        end
        if S.peer_barrier then
            -- client, barrier mode: never block the game's call either
            if S.cin.active and S.cin.id==id and not (S.cin.barrier and S.cin.phase=='prepare') then
                return false   -- the host is already playing it: join late, no freeze
            end
            freeze_local(id)
            S.message='Waiting for all players...'
            if not (S.cin.active and S.cin.barrier and S.cin.id==id) then
                -- our game got there first: ask the host to open the barrier
                S.req={id=id,flow=flow,fallback_at=now()+(E.barrier_timeout or 20)+5}
                send('cinreq3',{id=id,flow=flow,area=area(),where=E.where(),auto=pending and pending.auto or false})
            end
            return false
        end
        if S.cin.active and S.cin.id==id then
            -- The host is already in this scene (real session: halfway through when the partner's game
            -- reached the trigger). Play it natively now, with the game's own callbacks; the host's
            -- timeline positions then move it to the same point.
            S.queue.play=nil;S.pending=nil;S.message=''
            return false
        end
        S.pending={id=id,flow=flow,args=pending,until_time=now()+30,fallback_at=now()+(E.fallback_seconds or 10)}
        S.message='Waiting for all players...'
        send('cinreq3',{id=id,flow=flow,area=area(),where=E.where(),auto=pending and pending.auto or false})
        return true
    end
    function S.started(id)
        S.native_active=S.native_active or {};S.native_active[id]=true
        if host() and S.cin.id==id and S.cin.active then S.cin.seen=true;S.cin.phase='play';publish() end
    end
    function S.finished(id)
        if S.native_active then S.native_active[id]=nil end
        if host() and S.cin.id==id and S.cin.active then S.cin.active=false;S.cin.phase='end';publish() end
    end
    function S.request_skip()
        if S.internal_skip>0 or not connected() or not S.cap then return false end
        if not S.cin.active and not (E.playing and E.playing()) then return false end
        S.vote_local=true
        if S.cin.token and now()-(S.last_vote or -100)>0.5 then
            S.last_vote=now()
            if host() then publish() else send('cinvote3',{token=S.cin.token,id=S.cin.id}) end
        end
        S.message='Waiting for both players to skip'
        -- Always block local execution; a host commit releases both endpoints.
        -- No dependency on whether the peer's play acknowledgement arrived yet.
        return true
    end
    function S.mirror_call(index,args)
        if not connected() or not S.cap then return nil end
        if host() then
            S.rpc_tx=S.rpc_tx+1
            local d={seq=S.rpc_tx,index=index,args=args}
            S.rpc_journal[S.rpc_tx]=d;S.rpc_journal[S.rpc_tx-1024]=nil
            send('rpc3',d)
            return false
        end
        S.request_tx=S.request_tx+1
        send('rpcreq3',{seq=S.request_tx,index=index,args=args})
        return true
    end
    local function skip_local()
        if not E.playing() then return false end
        unfreeze_local()   -- skip a running scene, never a frozen one
        S.internal_skip=S.internal_skip+1
        local ok,value=pcall(E.skip)
        S.internal_skip=S.internal_skip-1
        if ok and value~=false then S.stats.skips=S.stats.skips+1;return true end
        if not ok then S.error=tostring(value) end
        return false
    end
    function S.handle(k,d)
        if type(d)~='table' then return end
        S.last_seen=now()
        if k=='session3' then
            if d.version~=3 or type(d.epoch)~='string' then return end
            if S.peer_epoch~=d.epoch then
                S.last_host_seq=-1;S.last_progress_seq=-1;S.request_seen={};S.request_pending={};S.rpc_pending={}
                S.rpc_rx=integer(d.rpc_seq) and d.rpc_seq or 0
            elseif not host() and integer(d.rpc_seq) and d.rpc_seq>S.rpc_rx
                and now()-(S.last_rpc_repair or -100)>0.5 then
                -- Detect a missing final event even if no later event arrives.
                S.last_rpc_repair=now();send('rpcrepair3',{after=S.rpc_rx})
            end
            S.cap,S.peer_epoch=true,d.epoch
            -- pause barrier when both ends support it (E.barrier=false switches it off locally)
            S.peer_barrier=E.barrier~=false and d.barrier==1
            return
        end
        if not connected() or not S.cap or d.epoch~=S.peer_epoch then return end
        if k=='rpc3' and not host() then
            if not valid_rpc(d) or d.seq<=S.rpc_rx or d.seq>S.rpc_rx+1024 then return end
            S.rpc_pending[d.seq]=d
            if d.seq>S.rpc_rx+1 and now()-(S.last_rpc_repair or -100)>0.5 then
                S.last_rpc_repair=now();send('rpcrepair3',{after=S.rpc_rx})
            end
        elseif k=='rpcreq3' and host() then
            if not valid_rpc(d) or S.request_seen[d.seq] or S.request_pending[d.seq] then return end
            if d.seq>(S.request_highest or 0)+1024 then return end
            S.request_highest=math.max(S.request_highest or 0,d.seq)
            d.until_time=now()+30;S.request_pending[d.seq]=d
        elseif k=='rpcrepair3' and host() then
            if not integer(d.after) or d.after<0 then return end
            for seq=d.after+1,math.min(S.rpc_tx,d.after+128) do
                local item=S.rpc_journal[seq]
                if item then send('rpc3',item) else S.error='Mission event history expired; checkpoint resync required';break end
            end
        elseif k=='cinreq3' and host() then
            if not (integer(d.id) and integer(d.flow)) then return end
            if S.cin.active and S.cin.id==d.id then return end   -- already held/playing: the client follows cin3
            if S.peer_barrier then
                -- The partner's game triggered it: open the barrier here too, or say at once that the
                -- host can't take part, so the partner doesn't sit waiting.
                if S.cin.active then send('cindeny3',{id=d.id,reason='busy'});return end
                if (d.area or '')~=area() then send('cindeny3',{id=d.id,reason='area'});return end
                if d.where and E.warp then pcall(E.warp,d.where) end
                open_barrier(d.id,d.flow,d.where,true)   -- the host starts (and freezes) it in its tick
                S.cin.auto=d.auto==true
                return
            end
            if not S.cin.active and (d.area or '')==area() then
                S.queue.request={id=d.id,flow=d.flow,area=d.area or '',where=d.where,args={auto=d.auto==true},until_time=now()+20}
            end
        elseif k=='cinready3' and host() then
            if d.token==S.cin.token and S.cin.barrier then
                S.cin.peer_joined=true
                if d.absent==true then S.cin.peer_absent=true end
            end
        elseif k=='cinpong3' and host() then
            if d.token==S.cin.token and finite(d.t) then
                local rtt=now()-d.t
                if rtt>=0 and rtt<5 and (not S.rtt or rtt<S.rtt) then S.rtt=rtt end
            end
        elseif k=='cinping3' and not host() then
            if type(d.token)=='string' and finite(d.t) then send('cinpong3',{token=d.token,t=d.t}) end
        elseif k=='cindeny3' and not host() then
            if S.req and S.req.id==d.id then
                S.req=nil;unfreeze_local()
                S.message=d.reason=='area' and 'Your partner is in another area - playing the cutscene here.'
                    or 'Your partner is in another cutscene - playing this one here.'
            end
            if S.pending and S.pending.id==d.id then
                release_pending(d.reason=='area' and 'Your partner is in another area - playing the cutscene here.'
                    or 'Your partner is in another cutscene - playing this one here.')
            end
        elseif k=='cinvote3' and host() then
            if d.token==S.cin.token and d.id==S.cin.id then
                S.vote_peer=true
                if not S.vote_local then S.message='Your partner wants to skip. Hold skip to agree.' end
            end
        elseif k=='cinack3' and host() then
            if d.token==S.cin.token and d.id==S.cin.id then S.cin.peer_ready=true;S.cin.peer_skippable=d.skippable==true end
        elseif k=='cin3' and not host() then
            if not integer(d.seq) or d.seq<=S.last_host_seq or type(d.token)~='string'
                or not integer(d.id) or not integer(d.flow) or (d.area~=nil and type(d.area)~='string')
                or (d.phase~='prepare' and d.phase~='play' and d.phase~='skip' and d.phase~='end') then return end
            S.last_host_seq=d.seq
            d.area=d.area or ''
            if S.cin.token~=d.token then
                S.vote_local=false
                S.message=''
                S.cin={token=d.token,id=d.id,flow=d.flow,area=d.area,where=d.where,barrier=d.barrier==true,
                    phase=d.phase,active=d.phase=='play' or d.phase=='prepare',started=now(),seen=false}
            end
            S.cin.phase=d.phase
            if d.vote and not S.vote_local then S.message='The host wants to skip. Hold skip to agree.' end
            S.cin.active=d.phase=='play' or d.phase=='prepare'
            if S.cin.barrier and d.phase=='prepare' then
                -- barrier open: the host leads now; the tick starts/freezes our copy and reports ready
                S.message='Waiting for all players...'
                if S.req and S.req.id==d.id then S.req=nil end
            elseif S.cin.barrier and d.phase=='play' then
                -- "go": unfreeze at once (the host delays its own unfreeze by half the round trip)
                if S.freeze and S.freeze.id==d.id then
                    unfreeze_local();S.message=''
                elseif E.current_id and E.current_id()==d.id and E.playing() then
                    S.message=''
                elseif not S.cin.go and d.area==area()
                    and not (S.local_played and S.local_played[d.id] and now()-S.local_played[d.id]<180) then
                    S.cin.go=now()   -- our copy never started: start it now, unfrozen (tick)
                end
                if E.current_id and E.current_id()==d.id and E.playing() then
                    S.cin.seen=true
                    send('cinack3',{token=d.token,id=d.id,skippable=not E.can_skip or E.can_skip()})
                end
                if S.vote_local then send('cinvote3',{token=d.token,id=d.id}) end
            elseif d.phase=='prepare' then
                if E.load and d.area==area() and not S.cin.preloaded then
                    local ok,value=pcall(E.load,d.id)
                    if ok and value~=false then S.cin.preloaded=true end
                end
            elseif d.phase=='play' then
                if E.current_id and E.current_id()==d.id and E.playing() then
                    S.cin.seen=true
                    send('cinack3',{token=d.token,id=d.id,skippable=not E.can_skip or E.can_skip()})
                    if E.correct_tracks and type(d.tracks)=='table' then E.correct_tracks(d.tracks) end
                elseif S.cin.seen then
                    S.message='Waiting for the host cinematic to finish'
                elseif S.local_played and S.local_played[d.id] and now()-S.local_played[d.id]<180 then
                    -- already played here after the host was too late; don't play it twice
                elseif not S.queue.play then
                    S.queue.play={id=d.id,flow=d.flow,area=d.area,where=d.where,auto=d.auto==true,until_time=now()+30}
                end
                if S.vote_local then send('cinvote3',{token=d.token,id=d.id}) end
            else
                S.queue.play=nil
                -- Host finishing naturally is also authoritative: a slower
                -- client must not remain watching after the host has returned.
                S.queue.finish={id=d.id,token=d.token,until_time=now()+20}
            end
        elseif k=='flow3' and not host() then
            if not integer(d.seq) or d.seq<=S.last_progress_seq or type(d.chapter)~='string'
                or type(d.values)~='table' or #d.values>4096
                or not integer(d.rpc_seq) or d.rpc_seq<0 then return end
            for _,p in ipairs(d.values) do if type(p)~='table' or not integer(p[1]) or p[1]<0 or p[1]>0xFFFFFFFF or not integer(p[2]) or math.abs(p[2])>0x7FFFFFFF then return end end
            S.last_progress_seq=d.seq;S.queue.progress=d
        end
    end
    -- Client: a cutscene the game wanted to play is held until the host confirms it. If that
    -- never happens (host elsewhere, message lost, connection gone), play it here with the game's
    -- own callbacks, so the client is never left on a black screen.
    function release_pending(reason)
        local p=S.pending
        if not p then return end
        S.pending=nil
        S.local_played=S.local_played or {};S.local_played[p.id]=now()
        S.internal_play=S.internal_play+1
        local ok,result=pcall(E.play,p.id,p.flow,p.args or {})
        S.internal_play=S.internal_play-1
        if ok and result~=false then S.stats.starts=S.stats.starts+1;S.message=reason
        else S.error='Could not play the held cutscene: '..tostring(result) end
    end
    function S.tick()
        -- freeze machinery (both roles): freeze our scene as soon as the engine allows (~0.1 s after
        -- it starts); unfreeze on schedule; and never leave a scene frozen.
        local f=S.freeze
        if f then
            if not f.done and E.freeze then
                local ok,r=pcall(E.freeze,f.id)
                if ok and r then f.done=true end
            end
            if now()-f.since>(E.freeze_max or 30) then
                unfreeze_local();S.message='';S.error='Released a cutscene that stayed frozen for 30 s'
            end
        end
        if S.release_at and now()>=S.release_at then unfreeze_local() end
        if S.freeze and (not connected() or not S.cap) then
            unfreeze_local();S.message='Partner connection lost - playing the cutscene here.'
        end
        if S.req and now()>S.req.fallback_at and not (S.cin.active and S.cin.barrier and S.cin.id==S.req.id) then
            S.req=nil;unfreeze_local();S.message='The host did not answer - playing the cutscene here.'
        end
        if not host() and S.pending and (not connected() or not S.cap) then
            release_pending('Partner connection lost - playing the cutscene here.')
        end
        local peer=E.peer()
        if S.peer~=peer then
            S.peer=peer;S.cap=false;S.peer_epoch=nil;S.last_hello=-100;S.last_host_seq=-1;S.last_progress_seq=-1
            S.queue={};S.pending=nil;S.vote_local=false;S.vote_peer=false
            S.request_pending={};S.request_seen={};S.request_highest=0;S.last_progress_full=-100
            if not connected() then S.cin={active=false,phase='end'} end
        end
        if not connected() then S.queue={};return end
        if now()-S.last_hello>2 then send('session3',{version=3,rpc_seq=S.rpc_tx,barrier=E.barrier~=false and 1 or 0});S.last_hello=now() end
        if not S.cap then return end
        local playing=E.playing()
        if host() then
            for _=1,32 do
                local seq
                for k in pairs(S.request_pending)do if not seq or k<seq then seq=k end end
                if not seq then break end
                local d=S.request_pending[seq]
                if E.apply_rpc and E.apply_rpc(d.index,d.args) then
                    S.request_pending[seq]=nil;S.request_seen[seq]=true;S.request_seen[seq-2048]=nil
                    S.mirror_call(d.index,d.args)
                elseif now()>d.until_time then
                    S.error='Host could not apply a requested mission event';S.request_pending[seq]=nil
                else break end
            end
            if playing and not S.cin.active and S.cin.phase~='skip' and E.current_id then
                local id=E.current_id()
                if id and (not S.cin.token or id~=S.cin.id) then
                    S.begin(id,E.current_flow and E.current_flow() or 0,nil,true)   -- already playing: no barrier
                    S.cin.seen=true;S.cin.phase='play';publish()
                end
            end
            if S.cin.active and S.cin.barrier and S.cin.phase=='prepare' then
                if S.cin.start_here and not S.cin.started_here then
                    -- the partner's game triggered it: start it here too (it freezes like any other)
                    S.cin.started_here=true
                    if playing and E.current_id and E.current_id()==S.cin.id then freeze_local(S.cin.id)
                    else
                        S.internal_play=S.internal_play+1
                        local ok,result=pcall(E.play,S.cin.id,S.cin.flow,{auto=S.cin.auto})
                        S.internal_play=S.internal_play-1
                        if ok and result~=false then freeze_local(S.cin.id);S.stats.starts=S.stats.starts+1
                        else S.error='Host could not start the cutscene: '..tostring(result) end
                    end
                end
                if now()-S.last_ping>0.25 then S.last_ping=now();send('cinping3',{token=S.cin.token,t=now()}) end
                local timeout=now()-S.cin.started>(E.barrier_timeout or 20)
                if (frozen(S.cin.id) and (S.cin.peer_joined or S.cin.peer_absent)) or timeout then
                    -- "go": tell the partner first, then unfreeze ours half a round trip later, so both
                    -- resume at the same moment
                    S.cin.phase='play';S.cin.started=now()
                    S.message=S.cin.peer_absent and 'Your partner is in another area - playing alone.'
                        or ((not S.cin.peer_joined) and 'Your partner did not respond - playing alone.') or ''
                    publish()
                    local together=S.cin.peer_joined and not S.cin.peer_absent
                    local delay=together and math.min((S.rtt or 0)/2,0.5) or 0
                    if delay<=0 then unfreeze_local() else S.release_at=now()+delay end
                end
            end
            if S.cin.active then
                if playing then
                    S.cin.seen=true
                    if S.cin.phase=='prepare' and not S.cin.barrier then S.cin.phase='play';publish() end
                end
                if S.vote_local and S.vote_peer and S.cin.peer_ready and S.cin.peer_skippable
                    and (not E.can_skip or E.can_skip()) then
                    S.cin.phase='skip';publish()
                    if skip_local() then S.cin.active=false;S.message='' end
                elseif (S.cin.seen and not playing) then
                    S.cin.active=false;S.cin.phase='end';S.message='';publish()
                elseif not S.cin.seen and now()-S.cin.started>30 then
                    S.error='Host cutscene did not start';S.cin.active=false;S.cin.phase='end';publish()
                end
            end
            if S.cin.token and now()-S.last_cin>0.5 then publish() end
            if S.queue.request and not playing and not S.cin.active then
                local q=S.queue.request;S.queue.request=nil
                if q.area==area() and now()<q.until_time then
                    -- Re-enter through the normal host hook, which allocates
                    -- the authoritative instance and publishes the start.
                    local ok,result=pcall(E.play,q.id,q.flow,q.args)
                    if not ok or result==false then S.error='Host rejected cutscene request' end
                end
            end
            if E.progress and now()-S.last_progress>2 then
                S.last_progress=now()
                local values,chapter=E.progress()
                if values and chapter then
                    local sig=E.progress_signature(values,chapter)
                    if sig~=S.progress_signature or now()-(S.last_progress_full or -100)>10 then
                        S.progress_signature=sig;S.last_progress_full=now();S.progress_seq=S.progress_seq+1
                        send('flow3',{seq=S.progress_seq,chapter=chapter,values=values,rpc_seq=S.rpc_tx})
                    end
                end
            end
        else
            -- Pause barrier (client): get our copy of the scene frozen, then report ready; or report
            -- absent (other area / already played alone). "go" (cin3 play) unfreezes it in S.handle.
            if S.cin.active and S.cin.barrier then
                if S.cin.phase=='prepare' then
                    local played=S.local_played and S.local_played[S.cin.id]
                    local absent=S.cin.area~=area() or (played~=nil and now()-played<180)
                    if not absent and not (S.freeze and S.freeze.id==S.cin.id) then
                        -- our game didn't trigger it: move next to the host, give the game's own trigger
                        -- (with its callbacks) a second to fire, otherwise start it here; either way it freezes
                        if S.cin.where and not S.cin.warped and E.warp then
                            S.cin.warped=true;S.cin.warp_time=now();pcall(E.warp,S.cin.where)
                        elseif not S.cin.started_here and now()-(S.cin.warp_time or -100)>=1 then
                            S.cin.started_here=true
                            if playing and E.current_id and E.current_id()==S.cin.id then freeze_local(S.cin.id)
                            else
                                S.internal_play=S.internal_play+1
                                local ok,result=pcall(E.play,S.cin.id,S.cin.flow,{auto=false})
                                S.internal_play=S.internal_play-1
                                if ok and result~=false then freeze_local(S.cin.id);S.stats.starts=S.stats.starts+1
                                else S.error='Could not start the cutscene: '..tostring(result) end
                            end
                        end
                    end
                    if (absent or frozen(S.cin.id)) and now()-(S.last_ready or -100)>0.25 then
                        S.last_ready=now();send('cinready3',{token=S.cin.token,absent=absent})
                    end
                elseif S.cin.phase=='play' and S.cin.go and not S.cin.go_started and not playing then
                    -- "go" arrived before our copy started: start it now, unfrozen
                    S.cin.go_started=now()
                    S.internal_play=S.internal_play+1
                    local ok,result=pcall(E.play,S.cin.id,S.cin.flow,{auto=false})
                    S.internal_play=S.internal_play-1
                    if ok and result~=false then S.stats.starts=S.stats.starts+1;S.message=''
                    else S.error='Could not start the cutscene: '..tostring(result) end
                end
            end
            -- Host-started scene. A cutscene that isn't preloaded loads for a few seconds before
            -- IsPlayingCutScene is true; re-requesting it meanwhile restarts the load (real session:
            -- 8 requests, black screen). Request once, then wait. After a warp, give the game's own
            -- trigger (with its callbacks) a moment to fire first.
            local q=S.queue.play
            if q then
                if playing and (not E.current_id or E.current_id()==q.id) then
                    S.queue.play=nil;S.pending=nil
                elseif now()>q.until_time then S.queue.play=nil;S.error='Timed out waiting for host cinematic resources'
                elseif q.requested then
                    if now()-q.requested>15 then S.queue.play=nil;S.error='The host cutscene did not start on this PC' end
                elseif q.area==area() and not playing then
                    if q.where and not q.warped then q.warped=E.warp(q.where)~=false;q.warp_time=now()
                    elseif q.warped and now()-(q.warp_time or 0)<1 and not (S.pending and S.pending.id==q.id) then
                        -- the game's own trigger may fire here; begin() then lets it play natively
                    else
                        local args=S.pending and S.pending.id==q.id and S.pending.args or {}
                        args.auto=q.auto
                        S.internal_play=S.internal_play+1
                        local ok,result=pcall(E.play,q.id,q.flow,args)
                        S.internal_play=S.internal_play-1
                        if ok and result~=false then q.requested=now();S.pending=nil;S.stats.starts=S.stats.starts+1
                        else S.queue.play=nil;S.error=ok and 'Client cutscene request returned false' or tostring(result) end
                    end
                end
            end
            local p=S.pending
            if p and not S.queue.play and not playing and not (S.cin.active and S.cin.id==p.id) and now()>=p.fallback_at then
                release_pending('The host did not start this cutscene - playing it here.')
            end
            if S.cin.active and playing and (not E.current_id or E.current_id()==S.cin.id) then
                S.cin.seen=true
                if now()-(S.last_ack or -100)>0.5 then send('cinack3',{token=S.cin.token,id=S.cin.id,skippable=not E.can_skip or E.can_skip()});S.last_ack=now() end
                if S.vote_local and now()-(S.last_vote or -100)>0.5 then send('cinvote3',{token=S.cin.token,id=S.cin.id});S.last_vote=now() end
            end
            if S.queue.finish then
                if not playing then S.queue.finish=nil;S.message=''
                elseif now()>S.queue.finish.until_time then S.error='Client could not finish the host cinematic';S.queue.finish=nil
                elseif not E.current_id or E.current_id()==S.queue.finish.id then skip_local() end
            end
            if S.queue.progress and (S.queue.progress.rpc_seq or 0)<S.rpc_rx then S.queue.progress=nil end
            if S.queue.progress and E.apply_progress and S.rpc_rx>=(S.queue.progress.rpc_seq or 0)
                and now()-(S.last_progress_apply or -100)>0.25 then
                S.last_progress_apply=now()
                local applied,remaining=E.apply_progress(S.queue.progress)
                S.stats.flow_applied=S.stats.flow_applied+(applied or 0)
                S.stats.flow_queued=remaining or 0
                if remaining==0 then S.queue.progress=nil end
            end
            for _=1,32 do
                local item=S.rpc_pending[S.rpc_rx+1]
                if not item then break end
                if E.apply_rpc and E.apply_rpc(item.index,item.args) then
                    S.rpc_pending[item.seq]=nil;S.rpc_rx=item.seq
                else break end
            end
            if next(S.rpc_pending) and not S.rpc_pending[S.rpc_rx+1] and now()-(S.last_rpc_repair or -100)>0.5 then
                S.last_rpc_repair=now();send('rpcrepair3',{after=S.rpc_rx})
            end
        end
    end
    S.E=E   -- engine adapter, for in-game checks (tools)
    if E.install then E.install(S) end
    return S
end

-- Native adapters. Method selection checks reflected parameter types instead
-- of assuming an old Nullable callback signature still exists in this build.
function M.engine(E)
    local live
    local med_td=sdk.find_type_definition('app.TimelineEventMediator')
    local play_method
    for _,m in ipairs(med_td:get_methods()) do
        local p=m:get_param_types()
        if m:get_name()=='play' and #p==6 and p[2]:get_full_name()=='System.Int32'
            and p[4]:get_full_name()=='System.Boolean' then play_method=m;break end
    end
    assert(play_method,'No compatible TimelineEventMediator.play overload')
    local function med() return sdk.get_managed_singleton('app.TimelineEventMediator') end
    local function active_process()
        local m=med();local list=m and m:get_field('_ActiveEvents')
        if list then
            local first
            for i=0,list:call('get_Count')-1 do
                local p=list:call('get_Item',i)
                if p and p:call('get_IsPlayProcess') then
                    first=first or p
                    if live and p:call('get_TimelineEventId')==live.cin.id then return p end
                end
            end
            return first
        end
    end
    E.playing=function()
        if live and live.native_active and live.native_active[live.cin.id] then return true end
        local m=med();return m and m:call('get_IsPlayingCutScene') or false
    end
    E.load=function(id)
        for _,m in ipairs(med_td:get_methods()) do
            if m:get_name()=='load' and #m:get_param_types()==3 then
                local p=m:get_param_types();local callback
                if p[3]:get_full_name():find('System.Nullable',1,true) then callback=ValueType.new(p[3]) end
                return m:call(med(),id,'RequiemCoop',callback)
            end
        end
        return false
    end
    E.can_skip=function() local m=med();return m and m:call('get_IsSkippable') or false end
    -- Freeze/unfreeze a running cutscene (verified in-game on 111100: pause() moves the process from
    -- state 8 to 9 and resume() back; canPause() turns true ~0.1 s after the start).
    local pause_key=sdk.create_managed_string('RequiemCoopBarrier'):add_ref()
    local function process_of(id)
        local m=med();local list=m and m:get_field('_ActiveEvents')
        if not list then return nil end
        for i=0,list:call('get_Count')-1 do
            local p=list:call('get_Item',i)
            if p and p:call('get_TimelineEventId')==id and p:call('get_IsPlayProcess') then return p end
        end
    end
    E.freeze=function(id)
        local p=process_of(id)
        if not (p and p:call('canPause')) then return false end
        return p:call('pause',pause_key)==true
    end
    E.unfreeze=function(id)
        local p=process_of(id)
        return p and p:call('resume',pause_key) or false
    end
    E.current_id=function() local p=active_process();return p and p:call('get_TimelineEventId') end
    E.current_flow=function() local p=active_process();return p and p:get_field('_FlowId') or 0 end
    E.play=function(id,flow,args)
        local parameters=play_method:get_param_types()
        local defaults={}
        for i=5,6 do
            if parameters[i]:get_full_name():find('System.Nullable',1,true) then defaults[i]=ValueType.new(parameters[i]) end
        end
        -- held calls replay with the game's own caller name; host-started ones use ours
        return play_method:call(med(),id,flow,args and args.name or 'RequiemCoop',args and args.auto or false,
            args and args.start_callback or defaults[5],args and args.end_callback or defaults[6])
    end
    E.skip=function() return med():call('skip(System.Object)',med()) end
    local function path(go)
        local names={};local tr=go:call('get_Transform')
        for _=1,12 do
            if not tr then break end
            table.insert(names,1,tr:call('get_GameObject'):call('get_Name'));tr=tr:call('get_Parent')
        end
        local folder=go:call('get_Folder')
        return (folder and folder:call('get_Path') or '')..'/'..table.concat(names,'/')
    end
    -- findComponents normally returns a SystemArray, but around scene changes it has come back as
    -- a plain managed object without get_size (seen in a real session: it broke cutscene sync).
    local function array_items(list)
        local out={}
        if not list then return out end
        local ok,n=pcall(function() if list.get_size then return list:get_size() end return list:call('get_Length') end)
        for i=0,(ok and type(n)=='number' and n or 0)-1 do
            local ok_e,e=pcall(function()
                if list.get_element then return list:get_element(i) end
                return list:call('GetValue(System.Int32)',i)
            end)
            if ok_e and e then out[#out+1]=e end
        end
        return out
    end
    local function timelines()
        local scene=E.scene();local list=scene and scene:call('findComponents(System.Type)',sdk.typeof('via.timeline.Timeline'))
        local out={}
        for _,t in ipairs(array_items(list)) do
            pcall(function()
                local state=t:call('get_PlayState')
                if state==1 or state==3 then
                    local go=t:call('get_GameObject');local name=go:call('get_Name')
                    if not name:find('PlayerDead',1,true) and not name:find('DamageTest',1,true) then out[path(go)]=t end
                end
            end)
        end
        return out
    end
    E.tracks=function()
        local out={}
        for key,t in pairs(timelines()) do
            if #out<32 then out[#out+1]={key=key,frame=t:call('get_Frame'),ending=t:call('get_EndFrame'),state=t:call('get_PlayState'),speed=t:call('get_PlaySpeed')} end
        end
        return out
    end
    E.correct_tracks=function(records)
        if #records>32 then return end
        local local_tracks=timelines()
        for _,r in ipairs(records) do
            local t=type(r)=='table' and local_tracks[r.key]
            if t and finite(r.frame) and finite(r.ending) and finite(r.speed) and r.frame>=0 and r.frame<=r.ending
                and (r.state==1 or r.state==3) and math.abs(t:call('get_EndFrame')-r.ending)<0.1 then
                if math.abs(t:call('get_Frame')-r.frame)>12 then t:call('set_Frame',r.frame);live.stats.repairs=live.stats.repairs+1 end
                t:call('set_PlaySpeed',r.speed);t:call('set_PlayState',r.state)
            end
        end
    end
    E.install=function(S)
        live=S
        _G.__requiem_coop_session_live=S
        local installed=_G.__requiem_coop_session_hooks or {};_G.__requiem_coop_session_hooks=installed
        S.stats.hooks=0;S.stats.missing={}
        local function hook(type_name,name,filter,handler,blocked_return)
            local td=sdk.find_type_definition(type_name)
            if not td then S.stats.missing[#S.stats.missing+1]=type_name;return end
            local matched=false
            for _,m in ipairs(td:get_methods()) do
                if m:get_name()==name and (not filter or filter(m)) then
                    matched=true
                    local types={};for _,p in ipairs(m:get_param_types()) do types[#types+1]=p:get_full_name() end
                    local key=type_name..'::'..name..'('..table.concat(types,',')..')'
                    S.stats.hooks=S.stats.hooks+1
                    if not installed[key] then
                        local stacks={}
                        sdk.hook(m,function(args)
                            local h=_G.__requiem_coop_session_live
                            local ok,block=pcall(function()return h and h[handler](args)end)
                            if not ok and h then h.error=tostring(block) end
                            local thread_key=tostring(sdk.get_thread_context())
                            local stack=stacks[thread_key] or {};stacks[thread_key]=stack
                            stack[#stack+1]=ok and block==true
                            if ok and block then return sdk.PreHookResult.SKIP_ORIGINAL end
                        end,function(retval)
                            local key_thread=tostring(sdk.get_thread_context());local stack=stacks[key_thread]
                            local blocked=stack and table.remove(stack)
                            if blocked and blocked_return~=nil then return sdk.to_ptr(blocked_return) end
                            return retval
                        end)
                        installed[key]=true
                    end
                end
            end
            if not matched then S.stats.missing[#S.stats.missing+1]=type_name..'::'..name end
        end
        function S.engine_play(args)
            local pending={auto=(sdk.to_int64(args[8])&0xFF)~=0}
            pcall(function()
                local name=sdk.to_managed_object(args[5])
                if name then pending.name=name:call('ToString') end
            end)
            for _,spec in ipairs({{'start_callback',6},{'end_callback',7}}) do
                local obj=sdk.to_managed_object(args[spec[2]])
                if obj then pending[spec[1]]=obj:add_ref() end
            end
            local flow=sdk.to_int64(args[4])&0xFFFFFFFF
            if flow>=0x80000000 then flow=flow-0x100000000 end
            return S.begin(sdk.to_int64(args[3])&0xFFFFFFFF,flow,pending)
        end
        function S.engine_skip() return S.request_skip() end
        function S.engine_request(args)
            local entry=sdk.to_managed_object(args[3])
            if entry and entry:call('get_Type')==6 then return S.request_skip() end
            return false
        end
        function S.engine_started(args)
            local e=sdk.to_managed_object(args[4]);if e then S.started(e:call('get_TimelineEventId')) end
            return false
        end
        function S.engine_finished(args)
            local e=sdk.to_managed_object(args[4]);if e then S.finished(e:call('get_TimelineEventId')) end
            return false
        end
        hook('app.TimelineEventMediator','playImpl',function(m)return #m:get_param_types()==6 end,'engine_play',1)
        hook('app.TimelineEventMediator','skip',nil,'engine_skip',0)
        hook('app.TimelineEventProcess','skip',nil,'engine_skip',0)
        hook('app.TimelineEventMediator','playSkip',nil,'engine_skip',nil)
        hook('app.AppEventManager','request',function(m)
            local p=m:get_param_types();return #p==1 and p[1]:get_full_name()=='app.AppEventDefine.RequestEntry'
        end,'engine_request',nil)
        hook('app.TimelineEventMediator','onStartingEvent',nil,'engine_started',nil)
        hook('app.TimelineEventMediator','onFinishedEvent',nil,'engine_finished',nil)
        -- Neutralize already-installed legacy hooks during a hot reload.
        _G.__requiem_coop_cs={on_play=function()end,on_request=function()return false end,event=function()end}
    end
    return E
end

-- Small unreliable light snapshots; unlike a weapon mesh this creates native
-- lights, including the flashlight's point fill. Off transitions also use the
-- reliable event channel and remote lights expire after missing snapshots.
function M.torch(E)
    local T={seq=0,remote_seq=-1,last=-100,last_state=-1,remote=nil,lights={},error=''}
    local FORMAT='<Bfffhhhhfffffff'
    local function q16(x)return math.max(-32767,math.min(32767,math.floor(x*32767+0.5)))end
    function T.pack(seq,records,stream)
        local out={'\0L1',string.pack('<I4I4B',seq,stream or 0,#records)}
        for _,l in ipairs(records) do
            out[#out+1]=string.pack(FORMAT,l.kind,l.p[1],l.p[2],l.p[3],q16(l.q[1]),q16(l.q[2]),q16(l.q[3]),q16(l.q[4]),
                l.radius,l.cone,l.falloff,l.intensity,l.color[1],l.color[2],l.color[3])
        end
        return table.concat(out)
    end
    function T.unpack(bytes)
        assert(bytes:sub(1,3)=='\0L1','invalid light packet')
        local seq,stream,count,at=string.unpack('<I4I4B',bytes,4)
        assert(count<=2,'too many torch lights')
        local records={}
        for _=1,count do
            local kind,x,y,z,qx,qy,qz,qw,radius,cone,falloff,intensity,r,g,b
            kind,x,y,z,qx,qy,qz,qw,radius,cone,falloff,intensity,r,g,b,at=string.unpack(FORMAT,bytes,at)
            assert((kind==1 or kind==2) and finite(x) and finite(y) and finite(z) and math.abs(x)+math.abs(y)+math.abs(z)<20
                and finite(radius) and radius>0 and radius<=200 and finite(cone) and cone>=0 and cone<=180
                and finite(falloff) and finite(intensity) and intensity>=0 and intensity<=1e8
                and finite(r) and finite(g) and finite(b),'invalid light state')
            local norm=(qx*qx+qy*qy+qz*qz+qw*qw)/(32767*32767)
            assert(norm>0.25 and norm<2.25,'invalid light rotation')
            records[#records+1]={kind=kind,p={x,y,z},q={qx/32767,qy/32767,qz/32767,qw/32767},
                radius=radius,cone=cone,falloff=falloff,intensity=intensity,color={r,g,b}}
        end
        assert(at==#bytes+1,'trailing light data')
        return seq,records,stream
    end
    function T.receive(bytes)
        local seq,records,stream=T.unpack(bytes)
        if E.peer_stream and stream~=E.peer_stream() then return end
        if seq<=T.remote_seq then return end
        T.remote_seq=seq;T.remote=records;T.received=E.now()
    end
    function T.off(seq)
        if integer(seq) and seq>=T.remote_seq then T.remote_seq=seq;T.remote={};T.received=E.now() end
    end
    function T.capture(go)
        local driver=go:call('getComponent(System.Type)',sdk.typeof('app.FlashLightDriver'))
        local controller=driver and driver:get_field('<FlashLightController>k__BackingField')
        if not controller or not controller:get_field('_IsLighting') or controller:call('get_IsDispOffBySequence') then return {} end
        local tr=go:call('get_Transform');local rootp,rootq=tr:call('get_Position'),tr:call('get_Rotation')
        local records,seen={},{}
        for _,spec in ipairs({{'_CurrentLight',1},{'_CurrentPointLight',2}}) do
            local light=controller:get_field(spec[1])
            if light and not seen[light:get_address()] and light:call('get_Enabled') and light:call('get_Intensity')>0 then
                seen[light:get_address()]=true
                local type_name=light:get_type_definition():get_full_name()
                local kind=type_name:find('SpotLight',1,true) and 1 or type_name:find('PointLight',1,true) and 2 or nil
                local lt=light:call('get_GameObject'):call('get_Transform');local p,q=lt:call('get_Position'),lt:call('get_Rotation')
                local x,y,z=E.qrot(-rootq.x,-rootq.y,-rootq.z,rootq.w,p.x-rootp.x,p.y-rootp.y,p.z-rootp.z)
                local qx,qy,qz,qw=E.qmul(-rootq.x,-rootq.y,-rootq.z,rootq.w,q.x,q.y,q.z,q.w)
                local c=light:call('get_Color')
                if kind and math.abs(x)+math.abs(y)+math.abs(z)<20 then records[#records+1]={kind=kind,p={x,y,z},q={qx,qy,qz,qw},radius=light:call('get_Radius'),
                    cone=kind==1 and light:call('get_Cone') or 0,falloff=kind==1 and light:call('get_Falloff') or 0,
                    intensity=light:call('get_Intensity'),color={c.x,c.y,c.z}}
                end
            end
        end
        return records
    end
    function T.send(go)
        local peer=E.peer()
        if T.peer~=peer then T.peer=peer;T.remote_seq=-1;T.remote=nil;T.last_state=-1 end
        if not E.enabled() or E.now()-T.last<0.1 then return end
        T.last=E.now()
        local records=T.capture(go)
        T.seq=T.seq+1
        if #records~=T.last_state then
            T.last_state=#records
            if #records==0 then E.off(T.seq) end
        end
        E.send(T.pack(T.seq,records,E.stream and E.stream() or 0))
    end
    function T.clear()
        for _,l in pairs(T.lights) do pcall(E.destroy,l.go) end
        T.lights={}
    end
    function T.apply(target,visible)
        local data=visible and T.remote and T.received and E.now()-T.received<0.6 and T.remote or {}
        if not target then T.clear();return end
        if T.owner~=target.go:get_address() then T.clear();T.owner=target.go:get_address() end
        local rp,rq=target.tr:call('get_Position'),target.tr:call('get_Rotation')
        for i,record in ipairs(data) do
            local item=T.lights[i]
            if item and item.kind~=record.kind then E.destroy(item.go);T.lights[i]=nil;item=nil end
            if not item then
                local go=E.create('coop_torch_'..i,target.folder)
                local light=go:call('createComponent(System.Type)',sdk.typeof(record.kind==1 and 'via.render.SpotLight' or 'via.render.PointLight'))
                item={go=go,light=light,kind=record.kind,tr=go:call('get_Transform')};T.lights[i]=item
            end
            local x,y,z=E.qrot(rq.x,rq.y,rq.z,rq.w,table.unpack(record.p))
            local qx,qy,qz,qw=E.qmul(rq.x,rq.y,rq.z,rq.w,table.unpack(record.q))
            item.tr:call('set_Position',Vector3f.new(rp.x+x,rp.y+y,rp.z+z))
            item.tr:call('set_Rotation',Quaternion.new(qw,qx,qy,qz))
            item.light:call('set_Radius',record.radius);item.light:call('set_Intensity',record.intensity)
            item.light:call('set_Color',Vector3f.new(table.unpack(record.color)))
            if record.kind==1 then item.light:call('set_Cone',record.cone);item.light:call('set_Falloff',record.falloff) end
            item.light:call('set_Enabled',true)
        end
        for i,item in pairs(T.lights) do if not data[i] then item.light:call('set_Enabled',false) end end
    end
    return T
end

return M
