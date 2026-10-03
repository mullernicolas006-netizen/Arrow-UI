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
| — | Automatic rebuild + reinstall + relaunch after a mutation | `LiveUIApp/Build/{PlaygroundBuildRunner,SimulatorDeviceFinder}.swift` |

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
- **The real view moves live during a drag, via the bridge — not touch
  injection.** `RuntimeWireProtocol.BridgeMessage` already had cases
  reserved for exactly this from early on (§25), but nothing sent or
  received them until now. Every `OverlayView` drag's `.onChanged` tick
  streams the live delta (device points, same math as the final
  mutation) to the connected runtime as one atomic
  `.previewOffset(nodeID:x:y:)` message, via `AppState.sendPreview` ->
  `BridgeServer.broadcast`. Both axes travel together in a single message
  deliberately — an earlier revision sent them as two separate messages
  (a `property: String`-tagged case, one for `"offsetX"`, one for
  `"offsetY"`), which meant the runtime applied two separate `@Published`
  updates — and therefore two separate renders — per drag tick, visibly
  less smooth than one combined update.

  On the runtime side, `LiveUIEditModeRoot` owns a `LiveUIPreviewStore`
  (an `ObservableObject` keyed by the same `.liveUITag` id strings),
  injects it via `.environmentObject`, and feeds it from
  `BridgeClient.onMessage`. `LiveUITagModifier` reads
  `previewStore.offsets[id]` and applies it as an `.offset()` on
  `content` *before* its own geometry-reporting `GeometryReader`, so the
  reported geometry — and therefore the desktop-side selection box and
  hit-testing — also stays in sync with the view while it's moving. That
  offset also carries a short (`0.05`s) *linear* `.animation` — not a
  spring — purely to paper over small, irregular gaps between network
  ticks (a message arriving a few ms late reads as a glide, not a jump);
  anything longer, or any easing with overshoot/settle, would add a
  catch-up lag behind the cursor, which is the opposite of the "exact
  1:1 tracking" feel this is for.

  This only ever holds the *delta* of whichever drag is in flight, not a
  view's total offset: a previous drag's rebuild already baked its own
  `.offset()` into the compiled binary, and this is layered on top of
  that. A real drag (one that ends up writing a mutation) deliberately
  leaves the preview in place rather than clearing it — clearing
  immediately would visually snap the view back until the rebuild
  finishes, and then snap again when it does; leaving it bridges
  smoothly into the relaunch, since a relaunched app is a fresh process
  where this transient state is simply gone, replaced by the newly
  compiled real `.offset()`. A no-op drag (below the apply threshold on
  both axes, so nothing was written to source) does send `.clearPreview`,
  since otherwise the real app would be left visibly nudged by an amount
  nothing on disk accounts for. With no runtime connected, every
  `sendPreview` call is a harmless no-op (`BridgeServer.broadcast` to
  zero connections) — only the outline box is visible in that case.

  **A screenshot-crop "ghost" preview existed briefly in between** (an
  earlier commit, superseded by the above) and was removed again: it
  re-rendered a cropped piece of the last polled mirror image to follow
  the cursor, as a stopgap before real live movement existed. In real
  testing it looked actively broken once combined with the real
  mechanism above — a small, wrongly-cropped box with overlapping/
  duplicated text, fighting the real view rather than complementing it —
  so it's gone; `OverlayView` no longer has a `draggedContentPreview`
  function or an `import AppKit`. If live movement alone ever turns out
  too sparse on its own (e.g. a very slow bridge connection), revisit
  with a cleaner design rather than re-adding this one as-is.

  **Caveat worth knowing when this doesn't *look* like it's working:**
  the running Simulator app has to actually be rebuilt against the
  updated `LiveUIRuntime` source before any of this takes effect — unlike
  `LiveUIApp` itself (`swift build`/`swift run` picks up source changes
  immediately), the Simulator app is a *separate*, already-compiled
  binary that only picks up `LiveUIRuntime` changes on its next build.
  `PlaygroundBuildRunner`'s existing auto-rebuild (triggered by the next
  drag that writes a mutation) does this via a normal local-path SwiftPM
  resolution, so no special cache-reset step is needed — but a
  *currently-running* app process, launched before a `LiveUIRuntime`
  change landed, is still running the old code until that next rebuild
  completes.
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
- **Resize handles.** A selected view shows 4 corner handles
  (`OverlayView.ResizeHandle`); dragging one writes/updates a single
  `.frame(width:, height:)` modifier via `LayoutEngine.sizeMutation`,
  mirroring how `offsetMutation` works for moves — same merge-not-stack
  behavior (reads an existing `.frame()` back via `currentFrame(of:)`
  rather than stacking a second one), same "never a spacing/padding
  hack, so it can never affect a sibling" property. One real difference
  from offset: a view with no `.frame()` yet still has a real, measured
  size (its intrinsic size), so `sizeMutation`'s "no existing frame"
  branch seeds from the view's current `RuntimeGeometry`, not from 0 —
  defaulting to 0 like offset does would snap the view to a tiny wrong
  size on its very first resize.

  Top/left handles also write an `.offset(x:, y:)` alongside the
  `.frame()` change, so the *opposite* corner stays anchored while
  resizing — the standard "drag the top-left handle, the view grows
  toward the top-left" behavior every other design tool has. Each
  corner can produce up to two mutations (one per axis) plus up to two
  offset mutations, applied sequentially the same way a diagonal
  move-drag already does.

  Only the local outline previews a resize in flight — unlike a move,
  this doesn't yet stream a live preview to the real running view over
  the bridge. That hits a genuine composition problem a move doesn't: a
  *second* resize's live override would need to apply *outside*
  whatever `.frame()` a previous resize's rebuild already compiled in,
  but `.liveUITag` sits *inside* the modifier chain (it wraps the raw
  view before any `.frame()`/`.offset()` written after it in source), so
  a repeat live-preview resize would just get re-constrained by the
  already-compiled outer `.frame()` and visually do nothing. Left
  unsolved rather than worked around; the real result still shows up
  correctly after the gesture ends and the auto-rebuild completes, same
  as every other mutation.

  Also not yet done: edge (non-corner) handles for resizing one
  dimension at a time, and handles on a `ZStack`-free-form vs. stack
  child behaving any differently (there isn't a parent-aware resize
  heuristic the way `LayoutEngine.mutation`'s spacing path exists for
  moves — every resize always goes through `sizeMutation`).

  Several things made the handles hard to actually grab in real
  testing. Two were real but secondary: `ResizeHandle` declared only
  `CaseIterable`, not `Hashable`/`Equatable`, despite being used with
  `ForEach(..., id: \.self)` and `==` — fixed by declaring the
  conformance explicitly; and each handle's visible dot is only 9pt,
  genuinely hard to land a mouse on through `CanvasTransform`'s scaling
  — its *hit area* is now a separate, larger (22pt) invisible region
  centered on the same point.

  A real fix along the way: `state.selection` only ever got set from
  `dragGesture`'s `onChanged` — and a plain `DragGesture`, even with
  `minimumDistance: 0`, is built around tracking *motion*. On macOS it's
  driven by `mouseDragged` events, which a genuinely stationary click
  (`mouseDown` immediately followed by `mouseUp`, no movement at all in
  between) never generates, so `onChanged` could simply never fire for a
  real click regardless of `minimumDistance`. `tapGesture` (a
  `SpatialTapGesture`, built on an actual click recognizer, not
  motion-tracking) now handles selection on its own, composed with
  `dragGesture` via `.simultaneously(with:)` on the same view.

  **The actual root cause**, found only after real console logs showed
  selection *was* firing correctly on every click (`hit` / `resolved` /
  `tap` all logging as expected) and resize still never triggered:
  `boxView`'s `isSelected` check compared `state.selection?.description`
  — the *indexed* node's full `ViewNodeID.description`, e.g.
  `"VStack@/Users/.../ContentView.swift#0.2.0.5.1.0.0.3.0.2.1.0.0"`
  (absolute file path, deep real structural path) — against `id`, the
  *runtime*-reported id string, e.g. `"VStack@ContentView.swift#2"`
  (short hand-typed file name and path from `.liveUITag(id:)`). These
  two string formats can never be equal, so `isSelected` was `false`
  unconditionally, for every view, regardless of what was clicked —
  meaning resize handles (gated purely on `isSelected`) could never have
  rendered no matter how correct everything else was. The outline still
  *looked* like selection worked in earlier testing only because
  `isDragging` (a correct runtime-id-to-runtime-id comparison) was
  transiently true during an active drag — never because of
  `isSelected`.

  Fixed with a new `AppState.selectedRuntimeID: String?`, set directly
  from the same `hitID` `OverlayView` already resolves `selection`
  from (in both `tapGesture` and `dragGesture`), and compared
  runtime-id-to-runtime-id in `boxView` — the same pattern `isDragging`
  already used correctly. `state.selection` itself (the indexed
  `ViewNodeID`) is unaffected and still correct for `InspectorView`,
  which compares `ViewNodeID` to `ViewNodeID`, not to a runtime string.

  The cursor also changes to a diagonal resize icon on hover over a
  handle (`resizeCursor(for:)`), reset on hover-exit and, belt-and-
  suspenders, in the gesture's own `onEnded` (hover-exit tracking isn't
  fully reliable mid-drag). SwiftUI doesn't do this automatically for
  any gesture — it has to be built explicitly via `.onHover` +
  `NSCursor`. AppKit's public `NSCursor` API has no diagonal-resize
  cursor (only `.resizeLeftRight`/`.resizeUpDown`); rather than reach for
  a private/undocumented cursor selector (which real apps do use, but
  it's exactly the kind of risky-undocumented-API choice this project
  has avoided everywhere else — see `idb`, `simctl`), the cursor is
  built from an SF Symbol (`arrow.up.left.and.arrow.down.right` /
  `arrow.up.right.and.arrow.down.left`) via `NSCursor(image:hotSpot:)` —
  both are literally diagonal double-headed arrows, public API only.

  **Real crash found via a pasted console log, not guessed at:** the
  diagnostic `print()` calls added a few iterations earlier (to trace
  the live-preview send/receive path end to end) included one on *every*
  `.onChanged` tick in both `OverlayView`'s drag gesture and
  `LiveUIPreviewStore.apply` — a drag gesture's `onChanged` can fire
  dozens of times per second, and logging every single one flooded
  Xcode's debug console fast enough that the Playground app got killed
  outright (`Terminated due to signal 9`), before the user could ever
  see whether selection/resize/drag had actually worked. The flooded log
  itself was the proof the preview mechanism *was* working — real
  `previewOffset` values streaming through correctly — so this was never
  a selection or hit-testing bug at all; it was the logging that had
  been added to debug an earlier, different problem. Both per-tick
  `print()` calls are gone now; the one-time start/end logs in
  `dragGesture`/`resizeGesture`/`tapGesture` stay.
- **Selection outlines are hover/selection-only, not always-on.** Early
  versions drew a box for *every* known view simultaneously. Since a
  parent's box always encloses its children's (a VStack's box always
  contains its Button's), that read as visual noise and was genuinely
  indistinguishable from "dragging one view also moved another one" — a
  real bug report that turned out to be this rendering choice, not a
  mutation bug. `OverlayView` now hit-tests the mouse position on every
  `.onContinuousHover` tick (suppressed mid-drag) and only draws a box for
  the view that's hovered, selected, or actively being dragged.
- **Canvas drags write `.offset(x:, y:)`, not a semantic layout
  property.** Earlier iterations tried approximating a drag with VStack
  `spacing` (only unambiguous with exactly two children) and, before
  that, edge-specific `padding` — both are documented above in git
  history and in the superseded revisions of this file, and both were
  real attempts at the spec's original "never a raw pixel hack" §5-6
  philosophy. In practice, real user testing kept hitting the same
  complaint regardless of which one was active: a drag never lands
  *exactly* where the cursor is released (both write a shared layout
  number, not a position), and worse, changing that shared number can
  visibly move a sibling that was never touched — "dragging this button
  also moved the other button," reported independently of which
  heuristic was in place at the time. Given that choice explicitly (see
  this feature's commit history), the product settled on precise
  positioning over semantic-minimal diffs: `LayoutEngine.offsetMutation`
  always writes/updates `.offset(x:, y:)` on the dragged view itself.
  `.offset` is a pure rendering displacement — SwiftUI never runs it
  through the parent's layout pass, so it literally cannot resize a stack
  or reposition a sibling, and the view moves by exactly the delta
  computed from the drag. `OverlayView`'s drag gesture now also applies
  both axes of a diagonal drag independently (each as its own mutation,
  re-resolving the node in between) instead of picking one dominant axis
  and dropping the other, which was itself a contributor to "doesn't land
  where I dropped it." `LayoutEngine.mutation(for:stackNodeID:)` (the
  spacing/padding decision table) is left in place and still covered by
  its own tests — the Inspector's spacing stepper still edits `spacing`
  directly as an explicit, typed edit, which is a different action from
  a drag and isn't affected by this change — but nothing in the canvas
  drag path calls it anymore.

## Automatic rebuild + relaunch

`AppState.apply(_:)` schedules a debounced (1.5s) rebuild after every
successful mutation via `PlaygroundBuildRunner`: finds the booted
Simulator (`xcrun simctl list devices booted -j`), runs `xcodebuild`
against an auto-detected `.xcodeproj` (`AppState.openProject` searches
`projectRoot` and up to 4 parent directories for one `.xcodeproj`, and
assumes the scheme name matches the project's filename — true for an
unmodified Xcode "App" template, not guaranteed for a renamed/multi-scheme
project), installs the result (`simctl install`), and relaunches it
(`simctl launch`, using the bundle identifier reported in the runtime's
`.hello` message). Debounced and single-flight: several quick drags in a
row trigger one rebuild, not one per drag, and a rebuild already in
flight is left to finish rather than restarted.

**Not yet verified against a real build** — this is the same category of
risk as the SwiftSyntax code: written from documented `xcodebuild`/
`simctl` behavior, not run against a compiler. The specific things to
check if it doesn't work on the first try: whether `-destination
"platform=iOS Simulator,id=<udid>"` is accepted as written, and whether
the built `.app` really lands at `<derivedDataPath>/Build/Products/
Debug-iphonesimulator/` for this project's build settings (that path
shape is a long-stable Xcode convention, but an unusual project
configuration could still place it elsewhere). Both failures print the
full `xcodebuild`/`simctl` output to the `LiveUIApp` terminal via
`print()`, following the same "make failures visible, not silent"
approach that found every bridge/connection bug earlier.

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
