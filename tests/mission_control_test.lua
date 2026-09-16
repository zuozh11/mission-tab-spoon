local root = debug.getinfo(1, 'S').source:sub(2):match('(.*/)') .. '../'
local count=0
local function check(value,message) assert(value,message); count=count+1 end
local function node(attributes, children)
    attributes.AXChildren=children or {}
    function attributes:attributeValue(name) return self[name] end
    return attributes
end
local function window(id,x)
    return node({AXRole='AXButton',AXIdentifier='same.app.space.4',wid=id,AXEnabled=true,
        AXFrame={x=x,y=10,w=50,h=50},AXTitle='Same title'})
end
local a,b=window(10,100),window(20,200)
local display=node({AXIdentifier='mc.display',AXFrame={x=0,y=0}}, {a,b,node({AXIdentifier='mc.spaces',AXRole='AXGroup'})})
local roots={['com.apple.WindowManager']=node({}, {display}),['com.apple.dock']=node({}, {node({AXIdentifier='mc'})})}
local fake={application={applicationsForBundleID=function(bundle)
    if roots[bundle] then return {{bundle=bundle,pid=function() return 1 end}} end
    return {}
end},axuielement={applicationElement=function(app) return roots[app.bundle] end}}
local mc=assert(loadfile(root..'MissionTab.spoon/mission_control.lua','t',setmetatable({hs=fake},{__index=_G})))()
local snap=mc.snapshot()
check(snap.backend=='WindowManager' and #snap.candidates==2, 'new tree enumerates windows, excludes spaces')
check(snap.candidates[1].id~=snap.candidates[2].id, 'same app and title remain distinct by wid')
local ordered=mc.order(snap.candidates,{20,10})
check(ordered[1].id==20, 'window identity joins recent-window order')
check(mc.stable(snap,mc.snapshot()), 'unchanged geometry is ready')
b.AXFrame={x=250,y=10,w=50,h=50}
check(not mc.stable(snap,mc.snapshot()), 'animation geometry must settle')
check(mc.find(mc.snapshot(),{id=20}).frame.x==250, 'navigation uses fresh thumbnail geometry')
roots['com.apple.WindowManager']=nil
roots['com.apple.dock']=node({}, {node({AXIdentifier='mc'}, {node({AXIdentifier='mc.display',AXFrame={x=-1000,y=0}}, {
    node({AXIdentifier='mc.windows'}, {a,b})})})})
snap=mc.snapshot()
check(snap.backend=='Dock' and #snap.candidates==2, 'legacy tree recognized by capability')
a.wid=nil; b.wid=nil
snap=mc.snapshot()
check(mc.find(snap,snap.candidates[1]).element==a, 'without wid use AX identity rather than title')
roots['com.apple.dock']=nil
check(not mc.snapshot().present, 'absent processes are a closed overview')
local target={element=1,frame={x=0,y=0,w=100,h=100}}
local cover={element=2,frame={x=30,y=0,w=100,h=100}}
local point=mc.point({candidates={target,cover}},target)
check(point.x>0 and point.x<30, 'grouped window selects exposed strip rather than covered centre')
cover.frame={x=-10,y=-10,w=120,h=120}
check(mc.point({candidates={target,cover}},target)==nil, 'fully hidden thumbnail never guesses a pointer target')
point=mc.point({candidates={target}},target)
check(point.x==50 and point.y==50, 'isolated thumbnail uses centre')
return {passed=true,assertions=count}
