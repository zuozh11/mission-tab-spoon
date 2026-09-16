local root = debug.getinfo(1, 'S').source:sub(2):match('(.*/)') .. '../'
local count=0
local function check(value,message) assert(value,message); count=count+1 end
local function node(attributes, children)
    attributes.AXChildren=children or {}
    function attributes:attributeValue(name)
        if name=='AXDisplayID' then self.displayReads=(self.displayReads or 0)+1 end
        return self[name]
    end
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
check(display.displayReads==1, 'display identity is read once per display rather than once per window')
local ordered,initial=mc.order(snap.candidates)
check(ordered[initial].id==10, 'spatial order starts at upper-left; controller owns MRU selection')
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
local ring={}
for i,xy in ipairs({{0,-100},{100,0},{0,100},{-100,0}}) do
    ring[i]={id=i,frame={x=xy[1]-5,y=xy[2]-5,w=10,h=10}}
end
local sorted,start=mc.order({ring[3],ring[1],ring[4],ring[2]})
for i=1,4 do check(sorted[i].id==i, 'clockwise order is top/right/bottom/left') end
check(sorted[start].id==1, 'circular order starts at the upper-left nearest group')
check(sorted[(start % #sorted)+1].id==2, 'Tab advances clockwise')
check(sorted[((start-2) % #sorted)+1].id==4, 'reverse wraps counterclockwise from first item')
local single,index=mc.order({ring[1]})
check(index==1 and single[index].id==1, 'one-window layout remains selectable')
local empty,index=mc.order({})
check(#empty==0 and index==nil, 'empty layout has no starting window')
return {passed=true,assertions=count}
