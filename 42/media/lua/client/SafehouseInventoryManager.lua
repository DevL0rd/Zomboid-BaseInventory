-- This contains the zone manager (not the zone manager WINDOW), which handles all the data

-- STRUCTURE OF ModData FOR THIS MOD:
-- ModData
-- --SafehouseInventoryZones
-- ----zones
-- ------name
-- ------x1
-- ------y1
-- ------x2
-- ------y2

SafehouseInventoryManager = SafehouseInventoryManager or {}
SafehouseInventoryManager.zoneItemCache = SafehouseInventoryManager.zoneItemCache or {}

-- Floors a zone covers. A zone spans every floor unless explicitly restricted to its own
-- (allFloors == false), so existing/legacy zones default to all-floors.
SafehouseInventoryManager.Z_MIN, SafehouseInventoryManager.Z_MAX = -8, 8
function SafehouseInventoryManager.zoneAllFloors(zone)
    return zone.allFloors ~= false
end
local function zoneZLevels(zone)
    if not SafehouseInventoryManager.zoneAllFloors(zone) then return { zone.z or 0 } end
    local t = {}
    for z = SafehouseInventoryManager.Z_MIN, SafehouseInventoryManager.Z_MAX do t[#t + 1] = z end
    return t
end

function SafehouseInventoryManager:getAllZones()
    self.zones = self.zones or {}
    return self.zones
end

function SafehouseInventoryManager:addZone(zone)
    self.zones = self.zones or {}
    table.insert(self.zones, zone)
    self:save()
end

function SafehouseInventoryManager:removeZone(zone)
    local zoneKey = zone.name or (zone.x1 .. "," .. zone.y1 .. "," .. (zone.z or 0))
    self.zoneItemCache[zoneKey] = nil
    -- Drop this zone's contribution to the have-at-base index too.
    if SafehouseInventoryIndex then SafehouseInventoryIndex.removeZone(zone) end

    self.zones = self.zones or {}
    for i = #self.zones, 1, -1 do
        if self.zones[i] == zone then
            table.remove(self.zones, i)
            break
        end
    end
    self:save()
end

-- Rename a zone, migrating everything keyed by its (name-derived) zone key to the new key so the
-- have-at-safehouse index, item caches and tooltips update immediately (no stale old name/count,
-- and no rescan needed even when away from the zone).
function SafehouseInventoryManager:renameZone(zone, newName)
    if not zone or not newName or newName == "" or newName == zone.name then return end
    local coords = zone.x1 .. "," .. zone.y1 .. "," .. (zone.z or 0)
    local oldKey = zone.name or coords
    zone.name = newName
    local newKey = newName

    -- Move the manager's cached item summary to the new key.
    if oldKey ~= newKey and self.zoneItemCache[oldKey] then
        self.zoneItemCache[newKey] = self.zoneItemCache[oldKey]
        self.zoneItemCache[oldKey] = nil
    end
    -- Relabel/move the index entry (preserves counts).
    if SafehouseInventoryIndex then SafehouseInventoryIndex.renameZone(zone, oldKey) end

    self:save()
    self:refresh()
end

function SafehouseInventoryManager:save()
    print("Safehouse Inventory: saving zones.")
    local md = ModData.getOrCreate("SafehouseInventoryZones")
    md.zones = self.zones or {}
    md.zoneItemCache = self.zoneItemCache or {} -- overwrite ModData's cache
    ModData.transmit("SafehouseInventoryZones")
end

function SafehouseInventoryManager:load()
    print("Safehouse Inventory: loading zones.")
    local md = ModData.getOrCreate("SafehouseInventoryZones")
    self.zones = md.zones or {}
    self.zoneItemCache = md.zoneItemCache or {} -- overwrite local cache
    if SafehouseInventoryPanel.instance then
        SafehouseInventoryPanel.instance:populateList()
    end
end

function SafehouseInventoryManager:getItemsInZone(zone)
    local zoneKey = zone.name or (zone.x1 .. "," .. zone.y1 .. "," .. (zone.z or 0))
    local items = {}

    if self:isZoneLoaded(zone) then
      for _, zz in ipairs(zoneZLevels(zone)) do
        for x = math.min(zone.x1, zone.x2), math.max(zone.x1, zone.x2) do
            for y = math.min(zone.y1, zone.y2), math.max(zone.y1, zone.y2) do
                local square = getCell():getGridSquare(x, y, zz)
                if square then
                    -- Items on the floor
                    for i = 0, square:getWorldObjects():size() - 1 do
                        local worldObj = square:getWorldObjects():get(i)
                        if worldObj and worldObj:getItem() then
                            table.insert(items, worldObj:getItem())
                        end
                    end
                    -- Items in containers
                    for i = 0, square:getObjects():size() - 1 do
                        local obj = square:getObjects():get(i)
                        if obj and obj:getContainer() then
                            local container = obj:getContainer()
                            for j = 0, container:getItems():size() - 1 do
                                local item = container:getItems():get(j)
                                table.insert(items, item)
                            end
                        end
                    end
                end
            end
        end
      end
        -- If we found items, update the cache and return them
        if #items > 0 then
            -- Apparently, the serializer can't handle objects, only simple types. so the cached items have
            -- to be saved as str or int, otherwise they won't be loaded with the save.
            local summary = {}

            local function cacheItem(item, containerName)
                local container = containerName or "-"
                if item.container then
                    local _container = item:getContainer()
                    if _container and _container.type then
                        containerName = getTextOrNull("IGUI_ContainerTitle_" .. item:getContainer():getType())
                    end
                end

                table.insert(summary, {
                    name = item:getName(),
                    displayName = item:getDisplayName(),
                    container = container
                })

                -- If it's a container, go deeper
                if item.getCategory and item:getCategory() == "Container" then
                    local contained = item:getItemContainer():getItems()
                    if contained and contained.size and contained:size() > 0 then
                        for i = 0, contained:size() - 1 do
                            local subItem = contained:get(i)
                            cacheItem(subItem, item:getDisplayName())
                        end
                    end
                end
            end

            for _, item in ipairs(items) do
                cacheItem(item)
            end
            self.zoneItemCache[zoneKey] = summary
            self:save()
            return items -- still return full items if zone is loaded
        else
            -- return cached item *summaries*
            return self.zoneItemCache[zoneKey] or {}
        end
    else
        -- Zone not loaded, use cached items if available
        return self.zoneItemCache[zoneKey] or {}
    end
end

function SafehouseInventoryManager:getAllItemInfo()
    local itemMap = {}


    local function processItem(item, zone)
        local name = item:getDisplayName()

        local sourceContainer = nil
        local sourceObject = nil

        if item:getContainer() then
            sourceContainer = item:getContainer()
            if item:getContainer() then
                if sourceContainer.getParent then
                    sourceObject = sourceContainer:getParent()
                end
            end
        end

        -- Start assuming the container is "-" and try to get the actual container
        local container = "-"
        if item:getContainer() then
            local parentItem = item:getContainer():getContainingItem()
            if parentItem then
                container = parentItem:getDisplayName()
            else
                container = getTextOrNull("IGUI_ContainerTitle_" .. item:getContainer():getType()) or
                    item:getContainer():getType() -- fallback
            end
        end

        -- Here, the | is used as a delimiter because we don't want to group items by name
        -- in case they are in different containers or zones. In other words, we are creating
        -- a unique string for each combination of name, zone and container.
        local key = name .. "|" .. (zone.name or "Unknown") .. "|" .. container
        if not itemMap[key] then
            itemMap[key] = {
                text = name,
                amount = 0,
                zone = zone.name or "Unknown",
                inside = container,
                sourceContainer = sourceContainer,
                sourceObject = sourceObject,
            }
        end
        itemMap[key].amount = itemMap[key].amount + 1

        -- If item is an ItemContainer, process its contents recursively
        if item.getCategory and (item:getCategory() == "Container") then
            local contained = item:getItemContainer():getItems()
            if contained and contained.size and contained:size() > 0 then
                for i = 0, contained:size() - 1 do
                    local subItem = contained:get(i)
                    processItem(subItem, zone)
                end
            end
        end
    end

    local zones = getPlayer() and self:getAccessibleZones(getPlayer()) or self:getAllZones()
    for _, zone in ipairs(zones) do
        for _, item in ipairs(self:getItemsInZone(zone)) do
            if item.getDisplayName then
                -- only works when zone is loaded
                processItem(item, zone)
            elseif item.displayName then
                -- summary mode (when items are cached)
                local key = item.displayName .. "|" .. (zone.name or "Unknown") .. "|" .. item.container
                if not itemMap[key] then
                    itemMap[key] = {
                        text = item.displayName,
                        amount = 0,
                        zone = zone.name or "Unknown",
                        inside = item.container
                    }
                end
                itemMap[key].amount = itemMap[key].amount + 1
            end
        end
    end

    -- Convert map to array for UI
    local grouped = {}
    for _, v in pairs(itemMap) do
        table.insert(grouped, v)
    end
    return grouped
end

function SafehouseInventoryManager:isZoneLoaded(zone)
    local zx1, zx2 = math.min(zone.x1, zone.x2), math.max(zone.x1, zone.x2)
    local zy1, zy2 = math.min(zone.y1, zone.y2), math.max(zone.y1, zone.y2)

    for _, zz in ipairs(zoneZLevels(zone)) do
        for x = zx1, zx2 do
            for y = zy1, zy2 do
                if getCell():getGridSquare(x, y, zz) then
                    return true -- At least one square is loaded
                end
            end
        end
    end
    return false
end

function SafehouseInventoryManager:isAnyZoneLoaded()
    for _, zone in ipairs(self:getAllZones()) do
        if self:isZoneLoaded(zone) then
            return true
        end
    end
    return false
end

function SafehouseInventoryManager:isAllZonesLoaded()
    for _, zone in ipairs(self:getAllZones()) do
        if not self:isZoneLoaded(zone) then
            return false
        end
    end
    return true
end

function SafehouseInventoryManager:refresh()
    if ISCharacterInfoWindow.instance
        and ISCharacterInfoWindow.instance.safehouseInventoryView then
        ISCharacterInfoWindow.instance.safehouseInventoryView:populateList()
    end
end

function SafehouseInventoryManager:getZoneByName(name)
    self.zones = self.zones or {}
    for _, zone in ipairs(self.zones) do
        if zone.name == name then
            return zone
        end
    end
    return nil
end

function SafehouseInventoryManager:isPlayerInZone(playerObj, zone)
    local x = playerObj:getX()
    local y = playerObj:getY()
    local z = playerObj:getZ()
    return x >= math.min(zone.x1, zone.x2) and x <= math.max(zone.x1, zone.x2)
        and y >= math.min(zone.y1, zone.y2) and y <= math.max(zone.y1, zone.y2)
        and (SafehouseInventoryManager.zoneAllFloors(zone) or z == (zone.z or 0))
end

function SafehouseInventoryManager:getZonePlayerIsIn(playerObj)
    for _, zone in ipairs(self:getAllZones()) do
        if self:isPlayerInZone(playerObj, zone) then
            return zone
        end
    end
    return nil
end

-- ── Safehouse association & access ────────────────────────────────────────────────────
-- Zones live inside a claimed safehouse and are shared with that safehouse's members. Each zone
-- is tagged with a stable safehouseId at creation; visibility/use is then filtered by membership.

-- Stable identifier for a SafeHouse instance.
function SafehouseInventoryManager.safehouseId(sh)
    if not sh then return nil end
    if sh.getId then
        local ok, id = pcall(function() return sh:getId() end)
        if ok and id ~= nil then return "id:" .. tostring(id) end
    end
    return "loc:" .. tostring(sh:getOwner()) .. "@" .. tostring(sh:getX()) .. "," .. tostring(sh:getY())
end

-- Is the player the owner of, or a member of, this safehouse?
function SafehouseInventoryManager.accessibleSafehouse(sh, playerObj)
    if not sh or not playerObj then return false end
    local u = (playerObj.getUsername and playerObj:getUsername()) or ""
    if sh:getOwner() == u then return true end
    local players = sh:getPlayers()
    if players then
        for i = 0, players:size() - 1 do
            if players:get(i) == u then return true end
        end
    end
    return false
end

-- The accessible safehouse covering a square (owner/member only), or nil.
function SafehouseInventoryManager.safehouseAt(square, playerObj)
    if not (SafeHouse and SafeHouse.getSafeHouse and square) then return nil end
    local sh = SafeHouse.getSafeHouse(square)
    if sh and SafehouseInventoryManager.accessibleSafehouse(sh, playerObj) then return sh end
    return nil
end

-- Can the player see/use a zone? True when its safehouse exists and the player is owner/member.
-- If the SafeHouse system is unavailable for some reason, fail open (don't hide zones).
function SafehouseInventoryManager.playerCanAccessZone(playerObj, zone)
    if not zone then return false end
    if not (SafeHouse and SafeHouse.getSafehouseList) then return true end
    if not zone.safehouseId then return false end -- zone not tied to a safehouse
    local list = SafeHouse.getSafehouseList()
    if not list then return true end
    for i = 0, list:size() - 1 do
        local sh = list:get(i)
        if SafehouseInventoryManager.safehouseId(sh) == zone.safehouseId then
            return SafehouseInventoryManager.accessibleSafehouse(sh, playerObj)
        end
    end
    return false
end

-- Zones the player may see/use (owner/member of their safehouse).
function SafehouseInventoryManager:getAccessibleZones(playerObj)
    local out = {}
    for _, zone in ipairs(self:getAllZones()) do
        if SafehouseInventoryManager.playerCanAccessZone(playerObj, zone) then
            out[#out + 1] = zone
        end
    end
    return out
end

-- Load zones (and migrate from Home Inventory) once global mod data is ready.
Events.OnInitGlobalModData.Add(function()
    SafehouseInventoryManager:load()
end)

-- Save zones on game save
Events.OnSave.Add(function()
    SafehouseInventoryManager:save()
end)

-- Refresh every ten minutes
Events.EveryTenMinutes.Add(function()
    print("Safehouse Inventory: Refreshing after 10 min.")
    SafehouseInventoryManager:refresh()
end)
