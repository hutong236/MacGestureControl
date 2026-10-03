# Bimanual Pinch-Hold Latch + Transparent HUD Design

Date: 2026-10-02
Status: Design approved in conversation; implementation pending written-spec review
Target branch: `feature/bimanual-latch-transparent-hud`

## 1. Goal

Add a two-hand interaction model in which the physical left hand acts as a modifier/lock hand and the physical right hand remains the primary operation hand.

The core interaction is:

1. The right hand starts a continuous operation such as scroll, drag, or zoom.
2. The left hand performs a thumb-index pinch and keeps it closed for 300 ms.
3. The app latches the current continuous operation.
4. The latched operation continues independently of the right-hand pose.
5. The right hand is free to perform compatible follow-up operations.
6. Releasing the left pinch ends the latch.

A transparent, click-through HUD shows the current action, left/right hand state, and whether the operation is active, becoming latched, or locked.

When this design conflicts with existing bimanual behavior, this design takes precedence.

## 2. Existing Behavior Being Replaced

Current V1.2 bimanual assistance uses a secondary hand with two behaviors:

- open palm = external clutch / recenter, which freezes pointer and scroll output;
- secondary-hand pinch = right-click.

Those semantics conflict directly with left-hand pinch-hold as the lock gesture. They are therefore superseded when bimanual assist is enabled under this design.

The existing single-hand motion engine, pointer smoothing, scroll filtering, drag recognition, zoom arbitration, recovery fusion, retraction suppression, and page mode behavior remain intact unless a specific latch rule below requires otherwise.

## 3. Architectural Choice

### Considered approaches

#### A. Put latching directly inside `TrackpadGestureEngine`

Pros:
- direct access to scroll velocity, drag state, and zoom intent;
- one state machine owns everything.

Cons:
- `TrackpadGestureEngine.swift` is already large and timing-sensitive;
- higher regression risk to the carefully tuned single-hand tracking behavior;
- harder to test latch behavior independently from motion estimation.

#### B. Implement all latch behavior in `AppController`

Pros:
- fewer new files;
- easy access to hand assignment and published UI state.

Cons:
- `AppController.swift` is already large;
- timers, continuous output, hand state, and UI state would become tightly coupled;
- harder to isolate and test.

#### C. Hybrid coordinator layer — selected

Keep the existing `TrackpadGestureEngine` responsible for recognizing and smoothing right-hand interaction, while introducing a dedicated `BimanualLatchCoordinator` between engine callbacks and system output.

Responsibilities:
- `HandPoseDetector`: expose handedness from Vision chirality.
- `AppController`: assign physical left/right roles, detect left pinch-hold lifecycle, route right-hand samples, and publish HUD state.
- `BimanualLatchCoordinator`: capture, sustain, update, and release latchable continuous actions.
- `GestureHUDWindowController`: display transparent click-through HUD.
- `TrackpadGestureEngine`: remain the source of single-hand pointer/scroll/drag/zoom intent; only minimal hooks may be added if an action snapshot is otherwise unavailable.

This preserves existing tuned motion behavior while giving the new bimanual feature a clear boundary.

## 4. Hand Roles and Identity

### Physical handedness

`HandPoseResult` will include a handedness value derived from `VNHumanHandPoseObservation.chirality`.

```swift
enum Handedness: Equatable {
    case left
    case right
    case unknown
}
```

Rules:

- When both physical hands are confidently identified:
  - right = primary operation hand;
  - left = hold/modifier hand.
- With only one detected hand, existing single-hand control behavior remains available for backward compatibility.
- A latch can only arm when a distinct physical left hand is present. Unknown-handedness observations must not guess and trigger a latch.
- Existing temporal hand tracking can remain as continuity support, but physical chirality becomes the role authority when available.

This avoids relying on screen position, camera mirroring, or Vision result ordering to decide which hand is the modifier.

## 5. Left-Hand Pinch-Hold State Machine

Introduce a state concept equivalent to:

```swift
enum LeftHoldState: Equatable {
    case idle
    case candidate(progress: Double)
    case latched(LatchedAction)
}
```

### Detection thresholds

Use palm-normalized thumb-index `pinchRatio` already produced by the detector.

Fixed initial thresholds:

- arm/open threshold: `>= 0.58`;
- pinch/closed threshold: `<= 0.32`;
- hold duration: `0.30 s`;
- release threshold: `>= 0.48`;
- release debounce: `0.08 s`;
- missing-left-hand safety release: `0.25 s` of sustained loss.

These values reuse the scale and ranges already proven by the previous secondary-pinch logic, while changing the meaning from an immediate right-click to a deliberate hold gesture.

### Lifecycle

1. **Idle** — no valid left pinch.
2. **Candidate** — left pinch is closed while a latchable right-hand action is active; HUD shows locking progress.
3. **Latched** — after 300 ms, snapshot the current latchable action and sustain it.
4. **Release** — left pinch opens past the release threshold for 80 ms; stop the sustained action.
5. **Safety cancel** — left hand is continuously missing for 250 ms, or an app lifecycle reset occurs; cancel the latch.

A short pinch that does not reach the hold duration has no bimanual system action under this design. The old secondary-pinch right-click action is removed from the bimanual mapping.

## 6. Latchable Actions

Only continuous operations can be latched. A continuous action snapshot must be no older than 200 ms at lock time; stale observations are not latchable.

### 6.1 Scroll

Snapshot:

```swift
struct LatchedScroll {
    var deltaX: Double
    var deltaY: Double
    var intensity: Double
}
```

Behavior:

- Capture the recent filtered scroll direction and magnitude at lock time.
- Continue emitting scroll events at a 60 Hz cadence independent of subsequent right-hand pose.
- Preserve natural-scrolling semantics already applied by the existing engine/output path.
- Clamp speed to safe limits so a noisy final frame cannot produce runaway scrolling.
- If the right hand later produces a newly confirmed scroll intent while scroll is already latched, update the latched vector only after the existing scroll intent engine confirms that new direction; otherwise preserve the locked vector.
- Right-hand pointer and compatible click interactions may continue while scroll remains latched.

Primary target use case:

`right-hand scroll down → left pinch hold → page keeps scrolling down → right hand becomes free → left release stops scrolling`.

### 6.2 Drag

Behavior:

- If the right hand is in an active drag when the left hold locks, keep the left mouse button logically down.
- Right-hand pointer movement remains available so the object can continue moving.
- Other actions that conflict with an already-held left mouse button are suppressed until the latch is released.
- Release of the left pinch must always release the left mouse button.
- Stop, error cleanup, camera loss, mode change, or permission-related reset must also release the button.

### 6.3 Zoom

Behavior:

- Only available when the existing experimental two-finger zoom feature is enabled.
- Capture the most recent confirmed zoom direction.
- Sustain zoom with a bounded repeating pulse cadence; never exceed the existing zoom pulse frequency limit.
- Release stops the zoom stream immediately.

### 6.4 Non-latchable actions

Never latch:

- click / double click;
- right-click;
- page-mode key actions;
- Back / Forward;
- Mission Control / App Exposé / Space switching;
- other one-shot keyboard/system commands.

Attempting a left hold while the current right-hand action is non-latchable leaves the hold state idle and must not replay the last old continuous action.

## 7. Concurrent Right-Hand Behavior While Latched

Compatibility rules:

| Latched action | Right-hand actions allowed while latched |
| --- | --- |
| Scroll | pointer, click, compatible drag initiation, confirmed scroll adjustment |
| Zoom | pointer, click, confirmed zoom adjustment |
| Drag | pointer movement only; conflicting clicks/system actions suppressed |

System-level swipes are not combined with a latch in the first implementation because they are discrete OS navigation actions and can conflict with continuous synthetic input.

## 8. Latch Coordinator

Create `GestureControl/Gesture/BimanualLatchCoordinator.swift`.

Conceptual API:

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
    func latchCurrentAction(timestamp: TimeInterval) -> Bool
    func release(timestamp: TimeInterval)
    func reset()
}
```

Implementation notes:

- Serialize coordinator state to avoid races between Vision callbacks and repeating output timers.
- Scroll latching uses a 60 Hz sustained-output timer.
- Zoom latching uses a bounded pulse timer consistent with current zoom rate limits.
- Do not synthesize latch state from stale data; require an action sample no older than 200 ms at latch time.
- Capture action snapshots rather than replaying raw old frames.
- Make release and reset idempotent.

## 9. Transparent HUD

Create:

- `GestureControl/UI/GestureHUDView.swift`
- `GestureControl/UI/GestureHUDWindowController.swift`

### Window behavior

Use a non-activating, borderless transparent `NSPanel` or `NSWindow`:

- `isOpaque = false`;
- `backgroundColor = .clear`;
- no title bar;
- `ignoresMouseEvents = true`;
- must not become key/main window;
- floating above ordinary app windows;
- joins all Spaces;
- supports full-screen auxiliary display;
- centered near the top of the active display;
- click-through so it never blocks normal mouse interaction.

### Visual style

- transparent outer window;
- compact SwiftUI content using `ultraThinMaterial` or a very light translucent backing surface;
- rounded corners;
- high-contrast text/icons while keeping the panel visually lightweight;
- no large opaque card.

### HUD state model

```swift
enum GestureHUDMode: Equatable {
    case idle
    case active
    case holdCandidate
    case latched
}

struct GestureHUDState: Equatable {
    var mode: GestureHUDMode
    var leftHandText: String
    var rightHandText: String
    var actionText: String
    var holdProgress: Double?
    var isLocked: Bool
}
```

Examples:

Active:

`Right: Scroll Down · Left: Ready`

Hold candidate:

`Left: HOLD 72% · Locking Scroll Down`

Latched:

`🔒 Scroll Down · Left: HOLD · Right: FREE`

Release:

`Scroll Released`

### Visibility

- Add a persisted `显示透明 HUD` setting and default it to enabled.
- HUD is shown while gesture control is running and the setting is enabled.
- Active/candidate/latched states are clearly visible.
- Idle state auto-hides after a short delay rather than occupying the screen continuously.
- Stop/error state hides the HUD after reset.

## 10. AppController Integration

`AppController` remains the orchestration layer.

Changes:

1. Replace old secondary open-palm clutch / secondary pinch-right-click state with left-hand pinch-hold state.
2. Route physical right-hand observations to the existing `TrackpadGestureEngine` when both hands are present.
3. Keep single-hand fallback behavior for compatibility.
4. Route existing engine output callbacks through `BimanualLatchCoordinator` where needed.
5. Keep pointer output direct unless a latched drag rule requires left-button arbitration.
6. Publish a unified `GestureHUDState` on the main queue.
7. Own/show/hide `GestureHUDWindowController` according to run state and HUD setting.
8. On any reset path, release the latch before resetting trackpad state.

Lifecycle cleanup must cover:

- user Stop;
- camera error;
- control-mode switch;
- bimanual feature disabled;
- app termination/relaunch path;
- lost processing generation;
- permission-related shutdown.

## 11. Settings/UI Changes

Update the trackpad guide text.

Remove/replace:

- `辅助手张开 → 离合`;
- `辅助手捏合 → 右键`;
- `双手辅助（离合 + 右键）` wording.

New wording explains:

- right hand = primary operation;
- left thumb-index pinch and hold 300 ms = lock current continuous action;
- release left pinch = stop lock;
- latchable: scroll / drag / zoom;
- transparent HUD shows current state.

Required setting labels:

- `双手联动（左手 Hold 锁定）`
- `显示透明 HUD`

The existing `bimanualAssistEnabled` persisted key is retained for migration compatibility even though its display semantics change. Add a separate persisted HUD-enabled key that defaults to true.

## 12. Safety and Failure Handling

Critical invariants:

1. There must never be a latched action when gesture processing is stopped.
2. A latched drag must never leave the left mouse button down after release/reset/error.
3. A lost left hand cannot cause indefinite scroll/zoom; 250 ms sustained loss triggers release.
4. Short left pinch noise must not latch an action.
5. Unknown hand chirality must not be treated as a definite left hand for locking.
6. Non-latchable right-hand actions must not inherit the previously latched continuous action.
7. HUD failure must not block gesture processing or pointer events.

## 13. Testing Strategy

### Unit/smoke coverage

Add a dedicated bimanual latch smoke test with at least these cases:

1. scroll becomes latched after 300 ms left pinch hold;
2. 100–250 ms pinch does not latch;
3. 80 ms release debounce ends scroll;
4. left-hand dropout shorter than 250 ms does not flap state;
5. sustained left-hand dropout of 250 ms releases latch;
6. action samples older than 200 ms cannot be latched;
7. latched drag guarantees mouse-up on release/reset;
8. zoom cannot latch when zoom feature is disabled;
9. discrete interactions cannot latch;
10. reset is idempotent;
11. switching modes clears latch;
12. disabling bimanual mode clears latch;
13. right-hand pointer output continues during a latched scroll;
14. old open-palm clutch no longer activates;
15. old left/secondary pinch no longer emits right-click;
16. HUD window is configured click-through and non-activating;
17. HUD disabled setting prevents HUD presentation without disabling gesture processing.

### Repository checks

Run existing smoke tests, especially:

- repository invariants;
- trackpad motion;
- V1.0 continuity;
- V1.1 recovery fusion;
- V1.1.1 zoom/scroll arbitration;
- V1.1.2 scroll retraction;
- V1.2 realtime intent;
- V1.3.1 event lifecycle 50x;
- V1.3.2 selection/page 50x.

### Build verification

Run the same `xcodebuild` command used by CI for the macOS target and confirm no compile/link errors after adding new source files to the Xcode project.

## 14. Files Expected to Change

Likely additions:

- `GestureControl/Gesture/BimanualLatchCoordinator.swift`
- `GestureControl/UI/GestureHUDView.swift`
- `GestureControl/UI/GestureHUDWindowController.swift`
- `scripts/v14_bimanual_latch_hud_smoke_test.swift`

Likely modifications:

- `GestureControl/Vision/HandPoseDetector.swift`
- `GestureControl/Models/GestureModels.swift`
- `GestureControl/AppController.swift`
- `GestureControl/UI/MenuBarPanel.swift`
- `GestureControl.xcodeproj/project.pbxproj`
- repository invariant / test scripts if their source-file expectations require updates.

Avoid unrelated refactoring.

## 15. Acceptance Criteria

The feature is complete when all of the following are true:

- With both hands visible, physical right hand remains the main operator and physical left hand is the Hold modifier.
- Right-hand downward scrolling followed by a 300 ms left pinch hold keeps the page scrolling after the right hand changes pose.
- Left pinch release stops the sustained scroll after the 80 ms release debounce.
- Sustained left-hand tracking loss cannot keep scroll/zoom running beyond the 250 ms safety window.
- Scroll, drag, and enabled zoom are latchable; discrete/system actions are not.
- Old open-palm clutch and secondary-pinch right-click no longer override the new mapping.
- HUD transparently displays current left/right/action/lock state without stealing focus or blocking clicks.
- The HUD setting exists, defaults on, and can disable HUD presentation independently of gesture processing.
- HUD works across normal Spaces and full-screen apps as permitted by macOS windowing behavior.
- Stop/error/mode-change paths cannot leave continuous input or a mouse button stuck.
- Existing single-hand and page-mode regression suites continue to pass.
- macOS build passes in CI-equivalent configuration.
