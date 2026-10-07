local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer

print("[BrainrotFarm] Starting v2.5...")

--------------------------------------------------------------------------------
-- CONFIG (tune to taste)
--------------------------------------------------------------------------------
local Config = {
    MaxDistance = 10000,     -- scan range (very high = whole map)
    ShotsPerVolley = 3,     -- shots per volley (was 10)
    VolleyDelay = 0.12,     -- delay between volleys (was 0.02)
    KillTimeout = 20,       -- give up on a target after this many seconds
    AttackDistance = 35,    -- stand this far from target while shooting (safer)
    RetreatHealth = 0.35,   -- retreat to safe zone if HP drops below this fraction
    RunSpeed = 500,         -- safe-zone return speed (outrun the chase wave)
    SafeZone = Vector3.new(67.571, 32.919, -122.604),
    BlacklistTime = 60,     -- ignore failed targets for this long
    WeaponName = "RPK-74",
}

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------
local loopIsActive = false
local autoFarmEnabled = false
local killCount = 0
local failCount = 0
local blacklist = {} -- [instance] = os.clock() of failure
local runToSafeZone -- forward declaration (defined before farmBody, used by UI button)

--------------------------------------------------------------------------------
-- CLEANUP / REMOTES
--------------------------------------------------------------------------------
local targetUI = LocalPlayer:WaitForChild("PlayerGui")
local old = targetUI:FindFirstChild("MobileBrainrotOverlay")
if old then old:Destroy() end

local Gasifier = ReplicatedStorage:WaitForChild("Gasifier", 5)
local function getRemotePath(pathStr)
    if not Gasifier then return nil end
    local current = Gasifier
    for section in string.gmatch(pathStr, "[^.]+") do
        if current then current = current:WaitForChild(section, 2) end
    end
    return current
end

local Remotes = { Catching = getRemotePath("Services.BrainrotService.RE.Catching") }
local SoundEvent = getRemotePath("Library.Commons.SoundCreator.event")
local BulletFunction = getRemotePath("Services.Projectile.RF.ReplyBullet")
local HitFunction = getRemotePath("Services.Projectile.RF.Hitted")

local brainrotsFolder = Workspace:WaitForChild("BrainrotsFolder", 5)
if not brainrotsFolder then
    warn("[BrainrotFarm] BrainrotsFolder missing from Workspace.")
    return
end

-- Catch acknowledgement: the server fires Catching.OnClientEvent(name, mutation, ...)
-- when a catch actually registers. We use it to know the carry started.
local carryStarted = false
local currentTargetName = nil
pcall(function()
    if Remotes.Catching and Remotes.Catching.OnClientEvent then
        Remotes.Catching.OnClientEvent:Connect(function(name, mutation)
            if currentTargetName and tostring(name) == currentTargetName then
                print("[BrainrotFarm] Catch confirmed by server: " .. tostring(name))
                carryStarted = true
            end
        end)
    end
end)

--------------------------------------------------------------------------------
-- NOCLIP (cached parts, cheaper than scanning every frame)
--------------------------------------------------------------------------------
local noclipParts = {}
local function refreshNoclipCache()
    noclipParts = {}
    local character = LocalPlayer.Character
    if character then
        for _, part in ipairs(character:GetDescendants()) do
            if part:IsA("BasePart") then
                table.insert(noclipParts, part)
            end
        end
        character.DescendantAdded:Connect(function(d)
            if d:IsA("BasePart") then
                table.insert(noclipParts, d)
            end
        end)
    end
end
LocalPlayer.CharacterAdded:Connect(function()
    task.wait(0.5)
    refreshNoclipCache()
end)
refreshNoclipCache()

RunService.PreSimulation:Connect(function()
    for _, part in ipairs(noclipParts) do
        if part and part.Parent and part.CanCollide then
            part.CanCollide = false
        end
    end
end)

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------
local function getMutation(item)
    local m = item:FindFirstChild("Mutation")
    if m and (m:IsA("StringValue") or m:IsA("ValueBase")) then
        return tostring(m.Value or "")
    end
    local attr = item:GetAttribute("Mutation")
    if attr ~= nil then return tostring(attr) end
    return ""
end

local function isMutated(item)
    local clean = string.lower(string.gsub(getMutation(item), "%s+", ""))
    return clean ~= "" and clean ~= "nomutation" and clean ~= "normal"
end

local function isBlacklisted(item)
    local t = blacklist[item]
    return t ~= nil and (os.clock() - t) < Config.BlacklistTime
end

local function getTargetPosition(item)
    if item:IsA("Model") then
        local ok, pivot = pcall(function() return item:GetPivot() end)
        if ok and pivot then return pivot.Position end
        local pp = item.PrimaryPart
        if pp then return pp.Position end
    elseif item:IsA("BasePart") then
        return item.Position
    end
    return nil
end

local function findHumanoid(item)
    -- recursive: some brainrots nest their Humanoid deeper than direct children
    if not item then return nil end
    local h = item:FindFirstChildOfClass("Humanoid")
    if h then return h end
    for _, d in ipairs(item:GetDescendants()) do
        if d:IsA("Humanoid") then return d end
    end
    return nil
end

local function ensureWeaponIsEquipped()
    local character = LocalPlayer.Character
    if not character then return nil end
    local current = character:FindFirstChild(Config.WeaponName)
    if current and current:IsA("Tool") and current:FindFirstChild("Handle") then
        return current
    end
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    if backpack then
        local w = backpack:FindFirstChild(Config.WeaponName)
        if w and w:IsA("Tool") and w:FindFirstChild("Handle") then
            w.Parent = character
            task.wait(0.05)
            return w
        end
    end
    return nil
end

local function FireWeapon(targetPart, distance)
    if not SoundEvent or not BulletFunction or not HitFunction then return false end
    local character = LocalPlayer.Character
    if not character then return false end
    local root = character:FindFirstChild("HumanoidRootPart")
    if not root then return false end
    if not targetPart or not targetPart.Parent then return false end

    local myPos = root.Position
    local targetPos = targetPart.Position
    local direction = (targetPos - myPos).Unit

    pcall(function()
        SoundEvent:FireServer(SoundService.Weapon.Weapons[Config.WeaponName].Shot, nil, myPos, 1, nil)
    end)
    pcall(function()
        BulletFunction:InvokeServer({
            Template = ReplicatedStorage.Gasifier.Library._Gasindex["gas_projectile@1.0.0"].projectile.Templates.Ink,
            CollisionGroup = "Bullets", Owner = LocalPlayer,
            Ignore = { Workspace.Camera, Workspace.ClientProjectiles, character, Workspace.Ignore },
            Life = 3, Color = Color3.new(1, 1, 0), Speed = 2500,
            CFrame = CFrame.lookAt(myPos, targetPos), Decay = 0,
            Size = Vector3.new(0.125, 0.125, 15),
        })
    end)
    pcall(function()
        HitFunction:InvokeServer({
            Normal = -direction,
            BulletCFrame = CFrame.lookAt(targetPos, myPos),
            BulletColor = Color3.new(1, 1, 0),
            Owner = LocalPlayer, Position = targetPos,
            InitialCFrame = CFrame.lookAt(myPos, targetPos),
            Material = Enum.Material.Plastic, Instance = targetPart, Distance = distance,
        })
    end)
    return true
end

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------
local Theme = {
    Blue = Color3.fromRGB(0, 170, 255),
    Pink = Color3.fromRGB(255, 80, 180),
    Green = Color3.fromRGB(0, 220, 100),
    Red = Color3.fromRGB(255, 60, 60),
    Orange = Color3.fromRGB(255, 140, 0),
    Yellow = Color3.fromRGB(255, 210, 0),
    Purple = Color3.fromRGB(150, 80, 255),
    Dark = Color3.fromRGB(30, 30, 60),
    White = Color3.fromRGB(255, 255, 255),
}

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "MobileBrainrotOverlay"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = targetUI

local MainFrame = Instance.new("Frame")
-- compact heights: collapsed hides the 130px target list + its padding
local FRAME_H_COLLAPSED = 172
local FRAME_H_EXPANDED = 310
MainFrame.Size = UDim2.new(0, 300, 0, FRAME_H_COLLAPSED)
MainFrame.Position = UDim2.new(0, 10, 0, 120)
MainFrame.BackgroundColor3 = Theme.Blue
MainFrame.BorderSizePixel = 0
MainFrame.Active = true
MainFrame.Parent = screenGui
local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 14)
mainCorner.Parent = MainFrame
local mainStroke = Instance.new("UIStroke")
mainStroke.Color = Theme.Dark
mainStroke.Thickness = 2
mainStroke.Parent = MainFrame

local TitleBar = Instance.new("Frame")
TitleBar.Size = UDim2.new(1, 0, 0, 40)
TitleBar.BackgroundColor3 = Theme.Pink
TitleBar.BorderSizePixel = 0
TitleBar.Parent = MainFrame
local titleCorner = Instance.new("UICorner")
titleCorner.CornerRadius = UDim.new(0, 14)
titleCorner.Parent = TitleBar
-- square off bottom of title bar
local titleFix = Instance.new("Frame")
titleFix.Size = UDim2.new(1, 0, 0, 14)
titleFix.Position = UDim2.new(0, 0, 1, -14)
titleFix.BackgroundColor3 = Theme.Pink
titleFix.BorderSizePixel = 0
titleFix.Parent = TitleBar

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Size = UDim2.new(1, -50, 1, 0)
TitleLabel.Position = UDim2.new(0, 12, 0, 0)
TitleLabel.BackgroundTransparency = 1
TitleLabel.Text = "🎯 Brainrot Farm"
TitleLabel.TextColor3 = Theme.White
TitleLabel.Font = Enum.Font.FredokaOne
TitleLabel.TextSize = 18
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.Parent = TitleBar

local MinButton = Instance.new("TextButton")
MinButton.Size = UDim2.new(0, 32, 0, 32)
MinButton.Position = UDim2.new(1, -38, 0, 4)
MinButton.BackgroundColor3 = Theme.Red
MinButton.Text = "X"
MinButton.TextColor3 = Theme.White
MinButton.Font = Enum.Font.FredokaOne
MinButton.TextSize = 16
MinButton.Parent = TitleBar
local minCorner = Instance.new("UICorner")
minCorner.CornerRadius = UDim.new(1, 0)
minCorner.Parent = MinButton

local StatusLabel = Instance.new("TextLabel")
StatusLabel.Size = UDim2.new(1, -20, 0, 26)
StatusLabel.Position = UDim2.new(0, 10, 0, 46)
StatusLabel.BackgroundTransparency = 1
StatusLabel.Text = "Idle"
StatusLabel.TextColor3 = Theme.White
StatusLabel.Font = Enum.Font.GothamBold
StatusLabel.TextSize = 14
StatusLabel.TextXAlignment = Enum.TextXAlignment.Left
StatusLabel.Parent = MainFrame

local function setStatus(text)
    StatusLabel.Text = text .. string.format("  |  ✅ %d  ❌ %d", killCount, failCount)
end

local AutoFarmBtn = Instance.new("TextButton")
AutoFarmBtn.Size = UDim2.new(0.5, -15, 0, 42)
AutoFarmBtn.Position = UDim2.new(0, 10, 0, 76)
AutoFarmBtn.BackgroundColor3 = Theme.Orange
AutoFarmBtn.Text = "🔁 AUTO: OFF"
AutoFarmBtn.TextColor3 = Theme.White
AutoFarmBtn.Font = Enum.Font.FredokaOne
AutoFarmBtn.TextSize = 14
AutoFarmBtn.Parent = MainFrame
local afCorner = Instance.new("UICorner")
afCorner.CornerRadius = UDim.new(0, 10)
afCorner.Parent = AutoFarmBtn

local RunBtn = Instance.new("TextButton")
RunBtn.Size = UDim2.new(0.5, -15, 0, 42)
RunBtn.Position = UDim2.new(0.5, 5, 0, 76)
RunBtn.BackgroundColor3 = Theme.Green
RunBtn.Text = "🏃 SAFE ZONE"
RunBtn.TextColor3 = Theme.White
RunBtn.Font = Enum.Font.FredokaOne
RunBtn.TextSize = 14
RunBtn.Parent = MainFrame
local rbCorner = Instance.new("UICorner")
rbCorner.CornerRadius = UDim.new(0, 10)
rbCorner.Parent = RunBtn

-- manual fallback: run back now, unstick the auto loop if needed
RunBtn.MouseButton1Click:Connect(function()
    loopIsActive = false
    setStatus("Manual run-back...")
    task.spawn(runToSafeZone)
end)

AutoFarmBtn.MouseButton1Click:Connect(function()
    autoFarmEnabled = not autoFarmEnabled
    if autoFarmEnabled then
        AutoFarmBtn.Text = "🔁 AUTO: ON"
        AutoFarmBtn.BackgroundColor3 = Theme.Green
        print("[BrainrotFarm] Auto-farm enabled")
    else
        AutoFarmBtn.Text = "🔁 AUTO: OFF"
        AutoFarmBtn.BackgroundColor3 = Theme.Orange
        print("[BrainrotFarm] Auto-farm disabled")
    end
end)

local DropdownBtn = Instance.new("TextButton")
DropdownBtn.Size = UDim2.new(1, -20, 0, 42)
DropdownBtn.Position = UDim2.new(0, 10, 0, 122)
DropdownBtn.BackgroundColor3 = Theme.Purple
DropdownBtn.Text = "🔽 Targets (0)"
DropdownBtn.TextColor3 = Theme.White
DropdownBtn.Font = Enum.Font.FredokaOne
DropdownBtn.TextSize = 15
DropdownBtn.Parent = MainFrame
local ddCorner = Instance.new("UICorner")
ddCorner.CornerRadius = UDim.new(0, 10)
ddCorner.Parent = DropdownBtn

local ScrollFrame = Instance.new("ScrollingFrame")
ScrollFrame.Size = UDim2.new(1, -20, 0, 130)
ScrollFrame.Position = UDim2.new(0, 10, 0, 168)
ScrollFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
ScrollFrame.BackgroundTransparency = 0.15
ScrollFrame.Visible = false
ScrollFrame.BorderSizePixel = 0
ScrollFrame.ScrollBarThickness = 6
ScrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
ScrollFrame.Parent = MainFrame
local sfCorner = Instance.new("UICorner")
sfCorner.CornerRadius = UDim.new(0, 10)
sfCorner.Parent = ScrollFrame

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 6)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = ScrollFrame
local listPad = Instance.new("UIPadding")
listPad.PaddingTop = UDim.new(0, 6)
listPad.PaddingLeft = UDim.new(0, 6)
listPad.PaddingRight = UDim.new(0, 6)
listPad.Parent = ScrollFrame

-- Minimize circle
local MinCircle = Instance.new("TextButton")
MinCircle.Name = "MinCircle"
MinCircle.Size = UDim2.new(0, 55, 0, 55)
MinCircle.Position = UDim2.new(0, 10, 0, 120)
MinCircle.BackgroundColor3 = Theme.Pink
MinCircle.Text = "🎯"
MinCircle.TextSize = 28
MinCircle.Font = Enum.Font.FredokaOne
MinCircle.TextColor3 = Theme.White
MinCircle.Visible = false
MinCircle.Parent = screenGui
local mcCorner = Instance.new("UICorner")
mcCorner.CornerRadius = UDim.new(1, 0)
mcCorner.Parent = MinCircle

MinButton.MouseButton1Click:Connect(function()
    MainFrame.Visible = false
    MinCircle.Visible = true
end)
MinCircle.MouseButton1Click:Connect(function()
    MinCircle.Visible = false
    MainFrame.Visible = true
end)

-- Draggable via title bar (simple, no nested connections)
do
    local dragging = false
    local dragStart = nil
    local startPos = nil
    TitleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = MainFrame.Position
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and dragStart and startPos then
            if input.UserInputType == Enum.UserInputType.MouseMovement
                or input.UserInputType == Enum.UserInputType.Touch then
                local delta = input.Position - dragStart
                MainFrame.Position = UDim2.new(
                    startPos.X.Scale, startPos.X.Offset + delta.X,
                    startPos.Y.Scale, startPos.Y.Offset + delta.Y)
            end
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
end

DropdownBtn.MouseButton1Click:Connect(function()
    ScrollFrame.Visible = not ScrollFrame.Visible
    -- grow/shrink the frame with the target list
    if ScrollFrame.Visible then
        MainFrame.Size = UDim2.new(0, 300, 0, FRAME_H_EXPANDED)
    else
        MainFrame.Size = UDim2.new(0, 300, 0, FRAME_H_COLLAPSED)
    end
end)

--------------------------------------------------------------------------------
-- TARGET LIST (button reuse + debounce + distance filter)
--------------------------------------------------------------------------------
local MutationColors = {
    rainbow = Color3.fromRGB(200, 100, 255),
    diamond = Color3.fromRGB(120, 200, 255),
    gold = Color3.fromRGB(230, 180, 0),
    shiny = Color3.fromRGB(180, 180, 80),
    blood = Color3.fromRGB(220, 50, 50),
    dark = Color3.fromRGB(90, 90, 140),
    lava = Color3.fromRGB(255, 110, 30),
    frost = Color3.fromRGB(150, 220, 255),
}

local function mutationColor(mutation)
    local m = string.lower(mutation)
    for key, color in pairs(MutationColors) do
        if string.find(m, key, 1, true) then
            return color
        end
    end
    return Theme.Orange -- fallback
end

local targetButtons = {} -- [instance] = button

local function onTargetSelected(item)
    if loopIsActive then return end
    ScrollFrame.Visible = false
    MainFrame.Size = UDim2.new(0, 300, 0, FRAME_H_COLLAPSED)
    task.spawn(function() runFarmCycle(item) end)
end

local function createTargetButton(item)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -6, 0, 46)
    btn.BackgroundColor3 = Theme.White
    btn.TextColor3 = Theme.Dark
    btn.TextSize = 13
    btn.Font = Enum.Font.GothamBold
    btn.TextXAlignment = Enum.TextXAlignment.Left
    btn.TextTruncate = Enum.TextTruncate.AtEnd
    btn.Parent = ScrollFrame
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 10)
    c.Parent = btn
    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 2
    stroke.Parent = btn
    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, 10)
    pad.Parent = btn
    btn.MouseButton1Click:Connect(function() onTargetSelected(item) end)
    return btn
end

local function updateDynamicMenu()
    -- expire blacklist entries for destroyed/old targets
    local now = os.clock()
    for target, t in pairs(blacklist) do
        if (not target) or (not target.Parent) or (now - t) >= Config.BlacklistTime then
            blacklist[target] = nil
        end
    end

    local seen = {}
    local count = 0
    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local rootPos = root and root.Position

    for _, item in ipairs(brainrotsFolder:GetChildren()) do
        if (item:IsA("BasePart") or item:IsA("Model")) and isMutated(item) and not isBlacklisted(item) then
            local pos = getTargetPosition(item)
            local dist = (rootPos and pos) and (rootPos - pos).Magnitude or nil
            if (not dist) or dist <= Config.MaxDistance then
                seen[item] = true
                count = count + 1
                local btn = targetButtons[item]
                if not btn or not btn.Parent then
                    btn = createTargetButton(item)
                    targetButtons[item] = btn
                end
                local mut = getMutation(item)
                local distTxt = dist and string.format(" [%dm]", math.floor(dist)) or ""
                btn.Text = "🌟 " .. item.Name .. " (" .. mut .. ")" .. distTxt
                btn.LayoutOrder = math.floor(dist or 99999)
                local mc = mutationColor(mut)
                btn.TextColor3 = Theme.Dark
                local stroke = btn:FindFirstChildOfClass("UIStroke")
                if stroke then stroke.Color = mc end
            end
        end
    end

    for target, btn in pairs(targetButtons) do
        if not seen[target] then
            pcall(function() btn:Destroy() end)
            targetButtons[target] = nil
        end
    end

    if count == 0 then
        DropdownBtn.Text = "🔽 Targets (none in range)"
    else
        DropdownBtn.Text = "🔽 Targets (" .. count .. ")"
    end
    ScrollFrame.CanvasSize = UDim2.new(0, 0, 0, listLayout.AbsoluteContentSize.Y + 12)
end

-- debounced refresh (was: full rebuild on every spawn)
local refreshPending = false
local function requestRefresh()
    if refreshPending then return end
    refreshPending = true
    task.delay(0.5, function()
        refreshPending = false
        pcall(updateDynamicMenu)
    end)
end
brainrotsFolder.ChildAdded:Connect(requestRefresh)
brainrotsFolder.ChildRemoved:Connect(requestRefresh)

--------------------------------------------------------------------------------
-- FARM CYCLE (xpcall so loopIsActive always resets)
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- RUN BACK TO SAFE ZONE (standalone: used by farm cycle + manual button)
--------------------------------------------------------------------------------
runToSafeZone = function()
    -- clear any stale render binding from older versions
    pcall(function() RunService:UnbindFromRenderStep("SafeZoneReturnRun") end)
    local character = LocalPlayer.Character
    local rootPart = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    print("[BrainrotFarm] Run-back check - root:", rootPart ~= nil,
        "hp:", humanoid and math.floor(humanoid.Health) or -1)
    if not (rootPart and humanoid and humanoid.Health > 0) then
        print("[BrainrotFarm] Run-back skipped (no character or dead)")
        return false
    end
    local stepPerFrame = Config.RunSpeed / 60 -- studs per frame
    while true do
        local ch = LocalPlayer.Character
        local rp = ch and ch:FindFirstChild("HumanoidRootPart")
        local hm = ch and ch:FindFirstChildOfClass("Humanoid")
        if not rp or not hm or hm.Health <= 0 then
            print("[BrainrotFarm] Run-back stopped: character gone/dead")
            return false
        end
        local remaining = (rp.Position - Config.SafeZone).Magnitude
        if remaining <= 6 then
            print("[BrainrotFarm] Arrived at safe zone")
            return true -- ARRIVED, confirmed
        end
        local dir = (Config.SafeZone - rp.Position).Unit
        -- CFrame nudge: reliable movement even if velocity gets overridden
        rp.CFrame = rp.CFrame + Vector3.new(dir.X * stepPerFrame, 0, dir.Z * stepPerFrame)
        rp.CFrame = CFrame.lookAt(rp.Position,
            Vector3.new(Config.SafeZone.X, rp.Position.Y, Config.SafeZone.Z))
        task.wait() -- next frame; loops until arrival confirmed
    end
end

local function farmBody(selectedTarget)
    local character = LocalPlayer.Character
    local rootPart = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not rootPart or not humanoid then return end

    local targetPart = selectedTarget:FindFirstChild("Hitbox")
        or (selectedTarget:IsA("Model") and selectedTarget.PrimaryPart)
        or selectedTarget
    if not targetPart then return end
    local targetHumanoid = findHumanoid(selectedTarget)
    carryStarted = false
    currentTargetName = selectedTarget.Name

    setStatus("Targeting: " .. selectedTarget.Name)

    -- teleport to a safe distance, staying on our current side of the target
    -- (avoids landing inside walls/geometry behind the brainrot)
    local targetCFrame = selectedTarget:IsA("Model")
        and selectedTarget:GetPivot() or targetPart.CFrame
    local targetPos = targetCFrame.Position
    local awayDir = (rootPart.Position - targetPos)
    if awayDir.Magnitude < 1 then awayDir = Vector3.new(0, 0, 1) end
    awayDir = awayDir.Unit
    local destPos = targetPos + awayDir * Config.AttackDistance + Vector3.new(0, 3, 0)
    rootPart.CFrame = CFrame.lookAt(destPos, targetPos)
    print("[BrainrotFarm] Teleported to target")
    task.wait(0.05)
    ensureWeaponIsEquipped()
    task.wait(0.1)

    -- kill loop (toned down: 3 shots / 0.12s instead of 10 / 0.02s)
    -- retreats to safe zone if the brainrot is killing us
    local startTime = os.clock()
    local targetDied = false
    local retreated = false
    local exitReason = "unknown"
    local lastCatchTry = 0
    local maxHP = humanoid.MaxHealth
    while selectedTarget and selectedTarget.Parent do
        if carryStarted then
            targetDied = true
            exitReason = "carry started (server ack)"
            print("[BrainrotFarm] Carry started!")
            break
        end
        if targetHumanoid and targetHumanoid.Parent and targetHumanoid.Health <= 0 then
            targetDied = true
            exitReason = "target died (hp 0)"
            print("[BrainrotFarm] Target died")
            break
        end
        if os.clock() - startTime > Config.KillTimeout then
            exitReason = "timeout"
            warn("[BrainrotFarm] Target timed out, blacklisting: " .. selectedTarget.Name)
            blacklist[selectedTarget] = os.clock()
            failCount = failCount + 1
            break
        end
        character = LocalPlayer.Character
        humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if not humanoid or humanoid.Health <= 0 then
            exitReason = "player dead/gone"
            print("[BrainrotFarm] Kill loop exit: player dead/gone")
            break
        end
        if humanoid.Health < maxHP * Config.RetreatHealth then
            exitReason = "retreat (low hp)"
            warn("[BrainrotFarm] Low HP (" .. math.floor(humanoid.Health)
                .. "), retreating from " .. selectedTarget.Name)
            blacklist[selectedTarget] = os.clock()
            retreated = true
            break
        end
        rootPart = character:FindFirstChild("HumanoidRootPart")
        if not rootPart then
            exitReason = "no rootpart"
            print("[BrainrotFarm] Kill loop exit: no rootpart")
            break
        end
        local dist = (rootPart.Position - targetPart.Position).Magnitude
        for _ = 1, Config.ShotsPerVolley do
            FireWeapon(targetPart, dist)
        end
        -- periodically try the catch while the target is still valid:
        -- the moment it's down, the server accepts and acks -> carryStarted
        if (os.clock() - startTime) > 4 and (os.clock() - lastCatchTry) > 2 then
            lastCatchTry = os.clock()
            pcall(function() Remotes.Catching:FireServer(selectedTarget) end)
        end
        task.wait(Config.VolleyDelay)
    end
    if exitReason == "unknown" then
        -- loop exited because the target vanished from the workspace.
        -- if we were shooting it for a while, our shots almost certainly
        -- killed it (some brainrots have no detectable Humanoid) -> treat as kill.
        -- if it vanished instantly, it likely despawned on its own.
        if (os.clock() - startTime) > 3 then
            exitReason = "target removed after shooting (assume killed)"
        else
            exitReason = "target vanished instantly (despawn?)"
        end
    end
    print("[BrainrotFarm] Kill loop exit: " .. exitReason)
    local killed = targetDied or exitReason == "target removed after shooting (assume killed)"

    -- unequip
    character = LocalPlayer.Character
    if character then
        local tool = character:FindFirstChild(Config.WeaponName)
        local backpack = LocalPlayer:FindFirstChild("Backpack")
        if tool and backpack then tool.Parent = backpack end
    end

    if killed then
        -- fire catch to START the carry sequence (skip if server already acked)
        if not carryStarted then
            print("[BrainrotFarm] Firing catch...")
            pcall(function()
                Remotes.Catching:FireServer(selectedTarget)
            end)
        else
            print("[BrainrotFarm] Catch already confirmed by server")
        end
        killCount = killCount + 1
        setStatus("Carrying - running in 1s...")
        task.wait(1) -- let the carry sequence attach before running
    elseif retreated then
        setStatus("Retreated - healing...")
    end
    -- run-back starts right below

    -- return to safe zone (blocks until arrival is CONFIRMED)
    setStatus("Running to safe zone...")
    runToSafeZone()

    -- if we retreated hurt, wait for HP regen before the next cycle
    if retreated then
        local healStart = os.clock()
        while (os.clock() - healStart) < 20 do
            local ch = LocalPlayer.Character
            local hm = ch and ch:FindFirstChildOfClass("Humanoid")
            if not hm or hm.Health <= 0 then break end
            if hm.Health >= hm.MaxHealth * 0.9 then break end
            task.wait(0.5)
        end
        setStatus("Healed - resuming")
    end
end

function runFarmCycle(selectedTarget)
    if loopIsActive then return end
    if not selectedTarget or not selectedTarget.Parent then return end
    print("[BrainrotFarm] Cycle start: " .. tostring(selectedTarget.Name))
    loopIsActive = true
    local ok, err = xpcall(function() farmBody(selectedTarget) end,
        function(e) return debug.traceback(tostring(e)) end)
    if not ok then
        warn("[BrainrotFarm] Cycle error: " .. tostring(err))
        failCount = failCount + 1
    end
    loopIsActive = false
    if not autoFarmEnabled then
        setStatus("Idle")
    end
    pcall(updateDynamicMenu)
end

--------------------------------------------------------------------------------
-- AUTO-FARM LOOP (nearest mutated target)
--------------------------------------------------------------------------------
local function getNearestMutatedTarget()
    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    local rootPos = root.Position
    local best, bestDist = nil, Config.MaxDistance
    for _, item in ipairs(brainrotsFolder:GetChildren()) do
        if (item:IsA("BasePart") or item:IsA("Model"))
            and isMutated(item) and not isBlacklisted(item) then
            local pos = getTargetPosition(item)
            if pos then
                local d = (rootPos - pos).Magnitude
                if d < bestDist then
                    best, bestDist = item, d
                end
            end
        end
    end
    return best
end

task.spawn(function()
    while true do
        task.wait(1)
        if autoFarmEnabled and not loopIsActive then
            local target = getNearestMutatedTarget()
            if target then
                setStatus("Auto: " .. target.Name)
                runFarmCycle(target)
            else
                setStatus("Auto: waiting for targets")
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- INIT
--------------------------------------------------------------------------------
setStatus("Idle")
updateDynamicMenu()
print("[BrainrotFarm] v2.5 loaded - UI ready")
