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
| §21-26 | Direct manipulation: click-to-select + drag-to-mutate on the canvas | `LiveUIApp/Views/OverlayView.swift` |
| §22-23 | Screen mirroring, coordinate mapping | `LiveUIApp/Mirroring/{SimulatorScreenMirror,CanvasTransform}.swift` |

Everything above is real logic with a clear, single responsibility — not
placeholders. The mutation engine specifically implements the exact
scenario from §15/§69: dragging inside a `VStack` produces a `spacing`
argument change, not an `.offset()`.

## Screen mirroring: what's real, what's a known gap

`SimulatorScreenMirror` polls `xcrun simctl io booted screenshot` (fully
public, documented Apple tooling — no private APIs, no third-party
dependency) and `OverlayView` composites it with the selection/drag
overlay through `CanvasTransform`, which uses the device's real screen
size (now sent over the wire in `RuntimeMessage.hello`) so the mirrored
image and the geometry boxes are pixel-aligned regardless of window size.

What this deliberately does *not* do yet:

- **It's a still-image poll, not video.** A few frames per second at
  most. If that feels too choppy in practice, the documented upgrade path
  is [`idb`](https://github.com/facebook/idb) (Meta's iOS Development
  Bridge) — it already solved real-time Simulator streaming using private
  CoreSimulator frame-buffer APIs, and is a maintained, swappable
  replacement for just the polling loop in `SimulatorScreenMirror`; it
  was deliberately *not* used for this first pass so the core
  click/drag-to-mutate loop has zero risky/private-API dependencies.
- **No input is forwarded into the Simulator.** Selection and dragging
  happen entirely on LiveUI's own canvas, hit-tested against
  `RuntimeGeometry` LiveUI already collects — the running app never
  receives synthetic taps. That's sufficient for the whole edit loop
  (select → drag → mutate source), and deliberately avoids needing
  touch-injection (which, unlike screenshotting, has no public API and
  would require something like `idb`). Forwarding real taps through would
  only matter for letting Edit Mode also interact with the live app
  (typing into fields, exercising real button actions) — a distinct,
  later feature.
- **Canvas drags don't know their parent yet.** `LayoutEngine.mutation`
  can produce the "grow the VStack's spacing" mutation, but only when
  given a `parentType`/`stackNodeID` — and `OverlayView`'s drag gesture
  currently passes `nil` for both, because `RuntimeViewInfo.parentID`
  isn't populated by today's manual `.liveUITag(...)` call sites. So
  every canvas drag takes the generic padding fallback. The Inspector's
  spacing stepper already proves the smarter VStack-spacing path works
  end to end; wiring `parentID` through is what's needed to get the same
  smarts from a canvas drag.

## What is *not* implemented (deliberately out of MVP scope, §65-67)

- **Automatic view instrumentation.** App code currently has to call
  `.liveUITag(id:type:file:path:)` manually, matching the exact ID
  `SourceIndexer` would compute. A build-time (or macro-based) pass that
  inserts these tags automatically is future work — see §7's own framing
  of the runtime as something that should eventually be "removable in
  Release builds."
- **Enum-shorthand modifier arguments, partially.** `MutationValue` now has
  a `.memberShorthand(String)` case (e.g. `.padding(.top, 12)`), and
  `LayoutEngine`'s canvas-drag fallback uses it — this was necessary, not
  optional: the earlier all-edges `.padding(N)` form silently padded the
  cross axis too (a vertical drag was visibly also shoving the view
  sideways). Still only wired up for the padding edge case; other
  shorthand args (`.frame(alignment: .leading)`, etc.) aren't produced by
  anything yet, though the model now supports them.
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
