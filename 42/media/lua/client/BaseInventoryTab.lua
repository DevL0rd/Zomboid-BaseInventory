--[[
    Base Inventory - Base-Wide Inventory Tabs
    -----------------------------------------
    Adds inventory tabs to the loot window sourced from your Home Inventory zones while you're
    standing in your base:
      - "Base Inventory" : every container across ALL loaded zones, merged (deduped).
      - One tab per named zone (only shown when 2+ zones are loaded).

    Selection is "sticky": once you click a Base Inventory tab it stays selected across loot-window
    refreshes - moving around or approaching world containers won't switch you off it. Clicking any
    real container (or scrolling to one) switches away. No pin/keybind needed.

    Crafting (cooking / AutoCook / hand-craft) pulls from the REAL loaded zone containers via the
    getContainers hook; the synthetic tab container is always stripped from that list, so items are
    never double-counted and away/unloaded items can't be used.

    Loot-window hooking adapted from Proximity Inventory (B42.19 fork); source changed to the zone.
]]

BaseInventoryTab = BaseInventoryTab or {}
local BIT = BaseInventoryTab

BIT.MARGIN = 3 -- tiles of slack around a zone

BIT.options = PZAPI.ModOptions:create("BaseInventory", "Base Inventory")
BIT.isEnabled = BIT.options:addTickBox("BaseInventory_isEnabled", "Enable the Base Inventory tabs", true)

-- Per-player state
BIT.itemContainer = {}       -- [playerNum] = combined ItemContainer
BIT.zoneItemContainer = {}   -- [playerNum][zoneKey] = ItemContainer
BIT.inventoryButtonRef = {}  -- [playerNum] = combined ISButton
BIT.zoneButtonRefs = {}      -- [playerNum] = { { btn=, containers={} }, ... }
BIT.allSynthetic = {}        -- [playerNum] = { ItemContainer... } active this refresh (crafting strip)
BIT._lastZones = {}          -- [playerNum] = result of getZonesWithContainers
BIT.stickContainer = {}      -- [playerNum] = the baseInv ItemContainer the user is viewing, or nil

BIT.icon = getTexture("media/textures/HomeInventory_Refresh.png") or getTexture("media/ui/Panel_Icon_Pin.png")

local function isBaseInvType(t)
    return t == "baseInv" or t == "baseInvZone"
end

-- ── Zone reading + container enumeration ────────────────────────────────────────────
local function getZones()
    local md = ModData.getOrCreate("HomeInventoryZones")
    return (md and md.zones) or {}
end

local function zoneBounds(zone)
    return math.min(zone.x1, zone.x2), math.min(zone.y1, zone.y2),
           math.max(zone.x1, zone.x2), math.max(zone.y1, zone.y2), (zone.z or 0)
end

local function playerNearZone(px, py, pz, zone)
    local x1, y1, x2, y2, zz = zoneBounds(zone)
    if pz ~= zz then return false end
    local m = BIT.MARGIN
    return px >= x1 - m and px <= x2 + m and py >= y1 - m and py <= y2 + m
end

-- Per-zone container lists for zones the player is currently in/near (loaded squares only).
local function getZonesWithContainers(playerObj)
    local out = {}
    local sq = playerObj:getCurrentSquare()
    if not sq then return out end
    local px, py, pz = sq:getX(), sq:getY(), sq:getZ()
    local cell = getCell()
    if not cell then return out end

    for _, zone in ipairs(getZones()) do
        if playerNearZone(px, py, pz, zone) then
            local x1, y1, x2, y2, zz = zoneBounds(zone)
            local seen, conts = {}, {}
            for x = x1, x2 do
                for y = y1, y2 do
                    local s = cell:getGridSquare(x, y, zz)
                    if s then
                        local objs = s:getObjects()
                        for i = 0, objs:size() - 1 do
                            local obj = objs:get(i)
                            local cont = obj and obj:getContainer()
                            if cont and not seen[cont] then
                                seen[cont] = true
                                conts[#conts + 1] = cont
                            end
                        end
                    end
                end
            end
            if #conts > 0 then
                out[#out + 1] = { zone = zone, key = (zone.name or (x1 .. "," .. y1 .. "," .. zz)), containers = conts }
            end
        end
    end
    return out
end

local function getZoneContainersFlat(playerObj)
    local out, seen = {}, {}
    for _, z in ipairs(getZonesWithContainers(playerObj)) do
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

local function getCombinedContainer(playerNum)
    if not BIT.itemContainer[playerNum] then BIT.itemContainer[playerNum] = newSynthetic("baseInv") end
    return BIT.itemContainer[playerNum]
end

local function getZoneContainer(playerNum, key)
    BIT.zoneItemContainer[playerNum] = BIT.zoneItemContainer[playerNum] or {}
    if not BIT.zoneItemContainer[playerNum][key] then
        BIT.zoneItemContainer[playerNum][key] = newSynthetic("baseInvZone")
    end
    return BIT.zoneItemContainer[playerNum][key]
end

-- ── begin: create the tab buttons (combined always; per-zone when 2+ zones loaded) ──
local function addBaseInventoryButtons(invSelf)
    local pnum = invSelf.player
    local playerObj = getSpecificPlayer(pnum)
    BIT.inventoryButtonRef[pnum] = nil
    BIT.zoneButtonRefs[pnum] = {}
    BIT.allSynthetic[pnum] = {}
    if not playerObj then return end

    local zones = getZonesWithContainers(playerObj)
    BIT._lastZones[pnum] = zones
    -- Combined tab is always created so it stays right-clickable even away from base.

    local combined = getCombinedContainer(pnum)
    combined:clear()
    local cbtn = invSelf:addContainerButton(combined, BIT.icon, "Base Inventory")
    BIT.inventoryButtonRef[pnum] = cbtn
    BIT.allSynthetic[pnum][#BIT.allSynthetic[pnum] + 1] = combined

    if #zones > 1 then
        for _, z in ipairs(zones) do
            local sc = getZoneContainer(pnum, z.key)
            sc:clear()
            local b = invSelf:addContainerButton(sc, BIT.icon, z.zone.name or z.key)
            BIT.zoneButtonRefs[pnum][#BIT.zoneButtonRefs[pnum] + 1] = { btn = b, containers = z.containers }
            BIT.allSynthetic[pnum][#BIT.allSynthetic[pnum] + 1] = sc
        end
    end
end

-- ── buttonsAdded: fill each synthetic container from its zone containers ─────────────
local function onButtonsAdded(invSelf)
    local pnum = invSelf.player
    local zones = BIT._lastZones[pnum]
    if not zones then return end

    local cbtn = BIT.inventoryButtonRef[pnum]
    if cbtn then
        local seen = {}
        for _, z in ipairs(zones) do
            for _, c in ipairs(z.containers) do
                if not seen[c] then seen[c] = true; cbtn.inventory:getItems():addAll(c:getItems()) end
            end
        end
    end

    for _, zr in ipairs(BIT.zoneButtonRefs[pnum] or {}) do
        for _, c in ipairs(zr.containers) do
            zr.btn.inventory:getItems():addAll(c:getItems())
        end
    end
end

-- ── Sticky selection ────────────────────────────────────────────────────────────────
-- Scroll fix: a synthetic container breaks vanilla getCurrentBackpackIndex (returns -1),
-- which turns mouse-wheel into camera zoom. Resolve the index via selectedButton instead.
local function patchMouseWheel(invSelf, playerNum)
    if invSelf._baseInvMouseWheelPatched then return end
    invSelf._baseInvMouseWheelPatched = true

    local _orig = invSelf.onMouseWheel
    invSelf.onMouseWheel = function(self, del)
        if not BIT.isEnabled:getValue() or self.onCharacter
            or not (self.inventory and isBaseInvType(self.inventory:getType()))
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
            return true -- consume; don't zoom the camera
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
            local target = self.backpacks[unlockedIndex].inventory
            -- scrolling onto/off our tabs updates the sticky selection
            BIT.stickContainer[playerNum] = isBaseInvType(target:getType()) and target or nil
            self:selectContainer(self.backpacks[unlockedIndex])
        end
        return true
    end
end

-- Keep the user's chosen Base Inventory tab selected across refreshes.
local function onRefreshEnd(invSelf)
    local pnum = invSelf.player
    local stick = BIT.stickContainer[pnum]
    if not stick then return end

    -- resolve stick to a present backpack; if the zone tab vanished, fall back to combined.
    local target = nil
    for i = 1, #invSelf.backpacks do
        if invSelf.backpacks[i].inventory == stick then target = stick; break end
    end
    if not target then
        local combined = BIT.itemContainer[pnum]
        for i = 1, #invSelf.backpacks do
            if invSelf.backpacks[i].inventory == combined then target = combined; break end
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
            patchMouseWheel(invSelf, invSelf.player)
            addBaseInventoryButtons(invSelf)
        elseif state == "buttonsAdded" then
            onButtonsAdded(invSelf)
        elseif state == "end" then
            onRefreshEnd(invSelf)
        end
    end)
    if not ok then print("[BaseInventory] tab refresh error (" .. tostring(state) .. "): " .. tostring(err)) end
end)

-- Clicking a container button updates the sticky selection: our tab -> stick, anything else -> release.
local old_onBackpackMouseDown = ISInventoryPage.onBackpackMouseDown
function ISInventoryPage:onBackpackMouseDown(button, x, y)
    local clicked = button and button.inventory
    if clicked then
        local pnum = self.player or 0
        BIT.stickContainer[pnum] = isBaseInvType(clicked:getType()) and clicked or nil
    end
    return old_onBackpackMouseDown(self, button, x, y)
end

-- ── Right-click context menu (Manage zones) ─────────────────────────────────────────
local function openZoneManager()
    local playerObj = getPlayer()
    if not playerObj then return end
    local playerNum = playerObj:getPlayerNum()
    local ui = HomeInventoryZonePanel.instance
    if not ui then
        ui = HomeInventoryZonePanel:new(getPlayerScreenLeft(playerNum) + 100, getPlayerScreenTop(playerNum) + 100, 500, 500, playerObj)
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
    if container and isBaseInvType(container:getType()) then
        local page = self.parent and self.parent.parent
        local playerNum = self.player or (page and page.player) or 0
        local context = ISContextMenu.get(playerNum, getMouseX(), getMouseY())
        if not context then return end
        context:addOption(getText("UI_HomeInventory_ManageZonesButton"), nil, openZoneManager)
        return
    end
    return old_onBackpackRightMouseDown(self, x, y)
end

-- ── CRAFTING: pull from the whole base zone (real, loaded containers only) ───────────
local orig_getContainers = ISInventoryPaneContextMenu.getContainers
ISInventoryPaneContextMenu.getContainers = function(character)
    local list = orig_getContainers(character)
    if not character or not list then return list end

    local pnum = character:getPlayerNum()
    for _, c in ipairs(BIT.allSynthetic[pnum] or {}) do
        if list:contains(c) then list:remove(c) end
    end

    local ok, conts = pcall(getZoneContainersFlat, character)
    if ok and conts then
        for i = 1, #conts do
            if not list:contains(conts[i]) then list:add(conts[i]) end
        end
    end
    return list
end

print("[BaseInventory] Base-wide tabs (sticky selection) + crafting + context menu loaded.")
