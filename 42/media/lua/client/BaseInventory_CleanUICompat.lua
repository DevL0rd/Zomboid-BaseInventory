--[[
    Base Inventory - CleanUI compatibility
    --------------------------------------
    CleanUI adds the loot-window controls (search box, sort, etc.) but only shows them for
    a hardcoded whitelist of virtual container types ("proxInv", "proximityInv", "csrLootBag"...)
    via a CleanUI-LOCAL function we can't extend. For those whitelisted/virtual containers it
    renders the controls from ISLootWindowContainerControls_FloorHandlerList.

    Our synthetic tabs ("baseInv" / "baseInvZone") aren't on that list, so CleanUI hides the
    controls. We wrap ISLootWindowContainerControls:arrange() and, when our container is the one
    displayed and CleanUI rendered nothing, replicate CleanUI's floor-handler render so the same
    search/sort controls appear.

    Guarded: if CleanUI's FloorHandlerList isn't present (CleanUI not installed), this no-ops.
    Deferred to OnGameStart so it wraps whatever final arrange() exists, regardless of mod order.
]]

local function isBaseInvType(t)
    return t == "baseInv" or t == "baseInvZone"
end

Events.OnGameStart.Add(function()
    if not (ISLootWindowContainerControls and ISLootWindowContainerControls.arrange) then return end
    if ISLootWindowContainerControls._baseInvArrangeWrapped then return end
    ISLootWindowContainerControls._baseInvArrangeWrapped = true

    local _orig_arrange = ISLootWindowContainerControls.arrange
    function ISLootWindowContainerControls:arrange()
        _orig_arrange(self)

        -- Only CleanUI provides this floor-handler list; without it there are no extra controls.
        if not ISLootWindowContainerControls_FloorHandlerList then return end
        if not self.getDisplayedContainer then return end

        local container = self:getDisplayedContainer()
        if not container or not isBaseInvType(container:getType()) then return end
        if self.controls and #self.controls > 0 then return end -- CleanUI already showed something

        local PAD = math.max(2, math.floor(getTextManager():getFontHeight(UIFont.Small) * 0.2))
        local x, y, rowHgt = PAD, PAD, 0
        for _, handlerClass in ipairs(ISLootWindowContainerControls_FloorHandlerList) do
            local handler = self:checkHandler(handlerClass, nil, container)
            if handler:shouldBeVisible() then
                local control = handler:getControl()
                if (x > 0) and (x + control:getWidth() > self.width) then
                    x = PAD; y = y + rowHgt + PAD; rowHgt = 0
                end
                control:setX(x)
                control:setY(y)
                control:setVisible(true)
                self:addChild(control)
                table.insert(self.controls, control)
                x = control:getRight() + 5
                rowHgt = math.max(rowHgt, control:getHeight())
            end
        end

        if self.controls and #self.controls > 0 then
            self:setWidth(self.lootWindow:getWidth() - self.lootWindow.containerButtonPanel.width)
            self:setHeight(y + rowHgt + PAD)
            self:setVisible(true)
            if self.fixMouseOverButton then self:fixMouseOverButton() end
        end
    end

    print("[BaseInventory] CleanUI loot-controls compat active (search/sort on the Base Inventory tab).")
end)
