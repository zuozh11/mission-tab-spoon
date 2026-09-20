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
local grid={}
for i,xy in ipairs({{0,0},{100,0},{200,0},{0,100},{100,100},{200,100}}) do
    grid[i]={id=i,frame={x=xy[1],y=xy[2],w=60,h=60}}
end
local input={grid[6],grid[3],grid[4],grid[2],grid[1],grid[5]}
local sorted,start=mc.order(input)
local expected={1,4,2,5,3,6}
for i=1,6 do
    check(sorted[i].id==expected[i], 'visit each column top to bottom, then move right')
    check(sorted[(i % 6)+1].id==expected[(i % 6)+1], 'forward wraps after the bottom-right window')
    check(sorted[((i-2) % 6)+1].id==expected[((i-2) % 6)+1], 'reverse follows the full reading order')
end
check(start==1 and input[1].id==6, 'start at upper-left without mutating the snapshot')
local staggered=mc.order({
    {id=4,frame={x=130,y=100,w=60,h=80}},
    {id=2,frame={x=0,y=100,w=60,h=80}},
    {id=3,frame={x=120,y=0,w=80,h=80}},
    {id=1,frame={x=10,y=0,w=80,h=80}},
})
for i,id in ipairs({1,2,3,4}) do
    check(staggered[i].id==id, 'small horizontal offsets retain top-to-bottom columns')
end
local screenshot=mc.order({
    {id=4,frame={x=1215,y=543,w=818,h=466}},
    {id=2,frame={x=758,y=64,w=830,h=466}},
    {id=3,frame={x=413,y=603,w=792,h=466}},
    {id=1,frame={x=11,y=122,w=740,h=472}},
})
for i,id in ipairs({1,3,2,4}) do
    check(screenshot[i].id==id, 'screenshot layout visits the lower-left window before the upper-right')
end
local secondScreenshot=mc.order({
    {id=2,frame={x=1204,y=111,w=833,h=477}},
    {id=3,frame={x=765,y=598,w=840,h=471}},
    {id=4,frame={x=396,y=64,w=801,h=471}},
    {id=1,frame={x=14,y=549,w=740,h=472}},
})
for i,id in ipairs({1,4,3,2}) do
    check(secondScreenshot[i].id==id, 'second screenshot follows left-to-right centres across staggered rows')
end
for _,layout in ipairs({{screenshot,{1,3,2,4}}, {secondScreenshot,{1,4,3,2}}}) do
    for _,scale in ipairs({0.5,2.5}) do
        for _,jitter in ipairs({-8,8}) do
            local candidates={}
            for i=#layout[1],1,-1 do
                local original=layout[1][i]
                local f=original.frame
                candidates[#candidates+1]={id=original.id,frame={
                    x=-2400+(f.x+(i%2==0 and jitter or -jitter))*scale,
                    y=300+f.y*scale,w=f.w*scale,h=f.h*scale,
                }}
            end
            local result=mc.order(candidates)
            for i,id in ipairs(layout[2]) do
                check(result[i].id==id, 'four-window layouts retain their order after scaling and small shifts')
            end
        end
    end
end
local thirdFrames={
    {13,61,583,373}, {14,562,577,366}, {776,96,400,250}, {603,442,575,366},
    {669,861,437,269}, {1189,63,654,389}, {1615,464,419,296}, {1189,771,624,367},
}
-- Scaling, display origins, small layout shifts and AX enumeration must not change the columns.
for _,scale in ipairs({0.5,1,2.5}) do
    for _,jitter in ipairs({-8,0,8}) do
        local candidates={}
        for i=#thirdFrames,1,-1 do
            local f=thirdFrames[i]
            candidates[#candidates+1]={id=i,frame={
                x=-2400+(f[1]+(i%2==0 and jitter or -jitter))*scale,
                y=300+f[2]*scale,w=f[3]*scale,h=f[4]*scale,
            }}
        end
        local result=mc.order(candidates)
        for i=1,8 do check(result[i].id==i, 'eight-window layout retains three visual columns') end
    end
end
local nearAligned=mc.order({
    {id=2,frame={x=0,y=100,w=100,h=60}},
    {id=1,frame={x=2,y=0,w=100,h=60}},
})
check(nearAligned[1].id==1 and nearAligned[2].id==2, 'two-pixel offset does not reverse a single column')
local distant=mc.order({
    {id=1,frame={x=0,y=100,w=60,h=60}},
    {id=2,frame={x=100,y=0,w=60,h=60}},
    {id=3,frame={x=1000,y=0,w=60,h=60}},
})
for i=1,3 do check(distant[i].id==i, 'a distant window does not merge distinct nearby columns') end
local chained=mc.order({
    {id=3,frame={x=120,y=0,w=100,h=60}},
    {id=2,frame={x=60,y=100,w=100,h=60}},
    {id=1,frame={x=0,y=0,w=100,h=60}},
})
for i=1,3 do check(chained[i].id==i, 'pairwise overlap does not chain distinct columns together') end
local stacked=mc.order({
    {id=3,frame={x=0,y=80,w=60,h=60}},
    {id=1,frame={x=0,y=0,w=60,h=60}},
    {id=2,frame={x=0,y=40,w=60,h=60}},
})
for i=1,3 do check(stacked[i].id==i, 'overlapping vertical stacks are visited top to bottom') end
local coincidentA={id=10,frame={x=0,y=0,w=40,h=40}}
local coincidentB={id=20,frame={x=0,y=0,w=40,h=40}}
local tied=mc.order({coincidentB,coincidentA})
check(tied[1].id==10 and tied[2].id==20, 'coincident thumbnails use stable window ID order')
local single,index=mc.order({grid[1]})
check(index==1 and single[index].id==1, 'one-window layout remains selectable')
local empty,index=mc.order({})
check(#empty==0 and index==nil, 'empty layout has no starting window')
return {passed=true,assertions=count}
