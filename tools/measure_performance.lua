-- Temporary local A/B sampling. No config files, saves or real peers are changed.
local action=performance_action or 'start'
local key='__requiem_performance_sample'
if action=='result' then return _G[key] end
local d=_G.__requiem_coop_debug()
assert(not d.link.connected and (not d.link.peer or d.link.peer==''),'Cannot A/B a live peer')
assert(not (_G[key] and _G[key].active),'Sampling already running')
local cfg
for i=1,100 do local n,v=debug.getupvalue(_G.__requiem_coop_debug,i);if not n then break end;if n=='cfg' then cfg=v end end
assert(cfg)
local result={active=true,label=performance_label or 'before',stages={},saved={enabled=cfg.enabled,mirror_test=cfg.mirror_test}}
_G[key]=result
local app=sdk.find_type_definition('via.Application'):get_method('get_FrameTimeMillisecond')
local order=performance_mirror and {{'disabled',false,false},{'mirror',true,true},{'disabled_after',false,false}} or {{'enabled_idle',true,false},{'disabled',false,false},{'enabled_idle_after',true,false}}
local index,warm,count=0,0,0
local stage
local function advance()
 index=index+1
 if index>#order then cfg.enabled=result.saved.enabled;cfg.mirror_test=result.saved.mirror_test;result.active=false;return end
 local s=order[index];cfg.enabled=s[2];cfg.mirror_test=s[3]
 stage={name=s[1],times={},lua_sum=0,started=os.clock()};result.stages[index]=stage;warm=90;count=0
end
advance()
re.on_frame(function()
 if _G[key]~=result or not result.active then return end
 local ok,err=pcall(function()
  if warm>0 then warm=warm-1;return end
  count=count+1
  local ms=app:call(nil);stage.times[#stage.times+1]=ms
  local debug=_G.__requiem_coop_debug();stage.lua_sum=stage.lua_sum+debug.prof.late+debug.prof.frame
  if count>=300 then
   local sum=0;for _,v in ipairs(stage.times)do sum=sum+v end
   table.sort(stage.times);stage.frames=#stage.times;stage.frame_ms=sum/#stage.times;stage.p95_ms=stage.times[math.ceil(#stage.times*.95)]
   stage.lua_callback_ms=stage.lua_sum/#stage.times;stage.wall_seconds=os.clock()-stage.started;stage.times=nil;stage.lua_sum=nil
   stage.debug={status=debug.status,animation=debug.animation,model=debug.model,prof=debug.prof,weapons=debug.weapons}
   advance()
  end
 end)
 if not ok then result.error=tostring(err);cfg.enabled=result.saved.enabled;cfg.mirror_test=result.saved.mirror_test;result.active=false end
end)
return {started=true,label=result.label}
