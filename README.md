# Don't Get Caught

A 2–10 player multiplayer horror-stealth party game for Roblox. Players sit at a dining
table and must eat their food without being seen by a guard who alternates between reading
a newspaper and looking up to check for movement. Last player alive wins.

This repo is the **source of truth** for the game's code. `Place1.rbxl` is a Roblox Studio
place file — a binary format — so it is never hand-edited directly. Instead, this project
uses [Rojo](https://rojo.space) to sync a normal folder of `.luau` files into Studio live.
That gives us real version control, code review, and an editor with IntelliSense, instead of
writing Lua inside Studio's built-in script editor.

## Status

**All 11 roadmap steps are done**, plus a lobby/matchmaking layer on top. The full loop is
playable end to end: **Hub** (create/join a private party via a short code, or browse/create
public rooms) → teleport into a **Match** server → Lobby → Intermission → seated players eat
while a guard reads/looks → caught players are shot, ragdolled, and spectate → the round ends,
rewards/stats are granted → back to a fresh Lobby (same server, ready for another round) — with
a real HUD, a functional Gold shop and inventory, a monetization framework (Developer
Products/Game Passes, including Instant Revive), daily login + missions, and an
atmosphere/polish pass on top. See [Lobby & Matchmaking](#lobby--matchmaking) for how the
Hub/Match split works, and **read its testing section's first paragraph before assuming
something's broken** — several pieces of this specific layer cannot be verified inside a local
Studio session, by nature of what they do (real cross-server teleports).

**What's deliberately out of scope**, and why — not oversights, explicit calls given what a
"system" actually means for each:

- **Season Pass & Events** (Halloween/Christmas/etc.) — these are primarily content-authoring
  work (dozens of catalog entries, time-boxed availability windows), not new mechanics. They'd
  reuse the exact same pattern `CosmeticCatalog.luau` already established — a "Season" would
  just be a second, XP-gated catalog list read the same way. Building that scaffolding without
  any actual seasonal content to put in it wouldn't demonstrate anything real.
- **Real art, audio, and animation assets** — every visual/audio effect in this codebase is
  either a primitive-part placeholder (guard figure, muzzle flash, hit effect) or has an
  explicit empty-`SoundId`/`GamePassId`/`DeveloperProduct` hook ready for a real asset ID to be
  dropped in. See `PlaceholderMapService.luau` and `Shared/Constants/MonetizationIds.luau` for
  exactly what needs manual setup in Roblox Studio / the Creator Dashboard and where.
- **Multi-table / multi-round-simultaneously support** — the design doc describes one dining
  table per server, which is what's built; running several tables per server would be a
  reasonable future scaling change (each system would need to become per-table-instanced
  rather than singleton) but isn't what was asked for.

See [Development Strategy](#development-strategy) for the full step-by-step checklist and
[Testing this step](#testing-this-step) for how to verify all of it.

## Project structure

```
default.project.json      Rojo project file — maps src/ onto the Roblox DataModel
rokit.toml                 Pinned toolchain version (Rojo 7.6.1)
src/
  Server/                  -> ServerScriptService.Server
    init.server.luau        Bootstrap: loads, Inits, then Starts every service
    Services/
      PlayerDataService.luau  Loads/saves player data via ProfileStore (see below)
      RoundService.luau       Lobby/Intermission/InProgress/Ended state machine (see below)
      SeatingService.luau     Assigns/seats round participants at real seats (see below)
      PlaceholderMapService.luau  TEMPORARY grey-box map — delete once real art exists (see below)
      EatingService.luau       Server-authoritative bites, food %, per-player noise (see below)
      GuardService.luau        Reading/Looking + suspicion + detection/shooting (see below)
      SpectatorService.luau    Bridges round/elimination state to clients (see below)
      RewardService.luau       Match stats + winner Gold/XP/Wins (see below)
      HudReplicationService.luau  Bridges round/eating/profile state to the HUD (see below)
      LeaderstatsService.luau  Populates the native Roblox leaderboard (see below)
      ShopService.luau         Gold purchases + equipping cosmetics (see below)
      MonetizationService.luau ProcessReceipt + Game Pass ownership (see below)
      RevivalService.luau      Orchestrates bringing an eliminated player back (see below)
      SkinVisualsService.luau  Applies equipped Fork/Plate/Chair/Food skins in the world (see below)
      DailyService.luau        Daily login reward + daily missions (see below)
      AtmosphereService.luau   Lighting/fog/thunder — asset-free mood (see below)
      PartyService.luau        HUB-only: private party codes via Reserved Servers (see below)
      PublicRoomService.luau   HUB-only: live browsable public room list (see below)
      RoomReportingService.luau  MATCH-only: reports a public room's live status (see below)
    Packages/
      ProfileStore.luau       Vendored data-persistence library (see below)
  Client/                  -> StarterPlayer.StarterPlayerScripts.Client
    init.client.luau        Bootstrap: loads, Inits, then Starts every controller
    Controllers/
      EatingController.luau    MATCH-only: held Left Mouse/touch -> RequestBite (see below)
      SpectatorController.luau MATCH-only: eliminated players' camera + camera shake
      HudController.luau       MATCH-only: builds the in-round HUD/menu UI tree (see below)
      HubController.luau       HUB-only: builds the party/public-room menu UI (see below)
    UI/Widgets.luau            Shared Instance-building helpers (newFrame/newLabel/newButton/...)
  Shared/                  -> ReplicatedStorage.Shared
    init.luau                Aggregates the modules below behind one require()
    Constants/GameConstants.luau   All tunable numbers (round timing, guard timing, player limits...)
    Constants/MonetizationIds.luau  PLACEHOLDER Developer Product / Game Pass IDs (see below)
    Data/CosmeticCatalog.luau      Every cosmetic item — shop, inventory, level-unlocks (see below)
    Data/DailyMissionCatalog.luau  The 3 daily missions (see below)
    Remotes/Remotes.luau           Central RemoteEvent/RemoteFunction registry
    Types/Types.luau               Shared Luau type definitions (RoundPhase, GuardState, RoomInfo, ...)
    Util/Signal.luau                Lightweight event class for module-to-module signalling
    Util/Logger.luau                Tagged console logger
    Util/Progression.luau           Shared XP/Level/Gold + boost math (see below)
    Util/RateLimiter.luau           Per-player cooldown guard for spam-prone remotes (see below)
    Util/ServerMode.luau            Hub vs Match detection (see below)
  StarterGui/              -> StarterGui (deliberately empty — see its own README)
ThirdPartyLicenses/         License texts for vendored code, kept out of the synced tree
```

### Why this shape

- **Everything server-authoritative.** Services live in `ServerScriptService` and own all
  game state. Controllers on the client only present state and forward player intent —
  they never decide outcomes.
- **Two-phase Init/Start lifecycle.** Both bootstraps require every module in their folder,
  call `:Init()` on all of them, *then* call `:Start()` on all of them. This means a
  service/controller can safely look up a sibling inside `Init` without load-order bugs,
  because every sibling is guaranteed to exist (and have finished its own `Init`) before any
  `Start` runs. New systems require zero edits to the bootstrap — just drop a ModuleScript
  into `Services/` or `Controllers/`.
- **Mode-gating, same mechanism.** A service/controller can export `Modes = {"Match"}` (or
  `{"Hub"}`) to skip its own Init/Start on a server running the other mode — see
  [Lobby & Matchmaking](#lobby--matchmaking). No `Modes` field means it runs in both. Every
  module still gets *required* either way (cheap, side-effect-free); only Init/Start are gated,
  so a Match-only service just sits inert on a Hub server instead of needing its own internal
  mode checks scattered through its logic.
- **One shared entry point.** `require(ReplicatedStorage.Shared)` gives you
  `Shared.Constants`, `Shared.Remotes`, `Shared.Signal`, `Shared.Logger`, `Shared.Types` —
  no deep-path requires scattered across the codebase.
- **Remotes are centrally registered**, not created ad hoc inside random scripts, so it's
  always obvious what the full client/server surface area is.

### ProfileStore & PlayerDataService

`src/Server/Packages/ProfileStore.luau` is the vendored, unmodified source of
[ProfileStore](https://github.com/MadStudioRoblox/ProfileStore) by Mad Studio (loleris) — the
actively-maintained successor to ProfileService, MIT licensed (full text in
`ThirdPartyLicenses/ProfileStore-LICENSE.txt`). It handles DataStore saving with session
locking so two servers can never corrupt the same player's save.

`src/Server/Services/PlayerDataService.luau` is the only system allowed to touch it. It:

- Defines `PlayerProfileData` — the full save schema (Gold, XP, Level, Wins, Statistics,
  Inventory, DailyRewards, Missions, Settings, OwnedGamepasses, ProcessedReceipts), matching
  the design doc's "Data to Save" / "Player Profile" lists. Fields for systems that don't
  exist yet (Missions, Shop) reserve their shape now; `Profile:Reconcile()` means new fields
  added to this template later automatically backfill existing saves — no migration script
  needed.
- Starts a session on `Players.PlayerAdded`, kicks the player if the session couldn't start
  (e.g. their data is session-locked by another server) or if a running session gets stolen.
- Exposes `PlayerDataService:GetData(player) --> PlayerProfileData?` for other services to
  read/write (e.g. `data.Gold += 10`) and `:GetProfile(player)` for the full ProfileStore
  `Profile` object, plus `.ProfileLoaded` / `.ProfileRemoving` signals other services can
  listen to instead of polling.
- Routes to `ProfileStore.Mock` automatically in Studio (`USE_MOCK_IN_STUDIO = true` at the
  top of the file) so playtesting never touches real DataStore keys and never requires
  enabling "Studio Access to API Services". Flip that flag to test real persistence.

### RoundService

`src/Server/Services/RoundService.luau` owns the "MAIN GAME LOOP" from the design doc and
nothing else — it has no idea what a seat, a fork, or a guard is. That separation is
deliberate: seating/eating/guard systems will each be their own module that reacts to this
service's signals instead of one script trying to own timing *and* gameplay at once.

State machine (driven by `RunService.Heartbeat`, not a polling `while wait()` loop):

```
Lobby ------(host clicks Start Game)-----> Intermission --(15s countdown elapses)--> InProgress
  ^                                               |                                          |
  |___________(players drop below Min)____________|                                          |
  |                                                                                            |
  |_______________________________(Ended, after an 8s winner-display hold)__(alive <= 1)______|
```

Lobby → Intermission is **not automatic** — it used to fire the instant the minimum player
count was reached, but that meant a room could start before everyone invited had actually
arrived. `RoundService:RequestStart()` (phase must be `"Lobby"`, `Constants.Players.Min` must
be met) is the only way in now, and only `HostService` calls it — see below for who's allowed
to.

- **Public API other services will build on:** `RoundService:GetPhase()`,
  `RoundService:GetAlivePlayers()`, `RoundService:IsPlayerAlive(player)`,
  `RoundService:RequestStart()` (host-gated, see `HostService`), and — the important one —
  `RoundService:EliminatePlayer(player, reason)`, the sole server-authoritative entry point for
  "this player got caught." Only `GuardService` should ever call that last one.
- **Signals:** `PhaseChanged(new, old)`, `IntermissionTick(secondsRemaining)` (≤1/sec, for a
  future countdown HUD), `RoundStarted(participants)` (seating/guard hook in here),
  `PlayerEliminated(player, remainingAliveCount)`, `RoundEnded(winner)`.
- A player disconnecting mid-round is quietly dropped from the alive roster (not treated as an
  "elimination" — no catch happened, nothing should play a death effect for it) so the round
  doesn't stall waiting for someone who isn't coming back.
- The 5-minute `Constants.Round.MaxDuration` is a hard safety-net force-end, independent of the
  win condition, so a stuck/bugged round can never hang a server forever.

### HostService

`src/Server/Services/HostService.luau` (Match-only) answers "who's allowed to click Start
Game?" — deliberately just **the first player present in this server**. That's always the
creator for both a private party and a public room, since `PartyService`/`PublicRoomService`
both teleport their creator in immediately (see Lobby & Matchmaking below), well before anyone
else could possibly have the code or see the room in the list — arrival order alone is the
signal, nothing needs to travel through `TeleportData` to mark it.

If the host leaves mid-wait, a random remaining player is immediately promoted (`Players.
PlayerRemoving`, excluding the leaver, `math.random` over whoever's left) — a room never gets
permanently stuck with no one able to start it. Every client learns who's currently host via
`HostChanged(host: Player?)`; `HudController` uses it purely to decide whether to *show* its
Start Game button — the real gate is server-side: `RequestStartRound` (client → server, no
payload) is checked against whoever `HostService` currently considers host, never against
anything the client claims about itself, before it calls `RoundService:RequestStart()`.

### SeatingService & PlaceholderMapService

`src/Server/Services/PlaceholderMapService.luau` is explicitly **temporary programmer art** —
it builds a grey-box floor/walls/table and 10 place settings (Plate, Food, Fork, Cup per seat)
at server start so there's something real to seat players at, standing in for the "Map Design"
polish pass (dark atmosphere, wood textures, rain outside, ...) from the design doc. It's
idempotent (skips building if `Workspace.DiningRoom` already exists) and tags every seat Model
with `CollectionService` (`Constants.Tags.DinnerSeat`) instead of anything hardcoding a path to
it. **Delete this file once an artist builds the real map/guard** — as long as the real map
tags its seats the same way (a Model with a `SeatPart` Seat child, tagged `DinnerSeat`) and the
real guard is `Workspace.DiningRoom.Guard` with `Newspaper`/`Gun` part children (`Gun` needs a
`MuzzleFlash` PointLight and a `GunshotSound` Sound child), nothing else in the codebase needs
to change. As of this step it also builds that placeholder guard figure — a blocky torso/head
at the `GuardSpot` position, no rig or animation assets, purely `CFrame`/`TweenService`-driven
(see `GuardService` below).

`src/Server/Services/SeatingService.luau` is the real, permanent system. It:

- Discovers seats purely via the `DinnerSeat` tag (`CollectionService:GetTagged` at `Init`,
  plus `GetInstanceAddedSignal`/`GetInstanceRemovedSignal` for ones that appear/disappear
  later) — it has no idea `PlaceholderMapService` exists.
- **Seat assignment and movement locking are two separate moments.** The instant a player's
  character exists — joining, respawning, or right after `RoundService.PhaseChanged` back to
  `"Lobby"` force-stands everyone (`Humanoid.Sit = false`) and immediately reseats whoever's
  still around — they're assigned a free seat (picked randomly among open ones) and sat down
  via `Seat:Sit()`, with movement still completely normal. "You're at the table" is true from
  the moment you arrive, not just once the round actually starts, so waiting with friends feels
  like sitting together rather than standing around a menu.
- Only `RoundService.RoundStarted` locks movement, on top of whatever seat each participant is
  already sitting in — no reshuffle, no re-teleport, just freezing them in place. Roblox's plain
  `Seat` normally stands a player up the instant they press a movement or jump key, so
  `lockAtSeat` zeroes `Humanoid.WalkSpeed`/`JumpPower`/`JumpHeight` (nowhere to walk to even if
  a client tried) and connects a `Humanoid.Seated` listener that force-sits them right back down
  if they still somehow pop out — but only while they're actually supposed to be locked in
  (still assigned to that exact seat, round still `InProgress`, not eliminated); it gets out of
  the way the instant they're legitimately allowed up (caught, or the round ended).
  `RevivalService`'s revive path re-locks the same way through `ReviveSeat`, so a revived player
  can't wander off either.
- Exposes `SeatingService:GetSeatForPlayer(player) --> Model?` — this is what `EatingService`
  calls to find a player's `Food`/`Fork` parts, and `:GetAllSeats()` /
  `:GetPlayerForSeat(seatModel)` for whatever else needs to reason about seats (the guard's
  line-of-sight, spectator camera cycling, ...).

### EatingService & EatingController

The first system with an actual client Controller and RemoteEvent (`RequestBite`,
client → server, zero payload — the server derives everything else from who fired it and its
own state). Design: **the client is dumb, the server is the only judge.**

`src/Client/Controllers/EatingController.luau` — `EatingController.luau` watches
`UserInputService` for Left Mouse / touch held down and fires `RequestBite` at most once every
`Constants.Eating.BiteInterval` (0.6s) while held. It has no idea what a player's food % even
is — it just forwards intent, paced by `RunService.Heartbeat` rather than a polling loop.

`src/Server/Services/EatingService.luau` on each `RequestBite`:

1. Rejects silently unless the round is `InProgress`, the sender is alive
   (`RoundService:IsPlayerAlive`), and they're actually seated (`SeatingService:GetSeatForPlayer`)
   — the server re-derives all of this itself; nothing about "am I eating" is ever trusted from
   the client.
2. If less than `BiteInterval` has passed since their last **counted** bite, it's a spam click:
   adds noise (`BaseBiteNoise * SpamNoiseMultiplier`) but **no** food progress — clicking faster
   never speeds up eating, it just makes you louder.
3. Otherwise it's a real bite: advances `biteCount` toward `Constants.Eating.BitesToFinish` (12),
   recomputes food %, adds normal noise, and — this needs no remote at all — directly shrinks
   the seat's `Food` part and tweens its `Fork` part via `TweenService`. Every client sees this
   automatically through ordinary Workspace replication.
4. A player's own noise meter (`Constants.Noise`, 0–100, separate from the design doc's guard-
   side global "Suspicion" meter, which doesn't exist yet) decays passively
   (`Constants.Noise.DecayPerSecond`) via the same `Heartbeat` loop `RoundService` uses.

Reacts to `SeatingService.PlayerSeated` (a new signal added this step) rather than
`RoundService.RoundStarted` to reset a player's food/noise state and restore their seat's
Food/Fork to full — `RoundStarted` fires to every connected service in an order our hand-rolled
`Signal` class doesn't guarantee, so `EatingService` can't assume `SeatingService` has already
seated anyone just because `RoundStarted` fired. Waiting for "this specific player is now
actually seated" sidesteps that race entirely.

Public API for later systems: `EatingService:GetFoodPercent(player)`, `:GetNoise(player)`,
`:HasFinishedEating(player)`, `:IsPlayerEating(player)` (true for a short window after each
real bite — deliberately not set by spam clicks, since they don't produce the actual
fork-at-mouth motion), and signals `FoodPercentChanged`, `NoiseChanged`, `PlayerFinishedEating`.

### GuardService

`src/Server/Services/GuardService.luau` is the "Guard AI", "Guard Suspicion", "Player
Detection", and "Shooting" sections of the design doc, all in one module — deliberately: all
of it is "everything about the guard," a single coherent domain, not an arbitrary grouping.

**State machine**, active only while `RoundService:GetPhase() == "InProgress"` (idle and reset
otherwise), driven by `RunService.Heartbeat` like everything else:

- **Reading**: 0.5–10s (`Constants.Guard.ReadingDurationMin/Max`) — a deliberately wide spread
  so the guard's timing never settles into a learnable rhythm. As suspicion rises, the upper
  bound compresses toward the minimum (`Constants.Suspicion.ReadingDurationInfluence` caps how
  much — at max suspicion the range still doesn't fully collapse to a single number, so timing
  is never *fully* predictable even under sustained pressure) — this is "higher suspicion
  increases chance of checking sooner" from the design doc.
- **Looking**: always 1–2s, unaffected by suspicion. Detection runs every single Heartbeat for
  the entire duration of this state, not just once when it begins — a player who starts a bite
  partway through a Looking window is just as caught as one who was already mid-bite when it
  started, matching "looks around" reading as continuous, not an instant snapshot.

**Suspicion** (0–100, `Constants.Suspicion`) is the guard's own private state — deliberately
never sent to a client, unlike each player's own visible Noise Meter. Two independent inputs,
both from the design doc's bullet list, plus passive decay:

- *"Many players eating"*: every Heartbeat tick, a small per-second trickle for each alive
  player currently `EatingService:IsPlayerEating(player)`.
- *"Loud noises" / "rapid bites"*: `GuardService` listens to `EatingService.NoiseChanged` and
  adds suspicion proportional to any **increase** in a player's own noise meter. A spam click's
  bigger noise spike (from `Constants.Noise.SpamNoiseMultiplier`) automatically produces a
  bigger suspicion spike here too — "rapid bites" doesn't need its own separate tracking, it's
  an emergent consequence of the noise link.

**Detection, shooting & elimination** — while `Looking`, every alive player with
`EatingService:IsPlayerEating(player) == true` is caught, server-side only, exactly like
detection on any other server-authoritative system. Per catch:

1. Aims the placeholder Guard's `Gun` part at the caught player's `HumanoidRootPart`
   (`CFrame.lookAt` + a `TweenService` tween that snaps back afterward), flashes its
   `MuzzleFlash` `PointLight`, plays its `GunshotSound` if a real `SoundId` has been assigned
   (empty by default — see `PlaceholderMapService`), and spawns a small red "hit" Part at the
   target that scales up and fades — all placeholder-quality, but the *orchestration* is real:
   swapping in real VFX/SFX later is a matter of pointing at real assets, not restructuring
   this function. None of this needs a remote — every client sees it via ordinary Workspace
   replication, the same trick `EatingService` uses for the fork/food.
2. Force-stands the player (`Humanoid.Sit = false`) and ragdolls them
   (`Humanoid.PlatformStand = true`) — a simple, reliable placeholder; a proper multi-limb
   ragdoll (`BallSocketConstraint`s) is future polish. `GuardService` tracks who it's ragdolled
   and un-ragdolls them when the round returns to `"Lobby"`, symmetric with how
   `SeatingService` releases seats at the same moment.
3. Calls `RoundService:EliminatePlayer(player, "caught eating")` — the actual game-state change
   is immediate and never waits on the cosmetic tweens/effects above to finish playing.

Exposes `GuardService:GetState() --> GuardState` and `:GetSuspicion() --> number`, plus a
`StateChanged(newState, oldState)` signal used internally to drive the newspaper tween.

### SpectatorService & SpectatorController

Two new, small, single-purpose pieces — the first client/server pair built specifically to
carry server truth to clients for something other than direct player input (`EatingController`
sends intent *to* the server; this pair carries state *from* it).

`src/Server/Services/SpectatorService.luau` has no state of its own — it only relays.
`RoundService` and `GuardService` deliberately don't know clients exist, so this is the one
place that turns their server-only signals into the three broadcasts (new remotes this step)
clients actually need: `RoundParticipants(participants)` on `RoundStarted` (the initial
spectate-able roster), `PlayerCaught(player)` on every `PlayerEliminated`, and
`SpectateReset()` when the phase returns to `"Lobby"`.

`src/Client/Controllers/SpectatorController.luau` maintains a local alive-roster from those
broadcasts and, when the `PlayerCaught` broadcast names the **local** player, enters spectator
mode: `Workspace.CurrentCamera.CameraType = Enum.CameraType.Scriptable`, which is what "free
spectate disabled" means in practice — Roblox's default camera script stops driving the camera
entirely once it's `Scriptable`, so there's nothing left to switch to free-look with. The
camera then follows one alive player at a time (a simple trailing offset, recomputed every
`Heartbeat`); **Q**/**E** cycle between them — a placeholder control scheme (no UI exists yet
for prev/next buttons), but the camera-following logic underneath won't need to change once
one does.

### RewardService

`src/Server/Services/RewardService.luau` is the only system that writes match statistics and
win rewards — it listens purely to `RoundService`'s existing signals, nothing new was added to
`RoundService` or `GuardService` for this:

- `RoundStarted(participants)` → `Statistics.MatchesPlayed += 1` for each participant, and
  starts a local clock for computing survival time.
- `PlayerEliminated(player, ...)` → `Statistics.TotalEliminations += 1`,
  `Statistics.CurrentWinStreak = 0`, and updates `Statistics.LongestSurvivalSeconds` if this
  run beat their personal best.
- `RoundEnded(winner)` → if there is one, grants `Constants.Rewards.WinGold`/`WinXP`,
  increments `Wins` and `CurrentWinStreak`, runs `Level` up through
  `Constants.Progression.XPPerLevel`-sized thresholds as needed, and applies a built-in
  `Highlight` to their character for `Constants.Round.EndedDisplayDuration` seconds as a
  placeholder "celebration" — no VFX asset needed, same trick as `RewardService`'s other
  placeholder-but-functional visuals elsewhere in this codebase.

All writes go through `PlayerDataService:GetData(player)` and no-op if it returns `nil` (the
player already disconnected and their ProfileStore session ended) instead of erroring.

### HudController, HudReplicationService & LeaderstatsService

The UI step. Same "code-built, not hand-authored in Studio" philosophy as
`PlaceholderMapService`'s 3D geometry, applied to 2D — see `HudController.luau`'s file doc
comment for the full reasoning (short version: code-built UI is a legitimate, common
production pattern here, not a placeholder to throw away).

`src/Server/Services/HudReplicationService.luau` is `SpectatorService`'s sibling — a stateless
relay, this time for HUD data instead of spectator data: broadcasts `RoundStateChanged(phase,
secondsRemaining)` to everyone, and sends `EatingStateChanged(foodPercent, noise)` /
`ProfileSnapshot(gold, xp, level, wins, settings)` to each player individually via
`FireClient` — nobody else's food %, noise, or wallet is any other client's business. It also
owns the one remote clients send back: `UpdateSetting(key, value)`, validated against a
`SETTING_VALIDATORS` allow-list (type + range per key) before it ever touches
`PlayerProfileData.Settings` — never trust the client, even for volume sliders.

`src/Client/Controllers/HudController.luau` builds one `ScreenGui` into `PlayerGui`:

- **Top bar**: players-alive count (derived from the existing `RoundParticipants`/
  `PlayerCaught` remotes from step 7 — reused rather than duplicated), round status/timer
  (a local stopwatch started on `RoundStateChanged("InProgress", ...)`, since there's no fixed
  round-duration countdown to sync, just an elapsed-time display), and a party code label that
  only appears at all if `PartyCodeAssigned` ever fires (see Lobby & Matchmaking) — empty in a
  public room or a Hub-browsed join, since neither of those has a short code to show.
- **Bottom bar**: Food %/Noise meters (simple fill-bar `Frame`s) and Gold/XP/Level labels,
  all from the two remotes above.
- **Four bottom-row buttons** (Inventory/Shop/Daily Rewards/Spectate — only one panel open at a
  time) plus a fixed **gear icon pinned to the top-right corner** that's the one entry point
  into Settings, deliberately kept in the same spot regardless of round state rather than mixed
  in with the other panel buttons.
- **Settings panel**: built once, the first time `ProfileSnapshot` arrives, from three small
  reusable control builders (`createSlider`/`createToggle`/`createCycle`) covering every field
  in `PlayerProfileData.Settings` — sliders drag *or* click-to-set (mouse and touch), and every
  change fires `UpdateSetting` immediately. It also has a **Leave Game** row: a plain client-side
  `TeleportService:Teleport(game.PlaceId, LocalPlayer)` back to the same place with no
  `PrivateServerId`, which is exactly what a normal server is — no server round-trip needed,
  same as `PromptProductPurchase` being a direct client call elsewhere in this file. Inventory/
  Shop/Daily Rewards started as shells and became real in step 10 (see below) — every row in all
  three panels rebuilds from scratch whenever its backing data arrives (`InventoryUpdated` /
  `DailyStateChanged`), rather than
  patching individual rows; the lists are small enough that simplicity wins over diffing.

`src/Server/Services/LeaderstatsService.luau` populates the standard `leaderstats` Folder
convention (Gold/Wins/Level) under each `Player` — Roblox renders its native top-right
leaderboard from this automatically, so the design doc's "Leaderboard" bullet needed zero
custom UI at all. Resyncs every second from `PlayerDataService` rather than hooking every
possible writer.

### CosmeticCatalog, ShopService, MonetizationService & RevivalService

`src/Shared/Data/CosmeticCatalog.luau` is the single source of truth for every cosmetic item —
`ShopService` (validates purchases/equips) and `HudController`'s Shop/Inventory panels both
read this exact same list, so nothing the UI ever shows can be un-purchasable. Every item
covers one of the design doc's rarities (Common → Secret, cosmetic-only — "No gameplay
advantages, never pay-to-win") and unlocks exactly one way: `Price` (Gold), `UnlockLevel`
(auto-granted on level-up), or `GamePassId` (Robux).

`src/Server/Services/ShopService.luau` is the only system allowed to grant ownership or change
what's equipped: auto-grants `Price == 0`/level-unlocked items on profile load and on
`RewardService.LevelUp`; `PurchaseCosmetic` deducts Gold server-side; `EquipCosmetic` checks
real ownership (`OwnedCosmetics`, or a cached Game Pass — see below) before ever touching
`EquippedCosmetics`. Emotes are multi-slot (toggle membership); every other category is a
single equipped slot.

`src/Server/Services/MonetizationService.luau` owns all `MarketplaceService` integration.
Every Developer Product / Game Pass ID lives in `Shared/Constants/MonetizationIds.luau` as a
**placeholder `0`** — that file's header comment explains exactly how to create the real ones
in the Roblox Creator Dashboard; nothing else in the codebase needs to change once you do.
`ProcessReceipt` grants a paid revive tier / Double XP / Double Gold and records every
`PurchaseId` in `PlayerProfileData.ProcessedReceipts` *before* confirming the purchase, so a
retried callback (Roblox retries until you return `Granted`) can never double-grant. Game Pass
ownership is checked once per session (profile load) and cached into `OwnedGamepasses` so
`ShopService` never needs an async Marketplace call just to check if an equip is allowed; `VIP`
additionally auto-grants its `Title_VIP` cosmetic the moment ownership is confirmed.

`src/Server/Services/RevivalService.luau` sequences the actual revive (no new game logic there)
**and** owns the escalating revive-pricing rule: a player's first revive each round is free,
the second costs 49 Robux, the third 60, and the fourth-and-every-one-after plateaus at 99 —
tracked per player in an in-memory `_revivesThisRound` count that resets whenever
`RoundService.RoundStarted` fires (same lifecycle as `RoundService`'s own `_roster`/`_alive`).
Because a single Roblox Developer Product can't have a dynamic price, the three paid tiers are
three separate products (`ReviveSecond` / `ReviveThird` / `ReviveFourthPlus` in
`MonetizationIds.DeveloperProducts`) — the free tier never touches a product at all, it's a
direct `RequestFreeRevive` remote straight into `RevivalService:AttemptFreeRevive`, which
re-checks eligibility server-side rather than trusting the client's "it's my first time" claim.
`RevivalService:GrantPaidRevive` (called by `MonetizationService` after any of the three tiers'
receipts) doesn't re-validate which specific tier was bought against the player's current
count — the Robux is already spent by then, so it always grants the revive if they're otherwise
eligible; the tier system is enforced by which product the UI shows/prompts, not by rejecting
purchases after the fact. Whichever path grants it, the actual sequence is the same three
calls, in order: `RoundService:RevivePlayer()` (game-state authority — were they even
eliminated this round? `RoundService` tracks a `_roster` of every participant, separate from
the shrinking `_alive` set, specifically so this check is possible), `SeatingService:ReviveSeat()`
(re-sits them at their **existing** seat assignment without going through the normal seating
path — deliberately so `EatingService` never resets their food/noise progress, matching "food
progress stays unchanged"), and `GuardService:ClearRagdoll()` (stands them back up immediately
rather than waiting for the next Lobby transition).

**Discoverability**: rather than leaving revives buried in the Shop's generic "Boosts & Revive"
list, `HudController` shows a prominent floating revive button that appears automatically the
instant the local player is caught (same `PlayerCaught` broadcast `SpectatorController` already
reacts to) and disappears the moment they're revived or a new round starts. Its label and
action both come from a targeted `ReviveTierChanged` broadcast the server fires to just that
player on elimination (`"Free" | "Second" | "Third" | "FourthPlus"`): on `"Free"` the button
reads "Revive (Free)" and just fires `RequestFreeRevive`, no Marketplace call at all; on any
paid tier it looks up the matching product, fetches the real price live via
`MarketplaceService:GetProductInfo` (so the label never goes stale if you change the price in
the Dashboard later) to show e.g. "Revive (49 Robux)", and clicking calls
`MarketplaceService:PromptProductPurchase` for that specific product.
`MonetizationService`/`RevivalService` remain the sole authority on whether either path actually
does anything.

**Closing the loop client-side**: a successful revive changes server state (`RoundService`,
`SeatingService`, `GuardService`) but nothing about that reaches clients unless something says
so — a new `PlayerRevived` broadcast (bridged through `SpectatorService`, same pattern as
`PlayerCaught`) tells every client to add the revived player back to their local spectate
roster, and tells the revived player's *own* client specifically to exit spectator mode
(restore `CameraType.Custom`) and hide the revive button — otherwise they'd be playable again
server-side while still visually stuck in the spectator camera.

### SkinVisualsService — making skins actually visible

Everything above tracks ownership and equipping correctly, but for a while nothing *looked*
different when you equipped a skin — `EquippedCosmetics` was just data nobody read back into
the world. `src/Server/Services/SkinVisualsService.luau` is that missing link.

`CosmeticCatalog.luau` items now carry `Color: Color3?`, `Material: Enum.Material?`, and an
optional `SpecialEffect: "Rainbow" | "Sway"` — the single source of truth for what a skin
actually *looks like*, same as `Price`/`UnlockLevel`/`GamePassId` are for how it's unlocked.
Fork/Plate/Chair/Food map directly onto a seat's real `Fork`/`Plate`/`SeatPart`/`Food` parts
(`Chair` → `SeatPart`, since there's no separate chair part — the Seat instance *is* the
chair). Emote/Title/VictoryAnimation stay data-only for now — visually representing those needs
real animation assets or a nameplate UI, out of scope for this pass.

Two triggers re-apply a player's current loadout to their seat:
- `SeatingService.PlayerSeated` — the moment they sit down.
- `ShopService.EquipmentChanged` (new signal, fired whenever an equip succeeds) — live,
  mid-round, since the Shop is reachable from the HUD at any time, not just between rounds.

Two continuous effects run off a single `Heartbeat` loop for the catalog's flashier items:
`Food_Rainbow` cycles hue every frame (`Color3.fromHSV`); `Chair_Animated` gently sways the
seat a few degrees (small enough to read as ambient flair, not disorienting for whoever's
sitting in it — the character is welded to the seat, so it sways with the chair). Both stop the
instant a player equips something else, so switching skins never leaves a stale effect running
on an old part.

Deliberately never touches `Size`/`Transparency` on the `Food` part — `EatingService` already
owns those (shrinking it as the player eats) — only `Color`/`Material`/rotation, so the two
systems read/write disjoint properties and can never fight each other.

### DailyService

`src/Server/Services/DailyService.luau` covers two independent systems sharing one UI panel:
a login-streak reward (`PlayerProfileData.DailyRewards`, reserved since step 2) and three fixed
daily missions (`Shared/Data/DailyMissionCatalog.luau`: survive 3 rounds, win 1 game, finish
food 5 times — straight from the design doc's examples). Both reset on UTC calendar-day
boundaries (`os.date("!*t", ...)`), independent of the server's local timezone. Mission
progress is tracked purely by reacting to `RoundService`/`EatingService` signals — this service
never decides whether a round was won, only counts.

### Progression & RateLimiter (Shared)

`src/Shared/Util/Progression.luau` centralizes the XP/Level curve and Double XP/Double Gold
boost math so `RewardService` and `DailyService` can't drift apart on either — both now call
`Progression.GrantXP`/`GrantGold` instead of keeping their own copies.

`src/Shared/Util/RateLimiter.luau` is a small per-player cooldown guard applied to every remote
that doesn't already have a natural cooldown baked into its own logic (`RequestBite` already
self-limits via `BiteInterval`) — `UpdateSetting`, `PurchaseCosmetic`, `EquipCosmetic`,
`ClaimDailyLogin`, `ClaimMission`. Not a security boundary on its own (every handler still
validates everything else), purely cost control: a scripted client firing one of these in a
tight loop can't waste meaningful server CPU on an otherwise harmless, idempotent-safe action.

### AtmosphereService & camera shake — the polish pass

`src/Server/Services/AtmosphereService.luau` covers the "Map Design"/"Sound Design" atmosphere
bullets that need no art asset: dark `Lighting` + fog + an `Atmosphere` instance, warm
`PointLight`s over the table, and a periodic (20–60s, randomized) thunder flash — a brightness
burst on a ceiling-mounted `PointLight`, the same technique as `GuardService`'s muzzle flash.
Its table-lighting step runs in `Start()`, not `Init()`, because it depends on
`PlaceholderMapService` having already built `Workspace.DiningRoom.Table` — Init-phase
ordering between services is unspecified, but every service's Init is guaranteed complete
before any Start runs, so `Start()` is the safe place for this cross-service Workspace lookup
(the same fix `SeatingService`/`GuardService` needed for their own). The thunder scheduler is a
long-lived `task.spawn` loop sleeping 20–60s between flashes — a legitimate use of `task.wait()`
in a loop, distinct from the polling anti-pattern the rest of this codebase avoids, because it
does no per-frame work between flashes.

`SpectatorController.luau` also gained a camera shake on every `PlayerCaught` broadcast (a
shared dramatic beat everyone feels, not just the caught player), via `Humanoid.CameraOffset` —
the standard Roblox technique for nudging the camera without fighting the default camera
script's control of `CameraType.Custom`.

### Optimization / anti-cheat audit

Part of this step was reviewing the whole codebase rather than adding more of it:

- **No polling loops.** Every recurring check in this codebase is either event-driven or a
  single `RunService.Heartbeat` connection made once in a service's `Start()` — grep confirms
  the only `task.wait()` in first-party code is `AtmosphereService`'s intentional long-sleep
  thunder scheduler (documented above); nothing uses legacy `wait()` or `while wait() do`.
- **No connection leaks.** Every `:Connect()` in a service/controller happens exactly once, in
  `Start()` — never inside a loop or a per-event handler that would accumulate duplicate
  connections. The one exception, `PlayerDataService`'s `profile.OnSessionEnd:Connect(...)`,
  is intentionally scoped per-player-per-session (one connection per join, cleaned up by
  ProfileStore when that session ends) — not a leak. `HudController`'s panel rows reconnect on
  every rebuild, but `clearChildren` `:Destroy()`s the old ones first, and Roblox automatically
  disconnects an Instance's own event connections when it's destroyed.
- **Nothing trusts the client.** Every gameplay-relevant remote handler re-derives state
  server-side (round phase, alive/seated status, ownership, funds) rather than trusting
  anything the client claims about itself — true since step 5's `EatingService` and never
  relaxed since.
- **Spam-prone remotes are rate-limited** — see `RateLimiter.luau` above.

## Lobby & Matchmaking

Added after the original 11-step roadmap, at request: a real lobby where a player can generate
a code to play with a friend, or browse public rooms to play with randoms.

### Architecture: one place, two modes

Same Rojo project, same place — no second place to manage or keep in sync. Every server is
either:

- **Hub** — the menu experience a player lands in via the game's normal Play button: create or
  join a private party, create or browse public rooms. No round/guard/seating logic runs here.
- **Match** — an actual round of Don't Get Caught, i.e. everything built in the 11 roadmap
  steps above. Reached only by being teleported in — never landed on directly.

`Shared/Util/ServerMode.luau` decides which, and it's cheap and immediate:
`game.PrivateServerId ~= ""` means Match, because **every** Match server — both private parties
and public rooms — is a [Reserved Server](https://create.roblox.com/docs/reference/engine/classes/TeleportService#ReserveServer),
created via `TeleportService:ReserveServer()`. An ordinary direct join (the normal Play button)
never has a `PrivateServerId`, so it always lands in a Hub. This is knowable at server boot,
before any player has joined — no waiting on join data required.

Services/controllers opt into a mode via `Modes = {"Match"}` / `{"Hub"}` (see "Why this shape"
above); everything from the original 11 steps got tagged `Match`-only except
`PlayerDataService`, `MonetizationService`, `ShopService`, `DailyService`, and
`LeaderstatsService` — a player's data, shop, and leaderboard all still make sense while
they're sitting in the Hub deciding what to play.

### Private parties — `PartyService.luau` (Hub-only)

`CreateParty` reserves a server (`TeleportService:ReserveServer`) and generates a **short**,
human-shareable code (6 characters, `Constants.Party.CodeCharacters` deliberately excludes
`0/O/1/I` so it's easy to read aloud or off a screenshot) — not Roblox's own long access code.
The mapping (short code → real access code) is written to a `PartyCodes` DataStore, because the
friend entering that code will very likely land on a **different** Hub server instance than the
one that created it; only a DataStore lookup (not in-memory state) can bridge that. `JoinParty`
looks up the code, checks it hasn't passed `Constants.Party.CodeExpirySeconds`, and calls
`TeleportService:TeleportToPrivateServer` with the real access code. Every friend enters the
code independently on their own client — there's no in-Hub "select your friends" UI — and they
all converge on the same reserved server because they all resolve to the same access code.

The host doesn't stay behind in the Hub either: `CreateParty` immediately teleports them into
the server they just reserved (same as `CreatePublicRoom` always has), passing the short code
along as `TeleportData`. `PartyCodeService.luau` (Match-only) reads it off whichever player's
join data carries it and broadcasts it to every client in that server (`PartyCodeAssigned`
remote) — the code then stays visible in the corner of the HUD for the whole match, not just
the few seconds before the host got teleported away, so they can still invite a second or third
friend later without needing to have written it down.

### Public rooms — `PublicRoomService.luau` (Hub) + `RoomReportingService.luau` (Match)

A public room is **the same mechanism** as a private party (a Reserved Server) — the only
difference is discoverability. `CreatePublicRoom` reserves a server exactly like `CreateParty`,
but additionally writes an entry into a `PublicRooms` DataStore, keyed by the reserved server's
own `PrivateServerId` (so no separate ID scheme is needed). That single fact — *does this
server's `PrivateServerId` have an entry in the `PublicRooms` store?* — is what
`RoomReportingService`, running inside the Match server itself, checks on boot to decide
whether it's a public room (report in) or a private party (stay silent forever). If it's
public, it periodically publishes its live player count and round phase via `MessagingService`
(topic `"PublicRoomUpdates"`) and refreshes the durable DataStore entry, and cleans up (removes
itself from both) when the room empties or the server shuts down (`game:BindToClose`).

On the Hub side, `PublicRoomService` subscribes to that same `MessagingService` topic to keep a
live, in-memory room list, broadcasting it to clients (`PublicRoomsUpdated`) whenever it
changes. A **freshly-booted** Hub server hasn't received any of those messages yet (Roblox
doesn't replay history to new subscribers), so it also does one `:ListKeysAsync` +
`:GetAsync`-per-key read against the `PublicRooms` DataStore on startup to seed its cache —
MessagingService for near-real-time updates, DataStore as the durable source new Hubs bootstrap
from. `JoinPublicRoom` just teleports the caller into the room's `AccessCode` like `JoinParty`
does.

### Testing this — **read this before assuming something's broken**

Studio's multi-client Test tab (`Clients: 2+`) runs every client against **one single local
server process**. It does not, and cannot, simulate multiple real independent server instances
— so `TeleportService:ReserveServer`/`TeleportToPrivateServer`, cross-server `MessagingService`,
and the "does a friend on a different server instance see my party" scenario **cannot be fully
exercised inside a local Studio session**, no matter how the code is written. This isn't a bug
to chase; it's what these APIs are for. What you *can* verify locally, and what genuinely needs
a published, live game:

**Locally verifiable (Studio, with "Enable Studio Access to API Services" on — Game Settings →
Security — since `DataStoreService`/`MessagingService` calls otherwise fail):**

1. Press Play with 1 client. You should land in the **Hub** — `HubController`'s menu (title,
   "Play with Friends", "Public Rooms" sections), *not* the Match HUD from the earlier steps.
   Output should show `[ServerBootstrap] Server mode: Hub` and `[ClientBootstrap] Server mode: Hub`.
2. Click **Create Public Room**. If this place has never been published to Roblox,
   `TeleportService:ReserveServer` cannot work at all — the button should re-enable within a
   moment showing a clear message (**"Public rooms require this game to be published to Roblox
   first."** if `game.PlaceId == 0`, or a generic retry message if the reservation call itself
   times out — `Constants.Party.ReserveServerTimeoutSeconds`, 8s) rather than sitting on
   "Creating..." forever. If you *do* have a published place with Studio API access enabled,
   this should actually succeed. Either way, check the DataStore to confirm what happened:
   ```lua
   local DataStoreService = game:GetService("DataStoreService")
   local store = DataStoreService:GetDataStore("PublicRooms")
   -- print the ListKeysAsync results to find the key you just wrote, then:
   -- print(store:GetAsync("<thatKey>"))
   ```
3. **Create Party** — same expectations as step 2 (either a real code appears, or a clear
   error, never an indefinite "Creating..."). If a code does appear, confirm it resolves via
   the `PartyCodes` DataStore the same way.
4. **Join Party** with a garbage code (e.g. `"ZZZZZZ"`) — should show `That code doesn't exist.`
   without erroring anything.
5. Confirm every Match-only controller/service from the earlier steps stays **inert** in this
   Hub session — e.g. `Workspace.DiningRoom` should never appear, since `PlaceholderMapService`
   never Starts in Hub mode.

**Needs a published, live game** (Create → publish this place, then actually play it from
roblox.com or the app with a second Roblox account/friend — this is the only way to get two
genuinely separate server processes):

6. One account clicks **Create Party**, shares the resulting code with the second account (chat,
   Discord, whatever) — the second account enters it via **Join Party** and both should land on
   the exact same server, seeing each other.
7. One account clicks **Create Public Room**; within a few seconds (`Constants.PublicRooms.HeartbeatInterval`),
   a *different* account's Hub session should show it in the **Public Rooms** list with the
   correct host name and player count, and joining it via that list should land them together.
8. Let a public room's creator leave (making it empty) — within moments, other Hub sessions'
   room lists should drop it (via the `"Remove"` MessagingService publish + `RemoveAsync`).

## Development workflow

1. **Install Rojo** (already done in this environment via `winget install Rojo.Rojo`).
   Alternatively use [Rokit](https://github.com/rojo-rbx/rokit) (`rokit install`) which reads
   `rokit.toml` for a pinned version — recommended if another teammate sets this up.
2. **Install the Roblox Studio Rojo plugin**: in Studio, go to the Plugins tab → Plugins
   Marketplace → search "Rojo" → install the official plugin by Rojo (or run
   `rojo plugin install`  from a terminal with Rojo on PATH).
3. **Open `Place1.rbxl`** in Roblox Studio.
4. **Serve the project**: from this folder, run:
   ```
   rojo serve
   ```
5. **Connect**: in Studio, open the Rojo plugin panel and click "Connect". Studio will sync
   in `ReplicatedStorage.Shared`, `ServerScriptService.Server`, and
   `StarterPlayer.StarterPlayerScripts.Client` live — any file you save here appears in
   Studio within moments.
6. Press **Play** (F5) in Studio to run the bootstraps.

### Testing this step

There's still no UI, so testing is via the Output window and the Command Bar. **Use Studio's
multi-player testing** (Test tab → set "Players" to 2+ → Start) since the round needs
`Constants.Players.Min` (2) players to leave the Lobby phase — a single-player Play session
will sit in Lobby forever, which is itself correct behavior worth confirming first.

**1. Single player — confirm it waits:**
Press Play with 1 player. Output should show the usual `PlayerDataService` lines but the round
should just sit there. Run in the Command Bar:
```lua
local RoundService = require(game.ServerScriptService.Server.Services.RoundService)
print(RoundService:GetPhase()) --> "Lobby"
```

**2. Two+ players — confirm the full cycle:**
Start a multi-player test session (2 players). Within a frame you should see in Output:
```
[RoundService] Intermission started — 2 player(s) present, 15s countdown.
```
followed by `[RoundService] Round started with 2 participant(s).` about 15 seconds later.
Confirm via the Command Bar:
```lua
local RoundService = require(game.ServerScriptService.Server.Services.RoundService)
print(RoundService:GetPhase())          --> "InProgress"
print(RoundService:GetAlivePlayers())   --> both players
```

**3. Simulate a catch (there's no guard yet, so trigger it manually):**
```lua
local RoundService = require(game.ServerScriptService.Server.Services.RoundService)
local target = game.Players:GetPlayers()[1]
RoundService:EliminatePlayer(target, "manual test")
```
Output should show `[RoundService] <name> was caught (manual test). 1 player(s) remain.`,
immediately followed by `[RoundService] Round ended. Winner: <other player's name>`. Eight
seconds later you should see `[RoundService] Waiting in Lobby for players.` — confirming the
Ended → Lobby loop closes correctly. Since both players are still connected, it should
immediately re-enter Intermission and start a new round.

**4. Drop below the minimum mid-countdown:** during step 2's 15-second countdown, disconnect
one of the two test players (or call `game.Players:GetPlayers()[1]:Kick()` from the Command
Bar). Output should show `[RoundService] Not enough players — cancelling intermission.` and
`RoundService:GetPhase()` should read `"Lobby"` again.

**5. Seating (new this step) — visual check:** with 2+ test players, look at the **Explorer**
after the server starts: `Workspace.DiningRoom` should contain `Floor`, 4 `Wall_*` parts,
`Table`, `GuardSpot`, and 10 `SeatN` models, each with `SeatPart`/`Plate`/`Food`/`Fork`/`Cup`
children. Switch to one of the test player windows and watch the character — once Intermission
ends and `RoundStarted` fires, they should visibly sit down at one of the 10 seats (Roblox's
native sit animation). Output should show `[SeatingService] Seated 2/2 participant(s).` right
after `[RoundService] Round started with 2 participant(s).`.

**6. Seating releases between rounds:** after step 3's manual `EliminatePlayer` call ends the
round and the 8-second Ended hold returns to Lobby, both players should visibly stand back up
(`Humanoid.Sit = false` firing) before the next Intermission seats them again — confirms
`SeatingService` is reacting to `RoundService.PhaseChanged` correctly, not just seating once
and never releasing.

**7. Eating (new this step) — the actual playable bit:** once seated (round `InProgress`),
switch to a test player's window and **hold down Left Mouse**. You should see, roughly every
0.6s: the fork on their plate lift and dip back down, and the food block visibly shrink a
little more each time. Output should NOT print anything per bite (this is intentionally quiet —
see the Command Bar check below for the real numbers). After ~12 bites (~7 seconds of holding)
the food should have fully shrunk/vanished and Output should show
`[EatingService] <name> finished eating.`

**8. Confirm the real numbers via Command Bar:**
```lua
local EatingService = require(game.ServerScriptService.Server.Services.EatingService)
local target = game.Players:GetPlayers()[1]
print(EatingService:GetFoodPercent(target)) --> climbs toward 100 as you hold Left Mouse
print(EatingService:GetNoise(target))       --> rises per bite, drains back toward 0 when you stop
```

**9. Spam-click penalty:** instead of holding, rapidly click Left Mouse many times in under a
second. `GetFoodPercent` should barely move (most clicks land inside the `BiteInterval` cooldown
and don't count) while `GetNoise` should jump up noticeably faster than normal steady eating —
confirms spam-clicking trades noise for no real speed gain, matching the design doc.

**10. Guard state machine (new this step):** with a round `InProgress`, watch Output. You
should see `[GuardService] Guard cycle started — Reading for N.Ns.` right as the round starts,
then alternating `[GuardService] Guard Reading -> Looking (N.Ns, suspicion=N)` /
`Looking -> Reading (...)` lines forever, with Reading durations between 0.5–10s and Looking
between 1–2s (spot-check a handful — they should look randomized, not a fixed cadence). Confirm
via Command Bar:
```lua
local GuardService = require(game.ServerScriptService.Server.Services.GuardService)
print(GuardService:GetState())      --> "Reading" or "Looking"
print(GuardService:GetSuspicion())  --> a number 0-100
```

**11. Suspicion responds to eating:** while the round is in progress, hold Left Mouse to eat
steadily for ~10 seconds, watching `GuardService:GetSuspicion()` in between — it should climb
noticeably faster while you're actively eating than it does while you're sitting idle (idle
suspicion should mostly just decay toward 0 via `Constants.Suspicion.DecayPerSecond`). Then spam
click for a couple seconds and compare the suspicion jump against the same duration of steady
eating — spam should raise it faster, since noise spikes feed suspicion proportionally
(`Constants.Suspicion.PerNoisePoint`) and spam clicks generate bigger spikes.

**12. Suspicion resets between rounds:** after a round ends and a new one begins (via the
manual `EliminatePlayer` trick from step 3), Output's next
`Guard cycle started — Reading for N.Ns.` line should reflect a full-range random duration
(not a suspiciously short one carried over from the previous round's high suspicion) — confirms
`GuardService` resets suspicion to 0 on every `RoundStarted`.

**13. The guard figure (new this step) — visual check:** in the **Explorer**, confirm
`Workspace.DiningRoom.Guard` exists with `Torso`/`Head`/`Newspaper`/`Gun` children, `Head` has
a `Face` Decal (the classic default Roblox face, via `rbxasset://` — no uploaded asset needed),
and `Gun` has `MuzzleFlash` (PointLight) and `GunshotSound` (Sound) children. Watch the
`Newspaper` part in a live view — it should visibly tween up (covering the guard's face) during
Reading and down during Looking (revealing the face), in sync with the Output log lines from
step 10.

**14. Get caught for real:** with a round `InProgress`, watch `GuardService:GetState()` in the
Command Bar (or watch the Newspaper) until it's `"Looking"`, then immediately hold Left Mouse.
You should see: the Gun snap toward you, its `MuzzleFlash` flicker, a small red sphere flash at
your character and fade, and your character go limp and fall over (ragdoll). Output should show
`[GuardService] <name> was caught eating!` immediately followed by
`[RoundService] <name> was caught (caught eating). N player(s) remain.` — confirming
`GuardService` really did call through to `RoundService:EliminatePlayer`, not just play a
visual. (Getting the timing right takes a couple of tries — that's the game working as
intended.)

**15. Spectator mode:** the instant you're caught, your camera should snap to a trailing view
of one of the other alive players and stop responding to normal mouse-look (confirms
`CameraType` really is `Scriptable`). Press **E** / **Q** — the view should jump to a different
alive player each press, wrapping around the roster. If only one other player is alive, both
keys should just keep you on them (nothing to cycle to).

**16. Spectator mode ends correctly:** let the round finish (down to 1 alive) and sit through
the 8-second Ended hold. The moment Output shows `[RoundService] Waiting in Lobby for
players.`, the spectating client's camera should snap back to normal (`CameraType` back to
`Custom`, mouse-look responsive again) even before they're reseated for the next round —
confirms `SpectateReset` fired and `SpectatorController` reacted to it.

**17. Rewards (new this step):** before a round ends, note the winner-to-be's gold via
Command Bar:
```lua
local PlayerDataService = require(game.ServerScriptService.Server.Services.PlayerDataService)
local target = game.Players:GetPlayers()[1]
print(PlayerDataService:GetData(target).Gold, PlayerDataService:GetData(target).XP, PlayerDataService:GetData(target).Wins)
```
Let them win a round (or use the manual `EliminatePlayer` trick to eliminate everyone else).
Output should show `[RewardService] <name> won the round! +50 gold, +100 XP (...)`. Re-run the
print above — `Gold` should be +50, `Wins` +1, and `XP`/`Level` should reflect the +100 XP
(at `Constants.Progression.XPPerLevel = 100`, a level-1 player with 0 XP should land exactly on
Level 2 with 0 XP left over). The winner's character should also visibly glow gold briefly
(the placeholder celebration `Highlight`).

**18. Stats for the caught, not just the winner:** check a player who got caught this round:
```lua
print(PlayerDataService:GetData(target).Statistics)
```
`MatchesPlayed` should be ≥1, `TotalEliminations` should have incremented by exactly 1 for this
catch, and `CurrentWinStreak` should read 0.

**19. HUD basics (new this step):** press Play. You should immediately see a top bar
("Players Alive: N", a status message) and a bottom bar (Food %/Noise meters at 0, Gold/XP/
Level) with five buttons. Numbers should match what Command Bar checks report (e.g. `Gold:`
should match `PlayerDataService:GetData(LocalPlayer).Gold`).

**20. HUD live-updates with gameplay:** hold Left Mouse while seated — the Food %/Noise bars in
the bottom-left should visibly fill in step with the fork/food animation from step 5. Win a
round — the Gold/Level/XP labels should update within ~1 second (the periodic `ProfileSnapshot`
resync) without needing to reopen anything.

**21. Panels:** click each of the five buttons in turn. Inventory/Shop/Daily Rewards should
open a small panel with a "coming in a future update" message; clicking a different button
should close whichever panel was open and open the new one (only one at a time); the **X**
button (or re-clicking the same button) should close it.

**22. Settings actually persist:** open Settings, drag the Music Volume slider partway, click
its track directly (should jump-to-click), and toggle Colorblind Mode ON. Confirm via Command
Bar:
```lua
local PlayerDataService = require(game.ServerScriptService.Server.Services.PlayerDataService)
print(PlayerDataService:GetData(game.Players:GetPlayers()[1]).Settings)
```
`MusicVolume` and `ColorblindMode` should reflect what you set. Try dragging a value with an
invalid *client* — this isn't easily fakeable from the UI itself, but you can confirm server
validation directly:
```lua
local Remotes = require(game.ReplicatedStorage.Shared.Remotes.Remotes)
Remotes.GetEvent("UpdateSetting"):FireServer("MusicVolume", 999) -- out of 0-1 range
```
Output should show `[HudReplicationService] <name> sent an invalid setting update for
'MusicVolume' — ignored.` and the stored value should be unchanged.

**23. Leaderboard:** press the default Roblox player-list toggle (Tab, or the player-count
icon top-right) — you should see the native leaderboard listing each player with Gold/Wins/
Level columns, matching `PlayerDataService` values (allow up to ~1 second for the periodic
sync after a change).

**24. Shop (new step 10) — Gold purchases:** open the Shop panel. You should see three
sections: "Gold Shop" (items with a gold price — `Buy` enabled/disabled based on your current
balance), "Robux Shop" (Game Pass items — `Get`, greyed out once "owned"), and "Boosts &
Revive" (the three Developer Products). Buy an affordable Gold-Shop item; the row should
immediately flip to "Owned", your Gold balance in the bottom bar should drop by its price, and
Output should show `[ShopService] <name> purchased <item> for N gold.`. Since
`MonetizationIds.luau` ships with every ID as placeholder `0`, clicking "Get"/a Robux item will
not open a real purchase prompt until you create the matching Developer Product/Game Pass in
the Creator Dashboard and fill in its ID — this is expected, not a bug.

**25. Inventory & equipping:** open the Inventory panel — you should see your owned items
(including the free `_Default` item in every category, auto-granted on profile load) grouped by
category, with the currently-equipped one reading "Equipped". Equip a different owned Fork —
Output should show `[ShopService] <name> equipped <item>.`, and re-opening the panel should
show the new one as equipped. Try equipping two different Emotes in a row — both should show
"Unequip" (multi-slot), unlike every other category which only ever has one equipped at a time.

**26. Level-unlock cosmetics:** find a catalog item with an `UnlockLevel` (e.g. `Fork_Golden`
at level 5 — see `CosmeticCatalog.luau`). Win enough rounds via the manual `EliminatePlayer`
trick to cross that level (check `PlayerDataService:GetData(target).Level` via Command Bar).
The moment you cross the threshold, Output should show a `[RewardService] ... won the round!`
line reflecting the new level, and the Inventory panel should show that item already owned
without ever having "bought" it.

**27. Revive framework — free first revive:** get a player caught for real (timing a bite
against the guard's Looking window, or the manual `EliminatePlayer` trick). On the caught
player's own window, the floating revive button should appear automatically reading
**"Revive (Free)"** — no Developer Product ID needed for this tier, it never touches
`MarketplaceService`. Click it. The player should visibly stand back up at their original seat
and stop being ragdolled; Output shows `[RevivalService] <name> was revived and returned to
their seat.`; and their food % (check via `EatingService:GetFoodPercent`) should be
**unchanged** from before they were caught. Client-side, on the revived player's own window:
their camera should snap back from the spectator view to normal gameplay control, and the
revive button should disappear. On every *other* window: "Players Alive" in the top bar should
tick back up by 1.

**27b. Revive button visibility:** get a different player caught for real and confirm the
floating revive button appears automatically on **their** window within the same frame as the
camera locking into spectator mode — you shouldn't need to open the Shop to find it. Start a
fresh round afterward and confirm the button is gone (it shouldn't persist across rounds).

**27c. Escalating paid tiers (needs real Developer Product IDs to fully test):** get the same
player caught and revived a second time in the same round (either via the free path again — it
should now be denied — or the manual Command Bar trick below) — the button should now read
**"Revive with Robux"** (or, once `MonetizationIds.DeveloperProducts.ReviveSecond` has a real
ID, the live fetched price, e.g. "Revive (49 Robux)"). Get them caught a third time: the button
should switch to the `ReviveThird` product (60 Robux). A fourth time and beyond: `ReviveFourthPlus`
(99 Robux), and it should stay on that tier no matter how many more times they're caught this
round. With every ID still `0`, you can exercise the *logic* (not the purchase flow) directly
via Command Bar:
```lua
local RevivalService = require(game.ServerScriptService.Server.Services.RevivalService)
local caughtPlayer = game.Players:GetPlayers()[1] -- must currently be eliminated, not alive
print(RevivalService:GetReviveTier(caughtPlayer)) --> "Free" | "Second" | "Third" | "FourthPlus"
print(RevivalService:GrantPaidRevive(caughtPlayer)) --> true (bypasses Marketplace, same as a
                                                       -- real purchase would after ProcessReceipt)
```
Confirm the tier resets to `"Free"` for everyone once a brand-new round starts (`RoundService`
firing `RoundStarted` clears `RevivalService`'s per-round counters) — get caught once in a new
round and the button should read "Revive (Free)" again, even if they used all three paid tiers
last round.

**27c. Skins are actually visible (new):** buy `Fork_Silver` and `Plate_Porcelain` from the
Gold Shop (150 gold each — check `PlayerDataService:GetData(target).Gold` before/after via
Command Bar), then equip both from the Inventory panel. Once seated for a round, look at that
player's actual plate — the fork should visibly be a lighter, metallic color and the plate a
glossy white, immediately, not just in the UI. Output shows
`[ShopService] <name> equipped Silver Fork.` etc. Try equipping a *different* fork while
already seated mid-round (open Shop from the in-round HUD) — it should change on the actual
seat live, without needing to stand up and resit.

**27d. Special effects:** since `RainbowEatingEffect`/`AnimatedChair` are Game-Pass-gated and
`MonetizationIds.GamePasses` ships with placeholder `0`s, you can't legitimately own them yet —
but you can exercise the visual effect directly via Command Bar to confirm it works before a
real Game Pass is wired up:
```lua
local target = game.Players:GetPlayers()[1]
local PlayerDataService = require(game.ServerScriptService.Server.Services.PlayerDataService)
local data = PlayerDataService:GetData(target)
table.insert(data.Inventory.OwnedCosmetics, "Food_Rainbow")
table.insert(data.Inventory.OwnedCosmetics, "Chair_Animated")
```
Then equip both from the Inventory panel while seated. The player's food should continuously
cycle through colors, and their chair should visibly, gently sway back and forth — both should
stop immediately if you re-equip the default Food/Chair instead.

**28. Daily Rewards (new step 10):** open the Daily Rewards panel. "Daily Login" should show
"Streak: 0 day(s)" (first time) with a `Claim` button; click it — Output shows
`[DailyService] <name> claimed the daily login reward: +N gold (streak 1).`, the button
becomes "Claimed", and clicking again does nothing (already claimed today, confirmed by the
button state). The three missions should show `0/3`, `0/1`, `0/5` progress. To progress
**FinishFood**, hold Left Mouse to fully finish eating once — its counter should tick to `1/5`.
To progress **WinGames**/**SurviveRounds**, win a round or use the manual `EliminatePlayer`
trick so a round actually ends with a winner. Once any mission reaches its target, its button
changes to `Claim`; click it to receive the reward and confirm it locks to "Claimed".

**29. Atmosphere (new step 11):** on server start, the room should look visibly darker/warmer
than earlier steps (check `Lighting.Ambient`/`Lighting.ClockTime` in the Command Bar, or just
look at it) — a `PointLight` named `WarmLight` should exist under `Workspace.DiningRoom.Table`.
Roughly every 20–60 seconds, watch for a brief bright flash from a `ThunderFlash` PointLight
near the ceiling (no thunder sound yet — that needs a real audio asset, see
`AtmosphereService.luau`'s TODO comment).

**30. Camera shake (new step 11):** get a player caught (real detection or the manual
`EliminatePlayer` trick) while watching from **another still-alive** player's window — their
view should briefly judder for about 0.3 seconds, confirming the shake fires for everyone, not
just the caught player or spectators.

**31. Rate limiting (new step 11):** from the Command Bar, try firing a rate-limited remote
faster than a human could click:
```lua
local Remotes = require(game.ReplicatedStorage.Shared.Remotes.Remotes)
local event = Remotes.GetEvent("UpdateSetting")
for _ = 1, 5 do
	event:FireServer("MusicVolume", math.random())
end
```
Only the first call in quick succession should actually change the stored setting — check
`PlayerDataService:GetData(target).Settings.MusicVolume` a couple of times across a few seconds
to confirm later calls within the same ~0.3s window were dropped.

This was also validated automatically two ways: `rojo build default.project.json` compiles
the whole tree into a standalone place file with no errors (confirms every module path
resolves), and the entire `src/` tree (excluding the vendored `Packages/` folder) passes
`luau-lsp analyze` under `--!strict` with zero type errors.

## Development strategy

Per the design brief, this game was built **incrementally, one system per step**, each
production-ready (server-authoritative, validated, commented) before moving to the next.
All 11 steps are complete:

1. ~~Project architecture and folder structure~~ — done
2. ~~Player data persistence (`PlayerDataService` on top of ProfileStore) + shared data schema~~ — done
3. ~~Round/game-loop state machine (Lobby → Intermission → InProgress → Ended)~~ — done
4. ~~Seating system (2–10 dynamic seat assignment)~~ — done
5. ~~Eating system + Noise system~~ — done
6. ~~Guard AI (Reading/Looking state machine + suspicion)~~ — done
7. ~~Detection & shooting → elimination → spectator mode~~ — done
8. ~~Win condition, rewards, return-to-lobby~~ — done
9. ~~UI (HUD, lobby, shop, inventory)~~ — done
10. ~~Progression, shop, monetization, daily missions~~ — done (Season Pass/Events deliberately
    out of scope — see [Status](#status))
11. ~~Polish: VFX/SFX (asset-free), optimization pass, anti-cheat hardening~~ — done

**Post-roadmap addition** (requested after the original 11 steps shipped): ~~Lobby &
matchmaking — private party codes and a live browsable public-room list~~ — done. See
[Lobby & Matchmaking](#lobby--matchmaking) for the full architecture; it's a genuinely
different layer (cross-server, via `TeleportService`/`MessagingService`) from anything in the
11 steps above, which is why it's called out separately here rather than folded into step 9's
"lobby" bullet — that step was about in-round UI, this is about getting into a round at all.

### What a real launch still needs

This codebase is a complete, production-*structured* implementation, but a couple of things
are inherently outside what code alone can deliver:

- **Fill in `Shared/Constants/MonetizationIds.luau`** with real Developer Product/Game Pass IDs
  from the Creator Dashboard (instructions in that file).
- **Publish the place** to actually test party codes and public rooms end-to-end — see
  [Lobby & Matchmaking](#lobby--matchmaking)'s testing section; cross-server features can't be
  fully exercised inside a local Studio session by nature of what they do.
- **Real art**: replace `PlaceholderMapService`'s grey-box room/table/guard with a modeled,
  textured map and a rigged guard character (keep the `DinnerSeat` tag contract and the
  `Guard`/`Newspaper`/`Gun` naming contract — see that file's doc comment — and nothing else
  needs to change).
- **Real audio**: gunshot (`Gun.GunshotSound`), thunder rumble, chewing/plate/chair/clock/rain
  ambience — every hook already exists and is called at the right moment, just needs a
  `SoundId`.
- **Real animations**: a proper fork-to-mouth animation and guard reading/aiming animations
  would replace the `TweenService`-driven placeholder motion in `EatingService`/`GuardService`.
