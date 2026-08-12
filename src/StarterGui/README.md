# StarterGui

Deliberately empty. The UI (HUD, Settings, Inventory/Shop/Daily Rewards shells) is built
entirely by `src/Client/Controllers/HudController.luau` via `Instance.new()` into
`LocalPlayer.PlayerGui` at runtime — the same "no hand-authored Studio assets, everything is
code and version-controlled" approach `PlaceholderMapService` uses for the 3D world, applied to
2D UI. See `HudController.luau`'s file doc comment for the reasoning.
