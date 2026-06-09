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
        context:addOption(getText("UI_SafehouseInventory_ForgetOrigins"), nil, function()
            local playerObj = getSpecificPlayer(playerNum)
            local conts = getZoneContainersFlat(playerObj)
            conts[#conts + 1] = playerObj and playerObj:getInventory()
            BaseInv.forgetOrigins(conts)
        end)
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
        -- Expose any zone crate the player can actually reach right now as a REAL container in the pool.
        -- This is what lets transfers to/from it pass ISInventoryTransferAction:isValid the instant we're
        -- adjacent, instead of waiting for the loot window to refresh its backpack list. That refresh lag
        -- is exactly what made multi-item takes/returns drop everything after the first item: the engine
        -- clears the whole action queue the moment one transfer looks unreachable. Within 2.5 tiles it's
        -- also inside crafting's own accessibility gate, so this stays craft-safe.
        for i = 1, #conts do
            local c = conts[i]
            local o = c:getParent()
            local sq = o and o.getSquare and o:getSquare()
            if sq and sq:DistToProper(character) <= 2.5 and not list:contains(c) then
                list:add(c)
            end
        end

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
local _doorState = {} -- [playerNum] = { prev = sq, closedSeen = {[door]=true}, opened = {[door]=doorSq} }

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
        if not st then st = { prev = nil, closedSeen = {}, opened = {} }; _doorState[pnum] = st end

        -- Crossed into a new tile? If the door we just came through is open and we'd seen it closed a
        -- moment ago, it's one we opened by walking through -- queue it to close behind us.
        if st.prev and st.prev ~= cur then
            local d = _asDoor(st.prev:getDoorTo(cur))
            if d and d:IsOpen() and not _doorBlocked(d) and st.closedSeen[d] then
                st.opened[d] = d:getSquare()
            end
        end
        st.prev = cur

        -- Forget remembered-closed doors we've stepped well clear of (keeps the set tiny).
        for d in pairs(st.closedSeen) do
            local dsq = d.getSquare and d:getSquare()
            if (not dsq) or dsq:DistTo(playerObj) > 3 then st.closedSeen[d] = nil end
        end
        -- Remember the edge-doors around us that are currently CLOSED. Crucially this is NOT wiped when a
        -- door opens -- the character opens a door while still on the near tile, so if we forgot it the
        -- instant it opened (the old bug) the crossing check above would never recognise it as ours.
        local cell = getCell()
        local x, y, z = cur:getX(), cur:getY(), cur:getZ()
        for _, n in ipairs({ { x + 1, y }, { x - 1, y }, { x, y + 1 }, { x, y - 1 } }) do
            local nsq = cell:getGridSquare(n[1], n[2], z)
            local d = nsq and _asDoor(cur:getDoorTo(nsq))
            if d and not d:IsOpen() and not _doorBlocked(d) then st.closedSeen[d] = true end
        end

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

    -- Strip the remembered origin from every item in the given containers. Backs the "forget origins"
    -- tab option, for when you reorganise storage and don't want items routing back to where they were.
    function BaseInv.forgetOrigins(containers)
        local n = 0
        for _, c in ipairs(containers or {}) do
            local its = c and c.getItems and c:getItems()
            if its then
                for i = 0, its:size() - 1 do
                    local it = its:get(i)
                    local md = it and it.getModData and it:getModData()
                    if md and md.BaseInv_origin ~= nil then md.BaseInv_origin = nil; n = n + 1 end
                end
            end
        end
        return n
    end

    -- Build an ordered list of candidate destination containers for a returned item, best first:
    --   1) its origin container, if still in scope;
    --   2) in-scope containers already holding the same item TYPE, nearest first;
    --   3) in-scope containers holding the same CATEGORY, the one with the most of that category first.
    -- returnDropped then takes the first that can fit the item within its weight capacity. `conts` is the
    -- mod's current in-scope set; the floor is never a target.
    function BaseInv.buildReturnCandidates(playerObj, item, origin, conts)
        local out, seen = {}, {}
        local function push(c)
            if c and not seen[c] and c.getType and c:getType() ~= "floor" and c.getParent and c:getParent() then
                seen[c] = true; out[#out + 1] = c
            end
        end
        local oc = BaseInv.findOriginContainer(origin)
        if oc then
            for _, c in ipairs(conts or {}) do if c == oc then push(c); break end end
        end
        local ft = item:getFullType()
        -- use the inventory's own display category (Ammo, Food, First Aid...), NOT getCategory() --
        -- that one is the coarse engine class and lumps unrelated junk (a drink with ammo) together
        local cat = item.getDisplayCategory and item:getDisplayCategory()
        local typeM, catM = {}, {}
        for _, c in ipairs(conts or {}) do
            if c and not seen[c] and c:getType() ~= "floor" then
                local o = c:getParent()
                local sq = o and o.getSquare and o:getSquare()
                if sq then
                    local its = c:getItems()
                    local tc, cc = 0, 0
                    for i = 0, its:size() - 1 do
                        local it2 = its:get(i)
                        if it2 then
                            if it2:getFullType() == ft then tc = tc + 1 end
                            if cat and it2.getDisplayCategory and it2:getDisplayCategory() == cat then cc = cc + 1 end
                        end
                    end
                    if tc > 0 then typeM[#typeM + 1] = { c = c, d = sq:DistToProper(playerObj) } end
                    if cc > 0 then catM[#catM + 1] = { c = c, n = cc } end
                end
            end
        end
        table.sort(typeM, function(a, b) return a.d < b.d end)
        for _, m in ipairs(typeM) do push(m.c) end
        table.sort(catM, function(a, b) return a.n > b.n end)
        for _, m in ipairs(catM) do push(m.c) end
        return out
    end

    -- Route a list of containers into a nearest-neighbour order from the player, penalising other floors
    -- so we finish our own floor before the stairs (the walk still pathfinds fine). Sorts in place.
    function BaseInv.routeContainers(playerObj, list)
        if not (playerObj and list) or #list < 2 then return end
        local FLOOR_PENALTY = 50
        local cx, cy, cz = playerObj:getX(), playerObj:getY(), math.floor(playerObj:getZ())
        for w = 1, #list do
            local bi, bd = w, math.huge
            for i = w, #list do
                local o = list[i]:getParent()
                local sq = o and o.getSquare and o:getSquare()
                local tx, ty, tz = cx, cy, cz
                if sq then tx, ty, tz = sq:getX(), sq:getY(), sq:getZ() end
                local dx, dy = tx - cx, ty - cy
                local d = math.sqrt(dx * dx + dy * dy) + math.abs(tz - cz) * FLOOR_PENALTY
                if d < bd then bd = d; bi = i end
            end
            list[w], list[bi] = list[bi], list[w]
            local o = list[w]:getParent()
            local sq = o and o.getSquare and o:getSquare()
            if sq then cx, cy, cz = sq:getX(), sq:getY(), sq:getZ() end
        end
    end

    -- Expose the exact source/destination containers of an in-progress managed move in getContainers
    -- whenever the player is adjacent to them. After auto-walking to a crate and back, the loot window
    -- hasn't re-listed the container you returned to, so a deposit transfer would fail its isValid
    -- (destination "not reachable") and clear the queue. Force-listing them closes that refresh gap.
    BaseInv._forceInclude = BaseInv._forceInclude or {}
    if not BaseInv._getContainersPatched and ISInventoryPaneContextMenu then
        BaseInv._getContainersPatched = true
        local _bi_origGetConts = ISInventoryPaneContextMenu.getContainers
        ISInventoryPaneContextMenu.getContainers = function(character)
            local list = _bi_origGetConts(character)
            pcall(function()
                if character and list then
                    for c in pairs(BaseInv._forceInclude) do
                        local o = c.getParent and c:getParent()
                        local sq = o and o.getSquare and o:getSquare()
                        if sq and sq:DistToProper(character) <= 2.5 and not list:contains(c) then
                            list:add(c)
                        end
                    end
                end
            end)
            return list
        end
    end

    -- Move dragged items to their targets in two phases. First walk to each source the item isn't already
    -- carried in and TAKE it into the player's inventory; then walk to each destination and DEPOSIT it.
    -- Splitting it this way is what lets you send an item that lives in a distant safehouse crate to
    -- another container -- the character fetches it, then carries it over -- instead of a single transfer
    -- failing because the far source and the destination are never reachable at the same moment.
    -- `plan` is a list of { item = <InventoryItem>, target = <ItemContainer> }.
    function BaseInv.fetchThenDeposit(playerNum, plan)
        local playerObj = getSpecificPlayer(playerNum)
        if not (playerObj and plan) or #plan == 0 then return end
        local inv = playerObj:getInventory()
        BaseInv._managing = true  -- suppress the per-take auto-walk wrap; we do our own walking here
        -- force this move's sources/destinations into getContainers while we're adjacent to them
        BaseInv._forceInclude = {}
        for _, p in ipairs(plan) do
            if p.target then BaseInv._forceInclude[p.target] = true end
            local s = p.item.getContainer and p.item:getContainer()
            if s then BaseInv._forceInclude[s] = true end
        end
        -- Phase 1: fetch everything stored in a remote container (not carried on the player) into the
        -- inventory. Items already in your inventory or bags are left where they are.
        local fg, fo, fetched = {}, {}, {}
        for _, p in ipairs(plan) do
            local src = p.item.getContainer and p.item:getContainer()
            if src and src ~= inv and src:getOutermostContainer() ~= inv then
                if not fg[src] then fg[src] = {}; fo[#fo + 1] = src end
                table.insert(fg[src], p.item)
                fetched[p.item] = true
            end
        end
        BaseInv.routeContainers(playerObj, fo)
        for _, src in ipairs(fo) do
            local o = src:getParent()
            if (not o) or luautils.walkAdjObject(playerObj, o, true, true) then
                for _, item in ipairs(fg[src]) do
                    ISTimedActionQueue.add(ISInventoryTransferAction:new(playerObj, item, src, inv, nil))
                end
            end
        end
        -- Phase 2: deposit each item into its target (now coming from the inventory).
        local dg, dord = {}, {}
        for _, p in ipairs(plan) do
            if p.target and p.target ~= inv and p.target ~= p.item:getContainer() then
                if not dg[p.target] then dg[p.target] = {}; dord[#dord + 1] = p.target end
                table.insert(dg[p.target], p.item)
            end
        end
        BaseInv.routeContainers(playerObj, dord)
        for _, T in ipairs(dord) do
            local o = T:getParent()
            if (not o) or luautils.walkAdjObject(playerObj, o, true, true) then
                for _, item in ipairs(dg[T]) do
                    -- fetched items are now in the inventory; everything else transfers straight from
                    -- wherever it already sits (main inventory OR a bag). Forcing the main inventory as
                    -- the source broke items kept in a backpack -- the transfer went invalid.
                    local srcC = fetched[item] and inv or item:getContainer()
                    ISTimedActionQueue.add(ISInventoryTransferAction:new(playerObj, item, srcC, T, nil))
                end
            end
        end
        BaseInv._managing = false
    end

    -- Drop dragged items onto an ordinary EXTERNAL container (not a mod tab, not the player's own bags):
    -- only step in when at least one item lives in a remote container a single transfer couldn't reach,
    -- then fetch-and-deposit it (respecting the destination's weight). Returns true if it handled the
    -- drop, false to let vanilla run (takes into your own inventory already walk to the source on their own).
    function BaseInv.handleDropToContainer(playerNum, dest)
        local playerObj = getSpecificPlayer(playerNum)
        if not (playerObj and dest and ISMouseDrag.dragging) then return false end
        local dt = dest.getType and dest:getType()
        if dt == "proxInv" or dt == "floor" or dt == "safehouseInv" or dt == "safehouseInvZone" or dt == "safehouseInvCraft" then
            return false
        end
        local inv = playerObj:getInventory()
        if dest == inv or (dest.getOutermostContainer and dest:getOutermostContainer() == inv) then
            return false
        end
        local dragging = ISInventoryPane.getActualItems(ISMouseDrag.dragging)
        if not dragging then return false end
        local anyRemote = false
        for _, item in ipairs(dragging) do
            local src = item.getContainer and item:getContainer()
            if src and src ~= inv and src:getOutermostContainer() ~= inv then
                local o = src:getParent()
                local sq = o and o.getSquare and o:getSquare()
                if sq and sq:DistToProper(playerObj) > 2.5 then anyRemote = true; break end
            end
        end
        if not anyRemote then return false end  -- purely-near drops: let vanilla handle them
        local plan, committed, skipNoRoom = {}, 0, 0
        for _, item in ipairs(dragging) do
            if item:getContainer() ~= dest then
                local w = (item.getUnequippedWeight and item:getUnequippedWeight()) or 0
                if dest.hasRoomFor and dest:hasRoomFor(playerObj, committed + w) then
                    committed = committed + w
                    plan[#plan + 1] = { item = item, target = dest }
                else
                    skipNoRoom = skipNoRoom + 1
                end
            end
        end
        if #plan > 0 then BaseInv.fetchThenDeposit(playerNum, plan) end
        if HaloTextHelper and skipNoRoom > 0 then
            HaloTextHelper.addBadText(playerObj, getText("UI_BaseInv_KeptNoRoom", skipNoRoom))
        end
        if ISMouseDrag.draggingFocus then
            ISMouseDrag.draggingFocus:onMouseUp(0, 0)
            ISMouseDrag.draggingFocus = nil
        end
        ISMouseDrag.dragging = nil
        return true
    end

    -- Send the currently-dragged items home. resolveFn(playerObj, item, origin) returns an ordered list
    -- of candidate containers; we take the first that fits the item within its weight capacity (tracking
    -- the weight committed to each container across the whole drag), else leave the item put with a toast
    -- saying why. The actual movement (fetching far sources first) goes through fetchThenDeposit.
    function BaseInv.returnDropped(playerNum, resolveFn)
        local playerObj = getSpecificPlayer(playerNum)
        pcall(function()
            if not playerObj or not ISMouseDrag.dragging then return end
            local dragging = ISInventoryPane.getActualItems(ISMouseDrag.dragging)
            if not dragging then return end
            local committed, plan = {}, {}
            local skipNoRoom, skipNoMatch = 0, 0
            for _, item in ipairs(dragging) do
                local md = item.getModData and item:getModData()
                local candidates = (resolveFn and resolveFn(playerObj, item, md and md.BaseInv_origin)) or {}
                local w = (item.getUnequippedWeight and item:getUnequippedWeight()) or 0
                -- take the first candidate that can still fit this item (counting what we've already
                -- promised it this drag); when a crate fills up the rest flow to the next candidate
                local target = nil
                for _, c in ipairs(candidates) do
                    local already = committed[c] or 0
                    if c.hasRoomFor and c:hasRoomFor(playerObj, already + w) then
                        target = c; committed[c] = already + w; break
                    end
                end
                if target then
                    plan[#plan + 1] = { item = item, target = target }
                elseif #candidates > 0 then
                    skipNoRoom = skipNoRoom + 1   -- somewhere matched but everything was full
                else
                    skipNoMatch = skipNoMatch + 1 -- nothing in scope to put it in
                end
            end
            if #plan > 0 then BaseInv.fetchThenDeposit(playerNum, plan) end
            if HaloTextHelper and playerObj then
                if skipNoRoom > 0 then HaloTextHelper.addBadText(playerObj, getText("UI_BaseInv_KeptNoRoom", skipNoRoom)) end
                if skipNoMatch > 0 then HaloTextHelper.addBadText(playerObj, getText("UI_BaseInv_KeptNoMatch", skipNoMatch)) end
            end
        end)
        if ISMouseDrag.draggingFocus then
            ISMouseDrag.draggingFocus:onMouseUp(0, 0)
            ISMouseDrag.draggingFocus = nil
        end
        ISMouseDrag.dragging = nil
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

    -- Auto-walk to a far source crate when TAKING items out (covers drag, double-click, multi-select).
    -- A normal transfer only reaches containers within ~2.5 tiles, so taking from a distant zone crate
    -- silently fails. Here we queue a walk to the crate before the transfer is queued; once the player
    -- is adjacent the crate becomes reachable and the transfer goes through.
    if not BaseInv._takeWalkPatched and ISInventoryTransferAction then
        BaseInv._takeWalkPatched = true
        local _origTANew = ISInventoryTransferAction.new
        function ISInventoryTransferAction.new(class, character, item, srcContainer, destContainer, ...)
            pcall(function()
                if not BaseInv._managing and character and item and destContainer and character.getInventory
                    and destContainer:getOutermostContainer() == character:getInventory() then
                    local cont = item.getContainer and item:getContainer()
                    local obj = cont and cont:getParent()
                    local sq = obj and obj.getSquare and obj:getSquare()
                    if sq and sq:DistToProper(character) > 2.0 then
                        luautils.walkAdjObject(character, obj, true, true)
                    end
                end
            end)
            return _origTANew(class, character, item, srcContainer, destContainer, ...)
        end
    end

    -- Reorder a list of items being taken into the player as a floor-aware nearest-neighbour route, so
    -- grabbing several items spread across crates on different floors collects them a floor at a time
    -- instead of bouncing up and down the stairs in weight order. Sorts the list in place; the per-item
    -- walk wrap above then walks to each crate in this order.
    function BaseInv.routeSortItems(playerNum, items)
        local playerObj = getSpecificPlayer(playerNum)
        if not (playerObj and items and #items >= 2) then return end
        local FLOOR_PENALTY = 50
        local pool = {}
        for _, it in ipairs(items) do
            local cont = it.getContainer and it:getContainer()
            local outer = cont and cont:getOutermostContainer()
            local obj = outer and outer:getParent()
            local sq = obj and obj.getSquare and obj:getSquare()
            pool[#pool + 1] = { item = it, sq = sq }
        end
        local curX, curY, curZ = playerObj:getX(), playerObj:getY(), math.floor(playerObj:getZ())
        for w = 1, #items do
            local bestIdx, bestD = 1, math.huge
            for idx = 1, #pool do
                local p = pool[idx]
                local tx, ty, tz = curX, curY, curZ
                if p.sq then tx, ty, tz = p.sq:getX(), p.sq:getY(), p.sq:getZ() end
                local dx, dy = tx - curX, ty - curY
                local d = math.sqrt(dx * dx + dy * dy) + math.abs(tz - curZ) * FLOOR_PENALTY
                if d < bestD then bestD = d; bestIdx = idx end
            end
            local p = table.remove(pool, bestIdx)
            items[w] = p.item
            if p.sq then curX, curY, curZ = p.sq:getX(), p.sq:getY(), p.sq:getZ() end
        end
    end

    -- True only when a take is worth routing: 2+ distinct source squares and at least one off our floor
    -- or out of reach. Plain nearby single-crate takes keep vanilla's weight order untouched.
    function BaseInv.takeNeedsRoute(playerObj, items)
        if not (playerObj and items and #items >= 2) then return false end
        local pz = math.floor(playerObj:getZ())
        local squares, distinct, far = {}, 0, false
        for _, it in ipairs(items) do
            local cont = it.getContainer and it:getContainer()
            local outer = cont and cont:getOutermostContainer()
            local obj = outer and outer:getParent()
            local sq = obj and obj.getSquare and obj:getSquare()
            if sq then
                if not squares[sq] then squares[sq] = true; distinct = distinct + 1 end
                if sq:getZ() ~= pz or sq:DistToProper(playerObj) > 2.5 then far = true end
            end
        end
        return distinct >= 2 and far
    end

    -- Route-sort the shared take path (multi-select drag, loot-all). We pre-sort, then neutralise
    -- vanilla's weight re-sort for just this call so our order survives into the transfer queue.
    if not BaseInv._takeSortPatched and ISInventoryPane then
        BaseInv._takeSortPatched = true
        local _origTransferByWeight = ISInventoryPane.transferItemsByWeight
        function ISInventoryPane:transferItemsByWeight(items, container)
            local routed = false
            pcall(function()
                local playerObj = getSpecificPlayer(self.player)
                if playerObj and container and container.getOutermostContainer
                    and container:getOutermostContainer() == playerObj:getInventory()
                    and BaseInv.takeNeedsRoute(playerObj, items) then
                    BaseInv.routeSortItems(self.player, items)
                    routed = true
                end
            end)
            if routed then
                self.sortItemsByTypeAndWeight = function() end
                local ok, err = pcall(_origTransferByWeight, self, items, container)
                self.sortItemsByTypeAndWeight = nil
                if not ok then error(err, 0) end
                return
            end
            return _origTransferByWeight(self, items, container)
        end

        -- Double-clicking a stacked row grabs every copy in it. Index 1 of a stack is a dummy duplicate
        -- (see getActualItems), so we route-sort the real items 2..N in place and the vanilla loop then
        -- collects them floor-by-floor.
        local _origDblClick = ISInventoryPane.onMouseDoubleClick
        function ISInventoryPane:onMouseDoubleClick(x, y)
            pcall(function()
                local playerObj = getSpecificPlayer(self.player)
                local row = self.items and self.mouseOverOption and self.items[self.mouseOverOption]
                if playerObj and row and not instanceof(row, "InventoryItem") and row.items and #row.items > 2 then
                    local sub = {}
                    for i = 2, #row.items do sub[#sub + 1] = row.items[i] end
                    if BaseInv.takeNeedsRoute(playerObj, sub) then
                        BaseInv.routeSortItems(self.player, sub)
                        for i = 2, #row.items do row.items[i] = sub[i - 1] end
                    end
                end
            end)
            return _origDblClick(self, x, y)
        end
    end

    -- Right-click "Grab All" funnels through onGrabItems, which flattens its input with getActualItems
    -- in input order. Handing it a route-ordered flat list makes it grab a floor at a time too.
    if not BaseInv._grabPatched and ISInventoryPaneContextMenu then
        BaseInv._grabPatched = true
        local _origGrab = ISInventoryPaneContextMenu.onGrabItems
        if _origGrab then
            ISInventoryPaneContextMenu.onGrabItems = function(items, player)
                pcall(function()
                    local playerObj = getSpecificPlayer(player)
                    local flat = ISInventoryPane.getActualItems(items)
                    if playerObj and BaseInv.takeNeedsRoute(playerObj, flat) then
                        BaseInv.routeSortItems(player, flat)
                        items = flat
                    end
                end)
                return _origGrab(items, player)
            end
        end
    end

    -- Drag-validity highlight: our synthetic tabs reject items via isItemAllowed/hasRoomFor, so the
    -- vanilla drag overlay paints the dragged item red even though our drop handler accepts it (it sends
    -- the item home). Each mod registers a predicate for its tab types; while a drag hovers one of them,
    -- clear the per-item "can't drop" flags so the item shows as a valid drop.
    BaseInv.homeTypePredicates = BaseInv.homeTypePredicates or {}
    function BaseInv.isHomeTabType(t)
        if not t then return false end
        for i = 1, #BaseInv.homeTypePredicates do
            if BaseInv.homeTypePredicates[i](t) then return true end
        end
        return false
    end

    if not BaseInv._dragHLPatched and ISInventoryPaneDraggedItems then
        BaseInv._dragHLPatched = true
        local _origDIUpdate = ISInventoryPaneDraggedItems.update
        function ISInventoryPaneDraggedItems:update()
            _origDIUpdate(self)
            pcall(function()
                local c = self.mouseOverContainer
                if c and c.getType and self.itemNotOK and BaseInv.isHomeTabType(c:getType()) then
                    table.wipe(self.itemNotOK)
                end
            end)
        end
    end
end

BaseInv.homeTypePredicates = BaseInv.homeTypePredicates or {}
table.insert(BaseInv.homeTypePredicates, isSafehouseInvType)

-- Candidate destinations for a returned item, scoped to the safehouse zone loaded right now -- so it
-- never walks off to a container elsewhere in the world, and does nothing while you're away from the
-- safehouse (the zone isn't loaded). Tiering (origin / same type / same category) and weight handling
-- live in BaseInv.buildReturnCandidates.
local function SHInv_nearestZoneCrate(playerObj, item, origin)
    if not item then return {} end
    return BaseInv.buildReturnCandidates(playerObj, item, origin, getZoneContainersFlat(playerObj))
end

local _SHInv_origDropInContainer = ISInventoryPage.dropItemsInContainer
function ISInventoryPage:dropItemsInContainer(button)
    if BIT.isEnabled:getValue() and ISMouseDrag.dragging and button and button.inventory then
        if isSafehouseInvType(button.inventory:getType()) then
            return BaseInv.returnDropped(self.player, SHInv_nearestZoneCrate)
        elseif BaseInv.handleDropToContainer(self.player, button.inventory) then
            return true
        end
    end
    return _SHInv_origDropInContainer(self, button)
end

-- Also catch dropping onto the item LIST (the pane), not just the tab icon.
local _SHInv_origPaneMouseUp = ISInventoryPane.onMouseUp
function ISInventoryPane:onMouseUp(x, y)
    if BIT.isEnabled:getValue() and ISMouseDrag.dragging ~= nil and ISMouseDrag.draggingFocus ~= self
        and ISMouseDrag.draggingFocus ~= nil and self.inventory then
        if isSafehouseInvType(self.inventory:getType()) then
            BaseInv.returnDropped(self.player, SHInv_nearestZoneCrate)
            self.selected = {}
            self.draggingMarquis = false
            return true
        elseif BaseInv.handleDropToContainer(self.player, self.inventory) then
            self.selected = {}
            self.draggingMarquis = false
            return true
        end
    end
    return _SHInv_origPaneMouseUp(self, x, y)
end

print("[SafehouseInventory] Per-zone tabs (sticky selection) + crafting + context menu loaded.")
