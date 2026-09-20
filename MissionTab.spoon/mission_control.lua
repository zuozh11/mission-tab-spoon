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
        result.candidates[#result.candidates + 1] = {
            element = element, id = wid, frame = frame, display = display, displayID = displayID,
        }
    end
    local root, pid = applicationRoot('com.apple.WindowManager')
    for _, display in ipairs(children(root)) do
        if display.AXIdentifier == 'mc.display' then
            result.present, result.backend, result.pid = true, 'WindowManager', pid
            local displayFrame = display.AXFrame or { x = 0, y = 0 }
            local displayID = display:attributeValue('AXDisplayID')
            for _, element in ipairs(children(display)) do
                if element.AXRole == 'AXButton' then add(element, displayFrame, displayID) end
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
                    local displayID = display:attributeValue('AXDisplayID')
                    for _, windows in ipairs(children(display)) do
                        if windows.AXIdentifier == 'mc.windows' then
                            for _, element in ipairs(children(windows)) do add(element, displayFrame, displayID) end
                        end
                    end
                end
            end
        end
    end
    return result
end

-- Infer columns from horizontal spacing, then visit each column from top to bottom.
function MC.order(candidates)
    if #candidates == 0 then return candidates, nil end
    local entries, widths = {}, {}
    for i, candidate in ipairs(candidates) do
        local f = candidate.frame
        entries[i] = { candidate = candidate, ordinal = i,
            x = f.x + f.w / 2, y = f.y + f.h / 2 }
        widths[i] = f.w
    end
    local function tieBreak(a, b)
        local aid, bid = a.candidate.id, b.candidate.id
        if aid and bid and aid ~= bid then return aid < bid end
        return a.ordinal < b.ordinal
    end
    table.sort(entries, function(a, b)
        if a.x ~= b.x then return a.x < b.x end
        if a.y ~= b.y then return a.y < b.y end
        return tieBreak(a, b)
    end)
    table.sort(widths)
    local typicalWidth = (widths[math.floor((#widths + 1) / 2)] + widths[math.ceil((#widths + 1) / 2)]) / 2
    local largestGap = 0
    for i = 2, #entries do
        largestGap = math.max(largestGap, entries[i].x - entries[i - 1].x)
    end
    -- Tolerate small alignment errors even in a single column. Clear gutters allow
    -- wider offsets, but one distant window cannot inflate tolerance without limit.
    local columnSpan = math.max(typicalWidth / 4, math.min(largestGap, typicalWidth) * 2 / 3)
    local columns = {}
    for _, entry in ipairs(entries) do
        local column = columns[#columns]
        -- Measure the entire span, not adjacent gaps, to prevent chained merging.
        if not column or entry.x - column.x > columnSpan then
            column = { x = entry.x, entries = {} }
            columns[#columns + 1] = column
        end
        column.entries[#column.entries + 1] = entry
    end
    local ordered = {}
    for _, column in ipairs(columns) do
        table.sort(column.entries, function(a, b)
            if a.y ~= b.y then return a.y < b.y end
            if a.x ~= b.x then return a.x < b.x end
            return tieBreak(a, b)
        end)
        for _, entry in ipairs(column.entries) do ordered[#ordered + 1] = entry.candidate end
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
                if (id and candidate.id == id) or candidate.element == hit then return i, true end
            end
            hit = hit:attributeValue('AXParent')
        end
    end
    -- Measure distance to the thumbnail edge, using its centre to break ties.
    local found, hits, nearest = nil, 0, 1
    local bestDistance, bestCentre = math.huge, math.huge
    for i, candidate in ipairs(ordered) do
        local frame = candidate.frame
        if contains(frame, point) then found, hits = i, hits + 1 end
        local dx = math.max(frame.x - point.x, 0, point.x - frame.x - frame.w)
        local dy = math.max(frame.y - point.y, 0, point.y - frame.y - frame.h)
        local distance = dx * dx + dy * dy
        local centre = (point.x - frame.x - frame.w / 2)^2
            + (point.y - frame.y - frame.h / 2)^2
        if distance < bestDistance or (distance == bestDistance and centre < bestCentre) then
            nearest, bestDistance, bestCentre = i, distance, centre
        end
    end
    if hits == 1 then return found, true end
    return nearest, false

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
