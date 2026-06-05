-- This is the panel that appears when "Manage Zones" is clicked

require "HomeInventoryManager"
-- require "AddHomeInventoryZoneUI"
require "HomeInventoryInfoPanelUI"

HomeInventoryZonePanel = ISCollapsableWindowJoypad:derive("HomeInventoryZonePanel");

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.NewSmall)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.NewMedium)
local UI_BORDER_SPACING = 10
local BUTTON_HGT = FONT_HGT_SMALL + 6

function HomeInventoryZonePanel:initialise()
    local btnWid = 150

    self.descriptionText = getText("UI_HomeInventory_ZoneManagerDesc")

    local descriptionWidth = getTextManager():MeasureStringX(UIFont.Small, self.descriptionText)

    self.zoneUpdateText = getTextManager():WrapText(UIFont.Small, getText("UI_HomeInventory_ZoneUpdateHint"),
        self:getWidth() / 2)
    local zoneUpdateWidth = getTextManager():MeasureStringX(UIFont.Small, self.zoneUpdateText)

    local width = UI_BORDER_SPACING * 2 + 2 + math.max(
        descriptionWidth,
        zoneUpdateWidth
    )
    self:setWidth(math.max(width, self.width))

    self.zoneList = ISScrollingListBox:new(UI_BORDER_SPACING + 1, self:titleBarHeight() + UI_BORDER_SPACING,
        self.width - (UI_BORDER_SPACING + 1) * 2, BUTTON_HGT * 16)
    self.zoneList:initialise()
    self.zoneList:instantiate()
    self.zoneList.itemheight = BUTTON_HGT
    self.zoneList.selected = 0
    self.zoneList.joypadParent = self
    self.zoneList.font = UIFont.NewSmall
    self.zoneList.doDrawItem = self.drawList
    self.zoneList.drawBorder = true
    self:addChild(self.zoneList)

    self.addZone = ISButton:new(self.zoneList.x, self.zoneList.y + self.zoneList.height + UI_BORDER_SPACING, btnWid,
        BUTTON_HGT, getText("UI_HomeInventory_ZoneAddButton"), self, HomeInventoryZonePanel.onClick)
    self.addZone.internal = "ADDZONE"
    self.addZone:initialise()
    self.addZone:instantiate()
    self.addZone.borderColor = self.buttonBorderColor
    self:addChild(self.addZone)

    self.removeZone = ISButton:new(self.width - 1 - btnWid - UI_BORDER_SPACING, self.addZone.y, btnWid, BUTTON_HGT,
        getText("UI_HomeInventory_ZoneRemoveButton"), self, HomeInventoryZonePanel.onClick)
    self.removeZone.internal = "REMOVEZONE"
    self.removeZone:initialise()
    self.removeZone:instantiate()
    self.removeZone.borderColor = self.buttonBorderColor
    self:addChild(self.removeZone)
    self.removeZone.enable = false

    self.renameZone = ISButton:new(self.removeZone.x - btnWid - UI_BORDER_SPACING, self.addZone.y, btnWid, BUTTON_HGT,
        getText("UI_HomeInventory_ZoneRenameButton"), self, HomeInventoryZonePanel.onClick)
    self.renameZone.internal = "RENAMEZONE"
    self.renameZone:initialise()
    self.renameZone:instantiate()
    self.renameZone.borderColor = self.buttonBorderColor
    self:addChild(self.renameZone)
    self.renameZone.enable = false

    self.closeButton = ISButton:new(self.removeZone.x, self.addZone:getBottom() + BUTTON_HGT * 2, btnWid, BUTTON_HGT,
        getText("UI_HomeInventory_CloseButton"), self, HomeInventoryZonePanel.onClick)
    self.closeButton.internal = "OK"
    self.closeButton:initialise()
    self.closeButton:instantiate()
    self.closeButton:enableCancelColor()
    self:addChild(self.closeButton)

    self:setHeight(self.closeButton:getBottom() + UI_BORDER_SPACING + 1)

    if self.listTakesFocus then
        self.joypadIndexY = 1
        self.joypadIndex = 1
        self.joypadButtonsY = {}
        self.joypadButtons = {}
        self:insertNewLineOfButtons(self.zoneList)
        self:insertNewLineOfButtons(self.addZone, self.renameZone, self.removeZone)
    end

    self:populateList()

    -- Show designation zones while this window is open
    if self.player then
        self.player:setSeeDesignationZone(true)
    end
end

function HomeInventoryZonePanel:close()
    -- Hide designation zones when this window is closed
    if self.player then
        self.player:setSeeDesignationZone(false)
    end
    self:setVisible(false)
    self:removeFromUIManager()
end

function HomeInventoryZonePanel:populateList()
    HomeInventoryManager:load()

    self.zoneList:clear()

    self.zones = HomeInventoryManager:getAllZones()

    for i, zone in ipairs(self.zones or {}) do
        local newZone = {}
        newZone.title = zone.name
        newZone.size = math.abs(zone.x2 - zone.x1 + 1) * math.abs(zone.y2 - zone.y1 + 1)
        newZone.zone = zone
        newZone.loaded = HomeInventoryManager:isZoneLoaded(zone) -- Add loaded status
        self.zoneList:addItem(newZone.title, newZone)
    end

    -- since I can't figure out how to set the panel as a parent
    if not HomeInventoryPanel.instance then
        return
    else
        HomeInventoryPanel.instance:populateList()
    end

    print(self.zoneList)
end

function HomeInventoryZonePanel:drawList(y, item, alt)
    -- This could be a ISScrollingListBox instead
    local a = 0.9
    if not self.currentWidth then self.currentWidth = 0 end
    self:drawRectBorder(0, (y), self:getWidth(), self.itemheight - 1, a, self.borderColor.r, self.borderColor.g,
        self.borderColor.b)

    if self.selected == item.index then
        self:drawRect(0, (y), self:getWidth(), self.itemheight - 1, 0.3, 0.7, 0.35, 0.15)
    end

    self:drawText(item.item.title, 10, y + 2, 1, 1, 1, a, self.font)
    local newWidth = getTextManager():MeasureStringX(self.font, item.item.title)
    if newWidth > self.currentWidth then
        self.currentWidth = newWidth
    end

    local sizeString = getText("UI_HomeInventory_ZoneSize", item.item.size)
    self:drawText(sizeString, self.currentWidth + 180, y + 2, 1, 1, 1, a, self.font)

    -- Draw Loaded column
    local updatedText = getText("UI_HomeInventory_ZoneManagerUpdated")
    local notUpdatedText = getText("UI_HomeInventory_ZoneManagerNotUpdated")

    local loadedText = item.item.loaded and updatedText or notUpdatedText
    self:drawText(loadedText, self.currentWidth + 300, y + 2, 1, 1, 1, a, self.font)

    return y + self.itemheight
end

function HomeInventoryZonePanel:prerender()
    ISCollapsableWindowJoypad.prerender(self)
    -- self:drawText("Home Inventory Zones", self.width/2 - (getTextManager():MeasureStringX(UIFont.NewMedium, "Home Inventory Zones") / 2), z, 1,1,1,1, UIFont.NewMedium)
    self:drawZoneAreaOnGround()
end

function HomeInventoryZonePanel:drawZoneAreaOnGround()
    -- now highlight every saved zone
    for _, zone in ipairs(self.zones or HomeInventoryManager:getAllZones()) do
        if math.floor(zone.z) == math.floor(self.player:getZ()) then
            addAreaHighlightForPlayer(
                self.playerNum,
                zone.x1, zone.y1,
                zone.x2, zone.y2,
                zone.z or self.player:getZ(),
                0.7, 0.35, 0.15, 0.3 -- tweak RGBA as you like
            )
        end
    end
end

function HomeInventoryZonePanel:drawZoneNameOnGround()
    if not self:getIsVisible() then return end

    local tm   = getTextManager()
    local font = UIFont.Medium
    local camX = IsoCamera.getOffX()
    local camY = IsoCamera.getOffY()

    for _, zone in ipairs(HomeInventoryManager:getAllZones() or {}) do
        if math.floor(zone.z) == math.floor(self.player:getZ()) then
            local cx    = (zone.x1 + zone.x2) / 2
            local cy    = (zone.y1 + zone.y2) / 2
            local floor = getPlayer():getZ() or zone.z
            floor       = math.floor(floor)

            local rawX  = IsoUtils.XToScreen(cx, cy, floor, floor)
            local rawY  = IsoUtils.YToScreen(cx, cy, floor, floor)

            local sx    = (rawX - camX) / getCore():getZoom(0) -- accounting for zoom in/out
            local sy    = (rawY - camY) / getCore():getZoom(0)

            local name  = zone.name
            local w     = tm:MeasureStringX(font, name)
            tm:DrawString(font, sx - w / 2, sy, name, 1, 1, 1, 1)
        end
    end
end

function HomeInventoryZonePanel:updateButtons()
end

function HomeInventoryZonePanel:render()
    ISCollapsableWindowJoypad.render(self)

    self:drawZoneNameOnGround()

    self:updateButtons()

    self.removeZone.enable = false
    self.renameZone.enable = false
    if self.zoneList.selected > 0 then
        self.removeZone.enable = true
        self.renameZone.enable = true
        self.selectedZone = self.zoneList.items[self.zoneList.selected].item.zone
    else
        self.selectedZone = nil
    end

end

function HomeInventoryZonePanel:onClick(button)
    if button.internal == "OK" then
        self:close()
    end
    if button.internal == "REMOVEZONE" then
        if self.selectedZone then
            local removeText = getText("UI_HomeInventory_ZoneRemove", self.selectedZone.name)
            local modal = ISModalDialog:new(0, 0, 350, 150, removeText, true, nil, HomeInventoryZonePanel.onRemoveZone)
            modal:initialise()
            modal:addToUIManager()
            modal.ui = self
            modal.selectedZone = self.selectedZone
            modal.moveWithMouse = true
        end
    end
    if button.internal == "RENAMEZONE" then
        if self.selectedZone then
            local renameText = getText("UI_HomeInventory_ZoneRename", self.selectedZone.name)
            local modal = ISTextBox:new(0, 0, 280, 180, renameText, self.selectedZone.name, self,
                HomeInventoryZonePanel.onRenameZoneClick)
            modal:initialise()
            modal:addToUIManager()
            modal.maxChars = 30
        end
    end
    if button.internal == "ADDZONE" then
        local ui = AddHomeInventoryZoneUI:new(getPlayerScreenLeft(self.playerNum) + 10,
            getPlayerScreenTop(self.playerNum) + 10, 320, FONT_HGT_MEDIUM * 8, self.player)
        ui:initialise()
        ui:addToUIManager()
        ui.parentUI = self
        self:setVisible(false)
    end
end

function HomeInventoryZonePanel:onRenameZoneClick(button, panel)
    if button.internal == "OK" then
        if button.parent.entry:getText() and button.parent.entry:getText() ~= "" then
            if self.selectedZone then
                self.selectedZone.name = button.parent.entry:getText()
                self:populateList()
            end
        end
    end
end

function HomeInventoryZonePanel:onRemoveZone(button)
    local zone = button.parent.selectedZone

    if button.internal == "YES" then
        HomeInventoryManager:removeZone(zone)
        button.parent.ui:populateList()
        HomeInventoryManager:refresh()
    end
end

HomeInventoryZonePanel.toggleZoneUI = function(playerNum)
    -- This getPlayerZoneUI returns the Animal UI and not the home inventory UI so don't use this function.
    -- I'm not deleting this in case for some reason it is needed internally
    local ui = getPlayerZoneUI(playerNum)
    if ui then
        if ui:getIsVisible() then
            ui:setVisible(false)
            ui:removeFromUIManager()
        else
            ui:setVisible(true)
            ui:centerOnScreen(playerNum)
            ui:addToUIManager()
            ui:populateList()
        end
    end
end

function HomeInventoryZonePanel:new(x, y, width, height, player)
    x = getCore():getScreenWidth() / 2 - (width / 2)
    y = getCore():getScreenHeight() / 2 - (height / 2)
    local o = ISCollapsableWindowJoypad.new(self, x, y, width, height)
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.8 }
    o.width = width
    o.playerNum = player:getPlayerNum()
    o.height = height
    o.player = player
    o:setResizable(false)
    o.moveWithMouse = true
    HomeInventoryZonePanel.instance = o
    o.buttonBorderColor = { r = 0.7, g = 0.7, b = 0.7, a = 0.5 }
    o.listTakesFocus = false
    o:setTitle(getText("UI_HomeInventory_HomeInventoryTitle"))
    return o
end
