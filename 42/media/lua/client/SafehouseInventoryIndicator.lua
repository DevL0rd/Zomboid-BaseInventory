--[[
    Safehouse Inventory - "have-at-base" indicator
    -----------------------------------------
    Draws a small house badge on every item you already store at a base zone (anywhere you see it:
    loot containers, the floor, your own bags, even the Base tabs), and appends a per-zone stock
    breakdown to the item tooltip. Data comes from SafehouseInventoryIndex (O(1) lookup per item).

    Rendering is hooked onto ISInventoryPane:renderdetails. CleanUI swaps the inventory pane CLASS at
    runtime (vanilla <-> CleanUI mode), so instead of hooking one fixed class once we re-apply the
    hook to whichever pane class is actually live, each time the inventory window refreshes. Both the
    vanilla and CleanUI panes expose renderdetails(doDragged) + self.itemslist, so the same draw loop
    works for either. The tooltip class (ISToolTipInv) is NOT swapped by CleanUI, so it's hooked once.

    Item-list iteration mirrors the proven loop in vanilla/CleanUI renderdetails (and P4HasBeenRead):
    rows are walked in order so y stays aligned with the on-screen list, honouring scroll, dragging
    and collapsed stacks.
]]

SafehouseInventoryIndicator = SafehouseInventoryIndicator or {}
local IND = SafehouseInventoryIndicator
local IDX = SafehouseInventoryIndex

IND.tex = getTexture("media/textures/SafehouseInventory_Home.png")
IND._renderBroken = false -- set if the draw loop errors, to avoid per-frame spam

local function badgeEnabled()
    local BIT = SafehouseInventoryTab
    return not (BIT and BIT.showBadge and not BIT.showBadge:getValue())
end

local function tooltipEnabled()
    local BIT = SafehouseInventoryTab
    return not (BIT and BIT.showTooltip and not BIT.showTooltip:getValue())
end

-- ── Badge drawing over inventory list rows ──────────────────────────────────────────
local function drawBadgesImpl(self, doDragged)
    if not IND.tex or not badgeEnabled() then return end
    if not self.itemslist then return end

    local y = 0
    local MOUSEX = self:getMouseX()
    local MOUSEY = self:getMouseY()
    local YSCROLL = self:getYScroll()
    local HEIGHT = self:getHeight()

    for _, v in ipairs(self.itemslist) do
        local items = v.items
        if items then
            local count = 1
            for _, item in ipairs(items) do
                local info = item and IDX.getInfo(item:getFullType())
                if info and count == 1 then
                    local doIt = true
                    local xoff, yoff = 0, 0
                    local isDragging = false
                    if self.dragging ~= nil and self.selected[y + 1] ~= nil and self.dragStarted then
                        xoff = MOUSEX - self.draggingX
                        yoff = MOUSEY - self.draggingY
                        if not doDragged then doIt = false else isDragging = true end
                    elseif doDragged then
                        doIt = false
                    end

                    local topOfItem = y * self.itemHgt + YSCROLL
                    if not isDragging and ((topOfItem + self.itemHgt < 0) or (topOfItem > HEIGHT)) then
                        doIt = false
                    end

                    if doIt then
                        local texWH = math.min(self.itemHgt - 2, 32)
                        local bs = math.max(8, math.min(16, math.floor(texWH * 0.5)))
                        local bx = xoff + 1
                        local by = (y * self.itemHgt) + self.headerHgt + yoff + texWH - bs
                        self:drawTextureScaled(IND.tex, bx, by, bs, bs, 1, 1, 1, 1)
                    end
                end

                y = y + 1
                if count == 1 and self.collapsed ~= nil and v.name ~= nil and self.collapsed[v.name] then break end
                if count == 51 then break end
                count = count + 1
            end
        end
    end
end

function IND.drawBadges(self, doDragged)
    if IND._renderBroken then return end
    local ok, err = pcall(drawBadgesImpl, self, doDragged)
    if not ok then
        IND._renderBroken = true
        print("[SafehouseInventory] badge render disabled after error: " .. tostring(err))
    end
end

-- Wrap renderdetails on whatever pane class is currently live (handles CleanUI's class swap).
local function ensureRenderHook(pane)
    if not pane then return end
    local cls = getmetatable(pane)
    cls = cls and cls.__index
    if type(cls) ~= "table" then return end
    if rawget(cls, "__safehouseInvBadgeHooked") then return end
    local orig = cls.renderdetails
    if type(orig) ~= "function" then return end
    rawset(cls, "__safehouseInvBadgeHooked", true)
    cls.renderdetails = function(self, doDragged)
        orig(self, doDragged)
        IND.drawBadges(self, doDragged)
    end
end

-- ── Tooltip: per-zone stock breakdown ───────────────────────────────────────────────
function IND.drawTooltipExtra(self)
    if not IND.tex or not tooltipEnabled() then return end
    if ISContextMenu.instance and ISContextMenu.instance.visibleCheck then return end
    local item = self.item
    if not item then return end
    local info = IDX.getInfo(item:getFullType())
    if not info then return end

    -- copy + sort zones by count desc (don't mutate the cached index)
    local zones = {}
    for i = 1, #info.zones do zones[i] = info.zones[i] end
    table.sort(zones, function(a, b) return (a.count or 0) > (b.count or 0) end)

    local MAX_ZONES = 6
    local title = getText("UI_SafehouseInventory_Tooltip_AtBase") .. ": " .. info.total
    local lines = {}
    for i = 1, math.min(#zones, MAX_ZONES) do
        local z = zones[i]
        lines[#lines + 1] = "  " .. (z.name or "?") .. ": " .. z.count
    end
    if #zones > MAX_ZONES then
        lines[#lines + 1] = "  +" .. (#zones - MAX_ZONES) .. " " .. getText("UI_SafehouseInventory_Tooltip_More")
    end

    local font = UIFont.Small
    local tm = getTextManager()
    local fh = tm:getFontHeight(font)
    local pad = 6
    local iconSize = 14

    local boxW = tm:MeasureStringX(font, title) + iconSize + 4
    for _, l in ipairs(lines) do
        boxW = math.max(boxW, tm:MeasureStringX(font, l))
    end
    boxW = boxW + pad * 2
    local boxH = (1 + #lines) * fh + pad * 2

    -- place below the tooltip, or above if it would run off the bottom of the screen
    local x = 0
    local y = self:getHeight() + 3
    local screenH = getCore():getScreenHeight()
    if self:getY() + y + boxH > screenH then
        y = -(boxH + 3)
    end

    self:drawRect(x, y, boxW, boxH, 0.88, 0.09, 0.09, 0.09)
    self:drawRectBorder(x, y, boxW, boxH, 0.55, 0.62, 0.62, 0.62)

    local ty = y + pad
    self:drawTextureScaled(IND.tex, x + pad, ty + 1, iconSize, iconSize, 1, 1, 1, 1)
    self:drawText(title, x + pad + iconSize + 4, ty, 0.95, 1.0, 0.85, 1, font)
    ty = ty + fh
    for _, l in ipairs(lines) do
        self:drawText(l, x + pad, ty, 0.82, 0.82, 0.82, 1, font)
        ty = ty + fh
    end
end

local orig_ttRender = ISToolTipInv.render
function ISToolTipInv:render()
    orig_ttRender(self)
    local ok, err = pcall(IND.drawTooltipExtra, self)
    if not ok then print("[SafehouseInventory] tooltip render error: " .. tostring(err)) end
end

-- ── Wiring ──────────────────────────────────────────────────────────────────────────
-- On every inventory/loot refresh: make sure the live pane class is hooked, and refresh the
-- index for any base zone we're in range of (throttled inside IDX.update).
Events.OnRefreshInventoryWindowContainers.Add(function(invSelf, state)
    if state ~= "begin" then return end
    ensureRenderHook(invSelf.inventoryPane)
    IDX.update(getSpecificPlayer(invSelf.player))
end)

print("[SafehouseInventory] have-at-base indicator (badge + tooltip) loaded.")

return SafehouseInventoryIndicator
