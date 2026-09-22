--- === MissionTab ===
--- Short Command-Tab switches applications; hold Command to navigate Mission Control.
local obj = { name = 'MissionTab', version = '0.2.35', author = 'zuozhi', license = 'MIT' }
local directory = debug.getinfo(1, 'S').source:sub(2):match('(.*/)')
local Session = dofile(directory .. 'session.lua')
local MC = dofile(directory .. 'mission_control.lua')
local event = hs.eventtap.event
local types, properties = event.types, event.properties
local marker = 0x4D544142
local function now() return hs.timer.absoluteTime() / 1e9 end
local function tagged(e) return e:setProperty(properties.eventSourceUserData, marker) end
local function hoverChanged(run, point)
    return not point or not run.lastPointer
        or math.abs(point.x - run.lastPointer.x) + math.abs(point.y - run.lastPointer.y) > 2
end

-- Dock visibility can notify screen watchers without changing thumbnail coordinates.
local function screenLayout()
    local screens = {}
    for _, screen in ipairs(hs.screen.allScreens()) do
        local frame = screen:fullFrame()
        screens[#screens + 1] = string.format('%s:%g,%g,%g,%g',
            screen:id(), frame.x, frame.y, frame.w, frame.h)
    end
    table.sort(screens)
    return table.concat(screens, ';')
end

local function restorePointer(run)
    if run and run.pointerMoved and not run.userPointer then
        hs.mouse.absolutePosition(run.pointer)
        run.pointerMoved = false
    end
end

-- Resolve only the selected window's process. hs.window.get() and orderedWindows()
-- enumerate every application through AX; one slow app can disable our event tap.
local function windowForID(id)
    if not id then return nil end
    local pid
    for _, window in ipairs(hs.window.list()) do
        if window.kCGWindowNumber == id then pid = window.kCGWindowOwnerPID; break end
    end
    if not pid then return nil end
    local root = hs.axuielement.applicationElementForPID(pid)
    if not root then return nil end
    local deadline = now() + 0.2
    root:setTimeout(0.05)
    for _, element in ipairs(root:attributeValue('AXWindows') or {}) do
        if now() >= deadline then return nil end
        element:setTimeout(0.05)
        local window = element:asHSWindow()
        if window and window:id() == id then return window end
    end
end

-- Stacking order can raise an application's other windows without focusing them.
-- Observe only the frontmost application; never enumerate all AX windows for MRU.
function obj:_rememberFocus(root)
    if not self.running or self.run then return end
    local element = root:attributeValue('AXFocusedWindow')
    if not element then return end
    element:setTimeout(0.05)
    local window = element:asHSWindow()
    local id = window and window:id()
    if not id then return end
    for i, recentID in ipairs(self.focusHistory) do
        if recentID == id then table.remove(self.focusHistory, i); break end
    end
    table.insert(self.focusHistory, 1, id)
    -- Bound stale IDs from closed windows without subscribing to every application.
    self.focusHistory[129] = nil
end

function obj:_watchFocus()
    if self.focusObserver then self.focusObserver:stop(); self.focusObserver = nil end
    local app = hs.application.frontmostApplication()
    if not app then return end
    local pid = app:pid()
    local root = hs.axuielement.applicationElementForPID(pid)
    if not root then return end
    root:setTimeout(0.05)
    self:_rememberFocus(root)
    -- Some applications do not support AX notifications. Keep the recorded focus
    -- and retry on their next activation rather than breaking keyboard navigation.
    local ok, err = pcall(function()
        local observer = hs.axuielement.observer.new(pid)
        self.focusObserver = observer
        observer:callback(function(source)
            local front = hs.application.frontmostApplication()
            if self.focusObserver == source and front and front:pid() == pid then
                self:_rememberFocus(root)
            end
        end):addWatcher(root, 'AXFocusedWindowChanged'):start()
    end)
    if not ok then
        if self.focusObserver then self.focusObserver:stop(); self.focusObserver = nil end
        self.log.w('Cannot observe focused window: ' .. tostring(err))
    end
end

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

-- Visual feedback only: no mouse callback or tracking, so native hover/clicks pass through.
function obj:_highlight(target)
    if not target then
        if self.highlight then self.highlight:delete(); self.highlight = nil end
        self.highlightFrame, self.highlightScreen = nil, nil
        return
    end
    local frame = target.frame
    local previous = self.highlightFrame
    if previous and previous.x == frame.x and previous.y == frame.y
        and previous.w == frame.w and previous.h == frame.h then return end
    local screen = hs.mouse.getCurrentScreen():fullFrame()
    local oldScreen = self.highlightScreen
    if self.highlight and (oldScreen.x ~= screen.x or oldScreen.y ~= screen.y
        or oldScreen.w ~= screen.w or oldScreen.h ~= screen.h) then
        self.highlight:delete()
        self.highlight = nil
    end
    -- Keep the native overlay window still: Mission Control can animate window moves
    -- independently of AX geometry. Only redraw the rectangle inside this screen canvas.
    local drawingFrame = { x = frame.x - screen.x, y = frame.y - screen.y, w = frame.w, h = frame.h }
    if not self.highlight then
        self.highlight = hs.canvas.new(screen):level('overlay')
            :behavior({ 'canJoinAllSpaces', 'stationary' }):clickActivating(false)
            :canvasMouseEvents(false, false, false, false):mouseCallback(nil)
        self.highlight:appendElements({ type = 'rectangle', action = 'fill', frame = drawingFrame,
            fillColor = { red = 0.2, green = 0.55, blue = 1, alpha = 0.20 },
            roundedRectRadii = { xRadius = 8, yRadius = 8 } })
        self.highlight:show()
    else
        self.highlight:elementAttribute(1, 'frame', drawingFrame)
    end
    self.highlightScreen = screen
    self.highlightFrame = frame
end

-- App badges share the native overview's geometry, including when opened by a gesture.
-- Keep one stationary, click-through canvas per display, as with selection feedback.
function obj:_clearAppIcons()
    for _, canvas in pairs(self.iconCanvases or {}) do canvas:delete() end
    self.iconCanvases, self.iconImages, self.iconGrouped, self.iconElements = nil, nil, nil, nil
    self.iconOwners, self.iconWindowIDs = nil, nil
    if self.iconTimer then self.iconTimer:stop(); self.iconTimer = nil end
end

function obj:_updateAppIcons(snapshot)
    snapshot = snapshot or MC.snapshot()
    if not snapshot.present then self:_clearAppIcons(); return end
    if self.iconGrouped == nil then
        local preferences = hs.plist.read(os.getenv('HOME') .. '/Library/Preferences/com.apple.dock.plist') or {}
        self.iconGrouped = preferences['expose-group-apps'] == true
    end
    if self.iconGrouped then return end -- macOS supplies the grouped badges.
    self.iconCanvases, self.iconImages = self.iconCanvases or {}, self.iconImages or {}
    self.iconElements = self.iconElements or {}
    local ids, changed = {}, self.iconWindowIDs == nil
    for _, candidate in ipairs(snapshot.candidates) do
        if candidate.id then
            ids[candidate.id] = true
            if not self.iconWindowIDs or not self.iconWindowIDs[candidate.id]
                or not self.iconOwners[candidate.id] then changed = true end
        end
    end
    for id in pairs(self.iconWindowIDs or {}) do
        if not ids[id] then changed = true; break end
    end
    if changed then
        self.iconOwners = {}
        for _, window in ipairs(hs.window.list()) do
            self.iconOwners[window.kCGWindowNumber] = window.kCGWindowOwnerPID
        end
        self.iconWindowIDs = ids
    end
    local owners = self.iconOwners
    local visible = {}
    for _, screen in ipairs(hs.screen.allScreens()) do
        local id, frame = screen:id(), screen:fullFrame()
        local elements = {}
        for _, candidate in ipairs(MC.onScreen(snapshot, id, frame).candidates) do
            local pid = owners[candidate.id]
            local icon = pid and self.iconImages[pid]
            if pid and icon == nil then
                local app = hs.application.applicationForPID(pid)
                local bundle = app and app:bundleID()
                icon = bundle and hs.image.imageFromAppBundle(bundle) or false
                self.iconImages[pid] = icon
            end
            if icon then
                local thumbnail, size = candidate.frame, 48
                -- Straddle the bottom edge like the native grouped badge, but keep
                -- the entire icon on screen for thumbnails near a display edge.
                local x = math.max(0, math.min(frame.w - size, thumbnail.x - frame.x + (thumbnail.w - size) / 2))
                local y = math.max(0, math.min(frame.h - size, thumbnail.y - frame.y + thumbnail.h - 32))
                elements[#elements + 1] = { type = 'image', image = icon,
                    frame = { x = x, y = y, w = size, h = size }, imageScaling = 'scaleProportionally',
                    withShadow = true,
                    shadow = { blurRadius = 3, color = { white = 0, alpha = 0.25 },
                        offset = { w = 0, h = -1 } } }
            end
        end
        if #elements > 0 then
            visible[id] = true
            local canvas = self.iconCanvases[id]
            if not canvas then
                canvas = hs.canvas.new(frame):level('overlay')
                    :behavior({ 'canJoinAllSpaces', 'stationary' }):clickActivating(false)
                    :canvasMouseEvents(false, false, false, false):mouseCallback(nil)
                self.iconCanvases[id] = canvas
            end
            local previous = self.iconElements[id]
            local changed = not previous or #previous ~= #elements
            if not changed then
                for i, element in ipairs(elements) do
                    local old, frame = previous[i], element.frame
                    if old.image ~= element.image or old.frame.x ~= frame.x or old.frame.y ~= frame.y
                        or old.frame.w ~= frame.w or old.frame.h ~= frame.h then
                        changed = true
                        break
                    end
                end
            end
            if changed then
                canvas:replaceElements(elements):show()
                self.iconElements[id] = elements
            end
        end
    end
    for id, canvas in pairs(self.iconCanvases) do
        if not visible[id] then
            canvas:delete()
            self.iconCanvases[id], self.iconElements[id] = nil, nil
        end
    end
    if not self.iconTimer then
        self.iconTimer = hs.timer.doEvery(0.03, function()
            -- The navigation worker supplies a fresh snapshot while it owns the gesture.
            if not self.workTimer then self:_safeAppIcons() end
        end)
    end
end

function obj:_safeAppIcons(snapshot)
    local ok, err = xpcall(function() self:_updateAppIcons(snapshot) end, debug.traceback)
    if not ok then
        self:_clearAppIcons()
        self.log.w('Cannot display application icons: ' .. tostring(err))
    end
end

function obj:_finish(reason)
    self:_highlight()
    if self.replayTimer then self.replayTimer:stop(); self.replayTimer = nil end
    local resumeQueue = reason == 'committed' or reason == 'native-replay' or (reason == 'cancelled' and self.session.cancelledByUser)
    local run = self.run
    local overviewOpen = run and run.ownsMC and MC.snapshot().present
    if not overviewOpen then restorePointer(run) end
    if run and run.restoreFocus and run.original and not overviewOpen then
        pcall(function() run.original:focus() end)
    end
    self.lastResult = self.lastResult or {}
    self.lastResult.reason = reason
    self.run = nil
    if self.running then self:_watchFocus() end
    self.session:reset()
    if resumeQueue and not self.suspended and #self.queuedSessions > 0 then
        local nextSession = table.remove(self.queuedSessions, 1)
        for key in pairs(self.session.swallowed) do nextSession.swallowed[key] = true end
        self.session = nextSession
        return -- Keep the worker alive for input received during the exit animation.
    end
    for _, queued in ipairs(self.queuedSessions) do
        for key in pairs(queued.swallowed) do self.session.swallowed[key] = true end
    end
    self.queuedSessions = {}
    if self.workTimer then self.workTimer:stop(); self.workTimer = nil end
end

function obj:_cancel(reason)
    self:_highlight()
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

function obj:_hover(point, time)
    -- Overlap can hide every safe hover point, especially during layout changes.
    -- Keep keyboard selection: confirmation uses the window ID, not the pointer.
    if not point then return end
    self.run.pointerMoved, self.run.lastPointer = true, point
    hs.mouse.absolutePosition(point)
    tagged(event.newMouseEvent(types.mouseMoved, point):setFlags({})):post()
    self.run.hoveredAt = time
end

function obj:_replay(remainingFlags)
    -- Replay only when this gesture owns the controller, so it cannot overtake an exit.
    remainingFlags = remainingFlags or hs.eventtap.checkKeyboardModifiers()
    local releasedFlags = {}
    for key, value in pairs(remainingFlags) do
        if key ~= 'cmd' then releasedFlags[key] = value end
    end
    self.lastResult = nil
    tagged(event.newKeyEvent('cmd', true)):post()
    for _, direction in ipairs(self.session.directions) do
        if direction < 0 then tagged(event.newKeyEvent('shift', true)):post() end
        local mods = direction < 0 and { 'cmd', 'shift' } or { 'cmd' }
        tagged(event.newKeyEvent(mods, 'tab', true)):post()
        tagged(event.newKeyEvent(mods, 'tab', false)):post()
        if direction < 0 then tagged(event.newKeyEvent('shift', false)):post() end
    end
    tagged(event.newKeyEvent('cmd', false):setFlags(releasedFlags)):post()
    -- A queued replay may run after the user has already started holding Command again.
    if remainingFlags.cmd then
        tagged(event.newKeyEvent('cmd', true):setFlags(remainingFlags)):post()
    end
    self:_finish('native-replay')
end

function obj:_tick(snapshot)
    local s, time = self.session, now()
    if s.mode == 'idle' then return end
    s:advance(time)
    -- Resolve external overview changes on the worker, never from a stale health cache.
    if not self.run and s.mode ~= 'cancelling' then
        if s.mode ~= 'pending' or not s.entryChecked then
            snapshot = snapshot or MC.snapshot()
            s.entryChecked = true
            if snapshot.present then s.mode = 'dismissing' end
        end
        if s.mode == 'replay' then self:_replay(); return end
    end
    if s.mode == 'pending' then return end
    if not self.run then
        local original = hs.window.focusedWindow()
        local screen = hs.mouse.getCurrentScreen()
        if not screen then self:_finish('pointer-screen-unavailable'); return end
        local recent, seen = {}, {}
        local originalID = original and original:id()
        local function append(id)
            if id and id ~= originalID and not seen[id] then
                recent[#recent + 1], seen[id] = id, true
            end
        end
        for _, id in ipairs(self.focusHistory) do append(id) end
        for _, window in ipairs(hs.window.list()) do append(window.kCGWindowNumber) end
        self.run = { original = original, recent = recent, serial = s.serial,
            screenID = screen:id(), screenFrame = screen:fullFrame(),
            pointer = hs.mouse.absolutePosition(), stepOrigin = s.directions[1] }
        self.lastResult = nil
    end
    local run = self.run
    if s.mode == 'cancelling' then self:_cancel('cancelled'); return end
    snapshot = snapshot or MC.snapshot()
    if snapshot.present and run.ownsMC then run.sawMC = true end
    -- Closing the last window is a normal overview update, not a failed entry.
    if snapshot.present and (run.target or run.candidates) and not s.released
        and (s.mode == 'opening' or s.mode == 'navigating')
        and (not run.backend or (snapshot.backend == run.backend and snapshot.pid == run.pid))
        and #MC.onScreen(snapshot, run.screenID, run.screenFrame).candidates == 0 then
        run.target, run.mouseSelection = nil, true
        run.backend, run.pid = snapshot.backend, snapshot.pid
        s.mode = 'navigating'
    end
    if run.mouseSelection then
        local target
        local screen = hs.mouse.getCurrentScreen()
        if snapshot.present and not s.released and screen then
            local scoped = MC.onScreen(snapshot, screen:id(), screen:fullFrame())
            local index, hit = MC.pointerIndex(snapshot, scoped.candidates, hs.mouse.absolutePosition())
            if hit then target = scoped.candidates[index] end
        end
        self:_highlight(target)
    end
    if s.mode == 'dismissing' then
        if not snapshot.present then self:_finish('already-closed'); return end
        run.openedAt, run.ownsMC, run.sawMC = time, true, true
        hs.spaces.toggleMissionControl()
        run.closing, s.mode = time, 'closing'
        return
    end
    if s.mode == 'opening' then
        if not run.openedAt then
            run.openedAt, run.ownsMC = time, true
            hs.spaces.openMissionControl()
            return
        end
        local scoped = MC.onScreen(snapshot, run.screenID, run.screenFrame)
        if time - run.openedAt > self.openTimeout and #scoped.candidates == 0 then
            if snapshot.present then
                self:_cancel('no-windows')
                return
            end
            -- Show Desktop can consume the first request without opening overview.
            -- Retry once only after the full deadline and a fresh absent snapshot.
            if not run.openRetried then
                run.openRetried, run.openedAt = true, time
                hs.spaces.openMissionControl()
                return
            end
            self.suspended = 'Mission Control did not expose usable windows; call start() to retry'
            self:_cancel('open-timeout')
            return
        end
        -- Preview as soon as AX exposes a usable frame; keep following it during animation.
        -- Freeze navigation order when stable, or at the deadline if windows are usable.
        -- Release can confirm a live target earlier.
        local candidates, base = MC.order(scoped.candidates)
        if base then
            if run.recent then
                local found
                for _, id in ipairs(run.recent) do
                    for i, candidate in ipairs(candidates) do
                        if candidate.id == id then base, found = i, true; break end
                    end
                    if found then break end
                end
            else
                local hit
                base, hit = MC.pointerIndex(scoped, candidates, run.pointer)
                -- A resumed navigation key advances from an actual hover; blank space selects the nearest thumbnail.
                run.stepOrigin = run.resumeSteps - (hit and run.resumeDirection or 0)
            end
        end
        if base and not run.mouseSelection then
            local offset = s.steps - run.stepOrigin
            local index = ((base - 1 + offset) % #candidates) + 1
            local target = candidates[index]
            if not s.released then self:_highlight(target) end
            local point = not s.released and MC.point(snapshot, target)
            if not run.target or run.target.id ~= target.id
                or hoverChanged(run, point) then
                run.index, run.target = index, target
                if not s.released then self:_hover(point, time) end
            end
        end
        if s.released and (base or (run.mouseSelection and snapshot.present)) then
            run.backend, run.pid = snapshot.backend, snapshot.pid
            s.mode = run.mouseSelection and 'navigating' or 'committing'
        elseif MC.stable(run.previous, scoped)
            or (base and time - run.openedAt > self.openTimeout) then
            run.candidates, run.base = candidates, base
            run.backend, run.pid = snapshot.backend, snapshot.pid
            -- AX frames can settle before native hover tracking is ready.
            -- Refresh once after settling, even if the pointer has not moved.
            run.hoverRefreshAt = time + self.hoverDelay
            s.mode = 'navigating'
        else
            run.previous = scoped
            return
        end
    end
    if s.mode == 'closing' then
        self:_highlight()
        if not snapshot.present then
            if run.focusTarget and not run.focusApplied then
                run.focusApplied = true
                if not run.focusTarget:id() then self:_finish('target-disappeared'); return end
                run.focusTarget:focus()
            end
            -- Confirmation keeps the pointer where navigation or the user left it.
            if not run.cancelReason then run.pointerMoved = false end
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
            self.log.w('Mission Control close timed out; ending this gesture')
            -- Drop stale queued input, but let a fresh gesture inspect the current overview.
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
        if not target then
            if s.released then self:_cancel('target-disappeared'); return end
            -- Reuse entry reconciliation after a window/app closes. Prefer the next
            -- surviving window in the old order, then freeze the updated layout.
            run.recent = {}
            for offset = 1, #run.candidates do
                local candidate = run.candidates[((index - 1 + offset) % #run.candidates) + 1]
                if candidate.id then run.recent[#run.recent + 1] = candidate.id end
            end
            run.stepOrigin, run.openedAt = s.steps, time
            run.target, run.index, run.previous = nil, nil, nil
            self:_highlight()
            s.mode = 'opening'
            return
        end
        if not s.released then self:_highlight(target) end
        local point = not s.released and MC.point(snapshot, target)
        if run.index ~= index or hoverChanged(run, point)
            or (run.hoverRefreshAt and time >= run.hoverRefreshAt) then
            run.index, run.target = index, target
            if not s.released then self:_hover(point, time) end
            if run.hoverRefreshAt and time >= run.hoverRefreshAt then run.hoverRefreshAt = nil end
        end
        if s.released then s.mode = 'committing' end
    end
    if s.mode == 'committing' then
        self:_highlight()
        local target = MC.find(MC.onScreen(snapshot, run.screenID, run.screenFrame), run.target)
        if not target then self:_cancel('target-disappeared'); return end
        run.focusTarget = windowForID(target.id)
        if not run.focusTarget then self:_cancel('target-unavailable'); return end
        hs.spaces.toggleMissionControl()
        run.closing, s.mode = time, 'closing'
        -- Request focus during exit; reapply after exit because macOS may restore native hover focus.
        run.focusTarget:focus()
    end
end

function obj:_safeTick()
    local ok, err = xpcall(function()
        if self.session.mode == 'idle' then return end
        self.session:advance(now())
        if self.session.mode == 'pending' and self.session.entryChecked then return end
        -- Share only within this callback; never reuse AX elements across worker ticks.
        local snapshot = MC.snapshot()
        self:_safeAppIcons(snapshot)
        self:_tick(snapshot)
    end, debug.traceback)
    if not ok then
        self:_highlight()
        restorePointer(self.run)
        self.log.e(err)
        self.suspended = 'Runtime error; inspect MissionTab log and call start()'
        -- Stop owning input immediately. Do not guess a click or toggle after an AX error.
        self.run = nil
        if self.replayTimer then self.replayTimer:stop(); self.replayTimer = nil end
        for _, queued in ipairs(self.queuedSessions) do
            for key in pairs(queued.swallowed) do self.session.swallowed[key] = true end
        end
        self.queuedSessions = {}
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
        local point = e:location()
        if run and run.ownsMC and motion > 0
            and (not run.lastPointer
                or math.abs(point.x - run.lastPointer.x) + math.abs(point.y - run.lastPointer.y) > 3)
            and (mode == 'opening' or mode == 'navigating' or mode == 'committing') then
            run.mouseSelection, run.userPointer = true, true
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
    if not self.suspended and (#self.queuedSessions > 0
        or (self.session.released and self.session.mode ~= 'idle' and self.session.mode ~= 'cancelling'
            and (not self.run or not self.run.cancelReason))) then
        -- Keep each new gesture while macOS finishes the previous exit. Releases still
        -- belong to the session that swallowed their key-down, even across gestures.
        if inputKind == 'up' then
            if self.session.swallowed[key] then
                return self.session:handle(inputKind, key, e:getFlags(), false, now())
            end
            for _, queued in ipairs(self.queuedSessions) do
                if queued.swallowed[key] then
                    return queued:handle(inputKind, key, e:getFlags(), false, now())
                end
            end
        end
        local queued = self.queuedSessions[#self.queuedSessions]
        local fresh = not queued or (queued.released and inputKind == 'down' and key == 'tab')
        if fresh then queued = Session.new(self.holdDelay) end
        local consumed = queued:handle(inputKind, key, e:getFlags(),
            e:getProperty(properties.keyboardEventAutorepeat) == 1, now())
        if fresh and queued.mode ~= 'idle' then
            self.queuedSessions[#self.queuedSessions + 1] = queued
        end
        return consumed
    end
    local previousKeyCount = #(self.session.directions or {})
    local previousSerial = self.session.serial
    local consumed = self.session:handle(inputKind, key, e:getFlags(),
        e:getProperty(properties.keyboardEventAutorepeat) == 1, now())
    if self.run and self.run.mouseSelection
        and #(self.session.directions or {}) ~= previousKeyCount then
        local screen = hs.mouse.getCurrentScreen()
        if not screen then self.session.mode = 'cancelling'
        else
            local run = self.run
            run.screenID, run.screenFrame = screen:id(), screen:fullFrame()
            run.pointer = hs.mouse.absolutePosition()
            run.resumeSteps = self.session.steps
            run.resumeDirection = self.session.directions[#self.session.directions]
            run.recent, run.userPointer, run.pointerMoved, run.lastPointer = nil, false, false, nil
            run.mouseSelection, run.index, run.target, run.previous = false, nil, nil, nil
            run.openedAt = now()
            self.session.mode = 'opening'
        end
    end
    if self.session.released then self:_highlight() end
    if self.session.serial ~= previousSerial then
        self.lastResult = nil
    end
    if self.session.mode == 'replay' and not self.replayTimer then
        -- Verify the overview outside the input callback, without waiting for the 30 ms worker.
        local timer
        timer = hs.timer.doAfter(0, function()
            if self.replayTimer ~= timer then return end
            self.replayTimer = nil
            self:_safeTick()
        end)
        self.replayTimer = timer
    end
    if self.session.mode ~= 'idle' and not self.workTimer then
        local timer
        timer = hs.timer.doEvery(0.03, function()
            if self.workTimer == timer then self:_safeTick() end
        end)
        self.workTimer = timer
    end
    return consumed
end

function obj:start()
    if self.running then self:stop() end
    if self.cleanup then self.restartAfterCleanup = true; return self end
    assert(self.holdDelay >= 0 and self.openTimeout > 0 and self.hoverDelay >= 0 and self.closeTimeout > 0,
        'MissionTab timing values must be nonnegative (timeouts must be positive)')
    self.session, self.suspended, self.queuedSessions = Session.new(self.holdDelay), nil, {}
    self.reverseKeyCode = self.reverseKeyCode or hs.keycodes.map['`'] or 50
    if not hs.accessibilityState() then self.suspended = 'Accessibility permission required'; return self end
    self.tap = hs.eventtap.new({ types.keyDown, types.keyUp, types.flagsChanged, types.mouseMoved }, function(e) return self:_event(e) end):start()
    self.running = true
    self.focusHistory = {}
    self.applicationWatcher = hs.application.watcher.new(function(_, kind)
        if self.running and kind == hs.application.watcher.activated then self:_watchFocus() end
    end):start()
    self:_watchFocus()
    self.health = hs.timer.doEvery(0.5, function()
        if not self.running then return end
        if not self.iconTimer and not self.workTimer then self:_safeAppIcons() end
        if hs.eventtap.isSecureInputEnabled() then
            if self.session.mode ~= 'idle' then self.session.mode, self.session.cancelledByUser = 'cancelling', false end
            self.suspended = 'secure-input'
        elseif self.suspended == 'secure-input' then self.suspended = nil end
        if not self.tap:isEnabled() then
            self.tap:start()
            -- A timeout can disable the tap without a user cancellation. Recover the
            -- physical Command state in case its release happened while events were lost.
            local active = self.queuedSessions[#self.queuedSessions] or self.session
            if active.mode ~= 'idle' then
                active:handle('flags', '', hs.eventtap.checkKeyboardModifiers(), false, now())
            end
        end
    end)
    self.screenLayout = screenLayout()
    self.screenWatcher = hs.screen.watcher.new(function()
        local layout = screenLayout()
        if layout == self.screenLayout then return end
        self.screenLayout = layout
        self:_clearAppIcons()
        if self.session.mode ~= 'idle' then self.session.mode, self.session.cancelledByUser = 'cancelling', false end
    end):start()
    self.sleepWatcher = hs.caffeinate.watcher.new(function(kind)
        if kind == hs.caffeinate.watcher.systemWillSleep or kind == hs.caffeinate.watcher.screensDidLock then
            if self.session.mode ~= 'idle' then self.session.mode, self.session.cancelledByUser = 'cancelling', false end
        end
    end):start()
    return self
end

function obj:stop()
    self:_clearAppIcons()
    self:_highlight()
    self.queuedSessions = {}
    self.restartAfterCleanup = false
    if self.tap then self.tap:stop(); self.tap = nil end
    for _, key in ipairs({ 'health', 'workTimer', 'replayTimer', 'screenWatcher', 'sleepWatcher', 'applicationWatcher', 'focusObserver' }) do
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
                restorePointer(run)
                if run.original then pcall(function() run.original:focus() end) end
                self.cleanup:stop(); self.cleanup = nil
            end
            if self.cleanup and now() > deadline then
                restorePointer(run)
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
