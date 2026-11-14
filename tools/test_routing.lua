-- Routing check: every message kind the session library handles must be forwarded to it by the main
-- script's event router. (Real sessions broke twice on this: anstate, then cinready3/cindeny3; the
-- session simulations call the library directly and can't see it.)
local main=assert(protocol_source):gsub('\r\n','\n')
local lib=assert(session_source):gsub('\r\n','\n')
local passed=0
local router=assert(main:match('if session and %((.-)%) then'),'session router not found in the main script')
local kinds={}
for k in lib:gmatch("k=='([%w]+)'") do kinds[k]=true end
local missing={}
for k in pairs(kinds) do
    passed=passed+1
    if not router:find('k=="'..k..'"',1,true) then missing[#missing+1]=k end
end
table.sort(missing)
assert(#missing==0,'session messages not forwarded by the main script: '..table.concat(missing,', '))
-- capability/animation events handled by anim.event must be routed too
local anim_router=assert(main:match('if (k == "anver" or .-) then\n%s*anim%.event%(k, v%)'),'anim router not found')
for _,k in ipairs({'anver','ancompact','anbones','anhead','enbatch','anstate','shdef','shack','shreq','aldef','alack','alreq','anres','anready','anfail'}) do
    passed=passed+1
    assert(anim_router:find('k == "'..k..'"',1,true),'animation event not routed: '..k)
end
return {passed=passed,session_kinds=(function()local n=0;for _ in pairs(kinds)do n=n+1 end;return n end)()}
