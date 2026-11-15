-- ============================================================
-- LeaMode Ultra v13
-- bypass++ | step-smooth aimbot w/ proper silent-aim bone pick
-- ESP w/ camera-nil fallback | minimap w/ render-loss fallback
-- loot tracker: 100% client-local, no replication, local notify
-- car fly: hotkey bind + harder config | 6-tab menu
-- ============================================================

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage= game:GetService("ReplicatedStorage")
local Workspace        = game:GetService("Workspace")
local Lighting         = game:GetService("Lighting")
local TweenService     = game:GetService("TweenService")
local LocalPlayer      = Players.LocalPlayer
local Mouse            = LocalPlayer:GetMouse()

-- ===================== CONFIG =====================
local CFG = {
    flySpeed      = 100,
    walkBoost     = 70,
    jumpBoost     = 110,
    carFlySpeed   = 220,
    carFlyBoost   = 380,
    carFlyKey     = Enum.KeyCode.F6,   -- dedicated hotkey, independent of menu

    aimKey        = Enum.KeyCode.Q,
    aimFovPx      = 320,
    aimMaxDist    = 1e9,
    aimBone       = "Head",
    aimPredict    = 0.12,
    aimStepPx     = 18,

    mapSize       = 220,       -- bigger minimap
    mapRange      = 500,
    mapShowNames  = true,      -- show name labels on radar
    ownerHz       = 0.15,
    carSnap       = 22,   -- raised to match higher carFlySpeed/Boost, avoids rubber-band snap

    lootEnabled   = true,      -- loot tracker on/off
    lootRange     = 400,       -- studs – only show loot within this range
    lootMaxItems  = 60,        -- cap entries in loot panel
    lootBodyGlow  = true,      -- highlight dead bodies with loot
}

-- ===================== STATE =====================
local ON = {
    Speed=false, Fly=false, Noclip=false, InfJump=false,
    HighJump=false, NoFall=false, MobPush=false,
    ESP=false, Tracers=false, Fullbright=false, Minimap=true, ShowFov=true,
    Aimbot=false, SilentAim=false,
    AntiTP=true, Ownership=true, God=false, CarFly=false, Bypass=false,
    LootTracker=true,
}

local WHITELIST = {}

local S = {
    flyBV=nil, flyBG=nil, flyAtt=nil, flyConn=nil,
    carConn=nil, carBV=nil, carBG=nil, carAtt=nil, carModel=nil, carCF=nil,
    noclipConn=nil, ownerConn=nil, antiConn=nil, godConn=nil,
    espHL={}, tracerBeams={}, espFolder=nil, tracerFolder=nil, originAtt=nil,
    aimTarget=nil, lastCF=nil, lit={},
    gui=nil, fov=nil, map=nil, mapDots=nil, mapArrow=nil, status=nil,
    ownerT=0,
    -- loot tracker
    lootLog={},          -- [{killerName, victimName, items={}, ts, bodyModel}]
    lootBodyHL={},       -- bodyModel -> Highlight
    lootPanel=nil,       -- ScrollingFrame ref
    lootConn=nil,
}

local COL_E  = Color3.fromRGB(255, 60,  60)
local COL_F  = Color3.fromRGB(70,  255, 110)
local COL_ME = Color3.fromRGB(90,  170, 255)
local ACCENT = Color3.fromRGB(255, 145, 45)

local function char()  return LocalPlayer.Character end
local function hrp()   local c=char() return c and c:FindFirstChild("HumanoidRootPart") end
local function hum()   local c=char() return c and c:FindFirstChildOfClass("Humanoid") end
local function wl(p)   return WHITELIST[p.UserId] == true end
local function low(s)  return string.lower(tostring(s or "")) end

-- ===================== BYPASS =====================
local BLOCK = {
    "kick","ban","detect","anticheat","watchdog","antitamper","antiteleport",
    "teleportback","positioncheck","velocitycheck","speedcheck","flycheck",
    "noclipcheck","cheatdetect","securitycheck","clientcheck","integrity",
    "violation","punish","report","monitor","exploit","sandbox","cheatlog",
    "hacklog","hackcheck","hackdetect","abusereport","playerlog","movement_log",
    "abusecheck","speedlog","flagged","admincheck","adminlog","bancheck",
}
local ALLOW = {
    "move","stance","walk","jump","input","character","humanoid","replicate",
    "physics","network","cframe","position","velocity","vehicle","seat","drive",
    "car","chassis","engine","wheel","animation","emote","tool","equip",
}

local function blockRemote(name)
    local n = low(name)
    for _, a in ipairs(ALLOW) do if string.find(n, a, 1, true) then return false end end
    for _, b in ipairs(BLOCK) do if string.find(n, b, 1, true) then return true end end
    return false
end

local getBestTarget
local _hook = false
local function installHook()
    if _hook then return end
    _hook = true
    pcall(function()
        local mt = getrawmetatable and getrawmetatable(game)
        if not mt then return end
        local old = mt.__namecall
        setreadonly(mt, false)
        mt.__namecall = newcclosure(function(self, ...)
            -- guard: let the engine's own calls pass untouched
            if checkcaller and checkcaller() then return old(self, ...) end
            local method = getnamecallmethod and getnamecallmethod() or ""
            -- block self-kick
            if method == "Kick" and self == LocalPlayer then return end
            -- remote intercept
            if method == "FireServer" or method == "InvokeServer"
            or method == "Fire"       or method == "FireAllClients"
            or method == "FireClient" then
                local n = (self and rawget(self,"Name")) or (pcall(function() return self.Name end) and self.Name) or ""
                if blockRemote(n) then
                    if method == "InvokeServer" then return nil end
                    return
                end
                -- silent aim redirect
                if ON.SilentAim and getBestTarget then
                    local ln = low(n)
                    if string.find(ln,"gun")    or string.find(ln,"fire")
                    or string.find(ln,"shoot")  or string.find(ln,"hit")
                    or string.find(ln,"damage") or string.find(ln,"ray")
                    or string.find(ln,"bullet") or string.find(ln,"weapon")
                    or string.find(ln,"cast")   or string.find(ln,"proj")
                    or string.find(ln,"attack") or string.find(ln,"shot") then
                        local t = getBestTarget()
                        if t then
                            -- mirror the visual aimbot's aim-point math exactly:
                            -- head nudge + velocity-lead prediction, not raw bone pos
                            local aimPoint = t.Position
                            if t.Name == "Head" then
                                aimPoint = aimPoint + Vector3.new(0, 0.1, 0)
                            end
                            if CFG.aimPredict > 0 and t.Parent then
                                local tRoot = t.Parent:FindFirstChild("HumanoidRootPart") or t
                                local ok, vel = pcall(function() return tRoot.AssemblyLinearVelocity end)
                                if ok and vel then
                                    aimPoint = aimPoint + vel * CFG.aimPredict
                                end
                            end
                            local args = {...}
                            local r = hrp()
                            local origin = r and r.Position or aimPoint
                            for i,v in ipairs(args) do
                                if typeof(v)=="Vector3" then
                                    local mag = v.Magnitude>0.1 and v.Magnitude or 120
                                    args[i] = (aimPoint-origin).Unit * mag
                                elseif typeof(v)=="CFrame" then
                                    args[i] = CFrame.new(v.Position, aimPoint)
                                end
                            end
                            return old(self, table.unpack(args))
                        end
                    end
                end
            end
            if method == "InvokeServer" then
                local n = (self and rawget(self,"Name")) or ""
                if blockRemote(n) then return nil end
            end
            return old(self, ...)
        end)
        setreadonly(mt, true)
    end)
    -- secondary: hook __index on RemoteEvent/RemoteFunction to intercept :Connect
    pcall(function()
        local mt2 = getrawmetatable and getrawmetatable(Instance.new("RemoteEvent"))
        if not mt2 then return end
        local old2 = mt2.__index
        setreadonly(mt2, false)
        mt2.__index = newcclosure(function(self, key)
            if (key == "OnClientEvent" or key == "OnClientInvoke") then
                if blockRemote(self.Name) then
                    -- return a dummy signal that never fires
                    return { Connect = function() return { Disconnect=function()end } end,
                             Wait    = function() return end }
                end
            end
            return old2(self, key)
        end)
        setreadonly(mt2, true)
    end)
end

local function stripConns()
    if not getconnections then return end
    pcall(function()
        local h = hum()
        if not h then return end
        for _, sig in ipairs({
            h.HealthChanged, h.Died, h.StateChanged,
            h:GetPropertyChangedSignal("WalkSpeed"),
            h:GetPropertyChangedSignal("JumpPower"),
        }) do
            for _, c in ipairs(getconnections(sig)) do
                pcall(function()
                    if c.Disable then c:Disable() elseif c.Disconnect then c:Disconnect() end
                end)
            end
        end
    end)
    pcall(function()
        for _, obj in ipairs(Workspace:GetDescendants()) do
            if obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction") then
                if blockRemote(obj.Name) then
                    for _, c in ipairs(getconnections(obj.OnClientEvent or obj.OnClientInvoke)) do
                        pcall(function() if c.Disable then c:Disable() elseif c.Disconnect then c:Disconnect() end end)
                    end
                end
            end
        end
    end)
end

local function claim(root)
    if not root then return end
    for _, p in ipairs(root:GetDescendants()) do
        if p:IsA("BasePart") then pcall(function() p:SetNetworkOwner(LocalPlayer) end) end
    end
    if root:IsA("BasePart") then pcall(function() root:SetNetworkOwner(LocalPlayer) end) end
end

local function startBypass()
    installHook()
    stripConns()
    claim(char())
    ON.Bypass = true
    ON.Ownership = true
    ON.AntiTP = true
    if not S.ownerConn then
        S.ownerConn = RunService.Heartbeat:Connect(function()
            if not ON.Ownership then return end
            local now = os.clock()
            if now - S.ownerT < CFG.ownerHz then return end
            S.ownerT = now
            claim(char())
            if S.carModel then claim(S.carModel) end
        end)
    end
    if not S.antiConn then
        S.antiConn = RunService.Heartbeat:Connect(function()
            if not ON.AntiTP then return end
            local r = hrp()
            if not r then return end
            if ON.Fly or ON.CarFly then
                S.lastCF = r.CFrame
            elseif S.lastCF then
                if (r.Position - S.lastCF.Position).Magnitude > 16 then
                    r.CFrame = S.lastCF
                    r.AssemblyLinearVelocity = Vector3.zero
                else
                    S.lastCF = r.CFrame
                end
            else
                S.lastCF = r.CFrame
            end
        end)
    end
end

local function startGod()
    if S.godConn then S.godConn:Disconnect() end
    local h = hum()
    if not h then return end
    pcall(function() h.BreakJointsOnDeath = false end)
    S.godConn = h.HealthChanged:Connect(function(hp)
        if ON.God and hp < h.MaxHealth then pcall(function() h.Health = h.MaxHealth end) end
    end)
end

-- ===================== MOVEMENT =====================
local function applySpeed()
    local h = hum()
    if not h then return end
    h.WalkSpeed = ON.Speed and CFG.walkBoost or 16
    if ON.HighJump then
        h.JumpPower = CFG.jumpBoost
        pcall(function() h.JumpHeight = 24 end)
    else
        h.JumpPower = 50
    end
end

RunService.Stepped:Connect(function()
    if ON.Speed then
        local h = hum()
        if h then h.WalkSpeed = CFG.walkBoost end
    end
end)

local function flyStop()
    if S.flyConn then S.flyConn:Disconnect() S.flyConn=nil end
    pcall(function() if S.flyBV then S.flyBV:Destroy() end end)
    pcall(function() if S.flyBG then S.flyBG:Destroy() end end)
    pcall(function() if S.flyAtt then S.flyAtt:Destroy() end end)
    S.flyBV,S.flyBG,S.flyAtt=nil,nil,nil
    local h=hum(); if h and not ON.Fly then pcall(function() h.PlatformStand=false end) end
end

local function flyStart()
    if ON.CarFly or not ON.Fly then flyStop() return end
    local r,h = hrp(),hum()
    if not r or not h then return end
    pcall(function() h.PlatformStand=true end)
    if not S.flyAtt or S.flyAtt.Parent~=r then
        flyStop()
        local att=Instance.new("Attachment"); att.Name="LeaFlyAtt"; att.Parent=r; S.flyAtt=att
        local lv=Instance.new("LinearVelocity"); lv.Name="LeaFlyLV"; lv.Attachment0=att
        lv.MaxForce=1e9; lv.RelativeTo=Enum.ActuatorRelativeTo.World; lv.Parent=r; S.flyBV=lv
        local ao=Instance.new("AlignOrientation"); ao.Name="LeaFlyAO"; ao.Attachment0=att
        ao.Mode=Enum.OrientationAlignmentMode.OneAttachment; ao.MaxTorque=1e9; ao.Responsiveness=80; ao.Parent=r; S.flyBG=ao
    end
    if S.flyConn then return end
    S.flyConn = RunService.Heartbeat:Connect(function()
        if not ON.Fly or ON.CarFly then flyStop() return end
        local rr=hrp(); if not rr or not S.flyBV then return end
        local cam=Workspace.CurrentCamera; if not cam then return end
        local uis=UserInputService
        local v=Vector3.zero
        local f,rt=cam.CFrame.LookVector,cam.CFrame.RightVector
        if uis:IsKeyDown(Enum.KeyCode.W) then v+=f end
        if uis:IsKeyDown(Enum.KeyCode.S) then v-=f end
        if uis:IsKeyDown(Enum.KeyCode.A) then v-=rt end
        if uis:IsKeyDown(Enum.KeyCode.D) then v+=rt end
        if uis:IsKeyDown(Enum.KeyCode.Space) then v+=Vector3.yAxis end
        if uis:IsKeyDown(Enum.KeyCode.LeftShift) then v-=Vector3.yAxis end
        S.flyBV.VectorVelocity = v.Magnitude>0 and v.Unit*CFG.flySpeed or Vector3.zero
        if S.flyBG then S.flyBG.CFrame=cam.CFrame end
        S.lastCF = rr.CFrame
    end)
end

local function setNoclip(on)
    if S.noclipConn then S.noclipConn:Disconnect() S.noclipConn=nil end
    if not on then return end
    S.noclipConn = RunService.Stepped:Connect(function()
        local c=char(); if not c then return end
        for _,p in ipairs(c:GetDescendants()) do
            if p:IsA("BasePart") then p.CanCollide=false end
        end
    end)
end

UserInputService.JumpRequest:Connect(function()
    if ON.InfJump then local h=hum(); if h then h:ChangeState(Enum.HumanoidStateType.Jumping) end end
end)

-- ===================== CAR FLY v2 =====================
local function getVehicle()
    local h=hum(); if not h then return nil end
    local seat=h.SeatPart
    if seat and (seat:IsA("VehicleSeat") or seat:IsA("Seat")) then
        local m=seat:FindFirstAncestorOfClass("Model")
        return seat,m,(m and m.PrimaryPart) or seat
    end
    for _,o in ipairs(Workspace:GetDescendants()) do
        if (o:IsA("VehicleSeat") or o:IsA("Seat")) and o.Occupant==h then
            local m=o:FindFirstAncestorOfClass("Model")
            return o,m,(m and m.PrimaryPart) or o
        end
    end
end

local function carClean()
    pcall(function() if S.carBV then S.carBV:Destroy() end end)
    pcall(function() if S.carBG then S.carBG:Destroy() end end)
    pcall(function() if S.carAtt then S.carAtt:Destroy() end end)
    S.carBV,S.carBG,S.carAtt=nil,nil,nil
end

local function carNoclip(model, primary)
    local function strip(p)
        if p:IsA("BasePart") then
            p.CanCollide=false; p.CanTouch=false
            pcall(function() p.CanQuery=false end)
        end
    end
    if model then for _,p in ipairs(model:GetDescendants()) do strip(p) end
    elseif primary then strip(primary) end
    local c=char(); if c then for _,p in ipairs(c:GetDescendants()) do strip(p) end end
end

local function carAttach(primary)
    if not primary then return end
    if S.carAtt and S.carAtt.Parent~=primary then carClean() end
    if S.carAtt and S.carAtt.Parent==primary then return end
    local att=Instance.new("Attachment"); att.Name="LeaCarAtt"; att.Parent=primary; S.carAtt=att
    local lv=Instance.new("LinearVelocity"); lv.Name="LeaCarLV"; lv.Attachment0=att
    lv.MaxForce=1e10; lv.RelativeTo=Enum.ActuatorRelativeTo.World; lv.Parent=primary; S.carBV=lv
    local ao=Instance.new("AlignOrientation"); ao.Name="LeaCarAO"; ao.Attachment0=att
    ao.Mode=Enum.OrientationAlignmentMode.OneAttachment; ao.MaxTorque=1e10; ao.Responsiveness=55; ao.Parent=primary; S.carBG=ao
end

local function carStop()
    if S.carConn then S.carConn:Disconnect() S.carConn=nil end
    carClean(); S.carModel=nil; S.carCF=nil; ON.CarFly=false
end

local function carStart()
    if not ON.Bypass then startBypass() end
    ON.CarFly=true
    if S.carConn then return end
    S.carConn = RunService.Heartbeat:Connect(function()
        if not ON.CarFly then carStop() return end
        local seat,model,primary = getVehicle()
        if not seat or not primary then
            if S.carBV then carClean(); S.carModel=nil; S.carCF=nil end
            return
        end
        local h=hum()
        if h and seat:IsA("VehicleSeat") and seat.Occupant~=h then pcall(function() seat:Sit(h) end) end
        if S.carModel~=model then
            S.carModel=model; S.carCF=nil; carClean()
            claim(model or primary); carNoclip(model,primary); carAttach(primary)
        end
        carNoclip(model,primary)
        claim(model or primary)
        if seat:IsA("VehicleSeat") then
            pcall(function() seat.Torque=0; seat.TurnSpeed=0; seat.MaxSpeed=0 end)
        end
        if not S.carBV or S.carBV.Parent~=primary then carAttach(primary) end
        if not S.carBV then return end
        pcall(function() primary.AssemblyAngularVelocity=Vector3.zero end)
        local cam=Workspace.CurrentCamera; if not cam then return end
        local uis=UserInputService
        local look=cam.CFrame.LookVector; local rght=cam.CFrame.RightVector
        local fwd=Vector3.new(look.X,0,look.Z); fwd=fwd.Magnitude>0.05 and fwd.Unit or Vector3.new(0,0,-1)
        local lat=Vector3.new(rght.X,0,rght.Z); lat=lat.Magnitude>0.05 and lat.Unit or Vector3.new(1,0,0)
        local v=Vector3.zero
        if uis:IsKeyDown(Enum.KeyCode.W)         then v=v+Vector3.yAxis end
        if uis:IsKeyDown(Enum.KeyCode.S)         then v=v-Vector3.yAxis end
        if uis:IsKeyDown(Enum.KeyCode.A)         then v=v-lat end
        if uis:IsKeyDown(Enum.KeyCode.D)         then v=v+lat end
        if uis:IsKeyDown(Enum.KeyCode.Space)     then v=v+fwd end
        if uis:IsKeyDown(Enum.KeyCode.LeftControl) then v=v-fwd end
        local spd=uis:IsKeyDown(Enum.KeyCode.LeftShift) and CFG.carFlyBoost or CFG.carFlySpeed
        if v.Magnitude>0.05 then
            S.carBV.VectorVelocity=v.Unit*spd; S.carCF=primary.CFrame
        else
            S.carBV.VectorVelocity=Vector3.zero
            if not S.carCF then S.carCF=primary.CFrame end
        end
        if S.carBG then S.carBG.CFrame=CFrame.lookAt(primary.Position, primary.Position+fwd) end
        if S.carCF then
            local drift=(primary.Position-S.carCF.Position).Magnitude
            local spd2=primary.AssemblyLinearVelocity.Magnitude
            if drift>CFG.carSnap and spd2<10 then
                primary.CFrame=S.carCF
                primary.AssemblyLinearVelocity=Vector3.zero
                claim(model or primary)
            elseif v.Magnitude>0.05 then
                S.carCF=primary.CFrame
            end
        end
        local r=hrp()
        if r and (r.Position-primary.Position).Magnitude>12 then
            pcall(function() r.CFrame=primary.CFrame*CFrame.new(0,2,0); r.AssemblyLinearVelocity=Vector3.zero end)
        end
    end)
end

-- ===================== AIMBOT — step smooth =====================
getBestTarget = function()
    local cam = Workspace.CurrentCamera
    if not cam then return nil end
    local vp = cam.ViewportSize
    local cx, cy = vp.X*0.5, vp.Y*0.5
    local best, bestPx = nil, CFG.aimFovPx
    local myPos = (hrp() and hrp().Position) or cam.CFrame.Position

    if S.aimTarget and S.aimTarget.Parent then
        local plr = Players:GetPlayerFromCharacter(S.aimTarget.Parent)
        if plr and not wl(plr) then
            local h = S.aimTarget.Parent:FindFirstChildOfClass("Humanoid")
            if h and h.Health>0 then
                local sp, on = cam:WorldToViewportPoint(S.aimTarget.Position)
                if on and sp.Z>0 then
                    local px = (Vector2.new(sp.X,sp.Y)-Vector2.new(cx,cy)).Magnitude
                    if px < CFG.aimFovPx*1.5 then return S.aimTarget end
                end
            end
        end
        S.aimTarget = nil
    end

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr~=LocalPlayer and plr.Character and not wl(plr) then
            local h = plr.Character:FindFirstChildOfClass("Humanoid")
            local bone = plr.Character:FindFirstChild(CFG.aimBone)
                      or plr.Character:FindFirstChild("HumanoidRootPart")
            if h and bone and h.Health>0 then
                if (bone.Position-myPos).Magnitude <= CFG.aimMaxDist then
                    local sp, on = cam:WorldToViewportPoint(bone.Position)
                    if on and sp.Z>0 then
                        local px = (Vector2.new(sp.X,sp.Y)-Vector2.new(cx,cy)).Magnitude
                        if px < bestPx then
                            bestPx = px
                            best = bone
                        end
                    end
                end
            end
        end
    end
    S.aimTarget = best
    return best
end

RunService.RenderStepped:Connect(function()
    if not ON.Aimbot then S.aimTarget=nil return end
    if not UserInputService:IsKeyDown(CFG.aimKey) then return end
    local cam = Workspace.CurrentCamera
    if not cam then return end
    local target = getBestTarget()
    if not target then return end

    local aim = target.Position
    if target.Name=="Head" then aim = aim + Vector3.new(0,0.1,0) end
    if CFG.aimPredict>0 and target.Parent then
        local root = target.Parent:FindFirstChild("HumanoidRootPart") or target
        aim = aim + root.AssemblyLinearVelocity * CFG.aimPredict
    end

    local vp = cam.ViewportSize
    local cx, cy = vp.X*0.5, vp.Y*0.5
    local sp = cam:WorldToViewportPoint(aim)
    local screenPos = Vector2.new(sp.X, sp.Y)
    local center = Vector2.new(cx, cy)
    local delta = screenPos - center
    local dist = delta.Magnitude
    if dist < 0.5 then return end
    local step = math.min(dist, CFG.aimStepPx)
    local newScreen = center + delta.Unit * (dist - step)
    local depth = sp.Z
    if depth <= 0 then return end
    local ray = cam:ViewportPointToRay(newScreen.X, newScreen.Y)
    local newWorld = ray.Origin + ray.Direction * depth
    local goal = CFrame.new(cam.CFrame.Position, newWorld)
    cam.CFrame = goal
end)

-- ===================== ESP =====================
-- BillboardGui per player: name + distance, always visible regardless of frustum
local function makeInfoBB(plr)
    if not plr.Character then return end
    local root = plr.Character:FindFirstChild("HumanoidRootPart")
    if not root then return end
    local friend = wl(plr)
    local col = friend and COL_F or COL_E

    local old = root:FindFirstChild("LeaBB")
    if old then old:Destroy() end

    local bb = Instance.new("BillboardGui")
    bb.Name = "LeaBB"
    bb.Size = UDim2.fromOffset(80, 32)
    bb.StudsOffset = Vector3.new(0, 3.2, 0)
    bb.AlwaysOnTop = true
    bb.ResetOnSpawn = false
    bb.Parent = root

    local nameLbl = Instance.new("TextLabel", bb)
    nameLbl.Size = UDim2.new(1,0,0.6,0)
    nameLbl.BackgroundTransparency = 1
    nameLbl.Text = plr.Name
    nameLbl.Font = Enum.Font.GothamBold
    nameLbl.TextSize = 11
    nameLbl.TextColor3 = col
    nameLbl.TextStrokeTransparency = 0.3
    nameLbl.TextXAlignment = Enum.TextXAlignment.Center

    local distLbl = Instance.new("TextLabel", bb)
    distLbl.Name = "Dist"
    distLbl.Size = UDim2.new(1,0,0.4,0)
    distLbl.Position = UDim2.fromScale(0,0.6)
    distLbl.BackgroundTransparency = 1
    distLbl.Text = "? m"
    distLbl.Font = Enum.Font.Gotham
    distLbl.TextSize = 9
    distLbl.TextColor3 = Color3.fromRGB(200,200,200)
    distLbl.TextStrokeTransparency = 0.3
    distLbl.TextXAlignment = Enum.TextXAlignment.Center
end

local function makeHL(plr)
    if not plr.Character then return end
    local old = S.espHL[plr]
    if old and old.Parent then old:Destroy() end
    S.espHL[plr] = nil
    local friend = wl(plr)
    local col = friend and COL_F or COL_E
    local hl = Instance.new("Highlight")
    hl.Name = "LeaHL"
    hl.FillColor = col
    hl.OutlineColor = col
    hl.FillTransparency = 0.55
    hl.OutlineTransparency = 0
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop   -- visible through walls
    local ok = pcall(function()
        hl.Adornee = plr.Character
        hl.Parent = game:GetService("CoreGui")
    end)
    if not ok or not hl.Parent then
        hl.Adornee = nil
        hl.Parent = plr.Character
    end
    S.espHL[plr] = hl
    if ON.ESP then makeInfoBB(plr) end
end

local function makeTracer(plr)
    local my = hrp()
    if not my or not plr.Character then return end
    if not S.tracerFolder or not S.tracerFolder.Parent then
        local tf = Instance.new("Folder"); tf.Name="LeaTr"; tf.Parent=Workspace; S.tracerFolder=tf
    end
    if not S.originAtt or S.originAtt.Parent~=my then
        if S.originAtt then pcall(function() S.originAtt:Destroy() end) end
        local oa = Instance.new("Attachment"); oa.Name="LeaTO"; oa.Parent=my; S.originAtt=oa
    end
    local old = S.tracerBeams[plr]
    if old and old.Parent then old:Destroy() end
    S.tracerBeams[plr] = nil
    local bone = plr.Character:FindFirstChild("Head") or plr.Character:FindFirstChild("HumanoidRootPart")
    if not bone then return end
    local a1 = bone:FindFirstChild("LeaTE") or Instance.new("Attachment")
    a1.Name="LeaTE"; a1.Parent=bone
    local friend = wl(plr)
    local col = friend and COL_F or COL_E
    local beam = Instance.new("Beam")
    beam.Attachment0 = S.originAtt; beam.Attachment1 = a1
    beam.Width0=0.09; beam.Width1=0.09; beam.FaceCamera=true
    beam.Color=ColorSequence.new(col)
    beam.Transparency=NumberSequence.new(0.2)
    beam.LightEmission=1; beam.Parent=S.tracerFolder
    S.tracerBeams[plr] = beam
end

local function clearESP()
    for plr, hl in pairs(S.espHL) do
        pcall(function() if hl and hl.Parent then hl:Destroy() end end)
    end
    S.espHL = {}
    for plr, beam in pairs(S.tracerBeams) do
        pcall(function() if beam and beam.Parent then beam:Destroy() end end)
    end
    S.tracerBeams = {}
    if S.tracerFolder then pcall(function() S.tracerFolder:Destroy() end) end
    S.tracerFolder = nil
    if S.originAtt then pcall(function() S.originAtt:Destroy() end) end
    S.originAtt = nil
    -- remove BillboardGuis
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr.Character then
            local root = plr.Character:FindFirstChild("HumanoidRootPart")
            if root then
                local bb = root:FindFirstChild("LeaBB")
                if bb then pcall(function() bb:Destroy() end) end
            end
        end
    end
end

local function doESP()
    if not (ON.ESP or ON.Tracers) then clearESP() return end
    local myPos = hrp() and hrp().Position
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and plr.Character then
            local h = plr.Character:FindFirstChildOfClass("Humanoid")
            if h and h.Health > 0 then
                if ON.ESP then
                    local hl = S.espHL[plr]
                    if not hl or not hl.Parent then makeHL(plr) end
                    -- update distance label
                    local root = plr.Character:FindFirstChild("HumanoidRootPart")
                    if root and myPos then
                        local bb = root:FindFirstChild("LeaBB")
                        if not bb then makeInfoBB(plr) bb = root:FindFirstChild("LeaBB") end
                        if bb then
                            local dl = bb:FindFirstChild("Dist")
                            if dl then
                                local dist = math.floor((root.Position - myPos).Magnitude)
                                dl.Text = dist .. " m"
                                -- color-code distance
                                if dist < 50 then dl.TextColor3 = COL_E
                                elseif dist < 150 then dl.TextColor3 = Color3.fromRGB(255,200,60)
                                else dl.TextColor3 = Color3.fromRGB(180,180,180) end
                            end
                        end
                    end
                end
                if ON.Tracers then
                    local beam = S.tracerBeams[plr]
                    if not beam or not beam.Parent then makeTracer(plr) end
                end
            else
                -- dead: remove ESP
                local hl = S.espHL[plr]
                if hl and hl.Parent then hl:Destroy() end
                S.espHL[plr] = nil
                local beam = S.tracerBeams[plr]
                if beam and beam.Parent then beam:Destroy() end
                S.tracerBeams[plr] = nil
                -- remove billboard
                if plr.Character then
                    local root = plr.Character:FindFirstChild("HumanoidRootPart")
                    if root then local bb=root:FindFirstChild("LeaBB") if bb then pcall(function()bb:Destroy()end) end end
                end
            end
        end
    end
    for plr, hl in pairs(S.espHL) do
        if not plr.Parent then
            pcall(function() if hl and hl.Parent then hl:Destroy() end end)
            S.espHL[plr] = nil
        end
    end
    for plr, beam in pairs(S.tracerBeams) do
        if not plr.Parent then
            pcall(function() if beam and beam.Parent then beam:Destroy() end end)
            S.tracerBeams[plr] = nil
        end
    end
end

Players.PlayerAdded:Connect(function(plr)
    plr.CharacterAdded:Connect(function()
        task.wait(0.3)
        if ON.ESP or ON.Tracers then doESP() end
    end)
end)
for _, plr in ipairs(Players:GetPlayers()) do
    if plr ~= LocalPlayer then
        plr.CharacterAdded:Connect(function()
            task.wait(0.3)
            if ON.ESP or ON.Tracers then doESP() end
        end)
    end
end

local function fullbright(on)
    if on then
        S.lit.b,S.lit.c,S.lit.f=Lighting.Brightness,Lighting.ClockTime,Lighting.FogEnd
        Lighting.Brightness=3.2; Lighting.ClockTime=14; Lighting.FogEnd=1e6; Lighting.GlobalShadows=false
    else
        if S.lit.b then Lighting.Brightness=S.lit.b end
        if S.lit.c then Lighting.ClockTime=S.lit.c end
        if S.lit.f then Lighting.FogEnd=S.lit.f end
        Lighting.GlobalShadows=true; S.lit={}
    end
end

-- ===================== MINIMAP =====================
local function buildMap(parent)
    if S.map then S.map:Destroy() end
    local size=CFG.mapSize
    local frame=Instance.new("Frame")
    frame.Name="Radar"
    frame.Size=UDim2.fromOffset(size,size)
    frame.Position=UDim2.new(1,-size-12,0,12)
    frame.BackgroundColor3=Color3.fromRGB(8,8,10)
    frame.BackgroundTransparency=0.15
    frame.BorderSizePixel=0
    frame.ZIndex=90
    frame.Parent=parent
    Instance.new("UICorner",frame).CornerRadius=UDim.new(0,size/2)
    local stroke=Instance.new("UIStroke",frame)
    stroke.Color=ACCENT; stroke.Thickness=1.8; stroke.Transparency=0.2

    -- crosshair lines
    local hline=Instance.new("Frame")
    hline.Size=UDim2.new(1,0,0,1); hline.Position=UDim2.new(0,0,0.5,0)
    hline.BackgroundColor3=Color3.fromRGB(50,50,62); hline.BackgroundTransparency=0.4
    hline.BorderSizePixel=0; hline.ZIndex=91; hline.Parent=frame
    local vline=Instance.new("Frame")
    vline.Size=UDim2.new(0,1,1,0); vline.Position=UDim2.new(0.5,0,0,0)
    vline.BackgroundColor3=Color3.fromRGB(50,50,62); vline.BackgroundTransparency=0.4
    vline.BorderSizePixel=0; vline.ZIndex=91; vline.Parent=frame

    -- range rings (25% and 60% of radius)
    for _, frac in ipairs({0.5, 1.0}) do
        local ring=Instance.new("Frame")
        local rs = size * frac
        ring.Size=UDim2.fromOffset(rs, rs)
        ring.AnchorPoint=Vector2.new(0.5,0.5)
        ring.Position=UDim2.fromScale(0.5,0.5)
        ring.BackgroundTransparency=1
        ring.BorderSizePixel=0
        ring.ZIndex=91
        ring.Parent=frame
        Instance.new("UICorner",ring).CornerRadius=UDim.new(1,0)
        local rs2=Instance.new("UIStroke",ring)
        rs2.Color=Color3.fromRGB(50,50,62); rs2.Thickness=0.8; rs2.Transparency=0.55
    end

    -- my dot
    local me=Instance.new("Frame")
    me.Size=UDim2.fromOffset(8,8); me.AnchorPoint=Vector2.new(0.5,0.5)
    me.Position=UDim2.fromScale(0.5,0.5); me.BackgroundColor3=COL_ME
    me.BorderSizePixel=0; me.ZIndex=94; me.Parent=frame
    Instance.new("UICorner",me).CornerRadius=UDim.new(1,0)

    -- direction arrow (rotates with camera via UpdateMap)
    local arrow=Instance.new("Frame")
    arrow.Size=UDim2.fromOffset(4,10); arrow.AnchorPoint=Vector2.new(0.5,1)
    arrow.Position=UDim2.new(0.5,0,0.5,-5)
    arrow.BackgroundColor3=ACCENT; arrow.BorderSizePixel=0; arrow.ZIndex=95; arrow.Parent=frame
    Instance.new("UICorner",arrow).CornerRadius=UDim.new(0,2)
    S.mapArrow=arrow

    local dots=Instance.new("Folder"); dots.Name="Dots"; dots.Parent=frame

    -- "RADAR" bottom label
    local label=Instance.new("TextLabel")
    label.Size=UDim2.new(1,0,0,13); label.Position=UDim2.new(0,0,1,-14)
    label.BackgroundTransparency=1
    label.Text="RADAR  "..tostring(math.floor(CFG.mapRange)).."m"
    label.Font=Enum.Font.GothamBold; label.TextSize=8
    label.TextColor3=ACCENT; label.ZIndex=92; label.Parent=frame

    S.map=frame; S.mapDots=dots
end

local function updateMap()
    if not ON.Minimap or not S.map or not S.mapDots then
        if S.map then S.map.Visible=false end
        return
    end
    S.map.Visible=true
    local my=hrp()
    local myPos
    if my then
        myPos = my.Position
        S.lastMapPos = myPos          -- cache for respawn gap
    elseif S.lastMapPos then
        myPos = S.lastMapPos          -- keep rendering enemy dots using last known self-pos
    else
        return                       -- truly nothing to go on yet (first spawn)
    end
    local range=CFG.mapRange
    local half=CFG.mapSize*0.5

    -- camera can be nil during death screen / respawn transitions — never blank the map for it
    local cam = Workspace.CurrentCamera
    if not cam then
        cam = Workspace:FindFirstChildOfClass("Camera")
    end
    local camYaw
    if cam then
        camYaw = math.atan2(-cam.CFrame.LookVector.X, -cam.CFrame.LookVector.Z)
    else
        camYaw = 0  -- fixed north-up orientation, dots still render
    end
    local cosY, sinY = math.cos(camYaw), math.sin(camYaw)
    if S.mapArrow then
        S.mapArrow.Visible = cam ~= nil  -- hide heading arrow only, dots stay live
    end

    for _,d in ipairs(S.mapDots:GetChildren()) do d:Destroy() end

    for _,plr in ipairs(Players:GetPlayers()) do
        if plr~=LocalPlayer and plr.Character then
            local root=plr.Character:FindFirstChild("HumanoidRootPart")
            local h=plr.Character:FindFirstChildOfClass("Humanoid")
            -- show ALIVE enemies — no frustum check, pure world position
            if root and h and h.Health>0 then
                local dlt=root.Position-myPos
                local rx =  dlt.X*cosY + dlt.Z*sinY
                local rz = -dlt.X*sinY + dlt.Z*cosY
                local inRange = (dlt.X^2+dlt.Z^2) <= (range*range)
                local dx=math.clamp(rx/range*half, -half+7, half-7)
                local dz=math.clamp(rz/range*half, -half+7, half-7)
                local col = wl(plr) and COL_F or COL_E
                -- dot size: bigger when close
                local dist2d = math.sqrt(dlt.X^2+dlt.Z^2)
                local dotSz  = dist2d < 50 and 10 or (dist2d < 150 and 8 or 6)

                local dot=Instance.new("Frame")
                dot.Size=UDim2.fromOffset(dotSz,dotSz)
                dot.AnchorPoint=Vector2.new(0.5,0.5)
                dot.Position=UDim2.new(0.5,dx,0.5,dz)
                dot.BackgroundColor3=col
                -- flash red if outside range (clamped to edge)
                if not inRange then dot.BackgroundColor3=Color3.fromRGB(220,80,80) end
                dot.BorderSizePixel=0; dot.ZIndex=93; dot.Parent=S.mapDots
                Instance.new("UICorner",dot).CornerRadius=UDim.new(1,0)

                -- name label above dot
                if CFG.mapShowNames then
                    local nl=Instance.new("TextLabel")
                    nl.Size=UDim2.fromOffset(60,10)
                    nl.AnchorPoint=Vector2.new(0.5,1)
                    nl.Position=UDim2.new(0.5,dx,0.5,dz-dotSz/2-1)
                    nl.BackgroundTransparency=1
                    nl.Text=plr.Name
                    nl.Font=Enum.Font.GothamBold
                    nl.TextSize=8
                    nl.TextColor3=col
                    nl.TextStrokeTransparency=0.1
                    nl.ZIndex=94
                    nl.Parent=S.mapDots
                end
            end
        end
    end
end

local function updateFov()
    if not S.fov then return end
    if ON.Aimbot and ON.ShowFov then
        S.fov.Visible=true
        local d=CFG.aimFovPx*2
        S.fov.Size=UDim2.fromOffset(d,d)
    else
        S.fov.Visible=false
    end
end

-- ===================== LOOT TRACKER =====================
-- Watches for Humanoid.Died on every player character.
-- When a player dies we snapshot their character's Tool/accessory inventory
-- and any Part/Model descendants that look like pickup drops.
-- Results show in a dedicated LOOT tab (live panel + minimap loot dots).

local COL_LOOT = Color3.fromRGB(255, 215, 60)   -- gold

local function guessLootItems(character)
    local items = {}
    -- 1. Tools the player was holding / in their Backpack
    local plr = Players:GetPlayerFromCharacter(character)
    if plr then
        local bp = plr:FindFirstChildOfClass("Backpack")
        if bp then
            for _, t in ipairs(bp:GetChildren()) do
                if t:IsA("Tool") then table.insert(items, "🔧 "..t.Name) end
            end
        end
        local char2 = plr.Character
        if char2 then
            for _, t in ipairs(char2:GetChildren()) do
                if t:IsA("Tool") then table.insert(items, "🔫 "..t.Name.." (equipped)") end
            end
        end
    end
    -- 2. Any child named like common loot patterns
    local lootKeywords = {"gun","weapon","rifle","pistol","smg","ammo","cash","money",
                          "medkit","heal","armor","vest","helmet","grenade","knife",
                          "sword","axe","shield","potion","key","item","loot","drop",
                          "backpack","bag","crate","chest"}
    for _, obj in ipairs(character:GetDescendants()) do
        local n = low(obj.Name)
        for _, kw in ipairs(lootKeywords) do
            if string.find(n, kw, 1, true) then
                table.insert(items, "📦 "..obj.Name)
                break
            end
        end
    end
    if #items == 0 then table.insert(items, "(no items detected)") end
    return items
end

-- Client-local only: lives in CoreGui, never parented under Workspace/the body,
-- so nothing here ever replicates server-side or becomes visible to other clients.
local function highlightBody(character)
    if not CFG.lootBodyGlow then return end
    local hl = Instance.new("Highlight")
    hl.Name = "LeaLootHL"
    hl.FillColor = COL_LOOT
    hl.OutlineColor = COL_LOOT
    hl.FillTransparency = 0.65
    hl.OutlineTransparency = 0
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Adornee = character
    local ok = pcall(function()
        hl.Parent = game:GetService("CoreGui")  -- CoreGui is always client-local, never replicated
    end)
    if not ok or not hl.Parent then
        -- CoreGui blocked in this exploit env — do NOT fall back to parenting
        -- under the character/Workspace, that path can be server-visible.
        -- Drop the visual highlight silently; loot panel entry still stands.
        pcall(function() hl:Destroy() end)
        return
    end
    S.lootBodyHL[character] = hl
    task.delay(60, function()
        pcall(function() if hl and hl.Parent then hl:Destroy() end end)
        S.lootBodyHL[character] = nil
    end)
end

local function refreshLootPanel()
    if not S.lootPanel or not S.lootPanel.Parent then return end
    for _, c in ipairs(S.lootPanel:GetChildren()) do
        if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
    end
    local my = hrp()
    local myPos = my and my.Position
    local shown = 0
    -- newest first
    for i = #S.lootLog, 1, -1 do
        if shown >= CFG.lootMaxItems then break end
        local entry = S.lootLog[i]
        -- distance filter
        local dist = 9999
        if myPos and entry.bodyPos then
            dist = math.floor((entry.bodyPos - myPos).Magnitude)
        end
        if dist > CFG.lootRange then continue end
        shown += 1

        local card = Instance.new("Frame")
        card.Size = UDim2.new(1, -4, 0, 0)  -- height set after contents
        card.AutomaticSize = Enum.AutomaticSize.Y
        card.BackgroundColor3 = Color3.fromRGB(18, 16, 10)
        card.BorderSizePixel = 0
        card.LayoutOrder = shown
        card.ZIndex = 52
        card.Parent = S.lootPanel
        Instance.new("UICorner", card).CornerRadius = UDim.new(0, 4)
        local cStroke = Instance.new("UIStroke", card)
        cStroke.Color = COL_LOOT; cStroke.Thickness = 0.8; cStroke.Transparency = 0.6
        local cLay = Instance.new("UIListLayout", card)
        cLay.Padding = UDim.new(0, 1)
        local cPad = Instance.new("UIPadding", card)
        cPad.PaddingLeft=UDim.new(0,6); cPad.PaddingRight=UDim.new(0,6)
        cPad.PaddingTop=UDim.new(0,4); cPad.PaddingBottom=UDim.new(0,4)

        -- header: victim name + distance
        local header = Instance.new("TextLabel", card)
        header.Size = UDim2.new(1,0,0,14)
        header.AutomaticSize = Enum.AutomaticSize.Y
        header.BackgroundTransparency = 1
        header.Text = "☠ "..entry.victimName.."  |  "..dist.."m  |  "..entry.killerName.." killed"
        header.Font = Enum.Font.GothamBold
        header.TextSize = 10
        header.TextColor3 = COL_LOOT
        header.TextXAlignment = Enum.TextXAlignment.Left
        header.TextWrapped = true
        header.ZIndex = 53

        -- items
        for _, item in ipairs(entry.items) do
            local il = Instance.new("TextLabel", card)
            il.Size = UDim2.new(1,0,0,12)
            il.AutomaticSize = Enum.AutomaticSize.Y
            il.BackgroundTransparency = 1
            il.Text = "  "..item
            il.Font = Enum.Font.Gotham
            il.TextSize = 9
            il.TextColor3 = Color3.fromRGB(210,200,170)
            il.TextXAlignment = Enum.TextXAlignment.Left
            il.TextWrapped = true
            il.ZIndex = 53
        end
    end
    if shown == 0 then
        local empty = Instance.new("TextLabel", S.lootPanel)
        empty.Size = UDim2.new(1,0,0,30)
        empty.BackgroundTransparency = 1
        empty.Text = "no loot in range"
        empty.Font = Enum.Font.Gotham
        empty.TextSize = 10
        empty.TextColor3 = Color3.fromRGB(90,90,100)
        empty.TextXAlignment = Enum.TextXAlignment.Center
        empty.ZIndex = 52
    end
end

local function watchPlayer(plr)
    local function onChar(character)
        local hum = character:WaitForChild("Humanoid", 10)
        if not hum then return end
        hum.Died:Connect(function()
            task.wait(0.3)  -- let drops spawn
            if not ON.LootTracker then return end
            local killerName = "unknown"
            -- try to identify killer via humanoid tag
            pcall(function()
                local tag = hum:FindFirstChild("creator")
                if tag and tag:IsA("ObjectValue") and tag.Value then
                    killerName = tag.Value.Name
                end
            end)
            local items = guessLootItems(character)
            local bodyPos
            pcall(function()
                local root = character:FindFirstChild("HumanoidRootPart")
                bodyPos = root and root.Position
            end)
            local entry = {
                victimName = plr.Name,
                killerName = killerName,
                items      = items,
                bodyPos    = bodyPos,
                ts         = os.clock(),
                bodyModel  = character,
            }
            table.insert(S.lootLog, entry)
            -- cap log
            while #S.lootLog > CFG.lootMaxItems do table.remove(S.lootLog, 1) end
            highlightBody(character)
            pcall(refreshLootPanel)
            pcall(say, "☠ "..plr.Name.." died — "..#items.." items")
            -- local-only system notification (StarterGui:SetCore is client-side, never replicates)
            pcall(function()
                game:GetService("StarterGui"):SetCore("SendNotification", {
                    Title = "Loot",
                    Text  = plr.Name.." dropped "..#items.." item(s)",
                    Duration = 4,
                })
            end)
        end)
    end
    if plr.Character then task.spawn(onChar, plr.Character) end
    plr.CharacterAdded:Connect(onChar)
end

local function startLootTracker()
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then watchPlayer(plr) end
    end
    Players.PlayerAdded:Connect(function(plr)
        if plr ~= LocalPlayer then watchPlayer(plr) end
    end)
end

-- loot dot refresh on minimap is handled in updateMap below
local _lootRefT = 0
-- ===================== LOOPS =====================
local _espT,_mapT,_lootT=0,0,0
RunService.Heartbeat:Connect(function(dt)
    _espT+=dt; _mapT+=dt; _lootT+=dt
    if _espT>=0.3  then _espT=0;  if ON.ESP or ON.Tracers then pcall(doESP) end end
    if _mapT>=0.08 then _mapT=0;  pcall(updateMap); pcall(updateFov) end
    if _lootT>=1.0 then _lootT=0; if ON.LootTracker then pcall(refreshLootPanel) end end
    if ON.NoFall then
        local h=hum()
        if h and h:GetState()==Enum.HumanoidStateType.Freefall then
            h:ChangeState(Enum.HumanoidStateType.GettingUp)
        end
    end
    if ON.MobPush then
        local r=hrp(); if r then
            for _,m in ipairs(Workspace:GetChildren()) do
                if m:IsA("Model") and m~=char() and not Players:GetPlayerFromCharacter(m) then
                    local mh=m:FindFirstChildOfClass("Humanoid")
                    local mr=m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart
                    if mh and mr and mh.Health>0 then
                        local d=(mr.Position-r.Position).Magnitude
                        if d>0.4 and d<=16 then
                            local away=r.Position-mr.Position
                            if away.Magnitude>0 then
                                r.AssemblyLinearVelocity=away.Unit*90+Vector3.new(0,40,0)
                            end
                        end
                    end
                end
            end
        end
    end
end)

LocalPlayer.CharacterAdded:Connect(function()
    task.wait(0.4)
    claim(char()); stripConns()
    flyStop(); carStop()
    if ON.Fly then flyStart() end
    if ON.CarFly then carStart() end
    if ON.Speed then applySpeed() end
    if ON.Noclip then setNoclip(true) end
    if ON.ESP or ON.Tracers then doESP() end
    if ON.God then startGod() end
    S.aimTarget=nil; S.lastCF=nil
end)

-- ===================== UI — FLAT RECTANGULAR =====================
-- Design: thin top bar always visible (draggable), click to slide panel down.
-- No circular buttons. Sharp corners with 4px radius max. Smooth TweenService anim.

local function say(t)
    if S.status then
        S.status.Text = tostring(t)
        task.delay(2, function()
            if S.status then S.status.Text = "ready" end
        end)
    end
end

local PANEL_H = 520  -- collapsed: 0, expanded: PANEL_H

local function buildGui()
    local pg = LocalPlayer:WaitForChild("PlayerGui")
    local old = pg:FindFirstChild("LeaHub")
    if old then old:Destroy() end

    local g = Instance.new("ScreenGui")
    g.Name = "LeaHub"
    g.ResetOnSpawn = false
    g.IgnoreGuiInset = true
    g.DisplayOrder = 999
    g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    g.Parent = pg
    S.gui = g
    -- remove old radar if exists (rebuild with new size)
    if S.map then S.map:Destroy() S.map=nil end

    -- FOV ring
    local fov = Instance.new("Frame")
    fov.Name = "FOV"
    fov.AnchorPoint = Vector2.new(0.5, 0.5)
    fov.Position = UDim2.fromScale(0.5, 0.5)
    fov.BackgroundTransparency = 1
    fov.ZIndex = 40
    fov.Parent = g
    local fs = Instance.new("UIStroke", fov)
    fs.Color = ACCENT; fs.Thickness = 1.2; fs.Transparency = 0.45
    Instance.new("UICorner", fov).CornerRadius = UDim.new(1, 0)
    S.fov = fov

    buildMap(g)

    -- ── Root container (top bar + panel together, draggable as one unit) ──
    local root = Instance.new("Frame")
    root.Name = "LeaRoot"
    root.Size = UDim2.fromOffset(280, 28)   -- starts as just the bar
    root.Position = UDim2.new(0.5, -140, 0, 8)
    root.BackgroundTransparency = 1
    root.ClipsDescendants = false
    root.ZIndex = 50
    root.Parent = g

    -- ── Top bar ──
    local bar = Instance.new("Frame")
    bar.Name = "TopBar"
    bar.Size = UDim2.new(1, 0, 0, 28)
    bar.Position = UDim2.fromOffset(0, 0)
    bar.BackgroundColor3 = Color3.fromRGB(14, 14, 18)
    bar.BorderSizePixel = 0
    bar.ZIndex = 55
    bar.Parent = root
    Instance.new("UICorner", bar).CornerRadius = UDim.new(0, 4)
    local barStroke = Instance.new("UIStroke", bar)
    barStroke.Color = Color3.fromRGB(50, 45, 38)
    barStroke.Thickness = 1
    barStroke.Transparency = 0.3

    -- accent left stripe
    local stripe = Instance.new("Frame")
    stripe.Size = UDim2.fromOffset(3, 16)
    stripe.Position = UDim2.fromOffset(8, 6)
    stripe.BackgroundColor3 = ACCENT
    stripe.BorderSizePixel = 0
    stripe.ZIndex = 56
    stripe.Parent = bar
    Instance.new("UICorner", stripe).CornerRadius = UDim.new(0, 2)

    -- title
    local titleLbl = Instance.new("TextLabel")
    titleLbl.Size = UDim2.new(1, -120, 1, 0)
    titleLbl.Position = UDim2.fromOffset(18, 0)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Text = "LEA  v12"
    titleLbl.Font = Enum.Font.GothamBold
    titleLbl.TextSize = 12
    titleLbl.TextColor3 = Color3.fromRGB(220, 215, 205)
    titleLbl.TextXAlignment = Enum.TextXAlignment.Left
    titleLbl.ZIndex = 56
    titleLbl.Parent = bar

    -- status pill on bar
    local statusPill = Instance.new("TextLabel")
    statusPill.Size = UDim2.fromOffset(80, 18)
    statusPill.Position = UDim2.new(1, -132, 0.5, -9)
    statusPill.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
    statusPill.Text = "ready"
    statusPill.Font = Enum.Font.Gotham
    statusPill.TextSize = 10
    statusPill.TextColor3 = Color3.fromRGB(100, 200, 120)
    statusPill.TextXAlignment = Enum.TextXAlignment.Center
    statusPill.ZIndex = 56
    statusPill.Parent = bar
    Instance.new("UICorner", statusPill).CornerRadius = UDim.new(0, 3)
    S.status = statusPill

    -- open/close toggle on bar (right side)
    local toggleBtn = Instance.new("TextButton")
    toggleBtn.Size = UDim2.fromOffset(44, 18)
    toggleBtn.Position = UDim2.new(1, -50, 0.5, -9)
    toggleBtn.BackgroundColor3 = Color3.fromRGB(28, 24, 18)
    toggleBtn.Text = "OPEN"
    toggleBtn.Font = Enum.Font.GothamBold
    toggleBtn.TextSize = 10
    toggleBtn.TextColor3 = ACCENT
    toggleBtn.ZIndex = 57
    toggleBtn.Parent = bar
    Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 3)
    local tStroke = Instance.new("UIStroke", toggleBtn)
    tStroke.Color = ACCENT; tStroke.Thickness = 1; tStroke.Transparency = 0.5

    -- ── Panel (slides down from under the bar) ──
    local panel = Instance.new("Frame")
    panel.Name = "Panel"
    panel.Size = UDim2.fromOffset(280, PANEL_H)
    panel.Position = UDim2.fromOffset(0, 28)
    panel.BackgroundColor3 = Color3.fromRGB(11, 11, 14)
    panel.ClipsDescendants = true
    panel.BorderSizePixel = 0
    panel.ZIndex = 50
    panel.Parent = root
    -- start hidden by clipping to 0 height
    panel.Size = UDim2.fromOffset(280, 0)
    local pStroke = Instance.new("UIStroke", panel)
    pStroke.Color = Color3.fromRGB(40, 38, 32)
    pStroke.Thickness = 1
    pStroke.Transparency = 0.3
    local pCorner = Instance.new("UICorner", panel)
    pCorner.CornerRadius = UDim.new(0, 4)

    local panelOpen = false

    local tweenInfo = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

    local function setPanel(open)
        panelOpen = open
        toggleBtn.Text = open and "CLOSE" or "OPEN"
        local targetH = open and PANEL_H or 0
        local tween = TweenService:Create(panel, tweenInfo, {Size = UDim2.fromOffset(310, targetH)})
        tween:Play()
    end

    toggleBtn.MouseButton1Click:Connect(function()
        setPanel(not panelOpen)
    end)

    -- ── Drag (bar only) ──
    local dragging, d0, p0 = false, nil, nil
    bar.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true; d0 = i.Position; p0 = root.Position
        end
    end)
    bar.InputEnded:Connect(function() dragging = false end)
    UserInputService.InputChanged:Connect(function(i)
        if not dragging then return end
        if i.UserInputType == Enum.UserInputType.MouseMovement
        or i.UserInputType == Enum.UserInputType.Touch then
            local d = i.Position - d0
            root.Position = UDim2.new(
                p0.X.Scale, p0.X.Offset + d.X,
                p0.Y.Scale, p0.Y.Offset + d.Y
            )
        end
    end)

    -- ── Tab bar inside panel ──
    local tabBar = Instance.new("Frame")
    tabBar.Size = UDim2.new(1, -12, 0, 28)
    tabBar.Position = UDim2.fromOffset(6, 8)
    tabBar.BackgroundColor3 = Color3.fromRGB(16, 16, 20)
    tabBar.ZIndex = 51
    tabBar.Parent = panel
    Instance.new("UICorner", tabBar).CornerRadius = UDim.new(0, 4)
    local tabLay = Instance.new("UIListLayout", tabBar)
    tabLay.FillDirection = Enum.FillDirection.Horizontal
    tabLay.Padding = UDim.new(0, 2)
    tabLay.VerticalAlignment = Enum.VerticalAlignment.Center
    local tabPad = Instance.new("UIPadding", tabBar)
    tabPad.PaddingLeft = UDim.new(0, 3); tabPad.PaddingRight = UDim.new(0, 3)
    tabPad.PaddingTop = UDim.new(0, 3); tabPad.PaddingBottom = UDim.new(0, 3)

    -- ── Scroll area ──
    local scroll = Instance.new("ScrollingFrame")
    scroll.Size = UDim2.new(1, -12, 1, -50)
    scroll.Position = UDim2.fromOffset(6, 44)
    scroll.BackgroundTransparency = 1
    scroll.ScrollBarThickness = 2
    scroll.ScrollBarImageColor3 = ACCENT
    scroll.CanvasSize = UDim2.fromOffset(0, 0)
    scroll.ZIndex = 51
    scroll.Parent = panel
    local sLay = Instance.new("UIListLayout", scroll)
    sLay.Padding = UDim.new(0, 4)
    sLay.SortOrder = Enum.SortOrder.LayoutOrder
    sLay:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        scroll.CanvasSize = UDim2.fromOffset(0, sLay.AbsoluteContentSize.Y + 10)
    end)

    -- ── Tabs ──
    local TABS = {
        {id="main",   t="Main"},
        {id="combat", t="Aim"},
        {id="move",   t="Move"},
        {id="visual", t="ESP"},
        {id="loot",   t="Loot"},
        {id="list",   t="List"},
    }
    -- widen panel + root for 6 tabs
    panel.Size = UDim2.fromOffset(310, 0)
    root.Size  = UDim2.fromOffset(310, 28)
    root.Position = UDim2.new(0.5, -155, 0, 8)
    local pages, tabs, active = {}, {}, nil

    for _, td in ipairs(TABS) do
        local page = Instance.new("Frame")
        page.Name = td.id
        page.Size = UDim2.new(1, 0, 0, 0)
        page.BackgroundTransparency = 1
        page.Visible = false
        page.AutomaticSize = Enum.AutomaticSize.Y
        page.ZIndex = 52
        page.Parent = scroll
        local pl = Instance.new("UIListLayout", page)
        pl.Padding = UDim.new(0, 4)
        pl.SortOrder = Enum.SortOrder.LayoutOrder
        pages[td.id] = {f = page, o = 0}
    end

    local function switch(id)
        if active == id then return end
        active = id
        for _, td in ipairs(TABS) do
            if pages[td.id] then pages[td.id].f.Visible = (td.id == id) end
        end
        for tid, b in pairs(tabs) do
            b.BackgroundColor3 = (tid == id) and Color3.fromRGB(32, 26, 16) or Color3.fromRGB(20, 20, 24)
            b.TextColor3 = (tid == id) and ACCENT or Color3.fromRGB(130, 130, 140)
        end
        scroll.CanvasPosition = Vector2.zero
    end

    local n = #TABS
    for _, td in ipairs(TABS) do
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1/n, -2, 1, 0)
        b.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
        b.Text = td.t
        b.Font = Enum.Font.GothamMedium
        b.TextSize = 11
        b.TextColor3 = Color3.fromRGB(130, 130, 140)
        b.ZIndex = 52
        b.Parent = tabBar
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 3)
        tabs[td.id] = b
        local id = td.id
        b.MouseButton1Click:Connect(function() switch(id) end)
    end

    -- ── Widget helpers ──
    local function tog(page, name, key, onE, onD)
        local p = pages[page]; if not p then return end
        p.o += 1
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, -2, 0, 32)
        row.BackgroundColor3 = Color3.fromRGB(17, 17, 21)
        row.LayoutOrder = p.o
        row.ZIndex = 52
        row.Parent = p.f
        Instance.new("UICorner", row).CornerRadius = UDim.new(0, 4)

        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, -54, 1, 0)
        lbl.Position = UDim2.fromOffset(10, 0)
        lbl.BackgroundTransparency = 1
        lbl.Text = name
        lbl.Font = Enum.Font.GothamMedium
        lbl.TextSize = 12
        lbl.TextColor3 = Color3.fromRGB(155, 155, 165)
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.ZIndex = 53
        lbl.Parent = row

        -- flat toggle: a simple rect that shifts color
        local pill = Instance.new("Frame")
        pill.Size = UDim2.fromOffset(36, 18)
        pill.Position = UDim2.new(1, -44, 0.5, -9)
        pill.ZIndex = 53
        pill.Parent = row
        Instance.new("UICorner", pill).CornerRadius = UDim.new(0, 3)

        local dot = Instance.new("Frame")
        dot.Size = UDim2.fromOffset(12, 12)
        dot.ZIndex = 54
        dot.Parent = pill
        Instance.new("UICorner", dot).CornerRadius = UDim.new(0, 2)

        local function ref()
            local on = ON[key]
            pill.BackgroundColor3 = on and ACCENT or Color3.fromRGB(36, 36, 44)
            dot.BackgroundColor3 = on and Color3.new(1, 1, 1) or Color3.fromRGB(90, 90, 100)
            dot.Position = on and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3)
            lbl.TextColor3 = on and Color3.fromRGB(255, 205, 140) or Color3.fromRGB(155, 155, 165)
            row.BackgroundColor3 = on and Color3.fromRGB(26, 22, 16) or Color3.fromRGB(17, 17, 21)
        end

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, 0, 1, 0)
        btn.BackgroundTransparency = 1
        btn.Text = ""
        btn.ZIndex = 55
        btn.Parent = row
        btn.MouseButton1Click:Connect(function()
            ON[key] = not ON[key]; ref()
            if ON[key] and onE then pcall(onE) end
            if not ON[key] and onD then pcall(onD) end
            say(name .. (ON[key] and " on" or " off"))
        end)
        ref()
    end

    local function act(page, name, fn)
        local p = pages[page]; if not p then return end
        p.o += 1
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, -2, 0, 28)
        b.BackgroundColor3 = Color3.fromRGB(17, 17, 21)
        b.LayoutOrder = p.o
        b.ZIndex = 52
        b.Parent = p.f
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)
        b.Text = "  " .. name
        b.Font = Enum.Font.GothamMedium
        b.TextSize = 12
        b.TextColor3 = Color3.fromRGB(210, 210, 215)
        b.TextXAlignment = Enum.TextXAlignment.Left
        b.MouseButton1Click:Connect(function()
            pcall(fn)
            b.BackgroundColor3 = Color3.fromRGB(30, 25, 16)
            task.delay(0.12, function() b.BackgroundColor3 = Color3.fromRGB(17, 17, 21) end)
        end)
    end

    local function sec(page, name)
        local p = pages[page]; if not p then return end
        p.o += 1
        local l = Instance.new("TextLabel")
        l.Size = UDim2.new(1, 0, 0, 14)
        l.BackgroundTransparency = 1
        l.Text = string.upper(name)
        l.Font = Enum.Font.GothamBold
        l.TextSize = 9
        l.TextColor3 = Color3.fromRGB(90, 82, 70)
        l.TextXAlignment = Enum.TextXAlignment.Left
        l.LayoutOrder = p.o
        l.ZIndex = 52
        l.Parent = p.f
    end

    local function slider(page, name, cfgKey, minV, maxV, step, fmt)
        local p = pages[page]; if not p then return end
        p.o += 1
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, -2, 0, 36)
        row.BackgroundColor3 = Color3.fromRGB(17, 17, 21)
        row.LayoutOrder = p.o
        row.ZIndex = 52
        row.Parent = p.f
        Instance.new("UICorner", row).CornerRadius = UDim.new(0, 4)

        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(0.55, 0, 0, 16)
        lbl.Position = UDim2.fromOffset(10, 2)
        lbl.BackgroundTransparency = 1
        lbl.Text = name
        lbl.Font = Enum.Font.GothamMedium
        lbl.TextSize = 11
        lbl.TextColor3 = Color3.fromRGB(155, 155, 165)
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.ZIndex = 53
        lbl.Parent = row

        local valLbl = Instance.new("TextLabel")
        valLbl.Size = UDim2.new(1, -20, 0, 14)
        valLbl.Position = UDim2.fromOffset(10, 20)
        valLbl.BackgroundTransparency = 1
        valLbl.Font = Enum.Font.GothamMedium
        valLbl.TextSize = 10
        valLbl.TextColor3 = ACCENT
        valLbl.TextXAlignment = Enum.TextXAlignment.Left
        valLbl.ZIndex = 53
        valLbl.Parent = row

        local function refreshVal()
            valLbl.Text = (fmt or "%g"):format(CFG[cfgKey])
        end
        refreshVal()

        local minus = Instance.new("TextButton")
        minus.Size = UDim2.fromOffset(20, 20)
        minus.Position = UDim2.new(1, -46, 0.5, -10)
        minus.BackgroundColor3 = Color3.fromRGB(26, 20, 14)
        minus.Text = "−"
        minus.Font = Enum.Font.GothamBold
        minus.TextSize = 14
        minus.TextColor3 = ACCENT
        minus.ZIndex = 54
        minus.Parent = row
        Instance.new("UICorner", minus).CornerRadius = UDim.new(0, 3)

        local plus = Instance.new("TextButton")
        plus.Size = UDim2.fromOffset(20, 20)
        plus.Position = UDim2.new(1, -22, 0.5, -10)
        plus.BackgroundColor3 = Color3.fromRGB(26, 20, 14)
        plus.Text = "+"
        plus.Font = Enum.Font.GothamBold
        plus.TextSize = 14
        plus.TextColor3 = ACCENT
        plus.ZIndex = 54
        plus.Parent = row
        Instance.new("UICorner", plus).CornerRadius = UDim.new(0, 3)

        minus.MouseButton1Click:Connect(function()
            CFG[cfgKey] = math.clamp(CFG[cfgKey] - step, minV, maxV); refreshVal()
            say(name .. ": " .. (fmt or "%g"):format(CFG[cfgKey]))
        end)
        plus.MouseButton1Click:Connect(function()
            CFG[cfgKey] = math.clamp(CFG[cfgKey] + step, minV, maxV); refreshVal()
            say(name .. ": " .. (fmt or "%g"):format(CFG[cfgKey]))
        end)
    end

    -- ── MAIN tab ──
    sec("main","bypass")
    act("main","Enable Bypass", function() startBypass(); say("bypass live") end)
    tog("main","Ownership",    "Ownership")
    tog("main","Anti-Teleport","AntiTP")
    tog("main","God Mode",     "God", startGod, function() if S.godConn then S.godConn:Disconnect() end end)

    -- ── COMBAT tab ──
    sec("combat","aimbot")
    tog("combat","Aimbot  [hold Q]","Aimbot")
    tog("combat","FOV Circle",      "ShowFov")
    tog("combat","Silent Aim",      "SilentAim")
    slider("combat","FOV radius",   "aimFovPx",  80, 700, 25, "%g px")
    slider("combat","Step speed",   "aimStepPx",  2,  60,  2, "%g px/f")
    slider("combat","Predict",      "aimPredict", 0, 0.5, 0.02, "%.2f")
    sec("combat","extra")
    tog("combat","Mob Push","MobPush")
    tog("combat","No Fall", "NoFall")

    -- ── MOVE tab ──
    sec("move","movement")
    tog("move","Speed",    "Speed",    applySpeed, applySpeed)
    tog("move","High Jump","HighJump", applySpeed, applySpeed)
    tog("move","Fly",      "Fly",      flyStart,   flyStop)
    tog("move","Noclip",   "Noclip",   function() setNoclip(true) end, function() setNoclip(false) end)
    tog("move","Inf Jump", "InfJump")
    slider("move","Fly speed",    "flySpeed",    20, 500, 10, "%g")
    slider("move","Walk boost",   "walkBoost",   16, 300, 5,  "%g")
    sec("move","vehicle  [F6 toggle]")
    tog("move","Car Fly","CarFly", carStart, carStop)
    slider("move","Car speed",  "carFlySpeed",  50, 600, 10, "%g")
    slider("move","Car boost",  "carFlyBoost",  50, 900, 20, "%g")

    -- ── ESP tab ──
    sec("visual","esp")
    tog("visual","ESP",        "ESP",        doESP, function() if not ON.Tracers then clearESP() else doESP() end end)
    tog("visual","Tracers",    "Tracers",    doESP, function() if not ON.ESP     then clearESP() else doESP() end end)
    tog("visual","Minimap",    "Minimap")
    tog("visual","Map Names",  "Minimap",    -- reuse Minimap flag; names controlled by CFG
        function() CFG.mapShowNames=true  end,
        function() CFG.mapShowNames=false end)
    tog("visual","Fullbright", "Fullbright", function() fullbright(true) end, function() fullbright(false) end)
    slider("visual","Map range","mapRange", 100, 3000, 100, "%g m")
    slider("visual","Map size", "mapSize",  120,  320,  20, "%g px")

    -- ── LOOT tab ──
    sec("loot","loot tracker")
    tog("loot","Loot Tracker","LootTracker",
        function() startLootTracker(); say("loot tracker on") end,
        function() say("loot tracker off") end)
    tog("loot","Body Glow",  "LootTracker",   -- reuse flag for now; glow follows tracker
        function() CFG.lootBodyGlow=true  end,
        function() CFG.lootBodyGlow=false end)
    slider("loot","Show range","lootRange", 50, 2000, 50, "%g m")

    -- clear button
    act("loot","Clear Log", function()
        S.lootLog={}
        for model, hl in pairs(S.lootBodyHL) do
            pcall(function() if hl and hl.Parent then hl:Destroy() end end)
        end
        S.lootBodyHL={}
        pcall(refreshLootPanel)
        say("loot log cleared")
    end)

    sec("loot","kills / drops")
    -- loot scroll panel
    local lp2 = pages["loot"]; lp2.o += 1
    local lootScroll = Instance.new("ScrollingFrame")
    lootScroll.Size = UDim2.new(1, -2, 0, 300)
    lootScroll.BackgroundColor3 = Color3.fromRGB(12, 11, 8)
    lootScroll.LayoutOrder = lp2.o
    lootScroll.ZIndex = 52
    lootScroll.ScrollBarThickness = 2
    lootScroll.ScrollBarImageColor3 = COL_LOOT
    lootScroll.CanvasSize = UDim2.fromOffset(0, 0)
    lootScroll.Parent = lp2.f
    Instance.new("UICorner", lootScroll).CornerRadius = UDim.new(0, 4)
    local lLay = Instance.new("UIListLayout", lootScroll)
    lLay.Padding = UDim.new(0, 4)
    lLay.SortOrder = Enum.SortOrder.LayoutOrder
    lLay:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        lootScroll.CanvasSize = UDim2.fromOffset(0, lLay.AbsoluteContentSize.Y + 8)
    end)
    S.lootPanel = lootScroll
    -- seed empty state
    local emptyL = Instance.new("TextLabel", lootScroll)
    emptyL.Size = UDim2.new(1,0,0,30)
    emptyL.BackgroundTransparency = 1
    emptyL.Text = "no loot yet — kills will appear here"
    emptyL.Font = Enum.Font.Gotham
    emptyL.TextSize = 10
    emptyL.TextColor3 = Color3.fromRGB(90,90,100)
    emptyL.TextXAlignment = Enum.TextXAlignment.Center
    emptyL.ZIndex = 52

    -- ── LIST tab ──
    sec("list","whitelist")
    local lp = pages["list"]; lp.o += 1
    local box = Instance.new("ScrollingFrame")
    box.Size = UDim2.new(1, -2, 0, 220)
    box.BackgroundColor3 = Color3.fromRGB(13, 13, 16)
    box.LayoutOrder = lp.o
    box.ZIndex = 52
    box.ScrollBarThickness = 2
    box.Parent = lp.f
    Instance.new("UICorner", box).CornerRadius = UDim.new(0, 4)
    local bl = Instance.new("UIListLayout", box)
    bl.Padding = UDim.new(0, 3)
    bl:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        box.CanvasSize = UDim2.fromOffset(0, bl.AbsoluteContentSize.Y + 6)
    end)

    local function refreshList()
        for _, c in ipairs(box:GetChildren()) do
            if c:IsA("TextButton") then c:Destroy() end
        end
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer then
                local friend = wl(plr)
                local b = Instance.new("TextButton")
                b.Size = UDim2.new(1, -6, 0, 24)
                b.BackgroundColor3 = friend and Color3.fromRGB(16, 32, 20) or Color3.fromRGB(32, 16, 16)
                b.Text = (friend and "[WL] " or "") .. plr.Name
                b.Font = Enum.Font.Gotham
                b.TextSize = 11
                b.TextColor3 = friend and COL_F or COL_E
                b.ZIndex = 53
                b.Parent = box
                Instance.new("UICorner", b).CornerRadius = UDim.new(0, 3)
                local p = plr
                b.MouseButton1Click:Connect(function()
                    if WHITELIST[p.UserId] then WHITELIST[p.UserId] = nil
                    else WHITELIST[p.UserId] = true end
                    refreshList()
                    if ON.ESP or ON.Tracers then doESP() end
                    say(p.Name .. (wl(p) and " friend" or " enemy"))
                end)
            end
        end
    end

    act("list","Refresh", refreshList)
    Players.PlayerAdded:Connect(function() task.defer(refreshList) end)
    Players.PlayerRemoving:Connect(function(p) WHITELIST[p.UserId] = nil; task.defer(refreshList) end)
    task.defer(refreshList)

    -- keyboard shortcuts
    UserInputService.InputBegan:Connect(function(i, gp)
        if gp then return end
        if i.KeyCode == Enum.KeyCode.RightShift then
            setPanel(not panelOpen)
            if panelOpen then
                if not active then switch("main") end
                refreshList()
            end
        elseif i.KeyCode == Enum.KeyCode.F9 then
            ON.Aimbot = not ON.Aimbot
            say("aimbot " .. (ON.Aimbot and "on" or "off"))
            updateFov()
        elseif i.KeyCode == Enum.KeyCode.F8 then
            ON.ESP = not ON.ESP
            if ON.ESP or ON.Tracers then doESP() else clearESP() end
            say("esp " .. (ON.ESP and "on" or "off"))
        elseif i.KeyCode == CFG.carFlyKey then
            ON.CarFly = not ON.CarFly
            if ON.CarFly then carStart() else carStop() end
            say("car fly " .. (ON.CarFly and "on" or "off"))
        end
    end)

    switch("main")
end

-- ===================== INIT =====================
task.wait(0.25)
startBypass()
buildGui()
ON.Minimap = true
ON.ShowFov = true
ON.LootTracker = true
updateFov()
startLootTracker()
-- rebuild minimap now that gui is live (new size)
if S.gui then buildMap(S.gui) end
