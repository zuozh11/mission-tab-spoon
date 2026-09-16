local root = debug.getinfo(1, 'S').source:sub(2):match('(.*/)') .. '../'
local Session = dofile(root .. 'MissionTab.spoon/session.lua')
local count = 0
local function check(value, message) assert(value, message); count = count + 1 end
local function begin(direction)
    local s = Session.new()
    check(s:handle('down', 'tab', { cmd = true, shift = direction == -1 }, false, 0), 'owns first Tab')
    return s
end
local s = begin()
check(s.mode == 'opening', 'first key-down opens without a hold threshold or Tab release')
s:handle('up', 'tab', { cmd = true }, false, 0.05)
s:handle('flags', 'cmd', {}, false, 0.08)
check(s.mode == 'opening' and s.released and s.steps == 1, 'short release queues overview confirmation')
s = begin()
s:handle('flags', 'rightcmd', { cmd = true }, false, 1.1)
check(not s.released, 'one Command remains down')
s:handle('flags', 'leftcmd', {}, false, 1.2)
check(s.mode == 'opening' and s.released, 'release during animation queues commit')
s = begin()
s:handle('down', 'tab', { cmd = true }, true, 0.1)
check(s.steps == 1, 'autorepeat ignored')
s:handle('up', 'tab', { cmd = true }, false, 0.11)
s:handle('down', 'tab', { cmd = true }, false, 0.12)
s:handle('up', 'tab', { cmd = true }, false, 0.13)
s:handle('down', 'grave', { cmd = true }, false, 0.14)
check(s.steps == 1 and #s.directions == 3, 'active forward and reverse presses retained')
s:handle('flags', 'cmd', {}, false, 0.15)
check(s.mode == 'opening' and s.released, 'multiple quick presses keep overview selection')
s:reset()
check(s:handle('up', 'grave', {}, false, 0.2), 'late owned key-up consumed after reset')
check(not s:handle('up', 'grave', {}, false, 0.3), 'release consumed exactly once')
s = begin()
check(s:handle('down', 'escape', { cmd = true }, false, 0.1), 'Esc owned')
check(s.mode == 'cancelling', 'Esc cancels opening')
s:handle('flags', 'cmd', {}, false, 0.11)
check(s.mode == 'cancelling', 'release does not revive cancelled session')
s = begin()
check(not s:handle('down', 'q', { cmd = true }, false, 0.1), 'other opening chord passes through')
check(s.mode == 'opening', 'other opening chord preserves navigation')
s = begin()
s.mode = 'navigating'
for _, key in ipairs({ 'w', 'q', 'c', 'v' }) do
    check(not s:handle('down', key, { cmd = true }, false, 0.4), 'shortcut key-down passes through')
    check(not s:handle('up', key, { cmd = true }, false, 0.5), 'shortcut key-up passes through')
end
check(s.mode == 'navigating', 'shortcut passthrough does not cancel navigation')
s = Session.new()
for _, flags in ipairs({ {}, {cmd=true,ctrl=true}, {cmd=true,alt=true}, {cmd=true,fn=true} }) do
    check(not s:handle('down', 'tab', flags, false, 0), 'unrelated chord passes through')
end
s = begin(-1)
check(s.steps == -1, 'reverse initial chord')
check(not s:handle('flags', 'shift', {cmd=true}, false, 0.1), 'physical modifiers always pass through')
return { assertions = count, passed = true }
