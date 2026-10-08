# LiveUI (Arrow-UI)

A bidirectional visual development environment for SwiftUI: drag a view in
a running app, and LiveUI rewrites the real Swift source that produced it
— minimally, structurally, and reversibly. See `ARCHITECTURE.md` for the
full design, module map, and current status.

## Quick start (on a Mac with Xcode/Swift installed)

```bash
swift build
swift test    # exercises the mutation engine's "holy grail" scenario end-to-end
swift run LiveUIApp
```

> This repo was authored without access to a Swift toolchain (see
> `ARCHITECTURE.md`'s "Environment this was built in" section) — `swift
> build`/`swift test` have not actually been run yet. Start there.

## Layout

- `Sources/LiveUIModels` — shared data model: view identity, `Mutation`, wire protocol.
- `Sources/LiveUICore` — SourceIndexer, SwiftSyntaxEngine, MutationEngine, LayoutEngine, HistoryEngine, Diagnostics.
- `Sources/SimulatorBridge` — local TCP transport between a running app and the desktop app.
- `Sources/LiveUIRuntime` — the `.liveUITag(...)` view modifier + registry that runs inside the app under development.
- `Sources/LiveUIApp` — the macOS desktop app (SwiftUI, run via `swift run LiveUIApp`).
- `Tests/LiveUICoreTests` — the mutation engine, layout engine, and history engine test suite.
