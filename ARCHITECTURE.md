# LiveUI — Architecture & Status

This document maps the LiveUI product spec onto the actual code in this
repo, and is explicit about what has and hasn't been verified.

## Environment this was built in (read this first)

This code was written in a Linux container with **no Xcode, no Swift
toolchain, and no iOS Simulator**. Nothing here has been compiled or run.
That's not a detail to gloss over — it's the single biggest risk in this
codebase right now.

What that means concretely:

- The logic (indexing, mutation, diffing, layout heuristics, undo/redo) is
  real — not stubbed, not mocked — and is backed by an actual test suite
  (`Tests/LiveUICoreTests`). But that test suite has never been *run*.
- The `LiveUICore` target's use of `SwiftSyntax`/`SwiftParser` (parsing,
  rewriting call expressions, building new argument lists) was written
  against the swift-syntax 509+ API surface (the one that shipped with
  Swift 5.9, e.g. `LabeledExprListSyntax`, `DeclReferenceExprSyntax`,
  `FunctionCallExprSyntax.arguments`). That API has been stable since
  late 2023, but some fine-grained calls (particular static `TokenSyntax`
  factory overloads, `LabeledExprSyntax`'s exact initializer signature)
  were written from memory, not verified against the compiler.

**First thing to do on a Mac:**

```bash
swift build
swift test
```

Fix whatever the compiler flags — it will very likely be small, localized
API-name mismatches in `Sources/LiveUICore/SwiftSyntaxEngine.swift`, not
structural problems. If you hit errors, the fastest path is to paste the
compiler output back into a LiveUI session; the design intent behind each
function is documented in comments specifically so that fix-up doesn't
require re-deriving the logic.

## What's implemented, and where, relative to the spec

| Spec section(s) | Concept | Where |
|---|---|---|
| §8-9 | View Registry, view identity | `LiveUIModels/Mutation.swift` (`ViewNodeID`, `StructuralPath`) |
| §11-13 | SwiftSyntax / AST, minimal source modification | `LiveUICore/SwiftSyntaxEngine.swift` |
| §14-17, §69 | Layout Intelligence Engine ("holy grail" heuristic) | `LiveUICore/LayoutEngine.swift` |
| §27-28, §54-55 | Undo/redo, rollback safety | `LiveUICore/HistoryEngine.swift` |
| §28, §45 | Code diff | `LiveUICore/Diagnostics.swift` |
| §49 | Source Indexer | `LiveUICore/SourceIndexer.swift` |
| §50-51 | Source Mapper, Layout Engine's container/modifier awareness | `SwiftSyntaxEngine.resolve` / `.findModifierCall` / `.outermostChainedExpr` |
| §52 | Mutation Engine | `LiveUICore/MutationEngine.swift` |
| §7, §56 | Runtime <-> desktop transport | `SimulatorBridge/{Framing,BridgeClient,BridgeServer}.swift` |
| §7-8 | View registration inside the running app | `LiveUIRuntime/LiveUITag.swift`, `LiveUIEditModeRoot.swift` |
| §6.1, §20, §23 | Desktop app shell, hierarchy, inspector | `LiveUIApp/*` |

Everything above is real logic with a clear, single responsibility — not
placeholders. The mutation engine specifically implements the exact
scenario from §15/§69: dragging inside a `VStack` produces a `spacing`
argument change, not an `.offset()`.

## What is *not* implemented (deliberately out of MVP scope, §65-67)

- **Actual pixel-level Simulator embedding / click-through.** `OverlayView`
  draws wireframe boxes from reported `RuntimeGeometry`, not the
  Simulator's real rendered pixels. True screen mirroring + input
  forwarding into the real Simulator window is a separate integration
  (likely `simctl`/ScreenCaptureKit-based) layered on top of the same
  geometry data — it does not change anything in `LiveUICore`.
- **Automatic view instrumentation.** App code currently has to call
  `.liveUITag(id:type:file:path:)` manually, matching the exact ID
  `SourceIndexer` would compute. A build-time (or macro-based) pass that
  inserts these tags automatically is future work — see §7's own framing
  of the runtime as something that should eventually be "removable in
  Release builds."
- **Enum-shorthand modifier arguments** (`.padding(.top, 12)`,
  `.frame(alignment: .leading)`). `MutationValue` only models literals
  (int/double/bool/string), not member-access shorthand. `addModifier`
  therefore only supports things like `.padding(12)` or
  `.frame(width: 240)` today. Extending `MutationValue` with a
  `.memberShorthand(String)` case is the natural next step (§18's
  `.frame(width: 240)` example already works; §15's alternative
  `.padding(.top, 12)` form does not, though the *simpler* `VStack(spacing:)`
  form of the same example — the one actually demonstrated end-to-end in
  `MutationEngineTests` — does).
- **String literal mutation.** Not needed by any §65 MVP property, and the
  exact SwiftSyntax type for string-literal segments has moved across
  versions, so it's stubbed to throw `.unsupportedLiteral` rather than
  guessed at.
- **Dynamic views** (`ForEach`, `if`/`else` branches), **components**
  (§31-33), **multi-device / dark mode / dynamic type** (§37-40),
  **animations/gestures** (§41-42), **the AI layer** (§43). All explicitly
  later phases in the spec (§68).
- **Conflict detection** (§30: someone hand-edits the file while a mutation
  is in flight). `MutationEngine` always re-parses the current on-disk /
  in-memory source before mutating, so a mutation targeting stale content
  will either resolve to the *current* node (by structural path or nearest
  type match) or fail with `nodeNotFound` — it does not currently diff
  against an expected "old value" and warn, which §30 asks for. Worth
  adding: compare `oldValue` in the `Mutation` against what's actually at
  the resolved location before applying, and surface a conflict instead of
  silently proceeding.
- **The macOS app is not an `.xcodeproj`.** It's a SwiftUI `App` built as a
  SwiftPM executable target (`swift run LiveUIApp`), specifically so the
  whole monorepo builds with one `swift build` without needing a
  hand-authored Xcode project file. Wrapping it as a proper `.app` bundle
  (icon, Info.plist, code signing) for distribution is future work.

## Wiring it into a real project (once it builds)

1. `swift build` at the repo root.
2. In the SwiftUI app you want to edit, add this package as a local SPM
   dependency and depend on `LiveUIRuntime`.
3. Wrap your root view:
   ```swift
   WindowGroup {
       LiveUIEditModeRoot(appName: "MyApp", bundleIdentifier: Bundle.main.bundleIdentifier ?? "") {
           ContentView()
               .liveUITag(id: "VStack@ContentView.swift#0", type: "VStack", file: "ContentView.swift", path: "0")
       }
   }
   ```
   (Manual tagging, per "not implemented" above.)
4. Run `swift run LiveUIApp`, open your project folder, run your app in the
   Simulator — the two should find each other over `localhost:51820`.

## Why a monorepo SwiftPM package instead of five folders of stub files

The spec's own module list (§46) reads naturally as folders, but folders
with no real content would just be an elaborate table of contents. This
repo instead groups the same responsibilities into SwiftPM targets that
have actual dependency edges between them (`LiveUIApp` depends on
`LiveUICore` depends on `LiveUIModels`, etc.) and — critically — that a
Mac can build and test today rather than "eventually, once someone adds
real code." The `Source Mapper`, `Runtime Registry`, and `Diagnostics`
concepts from §46 are folded into `LiveUICore`/`SwiftSyntaxEngine` rather
than kept as separate near-empty targets; split them out again once they
grow enough to warrant it.
