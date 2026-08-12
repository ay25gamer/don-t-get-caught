--!strict
--[[
	PlaceholderMapService.luau

	TEMPORARY. Builds simple grey-box geometry (floor, walls, a dining table,
	Constants.Seating.SeatCount place settings, and a blocky placeholder guard figure) so
	SeatingService and GuardService have something real to work with before an artist builds
	the real "Map Design" (dark atmosphere, wood textures, old furniture, rain outside, ...)
	and a real rigged guard character described in the design doc.

	The dining room is a real house sitting on real ground, not a box floating in Roblox's
	default void: a grass Ground plane extends well past the walls, a flat overhanging Roof
	caps the house, and a handful of simple trees dress the exterior — see buildGround/
	buildRoof/buildTrees below. This matters beyond looks: SpectatorController lets a caught
	player fly freely, so they can and will end up outside the four walls.

	Delete this file once that real geometry exists in Place1.rbxl. SeatingService doesn't care
	where seats come from — it only needs a Model tagged Constants.Tags.DinnerSeat with a
	child named "SeatPart" (a Seat instance). GuardService doesn't care where the guard comes
	from either — it only needs Workspace.DiningRoom.Guard with Newspaper/Gun part children
	(Gun needs a MuzzleFlash PointLight and a GunshotSound Sound child). Keep those contracts
	when building the real map/guard and nothing else in the codebase needs to change.

	Idempotent: does nothing if Workspace.DiningRoom already exists, so re-running the server
	(or a real map replacing this output under the same name) never duplicates/fights it.
]]

local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))
local Logger = Shared.Logger.new("PlaceholderMapService")
local Constants = Shared.Constants

local ROOM_SIZE = Vector3.new(50, 20, 40) -- X, Y, Z
local TABLE_HEIGHT = 3
local TABLE_SIZE = Vector3.new(6, TABLE_HEIGHT, 26) -- long rectangular table, seats along the Z sides
local SEAT_HEIGHT = 2
local SEAT_GAP_FROM_TABLE = 2.5 -- seat center distance from the table's side edge

local GROUND_SIZE = Vector3.new(400, 4, 400) -- grass extending well past the house on all sides
local ROOF_OVERHANG = 3
local ROOF_THICKNESS = 2
local TREE_TRUNK_HEIGHT = 6
local TREE_LEAVES_RADIUS = 4

local PlaceholderMapService = {}
-- Match-only — no dining room needed in the Hub. See Shared/Util/ServerMode.luau.
PlaceholderMapService.Modes = { "Match" }

local function newPart(name: string, size: Vector3, cframe: CFrame, color: Color3, parent: Instance, canCollide: boolean): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Anchored = true
	part.CanCollide = canCollide
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function buildRoomShell(parent: Instance)
	newPart("Floor", Vector3.new(ROOM_SIZE.X, 1, ROOM_SIZE.Z), CFrame.new(0, -0.5, 0), Color3.fromRGB(90, 78, 64), parent, true)

	local wallY = ROOM_SIZE.Y / 2
	local wallColor = Color3.fromRGB(40, 36, 32)
	newPart("Wall_North", Vector3.new(ROOM_SIZE.X, ROOM_SIZE.Y, 1), CFrame.new(0, wallY, -ROOM_SIZE.Z / 2), wallColor, parent, true)
	newPart("Wall_South", Vector3.new(ROOM_SIZE.X, ROOM_SIZE.Y, 1), CFrame.new(0, wallY, ROOM_SIZE.Z / 2), wallColor, parent, true)
	newPart("Wall_East", Vector3.new(1, ROOM_SIZE.Y, ROOM_SIZE.Z), CFrame.new(ROOM_SIZE.X / 2, wallY, 0), wallColor, parent, true)
	newPart("Wall_West", Vector3.new(1, ROOM_SIZE.Y, ROOM_SIZE.Z), CFrame.new(-ROOM_SIZE.X / 2, wallY, 0), wallColor, parent, true)
end

-- Grounds the house in an actual outdoor setting — grass extending well past the walls in
-- every direction, sitting one stud below the house Floor's bottom so there's a small natural
-- step up into the house rather than the two flat planes fighting for the same Y (and rather
-- than the house looking like it's floating in Roblox's default void). Spectating players
-- (SpectatorController lets a caught player fly freely) can wander outside the walls, so this
-- needs to actually be there, not just implied.
local function buildGround(parent: Instance)
	newPart("Ground", GROUND_SIZE, CFrame.new(0, -1 - GROUND_SIZE.Y / 2, 0), Color3.fromRGB(58, 96, 48), parent, true)
end

-- A simple flat overhanging roof — deliberately not a pitched/gabled shape, which would need
-- rotated parts whose exact angle math is easy to get subtly wrong without being able to see
-- the result; a flat slab unambiguously reads as "this box is a house" from outside with zero
-- risk of a twisted/inverted roof.
local function buildRoof(parent: Instance)
	local wallTopY = ROOM_SIZE.Y
	local roofSize = Vector3.new(ROOM_SIZE.X + ROOF_OVERHANG * 2, ROOF_THICKNESS, ROOM_SIZE.Z + ROOF_OVERHANG * 2)
	newPart("Roof", roofSize, CFrame.new(0, wallTopY + ROOF_THICKNESS / 2, 0), Color3.fromRGB(70, 32, 30), parent, false)
end

-- A handful of simple trees scattered around the house so the exterior doesn't read as bare
-- grass to the horizon — trunk + leaves, two Parts each, same "simple primitives" placeholder
-- style as everything else in this file.
local function buildTree(parent: Instance, position: Vector3, index: number)
	local treeModel = Instance.new("Model")
	treeModel.Name = ("Tree%d"):format(index)

	local trunk = newPart(
		"Trunk",
		Vector3.new(1.5, TREE_TRUNK_HEIGHT, 1.5),
		CFrame.new(position + Vector3.new(0, TREE_TRUNK_HEIGHT / 2, 0)),
		Color3.fromRGB(74, 50, 34),
		treeModel,
		true
	)

	local leaves = newPart(
		"Leaves",
		Vector3.new(TREE_LEAVES_RADIUS * 2, TREE_LEAVES_RADIUS * 2, TREE_LEAVES_RADIUS * 2),
		CFrame.new(position + Vector3.new(0, TREE_TRUNK_HEIGHT + TREE_LEAVES_RADIUS * 0.6, 0)),
		Color3.fromRGB(46, 92, 44),
		treeModel,
		false
	)
	leaves.Shape = Enum.PartType.Ball

	treeModel.PrimaryPart = trunk
	treeModel.Parent = parent
end

local function buildTrees(parent: Instance)
	local treePositions = {
		Vector3.new(ROOM_SIZE.X / 2 + 14, 0, ROOM_SIZE.Z / 2 + 10),
		Vector3.new(-(ROOM_SIZE.X / 2 + 16), 0, ROOM_SIZE.Z / 2 + 16),
		Vector3.new(ROOM_SIZE.X / 2 + 18, 0, -(ROOM_SIZE.Z / 2 + 8)),
		Vector3.new(-(ROOM_SIZE.X / 2 + 10), 0, -(ROOM_SIZE.Z / 2 + 18)),
		Vector3.new(0, 0, -(ROOM_SIZE.Z / 2 + 26)),
	}
	for index, position in ipairs(treePositions) do
		buildTree(parent, position, index)
	end
end

local function buildTable(parent: Instance): Part
	return newPart("Table", TABLE_SIZE, CFrame.new(0, TABLE_HEIGHT / 2, 0), Color3.fromRGB(64, 42, 28), parent, true)
end

-- One seat + its place setting (Plate, Food, Fork, Cup). `side` is +1 (east, +X) or -1 (west, -X).
local function buildSeat(index: number, side: number, z: number, parent: Instance)
	local seatModel = Instance.new("Model")
	seatModel.Name = ("Seat%d"):format(index)

	local seatX = side * (TABLE_SIZE.X / 2 + SEAT_GAP_FROM_TABLE)
	local seatPosition = Vector3.new(seatX, SEAT_HEIGHT, z)
	local facingCFrame = CFrame.lookAt(seatPosition, Vector3.new(0, SEAT_HEIGHT, z)) -- face across the table

	local seatPart = Instance.new("Seat")
	seatPart.Name = "SeatPart"
	seatPart.Size = Vector3.new(2, 1, 2)
	seatPart.CFrame = facingCFrame
	seatPart.Anchored = true
	seatPart.Color = Color3.fromRGB(87, 57, 41)
	seatPart.Parent = seatModel

	local plateX = side * (TABLE_SIZE.X / 2 - 1)
	local plateCFrame = CFrame.new(plateX, TABLE_HEIGHT + 0.075, z)
	newPart("Plate", Vector3.new(1.5, 0.15, 1.5), plateCFrame, Color3.fromRGB(235, 230, 220), seatModel, false)

	local foodCFrame = plateCFrame * CFrame.new(0, 0.2, 0)
	newPart("Food", Vector3.new(0.9, 0.4, 0.9), foodCFrame, Color3.fromRGB(178, 120, 70), seatModel, false)

	local forkCFrame = CFrame.new(plateX, TABLE_HEIGHT + 0.1, z + 1)
	newPart("Fork", Vector3.new(0.15, 0.05, 1), forkCFrame, Color3.fromRGB(200, 200, 205), seatModel, false)

	local cupX = side * (TABLE_SIZE.X / 2 - 1)
	local cupCFrame = CFrame.new(cupX, TABLE_HEIGHT + 0.25, z - 1.3)
	newPart("Cup", Vector3.new(0.5, 0.5, 0.5), cupCFrame, Color3.fromRGB(210, 225, 235), seatModel, false)

	seatModel.Parent = parent
	CollectionService:AddTag(seatModel, Constants.Tags.DinnerSeat)
end

local function guardCFrame(): CFrame
	local guardZ = -TABLE_SIZE.Z / 2 - 4
	local guardPosition = Vector3.new(0, SEAT_HEIGHT, guardZ)
	return CFrame.lookAt(guardPosition, Vector3.new(0, SEAT_HEIGHT, 0))
end

local function buildGuardSpot(parent: Instance, facingCFrame: CFrame)
	local marker = newPart("GuardSpot", Vector3.new(2, 1, 2), facingCFrame, Color3.fromRGB(20, 20, 20), parent, false)
	marker.Transparency = 0.5
	CollectionService:AddTag(marker, Constants.Tags.GuardSpot)
end

local GUARD_TORSO_SIZE = Vector3.new(2, 3, 1)
local GUARD_HEAD_SIZE = Vector3.new(1.2, 1.2, 1.2)
local GUARD_NEWSPAPER_SIZE = Vector3.new(1.6, 2, 0.1)
local GUARD_GUN_SIZE = Vector3.new(0.3, 0.3, 1.2)

-- Placeholder guard figure — a torso/head block with a Newspaper part (GuardService tweens
-- this up/down between Reading/Looking) and a Gun part (GuardService aims/flashes this at a
-- caught player). Local -Z is "forward" (toward the table, see `guardCFrame`'s `CFrame.lookAt`),
-- so anything positioned with a negative local Z offset sits in front of the guard.
--
-- The Gun carries a PointLight (muzzle flash — needs no texture asset, just a brightness
-- tween) and a Sound with an empty SoundId. Assign a real gunshot asset to that SoundId once
-- one is available; GuardService already calls :Play() on it at the right moment.
local function buildGuard(parent: Instance, facingCFrame: CFrame)
	local guardModel = Instance.new("Model")
	guardModel.Name = "Guard"

	local torso = newPart("Torso", GUARD_TORSO_SIZE, facingCFrame * CFrame.new(0, 2.5, 0), Color3.fromRGB(35, 35, 40), guardModel, false)
	local head = newPart("Head", GUARD_HEAD_SIZE, facingCFrame * CFrame.new(0, 4.5, 0), Color3.fromRGB(210, 180, 150), guardModel, false)

	-- rbxasset:// references a file bundled with the Roblox client itself (the classic default
	-- avatar face) — no uploaded asset ID needed, works offline, always available. Placed on
	-- the Front face since local -Z is "forward" here (see the comment above).
	local face = Instance.new("Decal")
	face.Name = "Face"
	face.Texture = "rbxasset://textures/face.png"
	face.Face = Enum.NormalId.Front
	face.Parent = head

	newPart("Newspaper", GUARD_NEWSPAPER_SIZE, facingCFrame * CFrame.new(0, 4.2, -1), Color3.fromRGB(230, 225, 205), guardModel, false)
	local gun = newPart("Gun", GUARD_GUN_SIZE, facingCFrame * CFrame.new(0.9, 2.6, -0.3), Color3.fromRGB(25, 25, 25), guardModel, false)

	local muzzleFlash = Instance.new("PointLight")
	muzzleFlash.Name = "MuzzleFlash"
	muzzleFlash.Color = Color3.fromRGB(255, 200, 120)
	muzzleFlash.Brightness = 0
	muzzleFlash.Range = 12
	muzzleFlash.Enabled = true
	muzzleFlash.Parent = gun

	local gunshotSound = Instance.new("Sound")
	gunshotSound.Name = "GunshotSound"
	gunshotSound.SoundId = ""
	gunshotSound.Volume = 1
	gunshotSound.Parent = gun

	guardModel.PrimaryPart = torso
	guardModel.Parent = parent
end

function PlaceholderMapService.Init()
	if Workspace:FindFirstChild("DiningRoom") then
		Logger:Debug("Workspace.DiningRoom already exists — skipping placeholder map generation.")
		return
	end

	local diningRoom = Instance.new("Folder")
	diningRoom.Name = "DiningRoom"

	buildGround(diningRoom)
	buildRoomShell(diningRoom)
	buildRoof(diningRoom)
	buildTrees(diningRoom)
	buildTable(diningRoom)
	local facingCFrame = guardCFrame()
	buildGuardSpot(diningRoom, facingCFrame)
	buildGuard(diningRoom, facingCFrame)

	local seatCount = Constants.Seating.SeatCount
	local seatsPerSide = seatCount / 2
	assert(seatsPerSide == math.floor(seatsPerSide), "Constants.Seating.SeatCount must be even to split evenly across both sides of the table")

	local seatIndex = 0
	for i = 1, seatsPerSide do
		local z = -TABLE_SIZE.Z / 2 + TABLE_SIZE.Z * i / (seatsPerSide + 1)
		for _, side in ipairs({ 1, -1 }) do
			seatIndex += 1
			buildSeat(seatIndex, side, z, diningRoom)
		end
	end

	diningRoom.Parent = Workspace
	Logger:Info(("Placeholder dining room built with %d seats."):format(seatIndex))
end

return PlaceholderMapService
