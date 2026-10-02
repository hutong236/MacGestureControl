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
- Scroll latch emits at `60 Hz`; each axis must stay within the existing engine safety envelope of `±22` pixels per source tick equivalent.
- Zoom latch repeat interval must not be faster than the existing `0.030 s` zoom pulse limit.
- Scroll, drag, and enabled zoom are latchable. Clicks, page actions, right-click, Back/Forward, Mission Control/App Exposé/Space switching are not.
- Old `辅助手张开 → 离合` and `辅助手捏合 → 右键` behavior is superseded by this design.
- Single-hand trackpad behavior and page mode must continue to work.
- HUD is enabled by default, independently disableable, transparent, non-activating, and click-through.
- Every stop/error/reset/mode-switch path must release any latched drag and stop repeating scroll/zoom output.

## Review Focus

1. **Camera mirroring / hand identity:** Vision ordering or mirrored screen position must not swap left/right roles; unknown chirality must never arm Hold. Covered in Task 1 smoke checks and build verification.
2. **Stale action reuse:** pinching after a scroll/zoom has already ended must not resurrect an old action older than 200 ms. Covered in Task 2.
3. **Lifecycle races:** stop, camera error, mode switch, disabling bimanual mode, and repeated reset calls must never leave a timer running or mouse button down. Covered in Tasks 2 and 3.
4. **Concurrent right-hand use:** a latched scroll must continue while the right hand returns to pointer/click behavior; a latched drag must suppress conflicting clicks/system gestures. Covered in Tasks 2 and 3.
5. **HUD interference:** the HUD must not become key/main, intercept mouse events, or disappear in another Space/full-screen context; disabling HUD must not disable gesture processing. Covered in Task 4 source invariants and Debug/Release builds.

---

### Task 1: Add handedness and shared bimanual/HUD models

**Files:**
- Modify: `GestureControl/Models/GestureModels.swift`
- Modify: `GestureControl/Vision/HandPoseDetector.swift`
- Create: `scripts/v14_bimanual_latch_hud_smoke_test.swift`

**Interfaces:**
- Produces: `enum Handedness { case left, right, unknown }`
- Produces: `enum LatchedAction: Equatable`
- Produces: `enum LeftHoldState: Equatable`
- Produces: `enum GestureHUDMode: Equatable`
- Produces: `struct GestureHUDState: Equatable`
- `HandPoseResult` gains `let handedness: Handedness`.

- [ ] **Step 1: Write the failing v14 smoke assertions for model and handedness requirements**

The smoke file must source-check that `Handedness`, `LeftHoldState`, `GestureHUDState`, and `HandPoseResult.handedness` exist, and model unknown-handedness as non-lockable.

- [ ] **Step 2: Run the new smoke test and verify it fails**

Run: `xcrun swift scripts/v14_bimanual_latch_hud_smoke_test.swift`

Expected: FAIL because the new models/handedness field do not exist.

- [ ] **Step 3: Add the shared feature models**

In `GestureModels.swift`, add exact public-in-module types:

```swift
enum Handedness: Equatable { case left, right, unknown }
enum LatchedAction: Equatable { case scroll(deltaX: Double, deltaY: Double); case drag; case zoom(step: Int) }
enum LeftHoldState: Equatable { case idle; case candidate(progress: Double); case latched(LatchedAction) }
enum GestureHUDMode: Equatable { case idle, active, holdCandidate, latched }
struct GestureHUDState: Equatable { ... }
```

`GestureHUDState` fields are `mode`, `leftHandText`, `rightHandText`, `actionText`, `holdProgress`, and `isLocked` exactly as defined in the spec.

- [ ] **Step 4: Add Vision chirality to `HandPoseResult`**

Map `VNHumanHandPoseObservation.chirality` to `Handedness`; if chirality is unavailable/unknown, return `.unknown`. Do not infer handedness from x-position.

- [ ] **Step 5: Run smoke test and Debug build**

Run:

```bash
xcrun swift scripts/v14_bimanual_latch_hud_smoke_test.swift
xcodebuild -project GestureControl.xcodeproj -scheme GestureControl -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Expected: both PASS.

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
- Consumes: `TrackpadInteraction`, `LatchedAction` from Task 1.
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
    func latchCurrentAction(timestamp: TimeInterval, zoomEnabled: Bool) -> Bool
    func release(timestamp: TimeInterval)
    func reset()
    var latchedAction: LatchedAction? { get }
}
```

- [ ] **Step 1: Extend v14 smoke coverage with latch lifecycle cases**

Add cases for: fresh scroll latches; >200 ms scroll does not; drag keeps button down and releases on reset; zoom requires `zoomEnabled`; discrete/system interactions do not latch; release/reset are idempotent; repeating scroll uses 60 Hz semantics; scroll deltas are clamped to the existing `±22` source envelope.

- [ ] **Step 2: Run the v14 smoke test and verify failure**

Run: `xcrun swift scripts/v14_bimanual_latch_hud_smoke_test.swift`

Expected: FAIL because coordinator source/API is missing.

- [ ] **Step 3: Implement coordinator state and stale-action arbitration**

Use one private serial queue or lock for coordinator state. Record timestamps for the latest scroll, left-button transition, zoom step, and interaction. `latchCurrentAction` must choose only a currently relevant latchable action with age `<= 0.20 s`; it must never fall back to an older unrelated action.

- [ ] **Step 4: Implement sustained output**

Scroll: use a `DispatchSourceTimer` at `60 Hz`; because source scroll callbacks come from the 120 Hz engine, emit `2 ×` the captured per-tick delta at 60 Hz, clamped so the equivalent speed never exceeds the engine's `±22` per 120 Hz tick envelope.

Zoom: use a repeating timer with interval `>= 0.030 s` and emit one signed zoom step per pulse. Drag: no timer; keep logical left button down and suppress an observed engine mouse-up while latched.

- [ ] **Step 5: Verify coordinator invariants**

Run:

```bash
xcrun swift scripts/v14_bimanual_latch_hud_smoke_test.swift
xcrun swift scripts/v131_event_lifecycle_50x_smoke_test.swift
```

Expected: PASS.

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
- Modify: `scripts/v14_bimanual_latch_hud_smoke_test.swift`

**Interfaces:**
- Consumes: handedness/models from Task 1 and coordinator from Task 2.
- Produces: `@Published private(set) var leftHoldState: LeftHoldState`
- Produces: `@Published private(set) var hudState: GestureHUDState`
- Keeps persisted key `trackpad.bimanualAssistEnabled.v1` for migration compatibility.

- [ ] **Step 1: Add failing smoke assertions for the new left-hand Hold lifecycle**

Cover exact timings: 100–250 ms pinch does not latch; 300 ms does; release requires 80 ms above `0.48`; short left-hand dropout does not flap; 250 ms continuous loss releases; unknown handedness does not arm; old open-palm clutch and secondary-pinch right-click mapping are absent.

- [ ] **Step 2: Run v14 and verify failure**

Run: `xcrun swift scripts/v14_bimanual_latch_hud_smoke_test.swift`

Expected: FAIL against current V1.2 auxiliary-hand code.

- [ ] **Step 3: Replace role assignment**

When both confident physical hands are present: choose `.right` as the primary pose and `.left` as the modifier pose. Preserve the existing temporal continuity fallback only for same-handedness reacquisition and single-hand operation; a lone `.unknown` or `.left` hand must not suddenly become the right-hand primary if a recent right-hand track exists.

- [ ] **Step 4: Replace `updateBimanualAssist` with left-pinch Hold state**

Implement candidate/latch/release/dropout using the exact global thresholds. Candidate state is allowed only when `BimanualLatchCoordinator.latchCurrentAction(...)` would have a current latchable action. Releasing/losing the left hand calls coordinator release and returns to `.idle`.

- [ ] **Step 5: Route engine outputs through the coordinator**

- Pointer delta stays direct to `TrackpadController`.
- Scroll delta calls `observeScroll`; coordinator forwards live scroll when not latched and owns repeated scroll while latched.
- Left-button changes call `observeLeftButton`; coordinator suppresses mouse-up during a latched drag and always forwards final release.
- Zoom steps call `observeZoomStep`; coordinator forwards live zoom and repeats only while latched.
- System swipe handler returns without posting if a conflicting latch is active.

- [ ] **Step 6: Remove the obsolete external clutch path**

Remove `setExternalClutch(...)` and `externalClutchActive` from `TrackpadGestureEngine` once no caller remains. Keep all single-hand filtering, scroll retraction, continuity, and zoom arbitration logic unchanged.

- [ ] **Step 7: Make lifecycle cleanup exhaustive**

Before `trackpadEngine.reset()` / `trackpad.resetMotionState()` on stop, camera error, mode change, bimanual disable, or recognition reset: call `latchCoordinator.reset()` and force `trackpad.setLeftButton(down: false)`. Repeated calls must be harmless.

- [ ] **Step 8: Run focused regression tests**

Run:

```bash
xcrun swift scripts/v14_bimanual_latch_hud_smoke_test.swift
xcrun swift scripts/v12_realtime_intent_smoke_test.swift
xcrun swift scripts/v131_event_lifecycle_50x_smoke_test.swift
xcrun swift scripts/v132_selection_page_50x_smoke_test.swift
```

Expected: PASS. If `v12_realtime_intent_smoke_test.swift` still asserts the retired clutch behavior, replace only that obsolete section with a source invariant confirming it is intentionally removed; retain the scroll-retraction/identity coverage.

- [ ] **Step 9: Commit**

```bash
git add GestureControl/AppController.swift GestureControl/Gesture/TrackpadGestureEngine.swift scripts/v12_realtime_intent_smoke_test.swift scripts/v14_bimanual_latch_hud_smoke_test.swift
git commit -m "feat: replace bimanual clutch with left-hand hold latch"
```

---

### Task 4: Add transparent click-through HUD

**Files:**
- Create: `GestureControl/UI/GestureHUDView.swift`
- Create: `GestureControl/UI/GestureHUDWindowController.swift`
- Modify: `GestureControl/AppController.swift`
- Modify: `scripts/v14_bimanual_latch_hud_smoke_test.swift`

**Interfaces:**
- Consumes: `GestureHUDState` from Task 1.
- Produces:

```swift
final class GestureHUDWindowController {
    func update(state: GestureHUDState)
    func setEnabled(_ enabled: Bool)
    func setRunning(_ running: Bool)
    func hide()
}
```

- [ ] **Step 1: Add failing HUD source-invariant tests**

Require: transparent background, `isOpaque = false`, `ignoresMouseEvents = true`, non-activating panel style, `.canJoinAllSpaces`, `.fullScreenAuxiliary`, floating level, no key/main activation, and independent enable/disable state.

- [ ] **Step 2: Run v14 and verify failure**

Run: `xcrun swift scripts/v14_bimanual_latch_hud_smoke_test.swift`

Expected: FAIL because HUD files do not exist.

- [ ] **Step 3: Implement `GestureHUDView`**

Render a compact one/two-line SwiftUI HUD using `ultraThinMaterial` or a very light translucent background. Candidate mode shows progress; latched mode shows a lock symbol and `Left: HOLD / Right: FREE`; idle content is subtle and eligible for auto-hide.

- [ ] **Step 4: Implement `GestureHUDWindowController`**

Use a borderless non-activating `NSPanel`, transparent outer background, mouse passthrough, floating level, all-Spaces/full-screen collection behavior, and top-center placement on the active/main screen. All window mutations occur on the main queue.

- [ ] **Step 5: Integrate HUD lifecycle into `AppController`**

Add persisted `@Published var hudEnabled` with key `gesture.hudEnabled.v1`, default `true`. Update HUD on main when interaction/hold/latch state changes. `stop`, error, and disabled setting hide the panel without affecting processing.

- [ ] **Step 6: Run v14 and Debug build**

Run:

```bash
xcrun swift scripts/v14_bimanual_latch_hud_smoke_test.swift
xcodebuild -project GestureControl.xcodeproj -scheme GestureControl -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Expected: PASS after project file registration in Task 5; before Task 5, a compile failure for missing source registration is acceptable and is the handoff signal to Task 5.

- [ ] **Step 7: Commit**

Commit after Task 5 registers the new files so the branch does not contain a knowingly unbuildable intermediate commit.

---

### Task 5: Update menu UI and Xcode project registration

**Files:**
- Modify: `GestureControl/UI/MenuBarPanel.swift`
- Modify: `GestureControl.xcodeproj/project.pbxproj`
- Modify: `scripts/v14_bimanual_latch_hud_smoke_test.swift`

**Interfaces:**
- Consumes: `controller.leftHoldState`, `controller.hudEnabled`, `controller.hudState`.

- [ ] **Step 1: Add failing UI copy/project-registration checks**

Require the exact setting labels `双手联动（左手 Hold 锁定）` and `显示透明 HUD`; reject old text `双手辅助（离合 + 右键）`, `辅助手张开`, and `辅助手捏合`; require all new Swift files to appear in the Sources build phase.

- [ ] **Step 2: Run v14 and verify failure**

Run: `xcrun swift scripts/v14_bimanual_latch_hud_smoke_test.swift`

- [ ] **Step 3: Update MenuBarPanel**

Replace old helper-hand guide rows with: right hand = main operation; left thumb-index pinch hold 300 ms = lock current continuous action; left release = unlock; latchable operations = scroll/drag/zoom. Add the HUD toggle. Replace preview overlay clutch text with left Hold/Locked state.

- [ ] **Step 4: Register new Swift sources in `project.pbxproj`**

Add `BimanualLatchCoordinator.swift`, `GestureHUDView.swift`, and `GestureHUDWindowController.swift` to PBXFileReference, PBXBuildFile, Sources group, and Sources build phase. Keep deployment/version settings unchanged.

- [ ] **Step 5: Run smoke test and Debug build**

Run:

```bash
xcrun swift scripts/v14_bimanual_latch_hud_smoke_test.swift
xcodebuild -project GestureControl.xcodeproj -scheme GestureControl -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Expected: PASS.

- [ ] **Step 6: Commit Tasks 4–5 together**

```bash
git add GestureControl/UI/GestureHUDView.swift GestureControl/UI/GestureHUDWindowController.swift GestureControl/AppController.swift GestureControl/UI/MenuBarPanel.swift GestureControl.xcodeproj/project.pbxproj scripts/v14_bimanual_latch_hud_smoke_test.swift
git commit -m "feat: add transparent gesture HUD"
```

---

### Task 6: Full regression and CI-equivalent verification

**Files:**
- Modify only if verification exposes a feature-related regression.

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

- [ ] **Step 2: Validate shell/plist invariants**

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

- [ ] **Step 5: Manual acceptance pass on macOS hardware**

Verify: right-hand downward scroll → left pinch hold for 300 ms → continuous down-scroll persists while right hand changes pose → left release stops; pointer remains usable during scroll latch; drag latch never leaves mouse down after release/Stop; HUD is click-through and visible in normal/full-screen Spaces; HUD toggle hides only the HUD.

- [ ] **Step 6: Final commit if verification required fixes**

Use a focused `fix:` commit describing only the regression corrected.
