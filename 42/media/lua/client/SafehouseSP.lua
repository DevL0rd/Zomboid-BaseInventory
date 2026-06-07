--[[
    Safehouse in Single-Player
    --------------------------
    Project Zomboid's safehouse system is fully functional at the engine level (the Java class
    zombie.iso.areas.SafeHouse exposes addSafeHouse / removeSafeHouse / addPlayer / removePlayer /
    save / load to Lua), but the *claim and management UX* is gated to multiplayer:
      * the "Claim Safehouse" world context option is only added by the (Java) context-menu logic in MP;
      * the claim/member/release buttons call the global send* functions, which are GameClient network
        calls that no-op when there is no server.

    This module patches that gap WITHOUT touching multiplayer:
      * In single-player (not a client, not a server) it overrides the global sendSafehouse* functions
        so they apply changes directly through the engine SafeHouse API.
      * In MP / on a dedicated server it delegates to the original functions unchanged.
      * It adds "Claim Safehouse" / "Manage Safehouse" / "Release Safehouse" world context options in SP
        (mirroring vanilla), reusing the vanilla ISSafehouseUI for management.

    Because the send* functions are the single choke point the rest of the game (and other mods) use,
    patching them here makes vanilla safehouse mechanics and safehouse-dependent mods work in SP too.

    NOTE: this is the foundation for SafehouseInventory's "zones must be inside a claimed safehouse,
    shared with its members" feature; it is intentionally a standalone, general patch.
]]

-- Single-player = neither a multiplayer client nor a server.
local function isSP()
    return not isClient() and not isServer()
end

-- The username the engine associates with the local player. Kept exactly as the engine reports it
-- (even if empty) so that SafeHouse owner/member comparisons stay consistent with the engine's own
-- isSafehouseAllowInteract / isOwner checks.
local function localUsername(playerObj)
    local u = playerObj and playerObj.getUsername and playerObj:getUsername()
    return u or ""
end

local function safeSave()
    if SafeHouse and SafeHouse.save then pcall(SafeHouse.save) end
end

local function notifyChanged()
    pcall(function() triggerEvent("OnSafehousesChanged") end)
end

-- Tiles of slack added around a claimed building so the safehouse covers the yard/porch too
-- (lets you draw inventory zones a bit outside the walls).
local CLAIM_PAD = 5

-- Rectangle (x, y, w, h) of the building on `square` (padded), or a padded area around the square.
local function claimRect(square)
    if not square then return nil end
    local b = square:getBuilding()
    local def = b and (b:getDef() or b)
    if def then
        local x, y = def:getX(), def:getY()
        local w = def.getW and def:getW()
        local h = def.getH and def:getH()
        if (not w or w <= 0) and def.getX2 then w = def:getX2() - x + 1 end
        if (not h or h <= 0) and def.getY2 then h = def:getY2() - y + 1 end
        if x and y and w and h and w > 0 and h > 0 then
            -- pad outward by CLAIM_PAD on every side
            return x - CLAIM_PAD, y - CLAIM_PAD, w + CLAIM_PAD * 2, h + CLAIM_PAD * 2
        end
    end
    -- Not a building (e.g. open ground): claim a padded area around the square.
    local s = CLAIM_PAD * 2 + 1
    return square:getX() - CLAIM_PAD, square:getY() - CLAIM_PAD, s, s
end

-- ── Override the global send* functions for single-player ─────────────────────────────
-- Each keeps a reference to the original and only changes behaviour when isSP().

local _origClaim = sendSafehouseClaim
function sendSafehouseClaim(square, playerObj, username)
    if not isSP() then return _origClaim and _origClaim(square, playerObj, username) end
    if not (SafeHouse and SafeHouse.addSafeHouse) then
        print("[SafehouseSP] SafeHouse.addSafeHouse not available; cannot claim in SP.")
        return
    end
    if SafeHouse.getSafeHouse(square) then return end -- already claimed
    local x, y, w, h = claimRect(square)
    if not x then return end
    username = username or localUsername(playerObj)
    local ok, sh = pcall(SafeHouse.addSafeHouse, x, y, w, h, username)
    if ok and sh then
        pcall(function() sh:setTitle((username ~= "" and username or "Safehouse") .. "'s Safehouse") end)
        safeSave()
        notifyChanged()
        print("[SafehouseSP] Claimed safehouse at " .. x .. "," .. y .. " (" .. w .. "x" .. h .. ") for '" .. tostring(username) .. "'.")
    else
        print("[SafehouseSP] addSafeHouse failed: " .. tostring(sh))
    end
end

local _origRelease = sendSafehouseRelease
function sendSafehouseRelease(safehouse)
    if not isSP() then return _origRelease and _origRelease(safehouse) end
    if SafeHouse and SafeHouse.removeSafeHouse then pcall(SafeHouse.removeSafeHouse, safehouse) end
    safeSave()
    notifyChanged()
end

-- Vanilla "change member" toggles membership for the given username.
local _origChangeMember = sendSafehouseChangeMember
function sendSafehouseChangeMember(safehouse, username)
    if not isSP() then return _origChangeMember and _origChangeMember(safehouse, username) end
    if not (safehouse and username) then return end
    local players = safehouse:getPlayers()
    local has = false
    if players then
        for i = 0, players:size() - 1 do
            if players:get(i) == username then has = true break end
        end
    end
    if has then
        pcall(function() safehouse:removePlayer(username) end)
    else
        pcall(function() safehouse:addPlayer(username) end)
    end
    safeSave()
    notifyChanged()
end

local _origChangeTitle = sendSafehouseChangeTitle
function sendSafehouseChangeTitle(safehouse, title)
    if not isSP() then return _origChangeTitle and _origChangeTitle(safehouse, title) end
    pcall(function() safehouse:setTitle(title) end)
    safeSave()
    notifyChanged()
end

local _origChangeOwner = sendSafehouseChangeOwner
function sendSafehouseChangeOwner(safehouse, username)
    if not isSP() then return _origChangeOwner and _origChangeOwner(safehouse, username) end
    pcall(function() safehouse:setOwner(username) end)
    safeSave()
    notifyChanged()
end

local _origChangeRespawn = sendSafehouseChangeRespawn
function sendSafehouseChangeRespawn(safehouse, username, enabled)
    if not isSP() then return _origChangeRespawn and _origChangeRespawn(safehouse, username, enabled) end
    pcall(function() safehouse:setRespawnInSafehouse(username, enabled) end)
    safeSave()
    notifyChanged()
end

-- Inviting has no meaning offline; treat it as directly adding the member.
local _origInvite = sendSafehouseInvite
function sendSafehouseInvite(safehouse, hostUsername, targetUsername)
    if not isSP() then return _origInvite and _origInvite(safehouse, hostUsername, targetUsername) end
    pcall(function() safehouse:addPlayer(targetUsername) end)
    safeSave()
    notifyChanged()
end

-- ── World context menu (single-player only; MP already provides these) ────────────────
local function openSafehouseUI(safehouse, playerObj)
    local width = 500 + getCore():getOptionFontSizeReal() * 30
    local ui = ISSafehouseUI:new((getCore():getScreenWidth() - width) / 2, getCore():getScreenHeight() / 2 - 225, width, 450, safehouse, playerObj)
    ui:initialise()
    ui:addToUIManager()
end

Events.OnFillWorldObjectContextMenu.Add(function(playerNum, context, worldobjects, test)
    if test then return end
    if not isSP() then return end -- MP/dedicated already have the vanilla options
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return end

    local square
    for _, o in ipairs(worldobjects) do
        local s = o.getSquare and o:getSquare()
        if s then square = s break end
    end
    square = square or playerObj:getCurrentSquare()
    if not square then return end

    local sh = SafeHouse and SafeHouse.getSafeHouse(square)
    if sh then
        local isOwner = (sh.isOwner and sh:isOwner(playerObj)) or (sh:getOwner() == localUsername(playerObj))
        if isOwner then
            context:addOption(getText("ContextMenu_ViewSafehouse"), worldobjects, function()
                openSafehouseUI(sh, playerObj)
            end)
            context:addOption(getText("ContextMenu_SafehouseRelease"), worldobjects, function()
                sendSafehouseRelease(sh)
            end)
        end
    elseif square:getBuilding() then
        context:addOption(getText("ContextMenu_SafehouseClaim"), worldobjects, function()
            sendSafehouseClaim(square, playerObj, localUsername(playerObj))
        end)
    end
end)

print("[SafehouseSP] Single-player safehouse patch loaded (SP=" .. tostring(isSP()) .. ").")
