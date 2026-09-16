--- === MissionTab ===
--- Short Command-Tab switches applications; hold Command to navigate Mission Control.
local obj = { name = 'MissionTab', version = '0.2.2', author = 'zuozhi', license = 'MIT' }
local directory = debug.getinfo(1, 'S').source:sub(2):match('(.*/)')
local Session = dofile(directory .. 'session.lua')
local MC = dofile(directory .. 'mission_control.lua')
local event = hs.eventtap.event
local types, properties = event.types, event.properties
local marker = 0x4D544142
local function now() return hs.timer.absoluteTime() / 1e9 end
local function tagged(e) return e:setProperty(properties.eventSourceUserData, marker) end
local function frameChanged(a, b)
    if not a then return true end
    for _, key in ipairs({ 'x', 'y', 'w', 'h' }) do
        if math.abs(a[key] - b[key]) > 2 then return true end
    end
    return false
end

obj.holdDelay = 0.18
obj.openTimeout = 1.5
obj.hoverDelay = 0.25 -- Legacy option name: minimum selection preview time, no mouse hover.
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
    self:_hidePreview()
    local run = self.run
    if run and run.ownsMC then self.overviewOpen = MC.snapshot().present end
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
    self:_hidePreview()
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

function obj:_hidePreview()
    if self.preview then self.preview:delete(); self.preview = nil end
end

function obj:_preview(target, time)
    self:_hidePreview()
    local frame = target.frame
    self.preview = hs.canvas.new(frame)
        :behavior({ 'canJoinAllSpaces', 'stationary' })
        :level(hs.canvas.windowLevels.screenSaver):clickActivating(false)
    -- No mouse callback: the overlay is click-through and never owns input.
    self.preview:appendElements({
        type = 'rectangle', action = 'stroke', strokeWidth = 5,
        strokeColor = { red = 0, green = 0.9, blue = 1, alpha = 1 },
        frame = { x = 3, y = 3, w = math.max(1, frame.w - 6), h = math.max(1, frame.h - 6) },
    }):show()
    self.run.previewFrame = { x = frame.x, y = frame.y, w = frame.w, h = frame.h }
    self.run.previewedAt = time
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
        local screen = hs.mouse.getCurrentScreen()
        if not screen then self:_finish('pointer-screen-unavailable'); return end
        self.run = { original = original, serial = s.serial,
            screenID = screen:id(), screenFrame = screen:fullFrame(),
            pointer = hs.mouse.absolutePosition(), stepOrigin = s.directions[1] }
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
        -- Preview as soon as AX exposes a usable frame; keep following it during animation.
        -- Stabilization only freezes the clockwise order and permits confirmation.
        local scoped = MC.onScreen(snapshot, run.screenID, run.screenFrame)
        local candidates, base = MC.order(scoped.candidates)
        if base then base = MC.pointerIndex(scoped, candidates, run.pointer) end
        if base and not run.mouseSelection then
            local offset = s.steps - run.stepOrigin
            local index = ((base - 1 + offset) % #candidates) + 1
            local target = candidates[index]
            if not run.target or run.target.id ~= target.id
                or frameChanged(run.previewFrame, target.frame) then
                run.index, run.target = index, target
                if not self:_preview(target, time) then return end
            end
        end
        if MC.stable(run.previous, scoped) then
            run.candidates, run.base = candidates, base
            run.backend, run.pid = snapshot.backend, snapshot.pid
            s.mode = 'navigating'
        else
            run.previous = scoped
            return
        end
    end
    if s.mode == 'closing' then
        if not snapshot.present then
            self:_hidePreview()
            if run.focusTarget and not run.focusApplied then
                run.focusApplied = true
                if not run.focusTarget:id() then self:_finish('target-disappeared'); return end
                run.focusTarget:focus()
                run.goneAt = now()
                return
            end
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
        if s.released then
            run.target = nil -- The system confirms the user's mouse selection.
            hs.spaces.toggleMissionControl()
            run.closing, s.mode = time, 'closing'
        end
        return
    end
    if s.mode == 'navigating' then
        -- The first navigation key selects the pointer target; later keys walk the frozen order.
        local offset = s.steps - run.stepOrigin
        local index = ((run.base - 1 + offset) % #run.candidates) + 1
        local target = MC.find(MC.onScreen(snapshot, run.screenID, run.screenFrame), run.candidates[index])
        if not target then self:_cancel('target-disappeared'); return end
        if run.index ~= index or frameChanged(run.previewFrame, target.frame) then
            run.index, run.target = index, target
            if not self:_preview(target, time) then return end
        end
        if s.released then s.mode = 'committing' end
    end
    if s.mode == 'committing' then
        local target = MC.find(MC.onScreen(snapshot, run.screenID, run.screenFrame), run.target)
        if not target then self:_cancel('target-disappeared'); return end
        if frameChanged(run.previewFrame, target.frame) then
            run.target = target
            if not self:_preview(target, time) then return end
        end
        if time - run.previewedAt < self.hoverDelay then return end
        run.focusTarget = target.id and hs.window.get(target.id)
        if not run.focusTarget then self:_cancel('target-unavailable'); return end
        self:_hidePreview()
        hs.spaces.toggleMissionControl()
        run.closing, s.mode = time, 'closing'
    end
end

function obj:_safeTick()
    local ok, err = xpcall(function() self:_tick() end, debug.traceback)
    if not ok then
        self:_hidePreview()
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
    if kind == types.mouseMoved then
        local run, mode = self.run, self.session.mode
        local motion = math.abs(e:getProperty(properties.mouseEventDeltaX))
            + math.abs(e:getProperty(properties.mouseEventDeltaY))
        if run and run.ownsMC and motion > 0
            and (mode == 'opening' or mode == 'navigating' or mode == 'committing') then
            run.mouseSelection = true
            self:_hidePreview()
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
    local previousKeyCount = #(self.session.directions or {})
    local previousSerial = self.session.serial
    local wasIdle = self.session.mode == 'idle'
    local consumed = self.session:handle(inputKind, key, e:getFlags(),
        e:getProperty(properties.keyboardEventAutorepeat) == 1, now())
    if self.run and self.run.mouseSelection
        and #(self.session.directions or {}) ~= previousKeyCount then
        local screen = hs.mouse.getCurrentScreen()
        if not screen then self.session.mode = 'cancelling'
        else
            local run = self.run
            run.screenID, run.screenFrame = screen:id(), screen:fullFrame()
            run.pointer, run.stepOrigin = hs.mouse.absolutePosition(), self.session.steps
            run.mouseSelection, run.index, run.target, run.previous = false, nil, nil, nil
            run.openedAt = now()
            self.session.mode = 'opening'
        end
    end
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
    self.tap = hs.eventtap.new({ types.keyDown, types.keyUp, types.flagsChanged, types.mouseMoved }, function(e) return self:_event(e) end):start()
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
    self:_hidePreview()
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
