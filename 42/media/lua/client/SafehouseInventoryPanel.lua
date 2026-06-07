require "ISUI/ISPanel"
require "SafehouseInventoryZonePanel"

-- To-do: derive from ISPanelJoypad instead to implement controller support
SafehouseInventoryPanel      = ISPanel:derive("SafehouseInventoryPanel")

local FONT_HGT_SMALL    = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM   = getTextManager():getFontHeight(UIFont.Medium)
local UI_BORDER_SPACING = 10
local BUTTON_HGT        = FONT_HGT_SMALL + 6

local FIXED_WIDTH       = getCore():getScreenWidth() / 4.8
local FIXED_HEIGHT      = getCore():getScreenHeight() / 1.8

local PADDING           = UI_BORDER_SPACING

-- Manage button dimensions
local BUTTON_X          = PADDING
local BUTTON_Y          = PADDING
-- local BUTTON_WIDTH  = FIXED_WIDTH - 2*PADDING - (30 + PADDING) -- last term is due to the refresh button
local BUTTON_WIDTH      = FIXED_WIDTH - 2 * PADDING
local BUTTON_HEIGHT     = BUTTON_HGT
local BUTTON_XEND       = BUTTON_X + BUTTON_WIDTH
local BUTTON_YEND       = BUTTON_Y + BUTTON_HEIGHT

-- Search bar dimensions
local SEARCH_X          = PADDING
local SEARCH_Y          = BUTTON_YEND + PADDING
local SEARCH_WIDTH      = FIXED_WIDTH - 2 * PADDING
local SEARCH_HEIGHT     = FONT_HGT_SMALL
local SEARCH_XEND       = SEARCH_X + SEARCH_WIDTH
local SEARCH_YEND       = SEARCH_Y + SEARCH_HEIGHT

-- Scrolling list dimensions
local HDR_PADDING       = 20                    -- header padding
local LIST_X            = 0                     -- start at the panel border
local LIST_Y            = PADDING + SEARCH_YEND + HDR_PADDING
local LIST_WIDTH        = FIXED_WIDTH           -- end at the panel border (fill)
local LIST_HEIGHT       = FIXED_HEIGHT - LIST_Y -- fill the rest of the window

-- Columns
local COLUMN_PADDING    = 5

local COL_NAME_X        = PADDING
local COL_AMOUNT_X      = COL_NAME_X + LIST_WIDTH / 2 - (2 * PADDING)
local COL_ZONE_X        = COL_AMOUNT_X +
    getTextManager():MeasureStringX(UIFont.Small, " x000 ") -- hopefully the player won't have more than 1000 of any single item
local COL_INSIDE_X      = COL_ZONE_X + (LIST_WIDTH - COL_ZONE_X) / 2

function SafehouseInventoryPanel:initialise()
    ISPanel.initialise(self);
    self:create();
end

function SafehouseInventoryPanel:setVisible(visible)
    -- not sure what this does since populateList() never gets called
    if visible then
        self:populateList()
    end
    self.javaObject:setVisible(visible);
end

function SafehouseInventoryPanel:prerender()
    ISPanel.prerender(self)

    self:updateHoveredContainerHighlight()

    self:setWidthAndParentWidth(FIXED_WIDTH)
    self:setHeightAndParentHeight(FIXED_HEIGHT)

    -- Header for the list
    self:drawText(getText("UI_SafehouseInventory_TableName"), COL_NAME_X, self.itemList.y - FONT_HGT_SMALL, 1, 1, 1, 1,
        UIFont.Small)
    self:drawText("", COL_AMOUNT_X, self.itemList.y - FONT_HGT_SMALL, 1, 1, 1, 1, UIFont.Small)
    self:drawText(getText("UI_SafehouseInventory_TableZone"), COL_ZONE_X, self.itemList.y - FONT_HGT_SMALL, 1, 1, 1, 1,
        UIFont.Small)
    self:drawText(getText("UI_SafehouseInventory_TableInside"), COL_INSIDE_X, self.itemList.y - FONT_HGT_SMALL, 1, 1, 1, 1,
        UIFont.Small)
end

function SafehouseInventoryPanel:updateHoveredContainerHighlight()
    local hovered = self.itemList.mouseoverselected

    if not hovered or hovered <= 0 or not self.itemList:isMouseOver() then
        self:clearHighlightedContainer()
        return
    end

    local row = self.itemList.items[hovered]
    local sourceObject = row and row.item and row.item.sourceObject or nil

    if sourceObject ~= self.highlightedContainerObject then
        self:clearHighlightedContainer()
        self.highlightedContainerObject = sourceObject
    end

    if self.highlightedContainerObject then
        self.highlightedContainerObject:setHighlighted(true, false)
        self.highlightedContainerObject:setHighlightColor(0.7, 0.35, 0.15, 0.8)
    end
end

function SafehouseInventoryPanel:clearHighlightedContainer()
    if self.highlightedContainerObject then
        self.highlightedContainerObject:setHighlighted(false, false)
        self.highlightedContainerObject = nil
    end
end

function SafehouseInventoryPanel:render()
    -- not sure why the vanilla non-resizable panels render the elements every frame,
    -- hopefully it works without doing that
    -- ISPanel.render(self)
end

function SafehouseInventoryPanel:create()
    SafehouseInventoryManager:load()

    self.items = {}

    self.manageButton = ISButton:new(0, 0, BUTTON_WIDTH, BUTTON_HEIGHT, getText("UI_SafehouseInventory_ManageZonesButton"),
        self, self.onManageButtonClick)
    self.manageButton:initialise()
    self:addChild(self.manageButton)

    self.searchBar = ISTextEntryBox:new("", 0, 0, SEARCH_WIDTH, SEARCH_HEIGHT)
    self.searchBar:initialise()
    self.searchBar:instantiate()
    self.searchBar:setClearButton(true)
    self.searchBar.onTextChange = function() self:filterItems() end
    self:addChild(self.searchBar)

    self.itemList = ISScrollingListBox:new(0, 0, LIST_WIDTH, LIST_HEIGHT)

    local maxNameWidth = COL_AMOUNT_X - COL_NAME_X - COLUMN_PADDING
    local maxZoneWidth = COL_INSIDE_X - COL_ZONE_X - COLUMN_PADDING
    local maxInsideWidth = LIST_WIDTH - COL_ZONE_X - COLUMN_PADDING
    self.itemList:initialise()
    self.itemList:instantiate()
    self.itemList:setOnMouseDownFunction(self, SafehouseInventoryPanel.onItemMouseDown)
    self.itemList.itemheight = FONT_HGT_SMALL
    self.itemList.font = UIFont.Small

    -- Overwrite the default doDrawItem function to draw all item info
    self.itemList.doDrawItem = function(self, y, item, alt)
        -- "item" in here is not a world item, it is a list item
        if not item.height then item.height = self.itemheight end -- compatibililty

        local itemPadY = self.itemPadY or (item.height - self.fontHgt) / 2

        if self.selected == item.index then
            self:drawSelection(0, y + itemPadY, self:getWidth(), item.height - 1);
        elseif (self.mouseoverselected == item.index) and self:isMouseOver() and not self:isMouseOverScrollBar() then
            self:drawMouseOverHighlight(0, y + itemPadY, self:getWidth(), item.height - 1);
        end

        self:drawRectBorder(0, (y) + itemPadY, self:getWidth(), item.height, 0.5, self.borderColor.r, self.borderColor.g,
            self.borderColor.b);

        local name = HITruncateText(item.item.text, self.font, maxNameWidth)
        local amount = "x" .. tostring(item.item.amount)
        local zone = HITruncateText(item.item.zone, self.font, maxZoneWidth)
        local inside = HITruncateText(item.item.inside, self.font, maxInsideWidth)

        self:drawText(name, COL_NAME_X, (y) + itemPadY, 0.9, 0.9, 0.9, 0.9, self.font);
        self:drawText(amount, COL_AMOUNT_X, (y) + itemPadY, 0.9, 0.9, 0.9, 0.9, self.font);
        self:drawText(zone, COL_ZONE_X, (y) + itemPadY, 0.9, 0.9, 0.9, 0.9, self.font);
        self:drawText(inside, COL_INSIDE_X, (y) + itemPadY, 0.9, 0.9, 0.9, 0.9, self.font);

        y = y + item.height;
        return y;
    end
    self:addChild(self.itemList)

    -- I removed these elements from the render() function as I can't see why they have
    -- to be redrawn every time. Maybe for debugging?
    self.manageButton:setVisible(true)
    self.manageButton:setX(BUTTON_X)
    self.manageButton:setY(BUTTON_Y)
    self.manageButton.enable = true
    self.manageButton.tooltip = nil

    self.searchBar:setVisible(true)
    self.searchBar:setX(SEARCH_X)
    self.searchBar:setY(SEARCH_Y)
    self.searchBar.tooltip = nil

    self.itemList.drawBorder = true
    self.itemList:setVisible(true)
    self.itemList:setX(0)
    self.itemList:setY(LIST_Y)

    self:populateList()
end

function HITruncateText(text, font, maxWidth)
    -- Truncate function since I can't figure out how to use the built-in TextManager for this
    local tm = getTextManager()
    if tm:MeasureStringX(font, text) <= maxWidth then
        return text
    end
    local ellipsis = "..."
    local ellipsisWidth = tm:MeasureStringX(font, ellipsis)
    local truncated = text
    while #truncated > 0 and tm:MeasureStringX(font, truncated) + ellipsisWidth > maxWidth do
        truncated = truncated:sub(1, -2)
    end
    return truncated .. ellipsis
end

function SafehouseInventoryPanel:filterItems()
    local filter = self.searchBar:getText():lower()
    self.itemList:clear()

    -- if #self.items < 1 then return end -- if no items were fetched

    for _, v in ipairs(self.items) do
        if filter == "" or v.text:lower():find(filter, 1, true) then
            self.itemList:addItem(v.text, v)
        end
    end
end

function SafehouseInventoryPanel:populateList()
    print("SafehouseInventory: populating item list.")
    self.itemList:clear()
    self.items = SafehouseInventoryManager:getAllItemInfo()
    self:filterItems()
end

function SafehouseInventoryPanel:onManageButtonClick()
    local playerObj = getPlayer()
    local playerNum = playerObj:getPlayerNum()

    local ui = SafehouseInventoryZonePanel.instance

    if not ui then
        -- if it doesn't exist, create
        ui = SafehouseInventoryZonePanel:new(
            getPlayerScreenLeft(playerNum) + 100,
            getPlayerScreenTop(playerNum) + 100,
            500,
            500,
            playerObj
        )
        ui:initialise()
        ui:addToUIManager()
    else
        -- if it is visible, close it
        if ui:getIsVisible() then
            ui:close()
        else
            -- if not visible but exists, bring to top
            ui:setVisible(true)
            ui:centerOnScreen(playerNum)
            ui:addToUIManager()
            ui:populateList()
        end
    end
    self:populateList()
end

function SafehouseInventoryPanel:onItemMouseDown(item)
    if not item then return end

    local row = self.itemList.selected

    local zone = SafehouseInventoryManager:getZoneByName(item.zone)

    if not zone then return end

    local player = getPlayer()

    local tx = (zone.x1 + zone.x2) / 2
    local ty = (zone.y1 + zone.y2) / 2
    local tz = player:getZ()

    local location = { -- hack until I make zones into classes with getters
        x = tx,
        y = ty,
        z = tz
    }

    function location:getX() return self.x end

    function location:getY() return self.y end

    function location:getZ() return self.z end

    local walkTo = ISWalkToTimedAction:new( -- defined in media/lua/client/TimedActions/WalkToTimedAction.lua
        player,
        location,
        nil,
        nil
    )

    ISTimedActionQueue.add(walkTo)

    -- Debug
    -- for k, v in pairs(item) do
    --     print(k .. " " .. v)
    -- end
    -- print("Clicked on row ", row, " which holds ", item)
end

function SafehouseInventoryPanel:new(x, y, width, height, playerNum)
    local o = {};

    width   = width or getCore():getScreenWidth() / 4.8 -- fallback to prevent errors
    height  = height or getCore():getScreenHeight() / 1.8

    o       = ISPanel:new(x, y, width, height);
    o:noBackground();
    setmetatable(o, self);
    self.__index = self;
    o.playerNum = playerNum
    o.char = getSpecificPlayer(playerNum);
    o.refreshNeeded = true
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 };
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.8 };

    return o;
end
