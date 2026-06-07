--[[
    Safehouse Inventory - "have-at-base" item index
    ------------------------------------------
    Keeps a cached lookup of every item TYPE stored across your safehouse zones, so any item you come
    across anywhere in the world can be answered instantly: "do I already have this at your safehouse, where,
    and how many?".

    Data model
    ----------
    Per zone we store a fullType -> count map. This is persisted inside the existing
    "SafehouseInventoryZones" ModData (md.typeIndex[zoneKey] = { name=, types={ [fullType]=count } }) so
    zones you're far from / that aren't loaded still light up items. Whenever you're in range of a
    zone (its squares are loaded) we re-scan it live and overwrite that zone's entry, keeping near
    zones accurate.

    A merged lookup (fullType -> { total, zones={ {name,count}.. } }) is rebuilt lazily from the
    per-zone maps and cached until something marks it dirty, so the render/tooltip hooks do an O(1)
    hash lookup per item.

    "In my base" = items inside containers in the zone PLUS items lying on the floor in the zone
    (matches SafehouseInventoryManager:getItemsInZone scope).
]]

SafehouseInventoryIndex = SafehouseInventoryIndex or {}
local IDX = SafehouseInventoryIndex

IDX.MARGIN = 3              -- tiles of slack around a zone (matches SafehouseInventoryTab.MARGIN)
IDX.SCAN_THROTTLE_MS = 1500 -- don't re-scan the same zone more often than this
IDX.Z_MIN, IDX.Z_MAX = -8, 8 -- floors swept for "all floors" zones (nil squares skipped cheaply)

IDX._merged = nil          -- cached merged lookup
IDX._dirty = true          -- merged needs rebuild
IDX._lastScan = {}         -- [zoneKey] = last scan timestamp
IDX._sig = {}              -- [zoneKey] = signature of last stored contents (change detection)

-- ── helpers ─────────────────────────────────────────────────────────────────────────
local function zoneBounds(zone)
    return math.min(zone.x1, zone.x2), math.min(zone.y1, zone.y2),
           math.max(zone.x1, zone.x2), math.max(zone.y1, zone.y2), (zone.z or 0)
end

-- A zone includes every floor unless explicitly restricted to its own (allFloors == false).
local function allFloorsOf(zone)
    return zone.allFloors ~= false
end

-- The list of z-levels a zone covers.
local function zLevels(zone)
    if not allFloorsOf(zone) then return { zone.z or 0 } end
    local t = {}
    for z = IDX.Z_MIN, IDX.Z_MAX do t[#t + 1] = z end
    return t
end

-- Order-independent fingerprint of a counts map, so we only rewrite/sync when contents change.
local function signatureOf(counts)
    local keys = {}
    for ft in pairs(counts) do keys[#keys + 1] = ft end
    table.sort(keys)
    local parts = {}
    for i = 1, #keys do parts[i] = keys[i] .. "=" .. counts[keys[i]] end
    return table.concat(parts, ";")
end

local function zoneKeyOf(zone)
    local x1, y1, _, _, zz = zoneBounds(zone)
    return zone.name or (x1 .. "," .. y1 .. "," .. zz)
end

local function getZones()
    local md = ModData.getOrCreate("SafehouseInventoryZones")
    return (md and md.zones) or {}
end

local function getTypeIndex()
    local md = ModData.getOrCreate("SafehouseInventoryZones")
    md.typeIndex = md.typeIndex or {}
    return md.typeIndex
end

local function playerNearZone(px, py, pz, zone)
    local x1, y1, x2, y2, zz = zoneBounds(zone)
    if not allFloorsOf(zone) and pz ~= zz then return false end
    local m = IDX.MARGIN
    return px >= x1 - m and px <= x2 + m and py >= y1 - m and py <= y2 + m
end

local function countItem(counts, item)
    if not item then return end
    local ft = item:getFullType()
    if ft then counts[ft] = (counts[ft] or 0) + 1 end
end

-- ── scanning ────────────────────────────────────────────────────────────────────────
-- Returns a { [fullType]=count } map for a zone, or nil if none of its squares are loaded
-- (so we keep the last persisted snapshot instead of wiping it).
function IDX.scanZoneCounts(zone)
    local cell = getCell()
    if not cell then return nil end
    local x1, y1, x2, y2 = zoneBounds(zone)
    local zs = zLevels(zone)

    local counts, seen = {}, {}
    local loaded = false
    for _, zz in ipairs(zs) do
        for x = x1, x2 do
            for y = y1, y2 do
                local sq = cell:getGridSquare(x, y, zz)
                if sq then
                    loaded = true
                    -- items on the floor
                    local wobjs = sq:getWorldObjects()
                    for i = 0, wobjs:size() - 1 do
                        local wo = wobjs:get(i)
                        countItem(counts, wo and wo:getItem())
                    end
                    -- items inside containers (each container once)
                    local objs = sq:getObjects()
                    for i = 0, objs:size() - 1 do
                        local obj = objs:get(i)
                        local cont = obj and obj:getContainer()
                        if cont and not seen[cont] then
                            seen[cont] = true
                            local items = cont:getItems()
                            for j = 0, items:size() - 1 do
                                countItem(counts, items:get(j))
                            end
                        end
                    end
                end
            end
        end
    end

    if not loaded then return nil end
    return counts
end

-- ── persistence / mutation ──────────────────────────────────────────────────────────
function IDX.setZone(zone, counts)
    local ti = getTypeIndex()
    ti[zoneKeyOf(zone)] = { name = zone.name or zoneKeyOf(zone), types = counts, safehouseId = zone.safehouseId }
    IDX._dirty = true
end

function IDX.removeZone(zone)
    local ti = getTypeIndex()
    local key = (type(zone) == "table") and zoneKeyOf(zone) or zone
    IDX._sig[key] = nil
    IDX._lastScan[key] = nil
    if ti[key] then
        ti[key] = nil
        IDX._dirty = true
    end
end

-- Force the next IDX.update to re-scan this zone (e.g. after its floor mode was toggled).
function IDX.invalidateZone(zone)
    local key = (type(zone) == "table") and zoneKeyOf(zone) or zone
    IDX._sig[key] = nil
    IDX._lastScan[key] = nil
end

-- Move a zone's entry from its old key to its current (renamed) key, relabeling and preserving
-- counts so the lookup/tooltip update immediately without a rescan.
function IDX.renameZone(zone, oldKey)
    local newKey = zoneKeyOf(zone)
    IDX._dirty = true
    if not oldKey or oldKey == newKey then return end
    local ti = getTypeIndex()
    if ti[oldKey] then
        ti[oldKey].name = zone.name
        ti[newKey] = ti[oldKey]
        ti[oldKey] = nil
    end
    IDX._sig[newKey], IDX._sig[oldKey] = IDX._sig[oldKey], nil
    IDX._lastScan[newKey], IDX._lastScan[oldKey] = IDX._lastScan[oldKey], nil
end

-- Re-scan every in-range, loaded zone (throttled per zone). Cheap to call often.
function IDX.update(playerObj)
    if not playerObj then return end
    local sq = playerObj:getCurrentSquare()
    if not sq then return end
    local px, py, pz = sq:getX(), sq:getY(), sq:getZ()
    local now = getTimestampMs()

    for _, zone in ipairs(getZones()) do
        if playerNearZone(px, py, pz, zone) and SafehouseInventoryManager.playerCanAccessZone(playerObj, zone) then
            local key = zoneKeyOf(zone)
            local last = IDX._lastScan[key] or 0
            if now - last >= IDX.SCAN_THROTTLE_MS then
                IDX._lastScan[key] = now
                local counts = IDX.scanZoneCounts(zone)
                if counts then
                    -- Only rewrite the persisted index (and mark the lookup dirty / sync) when the
                    -- zone's contents actually changed since we last stored them.
                    local sig = signatureOf(counts)
                    if sig ~= IDX._sig[key] then
                        IDX._sig[key] = sig
                        IDX.setZone(zone, counts)
                    end
                end
            end
        end
    end
end

-- ── lookup ──────────────────────────────────────────────────────────────────────────
function IDX.getMerged()
    if IDX._merged and not IDX._dirty then return IDX._merged end

    local merged = {}
    local player = getPlayer()
    for _, z in pairs(getTypeIndex()) do
        -- Only count zones whose safehouse the local player can access (owner/member).
        if (not player) or SafehouseInventoryManager.playerCanAccessZone(player, { safehouseId = z.safehouseId }) then
        local zname = z.name
        for fullType, count in pairs(z.types or {}) do
            if count and count > 0 then
                local e = merged[fullType]
                if not e then
                    e = { total = 0, zones = {} }
                    merged[fullType] = e
                end
                e.total = e.total + count
                e.zones[#e.zones + 1] = { name = zname, count = count }
            end
        end
        end
    end

    IDX._merged = merged
    IDX._dirty = false
    return merged
end

-- Fast yes/no + count info for a single item type. Returns nil when not at your safehouse.
---@return table|nil { total=number, zones={ {name=string, count=number}, ... } }
function IDX.getInfo(fullType)
    if not fullType then return nil end
    local e = IDX.getMerged()[fullType]
    if not e or e.total <= 0 then return nil end
    return e
end

function IDX.markDirty()
    IDX._dirty = true
end

-- ── wiring ──────────────────────────────────────────────────────────────────────────
-- Zones (and the persisted typeIndex) become available with global mod data.
Events.OnInitGlobalModData.Add(function()
    IDX._dirty = true
end)

-- Periodic refresh of whatever base zones are currently loaded around the player.
Events.EveryTenMinutes.Add(function()
    local p = getPlayer()
    if p then IDX.update(p) end
end)

return SafehouseInventoryIndex
