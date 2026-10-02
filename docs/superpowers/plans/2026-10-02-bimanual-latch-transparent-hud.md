# Bimanual Pinch-Hold Latch + Transparent HUD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add physical-left-hand pinch-hold locking for right-hand continuous gestures, plus a transparent click-through HUD, while preserving existing single-hand tracking behavior and replacing the old two-hand clutch/right-click mapping.

**Architecture:** Keep `TrackpadGestureEngine` focused on single-hand intent estimation. Add handedness from Vision, use `AppController` to assign physical hand roles and run the 300 ms left-hand hold state machine, and route scroll/drag/zoom through a dedicated `BimanualLatchCoordinator`. Add a separate AppKit/SwiftUI HUD window controller so display concerns remain outside the gesture engine.

**Tech Stack:** Swift 5, SwiftUI, AppKit, AVFoundation, Vision, Core Graphics, DispatchSourceTimer, Xcode 16/macOS target.

**Spec:** `docs/superpowers/specs/2026-10-02-bimanual-latch-transparent-hud-design.md`

## Global Constraints

- macOS deployment target remains `13.0`.
- No third-party dependencies.
- Physical right hand is the primary operation hand; physical left hand is the Hold/modifier hand when both are confidently identified.
- Left pinch thresholds: arm/open `>= 0.58`, closed `<= 0.32`, hold `0.30 s`, release `>= 0.48` for `0.08 s`, missing-left safety release `0.25 s`.
- Latchable action snapshot must be no older than `0.20 s`.
- Scroll latch emits at `60 Hz`; effective speed must stay inside the existing engine envelope of `±22` px per 120 Hz source tick.
- Zoom latch repeat interval must not be faster than the existing `0.030 s` zoom pulse limit.
- Scroll, drag, and enabled zoom are latchable. Clicks, page actions, right-click, Back/Forward, Mission Control/App Exposé/Space switching are not.
- Old `辅助手张开 → 离合` and `辅助手捏合 → 右键` behavior is superseded.
- Single-hand trackpad behavior and page mode remain supported.
- HUD defaults on, can be disabled independently, is transparent, non-activating, and click-through.
- Every stop/error/reset/mode-switch path releases a latched drag and stops repeating scroll/zoom output.

## Review Focus

1. **Camera mirroring / hand identity:** Vision ordering or image position must not swap left/right roles; unknown chirality never arms Hold. Task 1 + Task 3.
2. **Stale action reuse:** pinching after scroll/zoom ended must not resurrect an action older than 200 ms. Task 2.
3. **Lifecycle races:** stop, camera error, mode switch, bimanual disable, and repeated reset must not leave a timer or mouse button active. Tasks 2–3.
4. **Concurrent right-hand use:** latched scroll continues while the right hand returns to pointer/click; latched drag suppresses conflicting actions. Tasks 2–3.
5. **HUD interference:** HUD cannot become key/main, intercept mouse events, or vanish on Space/full-screen transitions; disabling HUD cannot disable gesture processing. Task 4.

---

### Task 1: Add handedness and shared bimanual/HUD models

**Files:**
- Modify: `GestureControl/Models/GestureModels.swift`
- Modify: `GestureControl/Vision/HandPoseDetector.swift`
- Create: `scripts/v14_bimanual_latch_hud_smoke_test.swift`

**Interfaces:**
- Produces: `enum Handedness: Equatable { case left, right, unknown }`
- Produces: `enum LatchedAction: Equatable`
- Produces: `enum LeftHoldState: Equatable`
- Produces: `enum GestureHUDMode: Equatable`
- Produces: `struct GestureHUDState: Equatable`
- `HandPoseResult` gains `let handedness: Handedness`.

- [ ] **Step 1: Write failing v14 smoke assertions**

The smoke test source-checks the new model names and `HandPoseResult.handedness`, and includes a tiny pure role model proving unknown-handedness is not a valid Hold hand.

- [ ] **Step 2: Run the smoke test and confirm RED**

Run: `xcrun swift scripts/v14_bimanual_latch_hud_smoke_test.swift`

Expected: FAIL because the models and handedness field do not exist.

- [ ] **Step 3: Add shared models**

Use these exact shapes:

```swift
enum Handedness: Equatable { case left, right, unknown }
enum LatchedAction: Equatable { case scroll(deltaX: Double, deltaY: Double); case drag; case zoom(step: Int) }
enum LeftHoldState: Equatable { case idle; case candidate(progress: Double); case latched(LatchedAction) }
enum GestureHUDMode: Equatable { case idle, active, holdCandidate, latched }
struct GestureHUDState: Equatable {
    var mode: GestureHUDMode
    var leftHandText: String
    var rightHandText: String
    var actionText: String
    var holdProgress: Double?
    var isLocked: Bool
}
```

- [ ] **Step 4: Add Vision chirality to `HandPoseResult`**

Map `VNHumanHandPoseObservation.chirality` directly to `Handedness`; do not infer handedness from camera x-position or result order. Apple Vision exposes chirality specifically as pose handedness.

- [ ] **Step 5: Verify GREEN**

```bash
xcrun swift scripts/v14_bimanual_latch_hud_smoke_test.swift
xcodebuild -project GestureControl.xcodeproj -scheme GestureControl -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add GestureControl/Models/GestureModels.swift GestureControl/Vision/HandPoseDetector.swift scripts/v14_bimanual_latch_hud_smoke_test.swift
git commit -m "feat: add bimanual handedness and HUD state models"
```

---

### Task 2: Implement `BimanualLatchCoordinator`

**Files:**
- Create: `GestureControl/Gesture/BimanualLatchCoordinator.swift`
- Modify: `scripts/v14_bimanual_latch_hud_smoke_test.swift`

**Interfaces:**
- Consumes: `TrackpadInteraction`, `LatchedAction`.
- Produces:

```swift
final class BimanualLatchCoordinator {
    var onScrollDelta: ((Double, Double) -> Void)?
    var onLeftButton: ((Bool) -> Void)?
    var onZoomStep: ((Int) -> Void)?
    var onStateChanged: ((LatchedAction?) -> Void)?

    func observeInteraction(_ interaction: TrackpadInteraction)
    func observeScroll(deltaX: Double, deltaY: Double, timestamp: TimeInterval)
    func observeLeftButton(_ down: Bool, timestamp: TimeInterval)
    func observeZoomStep(_ step: Int, timestamp: TimeInterval)
    func currentLatchableAction(timestamp: TimeInterval, zoomEnabled: Bool) -> LatchedAction?
    func latchCurrentAction(timestamp: TimeInterval, zoomEnabled: Bool) -> Bool
    func release(timestamp: TimeInterval)
    func reset()
    var latchedAction: LatchedAction? { get }
}
```

`observeScroll`, `observeLeftButton`, and `observeZoomStep` are the single forwarding boundary: when no latch owns that channel they immediately call the matching output closure; callers must not separately emit the same event.

- [ ] **Step 1: Extend v14 with latch lifecycle tests**

Cover: fresh scroll latches; >200 ms scroll does not; drag keeps button down and releases on reset; zoom requires `zoomEnabled`; zoom snapshot normalizes to signed direction (`-1` or `+1`); discrete/system interactions do not latch; release/reset are idempotent; scroll timer semantics are 60 Hz; effective scroll speed stays within the existing `±22`/120 Hz envelope.

- [ ] **Step 2: Run v14 and confirm RED**

Run: `xcrun swift scripts/v14_bimanual_latch_hud_smoke_test.swift`

- [ ] **Step 3: Implement state and stale-action arbitration**

Serialize coordinator state with one private lock or serial queue. Record timestamps for the latest scroll, button state, zoom step, and interaction. `currentLatchableAction(...)` is read-only and returns only a current action with age `<= 0.20 s`; `latchCurrentAction(...)` uses that same selection logic and mutates latch state.

- [ ] **Step 4: Implement sustained output**

Scroll: `DispatchSourceTimer` at 60 Hz. Since engine scroll output is 120 Hz, sustain the captured velocity equivalently (e.g. 2× the captured per-tick delta at 60 Hz) while clamping effective speed to the existing engine bound.

Zoom: repeat one signed step no faster than 30 ms. Drag: no repeating timer; keep logical left button down and suppress an engine mouse-up while drag is latched.

- [ ] **Step 5: Verify GREEN**

```bash
xcrun swift scripts/v14_bimanual_latch_hud_smoke_test.swift
xcrun swift scripts/v131_event_lifecycle_50x_smoke_test.swift
```

- [ ] **Step 6: Commit**

```bash
git add GestureControl/Gesture/BimanualLatchCoordinator.swift scripts/v14_bimanual_latch_hud_smoke_test.swift
git commit -m "feat: add continuous gesture latch coordinator"
```

---

### Task 3: Replace old two-hand behavior in `AppController`

**Files:**
- Modify: `GestureControl/AppController.swift`
- Modify: `GestureControl/Gesture/TrackpadGestureEngine.swift`
- Modify: `scripts/v12_realtime_intent_smoke_test.swift`
- Modify: `scripts/v14_bimanual_latch_hud_smoke_test.swift`

**Interfaces:**
- Consumes: handedness/models from Task 1 and coordinator from Task 2.
- Produces: `@Published private(set) var leftHoldState: LeftHoldState`
- Produces: `@Published private(set) var hudState: GestureHUDState`
- Keeps persisted key `trackpad.bimanualAssistEnabled.v1` for migration compatibility.

- [ ] **Step 1: Add failing Hold-state tests**

Cover exact thresholds: 100–250 ms pinch does not latch; 300 ms does; release needs 80 ms above `0.48`; dropout <250 ms does not flap; 250 ms continuous loss releases; unknown handedness does not arm; old open-palm clutch and secondary-pinch right-click source paths are absent.

- [ ] **Step 2: Run v14 and confirm RED**

Run: `xcrun swift scripts/v14_bimanual_latch_hud_smoke_test.swift`

- [ ] **Step 3: Replace hand-role assignment**

When both confidently identified hands exist, `.right` is primary and `.left` is modifier. Preserve temporal tracking only to stabilize reacquisition, not to override known chirality. With only one hand, preserve normal single-hand behavior; however, while a recent right-hand track exists, a lone left/unknown observation cannot immediately steal the primary pointer role.

- [ ] **Step 4: Replace `updateBimanualAssist` with left pinch-hold state**

Use `currentLatchableAction(...)` to decide whether a left pinch may enter `.candidate`. At 300 ms call `latchCurrentAction(...)`; do not call the mutating latch API during candidate probing. Release and 250 ms sustained loss call coordinator `release(...)` and return Hold state to `.idle`.

- [ ] **Step 5: Route outputs through coordinator exactly once**

- Pointer delta remains direct to `TrackpadController`.
- Scroll callback only calls `latchCoordinator.observeScroll(...)`.
- Left-button callback only calls `latchCoordinator.observeLeftButton(...)`; releases are still allowed during cleanup.
- Zoom callback only calls `latchCoordinator.observeZoomStep(...)`.
- Coordinator output closures call `trackpad.scroll`, `trackpad.setLeftButton`, and `handleZoom` respectively.
- System swipes are ignored while an incompatible latch is active.

- [ ] **Step 6: Remove obsolete external clutch support**

Delete `setExternalClutch(...)`, `externalClutchActive`, and related comments/branches from `TrackpadGestureEngine` once no callers remain. Do not alter single-hand scroll retraction, continuity fusion, pointer smoothing, or zoom arbitration.

- [ ] **Step 7: Make cleanup exhaustive**

Before trackpad reset on stop, camera error, control-mode change, bimanual disable, recognition reset, relaunch/quit: `latchCoordinator.reset()` and force final `trackpad.setLeftButton(down: false)`. Repeated reset/release is safe.

- [ ] **Step 8: Verify focused regressions**

```bash
xcrun swift scripts/v14_bimanual_latch_hud_smoke_test.swift
xcrun swift scripts/v12_realtime_intent_smoke_test.swift
xcrun swift scripts/v131_event_lifecycle_50x_smoke_test.swift
xcrun swift scripts/v132_selection_page_50x_smoke_test.swift
xcodebuild -project GestureControl.xcodeproj -scheme GestureControl -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

If V1.2 smoke coverage contains the retired clutch model, replace only that obsolete section with a source invariant that confirms the clutch is intentionally gone; retain the other V1.2 coverage.

- [ ] **Step 9: Commit**

```bash
git add GestureControl/AppController.swift GestureControl/Gesture/TrackpadGestureEngine.swift scripts/v12_realtime_intent_smoke_test.swift scripts/v14_bimanual_latch_hud_smoke_test.swift
git commit -m "feat: replace bimanual clutch with left-hand hold latch"
```

---

### Task 4: Add and wire the transparent HUD

**Files:**
- Create: `GestureControl/UI/GestureHUDView.swift`
- Create: `GestureControl/UI/GestureHUDWindowController.swift`
- Modify: `GestureControl/AppController.swift`
- Modify: `GestureControl/UI/MenuBarPanel.swift`
- Modify: `GestureControl.xcodeproj/project.pbxproj`
- Modify: `scripts/v14_bimanual_latch_hud_smoke_test.swift`

**Interfaces:**
- Consumes: `GestureHUDState`, `leftHoldState`.
- Produces:

```swift
final class GestureHUDWindowController {
    func update(state: GestureHUDState)
    func setEnabled(_ enabled: Bool)
    func setRunning(_ running: Bool)
    func hide()
}
```

- [ ] **Step 1: Add failing HUD/UI/project tests**

Require: transparent background, `isOpaque = false`, `ignoresMouseEvents = true`, non-activating panel, `.canJoinAllSpaces`, `.fullScreenAuxiliary`, floating level, no key/main activation; exact labels `双手联动（左手 Hold 锁定）` and `显示透明 HUD`; absence of old helper-hand copy; all new source files registered in the Xcode Sources phase.

- [ ] **Step 2: Run v14 and confirm RED**

Run: `xcrun swift scripts/v14_bimanual_latch_hud_smoke_test.swift`

- [ ] **Step 3: Implement `GestureHUDView`**

Compact one/two-line SwiftUI layout with translucent material. Candidate shows Hold progress; latched shows lock + action + `Left: HOLD` + `Right: FREE`. Idle is subtle and auto-hides after a short delay.

- [ ] **Step 4: Implement `GestureHUDWindowController`**

Borderless non-activating `NSPanel`; transparent outer background; mouse passthrough; floating window level; all-Spaces and full-screen auxiliary collection behavior; top-center placement on the active/main screen. Main-thread-only window mutation.

- [ ] **Step 5: Add HUD setting/lifecycle in `AppController`**

Add `@Published var hudEnabled`, persisted at `gesture.hudEnabled.v1`, default `true`. Show/update only while running and enabled. Stop/error/disable hides HUD but never stops gesture processing just because HUD is disabled.

- [ ] **Step 6: Update `MenuBarPanel` copy and status**

Replace old clutch/right-click guide with right-hand primary + left Pinch Hold 300 ms guidance; add HUD toggle; preview status shows Hold candidate/Locked rather than clutch state.

- [ ] **Step 7: Register sources in `project.pbxproj`**

Add `BimanualLatchCoordinator.swift`, `GestureHUDView.swift`, and `GestureHUDWindowController.swift` to PBXFileReference, PBXBuildFile, Sources group, and Sources build phase. Do not alter deployment target or version settings.

- [ ] **Step 8: Verify GREEN**

```bash
xcrun swift scripts/v14_bimanual_latch_hud_smoke_test.swift
xcodebuild -project GestureControl.xcodeproj -scheme GestureControl -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add GestureControl/UI/GestureHUDView.swift GestureControl/UI/GestureHUDWindowController.swift GestureControl/AppController.swift GestureControl/UI/MenuBarPanel.swift GestureControl.xcodeproj/project.pbxproj scripts/v14_bimanual_latch_hud_smoke_test.swift
git commit -m "feat: add transparent gesture HUD"
```

---

### Task 5: Full regression and CI-equivalent verification

**Files:**
- Modify only if verification reveals a feature-related regression.

**Interfaces:**
- Final integration gate; no new API.

- [ ] **Step 1: Run every smoke test exactly as CI does**

```bash
set -euo pipefail
for test in scripts/*_smoke_test.swift; do
  xcrun swift "$test"
done
```

Expected: all PASS.

- [ ] **Step 2: Validate scripts and plist**

```bash
bash -n build_release.sh install_local.sh
plutil -lint GestureControl/Info.plist
```

Expected: PASS.

- [ ] **Step 3: Run CI-equivalent Debug build**

```bash
xcodebuild \
  -project GestureControl.xcodeproj \
  -scheme GestureControl \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/GestureControlDerivedData \
  -jobs 2 \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run CI-equivalent Release clean build**

```bash
xcodebuild \
  -project GestureControl.xcodeproj \
  -scheme GestureControl \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/GestureControlDerivedData \
  -jobs 2 \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  clean build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Manual hardware acceptance**

Verify on a Mac with camera/input permission:
- right-hand downward scroll → left Pinch Hold 300 ms → scrolling continues while right hand changes pose → left release stops;
- right-hand pointer/click remains usable during scroll latch;
- drag latch never leaves mouse down after release or Stop;
- left-hand loss >250 ms stops latch;
- HUD does not capture clicks, works across normal/full-screen Spaces, and its toggle hides only the HUD.

- [ ] **Step 6: Commit only if verification required fixes**

Use a focused `fix:` commit describing the regression corrected.
