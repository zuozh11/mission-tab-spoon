-- Exercise the real controller with deterministic system boundaries, without touching the desktop.
local root = debug.getinfo(1, 'S').source:sub(2):match('(.*/)') .. '../'
local count = 0
local function check(value, message) assert(value, message); count = count + 1 end
local function fixture(holdDelay)
    local f = { time = 0, present = false, focused = 1, pointer = {x=900,y=900}, posted = {}, toggles = 0 }
    f.snapshotCalls, f.pointCalls = 0, 0
    local function watcher(callback)
        return { callback=callback, start=function(self) self.enabled=true; return self end,
            stop=function(self) self.enabled=false end, isEnabled=function(self) return self.enabled end }
    end
    local function win(id) return {id=function() return id end, focus=function() f.focused=id end,
        frame=function() return {x=id*100,y=0,w=50,h=50} end} end
    local function newEvent(kind, key, flags)
        local e = {kind=kind,key=key,flags=flags or {},props={}}
        function e:setProperty(k,v) self.props[k]=v; return self end
        function e:getProperty(k) return self.props[k] or 0 end
        function e:getType() return self.kind end
        function e:getKeyCode() return self.key end
        function e:getFlags() return self.flags end
        function e:setFlags(flags) self.flags=flags; return self end
        function e:location() return self.point end
        function e:post() f.posted[#f.posted+1]=self; if self.point then
            f.pointer=self.point
            if not f.hoverReadyAt or f.time >= f.hoverReadyAt then
                for id=1,3 do if self.point.x==id*100+25 then f.hoverID=id end end
            end
        end; return self end
        return e
    end
    local hs = {
        timer={absoluteTime=function() return f.time*1e9 end, doEvery=function(_,fn) return watcher(fn):start() end,
            doAfter=function(_,fn) return watcher(fn):start() end},
        logger={new=function() return {w=function() end,e=function(err) error(err) end} end},
        inspect=tostring, keycodes={map={tab=48,escape=53,['`']=50}},
        accessibilityState=function() return true end,
        mouse={getCurrentScreen=function() return {id=function() return 1 end,
            fullFrame=function() return f.screenFrame or {x=0,y=0,w=1000,h=1000} end} end, absolutePosition=function(p) if p then f.pointer=p end; return f.pointer end},
        window={get=function() error('global AX enumeration blocks input') end,
            orderedWindows=function() error('global AX enumeration blocks input') end,
            focusedWindow=function() return win(f.focused) end,
            list=function() return {{kCGWindowNumber=1,kCGWindowOwnerPID=101},
                {kCGWindowNumber=2,kCGWindowOwnerPID=102},{kCGWindowNumber=3,kCGWindowOwnerPID=103}} end},
        axuielement={applicationElementForPID=function(pid)
            f.resolvedPID=pid
            return {setTimeout=function() end,attributeValue=function(_,name)
                assert(name=='AXWindows')
                if f.targetUnresponsive then f.time=f.time+0.05; return nil end
                return {{setTimeout=function() end,asHSWindow=function() return win(pid-100) end}}
            end}
        end},
        spaces={openMissionControl=function()
            f.opens=(f.opens or 0)+1
            f.present=not f.noOpen and not (f.showDesktop and f.opens==1)
        end,toggleMissionControl=function()
            f.toggles=f.toggles+1
            if not f.stuck then f.present=not f.present; f.focused=f.hoverID or f.focused end
        end},
        screen={watcher={new=watcher},allScreens=function()
            if f.screens then return f.screens end
            return {{id=function() return 1 end,fullFrame=function()
                return f.screenFrame or {x=0,y=0,w=1000,h=1000}
            end}}
        end},caffeinate={watcher={new=watcher,systemWillSleep=1,screensDidLock=2}},
        eventtap={new=function(_,fn) return watcher(fn) end,isSecureInputEnabled=function() return f.secure end,checkKeyboardModifiers=function() return f.modifiers or {} end},
    }
    hs.eventtap.event={types={keyDown=1,keyUp=2,flagsChanged=3,mouseMoved=4,leftMouseDown=5,rightMouseDown=6},
        properties={eventSourceUserData='tag',keyboardEventAutorepeat='repeat',mouseEventDeltaX='dx',mouseEventDeltaY='dy'},
        newKeyEvent=function(mods,key,down)
            if type(mods)=='string' then return newEvent(3,mods,{[mods]=key==true}) end
            return newEvent(down and 1 or 2,key,mods)
        end,
        newMouseEvent=function(kind,point)
            local e=newEvent(kind); e.point=point
            return e
        end}
    hs.canvas={new=function(frame)
        local canvas={bounds=frame,frameUpdates=0,shows=0}
        function canvas:level(value) self.windowLevel=value; return self end
        function canvas:behavior(value) self.behaviors=value; return self end
        function canvas:clickActivating(value) self.activates=value; return self end
        function canvas:canvasMouseEvents(...) self.mouseEvents={...}; return self end
        function canvas:mouseCallback(value) self.callback=value; return self end
        function canvas:appendElements(value) self.element=value; return self end
        function canvas:elementAttribute(_, key, value) self.element[key]=value; return self end
        function canvas:frame(value) self.frameUpdates=self.frameUpdates+1; self.bounds=value; return self end
        function canvas:show() self.shows=self.shows+1; self.visible=true; return self end
        function canvas:delete() self.deleted=true; self.visible=false end
        f.canvas=canvas
        return canvas
    end}
    local mc = dofile(root .. 'MissionTab.spoon/mission_control.lua')
    local point=mc.point
    function mc.point(...) f.pointCalls=f.pointCalls+1; return point(...) end
    function mc.snapshot()
        f.snapshotCalls=f.snapshotCalls+1
        local out={present=f.present,backend='WindowManager',pid=f.pid or 7,candidates={}}
        if f.present and not f.empty then
            for id=1,3 do if id~=f.removed then
                out.candidates[#out.candidates+1]={id=id,element=id,frame={x=id*100+(f.motion and f.time*100 or 0),y=0,w=50,h=50},display={x=0,y=0}}
                if f.occluded and id==1 then
                    out.candidates[#out.candidates].frame={x=200,y=0,w=50,h=50}
                end
            end end
        end
        return out
    end
    local env=setmetatable({hs=hs,dofile=function(path)
        if path:match('mission_control.lua$') then return mc else return dofile(path) end
    end},{__index=_G})
    f.spoon=assert(loadfile(root .. 'MissionTab.spoon/init.lua','t',env))()
    if holdDelay ~= nil then f.spoon.holdDelay=holdDelay else f.spoon.holdDelay=0 end
    f.spoon:start()
    function f.input(kind,key,flags,tag)
        local e=newEvent(kind,key,flags); if tag then e.props.tag=tag end
        f.modifiers=flags
        local consumed=f.spoon:_event(e)
        local replay=f.spoon.replayTimer
        if replay and not f.deferReplay then replay.callback() end
        return consumed
    end
    function f.move(point)
        local e=newEvent(4); e.point=point; e.props.dx=10
        f.pointer=point
        return f.spoon:_event(e)
    end
    function f.tick(time) f.time=time; f.spoon:_tick() end
    function f.begin()
        f.input(1,48,{cmd=true}); f.input(2,48,{cmd=true}); f.tick(0.03); f.tick(0.2)
    end
    function f.ready() f.tick(0.5); f.tick(0.54) end
    return f
end
for _,shift in ipairs({false,true}) do
    local entry=fixture(); entry.motion=true
    entry.input(1,48,{cmd=true,shift=shift}); entry.input(2,48,{cmd=true,shift=shift})
    entry.tick(0.03); entry.tick(0.2); entry.tick(0.4)
    entry.motion=false; entry.ready(); entry.tick(0.9)
    check(entry.pointer.x==225 and entry.pointer.y==25 and #entry.posted>0,
        'entry and delayed hover refresh locate the MRU window for either direction')
    check(entry.spoon.run.target.id==2 and entry.spoon.highlight,
        'entry still selects and highlights the MRU window')
    entry.input(3,55,{}); entry.tick(0.93); entry.tick(0.96)
    check(entry.focused==2 and entry.spoon:status().lastResult.matched,
        'entry selection confirms by window ID after initial pointer placement')
end
local targeted=fixture(); targeted.begin(); targeted.ready(); targeted.input(3,55,{})
targeted.tick(0.6); targeted.tick(0.63)
check(targeted.resolvedPID==102 and targeted.spoon:status().lastResult.matched,
    'confirmation resolves only the selected window owner without global AX enumeration')
local unavailable=fixture(); unavailable.begin(); unavailable.ready(); unavailable.targetUnresponsive=true
unavailable.input(3,55,{}); unavailable.tick(0.6); unavailable.tick(0.7)
check(unavailable.spoon:status().lastResult.reason=='target-unavailable' and not unavailable.spoon.suspended,
    'unresponsive selected application ends the gesture without disabling input')
local reverseMask=fixture(); reverseMask.begin(); reverseMask.ready()
local originalCanvas=reverseMask.canvas
for _,id in ipairs({1,3,2,1}) do
    reverseMask.input(1,50,{cmd=true}); reverseMask.input(2,50,{cmd=true}); reverseMask.tick(reverseMask.time+0.03)
    check(reverseMask.spoon.run.target.id==id and reverseMask.canvas.element.frame.x==id*100,
        'reverse selection and drawn mask point to the same window')
    check(reverseMask.canvas==originalCanvas and reverseMask.canvas.frameUpdates==0,
        'reverse navigation never moves or resizes the visible native overlay')
end
local focusedEntry=fixture(); focusedEntry.focused=3
focusedEntry.begin(); focusedEntry.ready()
check(focusedEntry.spoon.run.target.id==1 and focusedEntry.pointer.x==125,
    'entry selects the most recent other window instead of the focused window')
local missingFocus=fixture(); missingFocus.removed=1
missingFocus.begin(); missingFocus.ready()
check(missingFocus.spoon.run.target.id==2,
    'entry falls back to a recent visible window when focus is absent from overview')
local exitPointer=fixture(); exitPointer.motion=true; exitPointer.begin()
local thumbnailPointer=exitPointer.pointer
exitPointer.input(3,55,{}); exitPointer.tick(0.23); exitPointer.tick(0.26)
check(exitPointer.spoon:status().state=='idle' and exitPointer.pointer==thumbnailPointer,
    'confirmation preserves thumbnail pointer instead of centering it on the desktop window')
local mouseExit=fixture(); mouseExit.begin(); mouseExit.ready()
mouseExit.move({x=800,y=800}); mouseExit.input(3,55,{})
mouseExit.tick(0.6); mouseExit.tick(0.63)
check(mouseExit.spoon:status().state=='idle' and mouseExit.pointer.x==800 and mouseExit.pointer.y==800,
    'mouse confirmation preserves the user pointer position after exit')
local movingEntry=fixture(); movingEntry.motion=true; movingEntry.begin()
for _,released in ipairs({false,true}) do
    local desktop=fixture(); desktop.showDesktop=true; desktop.begin()
    if released then desktop.input(3,55,{}) end
    desktop.tick(1.6)
    check(desktop.opens==2 and desktop.present and not desktop.spoon.suspended,
        'Show Desktop retries an absent overview once without suspending')
    desktop.tick(1.7); desktop.tick(1.8)
    if not released then desktop.input(3,55,{}); desktop.tick(1.9) end
    desktop.tick(2)
    check(desktop.spoon:status().lastResult.matched and desktop.toggles==1,
        'Show Desktop entry confirms even if Command was released before retry')
end
movingEntry.tick(0.5); movingEntry.tick(2)
check(movingEntry.opens==1, 'visible overview never retries its opening request')
check(movingEntry.present and movingEntry.toggles==0 and not movingEntry.spoon.suspended,
    'visible moving entry must not automatically close at the stabilization deadline')
local restartedTap=fixture(); restartedTap.begin(); restartedTap.ready()
restartedTap.spoon.tap:stop(); restartedTap.spoon.health.callback(); restartedTap.tick(0.6)
check(restartedTap.present and restartedTap.toggles==0 and restartedTap.spoon.tap:isEnabled(),
    'recovering a disabled event tap while Command is held preserves the overview')
local missedRelease=fixture(); missedRelease.begin(); missedRelease.ready()
missedRelease.spoon.tap:stop(); missedRelease.modifiers={}
missedRelease.spoon.health.callback(); missedRelease.tick(0.6); missedRelease.tick(0.7)
check(missedRelease.spoon:status().lastResult.reason=='committed',
    'tap recovery confirms when Command was actually released while the tap was disabled')
movingEntry.input(1,50,{cmd=true}); movingEntry.input(2,50,{cmd=true}); movingEntry.tick(2.03)
check(movingEntry.spoon.run.target.id==1 and movingEntry.present,
    'reverse navigation still works after freezing a moving entry layout at its deadline')
movingEntry.input(3,55,{}); movingEntry.tick(2.06); movingEntry.tick(2.1)
check(movingEntry.spoon:status().lastResult.matched,
    'moving layout still confirms the selected window after the stabilization deadline')
local offsetScreen=fixture(); offsetScreen.screenFrame={x=-500,y=-100,w=1000,h=1000}
offsetScreen.spoon:_highlight({frame={x=-450,y=-50,w=200,h=100}})
check(offsetScreen.canvas.bounds.x==-500 and offsetScreen.canvas.element.frame.x==50
    and offsetScreen.canvas.element.frame.y==50,
    'mask drawing uses local screen coordinates on displays with negative origins')
offsetScreen.spoon:stop()
local native=fixture(0.18)
for _, duringEntry in ipairs({true, false}) do
    local overlap=fixture()
    if duringEntry then overlap.occluded=true end
    overlap.begin(); overlap.ready()
    overlap.occluded=true
    local pointer=overlap.pointer
    local posted=#overlap.posted
    overlap.tick(0.6); overlap.tick(2)
    check(overlap.present and overlap.toggles==0 and overlap.spoon.session.mode=='navigating',
        'overlapping thumbnails must not close overview or block entry stabilization')
    check(overlap.pointer==pointer and #overlap.posted==posted,
        'occluded selection never moves pointer to an unsafe thumbnail')
    overlap.input(3,55,{}); overlap.tick(2.03); overlap.tick(2.06)
    check(overlap.focused==2 and overlap.spoon:status().lastResult.matched,
        'occluded target still confirms by window ID on Command release')
end
local temporaryOverlap=fixture(); temporaryOverlap.occluded=true
temporaryOverlap.begin(); temporaryOverlap.ready()
temporaryOverlap.occluded=false; temporaryOverlap.tick(0.6)
check(temporaryOverlap.pointer.x==225 and temporaryOverlap.toggles==0,
    'entry locates the recent thumbnail once it becomes safe to hover')
temporaryOverlap.input(1,48,{cmd=true}); temporaryOverlap.input(2,48,{cmd=true}); temporaryOverlap.tick(0.63)
check(temporaryOverlap.spoon.run.target.id==3 and temporaryOverlap.pointer.x==325 and temporaryOverlap.toggles==0,
    'navigation continues after temporary thumbnail overlap')
native.input(1,48,{cmd=true}); native.input(2,48,{cmd=true}); native.tick(0.08)
native.input(3,55,{})
check(#native.posted==4 and not native.present and native.spoon:status().state=='idle',
    'short press immediately replays native switching without opening overview')
check(native.spoon:status().lastResult.reason=='native-replay' and native.posted[4].flags.cmd==nil,
    'native replay releases Command and clears previous target diagnostics')
native.input(1,48,{cmd=true}); native.input(3,55,{})
check(#native.posted==8 and native.input(2,48,{}), 'consecutive short gestures and late Tab release are preserved')
local mixed=fixture(0.18); mixed.begin(); mixed.input(3,55,{}); mixed.stuck=true; mixed.tick(0.21)
local beforeReplay=#mixed.posted
mixed.input(1,48,{cmd=true}); mixed.input(2,48,{cmd=true}); mixed.input(3,55,{})
mixed.input(1,48,{cmd=true}); mixed.input(2,48,{cmd=true})
mixed.modifiers={cmd=true}
check(#mixed.posted==beforeReplay, 'short gesture during exit waits its turn instead of replaying into overview')
mixed.present=false; mixed.stuck=false; mixed.tick(0.24); mixed.tick(0.27)
check(#mixed.posted==beforeReplay+5 and mixed.posted[#mixed.posted].flags.cmd,
    'queued native replay commits then restores Command held for the next gesture')
check(mixed.spoon.session.mode=='pending' and #mixed.spoon.queuedSessions==0,
    'native replay continues to the next queued gesture')
mixed.tick(0.5)
check(mixed.present and mixed.spoon:status().state=='opening', 'next long gesture still opens overview')
local reverse=fixture(0.18)
reverse.input(1,48,{cmd=true,shift=true}); reverse.input(2,48,{cmd=true,shift=true}); reverse.input(3,55,{shift=true})
check(#reverse.posted==6 and reverse.posted[3].flags[2]=='shift' and reverse.posted[6].flags.shift,
    'reverse short replay preserves direction and remaining physical Shift')
local mask=fixture(); mask.motion=true; mask.begin()
local canvas=mask.canvas
check(canvas and canvas.visible and canvas.element.frame.x==220 and canvas.element.frame.y==0
    and canvas.element.frame.w==50 and canvas.element.frame.h==50 and canvas.element.fillColor.alpha==0.20,
    'selected thumbnail gets a full-size translucent highlight without margins during entry')
check(not canvas.activates and not canvas.callback and not canvas.mouseEvents[1],
    'highlight does not activate Hammerspoon or capture native pointer input')
mask.input(1,48,{cmd=true}); mask.input(2,48,{cmd=true}); mask.tick(0.3)
check(mask.canvas==canvas and canvas.element.frame.x==330, 'one canvas follows selection and moving entry geometry')
mask.move({x=800,y=800}); mask.tick(0.32)
check(canvas.deleted and not mask.spoon.highlight, 'moving into blank space removes the highlight')
mask.input(1,48,{cmd=true}); mask.input(2,48,{cmd=true}); mask.tick(0.4)
check(mask.spoon.highlight and mask.spoon.highlight.visible, 'keyboard resumption restores the highlight')
mask.input(3,55,{})
check(not mask.spoon.highlight, 'Command release removes highlight before the exit animation')
local stoppedMask=fixture(); stoppedMask.begin(); local stoppedCanvas=stoppedMask.canvas
stoppedMask.spoon:stop()
check(stoppedCanvas.deleted, 'stopping deletes the highlight')
local cancelMask=fixture(); cancelMask.begin(); local cancelCanvas=cancelMask.canvas
cancelMask.input(1,53,{cmd=true}); cancelMask.tick(0.3)
check(cancelCanvas.deleted, 'Escape cleanup removes the highlight')
local mouseMask=fixture(); mouseMask.begin(); mouseMask.ready()
local postedBeforeMouse=#mouseMask.posted
mouseMask.move({x=325,y=25}); mouseMask.tick(0.6)
check(mouseMask.spoon.highlight and mouseMask.canvas.element.frame.x==300,
    'mouse takeover highlights the hovered thumbnail')
check(mouseMask.pointer.x==325 and #mouseMask.posted==postedBeforeMouse,
    'mouse highlight does not warp pointer or synthesize hover events')
mouseMask.move({x=125,y=25}); mouseMask.tick(0.63)
check(mouseMask.canvas.element.frame.x==100, 'mouse highlight follows a different thumbnail')
mouseMask.move({x=800,y=800}); mouseMask.tick(0.66)
check(not mouseMask.spoon.highlight, 'blank space hides highlight instead of selecting nearest thumbnail')
mouseMask.move({x=225,y=25}); mouseMask.tick(0.69)
check(mouseMask.spoon.highlight, 'hovering a thumbnail again restores highlight')
mouseMask.input(3,55,{}); mouseMask.tick(0.72)
check(not mouseMask.spoon.highlight and mouseMask.toggles==1,
    'mouse confirmation hides highlight while preserving native exit')
local openingMouse=fixture(); openingMouse.motion=true; openingMouse.begin()
openingMouse.move({x=245,y=25}); openingMouse.tick(0.3)
check(openingMouse.spoon:status().state=='opening' and openingMouse.canvas.element.frame.x==230,
    'mouse highlight works while entry geometry is still moving')
local startup=fixture(); startup.begin()
for _=1,5 do startup.spoon.screenWatcher.callback() end
check(startup.spoon:status().state=='opening', 'unchanged screen geometry notifications do not cancel first entry')
startup.ready()
check(startup.spoon.highlight and startup.toggles==0, 'first entry keeps highlight and overview open after notification burst')
startup.screenFrame={x=100,y=0,w=1000,h=1000}
startup.spoon.screenWatcher.callback(); startup.tick(0.6)
check(startup.toggles==1 and startup.spoon:status().state=='closing', 'real screen rearrangement still cancels safely')
startup.spoon.screenWatcher.callback(); startup.tick(0.7)
check(startup.toggles==1 and startup.spoon:status().state=='idle', 'unchanged follow-up notification does not restart cancellation')
local topology=fixture()
local screenA={id=function() return 1 end,fullFrame=function() return {x=0,y=0,w=1000,h=1000} end}
local screenB={id=function() return 2 end,fullFrame=function() return {x=1000,y=0,w=1000,h=1000} end}
topology.screens={screenA,screenB}; topology.spoon.screenWatcher.callback(); topology.begin()
topology.screens={screenB,screenA}; topology.spoon.screenWatcher.callback()
check(topology.spoon:status().state=='opening', 'screen enumeration order alone does not cancel')
topology.screens={screenA}; topology.spoon.screenWatcher.callback()
check(topology.spoon:status().state=='cancelling', 'disconnecting a display still cancels active navigation')
local immediate=fixture(); immediate.hoverReadyAt=10; immediate.stuck=true
immediate.input(1,48,{cmd=true}); immediate.tick(0.03)
immediate.input(3,55,{}); immediate.tick(0.06)
check(immediate.toggles==1 and immediate.focused==2 and immediate.present,
    'release requests exit and target focus on first snapshot before animation or hover readiness')
immediate.tick(0.09)
check(immediate.toggles==1, 'closing animation does not trigger repeated exit requests')
immediate.present=false; immediate.focused=1; immediate.tick(0.12)
check(immediate.focused==2 and immediate.spoon:status().state=='idle',
    'exit reapplies target focus and releases input without diagnostic delay')
check(immediate.input(1,48,{cmd=true}), 'next gesture is accepted immediately after exit')
local settled=fixture(); settled.begin(); settled.ready(); settled.stuck=true
settled.input(3,55,{}); settled.tick(0.55)
check(settled.focused==2 and settled.toggles==1, 'settled release skips pending hover refresh and hover delay')
local sequence=fixture(); sequence.begin(); sequence.input(3,55,{})
sequence.stuck=true; sequence.tick(0.21)
check(sequence.input(1,48,{cmd=true}), 'exit animation accepts the next gesture')
sequence.input(2,48,{cmd=true}); sequence.input(1,48,{cmd=true}); sequence.input(2,48,{cmd=true})
sequence.input(3,55,{})
sequence.input(1,48,{cmd=true}); sequence.input(2,48,{cmd=true}); sequence.input(3,55,{})
check(#sequence.spoon.queuedSessions==2 and sequence.spoon.queuedSessions[1].steps==2,
    'exit animation retains navigation and separate released gestures')
sequence.present=false; sequence.stuck=false; sequence.tick(0.24)
check(sequence.spoon:status().state=='opening' and sequence.spoon.session.steps==2,
    'queued gesture starts as soon as the previous overview disappears')
sequence.time=0.27; sequence.spoon.workTimer.callback()
check(sequence.present, 'existing worker continues with the new session')
sequence.tick(0.3); sequence.tick(0.33)
check(sequence.focused==2 and sequence.spoon:status().state=='opening', 'second gesture confirms its own navigation and advances queue')
sequence.tick(0.36); sequence.tick(0.39); sequence.tick(0.42)
check(sequence.toggles==3 and sequence.focused==1 and sequence.spoon:status().state=='idle',
    'all three gestures finish without lost input or native replay')
local cancelled=fixture(); cancelled.begin(); cancelled.input(3,55,{}); cancelled.stuck=true; cancelled.tick(0.21)
cancelled.input(1,48,{cmd=true}); cancelled.input(2,48,{cmd=true}); cancelled.input(1,53,{cmd=true})
cancelled.present=false; cancelled.stuck=false; cancelled.tick(0.24); cancelled.tick(0.27)
check(cancelled.spoon:status().state=='idle' and cancelled.toggles==1, 'Escape cancels queued navigation before opening')
check(cancelled.input(2,53,{}), 'queued Escape release remains owned after cancellation')
local failed=fixture(); failed.begin(); failed.input(3,55,{}); failed.stuck=true; failed.tick(0.21)
failed.input(1,48,{cmd=true}); failed.tick(2)
check(not failed.spoon:status().suspended and #failed.spoon.queuedSessions==0, 'close failure drops queued gestures without disabling future input')
check(failed.input(2,48,{}), 'failed queue still consumes its matching key release')
local moving=fixture(); moving.motion=true; moving.begin()
moving.input(1,48,{cmd=true}); moving.input(2,48,{cmd=true}); moving.tick(0.3)
check(moving.spoon:status().state=='opening' and moving.spoon.run.target.id==3,
    'navigation updates the selected target while entry frames are still moving')
moving.input(3,55,{}); moving.tick(0.33)
check(moving.focused==3 and moving.toggles==1, 'release confirms without waiting for moving entry frames to settle')
local held=fixture(); held.begin(); held.input(3,55,{}); held.stuck=true; held.tick(0.21)
held.input(1,48,{cmd=true}); held.input(2,48,{cmd=true}); held.input(3,55,{})
held.input(1,48,{cmd=true}); held.input(2,48,{cmd=true})
held.present=false; held.stuck=false; held.tick(0.24)
held.input(1,48,{cmd=true}); held.input(2,48,{cmd=true}); held.input(3,55,{})
check(held.spoon.session.steps==1 and held.spoon.queuedSessions[1].steps==2
    and held.spoon.queuedSessions[1].released, 'navigation belongs to the latest held gesture while earlier gestures drain')
local early=fixture(); early.input(1,48,{cmd=true}); early.input(2,48,{cmd=true}); early.input(3,55,{})
early.input(1,48,{cmd=true}); early.input(2,48,{cmd=true}); early.input(3,55,{})
check(#early.spoon.queuedSessions==1 and early.spoon.session.steps==1,
    'two gestures before the first worker tick stay separate')
local skip=fixture(); skip.begin(); skip.input(3,55,{}); skip.stuck=true; skip.tick(0.21)
skip.input(1,48,{cmd=true}); skip.input(2,48,{cmd=true}); skip.input(1,53,{cmd=true})
skip.input(2,53,{cmd=true}); skip.input(3,55,{})
skip.input(1,48,{cmd=true}); skip.input(2,48,{cmd=true}); skip.input(3,55,{})
skip.present=false; skip.stuck=false; skip.tick(0.24); skip.tick(0.27)
skip.tick(0.3); skip.tick(0.33); skip.tick(0.36)
check(skip.toggles==2 and skip.focused==1 and skip.spoon:status().state=='idle',
    'cancelling one queued gesture preserves later independent gestures')
local interrupted=fixture(); interrupted.begin(); interrupted.input(3,55,{}); interrupted.stuck=true; interrupted.tick(0.21)
interrupted.input(1,48,{cmd=true}); interrupted.input(2,48,{cmd=true}); interrupted.input(3,55,{})
interrupted.spoon.sleepWatcher.callback(1)
interrupted.present=false; interrupted.tick(0.24)
check(interrupted.spoon:status().state=='idle' and #interrupted.spoon.queuedSessions==0,
    'global sleep interruption discards pending gestures')
local delayed=fixture(); delayed.hoverID=1; delayed.hoverReadyAt=0.7
delayed.begin(); delayed.ready()
delayed.input(1,48,{cmd=true}); delayed.input(2,48,{cmd=true}); delayed.tick(0.57)
check(delayed.pointer.x==325 and delayed.hoverID==1, 'navigation pointer placement can precede native hover readiness')
delayed.tick(0.8)
check(delayed.hoverID==3, 'stationary target receives native hover refresh after opening settles')
local posted=#delayed.posted
delayed.tick(1); delayed.tick(1.2)
check(#delayed.posted==posted, 'opening refresh ends without an endless event stream')
local f=fixture()
f.input(1,48,{cmd=true}); f.input(2,48,{cmd=true}); f.input(3,55,{})
check(f.spoon:status().state=='opening' and #f.posted==0, 'short press queues overview without native key replay')
check(not f.input(1,48,{cmd=true},0x4D544142), 'self-generated event never reenters')
f.tick(0.03)
check(f.present, 'short press opens on first worker tick without a hold delay')
f.ready(); f.tick(0.9); f.tick(1.2); f.tick(1.4); f.tick(1.6)
check(f.spoon:status().lastResult.matched and f.focused==2, 'short press confirms the overview target')
f=fixture(); f.input(1,48,{cmd=true}); f.input(3,55,{})
f.tick(0.03)
check(f.present, 'Command release before Tab release still opens overview')
check(f.input(2,48,{}), 'late Tab release consumed')
f=fixture(); f.begin(); f.input(3,55,{}); f.tick(0.21)
check(f.spoon:status().state=='closing' and f.focused==2, 'release during opening confirms at first candidate without waiting for layout')
f.tick(0.9); f.tick(1.2); f.tick(1.4); f.tick(1.6)
check(f.spoon:status().lastResult.matched and f.focused==2, 'early release commits exactly selected recent window')
check(f.toggles==1 and f.pointer.x==225, 'one toggle and pointer remains at the selected thumbnail')
f.input(1,48,{cmd=true}); f.input(2,48,{cmd=true}); f.input(3,55,{})
check(f.spoon:status().lastResult==nil, 'new short gesture clears the old selected target')
f=fixture(); f.begin(); f.ready(); f.input(1,50,{cmd=true}); f.input(2,50,{cmd=true}); f.tick(0.6)
f.input(3,55,{}); f.tick(0.9); f.tick(1.2); f.tick(1.4); f.tick(1.6)
check(f.focused==1, 'reverse navigation returns to original window')
f=fixture(); f.begin(); f.ready(); f.removed=2; f.input(3,55,{}); f.tick(0.9); f.tick(1.2); f.tick(1.4); f.tick(1.6)
check(f.spoon:status().lastResult.reason=='target-disappeared' and f.focused==1, 'missing target cancels and restores original')
for _, key in ipairs({13, 12}) do -- W / Q: native shortcut remains untouched.
    local closed=fixture(); closed.begin(); closed.ready()
    check(not closed.input(1,key,{cmd=true}) and not closed.input(2,key,{cmd=true}),
        'close shortcut passes through while Command remains held')
    closed.removed=2; closed.tick(0.6); closed.tick(0.63); closed.tick(0.66)
    check(closed.present and closed.toggles==0 and closed.spoon.run.target.id==3,
        'closing selected window keeps overview open and selects next survivor')
    closed.input(1,48,{cmd=true}); closed.input(2,48,{cmd=true}); closed.tick(0.69)
    check(closed.spoon.run.target.id==1, 'navigation continues through refreshed window order')
    closed.input(3,55,{}); closed.tick(0.72); closed.tick(0.75)
    check(closed.spoon:status().lastResult.matched and closed.focused==1,
        'Command release still confirms after closing a window')
end
for _, opening in ipairs({true, false}) do
    local last=fixture(); last.begin(); if not opening then last.ready() end
    last.empty=true; last.tick(0.6); last.tick(2)
    check(last.present and last.toggles==0 and not last.spoon.highlight
        and last.spoon.run.mouseSelection and not last.spoon.suspended,
        'closing all windows preserves overview during entry and navigation')
    last.empty=false; last.input(1,48,{cmd=true}); last.input(2,48,{cmd=true})
    last.tick(2.03); last.tick(2.06)
    check(last.spoon.run.target and not last.spoon.run.mouseSelection and last.toggles==0,
        'keyboard navigation resumes when windows become available again')
end
local otherClosed=fixture(); otherClosed.begin(); otherClosed.ready(); otherClosed.removed=3
otherClosed.tick(0.6)
check(otherClosed.spoon.run.target.id==2 and otherClosed.toggles==0,
    'closing another window preserves the current selection')
otherClosed.input(1,48,{cmd=true}); otherClosed.input(2,48,{cmd=true})
otherClosed.tick(0.63); otherClosed.tick(0.66); otherClosed.tick(0.69)
check(otherClosed.spoon.run.target.id==1 and otherClosed.toggles==0,
    'navigation skips a previously closed window without cancelling')
f=fixture(); f.begin(); f.ready(); f.input(1,53,{cmd=true}); f.tick(0.6); f.input(3,55,{}); f.tick(0.8); f.tick(1)
check(f.focused==1 and f.spoon:status().state=='idle', 'Esc cancels without later release committing')
f=fixture(); f.noOpen=true; f.begin(); f.tick(2); f.tick(3.6); f.tick(3.8)
check(f.spoon:status().suspended and f.spoon:status().state=='idle', 'overview that never appears cancels and suspends')
check(f.opens==2, 'unavailable overview gets at most one retry')
check(not f.input(1,48,{cmd=true}), 'suspended plugin preserves native shortcut')
f=fixture(); f.begin(); f.ready(); f.stuck=true; f.input(3,55,{}); f.tick(0.9); f.tick(1.2); f.tick(3)
check(not f.spoon:status().suspended and f.toggles==1, 'close timeout never blindly toggles twice or suspends input')
check(f.spoon:status().lastResult.reason=='close-timeout' and f.spoon:status().state=='idle'
    and not f.spoon.workTimer and not f.spoon.highlight, 'close timeout records failure and releases worker and overlay')
f.tick(4)
check(f.toggles==1, 'idle timeout recovery does not retry an old close request')
f.stuck=false
check(f.input(1,48,{cmd=true}), 'new gesture remains available after close timeout')
f.input(2,48,{cmd=true}); f.tick(4.03); f.input(3,55,{}); f.tick(4.06)
check(not f.present and f.toggles==2 and f.spoon:status().state=='idle',
    'new gesture dismisses the overview still open after timeout')
local recovered=fixture(); recovered.begin(); recovered.ready(); recovered.stuck=true
recovered.input(3,55,{}); recovered.tick(0.9); recovered.tick(3)
recovered.present=false; recovered.stuck=false -- User or delayed system animation closes it.
recovered.input(1,48,{cmd=true}); recovered.input(2,48,{cmd=true})
recovered.tick(3.03); recovered.tick(3.2); recovered.input(3,55,{})
recovered.tick(3.23); recovered.tick(3.26)
check(recovered.opens==2 and recovered.spoon:status().lastResult.reason=='committed'
    and recovered.spoon:status().lastResult.matched, 'fresh navigation succeeds after delayed external close')
f=fixture(); f.begin(); f.ready(); f.pid=8; f.tick(0.6); f.tick(0.8); f.tick(1)
check(f.spoon:status().lastResult.reason=='overview-replaced', 'process replacement cancels stale candidates')
f=fixture(); f.begin(); f.ready(); f.move({x=800,y=800}); f.tick(0.9)
check(f.spoon.run.mouseSelection and f.toggles==0 and f.present, 'mouse takeover keeps overview open')
check(f.pointer.x==800, 'pending hover refresh cannot reclaim the pointer after mouse takeover')
f=fixture(); f.begin(); f.ready(); f.present=false; f.tick(0.6); f.input(3,55,{})
check(f.toggles==0 and f.spoon:status().state=='idle', 'manual exit cannot be reopened on release')
f=fixture(); f.begin(); f.ready(); f.secure=true; f.spoon.health.callback(); f.tick(0.6); f.tick(0.8); f.tick(1)
check(f.spoon:status().suspended=='secure-input', 'secure input cancels active gesture')
f.secure=false; f.spoon.health.callback()
check(not f.spoon:status().suspended, 'secure input recovery restores availability')
f=fixture(); f.begin(); f.ready(); f.spoon:stop(); f.spoon.cleanup.callback(); f.time=0.8; f.spoon.cleanup.callback()
check(not f.spoon:status().running and f.focused==1 and f.pointer.x==900, 'stop releases input and restores desktop')
f=fixture(); f.input(1,48,{cmd=true}); f.tick(0.03); f.present=false; f.input(1,53,{cmd=true}); f.tick(0.22)
check(f.spoon:status().state=='cancelling', 'cancel waits for outstanding open request')
f.present=true; f.tick(0.5); f.tick(0.7); f.tick(0.9)
check(not f.present and f.toggles==1 and f.spoon:status().state=='idle', 'late overview is closed exactly once after Esc')
f=fixture(); f.input(1,48,{cmd=true}); f.tick(0.03); f.present=false; f.spoon:stop(); f.spoon.cleanup.callback()
check(f.spoon.cleanup~=nil, 'stop retains cleanup while open is outstanding')
f.present=true; f.spoon.cleanup.callback(); f.time=0.6; f.spoon.cleanup.callback(); f.time=0.8; f.spoon.cleanup.callback()
check(not f.present and f.toggles==1 and f.spoon.cleanup==nil, 'stop closes a late appearing overview and releases timer')
f=fixture(); f.begin(); f.ready(); f.input(3,55,{}); f.tick(0.9); f.tick(1.2); f.present=true; f.spoon:stop()
check(f.toggles==1, 'stop during closing does not issue a second toggle')
f=fixture(); f.input(1,48,{cmd=true}); f.tick(0.03); f.present=false; f.spoon:stop(); f.spoon:start()
check(not f.spoon:status().running and f.spoon.cleanup~=nil, 'restart waits for outstanding cleanup')
f.present=true; f.spoon.cleanup.callback(); f.time=0.6; f.spoon.cleanup.callback(); f.time=0.8; f.spoon.cleanup.callback()
check(f.spoon:status().running and not f.present, 'restart resumes only after old overview closes')
f=fixture(); f.begin(); f.ready(); f.input(1,48,{cmd=true}); f.input(2,48,{cmd=true}); f.tick(0.6)
f.input(3,55,{}); f.tick(0.9); f.tick(1.2); f.tick(1.4); f.tick(1.6)
check(f.focused==3, 'Tab advances spatially clockwise from the recent initial window')
f=fixture(); f.input(1,48,{cmd=true}); f.input(2,48,{cmd=true}); f.input(1,48,{cmd=true}); f.input(2,48,{cmd=true})
f.tick(0.03); f.tick(0.2); f.ready(); f.input(3,55,{}); f.tick(0.9); f.tick(1.2); f.tick(1.4); f.tick(1.6)
check(f.focused==3, 'queued Tab advances once after recent initial selection')

local opened=fixture(0.18); opened.present=true
opened.input(1,48,{cmd=true}); opened.input(2,48,{cmd=true}); opened.tick(0.03)
check(opened.toggles==1 and not opened.present, 'manual overview opens are dismissed without a health refresh')
local closed=fixture(0.18); closed.present=true; closed.spoon.health.callback(); closed.present=false
closed.input(1,48,{cmd=true}); closed.input(2,48,{cmd=true}); closed.input(3,55,{})
check(#closed.posted==4 and closed.spoon:status().lastResult.reason=='native-replay',
    'manual overview closes do not swallow a short switch')
local openedDuringHold=fixture(0.18)
openedDuringHold.input(1,48,{cmd=true}); openedDuringHold.input(2,48,{cmd=true}); openedDuringHold.tick(0.03)
openedDuringHold.present=true; openedDuringHold.tick(0.2)
check(openedDuringHold.toggles==1 and not openedDuringHold.present, 'overview opened during hold is dismissed')
local shortOpen=fixture(0.18); shortOpen.present=true
shortOpen.input(1,48,{cmd=true}); shortOpen.input(3,55,{})
check(shortOpen.toggles==1 and #shortOpen.posted==0, 'short switch dismisses an already open overview without native replay')
local deferred=fixture(0.18); deferred.deferReplay=true
deferred.input(1,48,{cmd=true}); deferred.input(3,55,{})
local callback=deferred.spoon.replayTimer.callback
check(#deferred.posted==0, 'replay checks run outside the event callback')
deferred.spoon:stop(); callback()
check(#deferred.posted==0, 'stop invalidates deferred replay')

local empty=fixture(); empty.empty=true; empty.begin(); empty.tick(2); empty.tick(2.1)
check(not empty.spoon:status().suspended and empty.spoon:status().lastResult.reason=='no-windows',
    'empty overview ends only the current gesture without suspending the plugin')
empty.empty=false; empty.time=3; empty.input(1,48,{cmd=true}); empty.input(2,48,{cmd=true})
empty.tick(3.03); empty.tick(3.06); empty.input(3,55,{}); empty.tick(3.09); empty.tick(3.12)
check(empty.spoon:status().lastResult.matched, 'next gesture works when windows become available')
local idle=fixture()
for _=1,100 do idle.spoon.health.callback() end
check(idle.snapshotCalls==0, 'idle health checks do not enumerate accessibility windows')
local stationary=fixture(); stationary.begin(); stationary.ready(); stationary.tick(0.9)
local updates, shows=stationary.canvas.frameUpdates, stationary.canvas.shows
for i=1,10 do stationary.tick(0.9+i*0.03) end
check(stationary.canvas.frameUpdates==updates and stationary.canvas.shows==shows,
    'unchanged selection does not send redundant native canvas updates')
local movingPoint=fixture(); movingPoint.begin(); movingPoint.ready(); movingPoint.tick(0.9)
movingPoint.input(1,48,{cmd=true}); movingPoint.input(2,48,{cmd=true}); movingPoint.tick(0.93)
movingPoint.motion=true
local points=movingPoint.pointCalls
movingPoint.tick(1)
check(movingPoint.pointCalls-points==1 and movingPoint.pointer.x==425,
    'moving target calculates one safe point and still moves the pointer to that point')
return {passed=true,assertions=count}
