# Controllers

Drop one ModuleScript per client system here (e.g. `CameraController.luau`, `HudController.luau`,
`EatingController.luau`).

**Contract:**

- Return a table (a singleton).
- Optional `function Controller.Init(self)` — set up state, look up other controllers via
  `require(script.Parent.OtherController)`. Runs for **every** controller before **any**
  controller starts.
- Optional `function Controller.Start(self)` — begin doing real work (input binding, UI
  connections, `RunService.RenderStepped`, etc.). Runs only after all controllers have
  finished `Init`.

`src/Client/init.client.luau` discovers and runs every ModuleScript here automatically — no
manual registration needed. Errors in one controller's `Init`/`Start` are caught and logged;
they do not stop other controllers from loading.

**Rules:**

- Controllers present state and forward player intent to the server — they never decide
  outcomes themselves (no client-side "did I get caught" logic, no client-side currency math).
  Treat every RemoteEvent from the server as the source of truth.
