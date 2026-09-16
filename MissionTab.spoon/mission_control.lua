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
    local function add(element, display)
        local frame = element:attributeValue('AXFrame')
        if not frame or frame.w <= 0 or frame.h <= 0 or element.AXEnabled == false then return end
        local wid = element:attributeValue('wid')
        result.candidates[#result.candidates + 1] = {
            element = element, id = wid, frame = frame, display = display,
        }
    end
    local root, pid = applicationRoot('com.apple.WindowManager')
    for _, display in ipairs(children(root)) do
        if display.AXIdentifier == 'mc.display' then
            result.present, result.backend, result.pid = true, 'WindowManager', pid
            local displayFrame = display.AXFrame or { x = 0, y = 0 }
            for _, element in ipairs(children(display)) do
                if element.AXRole == 'AXButton' then add(element, displayFrame) end
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
                            for _, element in ipairs(children(windows)) do add(element, displayFrame) end
                        end
                    end
                end
            end
        end
    end
    return result
end

-- Clockwise around the centre of the thumbnail layout; recency chooses only the start.
function MC.order(candidates, windowIDs, originalID)
    if #candidates == 0 then return candidates, nil end
    local left, top, right, bottom = math.huge, math.huge, -math.huge, -math.huge
    for _, candidate in ipairs(candidates) do
        local f = candidate.frame
        left, top = math.min(left, f.x), math.min(top, f.y)
        right, bottom = math.max(right, f.x + f.w), math.max(bottom, f.y + f.h)
    end
    local cx, cy = (left + right) / 2, (top + bottom) / 2
    local positions = {}
    for i, candidate in ipairs(candidates) do
        local f = candidate.frame
        local dx, dy = f.x + f.w / 2 - cx, f.y + f.h / 2 - cy
        positions[candidate] = { angle = (dx == 0 and dy == 0) and 0 or math.atan(dx, -dy) % (2 * math.pi),
            radius = dx * dx + dy * dy, ordinal = i }
    end
    table.sort(candidates, function(a, b)
        local ap, bp = positions[a], positions[b]
        if ap.angle ~= bp.angle then return ap.angle < bp.angle end
        if ap.radius ~= bp.radius then return ap.radius < bp.radius end
        if a.id and b.id and a.id ~= b.id then return a.id < b.id end
        return ap.ordinal < bp.ordinal
    end)
    for _, id in ipairs(windowIDs) do
        if id ~= originalID then
            for i, candidate in ipairs(candidates) do
                if candidate.id == id then return candidates, i end
            end
        end
    end
    for i, candidate in ipairs(candidates) do
        if originalID and candidate.id == originalID then return candidates, i end
    end
    return candidates, 1
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
