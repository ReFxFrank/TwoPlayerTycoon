--[[
    client.spec
    Boots the REAL ClientBootstrap against the real server and drives the UI the way a player does.

    This exists because a whole feature was missing and every server-side test passed: the LinkOffer
    remote was declared, fired and had a modal built for it, but no controller ever listened. The
    integration spec called PlotService:ResolveLink directly and walked straight past the gap, so
    linking -- the game's entire two-player hook -- could not be completed by an actual player.
]]

local RemoteSchema = loadModule("ReplicatedStorage/Modules/RemoteSchema")

local function bootServer()
    runScript("ServerScriptService/Core/Bootstrap")
    Mock.advance(0.5)
    local services = {}
    for _, name in ipairs({ "ProfileService", "PlotService", "EconomyService", "RemoteService" }) do
        services[name] = loadModule("ServerScriptService/Core/Services/" .. name)
    end
    return services
end

--- Runs ClientBootstrap as `player`, returning their ScreenGui.
--- setLocalPlayer is set OUTSIDE asClient and left set: FireClient only delivers to the mock's
--- current local player, so reverting it would silently stop every later server push reaching them.
local function bootClient(player)
    Mock.setLocalPlayer(player)
    Mock.asClient(player, function()
        runScript("StarterPlayer/StarterPlayerScripts/Client/ClientBootstrap")
    end)
    Mock.setLocalPlayer(player)
    Mock.advance(1)
    local gui = player:FindFirstChild("PlayerGui")
    return gui and gui:FindFirstChildOfClass("ScreenGui")
end

local function findModal(screenGui, name)
    for _, descendant in ipairs(screenGui:GetDescendants()) do
        if descendant.Name == name then return descendant end
    end
    return nil
end

t.test("the client boots and builds a HUD", function()
    bootServer()
    local ash = Mock.addPlayer("Ash", 1)
    Mock.advance(1)
    local screenGui = bootClient(ash)
    t.truthy(screenGui, "a ScreenGui was parented to PlayerGui")
    t.falsy(screenGui.ResetOnSpawn, "the HUD must survive a respawn")
end)

t.test("every controller ClientBootstrap lists actually exists", function()
    -- A name in the list with no module is a silently missing feature: ClientBootstrap warns and
    -- carries on, which is right at runtime and invisible in a test that does not check.
    local folder = game:GetService("StarterPlayer"):FindFirstChild("StarterPlayerScripts")
    local controllers = folder and folder:FindFirstChild("Client")
    controllers = controllers and controllers:FindFirstChild("Controllers")
    t.truthy(controllers, "the Controllers folder exists")

    local source = { "HudController", "NotifyController", "PromptController", "AffinityController",
        "LinkController", "RebirthController", "SettingsController", "EvolutionFxController",
        "SoundController" }
    for _, name in ipairs(source) do
        t.truthy(controllers:FindFirstChild(name), ("controller %s is missing"):format(name))
    end
end)

t.test("every server-to-client remote has a client consumer", function()
    -- The structural guard for the other direction. LinkOffer was fired by the server for a client
    -- that was never listening, and nothing anywhere failed.
    bootServer()
    local ash = Mock.addPlayer("Ash", 1)
    Mock.advance(1)
    bootClient(ash)

    local folder = game:GetService("ReplicatedStorage"):FindFirstChild(RemoteSchema.FolderName)
    for _, def in ipairs(RemoteSchema.List) do
        if def.Direction == "ServerToClient" then
            local remote = folder:FindFirstChild(def.Name)
            t.truthy(remote, def.Name .. " exists")
            local signal = Mock.Instances.getSignal(remote, "OnClientEvent")
            local listeners = 0
            for _ in pairs(signal._handlers) do listeners += 1 end
            t.gt(listeners, 0, ("%s is fired by the server but nothing on the client listens"):format(def.Name))
        end
    end
end)

t.test("a link offer reaches the occupant and Accept answers the server", function()
    local services = bootServer()
    local ash = Mock.addPlayer("Ash", 1)
    local bree = Mock.addPlayer("Bree", 2)
    Mock.advance(1)
    local screenGui = bootClient(ash) -- Ash is the occupant who will be asked
    local host = services.PlotService:GetSanctumForPlayer(ash)
    t.truthy(host)

    local modal = findModal(screenGui, "LinkOffer")
    t.truthy(modal, "the offer modal exists")
    t.falsy(modal.Visible, "and starts hidden")

    -- Bree asks to join. The server pushes LinkOffer to Ash.
    t.truthy(services.PlotService:RequestLink(bree, host))
    Mock.advance(0.2)
    t.truthy(modal.Visible, "the occupant is actually asked -- this is the bug that was missing")

    -- Ash presses Accept. That must reach the server as a real LinkResponse and complete the link.
    local confirm
    for _, descendant in ipairs(modal:GetDescendants()) do
        if descendant:IsA("TextButton") and descendant.Name == "Confirm" then confirm = descendant end
    end
    t.truthy(confirm, "the modal has a confirm button")
    Mock.asClient(ash, function()
        Mock.Instances.getSignal(confirm, "Activated"):Fire()
    end)
    Mock.advance(0.5)

    t.eq(#services.PlotService:GetOccupants(host), 2,
        "pressing Accept in the real UI completes the link")
    t.falsy(modal.Visible, "and the modal closes")
end)

t.test("declining sends a no and leaves both players where they were", function()
    local services = bootServer()
    local ash = Mock.addPlayer("Ash", 1)
    local bree = Mock.addPlayer("Bree", 2)
    Mock.advance(1)
    local screenGui = bootClient(ash)
    local host = services.PlotService:GetSanctumForPlayer(ash)
    local guestPlot = services.PlotService:GetSanctumForPlayer(bree)

    services.PlotService:RequestLink(bree, host)
    Mock.advance(0.2)
    local modal = findModal(screenGui, "LinkOffer")
    t.truthy(modal.Visible)

    local cancel
    for _, descendant in ipairs(modal:GetDescendants()) do
        if descendant:IsA("TextButton") and descendant.Name == "Cancel" then cancel = descendant end
    end
    Mock.asClient(ash, function()
        Mock.Instances.getSignal(cancel, "Activated"):Fire()
    end)
    Mock.advance(0.5)

    t.eq(#services.PlotService:GetOccupants(host), 1, "the link did not happen")
    t.eq(services.PlotService:GetSanctumForPlayer(bree).Id, guestPlot.Id, "and the joiner stayed home")
    t.falsy(modal.Visible)
end)

t.test("an unanswered offer closes itself rather than sitting open forever", function()
    local GameConfig = loadModule("ReplicatedStorage/Modules/GameConfig")
    local services = bootServer()
    local ash = Mock.addPlayer("Ash", 1)
    local bree = Mock.addPlayer("Bree", 2)
    Mock.advance(1)
    local screenGui = bootClient(ash)
    local host = services.PlotService:GetSanctumForPlayer(ash)

    services.PlotService:RequestLink(bree, host)
    Mock.advance(0.2)
    local modal = findModal(screenGui, "LinkOffer")
    t.truthy(modal.Visible)

    Mock.advance(GameConfig.Plot.LinkConfirmSeconds + 5)
    t.falsy(modal.Visible, "a modal that outlives its offer blocks the whole screen")
end)

t.test("the HUD renders essence from a real server push", function()
    local services = bootServer()
    local ash = Mock.addPlayer("Ash", 1)
    Mock.advance(1)
    local screenGui = bootClient(ash)
    local sanctum = services.PlotService:GetSanctumForPlayer(ash)

    services.EconomyService:Credit(sanctum, 12345)
    Mock.advance(2)

    local label
    for _, descendant in ipairs(screenGui:GetDescendants()) do
        if descendant.Name == "EssenceLabel" then label = descendant end
    end
    t.truthy(label, "the HUD has an essence label")
    t.truthy(#label.Text > 0, "and it rendered something")
    t.truthy(label.Text:find("12") ~= nil or label.Text:find("K") ~= nil,
        "which reflects the server's number, got: " .. label.Text)
end)
