-- Keyboard policy only. No Hammerspoon calls: timing and event order are testable.
local Session = {}
Session.__index = Session

function Session.new(delay)
    return setmetatable({ mode = 'idle', delay = delay, swallowed = {}, serial = 0 }, Session)
end

function Session:reset()
    self.mode = 'idle'
    self.cmd = false
    self.tabDown = false
    self.steps = 0
    self.released = false
    -- Keep owned key-downs until their matching key-up, even after cancellation.
end

function Session:handle(kind, key, flags, repeated, now)
    if kind == 'up' and self.swallowed[key] then
        self.swallowed[key] = nil
        if key == 'tab' then self.tabDown = false end
        return true
    end
    if kind == 'flags' then
        self.cmd = flags.cmd == true -- Aggregate flag stays set while either Command is down.
        if self.mode ~= 'idle' and not self.cmd then
            self.released = true
            if self.mode == 'pending' then self.mode = 'replay' end
        end
        return false
    end
    if kind ~= 'down' then return false end
    if self.swallowed[key] and repeated then return true end
    if self.mode == 'idle' then
        if key ~= 'tab' or not flags.cmd or flags.alt or flags.ctrl or flags.fn or repeated then
            return false
        end
        self.serial = self.serial + 1
        self.mode, self.started, self.cmd = 'pending', now, true
        self.steps = flags.shift and -1 or 1
        self.directions = { self.steps }
        self.tabDown, self.released = true, false
        self.swallowed.tab = true
        return true
    end
    if key == 'escape' then
        self.mode = 'cancelling'
        self.swallowed[key] = true
        return true
    end
    if self.mode == 'pending' or self.mode == 'opening' or self.mode == 'navigating' then
        if flags.cmd and not flags.ctrl and not flags.alt and not flags.fn
            and (key == 'tab' or key == 'grave') then
            self.swallowed[key] = true
            if key == 'tab' then self.tabDown = true end
            if not repeated then
                local direction = (key == 'grave' or flags.shift) and -1 or 1
                self.steps = self.steps + direction
                self.directions[#self.directions + 1] = direction
            end
            return true
        end
        if self.mode == 'pending' then
            self.mode = 'cancelling'
            return false -- A different chord before the overview belongs to the application.
        end
    end
    -- Only navigation and cancellation belong to MissionTab; preserve other shortcuts.
    return false
end

function Session:advance(now)
    if self.mode == 'pending' and not self.tabDown and self.cmd
        and now - self.started >= self.delay then
        self.mode = 'opening'
    end
end

return Session
