--[[
 RHYE Hub | ABOVE Auto Hunt V3.0 — Reliable Detection & Combat Spacing
 PlaceId: 124357835578554

 Community client-side helper. Uses visible NPC models, PathfindingService,
 standard Tool / mouse input, and detectable in-world teleporter interactions.
 No arbitrary server RemoteEvent calls, no damage overrides, no noclip.
 Local combat spacing and low-HP safety are best effort, not immunity.

 Configuration: RHYE_Hub/ABOVE_Global_Config.json (executor workspace)
 Shared on THIS computer / executor workspace, independent of Roblox UserId.
 Teleporter destinations may require one-time binding in the Home area.
]]
if not game:IsLoaded() then game.Loaded:Wait() end
if game.PlaceId ~= 124357835578554 then
    warn("[RHYE ABOVE] Wrong PlaceId. Expected 124357835578554")
    return
end

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local PathfindingService = game:GetService("PathfindingService")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")
local player = Players.LocalPlayer
while not player do task.wait(0.1); player = Players.LocalPlayer end

local env = (type(getgenv)=="function" and getgenv()) or _G
if type(env.RHYE_ABOVE_SHUTDOWN)=="function" then
    pcall(env.RHYE_ABOVE_SHUTDOWN)
end

local CONFIG_FOLDER = "RHYE_Hub"
local CONFIG_FILE = CONFIG_FOLDER.."/ABOVE_Global_Config.json"
local FALLBACK_CONFIG_FILE = "RHYE_ABOVE_Global_Config.json" -- if makefolder unsupported
local OLD_CONFIG_FILE = "RHYE_ABOVE_AutoHunt_V1.json"
local defaults = {
    farmMobs = true,
    targetGroup = "Slime", -- Only Slime or Skeleton (all variants)
    mobWeapon = "Sword",
    attackRange = 5,
    autoKite = true, -- default: keep a safer distance from melee mobs
    safeDistance = 4.2, -- ideal sword distance; ranged weapons auto prefer farther
    lowHealthSafety = true, -- avoid chasing while critically low on HP
    lowHealthThreshold = 35, -- percent

    attackInterval = 0.50,
    maxSearch = 250,
    walkSpeed = 20,
    autoChase = true,
    autoEquip = true,
    autoAim = true,
    attackMode = "Mouse",
    autoReturn = true,
    returnDelay = 13,
    portalSlimeName = "", -- user may bind a unique portal name or full path
    portalHubName = "", -- optional Home -> Hub step for a multi-portal route
    portalSkeletonName = "",
    autoAfk = true,
    autoSave = true,
    autoStart = false,
}
local cfg = {}
for key,value in pairs(defaults) do cfg[key]=value end
local loadedConfig = false
local function safeReadConfig(path)
    if type(readfile) ~= "function" then return nil end
    local ok,result = pcall(function()
        if type(isfile)=="function" and not isfile(path) then return nil end
        return HttpService:JSONDecode(readfile(path))
    end)
    if ok and type(result)=="table" then return result end
    return nil
end
local previous = safeReadConfig(CONFIG_FILE)
if not previous then previous=safeReadConfig(FALLBACK_CONFIG_FILE) end
if previous then
    loadedConfig = true
else
    previous = safeReadConfig(OLD_CONFIG_FILE)
    if previous and type(previous.targetMobs)=="string" then
        previous.targetGroup = previous.targetMobs:lower():find("skeleton",1,true) and "Skeleton" or "Slime"
    end
end
if previous then
    if type(previous.mobWeapon) ~= "string" and type(previous.weapon)=="string" then
        previous.mobWeapon = previous.weapon
    end
    for key,def in pairs(defaults) do
        if type(previous[key])==type(def) then cfg[key]=previous[key] end
    end
end
if cfg.targetGroup ~= "Slime" and cfg.targetGroup ~= "Skeleton" then cfg.targetGroup="Slime" end
if not table.find({"Sword","Bow","Scepter","Equipped"}, cfg.mobWeapon) then cfg.mobWeapon="Sword" end
if not table.find({"Mouse","Tool","Auto"}, cfg.attackMode) then cfg.attackMode="Mouse" end
cfg.attackRange = math.clamp(cfg.attackRange,2,35)
cfg.attackInterval = math.clamp(cfg.attackInterval,0.12,2)
cfg.safeDistance = math.clamp(cfg.safeDistance,2.5,20)
cfg.lowHealthThreshold = math.clamp(cfg.lowHealthThreshold,15,60)
cfg.maxSearch = math.clamp(cfg.maxSearch,50,500)
cfg.walkSpeed = math.clamp(cfg.walkSpeed,12,32)
cfg.returnDelay = math.clamp(cfg.returnDelay,8,45)

local running, closed = false, false
local connections = {}
local npcCache, npcCacheSet = {}, {}
local currentTarget, lastEnemySeen = nil, os.clock()
local lastTargetSwitchAt=0
local nextAttack, lastScan, lastNearScan = 0, 0, 0
local lastHealthCheck, measuredHealthRatio, measuredCurrentHealth = 0, nil, nil
local lastHealthReading, lastDamageAt, recovering = nil, -1e9, false
local lastRetreatGoal, lastRetreatAt, lastRetreatEnemy = nil, 0, nil
local lastPortalScan = 0
local portals = {}
local portalAttemptAt, portalInteractAt, portalArrivalAt = 0, 0, 0
local activePortal = nil
local lastCharacter = nil
local gui, statusText, targetText, farmButton
local lastStatus = "Ready"
local nav = {
    generation=0, subject=nil, waypoints=nil, index=1,
    goal=nil, computing=false, lastPlan=0, blockedConnection=nil,
    wanted=nil, lastMoveAt=0, lastMoveGoal=nil,
    lastProgressPosition=nil, lastProgressAt=0, failures=0,
    failedGoalAt=0, retryNow=false,
}
local blocked = setmetatable({},{__mode="k"})

local function remember(conn)
    table.insert(connections,conn)
    return conn
end
local function setStatus(message)
    message=tostring(message)
    if lastStatus==message then return end
    lastStatus=message
    if statusText and statusText.Parent then statusText.Text=message end
end

-- Debounced auto-save, account-independent by design (no UserId in path).
local saveGeneration=0
local function writeConfig(silent)
    if type(writefile)~="function" then
        if not silent then setStatus("No writefile API; config is session-only") end
        return false
    end
    local payload=HttpService:JSONEncode(cfg)
    local ok,err=pcall(function()
        if type(makefolder)=="function" then
            if type(isfolder)~="function" or not isfolder(CONFIG_FOLDER) then
                makefolder(CONFIG_FOLDER)
            end
        end
        writefile(CONFIG_FILE,payload)
    end)
    if not ok then
        -- Some executors expose writefile but do not support subfolders.
        local okFallback,errFallback=pcall(function()
            writefile(FALLBACK_CONFIG_FILE,payload)
        end)
        if okFallback then ok=true else err=errFallback end
    end
    if not ok then
        if not silent then setStatus("Config save error: "..tostring(err)) end
        warn("[RHYE ABOVE] config save error: "..tostring(err))
    elseif not silent then
        setStatus("Saved shared config in Potassium workspace")
    end
    return ok
end
local function scheduleSave(force)
    saveGeneration=saveGeneration+1
    local mine=saveGeneration
    if not cfg.autoSave and not force then return end
    task.delay(force and 0 or 0.65,function()
        if closed or mine~=saveGeneration then return end
        writeConfig(true)
    end)
end
local function changed(force)
    scheduleSave(force)
end

local function getCharacter()
    local character=player.Character
    if not character then return nil end
    local hum=character:FindFirstChildOfClass("Humanoid")
    local root=character:FindFirstChild("HumanoidRootPart")
    if not hum or not root or hum.Health<=0 then return nil end
    return character,hum,root
end
local function findRoot(model)
    if not model then return nil end
    if model:IsA("BasePart") then return model end
    if not model:IsA("Model") then return nil end
    if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then return model.PrimaryPart end
    for _,name in ipairs({"HumanoidRootPart","RootPart","Root","UpperTorso","Torso","Body","Head"}) do
        local part=model:FindFirstChild(name,true)
        if part and part:IsA("BasePart") then return part end
    end
    return model:FindFirstChildWhichIsA("BasePart",true)
end
-- ------------- Reliable NPC recognition (models AND single parts) -------------
-- ABOVE can stream NPCs as loose BaseParts, nested Models, or renamed rig roots.
-- Only Slime/Skeleton groups are accepted; never select player characters.
local ignoreTokens={"spawn","portal","teleport","gate","chest","display","decor","statue",
    "trophy","egg","skeleton key","slime block","slime gel",
    "spawner","resource","loot","drop","island","map","region","biome"}
local function groupFromString(value)
    if type(value)~="string" then return nil end
    local n=value:lower()
    for _,bad in ipairs(ignoreTokens) do
        if n:find(bad,1,true) then return nil end
    end
    if n:find("skeleton",1,true) then return "Skeleton" end
    if n:find("slime",1,true) then return "Slime" end
    return nil
end
local attributeNames={"MobType","MonsterType","EnemyType","Species","MobName","MonsterName","DisplayName","NPCType","Type"}
local function ownCategory(inst)
    if not inst then return nil end
    local group=groupFromString(inst.Name)
    if group then return group end
    for _,attr in ipairs(attributeNames) do
        group=groupFromString(inst:GetAttribute(attr))
        if group then return group end
    end
    for _,tag in ipairs(CollectionService:GetTags(inst)) do
        group=groupFromString(tag)
        if group then return group end
    end
    return nil
end
local function healthInfo(inst)
    if not inst then return nil,false end
    if inst:IsA("Model") then
        local hum=inst:FindFirstChildOfClass("Humanoid")
        if hum then return hum.Health,true end
    end
    for _,name in ipairs({"Health","HP","CurrentHealth","health","hp"}) do
        local attr=inst:GetAttribute(name)
        if type(attr)=="number" then return attr,true end
        local val=inst:FindFirstChild(name)
        if val and (val:IsA("NumberValue") or val:IsA("IntValue")) then return val.Value,true end
    end
    if inst:IsA("Model") then
        for _,name in ipairs({"Health","HP","CurrentHealth"}) do
            local val=inst:FindFirstChild(name,true)
            if val and (val:IsA("NumberValue") or val:IsA("IntValue")) then return val.Value,true end
        end
    end
    return nil,false
end
local function isPlayerModel(inst)
    local p=inst
    while p and p~=Workspace do
        if p:IsA("Model") and Players:GetPlayerFromCharacter(p) then return true end
        p=p.Parent
    end
    return false
end
local function categoryOf(inst)
    if not inst or not (inst:IsA("Model") or inst:IsA("BasePart")) then return nil end
    if isPlayerModel(inst) then return nil end
    local own=ownCategory(inst)
    if own then return own end
    if not inst:IsA("Model") then
        -- Standalone NPC part inside a folder of slimes/skeletons.  Require
        -- explicit life/enemy metadata to avoid matching scenery in that folder.
        local parent=inst.Parent
        if parent and parent:IsA("Folder") then
            local g=groupFromString(parent.Name)
            local hp,known=healthInfo(inst)
            if g and (known or inst:GetAttribute("IsMob")==true
                or inst:GetAttribute("IsEnemy")==true) then return g end
        end
        return nil
    end
    -- Only inspect deeper NPC hints for plausible actor containers, not map folders.
    local name=inst.Name:lower()
    local actorHint=inst:FindFirstChildOfClass("Humanoid") or inst.PrimaryPart
        or inst:GetAttribute("IsMob")==true or inst:GetAttribute("IsEnemy")==true
        or name:find("mob",1,true) or name:find("enemy",1,true)
        or name:find("npc",1,true) or name:find("creature",1,true)
    if not actorHint then return nil end
    -- Some NPCs have generic names under typed enemy folders.
    if inst.Parent and inst.Parent:IsA("Folder") then
        local group=groupFromString(inst.Parent.Name)
        if group then return group end
    end
    for _,child in ipairs(inst:GetChildren()) do
        if child:IsA("BasePart") or child:IsA("Model") then
            local group=ownCategory(child)
            if group then return group end
        end
        if child:IsA("BillboardGui") then
            for _,guiChild in ipairs(child:GetDescendants()) do
                if guiChild:IsA("TextLabel") then
                    local group=groupFromString(guiChild.Text)
                    if group then return group end
                end
            end
        end
    end
    local plate=inst:FindFirstChildWhichIsA("BillboardGui",true)
    if plate then
        for _,labelObj in ipairs(plate:GetDescendants()) do
            if labelObj:IsA("TextLabel") then
                local group=groupFromString(labelObj.Text)
                if group then return group end
            end
        end
    end
    return nil
end
local function canonicalMob(inst)
    if not (inst:IsA("Model") or inst:IsA("BasePart")) then return nil end
    if isPlayerModel(inst) then return nil end
    local group=categoryOf(inst)
    if not group then return nil end
    if inst:IsA("BasePart") then
        local m=inst:FindFirstAncestorOfClass("Model")
        for _=1,4 do
            if not m or m==Workspace or isPlayerModel(m) then break end
            if categoryOf(m)==group then return m end
            -- Generic rig containing a named Slime/Skeleton BasePart.
            if (m:FindFirstChildOfClass("Humanoid") or m:GetAttribute("IsEnemy")==true
                or m:GetAttribute("IsMob")==true) and categoryOf(m)==group then return m end
            local parent=m.Parent
            m=parent and (parent:IsA("Model") and parent or parent:FindFirstAncestorOfClass("Model")) or nil
        end
    end
    return inst
end
local function isMonster(inst)
    if not inst or not inst:IsDescendantOf(Workspace) or isPlayerModel(inst) then return false end
    if not categoryOf(inst) then return false end
    if inst:GetAttribute("IsDead")==true or inst:GetAttribute("Dead")==true
        or inst:GetAttribute("Alive")==false then return false end
    local root=findRoot(inst)
    if not root then return false end
    local hp,known=healthInfo(inst)
    if known then return hp>0 end
    if inst:IsA("BasePart") then
        -- A live slime can be a lone moving cube with no Humanoid instance.
        local exact=categoryOf(inst)
        if not exact then return false end
        if inst.Transparency>=0.98 then return false end
        return true
    end
    return inst:FindFirstChildWhichIsA("BasePart",true)~=nil
end
local function targetAlive(inst)
    if not inst or not inst:IsDescendantOf(Workspace) or isPlayerModel(inst) then return false end
    if categoryOf(inst)~=cfg.targetGroup then return false end
    if inst:GetAttribute("IsDead")==true or inst:GetAttribute("Dead")==true
        or inst:GetAttribute("Alive")==false then return false end
    local hp,known=healthInfo(inst)
    if known and hp<=0 then return false end
    return findRoot(inst)~=nil
end
local function addNPC(inst)
    local actor=canonicalMob(inst)
    if actor and not npcCacheSet[actor] and isMonster(actor) then
        npcCacheSet[actor]=true
        npcCache[#npcCache+1]=actor
        return true
    end
    return false
end
local function refreshNPCs()
    npcCache,npcCacheSet={},{}
    for _,item in ipairs(Workspace:GetDescendants()) do
        if item:IsA("Model") or (item:IsA("BasePart") and ownCategory(item)) then
            addNPC(item)
        end
    end
    lastScan=os.clock()
end
local function scanNearbyNPCs(root)
    local now=os.clock()
    if now-lastNearScan<0.75 then return end
    lastNearScan=now
    local overlap=OverlapParams.new()
    overlap.FilterType=Enum.RaycastFilterType.Exclude
    overlap.FilterDescendantsInstances=player.Character and {player.Character} or {}
    overlap.MaxParts=650
    local radius=math.min(125,cfg.maxSearch)
    local ok,parts=pcall(function()
        return Workspace:GetPartBoundsInRadius(root.Position,radius,overlap)
    end)
    if ok and parts then
        for _,part in ipairs(parts) do
            if ownCategory(part) then addNPC(part) end
            local model=part:FindFirstAncestorOfClass("Model")
            for _=1,3 do
                if not model or model==Workspace then break end
                if ownCategory(model) or model:FindFirstChildOfClass("Humanoid") then
                    addNPC(model)
                end
                local parent=model.Parent
                model=parent and parent:FindFirstAncestorOfClass("Model") or nil
            end
        end
    end
end
local function chooseTarget(root)
    local now=os.clock()
    local best,bestDist=nil,math.huge
    for _,npc in ipairs(npcCache) do
        if targetAlive(npc) and (not blocked[npc] or blocked[npc]<=now) then
            local part=findRoot(npc)
            if part then
                local dist=(part.Position-root.Position).Magnitude
                if dist<bestDist and dist<=cfg.maxSearch then
                    best,bestDist=npc,dist
                end
            end
        end
    end
    if targetAlive(currentTarget) and (not blocked[currentTarget] or blocked[currentTarget]<=now) then
        local part=findRoot(currentTarget)
        if part then
            local lockedDist=(part.Position-root.Position).Magnitude
            if lockedDist<=cfg.maxSearch*1.4 then
                -- Lock remains stable during combat, but a much closer Slime
                -- should take priority over a distant/inaccessible one.
                if best and best~=currentTarget and now-lastTargetSwitchAt>1.7
                    and bestDist+8 < lockedDist and bestDist < lockedDist*0.58 then
                    return best
                end
                return currentTarget
            end
        end
    end
    return best
end
local function matchingWeapon(tool,weapon)
    if not tool or not tool:IsA("Tool") then return false end
    if weapon=="Equipped" then return true end
    local name=tool.Name:lower()
    if weapon=="Sword" then return name:find("sword",1,true)~=nil or name:find("blade",1,true)~=nil end
    if weapon=="Bow" then return name:find("bow",1,true)~=nil or name:find("crossbow",1,true)~=nil end
    if weapon=="Scepter" then return name:find("scepter",1,true)~=nil or name:find("staff",1,true)~=nil end
    return false
end
local function equipWeapon(character,humanoid,weapon)
    local equipped=character:FindFirstChildOfClass("Tool")
    if weapon=="Equipped" then return equipped end
    if equipped and matchingWeapon(equipped,weapon) then return equipped end
    if not cfg.autoEquip then return equipped end
    local backpack=player:FindFirstChildOfClass("Backpack")
    if backpack then
        for _,candidate in ipairs(backpack:GetChildren()) do
            if matchingWeapon(candidate,weapon) then
                pcall(function() humanoid:EquipTool(candidate) end)
                return character:FindFirstChildOfClass("Tool") or candidate
            end
        end
    end
    return equipped
end
local function attackTarget(part,tool)
    local method=cfg.attackMode
    if method=="Tool" then
        if not tool or tool.Parent~=player.Character then return false,"Equip Tool first" end
        local ok=pcall(function() tool:Activate() end)
        return ok,ok and "Tool" or "Tool failed"
    end
    local cam=Workspace.CurrentCamera
    if not cam then return false,"No camera" end
    if cfg.autoAim then
        local pos=cam.CFrame.Position
        if (part.Position-pos).Magnitude>0.2 then
            pcall(function() cam.CFrame=CFrame.lookAt(pos,part.Position) end)
        end
    end
    local projected,visible=cam:WorldToViewportPoint(part.Position)
    if visible then
        local x,y=math.floor(projected.X),math.floor(projected.Y)
        local ok=pcall(function()
            local vim=game:GetService("VirtualInputManager")
            vim:SendMouseButtonEvent(x,y,0,true,game,0)
            task.wait(0.035)
            vim:SendMouseButtonEvent(x,y,0,false,game,0)
        end)
        if ok then return true,"Mouse" end
        ok=pcall(function()
            VirtualUser:Button1Down(Vector2.new(x,y),cam.CFrame)
            task.wait(0.035)
            VirtualUser:Button1Up(Vector2.new(x,y),cam.CFrame)
        end)
        if ok then return true,"VirtualUser" end
    end
    if type(mouse1click)=="function" then
        local ok=pcall(mouse1click)
        if ok then return true,"Executor click" end
    end
    if method=="Auto" and tool and tool.Parent==player.Character then
        local ok=pcall(function()tool:Activate()end)
        if ok then return true,"Tool fallback" end
    end
    return false,visible and "No compatible input API" or "Target outside camera"
end

-- ---------------- Smooth, obstacle-aware navigation ----------------
local function flat(v) return Vector3.new(v.X,0,v.Z) end
local function horizontalDistance(a,b) return (flat(a)-flat(b)).Magnitude end
local function los(from,to,excluded)
    local list={}
    if player.Character then list[#list+1]=player.Character end
    if excluded then list[#list+1]=excluded end
    local params=RaycastParams.new()
    params.FilterType=Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances=list
    params.RespectCanCollide=true
    local origin=from+Vector3.new(0,1.5,0)
    local direction=(to+Vector3.new(0,1.5,0))-origin
    if direction.Magnitude<0.1 then return true end
    return Workspace:Raycast(origin,direction,params)==nil
end
local function findFloorAt(position,excluded)
    local list={}
    if player.Character then list[#list+1]=player.Character end
    if excluded then list[#list+1]=excluded end
    local params=RaycastParams.new()
    params.FilterType=Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances=list
    params.RespectCanCollide=true
    local hit=Workspace:Raycast(position+Vector3.new(0,7,0),Vector3.new(0,-31,0),params)
    if hit and hit.Normal.Y>0.55 then return hit.Position end
    return nil
end
local function groundCorridor(from,to,excluded)
    local dist=horizontalDistance(from,to)
    if dist<2 then return true end
    for t=0.25,0.75,0.25 do
        local sample=from:Lerp(to,t)
        if not findFloorAt(sample,excluded) then return false end
    end
    return true
end
local function approachPoint(myPos,mobPart,mobModel,range)
    local mobPos=mobPart.Position
    local away=flat(myPos-mobPos)
    if away.Magnitude<0.2 then away=Vector3.new(1,0,0) end
    away=away.Unit
    local radius=math.max(1.5,range-0.65)
    local angles={0,math.rad(30),-math.rad(30),math.rad(60),-math.rad(60),
        math.rad(100),-math.rad(100),math.rad(140),-math.rad(140),math.pi}
    local best,bestScore=nil,math.huge
    local myFloor=findFloorAt(myPos,mobModel)
    for _,ang in ipairs(angles) do
        local c,s=math.cos(ang),math.sin(ang)
        local vec=Vector3.new(away.X*c-away.Z*s,0,away.X*s+away.Z*c)
        local sample=mobPos+vec*radius
        local floor=findFloorAt(sample,mobModel)
        if floor then
            local goal=Vector3.new(sample.X,floor.Y+2.7,sample.Z)
            local visible=los(goal,mobPos,mobModel)
            local direct=los(myPos,goal,mobModel)
                and groundCorridor(myPos,goal,mobModel)
            local heightPenalty=myFloor and math.abs(floor.Y-myFloor.Y)*2.5 or 0
            local score=horizontalDistance(myPos,goal)+(visible and 0 or 70)
                +(direct and -18 or 18)+heightPenalty
            if score<bestScore then best,bestScore=goal,score end
        end
    end
    if best then return best end
    -- Never manufacture an ungrounded destination over a cliff.
    local floor=findFloorAt(myPos,mobModel)
    if floor then return Vector3.new(myPos.X,floor.Y+2.7,myPos.Z) end
    return myPos
end
local function rotateFlat(v,radians)
    local c,s=math.cos(radians),math.sin(radians)
    return Vector3.new(v.X*c-v.Z*s,0,v.X*s+v.Z*c)
end
local function safeShortStep(from,goal,excluded)
    local diff=flat(goal-from)
    if diff.Magnitude<1 then return nil end
    local direction=diff.Unit
    local fromFloor=findFloorAt(from,excluded)
    if not fromFloor then return nil end
    local best,bestScore=nil,math.huge
    for _,ang in ipairs({0,math.rad(30),-math.rad(30),math.rad(60),-math.rad(60),
        math.rad(100),-math.rad(100)}) do
        for _,distance in ipairs({math.min(7,diff.Magnitude),3.5}) do
            local pt=from+rotateFlat(direction,ang)*distance
            local floor=findFloorAt(pt,excluded)
            if floor and math.abs(floor.Y-fromFloor.Y)<3.7 then
                local destination=Vector3.new(pt.X,floor.Y+2.7,pt.Z)
                if los(from,destination,excluded) and groundCorridor(from,destination,excluded) then
                    local closer=horizontalDistance(destination,goal)
                    local score=closer+math.abs(ang)*2.8
                    if score<bestScore then best,bestScore=destination,score end
                end
            end
        end
    end
    return best
end
local function safeRetreatPoint(from,enemyPos,enemy,needed)
    local away=flat(from-enemyPos)
    if away.Magnitude<0.2 then
        local character=player.Character
        local root=character and character:FindFirstChild("HumanoidRootPart")
        away=root and -flat(root.CFrame.LookVector) or Vector3.new(1,0,0)
    end
    away=away.Unit
    local fromFloor=findFloorAt(from,enemy)
    if not fromFloor then return nil end
    local best,bestScore=nil,-math.huge
    for _,distance in ipairs({math.clamp(needed,2.5,6.5),2.8,4.2}) do
        for _,ang in ipairs({0,math.rad(35),-math.rad(35),math.rad(70),-math.rad(70),
            math.rad(105),-math.rad(105),math.pi}) do
            local sample=from+rotateFlat(away,ang)*distance
            local floor=findFloorAt(sample,enemy)
            if floor and math.abs(floor.Y-fromFloor.Y)<3.3 then
                local destination=Vector3.new(sample.X,floor.Y+2.7,sample.Z)
                if los(from,destination,enemy) and groundCorridor(from,destination,enemy) then
                    local gain=horizontalDistance(destination,enemyPos)-horizontalDistance(from,enemyPos)
                    local score=gain*3-math.abs(ang)*1.8
                    if gain>0.6 and score>bestScore then best,bestScore=destination,score end
                end
            end
        end
    end
    return best
end
local function weaponCombatBounds()
    local kind=cfg.mobWeapon
    local reach=kind=="Sword" and math.min(cfg.attackRange,5.3) or cfg.attackRange
    local ideal=cfg.safeDistance
    if kind=="Bow" or kind=="Scepter" then
        ideal=math.max(ideal,math.min(11,reach-1))
    end
    ideal=math.clamp(ideal,2.3,math.max(2.3,reach-0.35))
    local minGap=math.max(1.8,ideal-0.9)
    return reach,ideal,minGap
end
local function currentHealthFraction(hum)
    -- Prefer explicit game's HUD health; ABOVE may show HP independently of Humanoid.Health.
    local guiRoot=player:FindFirstChildOfClass("PlayerGui")
    if guiRoot then
        for _,obj in ipairs(guiRoot:GetDescendants()) do
            if obj:IsA("TextLabel") then
                local txt=obj.Text
                local cur,max=txt:match("(%d+)%s*/%s*(%d+)%s*HP")
                if not cur and (obj.Name:lower():find("health",1,true)
                    or obj.Name:lower()=="hp") then
                    cur,max=txt:match("^%s*(%d+)%s*/%s*(%d+)%s*$")
                end
                cur,max=tonumber(cur),tonumber(max)
                if cur and max and max>0 and max<1e7 then
                    return math.clamp(cur/max,0,1),cur
                end
            end
        end
    end
    if hum and hum.MaxHealth>0 then
        return math.clamp(hum.Health/hum.MaxHealth,0,1),hum.Health
    end
    return nil,nil
end
local function clearNavigation()
    nav.generation=nav.generation+1
    if nav.blockedConnection then pcall(function()nav.blockedConnection:Disconnect()end)end
    nav.blockedConnection=nil
    nav.subject=nil;nav.waypoints=nil;nav.index=1;nav.goal=nil;nav.computing=false
    nav.lastPlan=0;nav.wanted=nil;nav.lastMoveGoal=nil;nav.lastMoveAt=0
    nav.lastProgressPosition=nil;nav.lastProgressAt=0;nav.failures=0;nav.retryNow=false
end
local function sendMove(humanoid,goal,force)
    local now=os.clock()
    if not force and nav.lastMoveGoal and
        horizontalDistance(nav.lastMoveGoal,goal)<2.5 and now-nav.lastMoveAt<1.35 then return end
    nav.lastMoveGoal=goal;nav.lastMoveAt=now
    humanoid:MoveTo(goal)
end
local function requestPath(start,goal,subject)
    local now=os.clock()
    if nav.computing or (now-nav.lastPlan < 1.25 and not nav.retryNow) then return end
    nav.lastPlan=now
    nav.retryNow=false
    nav.computing=true
    local generation=nav.generation
    task.spawn(function()
        local path,waypoints
        local ok=pcall(function()
            path=PathfindingService:CreatePath({
                AgentRadius=2,AgentHeight=5,AgentCanJump=true,WaypointSpacing=5,
            })
            path:ComputeAsync(start,goal)
            if path.Status==Enum.PathStatus.Success then waypoints=path:GetWaypoints() end
        end)
        if closed or not running or nav.generation~=generation or nav.subject~=subject then return end
        nav.computing=false
        if ok and waypoints and #waypoints>=2 then
            if nav.blockedConnection then pcall(function()nav.blockedConnection:Disconnect()end)end
            nav.waypoints=waypoints
            nav.index=2
            nav.goal=goal
            nav.blockedConnection=path.Blocked:Connect(function(idx)
                if nav.generation==generation and idx>=nav.index then nav.retryNow=true end
            end)
        else
            nav.waypoints=nil
            nav.goal=goal
        end
    end)
end
local function navMove(humanoid,root,goal,subject,exclude)
    if nav.subject~=subject then
        clearNavigation()
        nav.subject=subject
    end
    local now=os.clock()
    if not nav.lastProgressPosition then
        nav.lastProgressPosition=root.Position
        nav.lastProgressAt=now
    elseif horizontalDistance(nav.lastProgressPosition,root.Position)>0.85 then
        nav.lastProgressPosition=root.Position
        nav.lastProgressAt=now
        nav.failures=0
    elseif now-nav.lastProgressAt > 2.7 and horizontalDistance(root.Position,goal)>4 then
        nav.lastProgressAt=now
        nav.failures=nav.failures+1
        nav.retryNow=true
        nav.waypoints=nil
        humanoid.Jump=true
        if nav.failures>=3 then
            sendMove(humanoid,root.Position,true)
            return false,"Stuck: couldn't find a traversable route"
        end
    end

    local direct=horizontalDistance(root.Position,goal)<23
        and los(root.Position,goal,exclude)
        and groundCorridor(root.Position,goal,exclude)
    if direct then
        -- No path calculation is necessary in an unobstructed short corridor.
        sendMove(humanoid,goal,false)
        return true,"Direct"
    end
    if not nav.goal or horizontalDistance(nav.goal,goal)>8 or nav.retryNow or not nav.waypoints then
        requestPath(root.Position,goal,subject)
    end
    local wp
    if nav.waypoints then
        while nav.index<=#nav.waypoints do
            local candidate=nav.waypoints[nav.index]
            if horizontalDistance(candidate.Position,root.Position)<3.1
                and math.abs(candidate.Position.Y-root.Position.Y)<6 then
                nav.index=nav.index+1
            elseif nav.index<#nav.waypoints and
                horizontalDistance(root.Position,nav.waypoints[nav.index+1].Position)<12
                and los(root.Position,nav.waypoints[nav.index+1].Position,exclude) then
                nav.index=nav.index+1
            else
                break
            end
        end
        wp=nav.waypoints[nav.index]
    end
    if wp then
        if wp.Action==Enum.PathWaypointAction.Jump then humanoid.Jump=true end
        sendMove(humanoid,wp.Position,false)
        return true,"Waypoint "..tostring(nav.index)
    end
    if nav.computing then return false,"Calculating path" end
    -- A short safe sidestep prevents long stalls on rocks without walking off cliffs.
    local short=safeShortStep(root.Position,goal,exclude)
    if short and horizontalDistance(root.Position,short)>1.0 then
        sendMove(humanoid,short,false)
        return true,"Short safe step"
    end
    sendMove(humanoid,root.Position,false)
    return false,"No safe ground path; waiting"
end

-- ---------------- Teleporter return support ----------------
local function portalObjectName(inst)
    local parentName=inst.Parent and inst.Parent.Name or ""
    local generic=parentName:lower()
    if generic=="portals" or generic=="teleporters" or generic=="teleports" then parentName="" end
    return (inst.Name.." "..parentName):lower()
end
local function looksLikePortal(inst)
    if not (inst:IsA("Model") or inst:IsA("BasePart")) then return false end
    if inst:IsA("Model") and inst.Name:lower()=="portals" then return false end
    local text=portalObjectName(inst)
    return text:find("portal",1,true)~=nil or text:find("teleport",1,true)~=nil
        or text:find("gateway",1,true)~=nil
end
local function portalPart(obj)
    if obj:IsA("BasePart") then return obj end
    if obj:IsA("Model") then
        for _,n in ipairs({"Portal","Teleport","Center","Gate","Primary","Hitbox"}) do
            local p=obj:FindFirstChild(n,true)
            if p and p:IsA("BasePart") then return p end
        end
        return findRoot(obj)
    end
    return nil
end
local function scanPortals()
    local found,seen={},{}
    for _,inst in ipairs(Workspace:GetDescendants()) do
        if looksLikePortal(inst) then
            local object=inst
            if inst:IsA("BasePart") and inst.Parent and inst.Parent:IsA("Model")
                and looksLikePortal(inst.Parent) and inst.Parent.Name:lower()~="portals" then
                object=inst.Parent
            end
            if not seen[object] then
                local part=portalPart(object)
                if part then found[#found+1]={object=object,part=part} seen[object]=true end
            end
        end
    end
    portals=found
    lastPortalScan=os.clock()
    return found
end
local function assignedPortalName()
    return cfg.targetGroup=="Slime" and cfg.portalSlimeName or cfg.portalSkeletonName
end
local function matchingDestination(portal)
    local n=portalObjectName(portal.object)
    local full=portal.object:GetFullName()
    local assigned=assignedPortalName()
    if assigned~="" then
        if assigned==full then return 100 end
        if assigned==portal.object.Name then return 90 end
        return 0
    end
    if cfg.targetGroup=="Slime" then
        if n:find("slime",1,true) or n:find("wildland",1,true) then return 60 end
    else
        if n:find("ruins",1,true) or n:find("skeleton",1,true) then return 60 end
    end
    return 0
end
local function findReturnPortal(root)
    local best,bestScore=nil,-math.huge
    local assigned=assignedPortalName()
    local baseName=assigned~="" and assigned:match("[^%.]+$") or nil
    local sameNamed=0
    if baseName then
        for _,candidate in ipairs(portals) do
            if candidate.object.Name==baseName then sameNamed=sameNamed+1 end
        end
    end
    for _,item in ipairs(portals) do
        if item.part.Parent then
            local score=matchingDestination(item)
            if score==0 and sameNamed==1 and item.object.Name==baseName then
                score=80 -- account-specific full path changed; unique name survives
            end
            if score>0 then
                local dist=(item.part.Position-root.Position).Magnitude
                if dist<=350 and score*10-dist>bestScore then
                    best,bestScore=item,score*10-dist
                end
            end
        end
    end
    if best then return best end
    -- Multi-hop recovery: Home island -> Hub, then Hub -> Slime/Ruins.
    -- Hub step is NEVER guessed; must be explicitly bound by user.
    if cfg.portalHubName~="" then
        local hubBaseName=cfg.portalHubName:match("[^%.]+$")
        local hubMatches=0
        for _,item in ipairs(portals) do
            if item.object.Name==hubBaseName then hubMatches=hubMatches+1 end
        end
        local hubBest,hubDistance=nil,math.huge
        for _,item in ipairs(portals) do
            local full=item.object:GetFullName()
            local matches=full==cfg.portalHubName
                or (hubMatches==1 and item.object.Name==hubBaseName)
            local dist=(item.part.Position-root.Position).Magnitude
            if matches and dist<350 and dist<hubDistance then
                hubBest,hubDistance=item,dist
            end
        end
        return hubBest
    end
    return nil
end
local function bindNearestPortal(group)
    local _,_,root=getCharacter()
    if not root then setStatus("Stand near a teleporter first") return end
    scanPortals()
    local closest,dist=nil,65
    for _,item in ipairs(portals) do
        local d=(item.part.Position-root.Position).Magnitude
        if d<dist then closest,dist=item,d end
    end
    if not closest then
        setStatus("No portal identified nearby; need portal model details")
        return
    end
    local key=group=="Slime" and "portalSlimeName"
        or (group=="Skeleton" and "portalSkeletonName" or "portalHubName")
    cfg[key]=closest.object:GetFullName()
    changed(true)
    setStatus("Bound "..group.." to "..closest.object.Name.." ("..math.floor(dist).." st)")
    print("[RHYE ABOVE PORTAL] Bound "..group.." => "..cfg[key])
end
local function portalPrompt(item)
    local p=item.object:FindFirstChildWhichIsA("ProximityPrompt",true)
    if p and p.Enabled then return p end
    if item.object.Parent and item.object.Parent:IsA("Model") then
        p=item.object.Parent:FindFirstChildWhichIsA("ProximityPrompt",true)
        if p and p.Enabled then return p end
    end
    return nil
end
local function triggerPortal(item)
    if os.clock()-portalInteractAt<4.5 then return end
    portalInteractAt=os.clock()
    local prompt=portalPrompt(item)
    if not prompt then
        setStatus("Walking into portal "..item.object.Name.." (touch trigger)")
        return
    end
    if type(fireproximityprompt)=="function" then
        local ok=pcall(fireproximityprompt,prompt)
        if ok then setStatus("Triggered portal prompt: "..item.object.Name) return end
    end
    local ok=pcall(function()
        prompt:InputHoldBegin()
        task.delay(math.max(0.15,prompt.HoldDuration)+0.1,function()
            pcall(function()prompt:InputHoldEnd()end)
        end)
    end)
    if ok then setStatus("Using portal prompt: "..item.object.Name) end
end

local function stopHunt()
    running=false
    currentTarget=nil
    activePortal=nil
    recovering=false
    lastRetreatGoal=nil
    clearNavigation()
    local _,hum,root=getCharacter()
    if hum and root then hum:MoveTo(root.Position) end
    if farmButton and farmButton.Parent then farmButton.Text="START AUTO HUNT" end
    setStatus("Auto Hunt stopped")
end
local function shutdown()
    if closed then return end
    stopHunt()
    if cfg.autoSave then writeConfig(true) end
    closed=true
    for _,conn in ipairs(connections) do pcall(function()conn:Disconnect()end)end
    if gui then pcall(function()gui:Destroy()end)end
end
env.RHYE_ABOVE_SHUTDOWN=shutdown


-- ---------------------------------------------------------------
-- GUI (drawn with Roblox Instances; editable and independent of other hubs)
-- ---------------------------------------------------------------
local colors = {
    bg = Color3.fromRGB(18, 19, 25),
    sidebar = Color3.fromRGB(28, 30, 39),
    surface = Color3.fromRGB(38, 40, 51),
    panel = Color3.fromRGB(31, 33, 43),
    line = Color3.fromRGB(59, 62, 75),
    text = Color3.fromRGB(238, 241, 247),
    muted = Color3.fromRGB(165, 169, 181),
    blue = Color3.fromRGB(31, 151, 255),
    green = Color3.fromRGB(46, 203, 122),
    off = Color3.fromRGB(91, 95, 109),
    red = Color3.fromRGB(240, 89, 111),
}
local function create(className,props,parent)
    local inst = Instance.new(className)
    for property,value in pairs(props or {}) do inst[property] = value end
    inst.Parent = parent
    return inst
end
local function rounded(frame,amount)
    create("UICorner",{CornerRadius=UDim.new(0,amount or 10)},frame)
end
local function border(frame,thickness)
    create("UIStroke",{Color=colors.line, Thickness=thickness or 1, ApplyStrokeMode=Enum.ApplyStrokeMode.Border},frame)
end
local function label(parent,text,size,weight,color)
    return create("TextLabel",{
        BackgroundTransparency=1, Text=tostring(text), TextColor3=color or colors.text,
        Font=weight and Enum.Font.GothamBold or Enum.Font.Gotham,
        TextSize=size or 13, TextXAlignment=Enum.TextXAlignment.Left,
        TextYAlignment=Enum.TextYAlignment.Center,
        TextTruncate=Enum.TextTruncate.AtEnd,
    },parent)
end
local function button(parent,text,size)
    local b = create("TextButton",{
        BackgroundColor3=colors.surface, Text=tostring(text), TextColor3=colors.text,
        Font=Enum.Font.GothamMedium, TextSize=size or 12, AutoButtonColor=true,
        BorderSizePixel=0,
    },parent)
    rounded(b,9)
    return b
end

gui = create("ScreenGui",{
    Name="RHYE_ABOVE_AutoHunt_V3", ResetOnSpawn=false, IgnoreGuiInset=true,
    ZIndexBehavior=Enum.ZIndexBehavior.Sibling, DisplayOrder=10020,
},player:WaitForChild("PlayerGui"))
local main = create("Frame",{
    Name="Window", BackgroundColor3=colors.bg, BorderSizePixel=0,
    Size=UDim2.fromOffset(725,528), AnchorPoint=Vector2.new(0.5,0.5),
    Position=UDim2.new(0.5,0,0.5,0), Active=true,
},gui)
rounded(main,18); border(main,1)
local scale = create("UIScale",{Scale=1},main)
local function resizeScale()
    local view = Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize or Vector2.new(1280,720)
    scale.Scale = math.clamp(math.min(view.X/755,view.Y/565),0.55,1)
end
resizeScale()
remember(Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(resizeScale))
if Workspace.CurrentCamera then
    remember(Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(resizeScale))
end

local sidebar = create("Frame",{
    BackgroundColor3=colors.sidebar, BorderSizePixel=0,
    Position=UDim2.fromOffset(7,7),Size=UDim2.new(0,65,1,-14),
},main)
rounded(sidebar,14)
local circles = {Color3.fromRGB(255,94,84), Color3.fromRGB(255,193,67), Color3.fromRGB(45,204,113)}
for i,col in ipairs(circles) do
    local circle=create("Frame",{Size=UDim2.fromOffset(10,10),Position=UDim2.fromOffset(10+(i-1)*15,13),BackgroundColor3=col,BorderSizePixel=0},sidebar)
    rounded(circle,10)
end
local brand=label(sidebar,"R",31,true,colors.green)
brand.Size=UDim2.fromOffset(48,50)
brand.Position=UDim2.fromOffset(8,45)
brand.TextXAlignment=Enum.TextXAlignment.Center
local navCombat=button(sidebar,"⚔",25)
navCombat.Size=UDim2.fromOffset(46,44)
navCombat.Position=UDim2.fromOffset(10,111)
navCombat.BackgroundColor3=colors.blue
local navInfo=button(sidebar,"i",22)
navInfo.Size=UDim2.fromOffset(46,44)
navInfo.Position=UDim2.fromOffset(10,162)
local hideNav=button(sidebar,"−",21)
hideNav.Size=UDim2.fromOffset(46,39)
hideNav.Position=UDim2.new(0,10,1,-52)

local header=label(main,"RHYE Hub  /  Combat",18,true)
header.Position=UDim2.fromOffset(93,19)
header.Size=UDim2.fromOffset(370,25)
local subtitle=label(main,"ABOVE · Reliable Detect + Survival V3",11,false,colors.muted)
subtitle.Position=UDim2.fromOffset(94,45)
subtitle.Size=UDim2.fromOffset(370,20)
local close=button(main,"×",24)
close.Position=UDim2.new(1,-43,0,16)
close.Size=UDim2.fromOffset(29,29)
close.BackgroundColor3=colors.bg
remember(close.MouseButton1Click:Connect(shutdown))

local contentArea=create("Frame",{
    BackgroundTransparency=1,Position=UDim2.fromOffset(91,82),
    Size=UDim2.new(1,-109,1,-153),
},main)
local scroll=create("ScrollingFrame",{
    Name="CombatSettings",BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1), ScrollBarThickness=4,
    ScrollBarImageColor3=colors.line,CanvasSize=UDim2.fromOffset(0,0),
},contentArea)
local layout=create("UIListLayout",{Padding=UDim.new(0,8),SortOrder=Enum.SortOrder.LayoutOrder},scroll)
remember(layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    scroll.CanvasSize=UDim2.fromOffset(0,layout.AbsoluteContentSize.Y+14)
end))
local infoFrame=create("Frame",{
    BackgroundTransparency=1,Size=UDim2.fromScale(1,1),Visible=false,
},contentArea)
local infoLabel=label(infoFrame,"RHYE HUB  ·  ABOVE",23,true,colors.green)
infoLabel.Size=UDim2.new(1,0,0,40)
local infoBody=label(infoFrame,
    "AUTO HUNT V3 · DETECTION + COMBAT SPACING\n\n1. Target: Slime (all kinds) OR Skeleton (all kinds).\n2. Adjust range, weapon and speed, then START.\n3. If home-return fails, bind HOME->HUB portal at Home,\n   then bind SLIME/RUINS portal at the Hub (if needed).\n4. All accounts on the same Potassium workspace share\n   RHYE_Hub/ABOVE_Global_Config.json.\n\nAnti-AFK: ON by default; success depends on executor.\nNo forced remote attacks or server combat bypass.\nStop or close with UI buttons.",
    13,false,colors.muted)
infoBody.Size=UDim2.new(1,-18,1,-60)
infoBody.Position=UDim2.fromOffset(0,50)
infoBody.TextWrapped=true
infoBody.TextYAlignment=Enum.TextYAlignment.Top

local order=0
local function nextOrder() order=order+1; return order end
local function section(text)
    local t=label(scroll,text,12,true,colors.muted)
    t.Size=UDim2.new(1,-10,0,24)
    t.LayoutOrder=nextOrder()
    return t
end
local function settingRow(title,description,height)
    local frame=create("Frame",{
        Name=title,Size=UDim2.new(1,-8,0,height or 59),
        BackgroundColor3=colors.panel,BorderSizePixel=0,LayoutOrder=nextOrder(),
    },scroll)
    rounded(frame,11);border(frame,1)
    local titleLabel=label(frame,title,13,true)
    titleLabel.Position=UDim2.fromOffset(14,7)
    titleLabel.Size=UDim2.new(1,-210,0,21)
    local desc=label(frame,description,10,false,colors.muted)
    desc.Position=UDim2.fromOffset(14,29)
    desc.Size=UDim2.new(1,-204,0,19)
    desc.TextWrapped=false
    return frame
end
local function toggleRow(title,description,key)
    local frame=settingRow(title,description)
    local control=button(frame,"",12)
    control.Size=UDim2.fromOffset(54,27)
    control.Position=UDim2.new(1,-69,0,16)
    local function update()
        control.BackgroundColor3=cfg[key] and colors.blue or colors.off
        control.Text=cfg[key] and "ON" or "OFF"
    end
    update()
    remember(control.MouseButton1Click:Connect(function()
        cfg[key]=not cfg[key];update()
        changed(key=="autoSave")
    end))
    return control
end
local openPicker
local function inputRow(title,description,key,allowPicker)
    local frame=settingRow(title,description)
    local input=create("TextBox",{
        BackgroundColor3=colors.surface,TextColor3=colors.text,Font=Enum.Font.Gotham,
        TextSize=12,Text=cfg[key],PlaceholderText="Name, name, ...",
        BorderSizePixel=0,ClearTextOnFocus=false,
        Size=UDim2.fromOffset(allowPicker and 137 or 179,31),
        Position=UDim2.new(1,allowPicker and -199 or -194,0,13),
    },frame)
    rounded(input,8)
    remember(input.FocusLost:Connect(function()
        cfg[key]=input.Text
        changed()
        refreshNPCs()
    end))
    if allowPicker then
        local pick=button(frame,"LIST",10)
        pick.Size=UDim2.fromOffset(46,31)
        pick.Position=UDim2.new(1,-57,0,13)
        remember(pick.MouseButton1Click:Connect(function()
            openPicker(key,input)
        end))
    end
    return input
end
local function cycleRow(title,description,key,options)
    local frame=settingRow(title,description)
    local control=button(frame,"",12)
    control.Size=UDim2.fromOffset(175,30)
    control.Position=UDim2.new(1,-191,0,15)
    local function update() control.Text=tostring(cfg[key]) .. "  ▾" end
    update()
    remember(control.MouseButton1Click:Connect(function()
        local idx=1
        for i,v in ipairs(options) do if v==cfg[key] then idx=i break end end
        cfg[key]=options[(idx%#options)+1]
        if key=="targetGroup" then
            currentTarget=nil;activePortal=nil;clearNavigation()
            lastEnemySeen=os.clock()-cfg.returnDelay
        end
        update()
        changed()
    end))
    return control
end
local function sliderRow(title,description,key,minValue,maxValue,increment,suffix)
    local frame=settingRow(title,description,66)
    local line=create("Frame",{
        BackgroundColor3=colors.off,BorderSizePixel=0,
        Position=UDim2.new(1,-220,0,31),Size=UDim2.fromOffset(136,5),
    },frame);rounded(line,5)
    local fill=create("Frame",{BackgroundColor3=colors.blue,BorderSizePixel=0,Size=UDim2.fromScale(0,1)},line)
    rounded(fill,5)
    local nub=create("Frame",{
        BackgroundColor3=Color3.new(1,1,1),BorderSizePixel=0,
        Size=UDim2.fromOffset(17,17),AnchorPoint=Vector2.new(0.5,0.5),
        Position=UDim2.fromScale(0,0.5),
    },line);rounded(nub,20)
    local valueText=label(frame,"",11,true)
    valueText.Position=UDim2.new(1,-74,0,18)
    valueText.Size=UDim2.fromOffset(65,33)
    valueText.TextXAlignment=Enum.TextXAlignment.Center
    local function update()
        local pct=(cfg[key]-minValue)/(maxValue-minValue)
        fill.Size=UDim2.fromScale(pct,1)
        nub.Position=UDim2.fromScale(pct,0.5)
        valueText.Text=string.format("%g%s",cfg[key],suffix or "")
    end
    local dragging=false
    local function fromMouse(x)
        local pct=math.clamp((x-line.AbsolutePosition.X)/line.AbsoluteSize.X,0,1)
        cfg[key]=math.clamp(math.floor((minValue+(maxValue-minValue)*pct)/increment+0.5)*increment,minValue,maxValue)
        cfg[key]=math.floor(cfg[key]*100+0.5)/100
        update()
        changed()
    end
    remember(line.InputBegan:Connect(function(input)
        if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then
            dragging=true;fromMouse(input.Position.X)
        end
    end))
    remember(nub.InputBegan:Connect(function(input)
        if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then
            dragging=true;fromMouse(input.Position.X)
        end
    end))
    remember(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType==Enum.UserInputType.MouseMovement or input.UserInputType==Enum.UserInputType.Touch) then
            fromMouse(input.Position.X)
        end
    end))
    remember(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then dragging=false end
    end))
    update()
    return frame
end


section("AUTO HUNT • ONLY TWO MONSTER GROUPS")
toggleRow("Farm Mobs","Enable hunting the selected category.","farmMobs")
cycleRow("Target Mobs","Slime = ALL slimes; Skeleton = ALL skeletons.","targetGroup",{"Slime","Skeleton"})
cycleRow("Mob Weapon","Equip via Tool when available; otherwise use hotbar.","mobWeapon",{"Sword","Bow","Scepter","Equipped"})

section("ATTACK & SMOOTH MOVEMENT")
sliderRow("Attack Range","Max allowed distance; actual sword reach is about 5.4.","attackRange",2,35,0.5," st")
toggleRow("Auto Combat Spacing","Back away when mobs get too close; resume attacking.","autoKite")
sliderRow("Safe Combat Distance","Preferred gap for Sword; Bow/Scepter prefer longer range.","safeDistance",2.5,20,0.5," st")
toggleRow("Low HP Survival","Retreat and pause attack until HP recovers.","lowHealthSafety")
sliderRow("Low HP Threshold","Start defensive retreat under this percent HP.","lowHealthThreshold",15,60,5,"%")
sliderRow("Attack Interval","Added delay, does not bypass game cooldown.","attackInterval",0.15,2,0.05," s")
sliderRow("Search Radius","Search visible monsters within this radius.","maxSearch",50,500,10," st")
sliderRow("Walk Speed","Client Humanoid speed while hunting; may be limited.","walkSpeed",12,32,1,"")
cycleRow("Attack Method","Mouse = game LMB; Tool = Tool:Activate().","attackMode",{"Mouse","Tool","Auto"})
toggleRow("Auto Chase","Stable waypoint movement + walls/path rechecks.","autoChase")
toggleRow("Auto Equip","Try equipping a matching Roblox Tool.","autoEquip")
toggleRow("Auto Aim","Aim camera at your target when attacking.","autoAim")
local mobScanRow=settingRow("Mob Detection Debug","Re-scan nearby mobs; print identified models to Developer Console (F9).",61)
local mobScanBtn=button(mobScanRow,"SCAN MOBS (F9)",11)
mobScanBtn.Size=UDim2.fromOffset(146,29)
mobScanBtn.Position=UDim2.new(1,-161,0,16)
remember(mobScanBtn.MouseButton1Click:Connect(function()
    task.spawn(function()
        refreshNPCs()
        local _,_,root=getCharacter()
        if root then
            lastNearScan=0
            scanNearbyNPCs(root)
        end
        local count=0
        print("[RHYE ABOVE MOBS] --- scan --- total cached: "..tostring(#npcCache))
        for _,npc in ipairs(npcCache) do
            local part=findRoot(npc)
            if part and root then
                local d=(part.Position-root.Position).Magnitude
                if d<150 and count<35 then
                    count=count+1
                    local hp,known=healthInfo(npc)
                    print("[RHYE ABOVE MOBS]",categoryOf(npc) or "Unknown",
                        npc:GetFullName(),"distance",math.floor(d),
                        "hp",known and hp or "unknown")
                end
            end
        end
        setStatus("Mob scan: "..tostring(#npcCache).." found. See F9 logs")
    end)
end))

section("AUTO RETURN VIA GAME PORTAL")
toggleRow("Auto Return to Hunting Map","Return only when no monsters appear and a matching portal is visible.","autoReturn")
sliderRow("Return Wait","Seconds without a target before trying the portal.","returnDelay",8,45,1," s")
local portalRow=settingRow("Bind Teleporter","Stand near the intended portal and press its BIND button.",139)
local bindSlime=button(portalRow,"BIND SLIME PORTAL",11)
bindSlime.Size=UDim2.fromOffset(167,31)
bindSlime.Position=UDim2.fromOffset(14,58)
local bindSkeleton=button(portalRow,"BIND RUINS / SKELETON",11)
bindSkeleton.Size=UDim2.fromOffset(183,31)
bindSkeleton.Position=UDim2.fromOffset(191,58)
remember(bindSlime.MouseButton1Click:Connect(function()bindNearestPortal("Slime")end))
remember(bindSkeleton.MouseButton1Click:Connect(function()bindNearestPortal("Skeleton")end))
local bindHub=button(portalRow,"BIND HOME → HUB PORTAL",11)
bindHub.Size=UDim2.fromOffset(217,29)
bindHub.Position=UDim2.fromOffset(14,97)
remember(bindHub.MouseButton1Click:Connect(function()bindNearestPortal("Hub")end))
local portalScanRow=settingRow("Portal Diagnostics","Print detected portal objects and distances to F9 console.",65)
local portalScanButton=button(portalScanRow,"SCAN PORTALS",11)
portalScanButton.Size=UDim2.fromOffset(147,30)
portalScanButton.Position=UDim2.new(1,-163,0,16)
remember(portalScanButton.MouseButton1Click:Connect(function()
    scanPortals()
    local _,_,root=getCharacter()
    print("[RHYE ABOVE PORTAL] --- "..tostring(#portals).." candidates ---")
    for _,p in ipairs(portals) do
        local dist=root and math.floor((p.part.Position-root.Position).Magnitude) or -1
        print("[RHYE ABOVE PORTAL] ",p.object:GetFullName()," distance:",dist,
            " prompt:",portalPrompt(p) and portalPrompt(p).Name or "none")
    end
    setStatus("Portal scan: "..#portals.." candidates (F9 output)")
end))

section("PERSISTENCE & IDLE")
toggleRow("Anti AFK","ON by default; sends idle-input pulse (executor dependent).","autoAfk")
toggleRow("Auto Save Config","Automatically save every changed setting to workspace.","autoSave")
toggleRow("Auto Start on Script Load","Resume Auto Hunt automatically after loading hub.","autoStart")

local footer=create("Frame",{
    BackgroundColor3=colors.bg,BorderSizePixel=0,
    Position=UDim2.new(0,91,1,-69),Size=UDim2.new(1,-108,0,61),
},main)
create("Frame",{BackgroundColor3=colors.line,BorderSizePixel=0,Size=UDim2.new(1,0,0,1)},footer)
statusText=label(footer,lastStatus,11,false,colors.muted)
statusText.Size=UDim2.new(1,-220,0,18)
statusText.Position=UDim2.fromOffset(2,4)
targetText=label(footer,"Target: none",11,true,colors.text)
targetText.Size=UDim2.new(1,-220,0,18)
targetText.Position=UDim2.fromOffset(2,25)
local saveButton=button(footer,"SAVE",12)
saveButton.Size=UDim2.fromOffset(69,34)
saveButton.Position=UDim2.new(1,-228,0,13)
remember(saveButton.MouseButton1Click:Connect(function()writeConfig(false)end))
farmButton=button(footer,"START AUTO HUNT",12)
farmButton.BackgroundColor3=colors.blue
farmButton.Size=UDim2.fromOffset(149,34)
farmButton.Position=UDim2.new(1,-151,0,13)
local function startHunt()
    if running then return end
    if not cfg.farmMobs then setStatus("Enable Farm Mobs first") return end
    running=true
    currentTarget=nil
    lastEnemySeen=os.clock()-cfg.returnDelay
    recovering=false
    lastHealthReading=nil
    lastTargetSwitchAt=0
    nextAttack=0
    clearNavigation()
    farmButton.Text="STOP AUTO HUNT"
    setStatus("Auto Hunt V3 started: "..cfg.targetGroup)
end
remember(farmButton.MouseButton1Click:Connect(function()
    if running then stopHunt() else startHunt() end
end))

local minimized=false
local floating=button(gui,"R",22)
floating.BackgroundColor3=colors.green
floating.TextColor3=colors.bg
floating.Size=UDim2.fromOffset(48,48)
floating.Position=UDim2.new(0,18,0.35,0)
floating.Visible=false
remember(floating.MouseButton1Click:Connect(function()
    minimized=false;main.Visible=true;floating.Visible=false
end))
remember(hideNav.MouseButton1Click:Connect(function()
    minimized=true;main.Visible=false;floating.Visible=true
end))
local function showPage(combat)
    scroll.Visible=combat;infoFrame.Visible=not combat
    navCombat.BackgroundColor3=combat and colors.blue or colors.surface
    navInfo.BackgroundColor3=not combat and colors.blue or colors.surface
    header.Text=combat and "RHYE Hub  /  Combat" or "RHYE Hub  /  Info"
end
remember(navCombat.MouseButton1Click:Connect(function()showPage(true)end))
remember(navInfo.MouseButton1Click:Connect(function()showPage(false)end))

-- Drag window from header only.
local windowDragging=false
local dragStart,positionStart
remember(main.InputBegan:Connect(function(input)
    if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then
        local p=input.Position
        local origin=main.AbsolutePosition
        if p.Y-origin.Y<76 and p.X-origin.X>75 and p.X-origin.X<main.AbsoluteSize.X-43 then
            windowDragging=true;dragStart=p;positionStart=main.Position
        end
    end
end))
remember(UserInputService.InputChanged:Connect(function(input)
    if windowDragging and (input.UserInputType==Enum.UserInputType.MouseMovement or input.UserInputType==Enum.UserInputType.Touch) then
        local d=input.Position-dragStart
        main.Position=UDim2.new(positionStart.X.Scale,positionStart.X.Offset+d.X,
            positionStart.Y.Scale,positionStart.Y.Offset+d.Y)
    end
end))
remember(UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then
        windowDragging=false
    end
end))

-- ---------------- Runtime ----------------
refreshNPCs()
scanPortals()
if not loadedConfig and cfg.autoSave then scheduleSave(true) end
if cfg.autoStart and cfg.farmMobs then startHunt() end

remember(Workspace.DescendantAdded:Connect(function(item)
    if closed then return end
    if (item:IsA("Model") or item:IsA("BasePart")) and categoryOf(item) then
        task.delay(0.25,function()
            if closed or not item:IsDescendantOf(Workspace) then return end
            addNPC(item)
        end)
    elseif (item:IsA("Model") or item:IsA("BasePart")) and looksLikePortal(item) then
        lastPortalScan=0
    end
end))
remember(player.CharacterAdded:Connect(function()
    currentTarget=nil
    activePortal=nil
    lastEnemySeen=os.clock()-cfg.returnDelay
    recovering=false
    lastRetreatGoal=nil
    lastHealthReading=nil
    measuredHealthRatio=nil
    clearNavigation()
end))

-- Anti-AFK: automatic, enabled by default, even while Auto Hunt is paused.
-- An executor that disallows virtual input may still get the 20-minute kick.
local lastAfkPulse=os.clock()
local function antiAfkPulse()
    if closed or not cfg.autoAfk then return end
    lastAfkPulse=os.clock()
    local ok=pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new(0,0))
    end)
    if not ok then
        warn("[RHYE ABOVE] Anti-AFK VirtualUser unavailable in this executor")
    end
end
remember(player.Idled:Connect(function()
    antiAfkPulse()
end))
task.spawn(function()
    while not closed do
        task.wait(55)
        if cfg.autoAfk and os.clock()-lastAfkPulse>420 then antiAfkPulse() end
    end
end)

-- Periodic repair handles NPC streaming and renamed/late-loaded instances.
task.spawn(function()
    while not closed do
        task.wait(1.5)
        if os.clock()-lastScan>5 then pcall(refreshNPCs) end
        if cfg.autoReturn and os.clock()-lastPortalScan>10 then pcall(scanPortals) end
    end
end)

local lastMovementSpeedSet=0
local lastApproachTarget,approachCache,approachAt,mobCachePos=nil,nil,0,nil
local lastPortalFailureAt=0

task.spawn(function()
    while not closed do
        task.wait(0.17)
        if not running then continue end
        local character,hum,root=getCharacter()
        if not character then
            setStatus("Waiting for character / respawn")
            continue
        end
        local now=os.clock()
        if now-lastMovementSpeedSet>1.8 then
            if hum.WalkSpeed+0.5<cfg.walkSpeed then
                -- Never lower a faster sprint or legitimate player speed.
                pcall(function()hum.WalkSpeed=cfg.walkSpeed end)
            end
            lastMovementSpeedSet=now
        end
        scanNearbyNPCs(root)
        if now-lastHealthCheck>0.65 then
            lastHealthCheck=now
            local ratio,absolute=currentHealthFraction(hum)
            if ratio and absolute and lastHealthReading and absolute<lastHealthReading-0.1 then
                lastDamageAt=now
            end
            measuredHealthRatio,measuredCurrentHealth=ratio,absolute
            lastHealthReading=absolute
        end
        local target=chooseTarget(root)
        if target then
            lastEnemySeen=now
            if currentTarget~=target then
                currentTarget=target
                lastTargetSwitchAt=now
                activePortal=nil
                clearNavigation()
                nextAttack=0
                lastApproachTarget=nil
            end
            local part=findRoot(target)
            if not part then
                currentTarget=nil
                continue
            end
            local distance=(part.Position-root.Position).Magnitude
            local hDistance=horizontalDistance(part.Position,root.Position)
            local hp,known=healthInfo(target)
            targetText.Text=string.format("Target: %s  ·  %.1f st%s",target.Name,distance,
                known and string.format("  ·  HP %.0f",hp) or "")
            local tool=equipWeapon(character,hum,cfg.mobWeapon)
            local attackReach,idealGap,tooClose=weaponCombatBounds()
            local inRange=distance<=attackReach and los(root.Position,part.Position,target)

            -- A critical HP state is more important than farming: back away, pause combat.
            if cfg.lowHealthSafety and measuredHealthRatio then
                if measuredHealthRatio <= cfg.lowHealthThreshold/100 then recovering=true end
                if recovering and measuredHealthRatio >= math.max(0.60,cfg.lowHealthThreshold/100+0.23) then
                    recovering=false
                end
            else
                recovering=false
            end
            local recentHit=(now-lastDamageAt<1.4)
            local retreat=cfg.autoKite and (hDistance<tooClose
                or (recentHit and hDistance<attackReach+3))
            if recovering then retreat=true end

            if retreat then
                local required=math.max(idealGap-hDistance+0.8,2.8)
                if recovering then required=math.max(required,6.5) end
                if recentHit then required=math.max(required,4.5) end
                if lastRetreatEnemy~=target or not lastRetreatGoal
                    or now-lastRetreatAt>0.72
                    or horizontalDistance(root.Position,lastRetreatGoal)<1.2 then
                    lastRetreatGoal=safeRetreatPoint(root.Position,part.Position,target,required)
                    lastRetreatEnemy=target
                    lastRetreatAt=now
                end
                if lastRetreatGoal then
                    local success,info=navMove(hum,root,lastRetreatGoal,target,target)
                    if not success and nav.failures>=3 then
                        clearNavigation()
                        lastRetreatGoal=nil
                    end
                    setStatus(recovering and "LOW HP: retreating; combat paused"
                        or (success and "Kiting "..target.Name.." ["..info.."]"
                        or "Kiting: no safe route, avoid cliff"))
                else
                    -- No blindly crossing water, cliff, or wall for an impossible dodge.
                    if nav.subject then clearNavigation();hum:MoveTo(root.Position) end
                    setStatus("No safe dodge point (cliff / wall). Avoiding unsafe movement")
                end
                if not recovering and inRange and now>=nextAttack then
                    nextAttack=now+cfg.attackInterval
                    attackTarget(part,tool)
                end
            elseif inRange then
                lastRetreatGoal=nil
                if nav.subject then
                    clearNavigation()
                    hum:MoveTo(root.Position)
                end
                if now>=nextAttack then
                    nextAttack=now+cfg.attackInterval
                    local ok,method=attackTarget(part,tool)
                    setStatus(ok and ("Attacking "..target.Name.." ["..method.."]")
                        or ("Attack input unavailable: "..method))
                end
            elseif cfg.autoChase then
                lastRetreatGoal=nil
                if lastApproachTarget~=target or not approachCache or now-approachAt>1.0
                    or (mobCachePos and horizontalDistance(part.Position,mobCachePos)>3) then
                    approachCache=approachPoint(root.Position,part,target,attackReach)
                    approachAt=now
                    lastApproachTarget=target
                    mobCachePos=part.Position
                end
                local success,info=navMove(hum,root,approachCache,target,target)
                if not success and nav.failures>=3 then
                    blocked[target]=now+5
                    currentTarget=nil
                    clearNavigation()
                    setStatus("Route blocked near "..target.Name.."; trying others")
                elseif not success then
                    setStatus("Path to "..target.Name..": "..info)
                else
                    setStatus("Chasing "..target.Name.." ["..info.."]")
                end
            else
                setStatus("Target outside actual Attack Range: "..target.Name)
            end
        else
            currentTarget=nil
            lastApproachTarget=nil
            lastRetreatGoal=nil
            targetText.Text="Target: none ("..cfg.targetGroup..")"
            if recovering and cfg.lowHealthSafety and measuredHealthRatio
                and measuredHealthRatio<math.max(0.60,cfg.lowHealthThreshold/100+0.23) then
                if nav.subject then clearNavigation();hum:MoveTo(root.Position) end
                setStatus("LOW HP: wait for recovery before travelling")
                continue
            end
            recovering=false
            if not cfg.autoReturn then
                if nav.subject then clearNavigation();hum:MoveTo(root.Position) end
                setStatus("No visible "..cfg.targetGroup.."; waiting for respawn")
                continue
            end
            if now-lastEnemySeen<cfg.returnDelay then
                if nav.subject then clearNavigation();hum:MoveTo(root.Position) end
                setStatus("Waiting for new monsters ("..math.floor(cfg.returnDelay-(now-lastEnemySeen)).."s)")
                continue
            end
            -- Return is only attempted with a named/bound destination portal.
            -- Never choose an arbitrary portal when destination is unknown.
            local portal=findReturnPortal(root)
            if not portal then
                if nav.subject then clearNavigation();hum:MoveTo(root.Position) end
                setStatus("No destination portal found. Bind HOME->HUB / "..cfg.targetGroup..".")
                continue
            end
            if activePortal~=portal.object then
                activePortal=portal.object
                clearNavigation()
                portalArrivalAt=0
                portalInteractAt=0
            end
            local portalPos=portal.part.Position
            local dist=(portalPos-root.Position).Magnitude
            targetText.Text=string.format("Returning: %s  ·  %.0f st",portal.object.Name,dist)
            if dist<=9 then
                if portalArrivalAt==0 then portalArrivalAt=now end
                triggerPortal(portal)
                -- Touch-style portals require walking into the physical trigger.
                if dist>2.7 then sendMove(hum,portalPos,false) end
                if now-portalArrivalAt>17 and now-lastPortalFailureAt>15 then
                    lastPortalFailureAt=now
                    setStatus("Portal did not travel. Need a portal video / binding check.")
                end
            else
                portalArrivalAt=0
                local success,info=navMove(hum,root,portalPos,portal.object,portal.object)
                if not success and nav.failures>=3 then
                    setStatus("Cannot reach portal "..portal.object.Name.."; check route")
                    clearNavigation()
                elseif not success then
                    setStatus("Return path: "..info)
                else
                    setStatus("Auto Return via "..portal.object.Name.." ["..info.."]")
                end
            end
        end
    end
end)

setStatus(loadedConfig and "Loaded shared config | "..cfg.targetGroup.." | Anti-AFK "..(cfg.autoAfk and "ON" or "OFF")
    or "Ready | Shared config | Anti-AFK ON")
print("[RHYE ABOVE] V3 Reliable Hunt loaded. Shared config: "..CONFIG_FILE)
print("[RHYE ABOVE] Group: "..cfg.targetGroup.."  AutoReturn: "..tostring(cfg.autoReturn).."  AutoAFK: "..tostring(cfg.autoAfk))
