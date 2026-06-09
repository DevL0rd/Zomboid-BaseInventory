--[[
    Safehouse Inventory - per-zone inventory tabs
    ----------------------------------------
    For each Safehouse zone you're currently in range of, adds a loot-window tab (named after the zone)
    that merges every container in that zone into one inventory you can browse, take from, and
    craft/cook with. One tab per in-range zone - no "all zones" combined tab. If no zones are in
    range, a single empty "Safehouse Inventory" tab is shown so the right-click Manage Zones menu stays
    reachable.

    Selection is sticky: clicking a Safehouse Inventory tab keeps it selected across loot-window refreshes
    (moving / approaching world containers won't switch you off it); clicking or scrolling to a real
    container switches away.

    Crafting (cooking / AutoCook / hand-craft) pulls from the REAL loaded zone containers via the
    getContainers hook; the synthetic tab containers are always stripped from that list, so items are
    never double-counted and away/unloaded items can't be used.

    Loot-window hooking adapted from Proximity Inventory (B42.19 fork); source changed to the zone.
]]

SafehouseInventoryTab = SafehouseInventoryTab or {}
local BIT = SafehouseInventoryTab

BIT.MARGIN = 3 -- tiles of slack around a zone

BIT.options = PZAPI.ModOptions:create("SafehouseInventory", getText("UI_SafehouseInventory_TabName"))
BIT.isEnabled = BIT.options:addTickBox("SafehouseInventory_isEnabled", getText("UI_SafehouseInventory_Opt_Enable"), true)
-- "Have-at-safehouse" indicator: a house badge on items you already store at a safehouse zone, shown
-- on every item everywhere, plus a per-zone breakdown in the item tooltip. (See
-- SafehouseInventoryIndex.lua / SafehouseInventoryIndicator.lua.)
BIT.showBadge = BIT.options:addTickBox("SafehouseInventory_showBadge", getText("UI_SafehouseInventory_Opt_Badge"), true)
BIT.showTooltip = BIT.options:addTickBox("SafehouseInventory_showTooltip", getText("UI_SafehouseInventory_Opt_Tooltip"), true)
-- When ON (default), crafting that needs a zone item the player isn't holding makes the character
-- walk to the crate and take it into their inventory first (per ingredient, so multiple containers =
-- multiple trips). Turn OFF to consume zone items instantly at a distance instead.
BIT.walkToFetch = BIT.options:addTickBox("SafehouseInventory_walkToFetch", getText("UI_SafehouseInventory_Opt_WalkToFetch"), true)
-- Close doors the character opens by walking through them, once they've walked clear. Only doors that
-- were CLOSED when reached are closed back -- doors already standing open are left as they were.
BIT.autoCloseDoors = BIT.options:addTickBox("SafehouseInventory_autoCloseDoors", getText("UI_SafehouseInventory_Opt_AutoCloseDoors"), true)

-- Per-player state
BIT.zoneItemContainer = {}    -- [playerNum][zoneKey] = ItemContainer ("safehouseInvZone")
BIT.placeholderContainer = {} -- [playerNum] = empty ItemContainer ("safehouseInv") shown when no zones in range
BIT.zoneButtonRefs = {}       -- [playerNum] = { { btn=, containers={} }, ... }
BIT.allSynthetic = {}         -- [playerNum] = { ItemContainer... } active this refresh (crafting strip)
BIT._lastZones = {}           -- [playerNum] = result of getInRangeZones
BIT.stickContainer = {}       -- [playerNum] = the safehouseInv container the user is viewing, or nil

BIT.icon = getTexture("media/textures/SafehouseInventory_Home.png") or getTexture("media/ui/Panel_Icon_Pin.png")

local function isSafehouseInvType(t)
    return t == "safehouseInv" or t == "safehouseInvZone"
end

-- ── Zone reading + container enumeration ────────────────────────────────────────────
local function getZones()
    local md = ModData.getOrCreate("SafehouseInventoryZones")
    return (md and md.zones) or {}
end

local function zoneBounds(zone)
    return math.min(zone.x1, zone.x2), math.min(zone.y1, zone.y2),
           math.max(zone.x1, zone.x2), math.max(zone.y1, zone.y2), (zone.z or 0)
end

-- A zone spans every floor unless explicitly restricted to its own (allFloors == false).
BIT.Z_MIN, BIT.Z_MAX = -8, 8
local function allFloorsOf(zone)
    return zone.allFloors ~= false
end
local function zLevels(zone)
    if not allFloorsOf(zone) then return { zone.z or 0 } end
    local t = {}
    for z = BIT.Z_MIN, BIT.Z_MAX do t[#t + 1] = z end
    return t
end

local function playerNearZone(px, py, pz, zone)
    local x1, y1, x2, y2, zz = zoneBounds(zone)
    if not allFloorsOf(zone) and pz ~= zz then return false end
    local m = BIT.MARGIN
    return px >= x1 - m and px <= x2 + m and py >= y1 - m and py <= y2 + m
end

-- Persistent per-(player,zone) "floor" container gathering the zone's loose ground items. Ground
-- loot isn't in any container (it's IsoWorldInventoryObjects on the square), so -- like the vanilla
-- loot window's floor tab -- we collect it into one synthetic "floor" container, rebuilt each scan.
-- Items are shared BY REFERENCE (getItems():add, never AddItem) so we never reparent or remove the
-- real ground loot.
BIT.zoneFloorContainer = {} -- [playerNum][zoneKey] = ItemContainer ("floor")
local function getZoneFloorContainer(pnum, key)
    BIT.zoneFloorContainer[pnum] = BIT.zoneFloorContainer[pnum] or {}
    if not BIT.zoneFloorContainer[pnum][key] then
        local c = ItemContainer.new("floor", nil, nil)
        c:setExplored(true)
        BIT.zoneFloorContainer[pnum][key] = c
    end
    return BIT.zoneFloorContainer[pnum][key]
end

-- Every zone the player is in range of, each with its loaded containers (may be empty).
local function getInRangeZones(playerObj)
    local out = {}
    local sq = playerObj:getCurrentSquare()
    if not sq then return out end
    local px, py, pz = sq:getX(), sq:getY(), sq:getZ()
    local cell = getCell()
    if not cell then return out end
    local pnum = playerObj:getPlayerNum()

    for _, zone in ipairs(getZones()) do
        if playerNearZone(px, py, pz, zone) and SafehouseInventoryManager.playerCanAccessZone(playerObj, zone) then
            local x1, y1, x2, y2, zz = zoneBounds(zone)
            local key = zone.name or (x1 .. "," .. y1 .. "," .. zz)
            local seen, conts = {}, {}

            -- gather loose floor loot into the zone's synthetic floor container
            local floorCont = getZoneFloorContainer(pnum, key)
            floorCont:getItems():clear()
            local floorCount = 0

            for _, z in ipairs(zLevels(zone)) do
                for x = x1, x2 do
                    for y = y1, y2 do
                        local s = cell:getGridSquare(x, y, z)
                        if s then
                            -- real object containers (crates / shelves / fridges / counters / ...)
                            local objs = s:getObjects()
                            for i = 0, objs:size() - 1 do
                                local obj = objs:get(i)
                                local cont = obj and obj:getContainer()
                                if cont and not seen[cont] then
                                    seen[cont] = true
                                    conts[#conts + 1] = cont
                                end
                            end
                            -- loose items on the ground (no container -> share into floorCont)
                            local wobs = s:getWorldObjects()
                            if wobs then
                                for i = 0, wobs:size() - 1 do
                                    local wob = wobs:get(i)
                                    local it = wob and wob:getItem()
                                    if it then floorCont:getItems():add(it); floorCount = floorCount + 1 end
                                end
                            end
                        end
                    end
                end
            end
            if floorCount > 0 then conts[#conts + 1] = floorCont end

            out[#out + 1] = { zone = zone, key = key, containers = conts }
        end
    end
    return out
end

local function getZoneContainersFlat(playerObj)
    local out, seen = {}, {}
    for _, z in ipairs(getInRangeZones(playerObj)) do
        for _, c in ipairs(z.containers) do
            if not seen[c] then seen[c] = true; out[#out + 1] = c end
        end
    end
    return out
end

local function newSynthetic(name)
    local c = ItemContainer.new(name, nil, nil)
    c:setExplored(true)
    c:setOnlyAcceptCategory("none")
    c:setCapacity(0)
    return c
end

local function getZoneContainer(playerNum, key)
    BIT.zoneItemContainer[playerNum] = BIT.zoneItemContainer[playerNum] or {}
    if not BIT.zoneItemContainer[playerNum][key] then
        BIT.zoneItemContainer[playerNum][key] = newSynthetic("safehouseInvZone")
    end
    return BIT.zoneItemContainer[playerNum][key]
end

local function getPlaceholderContainer(playerNum)
    if not BIT.placeholderContainer[playerNum] then
        BIT.placeholderContainer[playerNum] = newSynthetic("safehouseInv")
    end
    return BIT.placeholderContainer[playerNum]
end

-- ── begin: one tab per in-range zone, or a single empty placeholder tab ──────────────
local function addSafehouseInventoryButtons(invSelf)
    local pnum = invSelf.player
    local playerObj = getSpecificPlayer(pnum)
    BIT.zoneButtonRefs[pnum] = {}
    BIT.allSynthetic[pnum] = {}
    if not playerObj then return end

    local zones = getInRangeZones(playerObj)
    BIT._lastZones[pnum] = zones

    if #zones == 0 then
        -- No zones in range: keep one empty tab so its right-click (Manage Zones) still works.
        local ph = getPlaceholderContainer(pnum)
        ph:clear()
        invSelf:addContainerButton(ph, BIT.icon, getText("UI_SafehouseInventory_TabName"))
        BIT.allSynthetic[pnum][#BIT.allSynthetic[pnum] + 1] = ph
        return
    end

    for _, z in ipairs(zones) do
        local sc = getZoneContainer(pnum, z.key)
        sc:clear()
        local b = invSelf:addContainerButton(sc, BIT.icon, z.zone.name or z.key)
        BIT.zoneButtonRefs[pnum][#BIT.zoneButtonRefs[pnum] + 1] = { btn = b, containers = z.containers }
        BIT.allSynthetic[pnum][#BIT.allSynthetic[pnum] + 1] = sc
    end
end

-- ── buttonsAdded: fill each zone tab from its containers ────────────────────────────
local function onButtonsAdded(invSelf)
    local pnum = invSelf.player
    for _, zr in ipairs(BIT.zoneButtonRefs[pnum] or {}) do
        for _, c in ipairs(zr.containers) do
            zr.btn.inventory:getItems():addAll(c:getItems())
        end
    end
end

-- ── Sticky selection ────────────────────────────────────────────────────────────────
local function containerPresent(invSelf, c)
    for i = 1, #invSelf.backpacks do
        if invSelf.backpacks[i].inventory == c then return true end
    end
    return false
end

-- Scroll fix: a synthetic container breaks vanilla getCurrentBackpackIndex (returns -1),
-- turning the wheel into camera zoom. Resolve the index via selectedButton instead.
local function patchMouseWheel(invSelf)
    if invSelf._safehouseInvMouseWheelPatched then return end
    invSelf._safehouseInvMouseWheelPatched = true

    local _orig = invSelf.onMouseWheel
    invSelf.onMouseWheel = function(self, del)
        if not BIT.isEnabled:getValue() or self.onCharacter
            or not (self.inventory and isSafehouseInvType(self.inventory:getType()))
        then
            return _orig(self, del)
        end

        local inContainerArea
        if self.isPageLeft then
            if self:isPageLeft() then
                inContainerArea = self:getMouseX() < self.containerButtonPanel.width
            else
                inContainerArea = self:getMouseX() >= (self:getWidth() - self.containerButtonPanel.width)
            end
        else
            inContainerArea = self:getMouseX() >= (self:getWidth() - self.buttonSize)
        end

        if not inContainerArea and not self:isCycleContainerKeyDown() then
            return true
        end

        local currentIndex = -1
        if self.selectedButton then
            for i = 1, #self.backpacks do
                if self.backpacks[i] == self.selectedButton then currentIndex = i; break end
            end
        end

        local ms = getTimestampMs()
        self.lastMouseWheelMS = self.lastMouseWheelMS or 0
        local wrap = (self.containerButtonPanel.height > self.containerButtonPanel:getScrollHeight())
            or (ms - self.lastMouseWheelMS > 750)
        self.lastMouseWheelMS = ms

        local unlockedIndex = (del < 0)
            and self:prevUnlockedContainer(currentIndex, wrap)
            or self:nextUnlockedContainer(currentIndex, wrap)

        if unlockedIndex ~= -1 then
            -- selectContainer() updates the sticky selection generically (see hook below)
            self:selectContainer(self.backpacks[unlockedIndex])
        end
        return true
    end
end

-- Keep the user's chosen Safehouse Inventory tab selected across refreshes.
local function onRefreshEnd(invSelf)
    local pnum = invSelf.player
    local stick = BIT.stickContainer[pnum]
    if not stick then return end

    local target = containerPresent(invSelf, stick) and stick or nil
    if not target then
        -- the zone tab vanished (walked away / zone renamed); fall back to any present tab of ours
        for _, c in ipairs(BIT.allSynthetic[pnum] or {}) do
            if containerPresent(invSelf, c) then target = c; break end
        end
        BIT.stickContainer[pnum] = target
    end
    if not target then return end

    invSelf.inventoryPane.inventory = target
    invSelf.inventoryPane.lastinventory = target
    invSelf.inventory = target

    invSelf.title = nil
    for _, cb in ipairs(invSelf.backpacks) do
        if cb.inventory == target then
            invSelf.selectedButton = cb
            cb:setBackgroundRGBA(0.7, 0.7, 0.7, 1.0)
            invSelf.title = cb.name
        else
            cb:setBackgroundRGBA(0.0, 0.0, 0.0, 0.0)
        end
    end

    if invSelf.inventoryPane then invSelf.inventoryPane:refreshContainer() end
end

-- ── Lifecycle wiring ────────────────────────────────────────────────────────────────
Events.OnRefreshInventoryWindowContainers.Add(function(invSelf, state)
    if not BIT.isEnabled:getValue() or invSelf.onCharacter then return end
    local ok, err = pcall(function()
        if state == "begin" then
            patchMouseWheel(invSelf)
            addSafehouseInventoryButtons(invSelf)
        elseif state == "buttonsAdded" then
            onButtonsAdded(invSelf)
        elseif state == "end" then
            onRefreshEnd(invSelf)
        end
    end)
    if not ok then print("[SafehouseInventory] tab refresh error (" .. tostring(state) .. "): " .. tostring(err)) end
end)

-- Sticky selection: selecting any real container through selectContainer() -- a UI tab click
-- (onBackpackClick), a world-container click, the scroll wheel, keyboard prev/next -- releases our
-- zone tab; selecting one of our zone tabs locks it.
--
-- EXCEPTION: while you take items from a zone tab, ISInventoryTransferAction keeps re-selecting the
-- item's source container (its update()/perform() call selectButtonForContainer). That's not the
-- player choosing a tab. We flag the loot page only for the duration of those transfer methods and
-- skip the release while flagged -- genuine selections aren't inside a transfer, so they're untouched.
local old_selectContainer = ISInventoryPage.selectContainer
function ISInventoryPage:selectContainer(button)
    if button and button.inventory and not self._safehouseInvProgrammatic then
        local pnum = self.player or 0
        BIT.stickContainer[pnum] = isSafehouseInvType(button.inventory:getType()) and button.inventory or nil
    end
    return old_selectContainer(self, button)
end

local function safehouseInvRunGuarded(action, orig)
    local loot = getPlayerLoot and action.character and getPlayerLoot(action.character:getPlayerNum())
    if loot then loot._safehouseInvProgrammatic = true end
    local ok, err = pcall(orig, action)
    if loot then loot._safehouseInvProgrammatic = false end
    if not ok then error(err, 0) end
end

local old_ISInventoryTransferAction_update = ISInventoryTransferAction.update
function ISInventoryTransferAction:update() safehouseInvRunGuarded(self, old_ISInventoryTransferAction_update) end

local old_ISInventoryTransferAction_perform = ISInventoryTransferAction.perform
function ISInventoryTransferAction:perform() safehouseInvRunGuarded(self, old_ISInventoryTransferAction_perform) end

-- ── Right-click context menu (Manage zones) ─────────────────────────────────────────
local function openZoneManager()
    local playerObj = getPlayer()
    if not playerObj then return end
    local playerNum = playerObj:getPlayerNum()
    local ui = SafehouseInventoryZonePanel.instance
    if not ui then
        ui = SafehouseInventoryZonePanel:new(getPlayerScreenLeft(playerNum) + 100, getPlayerScreenTop(playerNum) + 100, 500, 500, playerObj)
        ui:initialise()
        ui:addToUIManager()
    else
        ui:setVisible(true)
        ui:centerOnScreen(playerNum)
        ui:addToUIManager()
        ui:populateList()
    end
end

local old_onBackpackRightMouseDown = ISInventoryPage.onBackpackRightMouseDown
function ISInventoryPage:onBackpackRightMouseDown(x, y)
    local container = self.inventory
    if container and isSafehouseInvType(container:getType()) then
        local page = self.parent and self.parent.parent
        local playerNum = self.player or (page and page.player) or 0
        local context = ISContextMenu.get(playerNum, getMouseX(), getMouseY())
        if not context then return end
        context:addOption(getText("UI_SafehouseInventory_ManageZonesButton"), nil, openZoneManager)
        return
    end
    return old_onBackpackRightMouseDown(self, x, y)
end

-- ── CRAFTING / BUILDING: make zone-stored items usable as materials ──────────────────
-- Persistent per-player "craft proxy": a null-square synthetic container. The engine
-- (BaseCraftingLogic.isContainersAccessible) rejects the WHOLE craft if ANY container in the pool is
-- more than 2.5 tiles from the player -- so feeding it our real, far-away zone crates killed crafting
-- the instant a zone was in range, even for an item already in your hand. That distance check is
-- skipped when a container has no square (outer.getSquare() == null), so a synthetic container always
-- counts as "accessible". We pour the zone's items into it (shared references): the items stay
-- craftable from anywhere, and the engine consumes each from its real container (no distance check at
-- consume time). This is the same shape Proximity uses, and why Proximity never broke crafting.
BIT.craftProxy = {} -- [playerNum] = ItemContainer ("safehouseInvCraft")
local function getCraftProxy(pnum)
    if not BIT.craftProxy[pnum] then
        local c = ItemContainer.new("safehouseInvCraft", nil, nil)
        c:setExplored(true)
        BIT.craftProxy[pnum] = c
    end
    return BIT.craftProxy[pnum]
end

local orig_getContainers = ISInventoryPaneContextMenu.getContainers
ISInventoryPaneContextMenu.getContainers = function(character)
    local list = orig_getContainers(character)
    if not character or not list then return list end

    local pnum = character:getPlayerNum()
    -- strip our synthetic loot-window tabs so their shared items aren't double-counted
    for _, c in ipairs(BIT.allSynthetic[pnum] or {}) do
        if list:contains(c) then list:remove(c) end
    end

    -- Pour the zone's items (crates + loose floor loot) into the accessible craft proxy, deduped at
    -- the ITEM level: anything already present in the pool -- a crate you're standing at, or floor
    -- loot the engine already lists in its own floor tab right under you -- is skipped, so no item is
    -- ever counted twice.
    local ok, conts = pcall(getZoneContainersFlat, character)
    if ok and conts and #conts > 0 then
        local seen = {}
        for ci = 0, list:size() - 1 do
            local its = list:get(ci):getItems()
            for ii = 0, its:size() - 1 do seen[its:get(ii)] = true end
        end
        local proxy = getCraftProxy(pnum)
        proxy:getItems():clear()
        for i = 1, #conts do
            local its = conts[i]:getItems()
            for ii = 0, its:size() - 1 do
                local it = its:get(ii)
                if it and not seen[it] then
                    proxy:getItems():add(it)
                    seen[it] = true
                end
            end
        end
        if proxy:getItems():size() > 0 and not list:contains(proxy) then
            list:add(proxy)
        end
    end

    return list
end

-- ── Post-craft refresh + optional walk-to-fetch ──────────────────────────────────────
-- Rebuild the loot window so an item consumed straight out of a zone crate stops showing in the tab.
local function refreshLootFor(playerObj)
    if not playerObj then return end
    pcall(function()
        local loot = getPlayerLoot(playerObj:getPlayerNum())
        if loot and loot.refreshBackpacks then loot:refreshBackpacks() end
    end)
end

-- Walk the character to each crate holding a needed ingredient that's out of reach, and take it into
-- inventory BEFORE the craft runs. Per ingredient, so two ingredients in two crates = two trips.
-- Best-effort: if a crate can't be reached, that item is left for the proxy to supply remotely, so the
-- craft never breaks. Items already on the player / within reach are skipped (used directly).
local function queueZoneFetch(playerObj, logic)
    if not (playerObj and logic and logic.getRecipeData) then return end
    local okRD, rd = pcall(function() return logic:getRecipeData() end)
    if not okRD or not rd or not rd.getAllInputItems then return end
    local okItems, items = pcall(function() return rd:getAllInputItems() end)
    if not okItems or not items then return end
    local inv = playerObj:getInventory()

    -- Collect the out-of-reach world crates we need to visit (matches the engine's 2.5-tile gate);
    -- items on the player / already within reach are left for the craft to use directly.
    local targets = {}
    for i = 0, items:size() - 1 do
        pcall(function()
            local item = items:get(i)
            local cont = item and item:getContainer()
            if not cont or cont == inv then return end
            local outer = cont:getOutermostContainer()
            local obj = outer and outer:getParent()
            local sq = obj and obj.getSquare and obj:getSquare()
            if sq and sq:DistToProper(playerObj) > 2.0 then
                targets[#targets + 1] = { item = item, cont = cont, obj = obj, x = sq:getX(), y = sq:getY(), z = sq:getZ() }
            end
        end)
    end
    if #targets == 0 then return end

    -- Greedy nearest-neighbour route: from where we stand, always head to the closest remaining crate,
    -- then plan the next leg from THAT crate. Minimises back-and-forth without a full (expensive) TSP.
    -- The game has no synchronous path-distance call, so we use straight-line X/Y distance plus a flat
    -- per-floor penalty: a crate on another floor (through a ceiling/floor) is treated as much further,
    -- since you actually have to detour to the stairs. (The walk itself still pathfinds up/down fine.)
    local FLOOR_PENALTY = 50 -- "tiles" of detour added per floor of difference
    local curX, curY, curZ = playerObj:getX(), playerObj:getY(), math.floor(playerObj:getZ())
    while #targets > 0 do
        local bestIdx, bestD = 1, math.huge
        for idx = 1, #targets do
            local t = targets[idx]
            local dx, dy = t.x - curX, t.y - curY
            local d = math.sqrt(dx * dx + dy * dy) + math.abs(t.z - curZ) * FLOOR_PENALTY
            if d < bestD then bestD = d; bestIdx = idx end
        end
        local t = table.remove(targets, bestIdx)
        -- keepActions=true so each walk is APPENDED to the queue rather than clearing it
        if luautils.walkAdjObject(playerObj, t.obj, true, true) then
            ISTimedActionQueue.add(ISInventoryTransferAction:new(playerObj, t.item, t.cont, inv, nil))
        end
        curX, curY, curZ = t.x, t.y, t.z -- plan the next leg from this crate
    end
end

-- Shared hand-craft entry points: vanilla context-menu craft, vanilla craft window, and NeatCrafting
-- all funnel through these. Pre-queue the fetch (when enabled) and refresh the tab after.
if ISEntityUI then
    local _origStart = ISEntityUI.HandcraftStart
    if _origStart then
        ISEntityUI.HandcraftStart = function(_player, _logic, force, addToQueue, eatPercentage)
            if BIT.isEnabled:getValue() and BIT.walkToFetch:getValue() then pcall(queueZoneFetch, _player, _logic) end
            return _origStart(_player, _logic, force, addToQueue, eatPercentage)
        end
    end
    local _origMulti = ISEntityUI.HandcraftStartMultiple
    if _origMulti then
        ISEntityUI.HandcraftStartMultiple = function(_player, _logic, force, qty, addToQueue)
            if BIT.isEnabled:getValue() and BIT.walkToFetch:getValue() then pcall(queueZoneFetch, _player, _logic) end
            return _origMulti(_player, _logic, force, qty, addToQueue)
        end
    end
end

-- Refresh the tab after the craft consumes (so remotely-used zone items vanish from it immediately).
if ISHandcraftAction and ISHandcraftAction.perform then
    local _origHCPerform = ISHandcraftAction.perform
    function ISHandcraftAction:perform()
        _origHCPerform(self)
        refreshLootFor(self.character)
    end
end

-- ── Auto-close doors opened while walking ────────────────────────────────────────────
-- Close a door the character opened by pathing through it, once they've walked clear. Only doors that
-- were SHUT when reached are closed back; doors already standing open are left as they were.
local _doorState = {} -- [playerNum] = { prev = sq, wasClosed = {[door]=true} (this tile only), opened = {[door]=doorSq} }

local function _asDoor(o)
    if o and o.IsOpen and o.getSquare and o.ToggleDoorSilent then return o end
    return nil
end
local function _doorBlocked(d)
    return (d.isBarricaded and d:isBarricaded()) or false
end

Events.OnPlayerUpdate.Add(function(playerObj)
    if not playerObj or not BIT.isEnabled:getValue() or not BIT.autoCloseDoors:getValue() then return end
    pcall(function()
        local cur = playerObj:getCurrentSquare()
        if not cur then return end
        local pnum = playerObj:getPlayerNum()
        local st = _doorState[pnum]
        if not st then st = { prev = nil, wasClosed = {}, opened = {} }; _doorState[pnum] = st end

        -- Crossed into a new tile? The door behind us, if it was one we opened, gets queued to close.
        -- (st.wasClosed still holds the PREVIOUS tile's closed edge-doors, recorded last frame.)
        if st.prev and st.prev ~= cur then
            local d = _asDoor(st.prev:getDoorTo(cur))
            if d and d:IsOpen() and not _doorBlocked(d) and st.wasClosed[d] then
                st.opened[d] = d:getSquare()
            end
        end

        -- Refresh the candidate set to THIS tile's closed edge-doors (bounded to <=4, no accumulation).
        st.wasClosed = {}
        local cell = getCell()
        local x, y, z = cur:getX(), cur:getY(), cur:getZ()
        for _, n in ipairs({ { x + 1, y }, { x - 1, y }, { x, y + 1 }, { x, y - 1 } }) do
            local nsq = cell:getGridSquare(n[1], n[2], z)
            local d = nsq and _asDoor(cur:getDoorTo(nsq))
            if d and not d:IsOpen() and not _doorBlocked(d) then st.wasClosed[d] = true end
        end
        st.prev = cur

        -- Close each opened door once we've stepped clear of it.
        for d, dsq in pairs(st.opened) do
            if not d:IsOpen() then
                st.opened[d] = nil
            elseif dsq and dsq:DistTo(playerObj) > 1.5 then
                d:ToggleDoorSilent()
                st.opened[d] = nil
            end
        end
    end)
end)

-- ── BaseInv: remember where items came from, send them home on drag-back ─────────────
-- Shared between Safehouse Inventory and Proximity Inventory (same modData key + helpers). Defined
-- once; whichever mod loads first sets it up, the other reuses it.
BaseInv = BaseInv or {}
if not BaseInv._init then
    BaseInv._init = true

    -- Resolve the real container an item came from, from its stamped origin {x,y,z,type}.
    function BaseInv.findOriginContainer(origin)
        if not (origin and origin.x) then return nil end
        local cell = getCell()
        local sq = cell and cell:getGridSquare(origin.x, origin.y, origin.z)
        if not sq then return nil end
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
            local o = objs:get(i)
            local c = o and o:getContainer()
            if c and (not origin.type or c:getType() == origin.type) then return c end
        end
        return nil
    end

    -- Send the currently-dragged items home: each to its origin crate (or fallbackFn's container),
    -- walking there first. Returns true (the drop is handled). Mirrors vanilla drag-state cleanup.
    function BaseInv.returnDropped(page, fallbackFn)
        local playerObj = getSpecificPlayer(page.player)
        pcall(function()
            if not playerObj or not ISMouseDrag.dragging then return end
            local dragging = ISInventoryPane.getActualItems(ISMouseDrag.dragging)
            if not dragging then return end
            local groups, order = {}, {}
            for _, item in ipairs(dragging) do
                local md = item.getModData and item:getModData()
                local target = BaseInv.findOriginContainer(md and md.BaseInv_origin) or (fallbackFn and fallbackFn(playerObj, page))
                if target and target:getParent() then
                    if not groups[target] then groups[target] = {}; order[#order + 1] = target end
                    table.insert(groups[target], item)
                end
            end
            for _, target in ipairs(order) do
                -- keepActions=true: append each walk so multiple destinations don't wipe each other
                if luautils.walkAdjObject(playerObj, target:getParent(), true, true) then
                    for _, item in ipairs(groups[target]) do
                        ISTimedActionQueue.add(ISInventoryTransferAction:new(playerObj, item, item:getContainer(), target, nil))
                    end
                end
            end
        end)
        if ISMouseDrag.draggingFocus then
            ISMouseDrag.draggingFocus:onMouseUp(0, 0)
            ISMouseDrag.draggingFocus = nil
        end
        ISMouseDrag.dragging = nil
        pcall(function() page.inventoryPane.selected = {} end)
        return true
    end

    -- Stamp an item's origin crate when it's taken from a world container into the player's inventory.
    if not BaseInv._stampPatched and ISInventoryTransferAction then
        BaseInv._stampPatched = true
        local _origTAPerform = ISInventoryTransferAction.perform
        function ISInventoryTransferAction:perform()
            pcall(function()
                local it = self.item
                local cont = it and it:getContainer()
                if it and cont and self.character and self.destContainer
                    and self.destContainer:getOutermostContainer() == self.character:getInventory() then
                    local obj = cont:getParent()
                    local sq = obj and obj.getSquare and obj:getSquare()
                    if sq then
                        it:getModData().BaseInv_origin = { x = sq:getX(), y = sq:getY(), z = sq:getZ(), type = cont:getType() }
                    end
                end
            end)
            return _origTAPerform(self)
        end
    end
end

-- Drop onto a Safehouse Inventory tab -> send the items home (origin crate, else nearest zone crate).
local function SHInv_nearestZoneCrate(playerObj)
    local best, bestD = nil, math.huge
    for _, c in ipairs(getZoneContainersFlat(playerObj)) do
        local o = c:getParent()
        local sq = o and o.getSquare and o:getSquare()
        if sq and c:getType() ~= "floor" then
            local d = sq:DistToProper(playerObj)
            if d < bestD then bestD = d; best = c end
        end
    end
    return best
end

local _SHInv_origDropInContainer = ISInventoryPage.dropItemsInContainer
function ISInventoryPage:dropItemsInContainer(button)
    if BIT.isEnabled:getValue() and ISMouseDrag.dragging and button and button.inventory
        and isSafehouseInvType(button.inventory:getType()) then
        return BaseInv.returnDropped(self, SHInv_nearestZoneCrate)
    end
    return _SHInv_origDropInContainer(self, button)
end

print("[SafehouseInventory] Per-zone tabs (sticky selection) + crafting + context menu loaded.")
