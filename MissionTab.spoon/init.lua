--- === MissionTab ===
--- Short Command-Tab switches applications; hold Command to navigate Mission Control.
local obj = { name = 'MissionTab', version = '0.1.2', author = 'zuozhi', license = 'MIT' }
local directory = debug.getinfo(1, 'S').source:sub(2):match('(.*/)')
local Session = dofile(directory .. 'session.lua')
local MC = dofile(directory .. 'mission_control.lua')
local event = hs.eventtap.event
local types, properties = event.types, event.properties
local marker = 0x4D544142
local function now() return hs.timer.absoluteTime() / 1e9 end
local function tagged(e) return e:setProperty(properties.eventSourceUserData, marker) end
local function distance(a, b) return math.abs(a.x - b.x) + math.abs(a.y - b.y) end

obj.holdDelay = 0.18
obj.openTimeout = 1.5
obj.hoverDelay = 0.25
obj.closeTimeout = 1.5
obj.log = hs.logger.new('MissionTab', 'info')

function obj:status()
    return { running = self.running == true, state = self.session and self.session.mode or 'idle',
        suspended = self.suspended, lastResult = self.lastResult }
end

-- Read-only when MC is closed; manually open MC first for a useful snapshot.
function obj:diagnose()
    local snapshot = MC.snapshot()
    local output = { present = snapshot.present, backend = snapshot.backend, windows = {},
        version = hs.processInfo.version, os = hs.host.operatingSystemVersionString() }
    for _, candidate in ipairs(snapshot.candidates) do
        output.windows[#output.windows + 1] = { id = candidate.id, frame = candidate.frame }
    end
    return output
end

function obj:_finish(reason)
    local run = self.run
    if run and run.ownsMC then self.overviewOpen = MC.snapshot().present end
    if run and run.pointerMoved and not run.userPointer and run.pointer
        and not self.overviewOpen then
        hs.mouse.absolutePosition(run.pointer)
    end
    if run and run.restoreFocus and run.original and not self.overviewOpen then
        pcall(function() run.original:focus() end)
    end
    self.lastResult = self.lastResult or {}
    self.lastResult.reason = reason
    self.run = nil
    self.session:reset()
    if self.workTimer then self.workTimer:stop(); self.workTimer = nil end
end

function obj:_cancel(reason)
    local run = self.run
    if not run or not run.ownsMC then self:_finish(reason); return end
    if not MC.snapshot().present then
        -- AX can appear after the request has already been cancelled. Keep ownership
        -- until that outstanding open either becomes visible or reaches its deadline.
        if not run.sawMC and now() - run.openedAt < self.openTimeout then
            run.cancelReason = reason
            self.session.mode = 'cancelling'
            return
        end
        self:_finish(reason)
        return
    end
    run.restoreFocus = true
    if not run.closing then
        hs.spaces.toggleMissionControl()
        run.closing = now()
    end
    run.cancelReason = reason
    self.session.mode = 'closing'
end

function obj:_hover(target, time, snapshot)
    local point = MC.point(snapshot, target)
    if not point then self:_cancel('target-occluded'); return false end
    self.run.pointerMoved, self.run.lastPointer = true, point
    hs.mouse.absolutePosition(point)
    tagged(event.newMouseEvent(types.mouseMoved, point):setFlags({})):post()
    self.run.hoveredAt = time
    return true
end

function obj:_replay(remainingFlags)
    -- Emit inside the release callback, so a second fast chord cannot overtake this one.
    tagged(event.newKeyEvent('cmd', true)):post()
    for _, direction in ipairs(self.session.directions) do
        if direction < 0 then tagged(event.newKeyEvent('shift', true)):post() end
        local mods = direction < 0 and { 'cmd', 'shift' } or { 'cmd' }
        tagged(event.newKeyEvent(mods, 'tab', true)):post()
        tagged(event.newKeyEvent(mods, 'tab', false)):post()
        if direction < 0 then tagged(event.newKeyEvent('shift', false)):post() end
    end
    tagged(event.newKeyEvent('cmd', false):setFlags(remainingFlags or {})):post()
    self:_finish('native-replay')
end

function obj:_tick()
    local s, time = self.session, now()
    if s.mode == 'idle' then return end
    if s.mode == 'replay' then self:_replay(); return end
    if not self.run then
        local original = hs.window.focusedWindow()
        local ordered = {}
        for _, window in ipairs(hs.window.orderedWindows()) do ordered[#ordered + 1] = window:id() end
        self.run = { original = original, originalID = original and original:id(), order = ordered,
            pointer = hs.mouse.absolutePosition(), serial = s.serial }
        self.lastResult = nil
    end
    local run = self.run
    if s.mode == 'cancelling' then self:_cancel('cancelled'); return end
    s:advance(time)
    if s.mode == 'pending' then return end
    local snapshot = MC.snapshot()
    if snapshot.present and run.ownsMC then run.sawMC = true end
    if s.mode == 'dismissing' then
        if not snapshot.present then self:_finish('already-closed'); return end
        run.openedAt, run.ownsMC, run.sawMC = time, true, true
        hs.spaces.toggleMissionControl()
        run.closing, s.mode = time, 'closing'
        return
    end
    if s.mode == 'opening' then
        if not run.openedAt then
            if snapshot.present then self:_finish('already-open'); return end
            run.openedAt, run.ownsMC = time, true
            hs.spaces.openMissionControl()
            return
        end
        if time - run.openedAt > self.openTimeout then
            self.suspended = 'Mission Control did not expose usable windows; call start() to retry'
            self:_cancel('open-timeout')
            return
        end
        -- A stable AX frame can precede the visible animation finishing. Require a short floor.
        if time - run.openedAt >= 0.25 and MC.stable(run.previous, snapshot) then
            run.candidates, run.base = MC.order(snapshot.candidates, run.order, run.originalID)
            run.backend, run.pid = snapshot.backend, snapshot.pid
            s.mode = 'navigating'
        else
            run.previous = snapshot
            return
        end
    end
    if s.mode == 'closing' then
        if not snapshot.present then
            -- Let focus settle after the AX overview disappears.
            run.goneAt = run.goneAt or time
            if time - run.goneAt < 0.15 then return end
            if not run.cancelReason then
                local focused = hs.window.focusedWindow()
                local actual = focused and focused:id()
                self.lastResult = { target = run.target and run.target.id, actual = actual,
                    matched = run.target and run.target.id ~= nil and run.target.id == actual,
                    elapsed = time - s.started }
                if self.lastResult.target and not self.lastResult.matched then
                    self.log.w('Focus differs from selected window: ' .. hs.inspect(self.lastResult))
                end
            end
            self:_finish(run.cancelReason or 'committed')
        elseif time - run.closing > self.closeTimeout then
            self.suspended = 'Mission Control did not close; call start() to retry'
            self:_finish('close-timeout') -- No repeated toggle or click at an uncertain coordinate.
        end
        return
    end
    if not snapshot.present then self:_finish('external-exit'); return end
    if snapshot.backend ~= run.backend or snapshot.pid ~= run.pid then
        self:_cancel('overview-replaced'); return
    end
    if run.mouseSelection then
        if #s.directions ~= run.mouseKeyCount then
            -- A new navigation key returns control to the frozen keyboard order.
            run.mouseSelection, run.index = false, nil
            s.mode = 'navigating'
        else
            if s.released then
                run.target = nil -- The system chooses the window under the real pointer.
                hs.spaces.toggleMissionControl()
                run.closing, s.mode = time, 'closing'
            end
            return
        end
    end
    if s.mode == 'navigating' then
        -- The first Tab opens at the recent window. Only later keys move around the layout.
        local offset = s.steps - s.directions[1]
        local index = ((run.base - 1 + offset) % #run.candidates) + 1
        local target = MC.find(snapshot, run.candidates[index])
        if not target then self:_cancel('target-disappeared'); return end
        local point = MC.point(snapshot, target)
        if not point then self:_cancel('target-occluded'); return end
        if run.index ~= index or not run.lastPointer or distance(run.lastPointer, point) > 2 then
            run.index, run.target = index, target
            if not self:_hover(target, time, snapshot) then return end
        end
        if s.released then s.mode = 'committing' end
    end
    if s.mode == 'committing' then
        local target = MC.find(snapshot, run.target)
        if not target then self:_cancel('target-disappeared'); return end
        local point = MC.point(snapshot, target)
        if not point then self:_cancel('target-occluded'); return end
        if distance(point, run.lastPointer) > 2 then
            run.target = target
            if not self:_hover(target, time, snapshot) then return end
        end
        if time - run.hoveredAt < self.hoverDelay then return end
        hs.spaces.toggleMissionControl()
        run.closing, s.mode = time, 'closing'
    end
end

function obj:_safeTick()
    local ok, err = xpcall(function() self:_tick() end, debug.traceback)
    if not ok then
        self.log.e(err)
        self.suspended = 'Runtime error; inspect MissionTab log and call start()'
        -- Stop owning input immediately. Do not guess a click or toggle after an AX error.
        self.run = nil
        self.session:reset()
        if self.workTimer then self.workTimer:stop(); self.workTimer = nil end
    end
end

function obj:_event(e)
    if e:getProperty(properties.eventSourceUserData) == marker then return false end
    local kind = e:getType()
    if kind == types.mouseMoved or kind == types.leftMouseDown or kind == types.rightMouseDown then
        if self.run and self.run.ownsMC then
            -- Mouse movement changes the selection source, not Command's ownership.
            local motion = math.abs(e:getProperty(properties.mouseEventDeltaX))
                + math.abs(e:getProperty(properties.mouseEventDeltaY))
            local active = self.session.mode == 'opening' or self.session.mode == 'navigating'
                or self.session.mode == 'committing'
            if active and (kind ~= types.mouseMoved or (motion > 0 and (not self.run.lastPointer
                or distance(e:location(), self.run.lastPointer) > 3))) then
                self.run.userPointer = true
                self.run.mouseSelection = true
                self.run.mouseKeyCount = #self.session.directions
            end
        end
        return false
    end
    local keyCode = e:getKeyCode()
    local key = keyCode == hs.keycodes.map.tab and 'tab'
        or keyCode == self.reverseKeyCode and 'grave'
        or keyCode == hs.keycodes.map.escape and 'escape' or tostring(keyCode)
    local inputKind = kind == types.flagsChanged and 'flags' or kind == types.keyUp and 'up' or 'down'
    if self.session.mode == 'idle' and self.suspended then
        -- Still consume a matching release from a previously owned key-down.
        if inputKind == 'up' and self.session.swallowed[key] then
            self.session.swallowed[key] = nil
            return true
        end
        return false
    end
    local previousSerial = self.session.serial
    local wasIdle = self.session.mode == 'idle'
    local consumed = self.session:handle(inputKind, key, e:getFlags(),
        e:getProperty(properties.keyboardEventAutorepeat) == 1, now())
    if self.session.serial ~= previousSerial then
        self.lastResult = nil
        if wasIdle and self.overviewOpen then self.session.mode = 'dismissing' end
    end
    if self.session.mode == 'replay' then self:_replay(e:getFlags()); return consumed end
    if self.session.mode ~= 'idle' and not self.workTimer then
        local session, serial = self.session, self.session.serial
        self.workTimer = hs.timer.doEvery(0.03, function()
            if self.session == session and session.serial == serial then self:_safeTick() end
        end)
    end
    return consumed
end

function obj:start()
    if self.running then self:stop() end
    if self.cleanup then self.restartAfterCleanup = true; return self end
    assert(self.holdDelay >= 0 and self.openTimeout > 0 and self.hoverDelay >= 0 and self.closeTimeout > 0,
        'MissionTab timing values must be nonnegative (timeouts must be positive)')
    self.session, self.suspended = Session.new(self.holdDelay), nil
    self.reverseKeyCode = self.reverseKeyCode or hs.keycodes.map['`'] or 50
    if not hs.accessibilityState() then self.suspended = 'Accessibility permission required'; return self end
    self.overviewOpen = MC.snapshot().present
    self.tap = hs.eventtap.new({ types.keyDown, types.keyUp, types.flagsChanged,
        types.mouseMoved, types.leftMouseDown, types.rightMouseDown }, function(e) return self:_event(e) end):start()
    self.running = true
    self.health = hs.timer.doEvery(0.5, function()
        if not self.running then return end
        if hs.eventtap.isSecureInputEnabled() then
            if self.session.mode ~= 'idle' then self.session.mode = 'cancelling' end
            self.suspended = 'secure-input'
        elseif self.suspended == 'secure-input' then self.suspended = nil end
        if not self.tap:isEnabled() then
            if self.session.mode ~= 'idle' then self.session.mode = 'cancelling' end
            self.tap:start()
        end
        local ok, snapshot = pcall(MC.snapshot)
        if ok then self.overviewOpen = snapshot.present end
    end)
    self.screenWatcher = hs.screen.watcher.new(function()
        if self.session.mode ~= 'idle' then self.session.mode = 'cancelling' end
    end):start()
    self.sleepWatcher = hs.caffeinate.watcher.new(function(kind)
        if kind == hs.caffeinate.watcher.systemWillSleep or kind == hs.caffeinate.watcher.screensDidLock then
            if self.session.mode ~= 'idle' then self.session.mode = 'cancelling' end
        end
    end):start()
    return self
end

function obj:stop()
    self.restartAfterCleanup = false
    if self.tap then self.tap:stop(); self.tap = nil end
    for _, key in ipairs({ 'health', 'workTimer', 'screenWatcher', 'sleepWatcher' }) do
        if self[key] then self[key]:stop(); self[key] = nil end
    end
    local run = self.run
    if run and run.ownsMC then
        local ok, snapshot = pcall(MC.snapshot)
        local seen = run.sawMC or (ok and snapshot.present)
        local closeSent = run.closing ~= nil
        if ok and snapshot.present and not closeSent then
            hs.spaces.toggleMissionControl()
            closeSent = true
        end
        -- This bounded cleanup owns no input. A restart waits for the old request.
        local openDeadline = run.openedAt + self.openTimeout
        local deadline = math.max(now(), openDeadline) + self.closeTimeout
        local goneAt
        self.cleanup = hs.timer.doEvery(0.03, function()
            local valid, current = pcall(MC.snapshot)
            if valid and current.present then
                seen, goneAt = true, nil
                if not closeSent then hs.spaces.toggleMissionControl(); closeSent = true end
            elseif valid and (seen or now() >= openDeadline) then
                goneAt = goneAt or now()
                if now() - goneAt < 0.15 then return end
                if run.pointerMoved and not run.userPointer then hs.mouse.absolutePosition(run.pointer) end
                if run.original then pcall(function() run.original:focus() end) end
                self.cleanup:stop(); self.cleanup = nil
            end
            if self.cleanup and now() > deadline then
                self.cleanup:stop(); self.cleanup = nil
            end
            if not self.cleanup and self.restartAfterCleanup then
                self.restartAfterCleanup = false
                self:start()
            end
        end)
    end
    self.run = nil
    if self.session then self.session:reset() end
    self.running = false
    return self
end

return obj
