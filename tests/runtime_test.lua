-- Exercise the real controller with deterministic system boundaries, without touching the desktop.
local root = debug.getinfo(1, 'S').source:sub(2):match('(.*/)') .. '../'
local count = 0
local function check(value, message) assert(value, message); count = count + 1 end
local function fixture()
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
        screen={watcher={new=watcher}},caffeinate={watcher={new=watcher,systemWillSleep=1,screensDidLock=2}},
        eventtap={new=function(_,fn) return watcher(fn) end,isSecureInputEnabled=function() return f.secure end},
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
    local mc = dofile(root .. 'MissionTab.spoon/mission_control.lua')
    function mc.snapshot()
        local out={present=f.present,backend='WindowManager',pid=f.pid or 7,candidates={}}
        if f.present and not f.empty then
            for id=1,3 do if id~=f.removed then
                out.candidates[#out.candidates+1]={id=id,element=id,frame={x=id*100,y=0,w=50,h=50},display={x=0,y=0}}
            end end
        end
        return out
    end
    local env=setmetatable({hs=hs,dofile=function(path)
        if path:match('mission_control.lua$') then return mc else return dofile(path) end
    end},{__index=_G})
    f.spoon=assert(loadfile(root .. 'MissionTab.spoon/init.lua','t',env))():start()
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
check(f.spoon:status().state=='idle' and #f.posted==4, 'short press synchronously emits one native sequence')
check(f.posted[1].props.tag==0x4D544142 and f.posted[4].flags.cmd==nil, 'replay tagged and Command released')
check(not f.input(1,48,{cmd=true},0x4D544142), 'self-generated event never reenters')
f.input(1,48,{cmd=true}); f.input(3,55,{})
check(#f.posted==8, 'second immediate chord is not swallowed by pending replay')
check(f.input(2,48,{}), 'late Tab release after replay consumed')
f=fixture(); f.begin(); f.input(3,55,{}); f.ready()
check(f.spoon:status().state=='committing', 'release during opening waits for candidate readiness')
f.tick(0.9); f.tick(1.2); f.tick(1.4); f.tick(1.6)
check(f.spoon:status().lastResult.matched and f.focused==2, 'early release commits exactly selected recent window')
check(f.toggles==1 and f.pointer.x==225, 'one toggle and pointer centred on confirmed window')
f.input(1,48,{cmd=true}); f.input(2,48,{cmd=true}); f.input(3,55,{})
check(f.spoon:status().lastResult.target==nil, 'short replay does not report an old selected target')
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
f=fixture(); f.begin(); f.present=false; f.input(1,53,{cmd=true}); f.tick(0.22)
check(f.spoon:status().state=='cancelling', 'cancel waits for outstanding open request')
f.present=true; f.tick(0.5); f.tick(0.7); f.tick(0.9)
check(not f.present and f.toggles==1 and f.spoon:status().state=='idle', 'late overview is closed exactly once after Esc')
f=fixture(); f.begin(); f.present=false; f.spoon:stop(); f.spoon.cleanup.callback()
check(f.spoon.cleanup~=nil, 'stop retains cleanup while open is outstanding')
f.present=true; f.spoon.cleanup.callback(); f.time=0.6; f.spoon.cleanup.callback(); f.time=0.8; f.spoon.cleanup.callback()
check(not f.present and f.toggles==1 and f.spoon.cleanup==nil, 'stop closes a late appearing overview and releases timer')
f=fixture(); f.begin(); f.ready(); f.input(3,55,{}); f.tick(0.9); f.tick(1.2); f.present=true; f.spoon:stop()
check(f.toggles==1, 'stop during closing does not issue a second toggle')
f=fixture(); f.begin(); f.present=false; f.spoon:stop(); f.spoon:start()
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
