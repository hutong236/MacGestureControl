import Foundation

/// 将摄像头中的单手姿态转换成“空中触控板”语义。
///
/// V1.2 Real-time Intent Engine：在 Continuity Fusion 基础上进一步减少“回收即反向”的误差，并加入双手离合辅助。
/// - 单帧/短时 Vision 丢失不会立即 reset，而是保持运动状态并渐进降速；
/// - 置信度从硬阈值改成软权重，低置信度样本仍可参与连续追踪；
/// - fingerPattern 与位置追踪解耦：分类暂时缺失时继续沿用上一种已确认交互；
/// - 真正连续丢手超过 hold window 后才结束 tracking / drag / scroll；
/// - V1.1 增加恢复融合与语义模式迟滞，避免丢帧恢复/手指数抖动时速度和模式突然跳变；
/// - V1.2 将滚动回收改为“单向笔画锁 + 宽松轴向回中重武装”，不要求沿原路径精确返回；
/// - V1.2 支持辅助手离合：辅助手张开时冻结输出并持续重定位主手，松开后无跳变恢复；
/// - 暴露 Continuity、丢帧数、预测续接时长和恢复帧数，便于实机诊断。
final class TrackpadGestureEngine {
    struct Configuration: Equatable {
        // V1.0: 这是“硬底线”，不再作为 0.42 的二值 gate。
        // 0.18~0.70 之间由 soft confidence 连续降低观测权重。
        var minimumConfidence: Double = 0.18
        var softConfidenceFullTrust: Double = 0.70
        var continuityHoldDuration: Double = 0.20
        var continuityFadeStart: Double = 0.055
        var pointerPoseGrace: Double = 0.18
        var scrollPoseGrace: Double = 0.12
        // V1.1: 模式切换至少连续确认两帧，避免 pointer/scroll 因 fingerPattern 一帧抖动来回跳。
        var semanticSwitchConfirmFrames: Int = 2
        // V1.1: Vision 恢复后的前几帧降低新观测接管力度，让预测轨迹平滑“接回”真实关键点。
        var recoveryBlendFrames: Int = 3
        var recoveryTrustFloor: Double = 0.38
        var pointerSensitivity: Double = 1.0
        var scrollSensitivity: Double = 1.0
        var inertia: Double = 0.72
        var responsiveness: Double = 0.74
        var precisionAssist: Double = 0.68
        var naturalScrolling: Bool = true
        // V1.1.1: 键盘模拟的双指缩放默认关闭。它不是系统原生 magnify event，
        // 且 Vision 的指间距抖动可能与双指滚动冲突。用户显式开启后才参与判定。
        var twoFingerZoomEnabled: Bool = false

        // V0.7 adaptive tracking. These stay automatic by default instead of exposing more knobs.
        var nominalInputFPS: Double = 30.0
        var adaptiveTiming: Bool = true
        var directionContinuity: Double = 0.72
        var approachAssist: Double = 0.68

        // V0.8 trajectory / intent prediction.
        var statePredictionStrength: Double = 0.76
        var decelerationBrake: Double = 0.72
        var clickPreparationAssist: Double = 0.78
        var trajectoryWindow: Double = 0.16

        // V0.9 low-latency state estimation / rebound suppression.
        var alphaBetaStrength: Double = 0.72
        var processingLatencyCompensation: Double = 0.68
        var postClickReboundHold: Double = 0.085

        var pointerDeadZone: Double = 0.00120
        var pointerJumpLimit: Double = 0.16
        var pointerSampleTimeout: Double = 0.082
        var nominalPalmScale: Double = 0.14
        /// 持久化的个人舒适工作距离手掌尺度；nil 时自动学习。
        var personalPalmScale: Double? = nil
        var minimumDistanceGain: Double = 0.65
        var maximumDistanceGain: Double = 1.75
        var calibrationRequiredStableSamples: Int = 42

        var pinchStartRatio: Double = 0.34
        var pinchReleaseRatio: Double = 0.48
        var pinchArmRatio: Double = 0.56
        var pinchDeepPressRatio: Double = 0.27
        var pinchMinimumClosingSpeed: Double = 0.18
        var pinchMaximumArmingPointerSpeed: Double = 0.42
        // At ~30FPS, these values require roughly two consistent samples while keeping click latency low.
        var pinchPressDebounce: Double = 0.030
        var pinchReleaseDebounce: Double = 0.038
        var pinchPointerFreeze: Double = 0.050

        // V0.5 precision clutch / adaptive noise model.
        var precisionAnchorDelay: Double = 0.080
        var precisionAnchorRadius: Double = 0.0032
        var precisionReleaseRadius: Double = 0.0062
        var pointerNoiseFloorMin: Double = 0.00055
        var pointerNoiseFloorMax: Double = 0.00320

        var scrollDeadZone: Double = 0.00105
        var scrollAxisLockRatio: Double = 1.60
        var scrollStartThreshold: Double = 0.0042
        var scrollRampDuration: Double = 0.070
        var scrollReleaseWindow: Double = 0.14
        var scrollAccelerationStrength: Double = 0.72
        var scrollContactDebounce: Double = 0.030
        var scrollReleaseDebounce: Double = 0.042

        // V1.1.2 scroll retraction suppression：一次明显滚动完成后，手回到起始位置的
        // 反向轨迹不应被当作新的反向滚动。停稳后自动重新武装；明确持续反向也可重新接管。
        var scrollRetractionSuppressionEnabled: Bool = true
        var scrollRetractionArmTravel: Double = 0.010
        var scrollRetractionOppositeDelta: Double = 0.00065
        var scrollRetractionConfirmFrames: Int = 1
        var scrollRetractionNeutralSpeed: Double = 0.050
        var scrollRetractionNeutralHold: Double = 0.065
        // Retained for settings compatibility; V1.2 intentionally requires a short neutral pause
        // before a direction reversal instead of guessing whether a fast return is retraction.
        var scrollRetractionReverseTravel: Double = 0.011
        var scrollRetractionReverseConfirmFrames: Int = 3

        var zoomStepThreshold: Double = 0.050
        // V1.1.1 zoom/scroll arbitration：缩放要求双指中心基本静止，并连续同方向改变间距。
        var zoomCenterMovementLimit: Double = 0.010
        var zoomMaxCenterTravelBeforeLock: Double = 0.018
        var zoomMinimumSpanDelta: Double = 0.010
        var zoomIntentConfirmFrames: Int = 3
        var zoomPulseCooldown: Double = 0.030
    }

    var onPointerDelta: ((Double, Double) -> Void)?
    var onLeftButton: ((Bool) -> Void)?
    var onScrollDelta: ((Double, Double) -> Void)?
    var onSystemSwipe: ((GestureDirection) -> Void)?
    var onZoomStep: ((Int) -> Void)?
    var onInteractionChanged: ((TrackpadInteraction) -> Void)?
    /// progress 0...1；baseline 为完成后的个人 palm scale。
    var onCalibrationChanged: ((Double, Double?) -> Void)?
    /// inputFPS, stability(0...1), current distance compensation gain, Vision processing latency(s).
    var onTrackingTelemetry: ((Double, Double, Double, Double) -> Void)?
    /// 当前指针运动阶段，用于 UI 观测，也让上层知道系统是在移动还是准备点击。
    var onPointerMotionPhaseChanged: ((PointerMotionPhase) -> Void)?
    /// V0.9 双指滚动相位：接触 / 直接操控 / 惯性。
    var onScrollMotionPhaseChanged: ((ScrollMotionPhase) -> Void)?
    /// V1.0 continuity, cumulative dropped observations, current prediction-hold(s), last recovery frame count.
    var onContinuityTelemetry: ((Double, Int, Double, Int) -> Void)?

    private enum Mode: Equatable {
        case idle
        case pointer
        case drag
        case scroll
        case systemSwipe
    }

    private enum ScrollAxisLock {
        case none
        case horizontal
        case vertical
    }

    private let lock = NSLock()
    private var configuration = Configuration()
    private var lastSample: TrackpadSample?
    private var mode: Mode = .idle
    private var interaction: TrackpadInteraction = .idle

    // MARK: - Pointer / drag

    /// 像素/秒。由 Vision 样本更新，由 120Hz timer 积分成像素位移。
    private var pointerVelocityX = 0.0
    private var pointerVelocityY = 0.0
    private var pointerActive = false
    private var lastPointerSampleTime: TimeInterval = 0
    private var pointerStillSamples = 0
    private var lastRawPointerVelocityX = 0.0
    private var lastRawPointerVelocityY = 0.0
    private var smoothedPalmScale: Double?
    private var pointerNoiseFloor = 0.0010
    private var pointerAnchorX: Double?
    private var pointerAnchorY: Double?
    private var pointerAnchorCandidateSince: TimeInterval?
    private var pointerPrecisionLatched = false
    private var lastNormalizedPointerSpeed = 0.0

    // MARK: - V0.8 trajectory / motion phase

    private struct PointerKinematicSample {
        let timestamp: TimeInterval
        let vx: Double
        let vy: Double
        let normalizedSpeed: Double
    }
    private var pointerTrajectory: [PointerKinematicSample] = []
    private var pointerMotionPhase: PointerMotionPhase = .idle
    private var pointerPhaseCandidate: PointerMotionPhase?
    private var pointerPhaseCandidateSince: TimeInterval = 0
    private var pendingPointerPhase: PointerMotionPhase?
    private var lastPinchClosingSpeed = 0.0

    // V0.9 α-β pointer state. Position stays in Vision normalized coordinates;
    // velocity is normalized-units / second and is converted to pixels later.
    private struct PointerAlphaBetaState {
        var x: Double
        var y: Double
        var vx: Double
        var vy: Double
        var timestamp: TimeInterval
    }
    private var pointerAlphaBetaState: PointerAlphaBetaState?
    private var postClickReboundUntil: TimeInterval = 0
    private var lastExplicitPointerPoseTime: TimeInterval = -1
    private var lastExplicitTwoFingerPoseTime: TimeInterval = -1

    // MARK: - V0.7 adaptive timing / quality

    private var sampleIntervalEMA = 1.0 / 30.0
    private var sampleJitterEMA = 0.0
    private var confidenceEMA = 0.82
    private var trackingInstability = 0.0
    private var lastDistanceGain = 1.0
    private var lastTelemetryPublishTime: TimeInterval = 0
    private var processingLatencyEMA = 0.012
    private var pendingTelemetry: (Double, Double, Double, Double)?

    // MARK: - V1.0 continuity-first tracking

    private var lastValidObservationTime: TimeInterval = 0
    private var dropoutStartedAt: TimeInterval?
    private var currentDropoutFrames = 0
    private var totalDroppedObservations = 0
    private var lastRecoveryFrameCount = 0
    private var continuityEMA = 1.0
    private var lastContinuityPublishTime: TimeInterval = 0
    private var pendingContinuityTelemetry: (Double, Int, Double, Int)?

    // MARK: - V1.1 recovery fusion / semantic hysteresis

    private var pointerRecoveryFramesRemaining = 0
    private var pointerRecoveryFramesTotal = 0
    private var scrollRecoveryFramesRemaining = 0
    private var scrollRecoveryFramesTotal = 0
    private var semanticCandidateMode: Mode?
    private var semanticCandidateFrames = 0

    // MARK: - Personal calibration

    private var calibrationCandidateScale: Double?
    private var calibrationStableSamples = 0
    private var lastPublishedCalibrationProgress = -1.0
    private var pendingCalibrationUpdate: (Double, Double?)?

    // MARK: - V1.1 continuity helpers

    /// 跨 pointer/scroll/systemSwipe/idle 的语义变化至少连续确认若干帧。
    /// 目的不是让手势“更迟钝”，而是防止一帧手指数误判直接切换整个控制器状态。
    private func resolveSemanticModeLocked(
        requested: Mode,
        previous: Mode,
        config: Configuration
    ) -> Mode {
        let previousSemantic: Mode = previous == .drag ? .pointer : previous
        if requested == previousSemantic {
            semanticCandidateMode = nil
            semanticCandidateFrames = 0
            return requested
        }

        // idle 起步立即响应；drag 的进入/退出由 pinch 状态单独负责。
        if previousSemantic == .idle {
            semanticCandidateMode = nil
            semanticCandidateFrames = 0
            return requested
        }

        if semanticCandidateMode != requested {
            semanticCandidateMode = requested
            semanticCandidateFrames = 1
        } else {
            semanticCandidateFrames += 1
        }

        let required = max(config.semanticSwitchConfirmFrames, 1)
        if semanticCandidateFrames >= required {
            semanticCandidateMode = nil
            semanticCandidateFrames = 0
            return requested
        }
        return previousSemantic
    }

    /// Vision 从短时 dropout 恢复后，不让第一帧新观测 100% 接管速度。
    /// 连续几帧把 trust 从 recoveryTrustFloor 平滑提升到 1，避免“预测轨迹 -> 实测关键点”接缝。
    private func consumePointerRecoveryTrustLocked(config: Configuration) -> Double {
        guard pointerRecoveryFramesRemaining > 0, pointerRecoveryFramesTotal > 0 else { return 1.0 }
        let completed = pointerRecoveryFramesTotal - pointerRecoveryFramesRemaining
        let progress = Double(completed + 1) / Double(pointerRecoveryFramesTotal)
        let floor = min(max(config.recoveryTrustFloor, 0.20), 0.85)
        let trust = floor + (1.0 - floor) * smoothstep(0, 1, progress)
        pointerRecoveryFramesRemaining -= 1
        if pointerRecoveryFramesRemaining == 0 { pointerRecoveryFramesTotal = 0 }
        return trust
    }

    private func consumeScrollRecoveryTrustLocked(config: Configuration) -> Double {
        guard scrollRecoveryFramesRemaining > 0, scrollRecoveryFramesTotal > 0 else { return 1.0 }
        let completed = scrollRecoveryFramesTotal - scrollRecoveryFramesRemaining
        let progress = Double(completed + 1) / Double(scrollRecoveryFramesTotal)
        let floor = min(max(config.recoveryTrustFloor, 0.20), 0.85)
        let trust = floor + (1.0 - floor) * smoothstep(0, 1, progress)
        scrollRecoveryFramesRemaining -= 1
        if scrollRecoveryFramesRemaining == 0 { scrollRecoveryFramesTotal = 0 }
        return trust
    }

    // MARK: - Pinch / click intent

    private var leftButtonDown = false
    private var pinchPressCandidateSince: TimeInterval?
    private var pinchReleaseCandidateSince: TimeInterval?
    private var pinchArmed = false
    private var lastPinchRatio: Double?
    private var lastPinchTimestamp: TimeInterval?
    private var suppressPointerUntil: TimeInterval = 0

    // MARK: - V0.8 pointer intent / trajectory prediction

    @discardableResult
    private func updatePointerMotionPhaseLocked(
        normalizedSpeed: Double,
        timestamp: TimeInterval,
        pinchRatio: Double?,
        dragging: Bool,
        config: Configuration
    ) -> PointerMotionPhase {
        let previousSpeed = lastNormalizedPointerSpeed
        let speedDelta = normalizedSpeed - previousSpeed
        let ratio = pinchRatio ?? 1.0
        let pinchPreparing = pinchArmed
            && ratio < config.pinchArmRatio
            && ratio > config.pinchStartRatio * 0.92
            && (lastPinchClosingSpeed > 0.055 || ratio < config.pinchArmRatio * 0.90)
            && normalizedSpeed < 0.30

        let desired: PointerMotionPhase
        if dragging {
            desired = .dragging
        } else if pinchPreparing {
            desired = .clickReady
        } else if normalizedSpeed < 0.032 {
            desired = .settling
        } else if speedDelta > 0.075 && normalizedSpeed > 0.12 {
            desired = .accelerating
        } else if -speedDelta > 0.060 && previousSpeed > 0.15 {
            desired = .decelerating
        } else {
            desired = .cruising
        }

        if desired == pointerMotionPhase {
            pointerPhaseCandidate = nil
            return pointerMotionPhase
        }

        let hold: TimeInterval
        switch desired {
        case .dragging: hold = 0
        case .clickReady: hold = 0.024
        case .settling: hold = 0.030
        case .decelerating: hold = 0.018
        case .accelerating, .cruising:
            // 从静止进入移动时不要再额外等一帧；其它状态间切换保留轻微迟滞。
            hold = pointerMotionPhase == .idle || pointerMotionPhase == .settling ? 0 : 0.014
        case .idle: hold = 0
        }

        if pointerPhaseCandidate != desired {
            pointerPhaseCandidate = desired
            pointerPhaseCandidateSince = timestamp
            if hold > 0 { return pointerMotionPhase }
        }

        if timestamp - pointerPhaseCandidateSince >= hold {
            pointerMotionPhase = desired
            pointerPhaseCandidate = nil
            pendingPointerPhase = desired
        }
        return pointerMotionPhase
    }

    private func trajectoryPredictedVelocityLocked(
        timestamp: TimeInterval,
        rawVX: Double,
        rawVY: Double,
        normalizedSpeed: Double,
        phase: PointerMotionPhase,
        config: Configuration
    ) -> (Double, Double) {
        pointerTrajectory.append(
            PointerKinematicSample(
                timestamp: timestamp,
                vx: rawVX,
                vy: rawVY,
                normalizedSpeed: normalizedSpeed
            )
        )
        let window = min(max(config.trajectoryWindow, 0.08), 0.24)
        let cutoff = timestamp - window
        pointerTrajectory.removeAll { $0.timestamp < cutoff }
        if pointerTrajectory.count > 6 {
            pointerTrajectory.removeFirst(pointerTrajectory.count - 6)
        }

        guard pointerTrajectory.count >= 2 else { return (rawVX, rawVY) }

        var totalWeight = 0.0
        var trendVX = 0.0
        var trendVY = 0.0
        for sample in pointerTrajectory {
            let age = max(0, timestamp - sample.timestamp)
            let freshness = max(0.10, 1.0 - age / window)
            let weight = freshness * freshness
            trendVX += sample.vx * weight
            trendVY += sample.vy * weight
            totalWeight += weight
        }
        if totalWeight > 0 {
            trendVX /= totalWeight
            trendVY /= totalWeight
        } else {
            trendVX = rawVX
            trendVY = rawVY
        }

        guard let first = pointerTrajectory.first, let last = pointerTrajectory.last else {
            return (rawVX, rawVY)
        }
        let span = max(last.timestamp - first.timestamp, 0.012)
        let accelX = (last.vx - first.vx) / span
        let accelY = (last.vy - first.vy) / span

        let response = min(max(config.responsiveness, 0), 1)
        let strength = min(max(config.statePredictionStrength, 0), 1)
        let frameScale = min(max(frameAdaptiveScale(config: config), 0.80), 1.40)
        let stabilityGain = 1.0 - trackingInstability * 0.68
        let phaseHorizon: Double
        switch phase {
        case .accelerating: phaseHorizon = 0.010 + 0.008 * response
        case .cruising: phaseHorizon = 0.007 + 0.006 * response
        case .decelerating: phaseHorizon = 0.0025 + 0.0025 * response
        case .dragging: phaseHorizon = 0.0025
        case .settling, .clickReady, .idle: phaseHorizon = 0
        }

        // V0.9: Vision 推理本身带来的处理延迟只在明确运动阶段补偿。
        // 停驻/点击准备时不做 latency lead，避免为了追求低延迟而把光标推过目标。
        let latencyWeight: Double
        switch phase {
        case .accelerating: latencyWeight = 0.78
        case .cruising: latencyWeight = 0.58
        case .dragging: latencyWeight = 0.18
        case .decelerating: latencyWeight = 0.10
        case .settling, .clickReady, .idle: latencyWeight = 0
        }
        let latencyLead = min(max(processingLatencyEMA, 0), 0.060)
            * min(max(config.processingLatencyCompensation, 0), 1)
            * latencyWeight
        let predictionGate = smoothstep(0.10, 0.92, normalizedSpeed)
        let horizon = (phaseHorizon + latencyLead) * predictionGate * frameScale * stabilityGain * strength

        let trendBlend: Double
        switch phase {
        case .accelerating, .cruising: trendBlend = 0.18
        case .decelerating: trendBlend = 0.10
        case .dragging: trendBlend = 0.08
        case .settling, .clickReady, .idle: trendBlend = 0
        }
        var vx = rawVX * (1.0 - trendBlend) + trendVX * trendBlend
        var vy = rawVY * (1.0 - trendBlend) + trendVY * trendBlend

        let maxLeadX = abs(rawVX) * 0.11 + 28.0
        let maxLeadY = abs(rawVY) * 0.11 + 28.0
        let leadX = min(max(accelX * horizon, -maxLeadX), maxLeadX)
        let leadY = min(max(accelY * horizon, -maxLeadY), maxLeadY)
        vx += leadX
        vy += leadY

        if phase == .decelerating {
            let brake = 1.0 - min(max(config.decelerationBrake, 0), 1) * 0.12
            vx *= brake
            vy *= brake
        } else if phase == .settling || phase == .clickReady {
            vx *= 0.40
            vy *= 0.40
        }
        return (vx, vy)
    }

    /// V0.9 α-β 状态估计：用观测位置修正预测位置和速度。
    /// 返回 Vision 归一化坐标系下的速度（units/s），后续再乘距离与像素增益。
    private func alphaBetaVelocityLocked(
        currentX: Double,
        currentY: Double,
        timestamp: TimeInterval,
        phase: PointerMotionPhase,
        measurementTrust: Double,
        config: Configuration
    ) -> (Double, Double) {
        guard var state = pointerAlphaBetaState else {
            pointerAlphaBetaState = PointerAlphaBetaState(
                x: currentX, y: currentY, vx: 0, vy: 0, timestamp: timestamp
            )
            return (0, 0)
        }

        let dt = timestamp - state.timestamp
        guard dt > 0.010, dt < 0.20 else {
            pointerAlphaBetaState = PointerAlphaBetaState(
                x: currentX, y: currentY, vx: 0, vy: 0, timestamp: timestamp
            )
            return (0, 0)
        }

        let predictedX = state.x + state.vx * dt
        let predictedY = state.y + state.vy * dt
        let residualX = currentX - predictedX
        let residualY = currentY - predictedY

        let strength = min(max(config.alphaBetaStrength, 0), 1)
        let quality = min(max(1.0 - trackingInstability, 0), 1)
        let phaseResponse: Double
        switch phase {
        case .accelerating: phaseResponse = 1.00
        case .cruising: phaseResponse = 0.88
        case .decelerating: phaseResponse = 0.68
        case .dragging: phaseResponse = 0.72
        case .settling, .clickReady, .idle: phaseResponse = 0.42
        }

        // alpha 控制位置纠正，beta 控制速度纠正。V1.0 再乘 soft confidence：
        // 低置信度观测只轻量纠正预测状态，不再二值丢弃，也不会强行把坏点灌进速度估计。
        let trust = min(max(measurementTrust, 0), 1)
        let rawAlpha = min(max(0.42 + strength * 0.30 * phaseResponse + quality * 0.12, 0.38), 0.88)
        let rawBeta = min(max(0.045 + strength * 0.16 * phaseResponse + quality * 0.035, 0.035), 0.24)
        let alpha = 0.16 + (rawAlpha - 0.16) * (0.24 + trust * 0.76)
        let beta = rawBeta * (0.18 + trust * 0.82)

        state.x = predictedX + alpha * residualX
        state.y = predictedY + alpha * residualY
        state.vx += (beta / dt) * residualX
        state.vy += (beta / dt) * residualY

        // Vision 偶发坏点即使没超过 jump limit，也不能让估计速度无限膨胀。
        let maxNormalizedVelocity = 2.8
        state.vx = min(max(state.vx, -maxNormalizedVelocity), maxNormalizedVelocity)
        state.vy = min(max(state.vy, -maxNormalizedVelocity), maxNormalizedVelocity)
        state.timestamp = timestamp
        pointerAlphaBetaState = state
        return (state.vx, state.vy)
    }

    private func resetPointerAlphaBetaLocked(x: Double? = nil, y: Double? = nil, timestamp: TimeInterval = 0) {
        if let x, let y, timestamp > 0 {
            pointerAlphaBetaState = PointerAlphaBetaState(x: x, y: y, vx: 0, vy: 0, timestamp: timestamp)
        } else {
            pointerAlphaBetaState = nil
        }
    }

    // MARK: - Scroll

    /// 像素/秒。双指采样期间跟随手势，抬手后进入惯性衰减。
    private var scrollVelocityX = 0.0
    private var scrollVelocityY = 0.0
    private var scrollActive = false
    private var lastScrollSampleTime: TimeInterval = 0
    private var scrollStillSamples = 0
    private var scrollAxisLock: ScrollAxisLock = .none
    private var scrollAccumulatedX = 0.0
    private var scrollAccumulatedY = 0.0
    private var scrollStartTravel = 0.0
    private var scrollEngaged = false
    private var scrollEngagedAt: TimeInterval = 0
    private var scrollMotionPhase: ScrollMotionPhase = .idle
    private var pendingScrollMotionPhase: ScrollMotionPhase?
    private var scrollContactSince: TimeInterval = 0

    private struct VelocitySample {
        let timestamp: TimeInterval
        let x: Double
        let y: Double
    }
    private var scrollVelocityHistory: [VelocitySample] = []

    // MARK: V1.2 scroll stroke intent latch
    // Air gestures have no physical touch-down/lift boundary. Once a scroll stroke direction is
    // established, opposite motion is treated as hand re-centering until the hand becomes neutral.
    // This is deliberately velocity/intent based rather than origin based, so camera drift does not
    // create a false reverse scroll near the old starting point.
    private var scrollContactOriginX: Double?
    private var scrollContactOriginY: Double?
    private var scrollStrokeAxis: ScrollAxisLock = .none
    private var scrollStrokeDirection = 0.0
    private var scrollStrokePeakTravel = 0.0
    private var scrollRetractionSuppressed = false
    private var scrollRetractionCandidateFrames = 0
    private var scrollRetractionNeutralSince: TimeInterval?
    private var scrollRetractionReverseFrames = 0

    // MARK: V1.2 bimanual clutch
    private var externalClutchActive = false

    private var zoomAccumulator = 0.0
    private var zoomLockUntil: TimeInterval = 0
    // V1.1.1: 双指缩放与滚动互斥。一次双指接触一旦表现出明显平移，就锁定为滚动直到抬手。
    private var zoomSuppressedForContact = false
    private var zoomIntentActive = false
    private var zoomIntentDirection = 0
    private var zoomIntentFrames = 0
    private var zoomCenterTravel = 0.0

    // 统一 120Hz motion tick。输入帧可以只有约 24FPS，但输出不再按帧“跳格”。
    private var lastTickTime = ProcessInfo.processInfo.systemUptime
    private let motionQueue = DispatchQueue(label: "com.hutong.GestureControl.trackpad-motion", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    private let systemSwipeEngine = DirectionalGestureEngine()

    init() {
        var swipeConfig = DirectionalGestureEngine.Configuration()
        swipeConfig.minimumDistance = 0.115
        swipeConfig.minimumVelocity = 0.24
        swipeConfig.dominanceRatio = 1.28
        swipeConfig.maximumGestureDuration = 0.80
        swipeConfig.historyDuration = 0.90
        swipeConfig.cooldown = 0.75
        swipeConfig.minimumConfidence = 0.40
        systemSwipeEngine.update(configuration: swipeConfig)
        systemSwipeEngine.onGesture = { [weak self] direction in
            self?.onSystemSwipe?(direction)
        }

        let timer = DispatchSource.makeTimerSource(queue: motionQueue)
        // 120Hz is 8.333ms, not 8ms (125Hz). Matching the intended cadence keeps the
        // velocity integrator's nominal timing aligned with its tuning constants.
        timer.schedule(
            deadline: .now() + .nanoseconds(8_333_333),
            repeating: .nanoseconds(8_333_333),
            leeway: .microseconds(750)
        )
        timer.setEventHandler { [weak self] in
            self?.tickMotion()
        }
        timer.resume()
        self.timer = timer
    }

    deinit {
        timer?.cancel()
    }

    func update(configuration newConfiguration: Configuration) {
        lock.lock()
        configuration = newConfiguration
        if newConfiguration.personalPalmScale != nil {
            calibrationStableSamples = max(calibrationStableSamples, newConfiguration.calibrationRequiredStableSamples)
        }
        lock.unlock()
    }

    /// V1.2 双手辅助“离合”。辅助手张开时，主手仍被追踪，但所有指针/滚动输出冻结，
    /// 因此主手可以自由回到舒适位置；松开离合后从新位置继续，不产生反向回程或跳变。
    func setExternalClutch(active: Bool, timestamp: TimeInterval) {
        var publishIdle = false
        lock.lock()
        if externalClutchActive != active {
            externalClutchActive = active
            pointerVelocityX = 0
            pointerVelocityY = 0
            lastRawPointerVelocityX = 0
            lastRawPointerVelocityY = 0
            pointerTrajectory.removeAll(keepingCapacity: true)
            clearPrecisionAnchorLocked()
            resetPointerAlphaBetaLocked()
            cancelScrollLocked()
            semanticCandidateMode = nil
            semanticCandidateFrames = 0
            mode = .idle
            pointerActive = false
            lastPointerSampleTime = timestamp
            lastScrollSampleTime = timestamp
            publishIdle = active
        }
        lock.unlock()
        if publishIdle {
            systemSwipeEngine.reset()
            setInteraction(.idle)
        }
    }

    func resetPersonalCalibration() {
        lock.lock()
        configuration.personalPalmScale = nil
        calibrationCandidateScale = nil
        calibrationStableSamples = 0
        lastPublishedCalibrationProgress = -1
        pendingCalibrationUpdate = nil
        smoothedPalmScale = nil
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onCalibrationChanged?(0, nil)
        }
    }

    func reset() {
        var releaseButton = false

        lock.lock()
        if leftButtonDown {
            leftButtonDown = false
            releaseButton = true
        }

        lastSample = nil
        mode = .idle
        pointerVelocityX = 0
        pointerVelocityY = 0
        pointerActive = false
        pointerStillSamples = 0
        lastRawPointerVelocityX = 0
        lastRawPointerVelocityY = 0
        smoothedPalmScale = nil
        pointerNoiseFloor = 0.0010
        clearPrecisionAnchorLocked()
        lastNormalizedPointerSpeed = 0
        pointerTrajectory.removeAll(keepingCapacity: true)
        pointerMotionPhase = .idle
        pointerPhaseCandidate = nil
        pointerPhaseCandidateSince = 0
        pendingPointerPhase = .idle
        lastPinchClosingSpeed = 0
        resetPointerAlphaBetaLocked()
        postClickReboundUntil = 0
        lastExplicitPointerPoseTime = -1
        lastExplicitTwoFingerPoseTime = -1
        sampleIntervalEMA = 1.0 / max(configuration.nominalInputFPS, 1)
        sampleJitterEMA = 0
        confidenceEMA = 0.82
        trackingInstability = 0
        lastDistanceGain = 1
        processingLatencyEMA = 0.012
        lastTelemetryPublishTime = 0
        pendingTelemetry = nil
        lastValidObservationTime = 0
        dropoutStartedAt = nil
        currentDropoutFrames = 0
        totalDroppedObservations = 0
        lastRecoveryFrameCount = 0
        continuityEMA = 1.0
        lastContinuityPublishTime = 0
        pendingContinuityTelemetry = nil
        pointerRecoveryFramesRemaining = 0
        pointerRecoveryFramesTotal = 0
        scrollRecoveryFramesRemaining = 0
        scrollRecoveryFramesTotal = 0
        semanticCandidateMode = nil
        semanticCandidateFrames = 0
        externalClutchActive = false
        pinchPressCandidateSince = nil
        pinchReleaseCandidateSince = nil
        pinchArmed = false
        lastPinchRatio = nil
        lastPinchTimestamp = nil
        suppressPointerUntil = 0

        scrollVelocityX = 0
        scrollVelocityY = 0
        scrollActive = false
        scrollStillSamples = 0
        scrollStartTravel = 0
        scrollEngaged = false
        scrollEngagedAt = 0
        scrollMotionPhase = .idle
        pendingScrollMotionPhase = .idle
        scrollContactSince = 0
        scrollVelocityHistory.removeAll(keepingCapacity: true)
        resetScrollAxisLockLocked()
        resetScrollRetractionLocked()

        zoomAccumulator = 0
        zoomLockUntil = 0
        zoomSuppressedForContact = false
        zoomIntentActive = false
        zoomIntentDirection = 0
        zoomIntentFrames = 0
        zoomCenterTravel = 0
        lastTickTime = ProcessInfo.processInfo.systemUptime
        lock.unlock()

        systemSwipeEngine.reset()
        if releaseButton { onLeftButton?(false) }
        setInteraction(.idle)
        DispatchQueue.main.async { [weak self] in
            self?.onPointerMotionPhaseChanged?(.idle)
            self?.onScrollMotionPhaseChanged?(.idle)
        }
    }

    /// V1.0: 摄像头/Vision 短暂没给出可用手部观测时，不再立刻 reset。
    /// 返回 true 表示仍处于 continuity hold，UI 也应继续视为“手仍在跟踪中”。
    @discardableResult
    func observationMissed(timestamp: TimeInterval) -> Bool {
        let config = configurationSnapshot
        var continuityUpdate: (Double, Int, Double, Int)?
        var shouldFinalize = false
        var holding = false

        lock.lock()
        let wasTracking = mode != .idle || pointerActive || scrollActive || leftButtonDown
        if dropoutStartedAt == nil {
            dropoutStartedAt = timestamp
            currentDropoutFrames = 0
        }
        currentDropoutFrames += 1
        totalDroppedObservations += 1

        let sinceValid: TimeInterval
        if lastValidObservationTime > 0 {
            sinceValid = max(0, timestamp - lastValidObservationTime)
        } else {
            sinceValid = config.continuityHoldDuration + 1
        }
        let adaptiveHold = min(
            max(config.continuityHoldDuration, sampleIntervalEMA * 3.8),
            0.24
        )
        let fadeStart = min(max(config.continuityFadeStart, sampleIntervalEMA * 1.35), adaptiveHold * 0.65)

        if wasTracking, sinceValid <= adaptiveHold {
            holding = true
            let fadeT = smoothstep(fadeStart, adaptiveHold, sinceValid)
            let targetContinuity = 1.0 - fadeT * 0.34
            continuityEMA += (targetContinuity - continuityEMA) * 0.22

            // 丢帧期间禁止基于旧 pinch ratio 继续触发新点击，但已按下拖拽保持到 hard stop。
            pinchPressCandidateSince = nil
            pinchReleaseCandidateSince = nil
            lastPinchRatio = nil
            lastPinchTimestamp = nil

            // clickReady 依赖实时手指距离；失去观测后回到减速态，避免假“准备点击”长期刹死。
            if pointerMotionPhase == .clickReady, !leftButtonDown {
                pointerMotionPhase = .decelerating
                pendingPointerPhase = .decelerating
            }
        } else if wasTracking {
            shouldFinalize = true
            continuityEMA += (0.0 - continuityEMA) * 0.45
        } else {
            continuityEMA += (1.0 - continuityEMA) * 0.06
        }

        let holdAge = holding ? sinceValid : 0
        if timestamp - lastContinuityPublishTime >= 0.10 || shouldFinalize {
            lastContinuityPublishTime = timestamp
            continuityUpdate = (
                min(max(continuityEMA, 0), 1),
                totalDroppedObservations,
                holdAge,
                lastRecoveryFrameCount
            )
        }
        lock.unlock()

        if let continuityUpdate {
            DispatchQueue.main.async { [weak self] in
                self?.onContinuityTelemetry?(continuityUpdate.0, continuityUpdate.1, continuityUpdate.2, continuityUpdate.3)
            }
        }
        if shouldFinalize {
            finalizeHandLost(timestamp: timestamp)
            return false
        }
        return holding
    }

    /// 显式/超时的真正丢手。只有超过 continuity hold 后才走到这里。
    private func finalizeHandLost(timestamp: TimeInterval) {
        var releaseButton = false

        lock.lock()
        let wasScrolling = mode == .scroll
        if leftButtonDown {
            leftButtonDown = false
            releaseButton = true
        }

        // 双指从画面中离开，等价于真实触控板“抬起手指”：用最近约 140ms 的
        // 速度历史估算 release velocity，再进入惯性，避免最后一个噪声帧毁掉 flick。
        if wasScrolling {
            prepareScrollReleaseLocked(timestamp: timestamp)
            scrollActive = false
        } else {
            scrollVelocityX = 0
            scrollVelocityY = 0
            scrollActive = false
        }

        lastSample = nil
        mode = .idle
        pointerVelocityX = 0
        pointerVelocityY = 0
        pointerActive = false
        pointerStillSamples = 0
        lastRawPointerVelocityX = 0
        lastRawPointerVelocityY = 0
        smoothedPalmScale = nil
        pointerNoiseFloor = 0.0010
        clearPrecisionAnchorLocked()
        lastNormalizedPointerSpeed = 0
        pointerTrajectory.removeAll(keepingCapacity: true)
        pointerMotionPhase = .idle
        pointerPhaseCandidate = nil
        pointerPhaseCandidateSince = 0
        pendingPointerPhase = .idle
        lastPinchClosingSpeed = 0
        resetPointerAlphaBetaLocked()
        postClickReboundUntil = 0
        lastExplicitPointerPoseTime = -1
        lastExplicitTwoFingerPoseTime = -1
        pinchPressCandidateSince = nil
        pinchReleaseCandidateSince = nil
        pinchArmed = false
        lastPinchRatio = nil
        lastPinchTimestamp = nil
        suppressPointerUntil = 0
        dropoutStartedAt = nil
        currentDropoutFrames = 0
        lastValidObservationTime = 0
        pointerRecoveryFramesRemaining = 0
        pointerRecoveryFramesTotal = 0
        scrollRecoveryFramesRemaining = 0
        scrollRecoveryFramesTotal = 0
        semanticCandidateMode = nil
        semanticCandidateFrames = 0
        scrollStartTravel = 0
        scrollEngaged = false
        scrollEngagedAt = 0
        scrollContactSince = 0
        if wasScrolling, hypot(scrollVelocityX, scrollVelocityY) >= 70 {
            scrollMotionPhase = .coasting
            pendingScrollMotionPhase = .coasting
        } else {
            scrollMotionPhase = .idle
            pendingScrollMotionPhase = .idle
        }
        if !wasScrolling { scrollVelocityHistory.removeAll(keepingCapacity: true) }
        zoomAccumulator = 0
        zoomSuppressedForContact = false
        zoomIntentActive = false
        zoomIntentDirection = 0
        zoomIntentFrames = 0
        zoomCenterTravel = 0
        resetScrollAxisLockLocked()
        resetScrollRetractionLocked()
        let lostScrollPhase = scrollMotionPhase
        pendingScrollMotionPhase = nil
        lock.unlock()

        systemSwipeEngine.reset()
        if releaseButton { onLeftButton?(false) }
        setInteraction(.idle)
        DispatchQueue.main.async { [weak self] in
            self?.onPointerMotionPhaseChanged?(.idle)
            self?.onScrollMotionPhaseChanged?(lostScrollPhase)
        }
    }


    /// 兼容旧调用：显式 handLost 现在也按真正丢手处理。
    func handLost(timestamp: TimeInterval) {
        finalizeHandLost(timestamp: timestamp)
    }

    func process(_ sample: TrackpadSample) {
        let config = configurationSnapshot
        // V1.0 仅保留非常低的硬底线。正常的置信度波动不再 reset，而是在滤波阶段软降权。
        guard sample.confidence >= config.minimumConfidence else {
            observationMissed(timestamp: sample.timestamp)
            return
        }

        var mouseButtonChange: Bool?
        var zoomStep: Int?
        var interactionToPublish: TrackpadInteraction?
        var advanceLastSample = true

        lock.lock()

        let previous = lastSample
        let previousMode = mode
        let dt = previous.map { sample.timestamp - $0.timestamp } ?? 0

        // V1.0: 有效观测恢复时只恢复 continuity，不清掉速度/α-β/轨迹。
        // 这样 1~3 个丢帧之后不会重新“起步”。
        let recoveredFrames = currentDropoutFrames
        if recoveredFrames > 0 {
            lastRecoveryFrameCount = recoveredFrames
            let blendFrames = min(max(config.recoveryBlendFrames, 1), 5)
            if previousMode == .pointer || previousMode == .drag {
                pointerRecoveryFramesRemaining = blendFrames
                pointerRecoveryFramesTotal = blendFrames
            }
            if previousMode == .scroll {
                scrollRecoveryFramesRemaining = blendFrames
                scrollRecoveryFramesTotal = blendFrames
            }
            currentDropoutFrames = 0
            dropoutStartedAt = nil
            continuityEMA += (1.0 - continuityEMA) * 0.34
        } else {
            continuityEMA += (1.0 - continuityEMA) * 0.055
        }
        lastValidObservationTime = sample.timestamp
        if sample.timestamp - lastContinuityPublishTime >= 0.10 || recoveredFrames > 0 {
            lastContinuityPublishTime = sample.timestamp
            pendingContinuityTelemetry = (
                min(max(continuityEMA, 0), 1),
                totalDroppedObservations,
                0,
                lastRecoveryFrameCount
            )
        }

        updateTrackingTimingLocked(sample: sample, dt: dt, config: config)

        // V1.2 bimanual clutch: keep consuming the newest primary-hand observation as the
        // new baseline, but never emit motion while the auxiliary hand is holding the clutch.
        // This gives the air interface a real trackpad-like “lift/recenter” semantic.
        if externalClutchActive {
            mode = .idle
            pointerActive = false
            pointerVelocityX = 0
            pointerVelocityY = 0
            lastRawPointerVelocityX = 0
            lastRawPointerVelocityY = 0
            scrollActive = false
            scrollVelocityX = 0
            scrollVelocityY = 0
            scrollVelocityHistory.removeAll(keepingCapacity: true)
            lastSample = sample
            lastPointerSampleTime = sample.timestamp
            lastScrollSampleTime = sample.timestamp

            let calibrationUpdate = pendingCalibrationUpdate
            pendingCalibrationUpdate = nil
            let telemetryUpdate = pendingTelemetry
            pendingTelemetry = nil
            let continuityUpdate = pendingContinuityTelemetry
            pendingContinuityTelemetry = nil
            let motionPhaseUpdate = pendingPointerPhase
            pendingPointerPhase = nil
            let scrollPhaseUpdate = pendingScrollMotionPhase
            pendingScrollMotionPhase = nil
            lock.unlock()

            if let calibrationUpdate {
                DispatchQueue.main.async { [weak self] in
                    self?.onCalibrationChanged?(calibrationUpdate.0, calibrationUpdate.1)
                }
            }
            if let telemetryUpdate {
                DispatchQueue.main.async { [weak self] in
                    self?.onTrackingTelemetry?(telemetryUpdate.0, telemetryUpdate.1, telemetryUpdate.2, telemetryUpdate.3)
                }
            }
            if let continuityUpdate {
                DispatchQueue.main.async { [weak self] in
                    self?.onContinuityTelemetry?(continuityUpdate.0, continuityUpdate.1, continuityUpdate.2, continuityUpdate.3)
                }
            }
            if let motionPhaseUpdate {
                DispatchQueue.main.async { [weak self] in self?.onPointerMotionPhaseChanged?(motionPhaseUpdate) }
            }
            if let scrollPhaseUpdate {
                DispatchQueue.main.async { [weak self] in self?.onScrollMotionPhaseChanged?(scrollPhaseUpdate) }
            }
            setInteraction(.idle)
            return
        }

        // FingerPattern 属于“手势语义层”，关键点位置属于“连续追踪层”。
        // 分类暂时为 nil 时允许沿用上一种已确认交互；一旦明确识别成其它姿势则立即退出宽限。
        let pattern = sample.fingerPattern
        let pointerLandmarkUsable = sample.pointerObservationConfidence >= 0.18
        let scrollLandmarksUsable = sample.scrollObservationConfidence >= 0.18
        let explicitPointerPose = pattern?.isPointerPose == true && pointerLandmarkUsable
        let explicitTwoFingerPose = pattern?.isTwoFingerPose == true && scrollLandmarksUsable
        let systemSwipePose = pattern?.isSystemSwipePose == true
        if explicitPointerPose { lastExplicitPointerPoseTime = sample.timestamp }
        if explicitTwoFingerPose { lastExplicitTwoFingerPoseTime = sample.timestamp }

        let classificationMissing = pattern == nil
        let pointerGrace = sample.timestamp - lastExplicitPointerPoseTime <= max(config.pointerPoseGrace, 0.08)
        let twoFingerGrace = sample.timestamp - lastExplicitTwoFingerPoseTime <= max(config.scrollPoseGrace, config.scrollReleaseDebounce)
        let rawPointerPose = explicitPointerPose || (
            classificationMissing && pointerGrace &&
            (previousMode == .pointer || previousMode == .drag)
        )
        let rawTwoFingerPose = explicitTwoFingerPose || (
            classificationMissing && twoFingerGrace && previousMode == .scroll
        )

        // V1.1 semantic hysteresis：位置层可以继续高频更新，但 pointer / scroll / systemSwipe
        // 的语义切换不再由单帧 fingerPattern 决定。跨模式至少连续确认两帧；
        // 同一模式与 idle -> 首个模式仍立即响应，避免引入明显起步延迟。
        let requestedSemanticMode: Mode = systemSwipePose ? .systemSwipe : (rawTwoFingerPose ? .scroll : (rawPointerPose ? .pointer : .idle))
        let resolvedSemanticMode = resolveSemanticModeLocked(
            requested: requestedSemanticMode,
            previous: previousMode,
            config: config
        )
        let pointerPose = resolvedSemanticMode == .pointer || resolvedSemanticMode == .drag
        let twoFingerPose = resolvedSemanticMode == .scroll
        let confirmedSystemSwipePose = resolvedSemanticMode == .systemSwipe

        let pointerSpeedForIntent: Double = {
            guard let previous, dt > 0.012, dt < 0.16 else { return 0 }
            return hypot(sample.pointerX - previous.pointerX, sample.pointerY - previous.pointerY) / dt
        }()

        mouseButtonChange = updatePinchStateLocked(
            ratio: sample.pinchRatio,
            timestamp: sample.timestamp,
            allowPress: pointerPose || previousMode == .pointer || previousMode == .drag,
            pointerSpeed: pointerSpeedForIntent,
            config: config
        )
        if mouseButtonChange == true {
            // 捏合本身会改变食指几何位置。短暂冻结指针，防止点击发生前光标被推离目标。
            suppressPointerUntil = sample.timestamp + config.pinchPointerFreeze
            clearPrecisionAnchorLocked()
            resetPointerAlphaBetaLocked(x: sample.pointerX, y: sample.pointerY, timestamp: sample.timestamp)
            pointerVelocityX = 0
            pointerVelocityY = 0
            lastRawPointerVelocityX = 0
            lastRawPointerVelocityY = 0
        } else if mouseButtonChange == false {
            // V0.9: 松开捏合时手指会快速恢复形状，Vision 的 index tip 容易出现反弹位移。
            // 短暂压住 pointer，并重置状态估计器，避免 click/drag release 后光标“弹一下”。
            postClickReboundUntil = sample.timestamp + max(config.postClickReboundHold, 0)
            suppressPointerUntil = max(suppressPointerUntil, postClickReboundUntil)
            clearPrecisionAnchorLocked()
            pointerTrajectory.removeAll(keepingCapacity: true)
            resetPointerAlphaBetaLocked(x: sample.pointerX, y: sample.pointerY, timestamp: sample.timestamp)
            pointerVelocityX = 0
            pointerVelocityY = 0
            lastRawPointerVelocityX = 0
            lastRawPointerVelocityY = 0
        }

        if leftButtonDown {
            mode = .drag
            cancelScrollLocked()
            systemSwipeEngine.reset()
            if pointerLandmarkUsable {
                updatePointerMotionLocked(
                    current: sample,
                    previous: previous,
                    previousMode: previousMode,
                    config: config,
                    dragging: true
                )
            } else {
                // Palm 仍可见但食指关键点暂时遮挡：保持 drag，不把 palm center 当 pointer。
                pointerVelocityX *= 0.92
                pointerVelocityY *= 0.92
                lastPointerSampleTime = sample.timestamp
                advanceLastSample = false
            }
            interactionToPublish = .dragging
        } else if twoFingerPose {
            mode = .scroll
            pointerActive = false
            pointerVelocityX = 0
            pointerVelocityY = 0
            systemSwipeEngine.reset()

            if previousMode != .scroll {
                // 新一次双指接触：旧惯性立即被新的直接操作接管。
                scrollVelocityX = 0
                scrollVelocityY = 0
                scrollStillSamples = 0
                resetScrollAxisLockLocked()
                scrollStartTravel = 0
                scrollEngaged = false
                scrollEngagedAt = 0
                scrollContactSince = sample.timestamp
                        if scrollMotionPhase != .contact {
                    scrollMotionPhase = .contact
                    pendingScrollMotionPhase = .contact
                }
                scrollVelocityHistory.removeAll(keepingCapacity: true)
                resetScrollRetractionLocked(originX: sample.scrollX, originY: sample.scrollY)
                zoomAccumulator = 0
                zoomSuppressedForContact = false
                zoomIntentActive = false
                zoomIntentDirection = 0
                zoomIntentFrames = 0
                zoomCenterTravel = 0
            }

            if config.twoFingerZoomEnabled,
               sample.timestamp >= zoomLockUntil,
               let previous,
               let previousSpan = previous.twoFingerSpan,
               let currentSpan = sample.twoFingerSpan,
               dt > 0.020,
               dt < 0.20 {
                let spanDelta = currentSpan - previousSpan
                let centerMovement = hypot(
                    sample.scrollX - previous.scrollX,
                    sample.scrollY - previous.scrollY
                )
                zoomCenterTravel += centerMovement

                // 一旦出现明显的双指平移，当前接触周期就认定为滚动，不再允许 span 抖动抢占成 zoom。
                if scrollEngaged
                    || centerMovement > config.zoomCenterMovementLimit
                    || zoomCenterTravel > config.zoomMaxCenterTravelBeforeLock {
                    zoomSuppressedForContact = true
                    zoomIntentActive = false
                    zoomIntentDirection = 0
                    zoomIntentFrames = 0
                    zoomAccumulator = 0
                }

                if !zoomSuppressedForContact,
                   abs(spanDelta) >= config.zoomMinimumSpanDelta {
                    let direction = spanDelta > 0 ? 1 : -1
                    if zoomIntentDirection == direction {
                        zoomIntentFrames += 1
                    } else {
                        zoomIntentDirection = direction
                        zoomIntentFrames = 1
                        zoomAccumulator = 0
                    }
                    zoomAccumulator += spanDelta

                    if zoomIntentFrames >= max(config.zoomIntentConfirmFrames, 1),
                       abs(zoomAccumulator) >= config.zoomStepThreshold {
                        zoomIntentActive = true
                        let pulseCount = min(3, max(1, Int(abs(zoomAccumulator) / config.zoomStepThreshold)))
                        zoomStep = direction * pulseCount
                        zoomAccumulator -= Double(direction * pulseCount) * config.zoomStepThreshold
                        zoomLockUntil = sample.timestamp + config.zoomPulseCooldown
                        scrollActive = false
                        scrollVelocityX = 0
                        scrollVelocityY = 0
                        scrollVelocityHistory.removeAll(keepingCapacity: true)
                        interactionToPublish = .zooming
                    }
                } else if !zoomIntentActive {
                    // 方向反复/幅度很小的 span 抖动不允许长期累积。
                    zoomAccumulator *= 0.45
                    zoomIntentFrames = max(zoomIntentFrames - 1, 0)
                    if zoomIntentFrames == 0 { zoomIntentDirection = 0 }
                }
            } else if !config.twoFingerZoomEnabled {
                zoomAccumulator = 0
                zoomIntentActive = false
                zoomIntentDirection = 0
                zoomIntentFrames = 0
            }

            if zoomStep == nil, !zoomIntentActive, scrollLandmarksUsable,
               let previous,
               previousMode == .scroll,
               dt > 0.020,
               dt < max(0.20, min(config.continuityHoldDuration + 0.04, 0.28)) {
                updateScrollMotionLocked(
                    current: sample,
                    previous: previous,
                    dt: dt,
                    config: config
                )
                interactionToPublish = .scrolling
            } else if !scrollLandmarksUsable {
                // 双指语义仍在宽限期，但坐标缺失：保持直接操控相位，不推进坏坐标。
                scrollVelocityX *= 0.92
                scrollVelocityY *= 0.92
                scrollActive = true
                lastScrollSampleTime = sample.timestamp
                advanceLastSample = false
                interactionToPublish = .scrolling
            }
        } else if confirmedSystemSwipePose {
            mode = .systemSwipe
            pointerActive = false
            pointerVelocityX = 0
            pointerVelocityY = 0
            cancelScrollLocked()
            zoomAccumulator = 0
            interactionToPublish = .systemSwipe
        } else if pointerPose {
            mode = .pointer
            // 一指重新接管后停止旧的滚动惯性，避免“鼠标移动时页面还在滑”。
            cancelScrollLocked()
            systemSwipeEngine.reset()
            if pointerLandmarkUsable {
                updatePointerMotionLocked(
                    current: sample,
                    previous: previous,
                    previousMode: previousMode,
                    config: config,
                    dragging: false
                )
            } else {
                // 保持上一条可信 pointer 轨迹，等待食指关键点恢复。
                pointerVelocityX *= 0.92
                pointerVelocityY *= 0.92
                lastPointerSampleTime = sample.timestamp
                advanceLastSample = false
            }
            interactionToPublish = .pointer
        } else {
            // 如果刚刚是双指滚动，这里相当于“抬起双指”，保留当前滚动速度做惯性。
            if previousMode == .scroll {
                prepareScrollReleaseLocked(timestamp: sample.timestamp)
                scrollActive = false
                let releaseSpeed = hypot(scrollVelocityX, scrollVelocityY)
                let nextScrollPhase: ScrollMotionPhase = releaseSpeed >= 70 ? .coasting : .idle
                if scrollMotionPhase != nextScrollPhase {
                    scrollMotionPhase = nextScrollPhase
                    pendingScrollMotionPhase = nextScrollPhase
                }
            } else if previousMode != .idle {
                cancelScrollLocked()
            }

            mode = .idle
            pointerActive = false
            pointerVelocityX = 0
            pointerVelocityY = 0
            pointerStillSamples = 0
            pointerTrajectory.removeAll(keepingCapacity: true)
            if pointerMotionPhase != .idle {
                pointerMotionPhase = .idle
                pendingPointerPhase = .idle
            }
            pointerPhaseCandidate = nil
            systemSwipeEngine.reset()
            zoomAccumulator = 0
            interactionToPublish = .idle
        }

        if advanceLastSample {
            lastSample = sample
        }
        let currentMode = mode
        let calibrationUpdate = pendingCalibrationUpdate
        pendingCalibrationUpdate = nil
        let telemetryUpdate = pendingTelemetry
        pendingTelemetry = nil
        let continuityUpdate = pendingContinuityTelemetry
        pendingContinuityTelemetry = nil
        let motionPhaseUpdate = pendingPointerPhase
        pendingPointerPhase = nil
        let scrollPhaseUpdate = pendingScrollMotionPhase
        pendingScrollMotionPhase = nil
        lock.unlock()

        if let mouseButtonChange { onLeftButton?(mouseButtonChange) }
        if let zoomStep { onZoomStep?(zoomStep) }
        if let calibrationUpdate {
            DispatchQueue.main.async { [weak self] in
                self?.onCalibrationChanged?(calibrationUpdate.0, calibrationUpdate.1)
            }
        }
        if let telemetryUpdate {
            DispatchQueue.main.async { [weak self] in
                self?.onTrackingTelemetry?(telemetryUpdate.0, telemetryUpdate.1, telemetryUpdate.2, telemetryUpdate.3)
            }
        }
        if let continuityUpdate {
            DispatchQueue.main.async { [weak self] in
                self?.onContinuityTelemetry?(continuityUpdate.0, continuityUpdate.1, continuityUpdate.2, continuityUpdate.3)
            }
        }
        if let motionPhaseUpdate {
            DispatchQueue.main.async { [weak self] in
                self?.onPointerMotionPhaseChanged?(motionPhaseUpdate)
            }
        }
        if let scrollPhaseUpdate {
            DispatchQueue.main.async { [weak self] in
                self?.onScrollMotionPhaseChanged?(scrollPhaseUpdate)
            }
        }
        if let interactionToPublish { setInteraction(interactionToPublish) }

        // DirectionalGestureEngine 内部自行加锁；不要在 TrackpadGestureEngine lock 内调用它。
        if currentMode == .systemSwipe {
            systemSwipeEngine.process(
                HandSample(
                    x: sample.centerX,
                    y: sample.centerY,
                    timestamp: sample.timestamp,
                    confidence: sample.confidence
                )
            )
        }
    }

    private var configurationSnapshot: Configuration {
        lock.lock()
        let snapshot = configuration
        lock.unlock()
        return snapshot
    }

    // MARK: - Pinch / click intent

    /// 返回 nil 表示按键状态未改变；true/false 分别代表 mouseDown / mouseUp。
    ///
    /// V0.6 不再“看到距离够近就点击”。新点击必须先出现一次明确的张开状态，随后再
    /// 主动捏合；这样手刚进入画面时天然靠得比较近，或 Vision 短暂抖动，都不会误点。
    private func updatePinchStateLocked(
        ratio: Double?,
        timestamp: TimeInterval,
        allowPress: Bool,
        pointerSpeed: Double,
        config: Configuration
    ) -> Bool? {
        guard let ratio, ratio.isFinite else {
            pinchPressCandidateSince = nil
            pinchReleaseCandidateSince = nil
            lastPinchRatio = nil
            lastPinchTimestamp = nil
            return nil
        }

        let closingSpeed: Double = {
            guard let previousRatio = lastPinchRatio,
                  let previousTime = lastPinchTimestamp else { return 0 }
            let dt = timestamp - previousTime
            guard dt > 0.012, dt < 0.20 else { return 0 }
            // 正值表示拇指与食指正在主动靠近。
            return (previousRatio - ratio) / dt
        }()
        lastPinchRatio = ratio
        lastPinchTimestamp = timestamp
        lastPinchClosingSpeed = closingSpeed

        if leftButtonDown {
            pinchPressCandidateSince = nil

            if ratio > config.pinchReleaseRatio {
                if pinchReleaseCandidateSince == nil {
                    pinchReleaseCandidateSince = timestamp
                }
                if let since = pinchReleaseCandidateSince,
                   timestamp - since >= config.pinchReleaseDebounce {
                    leftButtonDown = false
                    pinchReleaseCandidateSince = nil
                    pinchArmed = true
                    return false
                }
            } else {
                pinchReleaseCandidateSince = nil
            }
            return nil
        }

        pinchReleaseCandidateSince = nil

        // 必须先看到一次张开的拇指/食指，才允许下一次捏合作为点击。
        // 用户把手直接以“已经捏住”的形态伸进镜头不会立即触发 mouseDown。
        if allowPress, ratio >= config.pinchArmRatio, pointerSpeed <= config.pinchMaximumArmingPointerSpeed {
            pinchArmed = true
        }

        guard allowPress, pinchArmed else {
            pinchPressCandidateSince = nil
            return nil
        }

        let hasIntent = closingSpeed >= config.pinchMinimumClosingSpeed || ratio <= config.pinchDeepPressRatio
        if ratio <= config.pinchStartRatio && hasIntent {
            if pinchPressCandidateSince == nil {
                pinchPressCandidateSince = timestamp
            }
            if let since = pinchPressCandidateSince,
               timestamp - since >= config.pinchPressDebounce {
                leftButtonDown = true
                pinchArmed = false
                pinchPressCandidateSince = nil
                return true
            }
        } else if ratio > config.pinchStartRatio + 0.035 {
            pinchPressCandidateSince = nil
        }

        return nil
    }

    // MARK: - Pointer

    private func updatePointerMotionLocked(
        current: TrackpadSample,
        previous: TrackpadSample?,
        previousMode: Mode,
        config: Configuration,
        dragging: Bool
    ) {
        let distanceGain = distanceCompensationGainLocked(sample: current, config: config)
        let recoveryTrust = consumePointerRecoveryTrustLocked(config: config)

        guard let previous,
              previousMode == .pointer || previousMode == .drag else {
            pointerVelocityX = 0
            pointerVelocityY = 0
            lastRawPointerVelocityX = 0
            lastRawPointerVelocityY = 0
            pointerActive = true
            pointerStillSamples = 0
            pointerAnchorCandidateSince = current.timestamp
            pointerAnchorX = current.pointerX
            pointerAnchorY = current.pointerY
            pointerPrecisionLatched = false
            resetPointerAlphaBetaLocked(x: current.pointerX, y: current.pointerY, timestamp: current.timestamp)
            lastPointerSampleTime = current.timestamp
            return
        }

        let dt = current.timestamp - previous.timestamp
        let maximumContinuousDT = min(max(config.continuityHoldDuration + 0.04, 0.16), 0.28)
        guard dt > 0.012, dt < maximumContinuousDT else {
            pointerVelocityX = 0
            pointerVelocityY = 0
            lastRawPointerVelocityX = 0
            lastRawPointerVelocityY = 0
            pointerTrajectory.removeAll(keepingCapacity: true)
            resetPointerAlphaBetaLocked(x: current.pointerX, y: current.pointerY, timestamp: current.timestamp)
            pointerActive = true
            pointerStillSamples = 0
            clearPrecisionAnchorLocked()
            lastPointerSampleTime = current.timestamp
            return
        }

        if current.timestamp < suppressPointerUntil {
            pointerVelocityX = 0
            pointerVelocityY = 0
            lastRawPointerVelocityX = 0
            lastRawPointerVelocityY = 0
            pointerTrajectory.removeAll(keepingCapacity: true)
            resetPointerAlphaBetaLocked(x: current.pointerX, y: current.pointerY, timestamp: current.timestamp)
            pointerActive = true
            pointerStillSamples = 0
            clearPrecisionAnchorLocked()
            lastPointerSampleTime = current.timestamp
            return
        }

        // 以“标准手掌大小”为基准补偿摄像头距离：手离镜头远时坐标位移变小，自动增益；
        // 靠近时自动降增益。这样用户前后移动身体时，指针速度不会明显忽快忽慢。
        var dx = (current.pointerX - previous.pointerX) * distanceGain
        var dy = (current.pointerY - previous.pointerY) * distanceGain
        var magnitude = hypot(dx, dy)

        guard magnitude <= config.pointerJumpLimit else {
            // V1.1: recovery 首帧的大 residual 可能只是遮挡期间真实移动，不应把速度硬清零。
            // 这时只拒绝该帧对速度的强修正，同时把参考位置接到新观测；正常状态下仍按坏点处理。
            if recoveryTrust < 0.999 {
                pointerVelocityX *= 0.82
                pointerVelocityY *= 0.82
                lastRawPointerVelocityX *= 0.82
                lastRawPointerVelocityY *= 0.82
                pointerTrajectory.removeAll(keepingCapacity: true)
                if var state = pointerAlphaBetaState {
                    state.x = current.pointerX
                    state.y = current.pointerY
                    state.timestamp = current.timestamp
                    state.vx *= 0.72
                    state.vy *= 0.72
                    pointerAlphaBetaState = state
                } else {
                    resetPointerAlphaBetaLocked(x: current.pointerX, y: current.pointerY, timestamp: current.timestamp)
                }
                pointerActive = true
                pointerStillSamples = 0
                clearPrecisionAnchorLocked()
                lastPointerSampleTime = current.timestamp
                return
            }

            // 非 recovery 的 Vision 偶发跳点：丢弃该样本，不让游标飞走。
            pointerVelocityX = 0
            pointerVelocityY = 0
            lastRawPointerVelocityX = 0
            lastRawPointerVelocityY = 0
            pointerTrajectory.removeAll(keepingCapacity: true)
            resetPointerAlphaBetaLocked(x: current.pointerX, y: current.pointerY, timestamp: current.timestamp)
            pointerActive = true
            pointerStillSamples = 0
            clearPrecisionAnchorLocked()
            lastPointerSampleTime = current.timestamp
            return
        }

        let normalizedSpeed = magnitude / dt
        updatePersonalCalibrationLocked(
            sample: current,
            normalizedSpeed: normalizedSpeed,
            dragging: dragging,
            config: config
        )
        let precision = min(max(config.precisionAssist, 0), 1)
        let phase = updatePointerMotionPhaseLocked(
            normalizedSpeed: normalizedSpeed,
            timestamp: current.timestamp,
            pinchRatio: current.pinchRatio,
            dragging: dragging,
            config: config
        )

        // V0.5 自适应噪声底：只在非常慢的动作中学习“这只手 + 当前光线 + 当前距离”的
        // 实际抖动幅度。稳定手可以获得更小死区，抖动较明显时自动放大死区。
        if normalizedSpeed < 0.10 {
            let observation = min(max(magnitude, config.pointerNoiseFloorMin), config.pointerNoiseFloorMax)
            let learningRate = dragging ? 0.035 : 0.075
            pointerNoiseFloor += (observation - pointerNoiseFloor) * learningRate
            pointerNoiseFloor = min(max(pointerNoiseFloor, config.pointerNoiseFloorMin), config.pointerNoiseFloorMax)
        }

        let confidencePenalty = max(0, 0.70 - current.confidence) * 1.6
        let noiseMultiplier = 1.35 + precision * 0.95
        // 输入 FPS 越高，每帧真实位移越小，因此略缩小 per-sample dead zone；
        // FPS 降低或跟踪环境不稳定时适当放大，避免低质量关键点把指针抖散。
        let frameDeadZoneScale = sqrt(frameAdaptiveScale(config: config))
        let adaptiveDeadZone = min(
            config.pointerDeadZone * 2.65,
            max(config.pointerDeadZone * 0.56, pointerNoiseFloor * noiseMultiplier)
        ) * (1.0 + confidencePenalty) * frameDeadZoneScale * (1.0 + trackingInstability * 0.30)

        // V0.5 Precision Clutch：慢慢对准按钮后自动“抱住”当前位置。只有手指明确越过
        // 释放半径才重新移动，避免停在目标上时被关键点噪声慢慢推走。
        let anchorDelay = max(0.045, config.precisionAnchorDelay - precision * 0.025)
        let anchorRadius = config.precisionAnchorRadius * (0.82 + precision * 0.38)
        let releaseRadius = config.precisionReleaseRadius * (0.84 + precision * 0.34)

        if pointerPrecisionLatched, let ax = pointerAnchorX, let ay = pointerAnchorY {
            let fromAnchorX = (current.pointerX - ax) * distanceGain
            let fromAnchorY = (current.pointerY - ay) * distanceGain
            let fromAnchor = hypot(fromAnchorX, fromAnchorY)

            if fromAnchor < releaseRadius {
                pointerVelocityX = 0
                pointerVelocityY = 0
                lastRawPointerVelocityX = 0
                lastRawPointerVelocityY = 0
                pointerActive = true
                pointerStillSamples = max(pointerStillSamples, 2)
                resetPointerAlphaBetaLocked(x: current.pointerX, y: current.pointerY, timestamp: current.timestamp)
                lastPointerSampleTime = current.timestamp
                return
            }

            // 释放时只传递超过迟滞圈的“超额位移”，不会突然把整个圈内位移补回来。
            let excessRatio = max(0, (fromAnchor - releaseRadius) / max(fromAnchor, 0.000_001))
            dx = fromAnchorX * excessRatio
            dy = fromAnchorY * excessRatio
            magnitude = hypot(dx, dy)
            pointerPrecisionLatched = false
            pointerAnchorCandidateSince = nil
        } else if !dragging && normalizedSpeed < 0.055 && magnitude < max(anchorRadius, adaptiveDeadZone * 1.8) {
            if pointerAnchorCandidateSince == nil {
                pointerAnchorCandidateSince = current.timestamp
                pointerAnchorX = current.pointerX
                pointerAnchorY = current.pointerY
            }

            if let ax = pointerAnchorX, let ay = pointerAnchorY {
                let candidateTravel = hypot(
                    (current.pointerX - ax) * distanceGain,
                    (current.pointerY - ay) * distanceGain
                )
                // 仍在缓慢连续移动就跟随重置候选点，不把“慢移动”误认成“停住”。
                if candidateTravel > anchorRadius {
                    pointerAnchorCandidateSince = current.timestamp
                    pointerAnchorX = current.pointerX
                    pointerAnchorY = current.pointerY
                }
            }

            if let since = pointerAnchorCandidateSince,
               current.timestamp - since >= anchorDelay {
                pointerPrecisionLatched = true
                pointerAnchorX = current.pointerX
                pointerAnchorY = current.pointerY
                pointerVelocityX = 0
                pointerVelocityY = 0
                lastRawPointerVelocityX = 0
                lastRawPointerVelocityY = 0
                pointerActive = true
                pointerStillSamples = 2
                resetPointerAlphaBetaLocked(x: current.pointerX, y: current.pointerY, timestamp: current.timestamp)
                lastPointerSampleTime = current.timestamp
                return
            }
        } else {
            clearPrecisionAnchorLocked()
        }

        if magnitude < adaptiveDeadZone || normalizedSpeed < 0.023 {
            pointerStillSamples += 1
            if pointerStillSamples >= 2 {
                pointerVelocityX = 0
                pointerVelocityY = 0
                lastRawPointerVelocityX = 0
                lastRawPointerVelocityY = 0
            } else {
                pointerVelocityX *= 0.20
                pointerVelocityY *= 0.20
            }
            lastNormalizedPointerSpeed = normalizedSpeed
            pointerActive = true
            if pointerStillSamples >= 2 {
                resetPointerAlphaBetaLocked(x: current.pointerX, y: current.pointerY, timestamp: current.timestamp)
            }
            lastPointerSampleTime = current.timestamp
            return
        }

        pointerStillSamples = 0
        if abs(dx) < adaptiveDeadZone * 0.58 { dx = 0 }
        if abs(dy) < adaptiveDeadZone * 0.58 { dy = 0 }

        let response = min(max(config.responsiveness, 0), 1)
        let speedT = smoothstep(0.030, 1.15, normalizedSpeed)

        // V0.8 分段加速度 + 状态增益：微动精细、巡航线性、快速跨屏加速。
        let microT = smoothstep(0.018, 0.16, normalizedSpeed)
        let fastT = smoothstep(0.34, 1.28, normalizedSpeed)
        let accelerationGain = 0.56 + 0.42 * microT + 0.92 * pow(fastT, 1.28)
        let dragPrecisionGain = dragging ? (0.54 + 0.31 * speedT) : 1.0
        let precisionFineGain = 1.0 - (1.0 - speedT) * precision * 0.18

        // “接近目标”减速仍保留，但 V0.8 由 motion phase 再做一层刹车。
        let deceleration = max(0, lastNormalizedPointerSpeed - normalizedSpeed)
        let approachIntent = smoothstep(0.055, 0.30, deceleration)
            * smoothstep(0.16, 0.58, lastNormalizedPointerSpeed)
            * (1.0 - smoothstep(0.32, 0.78, normalizedSpeed))
        var approachGain = 1.0 - min(max(config.approachAssist, 0), 1) * 0.30 * approachIntent
        if phase == .decelerating {
            approachGain *= 1.0 - min(max(config.decelerationBrake, 0), 1) * 0.20
        }

        // 捏合进入“准备点击”阶段时主动降速，而不是等到 mouseDown 后才冻结。
        let clickPreparationGain: Double
        if phase == .clickReady {
            clickPreparationGain = 1.0 - min(max(config.clickPreparationAssist, 0), 1) * 0.42
        } else if phase == .settling {
            clickPreparationGain = 0.88
        } else {
            clickPreparationGain = 1.0
        }
        lastNormalizedPointerSpeed = normalizedSpeed

        let scaleX = 1540.0 * config.pointerSensitivity * accelerationGain * dragPrecisionGain * precisionFineGain * approachGain * clickPreparationGain
        let scaleY = 1010.0 * config.pointerSensitivity * accelerationGain * dragPrecisionGain * precisionFineGain * approachGain * clickPreparationGain

        let measuredVelocityX = (dx / dt) * scaleX
        let measuredVelocityY = -(dy / dt) * scaleY

        // V0.9 α-β 估计器对“位置 -> 速度”做另一条低噪声估计，再与瞬时速度融合。
        // 加速时偏向瞬时速度以降低迟滞；巡航/减速时增加状态估计权重以减少 jitter。
        let abVelocity = alphaBetaVelocityLocked(
            currentX: current.pointerX,
            currentY: current.pointerY,
            timestamp: current.timestamp,
            phase: phase,
            measurementTrust: softConfidenceWeight(min(current.confidence, current.pointerObservationConfidence), config: config) * recoveryTrust,
            config: config
        )
        let abPixelVX = abVelocity.0 * distanceGain * scaleX
        let abPixelVY = -abVelocity.1 * distanceGain * scaleY
        let abStrength = min(max(config.alphaBetaStrength, 0), 1)
        let abBlend: Double
        switch phase {
        case .accelerating: abBlend = 0.22 * abStrength
        case .cruising: abBlend = 0.42 * abStrength
        case .decelerating: abBlend = 0.55 * abStrength
        case .dragging: abBlend = 0.36 * abStrength
        case .settling, .clickReady, .idle: abBlend = 0
        }
        let rawVelocityX = measuredVelocityX * (1.0 - abBlend) + abPixelVX * abBlend
        let rawVelocityY = measuredVelocityY * (1.0 - abBlend) + abPixelVY * abBlend

        // V0.9 短轨迹预测：最近 4~6 帧趋势 + 实测 Vision 处理延迟。加速/巡航可前馈，
        // 减速时缩短预测，停驻/准备点击直接关闭预测。
        let targetVelocity = trajectoryPredictedVelocityLocked(
            timestamp: current.timestamp,
            rawVX: rawVelocityX,
            rawVY: rawVelocityY,
            normalizedSpeed: normalizedSpeed,
            phase: phase,
            config: config
        )
        var targetVelocityX = targetVelocity.0
        var targetVelocityY = targetVelocity.1

        // 方向连续性：低/中速时，关键点偶发反向一跳通常是噪声；
        // 真正高速折返则保留，避免手感“黏住”。
        let previousRawSpeed = hypot(lastRawPointerVelocityX, lastRawPointerVelocityY)
        let rawSpeed = hypot(rawVelocityX, rawVelocityY)
        if previousRawSpeed > 45, rawSpeed > 45 {
            let cosine = (rawVelocityX * lastRawPointerVelocityX + rawVelocityY * lastRawPointerVelocityY)
                / max(rawSpeed * previousRawSpeed, 0.000_001)
            let abruptReverse = smoothstep(0.05, 0.85, -cosine)
            let lowSpeedGate = 1.0 - smoothstep(0.48, 1.05, normalizedSpeed)
            let continuity = min(max(config.directionContinuity, 0), 1)
            let continuityGain = 1.0 - abruptReverse * lowSpeedGate * continuity * 0.62
            targetVelocityX *= continuityGain
            targetVelocityY *= continuityGain
        }
        let observationTrust = (0.22 + softConfidenceWeight(min(current.confidence, current.pointerObservationConfidence), config: config) * 0.78) * recoveryTrust
        targetVelocityX = pointerVelocityX + (targetVelocityX - pointerVelocityX) * observationTrust
        targetVelocityY = pointerVelocityY + (targetVelocityY - pointerVelocityY) * observationTrust

        lastRawPointerVelocityX = rawVelocityX
        lastRawPointerVelocityY = rawVelocityY

        // 自适应滤波：先求 30FPS 下的 base alpha，再按真实 dt 归一化时间常数。
        let softConfidence = softConfidenceWeight(min(current.confidence, current.pointerObservationConfidence), config: config)
        let confidenceFactor = softConfidence
        let dragDamping = dragging ? (0.08 * (1.0 - speedT)) : 0
        let qualityDamping = trackingInstability * 0.15
        let baseAlpha = min(
            max(0.20 + response * 0.27 + speedT * 0.38 + confidenceFactor * 0.06 - dragDamping - qualityDamping, 0.16),
            0.92
        )
        let baseTimeAlpha = timeNormalizedAlpha(baseAlpha, dt: dt, config: config)
        let alpha = min(max(baseTimeAlpha * (0.46 + softConfidence * 0.54) * (0.62 + recoveryTrust * 0.38), 0.10), 0.95)
        let maxVelocity = dragging ? 1750.0 : 2800.0
        // 先限目标速度再送入滤波器，避免单个异常预测样本短暂污染 pointerVelocity。
        targetVelocityX = min(max(targetVelocityX, -maxVelocity), maxVelocity)
        targetVelocityY = min(max(targetVelocityY, -maxVelocity), maxVelocity)
        pointerVelocityX += (targetVelocityX - pointerVelocityX) * alpha
        pointerVelocityY += (targetVelocityY - pointerVelocityY) * alpha
        pointerVelocityX = min(max(pointerVelocityX, -maxVelocity), maxVelocity)
        pointerVelocityY = min(max(pointerVelocityY, -maxVelocity), maxVelocity)
        pointerActive = true
        lastPointerSampleTime = current.timestamp
    }

    // MARK: - Scroll

    private func updateScrollMotionLocked(
        current: TrackpadSample,
        previous: TrackpadSample,
        dt: TimeInterval,
        config: Configuration
    ) {
        let distanceGain = distanceCompensationGainLocked(sample: current, config: config)
        let recoveryTrust = consumeScrollRecoveryTrustLocked(config: config)
        var dx = (current.scrollX - previous.scrollX) * distanceGain
        var dy = (current.scrollY - previous.scrollY) * distanceGain
        let rawDX = dx
        let rawDY = dy
        let movement = hypot(dx, dy)

        guard movement < 0.18 else {
            scrollActive = true
            lastScrollSampleTime = current.timestamp
            return
        }

        // 类似真实触控板的“接触起步”：先跨过极小阈值，再平滑接管页面。
        // 这样双指刚摆好时的 Vision 抖动不会让页面先轻轻跳一下。
        if !scrollEngaged {
            scrollStartTravel += movement
            scrollActive = true
            lastScrollSampleTime = current.timestamp
            scrollVelocityX = 0
            scrollVelocityY = 0
            if scrollContactSince <= 0 { scrollContactSince = current.timestamp }
            let contactAge = current.timestamp - scrollContactSince
            if scrollStartTravel < config.scrollStartThreshold || contactAge < max(config.scrollContactDebounce, 0) {
                return
            }
            scrollEngaged = true
            scrollEngagedAt = current.timestamp
            zoomSuppressedForContact = true
            zoomIntentActive = false
            zoomAccumulator = 0
            zoomIntentDirection = 0
            zoomIntentFrames = 0
            scrollAccumulatedX = 0
            scrollAccumulatedY = 0
            if scrollMotionPhase != .tracking {
                scrollMotionPhase = .tracking
                pendingScrollMotionPhase = .tracking
            }
        }

        scrollAccumulatedX += abs(dx)
        scrollAccumulatedY += abs(dy)

        if scrollAxisLock == .none,
           scrollAccumulatedX + scrollAccumulatedY >= 0.010 {
            if scrollAccumulatedX > scrollAccumulatedY * config.scrollAxisLockRatio {
                scrollAxisLock = .horizontal
            } else if scrollAccumulatedY > scrollAccumulatedX * config.scrollAxisLockRatio {
                scrollAxisLock = .vertical
            }
        }

        // 已锁轴后允许用户明确改变方向时“重锁”，避免一次滚动全程被错误方向绑死。
        switch scrollAxisLock {
        case .horizontal:
            if abs(dy) > abs(dx) * 1.45 {
                scrollAxisLock = .vertical
                scrollAccumulatedX = 0
                scrollAccumulatedY = 0
            } else {
                let dominance = abs(dx) / max(abs(dy), 0.000_01)
                let secondaryGain = 0.08 + 0.30 * (1.0 - smoothstep(1.3, 3.2, dominance))
                dy *= secondaryGain
            }
        case .vertical:
            if abs(dx) > abs(dy) * 1.45 {
                scrollAxisLock = .horizontal
                scrollAccumulatedX = 0
                scrollAccumulatedY = 0
            } else {
                let dominance = abs(dy) / max(abs(dx), 0.000_01)
                let secondaryGain = 0.08 + 0.30 * (1.0 - smoothstep(1.3, 3.2, dominance))
                dx *= secondaryGain
            }
        case .none:
            break
        }

        // V1.2：一次滚动笔画确认方向后，反方向位移视为“空中重定位”并立即吞掉；
        // 只有回到宽松的主轴回中区域并短暂停稳才重新武装；横向偏移不参与回中判定。
        if shouldSuppressScrollRetractionLocked(
            current: current,
            rawDX: rawDX,
            rawDY: rawDY,
            dt: dt,
            config: config
        ) {
            scrollActive = true
            lastScrollSampleTime = current.timestamp
            return
        }

        let normalizedSpeed = hypot(dx, dy) / dt
        let scrollDeadZone = config.scrollDeadZone
            * sqrt(frameAdaptiveScale(config: config))
            * (1.0 + trackingInstability * 0.26)
        if movement < scrollDeadZone || normalizedSpeed < 0.022 {
            scrollStillSamples += 1
            if scrollStillSamples >= 2 {
                // 双指还贴着但已经停住：直接操控阶段快速停下；惯性只在抬手以后出现。
                scrollVelocityX *= 0.14
                scrollVelocityY *= 0.14
                if abs(scrollVelocityX) < 14 { scrollVelocityX = 0 }
                if abs(scrollVelocityY) < 14 { scrollVelocityY = 0 }
                // 已经明确停住，不让旧的高速样本在稍后抬手时重新制造惯性。
                scrollVelocityHistory.removeAll(keepingCapacity: true)
            }
            scrollActive = true
            lastScrollSampleTime = current.timestamp
            return
        }

        scrollStillSamples = 0
        let response = min(max(config.responsiveness, 0), 1)
        let speedT = smoothstep(0.022, 0.90, normalizedSpeed)
        let pixelsPerNormalizedUnit = 1180.0 * config.scrollSensitivity

        var targetVX = (dx / dt) * pixelsPerNormalizedUnit
        var targetVY = (dy / dt) * pixelsPerNormalizedUnit

        // V0.6 连续滚动加速度：
        // - 慢速双指移动降低增益，便于网页/PDF 一两行地精细滚；
        // - 快速 flick 提升增益，但用 smoothstep 保证中间没有台阶感。
        let accelerationStrength = min(max(config.scrollAccelerationStrength, 0), 1)
        let fineGain = 0.66 + (1.0 - accelerationStrength) * 0.12
        let fastGain = 1.18 + accelerationStrength * 0.58
        let scrollGain = fineGain + (fastGain - fineGain) * pow(speedT, 1.18)
        targetVX *= scrollGain
        targetVY *= scrollGain

        if config.naturalScrolling {
            // 内容跟随双指移动，语义与 macOS “自然滚动”一致。
            targetVX = -targetVX
            targetVY = -targetVY
        }

        // 起步阶段 0 -> 1 平滑增益，消除“越过阈值后突然蹿一下”。
        let rampAge = max(0, current.timestamp - scrollEngagedAt)
        let ramp = smoothstep(0, max(config.scrollRampDuration, 0.001), rampAge)
        targetVX *= ramp
        targetVY *= ramp

        // V1.0 soft confidence：低置信度时不丢帧，而是让新观测只轻量修正当前速度。
        let scrollObservationTrust = (0.24 + softConfidenceWeight(min(current.confidence, current.scrollObservationConfidence), config: config) * 0.76) * recoveryTrust
        targetVX = scrollVelocityX + (targetVX - scrollVelocityX) * scrollObservationTrust
        targetVY = scrollVelocityY + (targetVY - scrollVelocityY) * scrollObservationTrust

        // 双指滚动比指针略平滑；同样使用真实输入 dt 归一化，帧率波动时不会忽黏忽快。
        let baseScrollAlpha = min(
            max(0.28 + response * 0.18 + speedT * 0.35 - trackingInstability * 0.10, 0.24),
            0.84
        )
        let scrollTimeAlpha = timeNormalizedAlpha(baseScrollAlpha, dt: dt, config: config)
        let confidenceAlpha = 0.50 + softConfidenceWeight(min(current.confidence, current.scrollObservationConfidence), config: config) * 0.50
        let alpha = min(max(scrollTimeAlpha * confidenceAlpha * (0.64 + recoveryTrust * 0.36), 0.14), 0.90)
        scrollVelocityX += (targetVX - scrollVelocityX) * alpha
        scrollVelocityY += (targetVY - scrollVelocityY) * alpha

        let maxVelocity = 2950.0
        scrollVelocityX = min(max(scrollVelocityX, -maxVelocity), maxVelocity)
        scrollVelocityY = min(max(scrollVelocityY, -maxVelocity), maxVelocity)
        appendScrollVelocityHistoryLocked(
            timestamp: current.timestamp,
            x: scrollVelocityX,
            y: scrollVelocityY,
            window: config.scrollReleaseWindow
        )
        scrollActive = true
        lastScrollSampleTime = current.timestamp
    }

    private func appendScrollVelocityHistoryLocked(
        timestamp: TimeInterval,
        x: Double,
        y: Double,
        window: Double
    ) {
        guard x.isFinite, y.isFinite else { return }
        scrollVelocityHistory.append(VelocitySample(timestamp: timestamp, x: x, y: y))
        let cutoff = timestamp - max(window, 0.06)
        scrollVelocityHistory.removeAll { $0.timestamp < cutoff }
        if scrollVelocityHistory.count > 12 {
            scrollVelocityHistory.removeFirst(scrollVelocityHistory.count - 12)
        }
    }

    /// 用最近一小段直接操控速度估算“抬指瞬间速度”。比直接拿最后一帧稳定：
    /// 最后一帧往往已经因为 Vision 丢点、手指开始收回或滤波而变慢。
    private func prepareScrollReleaseLocked(timestamp: TimeInterval) {
        let window = max(configuration.scrollReleaseWindow, 0.06)
        let samples = scrollVelocityHistory.filter { timestamp - $0.timestamp <= window }
        guard !samples.isEmpty else { return }

        var totalWeight = 0.0
        var vx = 0.0
        var vy = 0.0
        for sample in samples {
            let age = max(0, timestamp - sample.timestamp)
            let freshness = max(0.08, 1.0 - age / window)
            let speed = hypot(sample.x, sample.y)
            let motionWeight = 0.45 + min(speed / 1400.0, 1.0) * 0.55
            let weight = freshness * freshness * motionWeight
            vx += sample.x * weight
            vy += sample.y * weight
            totalWeight += weight
        }
        guard totalWeight > 0 else { return }
        vx /= totalWeight
        vy /= totalWeight

        // 只有确实存在 flick 动量时才采用历史速度；慢慢放手则保持接近静止。
        let releaseSpeed = hypot(vx, vy)
        if releaseSpeed >= 70 {
            scrollVelocityX = scrollVelocityX * 0.30 + vx * 0.70
            scrollVelocityY = scrollVelocityY * 0.30 + vy * 0.70
        }
        scrollVelocityHistory.removeAll(keepingCapacity: true)
    }

    private func clearPrecisionAnchorLocked() {
        pointerAnchorX = nil
        pointerAnchorY = nil
        pointerAnchorCandidateSince = nil
        pointerPrecisionLatched = false
    }

    private func cancelScrollLocked() {
        scrollActive = false
        scrollVelocityX = 0
        scrollVelocityY = 0
        scrollStillSamples = 0
        scrollStartTravel = 0
        scrollEngaged = false
        scrollEngagedAt = 0
        scrollContactSince = 0
        if scrollMotionPhase != .idle {
            scrollMotionPhase = .idle
            pendingScrollMotionPhase = .idle
        }
        scrollVelocityHistory.removeAll(keepingCapacity: true)
        resetScrollAxisLockLocked()
        resetScrollRetractionLocked()
        zoomAccumulator = 0
        zoomSuppressedForContact = false
        zoomIntentActive = false
        zoomIntentDirection = 0
        zoomIntentFrames = 0
        zoomCenterTravel = 0
    }

    /// V1.2：单向滚动笔画锁（stroke-direction latch）。
    ///
    /// 摄像头手势没有真实触控板的“抬起再回到起点”。这里把一次连续滚动拆成单向笔画：
    /// - 主轴和方向一旦建立，同一笔画里的反方向位移全部视为重定位，不输出；
    /// - 即使在主笔画末端停顿，也不会误把稍后的收手当成反向滚动；
    /// - 只有回收到“起始轴向区域”并停稳，或两指姿势真正释放/辅助手离合，才重新武装；
    /// - 判定只看主轴投影，不要求手沿原路径精确返回，所以横向偏差不会造成误差。
    private func shouldSuppressScrollRetractionLocked(
        current: TrackpadSample,
        rawDX: Double,
        rawDY: Double,
        dt: TimeInterval,
        config: Configuration
    ) -> Bool {
        guard config.scrollRetractionSuppressionEnabled, scrollEngaged, dt > 0 else {
            return false
        }

        if scrollContactOriginX == nil || scrollContactOriginY == nil {
            scrollContactOriginX = current.scrollX
            scrollContactOriginY = current.scrollY
        }

        if scrollStrokeAxis == .none {
            switch scrollAxisLock {
            case .horizontal:
                scrollStrokeAxis = .horizontal
            case .vertical:
                scrollStrokeAxis = .vertical
            case .none:
                let primaryMagnitude = max(abs(rawDX), abs(rawDY))
                if primaryMagnitude >= max(config.scrollRetractionOppositeDelta * 1.4, 0.0010) {
                    scrollStrokeAxis = abs(rawDX) > abs(rawDY) ? .horizontal : .vertical
                }
            }
        }

        guard scrollStrokeAxis != .none else { return false }

        let originX = scrollContactOriginX ?? current.scrollX
        let originY = scrollContactOriginY ?? current.scrollY
        let primaryDelta: Double
        let axisDisplacement: Double
        switch scrollStrokeAxis {
        case .horizontal:
            primaryDelta = rawDX
            axisDisplacement = current.scrollX - originX
        case .vertical:
            primaryDelta = rawDY
            axisDisplacement = current.scrollY - originY
        case .none:
            return false
        }

        let deltaThreshold = max(config.scrollRetractionOppositeDelta, config.scrollDeadZone * 0.60)
        let speed = hypot(rawDX, rawDY) / max(dt, 0.001)

        if scrollStrokeDirection == 0 {
            let armTravel = max(config.scrollRetractionArmTravel, 0.006)
            if abs(axisDisplacement) >= armTravel || abs(primaryDelta) >= deltaThreshold * 1.35 {
                scrollStrokeDirection = axisDisplacement != 0
                    ? (axisDisplacement >= 0 ? 1 : -1)
                    : (primaryDelta >= 0 ? 1 : -1)
                scrollStrokePeakTravel = max(abs(axisDisplacement), armTravel)
                scrollRetractionSuppressed = false
                scrollRetractionNeutralSince = nil
            }
            return false
        }

        let directedDelta = primaryDelta * scrollStrokeDirection
        let directedDisplacement = axisDisplacement * scrollStrokeDirection
        scrollStrokePeakTravel = max(scrollStrokePeakTravel, directedDisplacement)
        let opposite = directedDelta < -deltaThreshold

        if opposite {
            // Swallow the very first reverse sample so the page never visibly bounces before the
            // state machine has time to classify the motion as hand re-centering.
            scrollRetractionSuppressed = true
            scrollRetractionCandidateFrames += 1
            scrollRetractionNeutralSince = nil
            scrollVelocityX = 0
            scrollVelocityY = 0
            scrollVelocityHistory.removeAll(keepingCapacity: true)
            scrollStillSamples = 0
            return true
        }

        if scrollRetractionSuppressed {
            scrollVelocityX = 0
            scrollVelocityY = 0
            scrollVelocityHistory.removeAll(keepingCapacity: true)

            // Broad axial re-center zone: return need not be geometrically exact. Lateral drift is
            // ignored completely and the allowed axial error scales with the stroke length.
            let rearmZone = max(0.006, scrollStrokePeakTravel * 0.30)
            let nearRecenter = directedDisplacement <= rearmZone
            if nearRecenter, speed <= max(config.scrollRetractionNeutralSpeed, 0.025) {
                if scrollRetractionNeutralSince == nil {
                    scrollRetractionNeutralSince = current.timestamp
                }
                if let neutralSince = scrollRetractionNeutralSince,
                   current.timestamp - neutralSince >= max(config.scrollRetractionNeutralHold, 0.045) {
                    rearmScrollStrokeLocked(at: current)
                }
            } else {
                scrollRetractionNeutralSince = nil
            }
            return true
        }

        // Same-direction movement keeps the current stroke live. A pause at the far end does NOT
        // rearm: otherwise a normal “pause then return hand” would become a false reverse scroll.
        if directedDelta > deltaThreshold {
            scrollRetractionCandidateFrames = 0
            scrollRetractionNeutralSince = nil
        }
        return false
    }

    private func rearmScrollStrokeLocked(at sample: TrackpadSample) {
        scrollContactOriginX = sample.scrollX
        scrollContactOriginY = sample.scrollY
        scrollStrokeAxis = .none
        scrollStrokeDirection = 0
        scrollStrokePeakTravel = 0
        scrollRetractionSuppressed = false
        scrollRetractionCandidateFrames = 0
        scrollRetractionNeutralSince = nil
        scrollRetractionReverseFrames = 0
        scrollStartTravel = 0
        scrollEngagedAt = sample.timestamp
    }

    private func resetScrollRetractionLocked(originX: Double? = nil, originY: Double? = nil) {
        scrollContactOriginX = originX
        scrollContactOriginY = originY
        scrollStrokeAxis = .none
        scrollStrokeDirection = 0
        scrollStrokePeakTravel = 0
        scrollRetractionSuppressed = false
        scrollRetractionCandidateFrames = 0
        scrollRetractionNeutralSince = nil
        scrollRetractionReverseFrames = 0
    }

    private func resetScrollAxisLockLocked() {
        scrollAxisLock = .none
        scrollAccumulatedX = 0
        scrollAccumulatedY = 0
    }

    /// 自动学习用户把手放在“舒服位置”时的手掌尺度。只在一指、低速、高置信度、非拖拽时
    /// 累积，避免把快速动作或捏合造成的形变当成工作距离。完成后由 AppController 持久化。
    private func updatePersonalCalibrationLocked(
        sample: TrackpadSample,
        normalizedSpeed: Double,
        dragging: Bool,
        config: Configuration
    ) {
        if let baseline = configuration.personalPalmScale ?? config.personalPalmScale {
            if lastPublishedCalibrationProgress < 1 {
                lastPublishedCalibrationProgress = 1
                pendingCalibrationUpdate = (1, baseline)
            }
            return
        }

        guard !dragging,
              normalizedSpeed < 0.085,
              sample.confidence >= 0.62,
              let rawScale = sample.palmScale,
              rawScale.isFinite,
              rawScale >= 0.060, rawScale <= 0.28 else { return }

        let clamped = min(max(rawScale, 0.060), 0.28)
        if let candidate = calibrationCandidateScale {
            // 稳定窗口用较低 alpha，避免一两帧关节抖动污染个人基线。
            calibrationCandidateScale = candidate + (clamped - candidate) * 0.085
        } else {
            calibrationCandidateScale = clamped
        }
        calibrationStableSamples += 1

        let required = max(config.calibrationRequiredStableSamples, 12)
        let progress = min(Double(calibrationStableSamples) / Double(required), 1.0)
        if progress - lastPublishedCalibrationProgress >= 0.08 || progress >= 1 {
            lastPublishedCalibrationProgress = progress
            pendingCalibrationUpdate = (progress, nil)
        }

        if calibrationStableSamples >= required, let baseline = calibrationCandidateScale {
            configuration.personalPalmScale = baseline
            lastPublishedCalibrationProgress = 1
            pendingCalibrationUpdate = (1, baseline)
        }
    }

    /// 将当前手掌尺寸平滑后转换成距离增益。V0.6 优先使用个人标定尺度；未完成标定前
    /// 才退回固定 nominalPalmScale。小手掌通常意味着离摄像头更远，需要放大位移。
    private func distanceCompensationGainLocked(sample: TrackpadSample, config: Configuration) -> Double {
        guard let rawScale = sample.palmScale, rawScale.isFinite, rawScale > 0.025 else { return 1.0 }
        let clampedScale = min(max(rawScale, 0.055), 0.30)
        if let current = smoothedPalmScale {
            // 距离变化本身应缓慢，不让单帧尺寸噪声变成速度抖动。
            smoothedPalmScale = current + (clampedScale - current) * 0.12
        } else {
            smoothedPalmScale = clampedScale
        }
        guard let scale = smoothedPalmScale else { return 1.0 }
        let nominal = configuration.personalPalmScale ?? config.personalPalmScale ?? config.nominalPalmScale
        let rawGain = nominal / scale
        let gain = min(max(rawGain, config.minimumDistanceGain), config.maximumDistanceGain)
        lastDistanceGain = gain
        return gain
    }

    // MARK: - Adaptive timing / tracking quality

    private func updateTrackingTimingLocked(
        sample: TrackpadSample,
        dt: TimeInterval,
        config: Configuration
    ) {
        let nominalFPS = min(max(config.nominalInputFPS, 15), 60)
        let nominalDT = 1.0 / nominalFPS

        if dt > 0.010, dt < 0.20 {
            let clampedDT = min(max(dt, 1.0 / 75.0), 1.0 / 10.0)
            let previousInterval = sampleIntervalEMA
            sampleIntervalEMA += (clampedDT - sampleIntervalEMA) * 0.12
            let normalizedJitter = abs(clampedDT - previousInterval) / max(previousInterval, 0.001)
            sampleJitterEMA += (normalizedJitter - sampleJitterEMA) * 0.10
        } else if sampleIntervalEMA <= 0 {
            sampleIntervalEMA = nominalDT
        }

        if sample.processingLatency.isFinite, sample.processingLatency >= 0, sample.processingLatency < 0.25 {
            let clampedLatency = min(max(sample.processingLatency, 0.001), 0.12)
            processingLatencyEMA += (clampedLatency - processingLatencyEMA) * 0.12
        }

        confidenceEMA += (sample.confidence - confidenceEMA) * 0.10
        let fps = min(max(1.0 / max(sampleIntervalEMA, 0.001), 1), 120)
        let lowFPSPenalty = max(0, nominalFPS - fps) / nominalFPS
        let confidencePenalty = max(0, 0.78 - confidenceEMA) / 0.38
        let jitterPenalty = min(sampleJitterEMA / 0.28, 1.0)
        let noisePenalty = min(
            max((pointerNoiseFloor - config.pointerNoiseFloorMin) / max(config.pointerNoiseFloorMax - config.pointerNoiseFloorMin, 0.000_001), 0),
            1
        )
        let targetInstability = min(
            max(confidencePenalty * 0.42 + jitterPenalty * 0.28 + lowFPSPenalty * 0.18 + noisePenalty * 0.12, 0),
            1
        )
        trackingInstability += (targetInstability - trackingInstability) * 0.09

        if sample.timestamp - lastTelemetryPublishTime >= 0.25 {
            lastTelemetryPublishTime = sample.timestamp
            let stability = min(max(1.0 - trackingInstability, 0), 1)
            pendingTelemetry = (fps, stability, lastDistanceGain, processingLatencyEMA)
        }
    }

    /// 将“每个 Vision 样本”的滤波 alpha 转换成时间常数近似不变的 alpha。
    /// 20FPS / 30FPS / 45FPS 时，单位时间响应接近一致。
    private func timeNormalizedAlpha(_ baseAlpha: Double, dt: TimeInterval, config: Configuration) -> Double {
        let clampedBase = min(max(baseAlpha, 0.001), 0.995)
        guard config.adaptiveTiming else { return clampedBase }
        let nominalDT = 1.0 / min(max(config.nominalInputFPS, 15), 60)
        let exponent = min(max(dt / nominalDT, 0.35), 2.5)
        return 1.0 - pow(1.0 - clampedBase, exponent)
    }

    private func frameAdaptiveScale(config: Configuration) -> Double {
        guard config.adaptiveTiming else { return 1.0 }
        let nominalDT = 1.0 / min(max(config.nominalInputFPS, 15), 60)
        return min(max(sampleIntervalEMA / nominalDT, 0.60), 1.65)
    }

    // MARK: - 120Hz motion output

    private func tickMotion() {
        let now = ProcessInfo.processInfo.systemUptime
        var pointerDeltaX = 0.0
        var pointerDeltaY = 0.0
        var scrollDeltaX = 0.0
        var scrollDeltaY = 0.0
        var scrollPhaseUpdate: ScrollMotionPhase?

        lock.lock()
        let dt = min(max(now - lastTickTime, 0.004), 0.025)
        lastTickTime = now

        // V1.0 continuity hold：短时没有新 Vision 观测时，不立刻把 120Hz 输出切断。
        let adaptiveContinuityHold = min(
            max(configuration.continuityHoldDuration, sampleIntervalEMA * 3.8),
            0.24
        )
        let sinceValidObservation = lastValidObservationTime > 0 ? max(0, now - lastValidObservationTime) : .infinity
        let continuityHolding = dropoutStartedAt != nil && sinceValidObservation <= adaptiveContinuityHold
        let continuityFade = continuityHolding
            ? smoothstep(configuration.continuityFadeStart, adaptiveContinuityHold, sinceValidObservation)
            : 0

        // Pointer: 样本间保持速度，相当于对 Vision 的离散采样做预测/插值。
        // 超过 timeout 仍没有新样本时快速刹停，指针不做“惯性滑行”。
        if pointerActive {
            let age = now - lastPointerSampleTime
            if continuityHolding {
                // 前几十毫秒几乎无感续接；随着 hold 变长逐渐刹车，避免“预测漂移”。
                let friction = 0.65 + continuityFade * 8.0
                let brake = exp(-friction * dt)
                pointerVelocityX *= brake
                pointerVelocityY *= brake
            } else {
                let adaptivePointerTimeout = max(
                    configuration.pointerSampleTimeout,
                    min(sampleIntervalEMA * 2.25, 0.155)
                )
                if age > adaptivePointerTimeout {
                    let brake = pow(0.20, dt * 120.0)
                    pointerVelocityX *= brake
                    pointerVelocityY *= brake
                }
                if age > adaptivePointerTimeout + 0.065 {
                    pointerVelocityX = 0
                    pointerVelocityY = 0
                    pointerActive = false
                }
            }
        }

        // V0.8 状态相关 120Hz 刹车：Vision 两帧之间仍会输出插值，因此在“减速/停驻/准备点击”
        // 阶段主动收掉残余速度，避免滤波尾巴把指针推过目标。
        switch pointerMotionPhase {
        case .clickReady:
            let brake = exp(-20.0 * dt)
            pointerVelocityX *= brake
            pointerVelocityY *= brake
        case .settling:
            let brake = exp(-15.0 * dt)
            pointerVelocityX *= brake
            pointerVelocityY *= brake
        case .decelerating:
            let brake = exp(-3.6 * min(max(configuration.decelerationBrake, 0), 1) * dt)
            pointerVelocityX *= brake
            pointerVelocityY *= brake
        case .idle:
            pointerVelocityX *= exp(-22.0 * dt)
            pointerVelocityY *= exp(-22.0 * dt)
        case .accelerating, .cruising, .dragging:
            break
        }

        if pointerActive || abs(pointerVelocityX) > 1 || abs(pointerVelocityY) > 1 {
            pointerDeltaX = pointerVelocityX * dt
            pointerDeltaY = pointerVelocityY * dt
            // 120Hz 每 tick 限幅，既防跳点，又允许快速跨屏。
            pointerDeltaX = min(max(pointerDeltaX, -21), 21)
            pointerDeltaY = min(max(pointerDeltaY, -21), 21)
        }

        // Scroll: 双指仍在时持续直接操控；抬手/丢帧后才进入惯性。
        let adaptiveScrollTimeout = max(0.11, min(sampleIntervalEMA * 2.45, 0.18))
        if scrollActive, continuityHolding {
            // 观测短缺时仍保持“手指未抬起”的语义，但逐渐收速；不要提前误进入 coasting。
            let brake = exp(-(0.55 + continuityFade * 6.5) * dt)
            scrollVelocityX *= brake
            scrollVelocityY *= brake
        } else if scrollActive && now - lastScrollSampleTime > adaptiveScrollTimeout {
            if scrollMotionPhase == .tracking {
                prepareScrollReleaseLocked(timestamp: now)
            }
            scrollActive = false
            let next: ScrollMotionPhase = hypot(scrollVelocityX, scrollVelocityY) >= 70 ? .coasting : .idle
            if scrollMotionPhase != next {
                scrollMotionPhase = next
                scrollPhaseUpdate = next
            }
        }

        if !scrollActive {
            let inertia = min(max(configuration.inertia, 0), 1)
            let speed = hypot(scrollVelocityX, scrollVelocityY)
            let speedT = min(speed / 1700.0, 1.0)

            // V0.7 连续时间摩擦模型：和 120Hz timer 偶发抖动解耦。
            // 高速 flick 摩擦较小；进入尾速后增加摩擦并附加轻微线性刹车，避免“拖长尾巴”。
            let highSpeedFriction = 1.35 + (1.0 - inertia) * 2.10
            let lowSpeedExtra = (1.0 - speedT) * (2.20 + (1.0 - inertia) * 1.30)
            let frictionPerSecond = highSpeedFriction + lowSpeedExtra
            let decay = exp(-frictionPerSecond * dt)
            scrollVelocityX *= decay
            scrollVelocityY *= decay

            if speed < 260, speed > 0 {
                let linearBrake = (72.0 + (1.0 - inertia) * 110.0) * dt
                let newSpeed = max(0, speed - linearBrake)
                let ratio = newSpeed / speed
                scrollVelocityX *= ratio
                scrollVelocityY *= ratio
            }
        }

        if abs(scrollVelocityX) < 4 { scrollVelocityX = 0 }
        if abs(scrollVelocityY) < 4 { scrollVelocityY = 0 }
        if !scrollActive, scrollMotionPhase == .coasting, hypot(scrollVelocityX, scrollVelocityY) < 8 {
            scrollMotionPhase = .idle
            scrollPhaseUpdate = .idle
        }

        scrollDeltaX = scrollVelocityX * dt
        scrollDeltaY = scrollVelocityY * dt
        scrollDeltaX = min(max(scrollDeltaX, -22), 22)
        scrollDeltaY = min(max(scrollDeltaY, -22), 22)
        lock.unlock()

        if let scrollPhaseUpdate {
            DispatchQueue.main.async { [weak self] in
                self?.onScrollMotionPhaseChanged?(scrollPhaseUpdate)
            }
        }
        if abs(pointerDeltaX) >= 0.008 || abs(pointerDeltaY) >= 0.008 {
            onPointerDelta?(pointerDeltaX, pointerDeltaY)
        }
        // Do not discard low-speed 120Hz scroll deltas. TrackpadController already accumulates
        // fractional pixels, so forwarding tiny deltas preserves micro-scroll continuity instead
        // of creating a speed-dependent dead band.
        if abs(scrollDeltaX) >= 0.010 || abs(scrollDeltaY) >= 0.010 {
            onScrollDelta?(scrollDeltaX, scrollDeltaY)
        }
    }

    private func softConfidenceWeight(_ confidence: Double, config: Configuration) -> Double {
        smoothstep(
            min(max(config.minimumConfidence, 0.05), 0.60),
            min(max(config.softConfidenceFullTrust, config.minimumConfidence + 0.05), 0.95),
            confidence
        )
    }

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let x = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return x * x * (3 - 2 * x)
    }

    private func setInteraction(_ newValue: TrackpadInteraction) {
        lock.lock()
        if interaction == newValue {
            lock.unlock()
            return
        }
        interaction = newValue
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onInteractionChanged?(newValue)
        }
    }
}
