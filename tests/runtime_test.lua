-- Exercise the real controller with deterministic system boundaries, without touching the desktop.
local root = debug.getinfo(1, 'S').source:sub(2):match('(.*/)') .. '../'
local count = 0
local function check(value, message) assert(value, message); count = count + 1 end
local function fixture(holdDelay)
    local f = { time = 0, present = false, focused = 1, pointer = {x=900,y=900}, posted = {}, toggles = 0 }
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
        timer={absoluteTime=function() return f.time*1e9 end, doEvery=function(_,fn) return watcher(fn):start() end},
        logger={new=function() return {w=function() end,e=function(err) error(err) end} end},
        inspect=tostring, keycodes={map={tab=48,escape=53,['`']=50}},
        accessibilityState=function() return true end,
        mouse={getCurrentScreen=function() return {id=function() return 1 end,
            fullFrame=function() return {x=0,y=0,w=1000,h=1000} end} end, absolutePosition=function(p) if p then f.pointer=p end; return f.pointer end},
        window={get=win,focusedWindow=function() return win(f.focused) end,orderedWindows=function() return {win(1),win(2),win(3)} end},
        spaces={openMissionControl=function() f.present=true end,toggleMissionControl=function()
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
        local canvas={bounds=frame}
        function canvas:level(value) self.windowLevel=value; return self end
        function canvas:behavior(value) self.behaviors=value; return self end
        function canvas:clickActivating(value) self.activates=value; return self end
        function canvas:canvasMouseEvents(...) self.mouseEvents={...}; return self end
        function canvas:mouseCallback(value) self.callback=value; return self end
        function canvas:appendElements(value) self.element=value; return self end
        function canvas:frame(value) self.bounds=value; return self end
        function canvas:show() self.visible=true; return self end
        function canvas:delete() self.deleted=true; self.visible=false end
        f.canvas=canvas
        return canvas
    end}
    local mc = dofile(root .. 'MissionTab.spoon/mission_control.lua')
    function mc.snapshot()
        local out={present=f.present,backend='WindowManager',pid=f.pid or 7,candidates={}}
        if f.present and not f.empty then
            for id=1,3 do if id~=f.removed then
                out.candidates[#out.candidates+1]={id=id,element=id,frame={x=id*100+(f.motion and f.time*100 or 0),y=0,w=50,h=50},display={x=0,y=0}}
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
        return f.spoon:_event(e)
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
local native=fixture(0.18)
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
check(canvas and canvas.visible and canvas.bounds.x==222 and canvas.element.fillColor.alpha==0.20,
    'selected thumbnail gets an inset translucent highlight during entry')
check(not canvas.activates and not canvas.callback and not canvas.mouseEvents[1],
    'highlight does not activate Hammerspoon or capture native pointer input')
mask.input(1,48,{cmd=true}); mask.input(2,48,{cmd=true}); mask.tick(0.3)
check(mask.canvas==canvas and canvas.bounds.x==332, 'one canvas follows selection and moving entry geometry')
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
check(mouseMask.spoon.highlight and mouseMask.canvas.bounds.x==302,
    'mouse takeover highlights the hovered thumbnail')
check(mouseMask.pointer.x==325 and #mouseMask.posted==postedBeforeMouse,
    'mouse highlight does not warp pointer or synthesize hover events')
mouseMask.move({x=125,y=25}); mouseMask.tick(0.63)
check(mouseMask.canvas.bounds.x==102, 'mouse highlight follows a different thumbnail')
mouseMask.move({x=800,y=800}); mouseMask.tick(0.66)
check(not mouseMask.spoon.highlight, 'blank space hides highlight instead of selecting nearest thumbnail')
mouseMask.move({x=225,y=25}); mouseMask.tick(0.69)
check(mouseMask.spoon.highlight, 'hovering a thumbnail again restores highlight')
mouseMask.input(3,55,{}); mouseMask.tick(0.72)
check(not mouseMask.spoon.highlight and mouseMask.toggles==1,
    'mouse confirmation hides highlight while preserving native exit')
local openingMouse=fixture(); openingMouse.motion=true; openingMouse.begin()
openingMouse.move({x=245,y=25}); openingMouse.tick(0.3)
check(openingMouse.spoon:status().state=='opening' and openingMouse.canvas.bounds.x==232,
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
check(failed.spoon:status().suspended and #failed.spoon.queuedSessions==0, 'close failure drops queued gestures')
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
check(delayed.pointer.x==225 and delayed.hoverID==1, 'early pointer placement can precede native hover readiness')
delayed.tick(0.8)
check(delayed.hoverID==2, 'stationary target receives native hover refresh after opening settles')
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
check(f.toggles==1 and f.pointer.x==225, 'one toggle and pointer centred on confirmed window')
f.input(1,48,{cmd=true}); f.input(2,48,{cmd=true}); f.input(3,55,{})
check(f.spoon:status().lastResult==nil, 'new short gesture clears the old selected target')
f=fixture(); f.begin(); f.ready(); f.input(1,50,{cmd=true}); f.input(2,50,{cmd=true}); f.tick(0.6)
f.input(3,55,{}); f.tick(0.9); f.tick(1.2); f.tick(1.4); f.tick(1.6)
check(f.focused==1, 'reverse navigation returns to original window')
f=fixture(); f.begin(); f.ready(); f.removed=2; f.input(3,55,{}); f.tick(0.9); f.tick(1.2); f.tick(1.4); f.tick(1.6)
check(f.spoon:status().lastResult.reason=='target-disappeared' and f.focused==1, 'missing target cancels and restores original')
f=fixture(); f.begin(); f.ready(); f.input(1,53,{cmd=true}); f.tick(0.6); f.input(3,55,{}); f.tick(0.8); f.tick(1)
check(f.focused==1 and f.spoon:status().state=='idle', 'Esc cancels without later release committing')
f=fixture(); f.empty=true; f.begin(); f.tick(2); f.tick(2.2); f.tick(2.4)
check(f.spoon:status().suspended and f.spoon:status().state=='idle', 'unknown structure cancels and suspends')
check(not f.input(1,48,{cmd=true}), 'suspended plugin preserves native shortcut')
f=fixture(); f.begin(); f.ready(); f.stuck=true; f.input(3,55,{}); f.tick(0.9); f.tick(1.2); f.tick(3)
check(f.spoon:status().suspended and f.toggles==1, 'close timeout never blindly toggles twice')
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
return {passed=true,assertions=count}
