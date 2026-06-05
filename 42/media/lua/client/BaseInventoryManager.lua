-- This contains the zone manager (not the zone manager WINDOW), which handles all the data

-- STRUCTURE OF ModData FOR THIS MOD:
-- ModData
-- --BaseInventoryZones
-- ----zones
-- ------name
-- ------x1
-- ------y1
-- ------x2
-- ------y2

BaseInventoryManager = BaseInventoryManager or {}
BaseInventoryManager.zoneItemCache = BaseInventoryManager.zoneItemCache or {}

function BaseInventoryManager:getAllZones()
    self.zones = self.zones or {}
    return self.zones
end

function BaseInventoryManager:addZone(zone)
    self.zones = self.zones or {}
    table.insert(self.zones, zone)
    self:save()
end

function BaseInventoryManager:removeZone(zone)
    local zoneKey = zone.name or (zone.x1 .. "," .. zone.y1 .. "," .. (zone.z or 0))
    self.zoneItemCache[zoneKey] = nil

    self.zones = self.zones or {}
    for i = #self.zones, 1, -1 do
        if self.zones[i] == zone then
            table.remove(self.zones, i)
            break
        end
    end
    self:save()
end

function BaseInventoryManager:save()
    print("Base Inventory: saving zones.")
    local md = ModData.getOrCreate("BaseInventoryZones")
    md.zones = self.zones or {}
    md.zoneItemCache = self.zoneItemCache or {} -- overwrite ModData's cache
    ModData.transmit("BaseInventoryZones")
end

function BaseInventoryManager:load()
    print("Base Inventory: loading zones.")
    local md = ModData.getOrCreate("BaseInventoryZones")
    -- One-time migration from the original "Home Inventory" mod so existing zones carry over.
    if (not md.zones) or (#md.zones == 0) then
        local old = ModData.getOrCreate("HomeInventoryZones")
        if old and old.zones and #old.zones > 0 then
            print("Base Inventory: migrating zones from Home Inventory.")
            md.zones = old.zones
            md.zoneItemCache = old.zoneItemCache or {}
            ModData.transmit("BaseInventoryZones")
        end
    end
    self.zones = md.zones or {}
    self.zoneItemCache = md.zoneItemCache or {} -- overwrite local cache
    if BaseInventoryPanel.instance then
        BaseInventoryPanel.instance:populateList()
    end
end

function BaseInventoryManager:getItemsInZone(zone)
    local zoneKey = zone.name or (zone.x1 .. "," .. zone.y1 .. "," .. (zone.z or 0))
    local items = {}

    if self:isZoneLoaded(zone) then
        for x = math.min(zone.x1, zone.x2), math.max(zone.x1, zone.x2) do
            for y = math.min(zone.y1, zone.y2), math.max(zone.y1, zone.y2) do
                local square = getCell():getGridSquare(x, y, zone.z)
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

function BaseInventoryManager:getAllItemInfo()
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

    for _, zone in ipairs(self:getAllZones()) do
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

function BaseInventoryManager:isZoneLoaded(zone)
    local zx1, zx2 = math.min(zone.x1, zone.x2), math.max(zone.x1, zone.x2)
    local zy1, zy2 = math.min(zone.y1, zone.y2), math.max(zone.y1, zone.y2)
    local zz = zone.z or 0

    for x = zx1, zx2 do
        for y = zy1, zy2 do
            if getCell():getGridSquare(x, y, zz) then
                return true -- At least one square is loaded
            end
        end
    end
    return false
end

function BaseInventoryManager:isAnyZoneLoaded()
    for _, zone in ipairs(self:getAllZones()) do
        if self:isZoneLoaded(zone) then
            return true
        end
    end
    return false
end

function BaseInventoryManager:isAllZonesLoaded()
    for _, zone in ipairs(self:getAllZones()) do
        if not self:isZoneLoaded(zone) then
            return false
        end
    end
    return true
end

function BaseInventoryManager:refresh()
    if ISCharacterInfoWindow.instance
        and ISCharacterInfoWindow.instance.baseInventoryView then
        ISCharacterInfoWindow.instance.baseInventoryView:populateList()
    end
end

function BaseInventoryManager:getZoneByName(name)
    self.zones = self.zones or {}
    for _, zone in ipairs(self.zones) do
        if zone.name == name then
            return zone
        end
    end
    return nil
end

function BaseInventoryManager:isPlayerInZone(playerObj, zone)
    local x = playerObj:getX()
    local y = playerObj:getY()
    local z = playerObj:getZ()
    return x >= math.min(zone.x1, zone.x2) and x <= math.max(zone.x1, zone.x2)
        and y >= math.min(zone.y1, zone.y2) and y <= math.max(zone.y1, zone.y2)
        and z == (zone.z or 0)
end

function BaseInventoryManager:getZonePlayerIsIn(playerObj)
    for _, zone in ipairs(self:getAllZones()) do
        if self:isPlayerInZone(playerObj, zone) then
            return zone
        end
    end
    return nil
end

-- Load zones (and migrate from Home Inventory) once global mod data is ready.
Events.OnInitGlobalModData.Add(function()
    BaseInventoryManager:load()
end)

-- Save zones on game save
Events.OnSave.Add(function()
    BaseInventoryManager:save()
end)

-- Refresh every ten minutes
Events.EveryTenMinutes.Add(function()
    print("Base Inventory: Refreshing after 10 min.")
    BaseInventoryManager:refresh()
end)
