--!strict
--[[
	PlayerDataService.luau

	Owns loading, session-locking, and saving every player's persistent data via ProfileStore
	(vendored, unmodified, in Packages/ProfileStore.luau — see README.md and
	ThirdPartyLicenses/ProfileStore-LICENSE.txt at the repo root). Every other service must
	read/write player data through this service (:GetData / :GetProfile) — never touch
	DataStores directly.

	Session lifecycle:
	  PlayerAdded    -> StartSessionAsync -> Reconcile -> AddUserId -> ProfileLoaded fired
	  PlayerRemoving -> ProfileRemoving fired -> EndSession
	  Session stolen by another server (OnSessionEnd fires while the player is still here)
	    -> the player is kicked, since this server can no longer be trusted to hold their data.

	In Studio, sessions are routed to ProfileStore.Mock (fake, in-memory, forgotten on server
	shutdown) so iterating on gameplay never touches real player data and never requires
	enabling "Studio Access to API Services". Flip USE_MOCK_IN_STUDIO to false to test real
	persistence from Studio.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))
local Logger = Shared.Logger.new("PlayerDataService")

local ProfileStoreLib = require(script.Parent.Parent.Packages.ProfileStore)

local USE_MOCK_IN_STUDIO = true
local PROFILE_STORE_NAME = Shared.Constants.DataStore.ProfileStoreName

--[[
	Data schema. This is the full contract of what gets persisted for a player (see the
	"DATA TO SAVE" / "PLAYER PROFILE" sections of the design doc). Fields reserved here before
	their owning system existed (Missions, Inventory, Boosts, ...) got filled in with real
	shapes once ShopService/MonetizationService/DailyMissionService were built — that's the
	payoff of reserving them early: Profile:Reconcile() fills in any field added to this
	template after a player's existing save was already written, so growing this table over
	time is always safe, no migration script ever needed.

	"Statistics.TotalEliminations" tracks the number of times THIS player has been caught by
	the guard (there is no player-vs-player kill mechanic in this game).
]]
export type PlayerProfileData = {
	Gold: number,
	XP: number,
	Level: number,
	Wins: number,

	Statistics: {
		MatchesPlayed: number,
		LongestSurvivalSeconds: number,
		CurrentWinStreak: number,
		TotalEliminations: number,
	},

	Inventory: {
		OwnedCosmetics: { string },
		EquippedCosmetics: {
			Fork: string,
			Plate: string,
			Chair: string,
			Food: string,
			Emotes: { string },
			Title: string,
			VictoryAnimation: string,
		},
		FavoriteCosmetic: string,
	},

	DailyRewards: {
		LastClaimedTimestamp: number,
		Streak: number,
	},

	Missions: {
		-- Keyed by DailyMissionCatalog id.
		Progress: { [string]: { Count: number, Claimed: boolean } },
		LastRefreshTimestamp: number, -- os.time() of the last daily reset; see DailyMissionService
	},

	Settings: {
		MusicVolume: number,
		SfxVolume: number,
		CameraSensitivity: number,
		Graphics: string,
		ColorblindMode: boolean,
		MotionBlur: boolean,
		Vibration: boolean,
	},

	OwnedGamepasses: { number },
	ProcessedReceipts: { [string]: boolean },

	-- os.time() timestamps; a boost is active while os.time() < the value. 0 means inactive.
	Boosts: {
		DoubleXPUntil: number,
		DoubleGoldUntil: number,
	},
}

local DEFAULT_DATA: PlayerProfileData = {
	Gold = 0,
	XP = 0,
	Level = 1,
	Wins = 0,

	Statistics = {
		MatchesPlayed = 0,
		LongestSurvivalSeconds = 0,
		CurrentWinStreak = 0,
		TotalEliminations = 0,
	},

	Inventory = {
		OwnedCosmetics = {},
		-- Must match real CosmeticCatalog.luau ids (e.g. "Fork_Default"), not a bare "Default" —
		-- ShopService/SkinVisualsService/HudController all resolve these via findItem(id) against
		-- the catalog, which only matches on the catalog's actual Id strings.
		EquippedCosmetics = {
			Fork = "Fork_Default",
			Plate = "Plate_Default",
			Chair = "Chair_Default",
			Food = "Food_Default",
			Emotes = {},
			Title = "",
			VictoryAnimation = "Victory_Default",
		},
		FavoriteCosmetic = "",
	},

	DailyRewards = {
		LastClaimedTimestamp = 0,
		Streak = 0,
	},

	Missions = {
		Progress = {},
		LastRefreshTimestamp = 0,
	},

	Settings = {
		MusicVolume = 0.5,
		SfxVolume = 0.5,
		CameraSensitivity = 0.5,
		Graphics = "Auto",
		ColorblindMode = false,
		MotionBlur = true,
		Vibration = true,
	},

	OwnedGamepasses = {},
	ProcessedReceipts = {},

	Boosts = {
		DoubleXPUntil = 0,
		DoubleGoldUntil = 0,
	},
}

export type PlayerProfile = ProfileStoreLib.Profile<PlayerProfileData>

-- ProfileStore.New() returns a ProfileStore<T> (which carries .Mock), but once we've picked
-- between the live store and store.Mock we only ever call :StartSessionAsync() on the result.
-- ProfileStoreStandard<T> (the type of .Mock) isn't exported by the library, so this narrow
-- structural type describes just the one method we need — both the live store and .Mock
-- satisfy it.
type SessionStore = {
	StartSessionAsync: (self: any, profile_key: string, params: { Steal: boolean? }) -> (PlayerProfile?),
}

local PlayerDataService = {}
PlayerDataService.__index = PlayerDataService

local self = setmetatable({
	_profiles = {} :: { [Player]: PlayerProfile },
	_store = nil :: SessionStore?,
	-- (player: Player, profile: PlayerProfile) -- fired once a player's data has finished loading
	ProfileLoaded = Shared.Signal.new(),
	-- (player: Player, profile: PlayerProfile) -- fired just before a leaving player's session ends
	ProfileRemoving = Shared.Signal.new(),
}, PlayerDataService)

-- Colon-sugar methods (`function PlayerDataService:Foo()`) would type their implicit `self`
-- from the empty `PlayerDataService` class table, not from the actual singleton above. Every
-- public method below takes an explicit `self: Self` parameter instead so it's fully typed
-- (see RoundService.luau for a case where skipping this actually breaks type-checking).
type Self = typeof(self)

-- profile_key must stay stable even if a player changes their username.
local function profileKeyForPlayer(player: Player): string
	return "Player_" .. tostring(player.UserId)
end

local function onPlayerAdded(player: Player)
	local store = self._store
	assert(store, "PlayerDataService.Init must run before players can join")

	-- Cancel prevents ProfileStore from continuing to retry the DataStore call after the
	-- player has already left (e.g. they left during a slow/retrying load).
	local profile = store:StartSessionAsync(profileKeyForPlayer(player), {
		Cancel = function()
			return player:IsDescendantOf(Players) == false
		end,
	} :: any)

	if not player:IsDescendantOf(Players) then
		-- Player left while their session was loading.
		if profile then
			profile:EndSession()
		end
		return
	end

	if not profile then
		Logger:Warn(("Could not start a data session for %s (session conflict) — kicking."):format(player.Name))
		player:Kick("Your data could not be loaded right now. Please rejoin in a moment.")
		return
	end

	profile:AddUserId(player.UserId)
	profile:Reconcile()

	profile.OnSessionEnd:Connect(function()
		self._profiles[player] = nil
		if player:IsDescendantOf(Players) then
			player:Kick("Your data was loaded on another server. Please rejoin.")
		end
	end)

	self._profiles[player] = profile
	Logger:Info(("Profile loaded for %s."):format(player.Name))
	self.ProfileLoaded:Fire(player, profile)
end

local function onPlayerRemoving(player: Player)
	local profile = self._profiles[player]
	if not profile then
		return
	end

	self.ProfileRemoving:Fire(player, profile)
	self._profiles[player] = nil
	profile:EndSession()
end

function PlayerDataService.Init(self: Self)
	local rootStore = ProfileStoreLib.New(PROFILE_STORE_NAME, DEFAULT_DATA)

	-- The `:: any :: SessionStore` double-cast below works around a Luau typechecker
	-- limitation unifying ProfileStore's recursive `T & JSONAcceptable` generic across two
	-- structurally-identical instantiations (confirmed via luau-lsp — the shapes genuinely
	-- match at runtime, StartSessionAsync really does return what SessionStore declares).
	if USE_MOCK_IN_STUDIO and RunService:IsStudio() then
		self._store = (rootStore.Mock :: any) :: SessionStore
		Logger:Warn("Using ProfileStore.Mock — data will NOT persist between play sessions (Studio only).")
	else
		self._store = (rootStore :: any) :: SessionStore
	end
end

function PlayerDataService.Start(self: Self)
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- Handle players who joined before this service finished starting.
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end
end

-- Returns the live Profile object, or nil if the player's data hasn't finished loading yet
-- (or they've already left). Prefer :GetData() unless you need Profile-level methods.
function PlayerDataService.GetProfile(self: Self, player: Player): PlayerProfile?
	return self._profiles[player]
end

-- Returns the player's mutable data table, or nil if it isn't loaded yet. Server-authoritative
-- systems read AND write through this table directly (e.g. `data.Gold += 10`) — ProfileStore
-- saves whatever is in here automatically while the session is active.
function PlayerDataService.GetData(self: Self, player: Player): PlayerProfileData?
	local profile = self._profiles[player]
	return if profile then profile.Data else nil
end

return self
