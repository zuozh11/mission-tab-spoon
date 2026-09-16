-- macOS owns the overview. AX elements and frames live for one overview only.
local MC = {}
local function applicationRoot(bundle)
    local app = hs.application.applicationsForBundleID(bundle)[1]
    if not app then return nil end
    return hs.axuielement.applicationElement(app), app:pid()
end

local function children(element)
    return element and element:attributeValue('AXChildren') or {}
end

function MC.snapshot()
    local result = { present = false, candidates = {} }
    local function add(element, display, displayID)
        local frame = element:attributeValue('AXFrame')
        if not frame or frame.w <= 0 or frame.h <= 0 or element.AXEnabled == false then return end
        local wid = element:attributeValue('wid')
        local identifier = element:attributeValue('AXIdentifier')
        result.candidates[#result.candidates + 1] = {
            element = element, id = wid, frame = frame, display = display, displayID = displayID,
            groupKey = identifier and identifier:match("^.+%.space%.%d+$"),
        }
    end
    local root, pid = applicationRoot('com.apple.WindowManager')
    for _, display in ipairs(children(root)) do
        if display.AXIdentifier == 'mc.display' then
            result.present, result.backend, result.pid = true, 'WindowManager', pid
            local displayFrame = display.AXFrame or { x = 0, y = 0 }
            for _, element in ipairs(children(display)) do
                if element.AXRole == 'AXButton' then add(element, displayFrame, display:attributeValue('AXDisplayID')) end
            end
        end
    end
    if result.present then return result end
    root, pid = applicationRoot('com.apple.dock')
    for _, group in ipairs(children(root)) do
        if group.AXIdentifier == 'mc' then
            result.present, result.backend, result.pid = true, 'Dock', pid
            for _, display in ipairs(children(group)) do
                if display.AXIdentifier == 'mc.display' then
                    local displayFrame = display.AXFrame or { x = 0, y = 0 }
                    for _, windows in ipairs(children(display)) do
                        if windows.AXIdentifier == 'mc.windows' then
                            for _, element in ipairs(children(windows)) do add(element, displayFrame, display:attributeValue('AXDisplayID')) end
                        end
                    end
                end
            end
        end
    end
    return result
end

-- Overlapping windows with the same app/Space identity form one clockwise stop.
-- Flatten each stop top-to-bottom so reverse navigation is the exact inverse.
function MC.order(candidates)
    if #candidates == 0 then return candidates, nil end
    local groups, assigned = {}, {}
    local function overlaps(a, b)
        return a.x < b.x + b.w and b.x < a.x + a.w
            and a.y < b.y + b.h and b.y < a.y + a.h
    end
    for i, candidate in ipairs(candidates) do
        if not assigned[i] then
            local group = { members = { { candidate = candidate, ordinal = i } }, ordinal = i }
            assigned[i] = true
            local cursor = 1
            while cursor <= #group.members do
                local member = group.members[cursor].candidate
                if member.groupKey then
                    for j, other in ipairs(candidates) do
                        if not assigned[j] and other.groupKey == member.groupKey
                            and other.display == member.display and overlaps(member.frame, other.frame) then
                            assigned[j] = true
                            group.members[#group.members + 1] = { candidate = other, ordinal = j }
                        end
                    end
                end
                cursor = cursor + 1
            end
            groups[#groups + 1] = group
        end
    end
    local left, top, right, bottom = math.huge, math.huge, -math.huge, -math.huge
    for _, group in ipairs(groups) do
        local gl, gt, gr, gb = math.huge, math.huge, -math.huge, -math.huge
        for _, member in ipairs(group.members) do
            local f = member.candidate.frame
            gl, gt = math.min(gl, f.x), math.min(gt, f.y)
            gr, gb = math.max(gr, f.x + f.w), math.max(gb, f.y + f.h)
        end
        group.x, group.y = (gl + gr) / 2, (gt + gb) / 2
        left, top, right, bottom = math.min(left, gl), math.min(top, gt), math.max(right, gr), math.max(bottom, gb)
        table.sort(group.members, function(a, b)
            local ac, bc = a.candidate, b.candidate
            if ac.frame.y ~= bc.frame.y then return ac.frame.y < bc.frame.y end
            if ac.frame.x ~= bc.frame.x then return ac.frame.x < bc.frame.x end
            if ac.id and bc.id and ac.id ~= bc.id then return ac.id < bc.id end
            return a.ordinal < b.ordinal
        end)
    end
    local cx, cy = (left + right) / 2, (top + bottom) / 2
    for _, group in ipairs(groups) do
        local dx, dy = group.x - cx, group.y - cy
        group.angle = (dx == 0 and dy == 0) and 0 or math.atan(dx, -dy) % (2 * math.pi)
        group.radius = dx * dx + dy * dy
    end
    table.sort(groups, function(a, b)
        if a.angle ~= b.angle then return a.angle < b.angle end
        if a.radius ~= b.radius then return a.radius < b.radius end
        return a.ordinal < b.ordinal
    end)
    -- Start the circular group order at the group nearest the upper-left corner.
    local first, nearest = 1, math.huge
    for i, group in ipairs(groups) do
        local distance = (group.x - left)^2 + (group.y - top)^2
        if distance < nearest then first, nearest = i, distance end
    end
    local ordered = {}
    for offset = 0, #groups - 1 do
        local group = groups[((first - 1 + offset) % #groups) + 1]
        for _, member in ipairs(group.members) do ordered[#ordered + 1] = member.candidate end
    end
    return ordered, 1
end

local function contains(frame, point)
    return point.x >= frame.x and point.x < frame.x + frame.w
        and point.y >= frame.y and point.y < frame.y + frame.h
end

function MC.onScreen(snapshot, screenID, screenFrame)
    local scoped = { present = snapshot.present, backend = snapshot.backend,
        pid = snapshot.pid, candidates = {} }
    for _, candidate in ipairs(snapshot.candidates) do
        local frame = candidate.display
        local sameScreen
        if candidate.displayID then
            sameScreen = candidate.displayID == screenID
        elseif frame and frame.w and frame.h then
            sameScreen = contains(screenFrame, { x = frame.x + frame.w / 2, y = frame.y + frame.h / 2 })
        else
            frame = candidate.frame
            sameScreen = contains(screenFrame, { x = frame.x + frame.w / 2, y = frame.y + frame.h / 2 })
        end
        if sameScreen then scoped.candidates[#scoped.candidates + 1] = candidate end
    end
    return scoped
end

function MC.pointerIndex(snapshot, ordered, point)
    -- Ask the overview's AX tree to resolve stacking, rather than guessing by rectangles.
    local ok, hit = pcall(function()
        return hs.axuielement.applicationElementForPID(snapshot.pid):elementAtPosition(point)
    end)
    if ok then
        for _ = 1, 8 do
            if not hit then break end
            local id = hit:attributeValue('wid')
            for i, candidate in ipairs(ordered) do
                if (id and candidate.id == id) or candidate.element == hit then return i end
            end
            hit = hit:attributeValue('AXParent')
        end
    end
    -- A unique rectangle is unambiguous; overlapping rectangles need an AX hit.
    local found
    for i, candidate in ipairs(ordered) do
        if contains(candidate.frame, point) then
            if found then return 1 end
            found = i
        end
    end
    return found or 1
end

function MC.find(snapshot, target)
    for _, candidate in ipairs(snapshot.candidates) do
        if (target.id and candidate.id == target.id)
            or (not target.id and candidate.element == target.element) then return candidate end
    end
end

function MC.stable(before, after)
    if not before or before.backend ~= after.backend or before.pid ~= after.pid
        or #before.candidates ~= #after.candidates or #after.candidates == 0 then return false end
    for _, target in ipairs(before.candidates) do
        local current = MC.find(after, target)
        if not current then return false end
        for _, key in ipairs({ 'x', 'y', 'w', 'h' }) do
            if math.abs(target.frame[key] - current.frame[key]) > 2 then return false end
        end
    end
    return true
end

-- Grouped windows overlap. Pick an exposed part instead of another window's centre.
function MC.point(snapshot, target)
    local pieces = { target.frame }
    for _, other in ipairs(snapshot.candidates) do
        if other.element ~= target.element then
            local nextPieces, cover = {}, other.frame
            for _, r in ipairs(pieces) do
                local left, top = math.max(r.x, cover.x), math.max(r.y, cover.y)
                local right = math.min(r.x + r.w, cover.x + cover.w)
                local bottom = math.min(r.y + r.h, cover.y + cover.h)
                if right <= left or bottom <= top then nextPieces[#nextPieces + 1] = r
                else
                    for _, piece in ipairs({
                        { x=r.x, y=r.y, w=r.w, h=top-r.y },
                        { x=r.x, y=bottom, w=r.w, h=r.y+r.h-bottom },
                        { x=r.x, y=top, w=left-r.x, h=bottom-top },
                        { x=right, y=top, w=r.x+r.w-right, h=bottom-top },
                    }) do
                        if piece.w >= 8 and piece.h >= 8 then nextPieces[#nextPieces + 1] = piece end
                    end
                end
            end
            pieces = nextPieces
        end
    end
    table.sort(pieces, function(a,b) return a.w*a.h > b.w*b.h end)
    local frame = pieces[1]
    if frame then return { x=frame.x+frame.w/2, y=frame.y+frame.h/2 } end
end

return MC
