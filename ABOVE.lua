--[[
 RHYE Hub | ABOVE Auto Hunt V9.0 — False Arrival + Target Recovery Fix
 PlaceId: 124357835578554

 Community client-side helper. Uses visible NPC models, PathfindingService,
 standard Tool / mouse input, and detectable in-world teleporter interactions.
 No arbitrary server RemoteEvent calls, no damage overrides, no noclip.
 V8 uses post-ControlModule Humanoid:Move while navigating, instead of relying
 exclusively on MoveTo (which may be overridden by in-game client controls).
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
    autoKite = true, -- master toggle; Sword is excluded by default via spacingMode
    spacingMode = "Ranged Only", -- Off / Ranged Only / All Weapons; avoids Sword kite/chase oscillation
    autoFixStuck = true,
    stuckTimeout = 2.8, -- seconds without real progress before recovery
    autoSwitchNoDamage = true,
    noDamageTimeout = 10, -- counted only after attack input, not travel time
    skipCooldown = 16, -- seconds a failed target is deprioritized
    safeDistance = 4.3, -- sword band centers around 4.3; ranged weapons keep farther
    lowHealthSafety = true, -- avoid chasing while critically low on HP
    lowHealthThreshold = 35, -- percent

    attackInterval = 0.50,
    maxSearch = 300, -- target acquisition radius, independent of attack distance
    walkSpeed = 20,
    walkMethod = "Hybrid", -- V8 default: post-control directional driving + stable MoveTo/path goals
    navEngineVersion = 9, -- V9 keeps the V8 movement driver and updates chase logic
    autoFixFalseArrival = true, -- never stop at an approach point outside attack reach
    falseArrivalTimeout = 3.5, -- skip unreachable approach after fallback fails
    teleportDestination = "Slime", -- manual portal travel: Slime or Ruins
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
cfg.maxSearch = math.clamp(cfg.maxSearch,60,600)
cfg.walkSpeed = math.clamp(cfg.walkSpeed,12,32)
cfg.returnDelay = math.clamp(cfg.returnDelay,8,45)
cfg.stuckTimeout = math.clamp(cfg.stuckTimeout,1.8,8)
cfg.noDamageTimeout = math.clamp(cfg.noDamageTimeout,6,30)
cfg.skipCooldown = math.clamp(cfg.skipCooldown,8,60)
cfg.falseArrivalTimeout = math.clamp(cfg.falseArrivalTimeout,2,9)
if not table.find({"Off","Ranged Only","All Weapons"},cfg.spacingMode) then cfg.spacingMode="Ranged Only" end
-- Existing users may have V7's MoveTo mode saved; upgrade it once to Hybrid.
-- Keep other saved settings, including Auto Return / anti-AFK / shared paths.
local navConfigUpgrade = previous and (tonumber(previous.navEngineVersion) or 0)<8
if navConfigUpgrade and cfg.walkMethod=="MoveTo" then cfg.walkMethod="Hybrid" end
if not table.find({"Hybrid","MoveTo","Steering"},cfg.walkMethod) then cfg.walkMethod="Hybrid" end
cfg.navEngineVersion=9
if cfg.teleportDestination~="Slime" and cfg.teleportDestination~="Ruins" then cfg.teleportDestination="Slime" end

local falseArrivalWatch
local running, closed = false, false
local connections = {}
local npcCache, npcCacheSet = {}, {}
local currentTarget, lastEnemySeen = nil, os.clock()
local lastTargetSwitchAt=0
local nextAttack, lastScan, lastNearScan = 0, 0, 0
local lastHealthCheck, measuredHealthRatio, measuredCurrentHealth = 0, nil, nil
local lastHealthReading, lastDamageAt, recovering = nil, -1e9, false
local lastRetreatGoal, lastRetreatAt, lastRetreatEnemy = nil, 0, nil
local kiteActive, kiteUntil, kiteTarget = false, 0, nil
local lastMonsterScanCount, lastMonsterScanRadius = 0, 0
local lastPortalScan = 0
local portals = {}
local portalAttemptAt, portalInteractAt, portalArrivalAt = 0, 0, 0
local activePortal = nil
-- Manual teleport choice follows valid in-game portals. Never assumes a
-- client-side CFrame movement is an authoritative server teleport.
local manualTravel = {
    active=false, destination=nil, started=0, portal=nil,
    enteredAt=0, enteredPos=nil, avoidObject=nil, avoidUntil=0,
    lastTransition=0, lastScan=0, directDestination=false,
    lastArrivalCheck=0,
}
local lastCharacter = nil
local gui, statusText, targetText, farmButton
local lastStatus = "Ready"
local nav = {
    generation=0, subject=nil, mode=nil, waypoints=nil, index=1,
    goal=nil, computing=false, lastPlan=0, blockedConnection=nil,
    wanted=nil, lastMoveAt=0, lastMoveGoal=nil,
    progressGoal=nil, progressDistance=nil, progressAt=0,
    failures=0, retryNow=false, lastFallbackAt=0,
    lastRouteWarningAt=0, lastPathError=nil,
    lastGoalChangedAt=0, lastPathRequestGoal=nil, lastPathRequestAt=0,
    steerGoal=nil, steerHum=nil, lastBestDist=nil, lastMovedPos=nil,
    actualSpeed=0, driveSamples=0, driveLastPos=nil, driveLastAt=0,
    driveCommanded=false, driveMode="idle", driveBindName="RHYE_ABOVE_V9_PostControls",
    lastMovedAt=0, pathRequestId=0, routeUnreachableUntil=0,
}
local blocked = setmetatable({},{__mode="k"})
-- Damage telemetry is best-effort. Some ABOVE NPCs do not replicate HP.
-- Never equate a successful simulated click with an accepted server hit.
local hitWatch = {target=nil,lastHP=nil,hpVisible=false,attackStart=nil,attacks=0,confirmed=0,selectedAt=0,nearBlockedSince=nil}
local movementWatch = {target=nil,mode=nil,anchor=nil,goal=nil,since=0,attempts=0,lastRecovery=0}
local stuckBudget = {target=nil,strikes=0,lastStrike=0}
local function resetHitWatch(target,now)
    hitWatch.target=target;hitWatch.lastHP=nil;hitWatch.hpVisible=false
    hitWatch.attackStart=nil;hitWatch.attacks=0;hitWatch.confirmed=0
    hitWatch.selectedAt=now or os.clock();hitWatch.nearBlockedSince=nil
end
local function resetMovementWatch(target,mode,root,goal,now)
    movementWatch.target=target;movementWatch.mode=mode
    movementWatch.anchor=root;movementWatch.goal=goal
    movementWatch.since=now or os.clock();movementWatch.attempts=0;movementWatch.lastRecovery=0
end

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
    -- Prefer locomotion roots to decorative PrimaryPart pivots when available.
    for _,name in ipairs({"HumanoidRootPart","RootPart","Root","UpperTorso","Torso","Body","Head"}) do
        local part=model:FindFirstChild(name,true)
        if part and part:IsA("BasePart") then return part end
    end
    if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then return model.PrimaryPart end
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
    -- Some custom NPCs expose HP only via a BillboardGui label. Only accept
    -- explicitly named HP/Health labels to avoid reading damage/level numbers.
    if inst:IsA("Model") then
        local plate=inst:FindFirstChildWhichIsA("BillboardGui",true)
        if plate then
            for _,obj in ipairs(plate:GetDescendants()) do
                if obj:IsA("TextLabel") then
                    local n=obj.Name:lower()
                    if n:find("health",1,true) or n=="hp" or n=="hptext" then
                        local a,b=obj.Text:match("(%d[%d,%.]*)%s*/%s*(%d[%d,%.]*)")
                        if a and b then
                            local current=tonumber((a:gsub(",","")))
                            local maximum=tonumber((b:gsub(",","")))
                            if current and maximum and maximum>0 and current<=maximum then
                                return current,true
                            end
                        end
                    end
                end
            end
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
    -- In ABOVE some actors are named simply "NPC" or "Enemy" and their
    -- category lives 1-4 containers above the model (e.g. NPCs/Slimes/Spawn).
    local ancestor=inst.Parent
    for _=1,4 do
        if not ancestor or ancestor==Workspace then break end
        local group=ownCategory(ancestor)
        if group then return group end
        ancestor=ancestor.Parent
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
local fullScanBusy = false
local function refreshNPCs()
    -- V4 rebuilt the entire NPC index every 3 seconds. On busy maps that can
    -- freeze the executor for a frame. Build off to the side in short batches.
    if fullScanBusy then return end
    fullScanBusy=true
    local updated, known = {}, {}
    local items=Workspace:GetDescendants()
    for i,item in ipairs(items) do
        if item:IsA("Model") or (item:IsA("BasePart") and ownCategory(item)) then
            local mob=canonicalMob(item)
            if mob and not known[mob] and isMonster(mob) then
                known[mob]=true
                updated[#updated+1]=mob
            end
        end
        if i%350==0 then task.wait() end  -- yield to render and movement
    end
    -- Preserve event-discovered enemies that appeared during the index rebuild.
    for _,mob in ipairs(npcCache) do
        if not known[mob] and isMonster(mob) then
            known[mob]=true
            updated[#updated+1]=mob
        end
    end
    npcCache,npcCacheSet=updated,known
    lastScan=os.clock()
    fullScanBusy=false
end

-- Nearby and global scanning cooperate: a fast, uncapped local scan plus
-- a less frequent complete Workspace index (handles non-queryable / streamed NPCs).
-- "Search Radius" is the final acquisition filter, NOT the attack distance.
local nearScanBusy=false
local function scanNearbyNPCs(root,immediate)
    local now=os.clock()
    if nearScanBusy or (not immediate and now-lastNearScan<1.45) then return end
    lastNearScan=now
    nearScanBusy=true
    local center=root.Position
    local function doScan()
        local overlap=OverlapParams.new()
        overlap.FilterType=Enum.RaycastFilterType.Exclude
        overlap.FilterDescendantsInstances=player.Character and {player.Character} or {}
        overlap.MaxParts=0 -- unlimited: scanning MUST not miss NPCs behind scenery
        local radius=math.min(115,cfg.maxSearch)
        lastMonsterScanRadius=radius
        local ok,parts=pcall(function()
            return Workspace:GetPartBoundsInRadius(center,radius,overlap)
        end)
        if ok and parts then
            local seen={}
            for i,part in ipairs(parts) do
                if closed then break end
                if not seen[part] and ownCategory(part) then
                    seen[part]=true
                    addNPC(part)
                end
                local node=part.Parent
                for _=1,5 do
                    if not node or node==Workspace then break end
                    if node:IsA("Model") and not seen[node] then
                        seen[node]=true
                        addNPC(node)
                    end
                    node=node.Parent
                end
                if not immediate and i%160==0 then task.wait() end
            end
        end
        lastMonsterScanCount=#npcCache
        nearScanBusy=false
    end
    if immediate then doScan()
    else
        task.spawn(function()
            local ok,err=pcall(doScan)
            if not ok then
                nearScanBusy=false
                warn("[RHYE ABOVE] Nearby scan error: "..tostring(err))
            end
        end)
    end
end

local function chooseTarget(root)
    local now=os.clock()
    local best,bestDist=nil,math.huge
    local currentDist=math.huge
    for _,npc in ipairs(npcCache) do
        if targetAlive(npc) then
            local part=findRoot(npc)
            if part then
                local delta=part.Position-root.Position
                local dist=Vector3.new(delta.X,0,delta.Z).Magnitude
                local height=math.abs(delta.Y)
                if dist<=cfg.maxSearch and height<=35 then
                    local skipped=blocked[npc] and blocked[npc]>now
                    if not skipped then
                        if dist<bestDist then best,bestDist=npc,dist end
                    end
                    if npc==currentTarget then currentDist=dist end
                end
            end
        end
    end
    if not targetAlive(currentTarget) or currentDist>cfg.maxSearch then return best end
    -- A blacklisted target is never selected again until its cooldown expires,
    -- even if it is standing within attack range.
    if blocked[currentTarget] and blocked[currentTarget]>now then return best end
    if not best or currentTarget==best then return currentTarget end
    -- Once attacks have started, keep this mob until death, no-damage timeout,
    -- or route failure. Prevents target oscillation in crowded slime packs.
    if hitWatch.target==currentTarget and hitWatch.attackStart then return currentTarget end
    -- A clearly closer monster must win when we are NOT already dealing damage.
    -- Avoid chasing a generic Slime 17+ studs away while a variant is right
    -- beside the player.  Keep a short 1.6s hysteresis to prevent target flicker.
    if now-lastTargetSwitchAt<1.6 then return currentTarget end
    if bestDist+4<currentDist and bestDist<currentDist*0.80 then return best end
    return currentTarget
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
local function walkingCorridor(from,to,excluded)
    local along=flat(to-from)
    if along.Magnitude<1.2 then return true end
    local side=Vector3.new(-along.Z,0,along.X).Unit*1.05
    -- Checking both shoulders catches edges of cave walls missed by a
    -- single center ray. Use only in navigation, not for combat LOS.
    return los(from,to,excluded) and los(from+side,to+side,excluded)
        and los(from-side,to-side,excluded)
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
    if dist<2.2 then return true end
    local steps=math.clamp(math.ceil(dist/5),2,12)
    local lastFloor=findFloorAt(from,excluded)
    for i=1,steps do
        local pt=from:Lerp(to,i/steps)
        local floor=findFloorAt(pt,excluded)
        if not floor then return false end
        -- Avoid high ledges. Pathfinding should select slopes or proper jumps.
        if lastFloor and math.abs(floor.Y-lastFloor.Y)>4.5 then return false end
        lastFloor=floor
    end
    return true
end

local function approachPoint(myPos,mobPart,mobModel,range)
    local mobPos=mobPart.Position
    -- Far chase uses a fixed approach offset. Don't generate a new ring point
    -- around a moving monster every frame or the avatar will zig-zag.
    local longDistance=horizontalDistance(myPos,mobPos)
    if longDistance>24 then
        local away=flat(myPos-mobPos)
        if away.Magnitude>0.2 then
            local dest=mobPos+away.Unit*math.max(2.5,range-0.2)
            local floor=findFloorAt(dest,mobModel)
            if floor then return Vector3.new(dest.X,floor.Y+2.7,dest.Z) end
            return Vector3.new(dest.X,myPos.Y,dest.Z)
        end
    end
    local away=flat(myPos-mobPos)
    if away.Magnitude<0.2 then away=Vector3.new(1,0,0) end
    away=away.Unit
    local radius=math.max(1.8,range-0.25)
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
            local direct=walkingCorridor(myPos,goal,mobModel)
                and groundCorridor(myPos,goal,mobModel)
            local heightPenalty=myFloor and math.abs(floor.Y-myFloor.Y)*2.5 or 0
            local score=horizontalDistance(myPos,goal)+(visible and 0 or 70)
                +(direct and -18 or 18)+heightPenalty
            if score<bestScore then best,bestScore=goal,score end
        end
    end
    if best then return best end
    -- On uneven cliffs/rocks there may be no safe ring position near the
    -- monster. Move a SHORT, grounded step toward it instead of returning the
    -- player's own position (the V3 "detected but never approached" bug).
    local toward=flat(mobPos-myPos)
    if toward.Magnitude>2 then
        local step=myPos+toward.Unit*math.min(5,toward.Magnitude-0.8)
        local floorStep=findFloorAt(step,mobModel)
        if floorStep and (not myFloor or math.abs(myFloor.Y-floorStep.Y)<3.5) then
            local dest=Vector3.new(step.X,floorStep.Y+2.7,step.Z)
            if walkingCorridor(myPos,dest,mobModel) and groundCorridor(myPos,dest,mobModel) then
                return dest
            end
        end
    end
    -- If ring samples failed, ask PathfindingService for a sensible grounded
    -- point close to the enemy; never return our OWN position as the chase goal.
    local mobFloor=findFloorAt(mobPos,mobModel)
    if mobFloor then
        return Vector3.new(mobPos.X,mobFloor.Y+2.7,mobPos.Z)
    end
    return Vector3.new(mobPos.X,myPos.Y,mobPos.Z)
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
                if walkingCorridor(from,destination,excluded) and groundCorridor(from,destination,excluded) then
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
                if walkingCorridor(from,destination,enemy) and groundCorridor(from,destination,enemy) then
                    local gain=horizontalDistance(destination,enemyPos)-horizontalDistance(from,enemyPos)
                    local score=gain*3-math.abs(ang)*1.8
                    if gain>0.6 and score>bestScore then best,bestScore=destination,score end
                end
            end
        end
    end
    return best
end
local function weaponCombatBounds(equippedTool)
    local kind=cfg.mobWeapon
    if kind=="Equipped" and equippedTool then
        if matchingWeapon(equippedTool,"Bow") then kind="Bow"
        elseif matchingWeapon(equippedTool,"Scepter") then kind="Scepter"
        else kind="Sword" end
    end
    local sword=(kind=="Sword" or kind=="Equipped")
    -- Sword's nominal 5.4 range from the reference UI is not a server promise;
    -- keep 0.3 studs margin so the script actually walks close enough to hit.
    local reach=sword and math.min(cfg.attackRange,5.1) or cfg.attackRange
    local ideal=cfg.safeDistance
    if not sword then
        ideal=math.max(ideal,math.min(12,reach-1.5))
    end
    ideal=math.clamp(ideal,2.5,math.max(2.5,reach-(sword and 0.4 or 1.0)))
    local retreatAt=math.max(1.7,ideal-(sword and 1.05 or 1.75))
    local settleAt=math.min(reach-0.15,ideal+(sword and 0.25 or 0.6))
    return reach,ideal,retreatAt,settleAt
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
    nav.pathRequestId=nav.pathRequestId+1
    if nav.blockedConnection then
        pcall(function()nav.blockedConnection:Disconnect()end)
    end
    nav.blockedConnection=nil
    nav.subject=nil;nav.mode=nil;nav.waypoints=nil;nav.index=1
    nav.goal=nil;nav.wanted=nil;nav.computing=false;nav.lastPlan=0
    nav.lastMoveGoal=nil;nav.lastMoveAt=0
    nav.progressGoal=nil;nav.progressDistance=nil;nav.progressAt=0
    nav.failures=0;nav.retryNow=false;nav.lastFallbackAt=0
    nav.lastPathError=nil;nav.steerGoal=nil;nav.steerHum=nil
    nav.lastGoalChangedAt=0;nav.lastPathRequestGoal=nil;nav.lastPathRequestAt=0
    nav.lastBestDist=nil;nav.lastMovedPos=nil;nav.lastMovedAt=0
    nav.routeUnreachableUntil=0
    nav.driveCommanded=false; nav.driveMode="idle"
    nav.driveLastPos=nil;nav.driveLastAt=0;nav.actualSpeed=0
end

-- Two separate responsibilities:
-- 1) navigation/path planner determines ONE stable waypoint.
-- 2) a post-ControlModule driver applies the requested direction every frame.
-- Many Roblox games write Humanoid:Move(Vector3.zero) from their PlayerModule
-- after a one-shot MoveTo; when that happens MoveTo reports a goal but the
-- avatar stands still in OPEN terrain (exactly what the V7 recording shows).
local function sendMove(humanoid,goal,force)
    if cfg.walkMethod=="Hybrid" or cfg.walkMethod=="Steering" then
        nav.steerGoal=goal
        nav.steerHum=humanoid
        local now=os.clock()
        local mustUpdate=force or not nav.lastMoveGoal
            or horizontalDistance(nav.lastMoveGoal,goal)>1.3
            or now-nav.lastMoveAt>3.4
        nav.lastMoveGoal=goal
        if mustUpdate then
            nav.lastMoveAt=now
            if cfg.walkMethod=="Hybrid" then
                -- Useful for state replication and as a fallback, but NOT the
                -- only source of motion while pursuing a target.
                humanoid:MoveTo(goal)
            end
        end
        return
    end
    nav.steerGoal=nil;nav.steerHum=nil
    local now=os.clock()
    if not force and nav.lastMoveGoal
        and horizontalDistance(nav.lastMoveGoal,goal)<1.3
        and now-nav.lastMoveAt<3.4 then return end
    nav.lastMoveGoal=goal
    nav.lastMoveAt=now
    humanoid:MoveTo(goal)
end

nav.driveAfterControls=function()
    if closed or (not running and not manualTravel.active) then return end
    local hum=nav.steerHum
    local goal=nav.steerGoal
    if not goal or not hum or hum.Health<=0 then return end
    local character=hum.Parent
    local root=character and character:FindFirstChild("HumanoidRootPart")
    if not root or root.Anchored then
        nav.driveMode=root and "root anchored" or "root missing"
        return
    end
    local now=os.clock()
    if nav.driveLastPos and now-nav.driveLastAt>0.6 then
        local elapsed=math.max(0.1,now-nav.driveLastAt)
        nav.actualSpeed=horizontalDistance(root.Position,nav.driveLastPos)/elapsed
        nav.driveLastPos=root.Position
        nav.driveLastAt=now
    elseif not nav.driveLastPos then
        nav.driveLastPos=root.Position
        nav.driveLastAt=now
    end
    local delta=flat(goal-root.Position)
    if delta.Magnitude>1.6 then
        -- World-space direction. Executed AFTER Roblox's ControlModule render
        -- step, preventing zero movement input from cancelling our nav command.
        hum:Move(delta.Unit,false)
        nav.driveCommanded=true
        nav.driveSamples=nav.driveSamples+1
        nav.driveMode=cfg.walkMethod
    else
        hum:Move(Vector3.zero,false)
        nav.driveCommanded=false
        nav.driveMode="at waypoint"
    end
end

-- Character priority is later than the usual Input / ControlModule step.
-- A named render binding is unbound in shutdown, so script reloads do not
-- accumulate independent movement writers in the same client.
nav.movementBound=false
nav.bindOK,nav.bindError=pcall(function()
    RunService:BindToRenderStep(nav.driveBindName,
        Enum.RenderPriority.Character.Value+5,nav.driveAfterControls)
end)
if nav.bindOK then
    nav.movementBound=true
else
    -- Fallback if an executor denies BindToRenderStep. This may be less
    -- reliable than post-input movement in games with custom controls.
    warn("[RHYE ABOVE V9] Post-input movement unavailable: "..tostring(nav.bindError))
    remember(RunService.Heartbeat:Connect(nav.driveAfterControls))
end

local function stopAtCombat(humanoid,root)
    if nav.mode~="combat-hold" then
        clearNavigation()
        nav.mode="combat-hold"
        humanoid:MoveTo(root.Position)
    end
end

-- All ComputeAsync jobs are asynchronous, bounded in age, and committed only
-- if still matching the current goal. Keep walking a valid OLD route while
-- a replacement is computed, rather than freezing in place.
local function requestPath(start,goal,subject,force)
    local now=os.clock()
    if nav.computing then return false end
    if not force and now-nav.lastPlan<2.6 then return false end
    if force and now-nav.lastPlan<0.9 then return false end
    nav.computing=true
    nav.lastPlan=now
    nav.lastPathRequestGoal=goal
    nav.lastPathRequestAt=now
    nav.pathRequestId=nav.pathRequestId+1
    local requestId=nav.pathRequestId
    local gen=nav.generation
    task.spawn(function()
        local path,waypoints
        local ok,err=pcall(function()
            path=PathfindingService:CreatePath({
                AgentRadius=2,AgentHeight=5,AgentCanJump=true,
                AgentCanClimb=false,WaypointSpacing=5,
            })
            path:ComputeAsync(start,goal)
            if path.Status==Enum.PathStatus.Success then
                waypoints=path:GetWaypoints()
            end
        end)
        if closed or nav.generation~=gen or nav.pathRequestId~=requestId
            or nav.subject~=subject then return end
        nav.computing=false
        -- Ignore stale paths; the monster may have moved substantially.
        if nav.wanted and horizontalDistance(nav.wanted,goal)>9 then
            nav.retryNow=true
            return
        end
        if ok and waypoints and #waypoints>=2 then
            if nav.blockedConnection then
                pcall(function()nav.blockedConnection:Disconnect()end)
            end
            nav.waypoints=waypoints;nav.index=2;nav.goal=goal
            nav.progressGoal=nil;nav.progressDistance=nil;nav.progressAt=0
            nav.failures=math.max(0,nav.failures-1)
            nav.lastPathError=nil
            nav.blockedConnection=path.Blocked:Connect(function(index)
                if nav.generation==gen and index>=nav.index then
                    nav.retryNow=true
                end
            end)
        else
            -- A failed replan does not delete a still-usable prior route.
            if not nav.waypoints then nav.goal=goal end
            nav.lastPathError=ok and (path and tostring(path.Status) or "No route") or tostring(err)
            nav.failures=nav.failures+1
        end
    end)
    return true
end

local function checkRouteProgress(root,waypoint)
    local now=os.clock()
    local remaining=horizontalDistance(root.Position,waypoint)
    if not nav.progressGoal or horizontalDistance(nav.progressGoal,waypoint)>2 then
        nav.progressGoal=waypoint
        nav.progressDistance=remaining
        nav.progressAt=now
        nav.lastMovedPos=root.Position
        nav.lastMovedAt=now
        return false
    end
    if remaining<nav.progressDistance-0.9 then
        nav.progressDistance=remaining
        nav.progressAt=now
        nav.lastMovedPos=root.Position
        nav.lastMovedAt=now
        nav.failures=math.max(0,nav.failures-1)
        return false
    end
    -- Require ACTUAL lack of progress for ~2.8 seconds, not small steering
    -- corrections or movement by a monster changing the desired goal.
    if now-nav.progressAt>2.8 and remaining>3.0 then
        nav.progressAt=now
        nav.progressDistance=remaining
        nav.failures=nav.failures+1
        nav.retryNow=true
        return true
    end
    return false
end

local function navMove(humanoid,root,goal,subject,exclude,mode)
    mode=mode or "approach"
    if nav.subject~=subject or nav.mode~=mode then
        clearNavigation()
        nav.subject=subject
        nav.mode=mode
    end
    local now=os.clock()
    if horizontalDistance(root.Position,goal)<1.8 then
        return true,"Arrived"
    end
    nav.wanted=goal
    local remaining=horizontalDistance(root.Position,goal)
    local direct=remaining<42
        and walkingCorridor(root.Position,goal,exclude)
        and groundCorridor(root.Position,goal,exclude)

    -- Only abandon a waypoint route if there's a clear direct corridor; this
    -- avoids oscillating between PathfindingService and steering each tick.
    if direct then
        if nav.waypoints then
            nav.waypoints=nil;nav.index=1;nav.goal=nil
            nav.progressGoal=nil
        end
        local stalled=checkRouteProgress(root,goal)
        if stalled then
            humanoid.Jump=true
            if nav.failures>=3 then
                nav.retryNow=true
                direct=false
            end
        end
        if direct then
            sendMove(humanoid,goal,false)
            return true,"Direct"
        end
    end

    local movingGoal=nav.goal and horizontalDistance(nav.goal,goal)>11
    local needsPlan=(not nav.waypoints) or nav.retryNow or movingGoal
    if needsPlan then
        local issued=requestPath(root.Position,goal,subject,nav.retryNow or movingGoal)
        if issued then nav.retryNow=false end
    end

    if nav.waypoints then
        while nav.index<=#nav.waypoints do
            local waypoint=nav.waypoints[nav.index]
            if horizontalDistance(root.Position,waypoint.Position)<3.0
                and math.abs(root.Position.Y-waypoint.Position.Y)<8 then
                nav.index=nav.index+1
                nav.progressGoal=nil
            else
                break
            end
        end
        local waypoint=nav.waypoints[nav.index]
        if waypoint then
            if waypoint.Action==Enum.PathWaypointAction.Jump then
                humanoid.Jump=true
            end
            local stalled=checkRouteProgress(root,waypoint.Position)
            if stalled then
                humanoid.Jump=true
                if nav.failures>=4 then return false,"Stuck at waypoint" end
                requestPath(root.Position,goal,subject,true)
            end
            sendMove(humanoid,waypoint.Position,false)
            return true,"Waypoint "..tostring(nav.index)
        else
            nav.waypoints=nil
        end
    end

    if nav.computing then
        -- Avoid a dead state if a path computation hangs.
        if now-nav.lastPathRequestAt>5 then
            nav.pathRequestId=nav.pathRequestId+1
            nav.computing=false
            nav.lastPathError="Path planning timed out"
            nav.failures=nav.failures+1
        else
            -- One steady short direct move while computing (only if clear).
            if not nav.lastMoveGoal or horizontalDistance(root.Position,nav.lastMoveGoal)<2.0 then
                local step=safeShortStep(root.Position,goal,exclude)
                if step then sendMove(humanoid,step,false) end
            end
            return true,"Planning"
        end
    end

    -- Do not pick a new fallback side step every tick: give it time to finish.
    if nav.lastMoveGoal and now-nav.lastFallbackAt<2.4
        and horizontalDistance(root.Position,nav.lastMoveGoal)>1.8 then
        local stalled=checkRouteProgress(root,nav.lastMoveGoal)
        if not stalled then return true,"Detour" end
    end
    if nav.failures>=5 then return false,"No traversable route" end
    if now-nav.lastFallbackAt>2.4 then
        nav.lastFallbackAt=now
        local step=safeShortStep(root.Position,goal,exclude)
        if step and horizontalDistance(root.Position,step)>1.6 then
            nav.progressGoal=nil
            sendMove(humanoid,step,false)
            return true,"Detour"
        end
    end
    return true,"Searching safe route"
end

-- Navigation watchdog: detect ZERO/poor progress rather than counting
-- Humanoid:MoveTo calls. Use a jump and forced replan; then skip this target.
local function monitorMovement(hum,root,goal,target,mode,now)
    if not cfg.autoFixStuck or not goal then return false,nil end
    if stuckBudget.target~=target then
        stuckBudget.target=target;stuckBudget.strikes=0;stuckBudget.lastStrike=0
    end
    local remaining=horizontalDistance(root.Position,goal)
    if remaining<3.0 then
        resetMovementWatch(target,mode,root.Position,goal,now)
        return false,nil
    end
    if movementWatch.target~=target or movementWatch.mode~=mode or not movementWatch.anchor
        or (movementWatch.goal and horizontalDistance(goal,movementWatch.goal)>11) then
        resetMovementWatch(target,mode,root.Position,goal,now)
        return false,nil
    end
    -- Progress = player actually moved, or got significantly closer to the goal.
    local moved=horizontalDistance(root.Position,movementWatch.anchor)
    local oldDist=horizontalDistance(movementWatch.anchor,movementWatch.goal or goal)
    if remaining<oldDist-1.25 then
        movementWatch.anchor=root.Position
        movementWatch.goal=goal
        movementWatch.since=now
        if movementWatch.attempts>0 then movementWatch.attempts=movementWatch.attempts-1 end
        return false,nil
    end
    -- A sideways loop around a rock does NOT reset the progress timer.
    -- The watchdog relies on reaching the current waypoint, not distance walked.
    if now-movementWatch.since<cfg.stuckTimeout then return false,nil end
    movementWatch.since=now
    movementWatch.attempts=movementWatch.attempts+1
    if now-stuckBudget.lastStrike>26 then stuckBudget.strikes=0 end
    stuckBudget.strikes=stuckBudget.strikes+1
    stuckBudget.lastStrike=now
    if stuckBudget.strikes>=3 then
        return true,"3 stuck recoveries failed (mob temporarily ignored)"
    end
    -- Repath/jump once. Avoid sending a constantly changing sideways MoveTo.
    hum.Jump=true
    nav.retryNow=true;nav.lastMoveGoal=nil;nav.progressGoal=nil
    if stuckBudget.strikes==2 then
        nav.waypoints=nil
        local step=safeShortStep(root.Position,goal,target)
        if step then sendMove(hum,step,true) end
    else
        sendMove(hum,goal,true)
    end
    return false,"Recovering "..tostring(stuckBudget.strikes).."/2"
end

local function registerAttack(target,now)
    if hitWatch.target~=target then resetHitWatch(target,now) end
    if not hitWatch.attackStart then hitWatch.attackStart=now end
    hitWatch.attacks=hitWatch.attacks+1
end
local function observeTargetHP(target,hp,known,now)
    if hitWatch.target~=target then resetHitWatch(target,now) end
    if known and type(hp)=="number" then
        hitWatch.hpVisible=true
        if hitWatch.lastHP and hp<hitWatch.lastHP-0.001 then
            -- Replicated decrease is the best evidence of a successful hit.
            hitWatch.confirmed=hitWatch.confirmed+1
            hitWatch.attackStart=nil;hitWatch.attacks=0
        end
        hitWatch.lastHP=hp
    end
end
local function shouldSkipNoDamage(now)
    return cfg.autoSwitchNoDamage and hitWatch.attackStart~=nil
        and hitWatch.attacks>=3 and now-hitWatch.attackStart>=cfg.noDamageTimeout
end

-- ---------------- Teleporter return support ----------------
local function portalObjectName(inst)
    local parentName=inst.Parent and inst.Parent.Name or ""
    local generic=parentName:lower()
    if generic=="portals" or generic=="teleporters" or generic=="teleports" then parentName="" end
    local title=(inst.Name.." "..parentName):lower()
    -- Don't traverse deep world/terrain Models while scanning every BasePart.
    -- Only check nested prompts for plausible teleporter object names.
    local candidate=title:find("portal",1,true) or title:find("teleport",1,true)
        or title:find("gateway",1,true) or title:find("ruins",1,true)
        or title:find("slime",1,true) or title:find("hub",1,true)
    local prompt=inst:FindFirstChildOfClass("ProximityPrompt")
    if not prompt and candidate then
        prompt=inst:FindFirstChildWhichIsA("ProximityPrompt",true)
    end
    if prompt then
        title=title.." "..prompt.ActionText:lower().." "..prompt.ObjectText:lower()
    end
    return title
end
local function looksLikePortal(inst)
    if not (inst:IsA("Model") or inst:IsA("BasePart")) then return false end
    if inst:IsA("Model") and inst.Name:lower()=="portals" then return false end
    local text=portalObjectName(inst)
    return text:find("portal",1,true)~=nil or text:find("teleport",1,true)~=nil
        or text:find("gateway",1,true)~=nil
        or text:find("travel to",1,true)~=nil
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
local function assignedPortalName(destination)
    destination=destination or cfg.targetGroup
    return destination=="Slime" and cfg.portalSlimeName or cfg.portalSkeletonName
end
local function matchingDestination(portal,destination)
    destination=destination or cfg.targetGroup
    local name=portalObjectName(portal.object)
    local full=portal.object:GetFullName()
    local assigned=assignedPortalName(destination)
    if assigned~="" then
        if assigned==full then return 100 end
        if assigned==portal.object.Name then return 90 end
    end
    if destination=="Slime" then
        if name:find("slime",1,true) or name:find("wildland",1,true) then return 60 end
    else
        if name:find("ruins",1,true) or name:find("skeleton",1,true) then return 60 end
    end
    return 0
end
local function findReturnPortal(root,destination,avoidObject,avoidUntil)
    destination=destination or cfg.targetGroup
    local best,bestScore=nil,-math.huge
    local assigned=assignedPortalName(destination)
    local baseName=assigned~="" and assigned:match("[^%.]+$") or nil
    local sameNamed=0
    if baseName then
        for _,candidate in ipairs(portals) do
            if candidate.object.Name==baseName then sameNamed=sameNamed+1 end
        end
    end
    local now=os.clock()
    for _,item in ipairs(portals) do
        if item.part.Parent and (item.object~=avoidObject or now>=(avoidUntil or 0)) then
            local score=matchingDestination(item,destination)
            if score==0 and sameNamed==1 and item.object.Name==baseName then
                score=80
            end
            if score>0 then
                local dist=(item.part.Position-root.Position).Magnitude
                -- A destination portal that is visible and close is preferred
                -- over travelling back through a Home/Hub portal.
                if dist<=450 and score*10-dist>bestScore then
                    best,bestScore=item,score*10-dist
                end
            end
        end
    end
    if best then return best,"destination" end
    -- Home -> Hub as an explicit optional first hop. Never guess a random portal.
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
            if matches and dist<450 and dist<hubDistance
                and (item.object~=avoidObject or now>=(avoidUntil or 0)) then
                hubBest,hubDistance=item,dist
            end
        end
        if hubBest then return hubBest,"hub" end
    end
    return nil,"unknown"
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

local function cancelManualTravel(message)
    if not manualTravel.active then return end
    manualTravel.active=false
    manualTravel.portal=nil
    manualTravel.enteredAt=0
    manualTravel.enteredPos=nil
    clearNavigation()
    local _,hum,root=getCharacter()
    if hum and root then hum:MoveTo(root.Position) end
    setStatus(message or "Teleport request cancelled")
end

local function requestManualTravel(destination)
    if destination~="Slime" and destination~="Ruins" then return end
    if running then
        -- run the same cleanup as Stop Hunt, without depending on a GUI button
        running=false
        currentTarget=nil
        activePortal=nil
        clearNavigation()
        if farmButton and farmButton.Parent then farmButton.Text="START AUTO HUNT" end
    end
    manualTravel.active=true
    manualTravel.destination=destination
    manualTravel.started=os.clock()
    manualTravel.portal=nil
    manualTravel.enteredAt=0
    manualTravel.enteredPos=nil
    manualTravel.avoidObject=nil
    manualTravel.avoidUntil=0
    manualTravel.lastTransition=0
    manualTravel.lastScan=0
    manualTravel.directDestination=false
    manualTravel.lastArrivalCheck=0
    scanPortals()
    setStatus("Teleport "..destination..": locating in-game portal")
end

local function atTravelDestination(root,destination)
    -- Known live mobs near the avatar indicate we're in the right hunting area.
    -- This avoids endlessly re-entering a portal after arrival.
    local category=destination=="Ruins" and "Skeleton" or "Slime"
    for _,mob in ipairs(npcCache) do
        if categoryOf(mob)==category and isMonster(mob) then
            local part=findRoot(mob)
            if part and horizontalDistance(root.Position,part.Position)<75
                and math.abs(root.Position.Y-part.Position.Y)<24 then return true end
        end
    end
    return false
end

local function runManualTravel(hum,root,now)
    if not manualTravel.active then return end
    local destination=manualTravel.destination
    if now-manualTravel.started>135 then
        cancelManualTravel("Teleport timed out. Bind SLIME / RUINS portal and retry")
        return
    end
    if now-manualTravel.lastScan>6 then
        manualTravel.lastScan=now
        scanPortals()
    end
    if now-manualTravel.lastTransition>2 and now-manualTravel.lastArrivalCheck>1.1 then
        manualTravel.lastArrivalCheck=now
        if atTravelDestination(root,destination) then
            cancelManualTravel("Arrived at "..destination.." area (visible mobs nearby)")
            return
        end
    end
    -- Observe the actual server-controlled position change before treating
    -- a portal as successful. Re-scan afterward in case Home -> Hub is required.
    if manualTravel.enteredPos then
        local displacement=(root.Position-manualTravel.enteredPos).Magnitude
        if displacement>32 then
            local used=manualTravel.portal
            manualTravel.avoidObject=used
            manualTravel.avoidUntil=now+23
            local arrived=manualTravel.directDestination
            manualTravel.portal=nil
            manualTravel.enteredPos=nil
            manualTravel.enteredAt=0
            manualTravel.lastTransition=now
            clearNavigation()
            scanPortals()
            if arrived then
                cancelManualTravel("Portal moved player; check "..destination.." area")
                return
            end
            setStatus("Hub step complete; searching "..destination.." portal")
            return
        end
        if now-manualTravel.enteredAt>14 then
            -- No position change; maybe wrong bind or UI-based teleport.
            manualTravel.avoidObject=manualTravel.portal
            manualTravel.avoidUntil=now+12
            manualTravel.portal=nil
            manualTravel.enteredPos=nil
            manualTravel.enteredAt=0
            clearNavigation()
            setStatus("Portal didn't transfer. Check its prompt / unlock")
            return
        end
    end
    local portal,step
    if manualTravel.enteredPos and manualTravel.portal
        and manualTravel.portal:IsDescendantOf(Workspace) then
        -- Keep the same portal while an activation is pending, but CONTINUE
        -- sending walking/interaction input if it requires touching the portal.
        for _,candidate in ipairs(portals) do
            if candidate.object==manualTravel.portal then portal=candidate break end
        end
        if not portal then
            local part=portalPart(manualTravel.portal)
            if part then portal={object=manualTravel.portal,part=part} end
        end
        step=manualTravel.directDestination and "destination" or "hub"
    end
    if not portal then
        portal,step=findReturnPortal(root,destination,manualTravel.avoidObject,manualTravel.avoidUntil)
    end
    if not portal then
        targetText.Text="Teleport "..destination.." | portal not detected"
        setStatus("No portal for "..destination..". Use BIND near portal, then retry")
        return
    end
    if manualTravel.portal~=portal.object then
        manualTravel.portal=portal.object
        manualTravel.enteredAt=0
        manualTravel.enteredPos=nil
        manualTravel.directDestination=(step=="destination")
        clearNavigation()
    end
    local portalPos=portal.part.Position
    local distance=(root.Position-portalPos).Magnitude
    targetText.Text=string.format("Teleport %s via %s (%.0f st)",destination,portal.object.Name,distance)
    if distance<=9 then
        if not manualTravel.enteredPos then
            manualTravel.enteredPos=root.Position
            manualTravel.enteredAt=now
        end
        triggerPortal(portal)
        if distance>2.5 then
            sendMove(hum,portalPos,false)
        end
        setStatus("Using "..portal.object.Name.." ["..step.."]")
    else
        local ok,info=navMove(hum,root,portalPos,portal.object,portal.object,"manual-portal")
        if not ok then
            manualTravel.avoidObject=portal.object
            manualTravel.avoidUntil=now+8
            clearNavigation()
            setStatus("Portal route blocked: trying another bound portal")
        else
            setStatus("Walking to "..destination.." portal ["..info.."]")
        end
    end
end

local function stopHunt()
    running=false
    currentTarget=nil
    resetHitWatch(nil)
    resetMovementWatch(nil,nil,nil,nil)
    activePortal=nil
    recovering=false
    lastRetreatGoal=nil
    kiteActive=false;kiteTarget=nil;kiteUntil=0
    clearNavigation()
    local _,hum,root=getCharacter()
    if hum and root then hum:MoveTo(root.Position);hum:Move(Vector3.zero,false) end
    if farmButton and farmButton.Parent then farmButton.Text="START AUTO HUNT" end
    setStatus("Auto Hunt stopped")
end
local function shutdown()
    if closed then return end
    if manualTravel.active then cancelManualTravel("Closing RHYE Hub") end
    stopHunt()
    if cfg.autoSave then writeConfig(true) end
    closed=true
    if nav.movementBound then
        pcall(function()RunService:UnbindFromRenderStep(nav.driveBindName)end)
        nav.movementBound=false
    end
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
    Name="RHYE_ABOVE_AutoHunt_V9", ResetOnSpawn=false, IgnoreGuiInset=true,
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
local subtitle=label(main,"ABOVE · False Arrival & Target Recovery V9",11,false,colors.muted)
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
    "AUTO HUNT V9 · FALSE ARRIVAL + TARGET RECOVERY\n\n1. Targets: Slime (all kinds) or Skeleton (all kinds).\n2. Sword spacing is disabled by default to stop chase/retreat loops.\n3. Auto Fix Stuck watches real movement; 10s no-damage switch uses observed mob HP when available.\n4. TELEPORT supports Slime and Ruins through game portals.\n5. Stand near a portal and BIND if it is not recognized.\n6. HOME -> HUB may be required for multiple hops.\n7. Ruins may require legitimate unlock progress.\n8. Settings are shared in Potassium workspace:\n   RHYE_Hub/ABOVE_Global_Config.json.\n\nClient-side walking and portal prompts depend on server rules.\nTeleport is not an instant server bypass; Anti-AFK not guaranteed.",
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
local renderSetting={}
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
    renderSetting[key]=update
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
    renderSetting[key]=update
    remember(control.MouseButton1Click:Connect(function()
        local idx=1
        for i,v in ipairs(options) do if v==cfg[key] then idx=i break end end
        cfg[key]=options[(idx%#options)+1]
        if key=="targetGroup" then
            currentTarget=nil;activePortal=nil;clearNavigation()
            resetHitWatch(nil);resetMovementWatch(nil,nil,nil,nil)
            blocked=setmetatable({},{__mode="k"})
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
    renderSetting[key]=update
    return frame
end


section("AUTO HUNT • ONLY TWO MONSTER GROUPS")
toggleRow("Farm Mobs","Enable hunting the selected category.","farmMobs")
cycleRow("Target Mobs","Slime = ALL slimes; Skeleton = ALL skeletons.","targetGroup",{"Slime","Skeleton"})
cycleRow("Mob Weapon","Equip via Tool when available; otherwise use hotbar.","mobWeapon",{"Sword","Bow","Scepter","Equipped"})

section("ATTACK & SMOOTH MOVEMENT")
sliderRow("Attack Range","Combat limit (Sword capped near 5.1). NOT monster detection range.","attackRange",2,35,0.5," st")
toggleRow("Auto Combat Spacing","Master toggle for distance management.","autoKite")
cycleRow("Spacing Mode","Ranged Only = NO Sword kite loop (recommended).","spacingMode",{"Ranged Only","Off","All Weapons"})
sliderRow("Safe Combat Distance","Preferred gap only when spacing applies; must be within weapon reach.","safeDistance",2.5,20,0.5," st")
toggleRow("Low HP Survival","Retreat and pause attack until HP recovers.","lowHealthSafety")
sliderRow("Low HP Threshold","Start defensive retreat under this percent HP.","lowHealthThreshold",15,60,5,"%")
sliderRow("Attack Interval","Added delay, does not bypass game cooldown.","attackInterval",0.15,2,0.05," s")
sliderRow("Search Radius","Mob detection ONLY (separate from Attack Range). Requires client streaming.","maxSearch",60,600,10," st")
sliderRow("Walk Speed","Client Humanoid speed while hunting; may be limited.","walkSpeed",12,32,1,"")
cycleRow("Walk Method","Hybrid drives after Roblox controls (recommended); MoveTo is legacy.","walkMethod",{"Hybrid","MoveTo","Steering"})
section("STUCK RECOVERY & FAILED TARGETS")
toggleRow("Auto Fix Stuck","Jump, replan, then skip blocked mob if still stuck.","autoFixStuck")
sliderRow("Stuck Timeout","Seconds without progress toward waypoint before recovery.","stuckTimeout",2,8,0.5," s")
toggleRow("Auto Fix False Arrival","Waypoint reached but monster is out of attack range: retry or switch.","autoFixFalseArrival")
sliderRow("False Arrival Timeout","Seconds after reroute before switching unreachable target.","falseArrivalTimeout",2,9,0.5," s")
toggleRow("Switch After No Damage","Change mob when attacks do not reduce visible HP.","autoSwitchNoDamage")
sliderRow("No Damage Timeout","Start counting AFTER attack inputs, default 10 seconds.","noDamageTimeout",6,30,1," s")
sliderRow("Skipped Mob Cooldown","Wait before retrying an unreachable/no-damage mob.","skipCooldown",8,60,2," s")
local debugCombatRow=settingRow("Combat Diagnostic (F9)","See target HP evidence, attack attempts and stuck retries.",61)
local debugCombatButton=button(debugCombatRow,"DEBUG COMBAT",11)
debugCombatButton.Size=UDim2.fromOffset(146,29)
debugCombatButton.Position=UDim2.new(1,-161,0,16)
remember(debugCombatButton.MouseButton1Click:Connect(function()
    local name=currentTarget and currentTarget.Name or "none"
    local hp=hitWatch.lastHP
    print("[RHYE ABOVE V9 DEBUG]", "Target="..name,
        "HP="..(hp and tostring(hp) or "unknown"),
        "ConfirmedDecreases="..tostring(hitWatch.confirmed),
        "AttackAttempts="..tostring(hitWatch.attacks),
        "AttackWindow="..(hitWatch.attackStart and string.format("%.1fs",os.clock()-hitWatch.attackStart) or "not started"),
        "StuckRetries="..tostring(stuckBudget.strikes),
        "NavMode="..tostring(nav.mode),
        "NavFailures="..tostring(nav.failures),
        "FalseArrivalAge="..string.format("%.1fs",falseArrivalWatch.fallbackAt>0 and os.clock()-falseArrivalWatch.fallbackAt or 0),
        "ApproachGoalDist="..string.format("%.1f",nav.wanted and ((player.Character and player.Character:FindFirstChild("HumanoidRootPart")) and horizontalDistance(player.Character.HumanoidRootPart.Position,nav.wanted) or -1) or -1),
        "SpacingMode="..cfg.spacingMode,
        "WalkMethod="..cfg.walkMethod,
        "DriveState="..tostring(nav.driveMode),
        "SpeedActual="..string.format("%.2f st/s",nav.actualSpeed),
        "DriverTicks="..tostring(nav.driveSamples),
        "HasMoveGoal="..tostring(nav.steerGoal~=nil),
        "RootAnchored="..tostring((player.Character and player.Character:FindFirstChild("HumanoidRootPart") and player.Character.HumanoidRootPart.Anchored) or false),
        "Route="..tostring(nav.lastPathError))
    setStatus("Combat diagnostics printed to F9")
end))
section("OTHER COMBAT OPTIONS")
cycleRow("Attack Method","Mouse = game LMB; Tool = Tool:Activate().","attackMode",{"Mouse","Tool","Auto"})
toggleRow("Auto Chase","Smooth stable waypoints + replan on obstruction only.","autoChase")
toggleRow("Auto Equip","Try equipping a matching Roblox Tool.","autoEquip")
toggleRow("Auto Aim","Aim camera at your target when attacking.","autoAim")
local presetRow=settingRow("Recommended Sword Preset","Search 300 / Attack 5 / Gap 4.3 / HP safety ON.",62)
local presetButton=button(presetRow,"APPLY PRESET",11)
presetButton.Size=UDim2.fromOffset(146,29)
presetButton.Position=UDim2.new(1,-161,0,16)
remember(presetButton.MouseButton1Click:Connect(function()
    local preset={mobWeapon="Sword",attackRange=5,safeDistance=4.3,
        maxSearch=300,walkSpeed=22,attackInterval=0.5,spacingMode="Ranged Only",
        autoKite=true,lowHealthSafety=true,lowHealthThreshold=40,
        walkMethod="Hybrid",autoFixStuck=true,stuckTimeout=2.8,
        autoFixFalseArrival=true,falseArrivalTimeout=3.5,autoSwitchNoDamage=true,
        noDamageTimeout=10,skipCooldown=16}
    for key,value in pairs(preset) do
        cfg[key]=value
        if renderSetting[key] then renderSetting[key]() end
    end
    kiteActive=false;kiteTarget=nil;lastRetreatGoal=nil
    resetMovementWatch(nil,nil,nil,nil,os.clock())
    clearNavigation()
    changed(true)
    setStatus("Sword preset applied: no melee kite; auto stuck/no-damage enabled")
end))
local mobScanRow=settingRow("Mob Detection Debug","Force reindex and print recognized NPCs to F9.",61)
local mobScanBtn=button(mobScanRow,"SCAN MOBS (F9)",11)
mobScanBtn.Size=UDim2.fromOffset(146,29)
mobScanBtn.Position=UDim2.new(1,-161,0,16)
remember(mobScanBtn.MouseButton1Click:Connect(function()
    task.spawn(function()
        refreshNPCs()
        local _,_,root=getCharacter()
        if root then
            lastNearScan=0
            scanNearbyNPCs(root,true)
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
        setStatus("Mob scan: "..tostring(#npcCache).." cached | search "..cfg.maxSearch.." st (F9)")
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

section("TELEPORT • SLIME / RUINS")
cycleRow("Teleport Destination","Choose Slime area or Ruins; follows available in-game portal.","teleportDestination",{"Slime","Ruins"})
local tpRow=settingRow("Teleport via Portal","GO follows real game portal; no instant server teleport.",95)
local tpGo=button(tpRow,"GO TO SELECTED",11)
tpGo.Size=UDim2.fromOffset(170,32)
tpGo.Position=UDim2.fromOffset(14,54)
local tpCancel=button(tpRow,"CANCEL TELEPORT",11)
tpCancel.Size=UDim2.fromOffset(170,32)
tpCancel.Position=UDim2.fromOffset(196,54)
remember(tpGo.MouseButton1Click:Connect(function()
    requestManualTravel(cfg.teleportDestination)
end))
remember(tpCancel.MouseButton1Click:Connect(function()
    cancelManualTravel("Teleport cancelled")
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
    if manualTravel.active then cancelManualTravel("Teleport cancelled; starting farm") end
    if not cfg.farmMobs then setStatus("Enable Farm Mobs first") return end
    running=true
    currentTarget=nil
    resetHitWatch(nil)
    resetMovementWatch(nil,nil,nil,nil)
    lastEnemySeen=os.clock()-cfg.returnDelay
    recovering=false
    lastHealthReading=nil
    lastTargetSwitchAt=0
    nextAttack=0
    clearNavigation()
    farmButton.Text="STOP AUTO HUNT"
    setStatus("Auto Hunt V9 started: "..cfg.targetGroup.." | "..cfg.walkMethod)
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
if (not loadedConfig or navConfigUpgrade) and cfg.autoSave then scheduleSave(true) end
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
    resetHitWatch(nil)
    resetMovementWatch(nil,nil,nil,nil)
    activePortal=nil
    lastEnemySeen=os.clock()-cfg.returnDelay
    recovering=false
    lastRetreatGoal=nil
    kiteActive=false;kiteTarget=nil;kiteUntil=0
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
        if os.clock()-lastScan>10 and not fullScanBusy then
            task.spawn(function()
                local ok,err=pcall(refreshNPCs)
                if not ok then
                    fullScanBusy=false
                    warn("[RHYE ABOVE] NPC index refresh: "..tostring(err))
                end
            end)
        end
        if (cfg.autoReturn or manualTravel.active) and os.clock()-lastPortalScan>10 then pcall(scanPortals) end
    end
end)

local lastMovementSpeedSet=0
local lastApproachTarget,approachCache,approachAt,mobCachePos=nil,nil,0,nil
-- A way-point may be reached while the monster is still too far away.  V8
-- treated this as successful navigation and repeatedly remained motionless.
falseArrivalWatch={target=nil,fallbackAt=0,firstAt=0,initialMobDistance=math.huge}
local function clearFalseArrival(target)
    falseArrivalWatch.target=target
    falseArrivalWatch.fallbackAt=0
    falseArrivalWatch.firstAt=0
    falseArrivalWatch.initialMobDistance=math.huge
end
local function mobCenterApproach(part,model,fallbackY)
    local position=part.Position
    local floor=findFloorAt(position,model)
    return floor and Vector3.new(position.X,floor.Y+2.7,position.Z)
        or Vector3.new(position.X,fallbackY,position.Z)
end
local lastPortalFailureAt=0
local function skipMob(target,now,why)
    blocked[target]=now+cfg.skipCooldown
    warn("[RHYE ABOVE V9] Skip "..target.Name.." for "..cfg.skipCooldown.."s | "..why)
    currentTarget=nil
    resetHitWatch(nil,now);resetMovementWatch(nil,nil,nil,nil,now)
    kiteActive=false;kiteTarget=nil;lastRetreatGoal=nil
    lastApproachTarget=nil;approachCache=nil;mobCachePos=nil
    clearFalseArrival(nil)
    clearNavigation()
    -- Prevent auto-return from treating temporarily excluded mobs as an empty map.
    lastEnemySeen=now
    setStatus("SKIP "..target.Name..": "..why)
end

task.spawn(function()
    while not closed do
        task.wait(0.17)
        if not running and not manualTravel.active then continue end
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
        if manualTravel.active then
            runManualTravel(hum,root,now)
            continue
        end
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
                resetHitWatch(target,now)
                resetMovementWatch(nil,nil,nil,nil,now)
                activePortal=nil
                clearNavigation()
                nextAttack=0
                lastApproachTarget=nil;approachCache=nil;mobCachePos=nil
                clearFalseArrival(target)
                lastRetreatGoal=nil;kiteActive=false;kiteTarget=nil
            end
            local part=findRoot(target)
            if not part then
                currentTarget=nil
                continue
            end
            local distance=(part.Position-root.Position).Magnitude
            local hDistance=horizontalDistance(part.Position,root.Position)
            local hp,known=healthInfo(target)
            observeTargetHP(target,hp,known,now)
            if shouldSkipNoDamage(now) then
                local reason=hitWatch.hpVisible
                    and ("no HP decrease after "..cfg.noDamageTimeout.."s / "..hitWatch.attacks.." attacks")
                    or ("HP unknown; no confirmed damage for "..cfg.noDamageTimeout.."s / retrying")
                skipMob(target,now,reason)
                continue
            end
            local tool=equipWeapon(character,hum,cfg.mobWeapon)
            local attackReach,idealGap,tooClose,settleAt=weaponCombatBounds(tool)
            targetText.Text=string.format("%s · %.1f st | Atk %.1f | Gap %.1f%s",target.Name,distance,
                attackReach,idealGap,known and string.format(" | HP %.0f",hp) or " | HP ?")
            local vertical=math.abs(root.Position.Y-part.Position.Y)
            local inRange=hDistance<=attackReach-0.20 and vertical<=7
                and los(root.Position,part.Position,target)
            -- If close to a mob for too long but unable to obtain a valid
            -- attack line, a repeatedly recalculated approach ring won't help.
            -- Give this mob a cooldown and try another one instead.
            if cfg.autoFixStuck and cfg.autoChase and not inRange
                and not hitWatch.attackStart and hDistance<math.max(14,attackReach+7) then
                hitWatch.nearBlockedSince=hitWatch.nearBlockedSince or now
                if now-hitWatch.nearBlockedSince>12 then
                    skipMob(target,now,"close to mob but cannot get attack line")
                    continue
                end
            else
                hitWatch.nearBlockedSince=nil
            end

            if cfg.lowHealthSafety and measuredHealthRatio then
                if measuredHealthRatio<=cfg.lowHealthThreshold/100 then recovering=true end
                if recovering and measuredHealthRatio>=math.max(0.60,cfg.lowHealthThreshold/100+0.23) then
                    recovering=false
                end
            else
                recovering=false
            end

            -- Hysteresis: the V3 loop treated every recently received hit as
            -- an order to retreat when the mob was <reach+3 studs away. That
            -- pulled swords OUT of attack range and made the character oscillate.
            if kiteTarget~=target then
                kiteActive=false
                kiteUntil=0
                kiteTarget=target
                lastRetreatGoal=nil
            end
            local recentHit=(now-lastDamageAt<0.85)
            local rangedWeapon=(cfg.mobWeapon=="Bow" or cfg.mobWeapon=="Scepter")
                or (cfg.mobWeapon=="Equipped" and tool
                    and (matchingWeapon(tool,"Bow") or matchingWeapon(tool,"Scepter")))
            local spacingEnabled=cfg.autoKite and (cfg.spacingMode=="All Weapons"
                or (cfg.spacingMode=="Ranged Only" and rangedWeapon))
            if spacingEnabled then
                if hDistance<tooClose then
                    kiteActive=true
                    kiteUntil=now+0.55
                elseif rangedWeapon and recentHit and hDistance<idealGap+0.2 then
                    kiteActive=true
                    kiteUntil=math.max(kiteUntil,now+0.55)
                elseif hDistance>=settleAt and now>=kiteUntil then
                    kiteActive=false
                end
                if hDistance>=settleAt+0.6 then
                    kiteActive=false
                end
            else
                kiteActive=false
            end
            local retreat=(recovering or kiteActive) and cfg.autoChase

            if retreat then
                local desired=idealGap+(recovering and 3.0 or 0)
                local required=math.max(2.1,desired-hDistance+0.35)
                if lastRetreatEnemy~=target or not lastRetreatGoal
                    or now-lastRetreatAt>0.95
                    or horizontalDistance(root.Position,lastRetreatGoal)<1.0 then
                    lastRetreatGoal=safeRetreatPoint(root.Position,part.Position,target,required)
                    lastRetreatEnemy=target
                    lastRetreatAt=now
                end
                if lastRetreatGoal then
                    local success,info=navMove(hum,root,lastRetreatGoal,target,target,"retreat")
                    if not success and nav.failures>=3 then
                        clearNavigation()
                        lastRetreatGoal=nil
                        kiteActive=false
                    end
                    setStatus(recovering and "LOW HP: trying to retreat; attacks paused"
                        or (success and "Spacing from "..target.Name.." ["..info.."]"
                        or "Spacing: no safe path; keep combat if possible"))
                else
                    -- Keep fighting in range rather than standing idle when
                    -- terrain offers no safe retreat (this is not invulnerability).
                    kiteActive=false
                    if inRange then stopAtCombat(hum,root) end
                    setStatus("No safe retreat point; continuing if in range")
                end
                if not recovering and inRange and now>=nextAttack then
                    nextAttack=now+cfg.attackInterval
                    local ok=attackTarget(part,tool)
                    if ok then registerAttack(target,now) end
                end
            elseif inRange then
                lastRetreatGoal=nil
                stopAtCombat(hum,root)
                if now>=nextAttack then
                    nextAttack=now+cfg.attackInterval
                    local ok,method=attackTarget(part,tool)
                    if ok then registerAttack(target,now) end
                    setStatus(ok and ("Attacking "..target.Name.." ["..method.."]")
                        or ("Attack input unavailable: "..method))
                end
            elseif cfg.autoChase then
                lastRetreatGoal=nil
                if lastApproachTarget~=target or not approachCache
                    or now-approachAt>7.0
                    or (mobCachePos and horizontalDistance(part.Position,mobCachePos)>8)
                    or (horizontalDistance(root.Position,approachCache)<2.1
                        and not inRange and now-approachAt>2.8)
                    or (nav.failures>=3 and now-approachAt>2.0) then
                    approachCache=approachPoint(root.Position,part,target,idealGap)
                    approachAt=now
                    lastApproachTarget=target
                    mobCachePos=part.Position
                end
                -- V8 BUG: An approach goal may already be at the player's feet
                -- even when the *mob* is 17+ studs away. navMove then reports
                -- "Arrived", monitorMovement resets because waypoint distance
                -- is <3, and the character stays still under enemy attacks.
                -- V9 distinguishes ARRIVED-AT-WAYPOINT from IN-ATTACK-RANGE.
                local falseArrival=(cfg.autoFixFalseArrival
                    and horizontalDistance(root.Position,approachCache)<2.4
                    and hDistance>attackReach+1.4)
                if falseArrival then
                    if falseArrivalWatch.target~=target then clearFalseArrival(target) end
                    if falseArrivalWatch.fallbackAt==0 then
                        falseArrivalWatch.firstAt=now
                        falseArrivalWatch.fallbackAt=now
                        falseArrivalWatch.initialMobDistance=hDistance
                        -- Approach the mob's ground position; actual combat
                        -- range still stops us before entering the mob hitbox.
                        approachCache=mobCenterApproach(part,target,root.Position.Y)
                        approachAt=now
                        nav.retryNow=true
                        nav.lastMoveGoal=nil
                        nav.progressGoal=nil
                        clearNavigation()
                        setStatus("False arrival: recalculating to "..target.Name)
                    elseif now-falseArrivalWatch.fallbackAt>=cfg.falseArrivalTimeout then
                        skipMob(target,now,"false arrival: still outside attack reach")
                        continue
                    end
                elseif falseArrivalWatch.target==target
                    and hDistance<=attackReach+0.4 then
                    clearFalseArrival(target)
                end

                -- Watch actual distance to the MOB while trying a fallback,
                -- not just distance to the last path waypoint.
                if cfg.autoFixFalseArrival and falseArrivalWatch.target==target
                    and falseArrivalWatch.fallbackAt>0 then
                    if hDistance<falseArrivalWatch.initialMobDistance-2.0 then
                        clearFalseArrival(target)
                    elseif now-falseArrivalWatch.fallbackAt>=cfg.falseArrivalTimeout
                        and hDistance>attackReach+1.4 and nav.actualSpeed<3 then
                        skipMob(target,now,"reroute failed to approach mob")
                        continue
                    end
                end
                local success,info=navMove(hum,root,approachCache,target,target,"approach")
                -- If route reported 'Arrived' despite the mob being far away,
                -- keep a second independent watchdog; a waypoint alone is not
                -- evidence that an attack can be made.
                if cfg.autoFixFalseArrival and info=="Arrived"
                    and hDistance>attackReach+1.4 then
                    if falseArrivalWatch.target~=target then clearFalseArrival(target) end
                    if falseArrivalWatch.fallbackAt==0 then
                        falseArrivalWatch.firstAt=now
                        falseArrivalWatch.fallbackAt=now
                        falseArrivalWatch.initialMobDistance=hDistance
                        approachCache=mobCenterApproach(part,target,root.Position.Y)
                        approachAt=now
                        clearNavigation()
                        success=true
                        info="Rerouting false arrival"
                    elseif now-falseArrivalWatch.fallbackAt>=cfg.falseArrivalTimeout then
                        skipMob(target,now,"arrived at waypoint, not monster")
                        continue
                    end
                end
                local activeWp=nav.waypoints and nav.waypoints[nav.index]
                local monitoredGoal=activeWp and activeWp.Position or approachCache
                local stuck,recoveryInfo=monitorMovement(hum,root,monitoredGoal,target,"approach",now)
                if stuck then
                    skipMob(target,now,"stuck: "..tostring(recoveryInfo))
                elseif not success and nav.failures>=4 then
                    skipMob(target,now,"pathfinding failed repeatedly")
                elseif not success then
                    setStatus("Path to "..target.Name..": "..info)
                else
                    setStatus("Chasing "..target.Name.." ["..info.."] "..
                        string.format("| mob %.1f st | mv %.1f st/s",hDistance,nav.actualSpeed)..
                        (recoveryInfo and " | "..recoveryInfo or ""))
                end
            else
                setStatus("Target detected but outside Attack Range: "..target.Name)
            end
        else
            currentTarget=nil
            lastApproachTarget=nil
            lastRetreatGoal=nil
            targetText.Text=string.format("Target: none (%s) | Search %.0f st | Cache %d",cfg.targetGroup,cfg.maxSearch,#npcCache)
            if recovering and cfg.lowHealthSafety and measuredHealthRatio
                and measuredHealthRatio<math.max(0.60,cfg.lowHealthThreshold/100+0.23) then
                if nav.subject then clearNavigation();hum:MoveTo(root.Position) end
                setStatus("LOW HP: wait for recovery before travelling")
                continue
            end
            recovering=false
            local cooldownMob=false
            for _,npc in ipairs(npcCache) do
                if blocked[npc] and blocked[npc]>now and targetAlive(npc) then
                    local p=findRoot(npc)
                    if p and horizontalDistance(root.Position,p.Position)<=cfg.maxSearch then
                        cooldownMob=true;break
                    end
                end
            end
            if cooldownMob then
                if nav.subject then clearNavigation();hum:MoveTo(root.Position) end
                setStatus("Nearby mobs cooling down after failed route/attack")
                continue
            end
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
                local success,info=navMove(hum,root,portalPos,portal.object,portal.object,"portal")
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
print("[RHYE ABOVE] V9 False Arrival + Target Recovery loaded. Shared config: "..CONFIG_FILE)
print("[RHYE ABOVE] Group: "..cfg.targetGroup.."  AutoReturn: "..tostring(cfg.autoReturn).."  AutoAFK: "..tostring(cfg.autoAfk))
