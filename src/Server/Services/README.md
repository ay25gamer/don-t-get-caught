# Services

Drop one ModuleScript per server system here (e.g. `RoundService.luau`, `SeatingService.luau`,
`GuardService.luau`, `PlayerDataService.luau`).

**Contract:**

- Return a table (a singleton; use `local Service = {}` and, if it needs internal state,
  build it OOP-style with `Service.new()` internally — but export the singleton, not the class,
  unless the system genuinely needs multiple instances, e.g. one Guard AI controller per round).
- Optional `function Service.Init(self)` — set up state, look up other services via
  `require(script.Parent.OtherService)`. Runs for **every** service before **any** service starts.
- Optional `function Service.Start(self)` — begin doing real work (loops, `RunService` connections,
  `Players.PlayerAdded`, etc.). Runs only after all services have finished `Init`.

`src/Server/init.server.luau` discovers and runs every ModuleScript here automatically — no
manual registration needed. Errors in one service's `Init`/`Start` are caught and logged; they
do not stop other services from loading.

**Rules:**

- Services are server-authoritative. Never trust data a RemoteEvent handler receives about the
  calling player's own state (position, whether they're "eating", etc.) — re-derive or validate
  it server-side.
- Keep RemoteEvents to a minimum; prefer server-driven state replication over chatty remotes.
