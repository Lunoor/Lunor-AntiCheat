--------------------------------------------------------------------------------
-- [ LPL - LUNOR PRODUCT LICENSE ]
-- Version: 2.0.0
-- Copyright (c) 2026 Lunor. All rights reserved.
--
-- WHAT IS THE LPL?
-- The Lunor Product License (LPL) is a custom proprietary license designed
-- to protect Lunor-branded developer resources. It allows for free usage
-- in personal projects while strictly prohibiting the unauthorized
-- redistribution or sale of the source code itself.
--
-- 1. LICENSE GRANT:
--    This script is licensed under the LPL. You are permitted to use and
--    modify this code strictly for use within the Roblox platform.
--
-- 2. RESTRICTIONS:
--    - Unauthorized redistribution of this source code is a violation of the LPL.
--    - You may NOT re-sell, re-bundle, or re-upload this script to any
--      public repository or the Roblox Creator Store.
--    - The "Lunor" branding and LPL header must remain intact at all times.
--
-- 3. OWNERSHIP:
--    This software is the property of Lunor. Use of this script constitutes
--    agreement to the terms of the LPL.
--
-- 4. WARRANTY:
--    THIS SOFTWARE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND.
--------------------------------------------------------------------------------
-- LUNOR ANTI-CHEAT v3.0.0
-- Modules: Fly | Noclip | Speed | Teleport | Gravity | BodyMover Injection
--          Stat Tampering | Anti-ESP (Proximity Culling) | Infinite Jump
--          Remote Flood | Aim Assistance | Damage Validation
--------------------------------------------------------------------------------

local Players         = game:GetService("Players")
local RunService      = game:GetService("RunService")
local HttpService     = game:GetService("HttpService")
local PhysicsService  = game:GetService("PhysicsService")

-- Only run on the server
assert(RunService:IsServer(), "[LUNOR AC] Must run on the server!")

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------
local CONFIG = {
	-- General
	Debug = false, -- Extra verbose logging

	-- Fly Detection
	FlyDetection = {
		Enabled                   = true,
		MaxAirTime                = 1.2,        -- seconds in air before suspicion is checked
		VerticalVelocityThreshold = 22,         -- upward studs/s that raises suspicion
		SuspicionThreshold        = 4,          -- suspicion points before correction
		SuspicionDecayRate        = 3,          -- points removed per grounded second
		GroundRayLength           = 5.5,        -- studs downward for grounded check
		-- Flat suspicion increments per frame (at 60fps, threshold=4 hit in ~1s when hovering)
		HoverSuspicionRate        = 0.25,       -- added each frame when near-zero velY in air
		ThrustSuspicionRate       = 0.4,        -- added each frame when flying upward fast
	},

	-- Noclip Detection
	NoclipDetection = {
		Enabled          = true,
		RaycastDistance  = 2.8,    -- studs in each cardinal direction
		CheckInterval    = 0.15,   -- seconds between checks
		ViolationLimit   = 6,      -- violations before punishment
		DecayRate        = 0.3,    -- violations removed per clean check
	},

	-- Speed Detection
	SpeedDetection = {
		Enabled          = true,
		MaxWalkSpeed     = 16,
		MaxRunSpeed      = 24,
		-- Multiplier buffer above max before flagging (accounts for lag/slopes)
		ToleranceMultiplier = 1.45,
		CheckInterval    = 0.12,
		ViolationLimit   = 5,
	},

	-- Teleport Detection
	TeleportDetection = {
		Enabled               = true,
		MaxDistancePerFrame   = 45,    -- studs
		IgnoreSpawnGracePeriod = 4,   -- seconds after spawn to ignore
	},

	-- Gravity Manipulation Detection
	GravityDetection = {
		Enabled               = true,
		ExpectedGravity       = workspace.Gravity,
		AllowedDeviation      = 5,     -- deviation in studs/s^2
		CheckInterval         = 2.0,
	},

	-- BodyMover Injection Detection
	BodyMoverDetection = {
		Enabled        = true,
		CheckInterval  = 0.5,
		-- BaseParts that are allowed to have movers (e.g. set via server scripts)
		Whitelist      = {},
	},

	-- Stat Tampering (WalkSpeed, JumpPower, JumpHeight set on client)
	StatTamperDetection = {
		Enabled           = true,
		MaxWalkSpeed      = 16,
		MaxJumpPower      = 50,
		MaxJumpHeight     = 7.2,
		CheckInterval     = 0.2,
	},

	-- Anti-ESP: Proximity Culling
	-- Hides characters from players who can't legitimately see them (behind walls, far away)
	-- Works by controlling which characters are streamed/visible per client
	ESPMitigation = {
		Enabled           = true,
		MaxRenderDistance = 150,   -- studs; beyond this, hide regardless of LOS
		CheckInterval     = 0.5,   -- seconds between LOS sweeps
		WallCheckSamples  = 3,     -- ray samples per player pair (reduces false positives)
	},

	-- Infinite Jump Detection
	InfiniteJumpDetection = {
		Enabled            = true,
		MaxJumpsBeforeLand = 2,    -- allow double-jump games; set to 1 for single-jump
		ResetOnGrounded    = true,
	},

	-- Remote Event Flood Detection
	RemoteFloodDetection = {
		Enabled        = true,
		MaxCallsPerSec = 25,       -- calls/sec before flagging (per remote, per player)
		WindowSize     = 1.0,      -- rolling window in seconds
		ViolationLimit = 3,
	},

	-- Aim Assistance / Aimbot Detection
	-- Tracks hit rate and angle snapping patterns server-side
	AimDetection = {
		Enabled           = true,
		TrackingWindow    = 10.0,  -- seconds of history to analyse
		MaxHitRate        = 0.92,  -- >92% hit rate is suspicious
		MinShotsToAnalyse = 15,    -- don't flag until we have a meaningful sample
		MaxReactionMs     = 80,    -- impossible human reaction time (ms) between shots on new targets
	},

	-- Damage Validation
	-- All damage must come through a server-side remote; direct stat edits get flagged
	DamageValidation = {
		Enabled       = true,
		MaxDamage     = 1000,      -- single-hit damage ceiling (set to your weapon max)
		RemoteName    = "DamageRemote", -- name of your damage RemoteEvent in ReplicatedStorage
	},

	-- Punishment
	PunishmentSystem = {
		KickOnDetection   = true,
		BanOnRepeat       = false,  -- hook your own ban system into banPlayer()
		RepeatThreshold   = 3,      -- detections before escalating kick message
		LogToConsole      = true,
		CorrectFirst      = true,   -- attempt to correct before kicking (softer)
	},
}

--------------------------------------------------------------------------------
-- INTERNAL STATE
--------------------------------------------------------------------------------
local playerData       = {} -- [player] = data table
local detectionLog     = {} -- [userId]  = array of detection events
local playerConnections = {} -- [player] = array of RBXScriptConnections

--------------------------------------------------------------------------------
-- UTILITIES
--------------------------------------------------------------------------------
local function debugLog(msg)
	if CONFIG.Debug then
		print("[LUNOR AC][DEBUG] " .. msg)
	end
end

local function createPlayerData(player)
	return {
		-- Position tracking
		lastPosition        = nil,
		lastValidPosition   = nil,
		positionHistory     = {},   -- ring buffer of recent positions

		-- Fly tracking
		airTime             = 0,
		flySuspicion        = 0,
		lastGroundedTime    = tick(),

		-- Noclip tracking
		noclipViolations    = 0,
		lastNoclipCheck     = 0,

		-- Speed tracking
		speedViolations     = 0,
		lastSpeedCheck      = 0,

		-- Stat tamper tracking
		lastStatCheck       = 0,

		-- BodyMover tracking
		lastBodyMoverCheck  = 0,

		-- Gravity tracking
		lastGravityCheck    = 0,

		-- Infinite jump tracking
		jumpCount           = 0,
		lastJumpState       = false,   -- was jumping last frame

		-- Remote flood tracking (table keyed by remote name)
		remoteCallLog       = {},

		-- Aim tracking
		shotsFired          = 0,
		shotsHit            = 0,
		lastShotTime        = 0,
		lastTargetId        = nil,
		aimSuspicion        = 0,

		-- ESP mitigation
		lastESPCheck        = 0,

		-- General
		detectionCount      = 0,
		joinTime            = tick(),
		isFlaggedForBan     = false,
	}
end

-- Ring-buffer position history (keeps last N positions for interpolation analysis)
local HISTORY_MAX = 20
local function recordPosition(data, pos)
	table.insert(data.positionHistory, { pos = pos, t = tick() })
	if #data.positionHistory > HISTORY_MAX then
		table.remove(data.positionHistory, 1)
	end
end

--------------------------------------------------------------------------------
-- LOGGING & PUNISHMENT
--------------------------------------------------------------------------------
local function logDetection(player, detectionType, details)
	if CONFIG.PunishmentSystem.LogToConsole then
		warn(string.format("[LUNOR AC] %-20s | %-25s | %s",
			player.Name, detectionType, details))
	end

	local uid = player.UserId
	if not detectionLog[uid] then detectionLog[uid] = {} end
	table.insert(detectionLog[uid], {
		type    = detectionType,
		time    = tick(),
		details = details,
	})
end

-- Override this function to connect your own ban system
local function banPlayer(player, reason)
	-- Example: DataStore ban flag, webhook, etc.
	warn(string.format("[LUNOR AC] BAN TRIGGERED for %s (%d): %s",
		player.Name, player.UserId, reason))
	-- By default falls through to kick
	player:Kick("Anti-Cheat: Banned – " .. reason)
end

local function punishPlayer(player, reason)
	local data = playerData[player]
	if not data then return end

	data.detectionCount += 1
	logDetection(player, "PUNISHMENT", string.format("Count: %d | %s", data.detectionCount, reason))

	if not CONFIG.PunishmentSystem.KickOnDetection then return end

	if data.detectionCount >= CONFIG.PunishmentSystem.RepeatThreshold then
		if CONFIG.PunishmentSystem.BanOnRepeat then
			data.isFlaggedForBan = true
			banPlayer(player, reason)
		else
			player:Kick(string.format(
				"Anti-Cheat: Repeated violations (%d). Contact support if this is an error.",
				data.detectionCount
			))
		end
	else
		player:Kick("Anti-Cheat: " .. reason)
	end
end

--------------------------------------------------------------------------------
-- CORRECTION HELPERS
--------------------------------------------------------------------------------
local function resetToValidPosition(player, character, reason)
	local data = playerData[player]
	if not data or not data.lastValidPosition then return end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then return end

	root.CFrame = CFrame.new(data.lastValidPosition)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero

	debugLog(string.format("Position corrected for %s: %s", player.Name, reason))
end

local function killBodyMovers(root)
	local movers = {
		"BodyVelocity", "BodyPosition", "BodyGyro",
		"BodyAngularVelocity", "BodyForce", "BodyThrust",
		"VectorForce", "AlignPosition", "AlignOrientation",
		"LinearVelocity", "AngularVelocity",
	}
	for _, child in ipairs(root:GetChildren()) do
		for _, moverClass in ipairs(movers) do
			if child:IsA(moverClass) then
				child:Destroy()
				debugLog("Destroyed " .. moverClass .. " on " .. root.Name)
			end
		end
	end
end

local function resetHumanoidStats(humanoid)
	if humanoid.WalkSpeed > CONFIG.StatTamperDetection.MaxWalkSpeed then
		humanoid.WalkSpeed = CONFIG.StatTamperDetection.MaxWalkSpeed
	end
	if humanoid.JumpPower > CONFIG.StatTamperDetection.MaxJumpPower then
		humanoid.JumpPower = CONFIG.StatTamperDetection.MaxJumpPower
	end
	if humanoid.JumpHeight > CONFIG.StatTamperDetection.MaxJumpHeight then
		humanoid.JumpHeight = CONFIG.StatTamperDetection.MaxJumpHeight
	end
end

local function clampHorizontalVelocity(root, maxSpeed)
	local v = root.AssemblyLinearVelocity
	local horiz = Vector3.new(v.X, 0, v.Z)
	if horiz.Magnitude > maxSpeed then
		local clamped = horiz.Unit * maxSpeed
		root.AssemblyLinearVelocity = Vector3.new(clamped.X, v.Y, clamped.Z)
	end
end

--------------------------------------------------------------------------------
-- GROUNDED CHECK
-- Uses multiple rays to reliably determine if the character is on ground
--------------------------------------------------------------------------------
local function isGrounded(character, rayLength)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then return false end

	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { character }
	params.FilterType = Enum.RaycastFilterType.Exclude

	-- Center + 4 offsets for better coverage (detects ground at edges of hitbox)
	local offsets = {
		Vector3.zero,
		Vector3.new( 1.5, 0,  0),
		Vector3.new(-1.5, 0,  0),
		Vector3.new( 0,   0,  1.5),
		Vector3.new( 0,   0, -1.5),
	}

	local dir = Vector3.new(0, -(rayLength or CONFIG.FlyDetection.GroundRayLength), 0)

	for _, offset in ipairs(offsets) do
		local origin = root.Position + offset
		local result = workspace:Raycast(origin, dir, params)
		if result then return true end
	end
	return false
end

--------------------------------------------------------------------------------
-- DETECTION: FLY HACK
--------------------------------------------------------------------------------
local function checkFlyHack(player, character, dt)
	if not CONFIG.FlyDetection.Enabled then return end

	local humanoid = character:FindFirstChild("Humanoid")
	local root     = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then return end

	local data = playerData[player]
	if not data then return end

	-- Don't check dead players
	if humanoid.Health <= 0 then return end

	local grounded   = isGrounded(character)
	local vel        = root.AssemblyLinearVelocity
	local inAir      = humanoid.FloorMaterial == Enum.Material.Air and not grounded

	if inAir then
		data.airTime = data.airTime + dt

		-- Flat per-frame increments so suspicion builds predictably (~1s to flag when hovering)
		if math.abs(vel.Y) < 1.5 then
			-- Hovering: near-zero vertical velocity while airborne = fly exploit
			data.flySuspicion += CONFIG.FlyDetection.HoverSuspicionRate
		end

		if vel.Y > CONFIG.FlyDetection.VerticalVelocityThreshold then
			-- Abnormal upward thrust
			data.flySuspicion += CONFIG.FlyDetection.ThrustSuspicionRate
		end

		-- Trigger once airtime passes threshold AND suspicion is high enough
		if data.airTime > CONFIG.FlyDetection.MaxAirTime
			and data.flySuspicion >= CONFIG.FlyDetection.SuspicionThreshold then

			logDetection(player, "FLY_HACK",
				string.format("AirTime=%.2fs Suspicion=%.2f VelY=%.2f",
					data.airTime, data.flySuspicion, vel.Y))

			-- Kill movers first so nothing fights the correction
			killBodyMovers(root)

			-- TP back to last known valid ground position
			if data.lastValidPosition then
				root.CFrame = CFrame.new(data.lastValidPosition)
				root.AssemblyLinearVelocity  = Vector3.zero
				root.AssemblyAngularVelocity = Vector3.zero
			else
				-- No valid position yet — just force-fall
				local hum = character:FindFirstChild("Humanoid")
				if hum then hum:ChangeState(Enum.HumanoidStateType.Freefall) end
				root.AssemblyLinearVelocity = Vector3.new(vel.X * 0.3, math.min(vel.Y, -15), vel.Z * 0.3)
			end

			-- Reset so it re-evaluates cleanly after correction
			data.flySuspicion = 0
			data.airTime      = 0

			data.detectionCount += 1
			if data.detectionCount >= 3 then
				punishPlayer(player, "Fly exploit – repeated")
			end
		end
	else
		-- Decay suspicion when grounded
		data.airTime      = 0
		data.flySuspicion = math.max(0, data.flySuspicion - CONFIG.FlyDetection.SuspicionDecayRate * dt)
		data.lastGroundedTime = tick()

		if grounded then
			data.lastValidPosition = root.Position
		end
	end
end

--------------------------------------------------------------------------------
-- DETECTION: NOCLIP
--------------------------------------------------------------------------------
local function checkNoclip(player, character)
	if not CONFIG.NoclipDetection.Enabled then return end

	local data = playerData[player]
	if not data then return end

	local now = tick()
	if now - data.lastNoclipCheck < CONFIG.NoclipDetection.CheckInterval then return end
	data.lastNoclipCheck = now

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { character }
	params.FilterType = Enum.RaycastFilterType.Exclude

	-- Cast rays in 6 directions (cardinal + up/down for ceiling clipping)
	local directions = {
		Vector3.new( 1, 0,  0), Vector3.new(-1, 0,  0),
		Vector3.new( 0, 0,  1), Vector3.new( 0, 0, -1),
		Vector3.new( 0, 1,  0), Vector3.new( 0,-1,  0),
	}

	local dist = CONFIG.NoclipDetection.RaycastDistance

	for _, dir in ipairs(directions) do
		local result = workspace:Raycast(root.Position, dir * dist, params)
		if result and result.Instance then
			local inst = result.Instance
			-- Only flag if it's a collidable, non-transparent part
			if inst.CanCollide and inst.Transparency < 0.9 and not inst:IsA("Terrain") then
				-- Extra check: is the hit extremely close? (inside the geometry)
				if result.Distance < 1.0 then
					data.noclipViolations += 1

					logDetection(player, "NOCLIP",
						string.format("Inside '%s' [%s] Dist=%.2f Violations=%d",
							inst.Name, inst.ClassName, result.Distance, data.noclipViolations))

					resetToValidPosition(player, character, "Noclip")

					-- Re-enable collisions on all character parts
					for _, part in ipairs(character:GetDescendants()) do
						if part:IsA("BasePart") then
							part.CanCollide = true
						end
					end

					if data.noclipViolations >= CONFIG.NoclipDetection.ViolationLimit then
						punishPlayer(player, "Noclip – repeated violations")
					end
					return
				end
			end
		end
	end

	-- Clean check: decay violations
	data.noclipViolations = math.max(0, data.noclipViolations - CONFIG.NoclipDetection.DecayRate)
	data.lastValidPosition = root.Position
end

--------------------------------------------------------------------------------
-- DETECTION: SPEED HACK + VELOCITY EXPLOIT
--------------------------------------------------------------------------------
local function checkSpeedHack(player, character)
	if not CONFIG.SpeedDetection.Enabled then return end

	local data = playerData[player]
	if not data then return end

	local now = tick()
	if now - data.lastSpeedCheck < CONFIG.SpeedDetection.CheckInterval then return end
	data.lastSpeedCheck = now

	local humanoid = character:FindFirstChild("Humanoid")
	local root     = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then return end

	local maxAllowed = CONFIG.SpeedDetection.MaxWalkSpeed * CONFIG.SpeedDetection.ToleranceMultiplier

	-- 1) WalkSpeed property check
	if humanoid.WalkSpeed > maxAllowed then
		data.speedViolations += 1
		logDetection(player, "SPEED_TAMPER",
			string.format("WalkSpeed=%.2f Max=%.2f Violations=%d",
				humanoid.WalkSpeed, maxAllowed, data.speedViolations))

		-- Reset stat and TP back to bleed off any distance already gained
		humanoid.WalkSpeed = CONFIG.SpeedDetection.MaxWalkSpeed
		if data.lastValidPosition then
			root.CFrame = CFrame.new(data.lastValidPosition)
			root.AssemblyLinearVelocity  = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
		end

		if data.speedViolations >= CONFIG.SpeedDetection.ViolationLimit then
			punishPlayer(player, "Speed modification – repeated")
		end
	end

	-- 2) Actual velocity check (catches physics-based speed exploits)
	local vel   = root.AssemblyLinearVelocity
	local hSpd  = Vector3.new(vel.X, 0, vel.Z).Magnitude
	local maxVel = CONFIG.SpeedDetection.MaxRunSpeed * CONFIG.SpeedDetection.ToleranceMultiplier

	if hSpd > maxVel and isGrounded(character) then
		data.speedViolations += 1
		logDetection(player, "VELOCITY_EXPLOIT",
			string.format("HorizSpeed=%.2f Max=%.2f Violations=%d",
				hSpd, maxVel, data.speedViolations))

		-- Clamp velocity AND TP back so they can't use the burst to gain ground
		clampHorizontalVelocity(root, CONFIG.SpeedDetection.MaxRunSpeed)
		if data.lastValidPosition then
			root.CFrame = CFrame.new(data.lastValidPosition)
			root.AssemblyLinearVelocity  = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
		end

		if data.speedViolations >= CONFIG.SpeedDetection.ViolationLimit + 1 then
			punishPlayer(player, "Abnormal velocity – repeated")
		end
	end
end

--------------------------------------------------------------------------------
-- DETECTION: TELEPORT
--------------------------------------------------------------------------------
local function checkTeleport(player, character)
	if not CONFIG.TeleportDetection.Enabled then return end

	local data = playerData[player]
	if not data then return end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then return end

	-- Grace period after spawn / respawn
	if tick() - data.joinTime < CONFIG.TeleportDetection.IgnoreSpawnGracePeriod then
		data.lastPosition      = root.Position
		data.lastValidPosition = root.Position
		return
	end

	local pos = root.Position

	if data.lastPosition then
		local dist = (pos - data.lastPosition).Magnitude

		if dist > CONFIG.TeleportDetection.MaxDistancePerFrame then
			logDetection(player, "TELEPORT",
				string.format("Distance=%.2f studs From=%s To=%s",
					dist, tostring(data.lastPosition), tostring(pos)))

			resetToValidPosition(player, character, "Teleport")

			data.detectionCount += 1
			if data.detectionCount >= 2 then
				punishPlayer(player, "Teleportation – repeated")
			end
			return
		end
	end

	data.lastPosition      = pos
	data.lastValidPosition = pos
	recordPosition(data, pos)
end

--------------------------------------------------------------------------------
-- DETECTION: STAT TAMPERING (WalkSpeed / JumpPower / JumpHeight)
--------------------------------------------------------------------------------
local function checkStatTamper(player, character)
	if not CONFIG.StatTamperDetection.Enabled then return end

	local data = playerData[player]
	if not data then return end

	local now = tick()
	if now - data.lastStatCheck < CONFIG.StatTamperDetection.CheckInterval then return end
	data.lastStatCheck = now

	local humanoid = character:FindFirstChild("Humanoid")
	if not humanoid then return end

	local flagged = false
	local details = {}

	if humanoid.WalkSpeed > CONFIG.StatTamperDetection.MaxWalkSpeed * 1.1 then
		table.insert(details, string.format("WalkSpeed=%.2f", humanoid.WalkSpeed))
		flagged = true
	end
	if humanoid.JumpPower > CONFIG.StatTamperDetection.MaxJumpPower * 1.1 then
		table.insert(details, string.format("JumpPower=%.2f", humanoid.JumpPower))
		flagged = true
	end
	if humanoid.JumpHeight > CONFIG.StatTamperDetection.MaxJumpHeight * 1.1 then
		table.insert(details, string.format("JumpHeight=%.2f", humanoid.JumpHeight))
		flagged = true
	end

	if flagged then
		logDetection(player, "STAT_TAMPER", table.concat(details, " | "))
		resetHumanoidStats(humanoid)
		data.detectionCount += 1
		if data.detectionCount >= CONFIG.PunishmentSystem.RepeatThreshold then
			punishPlayer(player, "Humanoid stat manipulation")
		end
	end
end

--------------------------------------------------------------------------------
-- DETECTION: BODY MOVER INJECTION
-- Exploiters inject BodyVelocity/BodyPosition etc. via LocalScripts or RemoteEvents
--------------------------------------------------------------------------------
local function checkBodyMovers(player, character)
	if not CONFIG.BodyMoverDetection.Enabled then return end

	local data = playerData[player]
	if not data then return end

	local now = tick()
	if now - data.lastBodyMoverCheck < CONFIG.BodyMoverDetection.CheckInterval then return end
	data.lastBodyMoverCheck = now

	local moverClasses = {
		"BodyVelocity", "BodyPosition", "BodyGyro",
		"BodyAngularVelocity", "BodyForce", "BodyThrust",
		"VectorForce", "AlignPosition", "AlignOrientation",
		"LinearVelocity", "AngularVelocity",
	}

	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			for _, child in ipairs(part:GetChildren()) do
				for _, mClass in ipairs(moverClasses) do
					if child:IsA(mClass) then
						-- Check whitelist
						local whitelisted = false
						for _, wl in ipairs(CONFIG.BodyMoverDetection.Whitelist) do
							if child == wl then whitelisted = true; break end
						end

						if not whitelisted then
							logDetection(player, "BODY_MOVER_INJECT",
								string.format("Found %s on %s.%s",
									mClass, part.Name, child.Name))
							child:Destroy()

							data.detectionCount += 1
							if data.detectionCount >= CONFIG.PunishmentSystem.RepeatThreshold then
								punishPlayer(player, "Physics object injection")
							end
						end
					end
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- DETECTION: GRAVITY MANIPULATION
-- Some exploits change workspace.Gravity via remote exploits or the physics engine
--------------------------------------------------------------------------------
local function checkGravityManipulation(player, character)
	if not CONFIG.GravityDetection.Enabled then return end

	local data = playerData[player]
	if not data then return end

	local now = tick()
	if now - data.lastGravityCheck < CONFIG.GravityDetection.CheckInterval then return end
	data.lastGravityCheck = now

	local currentGravity = workspace.Gravity
	local expected       = CONFIG.GravityDetection.ExpectedGravity
	local deviation      = math.abs(currentGravity - expected)

	if deviation > CONFIG.GravityDetection.AllowedDeviation then
		logDetection(player, "GRAVITY_MANIPULATED",
			string.format("Gravity=%.2f Expected=%.2f Deviation=%.2f",
				currentGravity, expected, deviation))

		-- Reset workspace gravity (affects all players — log prominently)
		warn(string.format(
			"[LUNOR AC] WARNING: workspace.Gravity was %.2f (expected %.2f). Resetting!",
			currentGravity, expected
		))
		workspace.Gravity = expected

		-- This is a server-side change so flag the triggering player
		punishPlayer(player, "Gravity manipulation detected")
	end
end

--------------------------------------------------------------------------------
-- DETECTION: ANTI-ESP (Proximity Culling)
-- ESP cheats read character positions from the Roblox DataModel.
-- We can't stop them reading it, but we CAN hide characters that the player
-- has no legitimate reason to see: too far away, or behind solid geometry.
-- This works by setting LocalTransparencyModifier on parts that aren't in LOS,
-- making the character invisible on cheaters' screens even if their ESP tries
-- to highlight it. Legitimate players see nothing different (their camera IS
-- in LOS of themselves, and nearby players are unaffected).
--------------------------------------------------------------------------------
local function hasLineOfSight(fromPlayer, toCharacter)
	local fromChar = fromPlayer.Character
	if not fromChar then return false end

	local fromRoot = fromChar:FindFirstChild("HumanoidRootPart")
	local toRoot   = toCharacter:FindFirstChild("HumanoidRootPart")
	if not fromRoot or not toRoot then return false end

	local origin    = fromRoot.Position
	local target    = toRoot.Position
	local direction = (target - origin)
	local distance  = direction.Magnitude

	if distance > CONFIG.ESPMitigation.MaxRenderDistance then return false end

	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { fromChar, toCharacter }
	params.FilterType = Enum.RaycastFilterType.Exclude

	-- Cast multiple samples (head, torso, feet) to reduce false-positives
	local sampleOffsets = {
		Vector3.new(0,  2, 0),
		Vector3.new(0,  0, 0),
		Vector3.new(0, -2, 0),
	}

	local hitCount = 0
	for i = 1, math.min(CONFIG.ESPMitigation.WallCheckSamples, #sampleOffsets) do
		local offset = sampleOffsets[i]
		local result = workspace:Raycast(origin + offset, (target + offset) - (origin + offset), params)
		if not result then
			hitCount += 1 -- clear LOS on this sample
		end
	end

	-- LOS = at least one clear sample
	return hitCount > 0
end

local function updateESPCulling(player)
	if not CONFIG.ESPMitigation.Enabled then return end

	local data = playerData[player]
	if not data then return end

	local now = tick()
	if now - data.lastESPCheck < CONFIG.ESPMitigation.CheckInterval then return end
	data.lastESPCheck = now

	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if otherPlayer == player then continue end

		local otherChar = otherPlayer.Character
		if not otherChar then continue end

		local canSee = hasLineOfSight(player, otherChar)

		-- Set LocalTransparencyModifier on all parts of the other character
		-- 1 = fully invisible to this client; 0 = normal
		-- This is a server-replicated property, so it affects what the client sees
		for _, part in ipairs(otherChar:GetDescendants()) do
			if part:IsA("BasePart") then
				part.LocalTransparencyModifier = canSee and 0 or 1
			end
		end
	end
end

--------------------------------------------------------------------------------
-- DETECTION: INFINITE JUMP
-- Tracks humanoid state transitions. A legitimate player can only jump when
-- grounded (or once in the air for double-jump). More jumps = exploit.
--------------------------------------------------------------------------------
local function setupInfiniteJumpDetection(player, character)
	if not CONFIG.InfiniteJumpDetection.Enabled then return end

	local humanoid = character:FindFirstChild("Humanoid")
	if not humanoid then return end

	local data = playerData[player]
	if not data then return end

	data.jumpCount     = 0
	data.lastJumpState = false

	local conn = humanoid.StateChanged:Connect(function(_, newState)
		if not playerData[player] then return end

		if newState == Enum.HumanoidStateType.Jumping then
			data.jumpCount += 1

			if data.jumpCount > CONFIG.InfiniteJumpDetection.MaxJumpsBeforeLand then
				logDetection(player, "INFINITE_JUMP",
					string.format("JumpCount=%d Max=%d",
						data.jumpCount, CONFIG.InfiniteJumpDetection.MaxJumpsBeforeLand))

				-- Force land state
				humanoid:ChangeState(Enum.HumanoidStateType.Freefall)

				-- TP back to last valid ground position
				local root = character:FindFirstChild("HumanoidRootPart")
				if root and data.lastValidPosition then
					root.CFrame = CFrame.new(data.lastValidPosition)
					root.AssemblyLinearVelocity = Vector3.zero
				end

				data.detectionCount += 1
				if data.detectionCount >= CONFIG.PunishmentSystem.RepeatThreshold then
					punishPlayer(player, "Infinite jump exploit")
				end
			end

		elseif newState == Enum.HumanoidStateType.Landed
			or newState == Enum.HumanoidStateType.Running
			or newState == Enum.HumanoidStateType.RunningNoPhysics then

			if CONFIG.InfiniteJumpDetection.ResetOnGrounded then
				data.jumpCount = 0
			end
		end
	end)

	if not playerConnections[player] then playerConnections[player] = {} end
	table.insert(playerConnections[player], conn)
end

--------------------------------------------------------------------------------
-- DETECTION: REMOTE EVENT FLOOD
-- Returns a wrapped FireServer that rate-limits calls from a given player.
-- Call this in your RemoteEvent.OnServerEvent handlers.
-- Usage: RemoteFloodGuard.wrap(remote, handler)
--------------------------------------------------------------------------------
local RemoteFloodGuard = {}

function RemoteFloodGuard.wrap(remote, handler)
	remote.OnServerEvent:Connect(function(player, ...)
		local data = playerData[player]
		if not data then handler(player, ...) return end

		local remoteName = remote.Name
		if not data.remoteCallLog[remoteName] then
			data.remoteCallLog[remoteName] = { calls = 0, windowStart = tick(), violations = 0 }
		end

		local log = data.remoteCallLog[remoteName]
		local now = tick()

		-- Roll window
		if now - log.windowStart >= CONFIG.RemoteFloodDetection.WindowSize then
			log.calls       = 0
			log.windowStart = now
		end

		log.calls += 1

		if log.calls > CONFIG.RemoteFloodDetection.MaxCallsPerSec then
			log.violations += 1
			logDetection(player, "REMOTE_FLOOD",
				string.format("Remote='%s' Calls=%d/s Violations=%d",
					remoteName, log.calls, log.violations))

			if log.violations >= CONFIG.RemoteFloodDetection.ViolationLimit then
				punishPlayer(player, "Remote event flooding – " .. remoteName)
			end
			return -- Drop the call
		end

		handler(player, ...)
	end)
end

--------------------------------------------------------------------------------
-- DETECTION: AIM ASSISTANCE / AIMBOT
-- Call AimTracker.recordShot(player, didHit, targetPlayer) from your
-- damage/hit-registration remote handler.
-- Flags statistically impossible hit rates and instant target-switching.
--------------------------------------------------------------------------------
local AimTracker = {}

function AimTracker.recordShot(shootingPlayer, didHit, targetPlayer)
	if not CONFIG.AimDetection.Enabled then return end

	local data = playerData[shootingPlayer]
	if not data then return end

	local now = tick()
	data.shotsFired += 1
	if didHit then data.shotsHit += 1 end

	-- Detect instant target switching (aimbot snaps between targets)
	if targetPlayer and targetPlayer.UserId ~= data.lastTargetId then
		local reactionMs = (now - data.lastShotTime) * 1000
		if data.lastTargetId ~= nil and reactionMs < CONFIG.AimDetection.MaxReactionMs then
			data.aimSuspicion += 2
			logDetection(shootingPlayer, "AIM_SNAP",
				string.format("TargetSwitch=%.0fms Threshold=%dms Suspicion=%d",
					reactionMs, CONFIG.AimDetection.MaxReactionMs, data.aimSuspicion))
		end
		data.lastTargetId = targetPlayer and targetPlayer.UserId or nil
	end

	data.lastShotTime = now

	-- Hit rate analysis (only after minimum sample)
	if data.shotsFired >= CONFIG.AimDetection.MinShotsToAnalyse then
		local hitRate = data.shotsHit / data.shotsFired

		if hitRate > CONFIG.AimDetection.MaxHitRate then
			data.aimSuspicion += 1
			logDetection(shootingPlayer, "AIM_ASSIST",
				string.format("HitRate=%.1f%% Max=%.1f%% Shots=%d Suspicion=%d",
					hitRate * 100, CONFIG.AimDetection.MaxHitRate * 100,
					data.shotsFired, data.aimSuspicion))
		end

		-- Decay over time window (rolling approximate)
		if data.shotsFired > 50 then
			data.shotsFired = math.floor(data.shotsFired * 0.8)
			data.shotsHit   = math.floor(data.shotsHit   * 0.8)
		end
	end

	if data.aimSuspicion >= 5 then
		punishPlayer(shootingPlayer, "Aim assistance detected")
	end
end

--------------------------------------------------------------------------------
-- DETECTION: DAMAGE VALIDATION
-- Validates incoming damage calls from clients.
-- Wire this up instead of letting clients fire damage directly.
-- Usage: DamageValidator.handleDamage(player, targetPlayer, amount, weapon)
--------------------------------------------------------------------------------
local DamageValidator = {}

function DamageValidator.handleDamage(attackingPlayer, targetPlayer, amount, weaponName)
	if not CONFIG.DamageValidation.Enabled then return false end

	local data = playerData[attackingPlayer]
	if not data then return false end

	-- Sanity checks
	if type(amount) ~= "number" or amount ~= amount then -- NaN check
		logDetection(attackingPlayer, "DAMAGE_NAN",
			string.format("Weapon='%s' Amount=NaN", tostring(weaponName)))
		punishPlayer(attackingPlayer, "Invalid damage value")
		return false
	end

	if amount <= 0 then
		logDetection(attackingPlayer, "DAMAGE_NEGATIVE",
			string.format("Weapon='%s' Amount=%.2f", tostring(weaponName), amount))
		return false
	end

	if amount > CONFIG.DamageValidation.MaxDamage then
		logDetection(attackingPlayer, "DAMAGE_OVERFLOW",
			string.format("Weapon='%s' Amount=%.2f Max=%d",
				tostring(weaponName), amount, CONFIG.DamageValidation.MaxDamage))
		punishPlayer(attackingPlayer, "Damage overflow exploit")
		return false
	end

	-- Verify target is a real, alive player
	if not targetPlayer or not targetPlayer.Parent then return false end
	local targetChar = targetPlayer.Character
	if not targetChar then return false end
	local targetHum = targetChar:FindFirstChild("Humanoid")
	if not targetHum or targetHum.Health <= 0 then return false end

	-- Verify attacking player is actually alive and close enough to deal damage
	local atkChar = attackingPlayer.Character
	if not atkChar then return false end
	local atkRoot = atkChar:FindFirstChild("HumanoidRootPart")
	local tgtRoot = targetChar:FindFirstChild("HumanoidRootPart")

	if atkRoot and tgtRoot then
		local dist = (atkRoot.Position - tgtRoot.Position).Magnitude
		-- Generous range check — tune MaxDamageRange to your longest-range weapon
		local MaxDamageRange = 300
		if dist > MaxDamageRange then
			logDetection(attackingPlayer, "DAMAGE_RANGE",
				string.format("Weapon='%s' Dist=%.2f Max=%d",
					tostring(weaponName), dist, MaxDamageRange))
			data.detectionCount += 1
			if data.detectionCount >= CONFIG.PunishmentSystem.RepeatThreshold then
				punishPlayer(attackingPlayer, "Out-of-range damage exploit")
			end
			return false
		end
	end

	-- All checks passed — apply damage server-side
	targetHum:TakeDamage(amount)
	return true
end

-- Expose both utilities globally so other server scripts can use them
_G.LunorAC = {
	RemoteFloodGuard = RemoteFloodGuard,
	AimTracker       = AimTracker,
	DamageValidator  = DamageValidator,
}

--------------------------------------------------------------------------------
-- DESCRIPTOR: Continuous per-character monitor loop
--------------------------------------------------------------------------------
local function monitorCharacter(player, character)
	local humanoid = character:WaitForChild("Humanoid", 8)
	if not humanoid then return end

	-- Reset joinTime on respawn so grace period re-applies
	local data = playerData[player]
	if data then
		data.joinTime          = tick()
		data.lastPosition      = nil
		data.lastValidPosition = nil
		data.airTime           = 0
		data.flySuspicion      = 0
		data.noclipViolations  = 0
		data.speedViolations   = 0
		data.jumpCount         = 0
	end

	setupInfiniteJumpDetection(player, character)

	local lastTick = tick()

	local conn = RunService.Heartbeat:Connect(function()
		if not player.Parent or not character.Parent then return end

		local now = tick()
		local dt  = now - lastTick
		lastTick  = now

		if dt <= 0 or dt > 1 then return end

		local ok, err = pcall(function()
			checkFlyHack(player, character, dt)
			checkNoclip(player, character)
			checkSpeedHack(player, character)
			checkTeleport(player, character)
			checkStatTamper(player, character)
			checkBodyMovers(player, character)
			checkGravityManipulation(player, character)
			updateESPCulling(player)
		end)

		if not ok then
			debugLog("Error in monitor loop for " .. player.Name .. ": " .. tostring(err))
		end
	end)

	-- Track connection for cleanup
	if not playerConnections[player] then playerConnections[player] = {} end
	table.insert(playerConnections[player], conn)

	-- Auto-disconnect when character is removed
	character.AncestryChanged:Connect(function()
		if not character.Parent then
			conn:Disconnect()
		end
	end)
end

--------------------------------------------------------------------------------
-- PLAYER LIFECYCLE
--------------------------------------------------------------------------------
local function onPlayerAdded(player)
	playerData[player] = createPlayerData(player)

	player.CharacterAdded:Connect(function(character)
		task.wait(0.5) -- Wait for character to fully load
		monitorCharacter(player, character)
	end)

	-- Handle if character already exists (e.g. hot-loading the script)
	if player.Character then
		task.wait(0.5)
		monitorCharacter(player, player.Character)
	end

	debugLog(string.format("Monitoring started for %s (%d)", player.Name, player.UserId))
end

local function onPlayerRemoving(player)
	-- Clean up all connections
	if playerConnections[player] then
		for _, conn in ipairs(playerConnections[player]) do
			conn:Disconnect()
		end
		playerConnections[player] = nil
	end

	-- Log summary if they had detections
	local uid = player.UserId
	if detectionLog[uid] and #detectionLog[uid] > 0 then
		warn(string.format("[LUNOR AC] Player %s (%d) left with %d detection(s) on record.",
			player.Name, uid, #detectionLog[uid]))
	end

	playerData[player]  = nil
	-- Optionally persist detectionLog[uid] to DataStore here
end

--------------------------------------------------------------------------------
-- BOOTSTRAP
--------------------------------------------------------------------------------
Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

print(string.format(
	"[LUNOR AC] v3.0.0 initialized | 12 module(s) active | %d player(s) monitored",
	#Players:GetPlayers()
))
