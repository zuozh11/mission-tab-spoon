-- Run via hs -c 'dofile(".../scripts/live-smoke.lua")'. Temporary event tap only.
local options = (...) or {}
local root = debug.getinfo(1, 'S').source:sub(2):match('(.*/)') .. '../'
if _G.missionTabSmoke and not _G.missionTabSmoke.done then error('Smoke test already running') end
local spoon = dofile(root .. 'MissionTab.spoon/init.lua'):start()
local original = hs.window.focusedWindow()
local pointer = hs.mouse.absolutePosition()
_G.missionTabSmoke = { results = {}, spoon = spoon }
local report = _G.missionTabSmoke
report.timers = {}
local finish
local function after(delay, fn)
    local timer = hs.timer.doAfter(delay, function()
        if not report.done then
            local ok, err = xpcall(fn, debug.traceback)
            if not ok then report.error=err; finish(true) end
        end
    end)
    report.timers[#report.timers + 1] = timer
end
local event = hs.eventtap.event
local function key(mods, name, down) event.newKeyEvent(mods, name, down):post() end
local function command(down) event.newKeyEvent('cmd', down):post() end
local cases = options.onlyLong and {} or { {name='short',hold=0.08} }
for i=1,(options.rounds or 1) do cases[#cases+1]={name='long-'..i,hold=0.9} end
if options.scenarios then
    cases[#cases+1]={name='next-then-back',hold=1.1,keys={{0.65,'tab'},{0.8,'`'}}}
    cases[#cases+1]={name='early-release',hold=0.27}
    cases[#cases+1]={name='escape',hold=0.9,keys={{0.65,'escape'}}}
end
finish = function(interrupted)
    command(false)
    spoon:stop()
    for _, view in ipairs(report.fixtures or {}) do view:delete() end
    if not interrupted then
        hs.mouse.absolutePosition(pointer)
        if original then original:focus() end
    end
    report.interrupted = interrupted
    for _, timer in ipairs(report.timers) do timer:stop() end
    report.done = true
end
local function run(index)
    local case = cases[index]
    if not case then finish(); return end
    local before=hs.window.focusedWindow()
    command(true)
    after(0.03,function() key({'cmd'},'tab',true) end)
    after(0.06,function() key({'cmd'},'tab',false) end)
    for _, step in ipairs(case.keys or {}) do
        after(step[1],function() key({'cmd'},step[2],true); key({'cmd'},step[2],false) end)
    end
    after(case.hold,function() command(false) end)
    after(case.hold+1.3,function()
        local focusedAfter=hs.window.focusedWindow()
        report.results[#report.results+1]={case=case.name,before=before and before:id(),after=focusedAfter and focusedAfter:id(),status=spoon:status(),overview=spoon:diagnose().present}
        local status = spoon:status()
        if (status.lastResult and status.lastResult.reason == 'mouse-takeover') or spoon:diagnose().present then
            finish(true)
            return
        end
        after(0.2,function() run(index+1) end)
    end)
end
if options.fixtures then
    report.fixtures, report.fixtureIDs = {}, {}
    for i=1,2 do
        local view = hs.webview.newBrowser({x=100+i*160,y=180+i*90,w=500,h=350})
            :html('<html><head><title>MissionTab test</title></head><body><h1>MissionTab test '..i..'</h1><p>Temporary test window</p></body></html>')
            :windowTitle('MissionTab test'):show()
        report.fixtures[i] = view
        report.fixtureIDs[i] = view:hswindow():id()
    end
    after(0.5,function()
        report.fixtures[1]:hswindow():focus()
        after(0.2,function()
            report.fixtures[2]:hswindow():focus()
            after(0.3,function() run(1) end)
        end)
    end)
else run(1) end
return 'smoke test started'
