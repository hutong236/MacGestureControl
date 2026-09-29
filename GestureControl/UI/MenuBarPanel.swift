import SwiftUI
import Foundation

struct MenuBarPanel: View {
    @ObservedObject var controller: AppController
    @State private var newGestureName = ""
    @State private var newGestureAction: KeyActionPreset = .space
    @State private var showPreview = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                controlSection
                permissionSection
                Divider()
                modeSection
                Divider()

                if controller.controlMode == .trackpad {
                    trackpadSection
                } else {
                    gestureSection
                    Divider()
                    customGestureSection
                    Divider()
                    pageTuningSection
                }

                if showPreview {
                    CameraPreviewView(session: controller.camera.session)
                        .frame(height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(controller.handDetected ? "手部已检测 · \(controller.detectedHandCount) 只" : "等待手部")
                                if controller.bimanualClutchActive {
                                    Text("双手离合：重定位中")
                                }
                                if let pattern = controller.currentFingerPattern {
                                    Text(pattern.shortDescription)
                                }
                            }
                            .font(.caption2)
                            .padding(6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                        }
                }

                if let error = controller.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button(showPreview ? "隐藏预览" : "摄像头预览") {
                        showPreview.toggle()
                    }
                    .disabled(!controller.cameraPermission)

                    Spacer()

                    Button("退出") {
                        controller.quit()
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 440, height: 790)
        .onAppear {
            controller.refreshPermissions()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: controller.isRunning ? "hand.raised.fill" : "hand.raised")
                .font(.system(size: 28))
            VStack(alignment: .leading, spacing: 2) {
                Text("Gesture Control")
                    .font(.headline)
                Text(controller.camera.cameraName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Circle()
                    .fill(controller.handDetected ? Color.green : Color.gray.opacity(0.35))
                    .frame(width: 10, height: 10)
                Text("V\(Bundle.main.object(forInfoDictionaryKey: \"CFBundleShortVersionString\") as? String ?? \"1.2\")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("启用手势控制", isOn: Binding(
                get: { controller.isRunning },
                set: { controller.toggleRunning($0) }
            ))

            HStack {
                Image(systemName: controller.controlMode == .trackpad ? "rectangle.and.hand.point.up.left" : "arrow.left.arrow.right")
                Text(controller.lastActionText.isEmpty ? "等待手势" : controller.lastActionText)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.caption)
        }
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            permissionRow(
                title: "摄像头",
                granted: controller.cameraPermission,
                actionTitle: controller.cameraPermission ? nil : "打开设置",
                action: controller.openCameraSettings
            )
            inputControlPermissionRow
        }
    }

    private var inputControlPermissionRow: some View {
        HStack {
            switch controller.inputControlState {
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                Text("辅助功能")
                Spacer()
                Text("已授权")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .restartRequired:
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(Color.orange)
                Text("辅助功能")
                Spacer()
                Text("已开启 · 需重启")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("立即重启") {
                    controller.relaunchForPermission()
                }
                .controlSize(.small)

            case .notGranted:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
                Text("辅助功能")
                Spacer()
                Text("未授权")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("授权") {
                    controller.requestAccessibility()
                }
                .controlSize(.small)
            }
        }
        .font(.caption)
    }

    private func permissionRow(
        title: String,
        granted: Bool,
        actionTitle: String?,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            Text(title)
            Spacer()
            Text(granted ? "已授权" : "未授权")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .font(.caption)
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("控制模式")
                .font(.subheadline.weight(.semibold))

            Picker("控制模式", selection: $controller.controlMode) {
                ForEach(ControlMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(controller.controlMode == .trackpad
                 ? "把摄像头前的手当作一块空中触控板，移动、滚动、拖拽和系统手势连续响应。"
                 : "保留原来的方向挥手 → 单次按键，适合 Keynote / PowerPoint 翻页。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var trackpadSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("空中触控板")
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 7) {
                trackpadGuideRow("hand.point.up.left", "一根食指", "移动鼠标指针")
                trackpadGuideRow("hand.pinch", "拇指 + 食指捏合", "按下 / 拖拽，松开即释放")
                trackpadGuideRow("hand.raised.fingers.spread", "食指 + 中指", "连续双向滚动，松手后带惯性")
                trackpadGuideRow("arrow.up.left.and.arrow.down.right", "双指张开 / 合拢", "放大 / 缩小")
                trackpadGuideRow("square.3.layers.3d", "三/四指左右滑", "切换桌面 / 全屏空间")
                trackpadGuideRow("rectangle.3.group", "三/四指上 / 下滑", "Mission Control / App Exposé")
                trackpadGuideRow("hand.raised.fill", "辅助手张开", "离合：主手自由回位，不产生任何页面/指针位移")
                trackpadGuideRow("hand.tap", "辅助手捏合", "右键点击")
            }
            .padding(10)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Text("跟手响应")
                    .frame(width: 68, alignment: .leading)
                Slider(value: $controller.trackingResponsiveness, in: 0...1)
                Text(String(format: "%.0f%%", controller.trackingResponsiveness * 100))
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }


            HStack {
                Text("精细稳定")
                    .frame(width: 68, alignment: .leading)
                Slider(value: $controller.precisionAssist, in: 0...1)
                Text(String(format: "%.0f%%", controller.precisionAssist * 100))
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
            HStack {
                Text("指针速度")
                    .frame(width: 68, alignment: .leading)
                Slider(value: $controller.pointerSensitivity, in: 0.35...2.5)
                Text(String(format: "%.2fx", controller.pointerSensitivity))
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }

            HStack {
                Text("滚动速度")
                    .frame(width: 68, alignment: .leading)
                Slider(value: $controller.scrollSensitivity, in: 0.35...2.5)
                Text(String(format: "%.2fx", controller.scrollSensitivity))
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }

            HStack {
                Text("滚动惯性")
                    .frame(width: 68, alignment: .leading)
                Slider(value: $controller.scrollInertia, in: 0...1)
                Text(String(format: "%.0f%%", controller.scrollInertia * 100))
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }

            Toggle("自然滚动（内容跟随手移动）", isOn: $controller.naturalScrolling)
            Toggle("单向滚动笔画锁（推荐）", isOn: $controller.scrollRetractionSuppressionEnabled)
            Text("一次滚动确认方向后，反向收手只作为重定位，不产生反向页面位移；回到宽松的主轴回中区域并停稳约 65ms 后重新武装。也可短暂放松双指姿势，相当于触控板“抬指”。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Toggle("双手辅助（离合 + 右键）", isOn: $controller.bimanualAssistEnabled)
            Text(controller.bimanualClutchActive
                 ? "辅助手张开：离合已按住，主手可自由回到舒适位置。"
                 : "第二只手张开可临时冻结并重定位主手；第二只手主动捏合执行右键。")
                .font(.caption2)
                .foregroundStyle(controller.bimanualClutchActive ? Color.orange : Color.secondary)
            Toggle("双指张合缩放（实验性）", isOn: $controller.twoFingerZoomEnabled)
            Text("默认关闭：双指上下/左右移动只滚动，不再误触页面 ⌘+ / ⌘- 缩放。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("当前：\(controller.trackpadInteraction.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundStyle(.secondary)
                    Text("动态跟踪")
                    Spacer()
                    if controller.visionFPS > 0 {
                        Text(String(format: "%.0f FPS · %.0fms · 稳定 %.0f%% · %d手 · 距离 %.2fx · %@ / %@",
                                    controller.visionFPS,
                                    controller.visionLatencyMS,
                                    controller.trackingStability * 100,
                                    controller.detectedHandCount,
                                    controller.distanceGain,
                                    controller.pointerMotionPhase.displayName,
                                    controller.scrollMotionPhase.displayName))
                            .monospacedDigit()
                            .foregroundStyle(controller.trackingStability >= 0.70 ? Color.secondary : Color.orange)
                    } else {
                        Text("等待采样")
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 7) {
                    Image(systemName: "link.circle")
                        .foregroundStyle(controller.trackingContinuity >= 0.90 ? Color.green : Color.orange)
                    Text("连续性")
                    Spacer()
                    Text(String(format: "%.1f%% · 丢帧 %d · 续接 %.0fms · 最近恢复 %d 帧",
                                controller.trackingContinuity * 100,
                                controller.droppedObservationCount,
                                controller.predictionHoldMS,
                                controller.lastRecoveryFrames))
                        .monospacedDigit()
                        .foregroundStyle(controller.trackingContinuity >= 0.90 ? Color.secondary : Color.orange)
                }
            }
            .font(.caption2)

            HStack(spacing: 8) {
                Image(systemName: controller.calibrationProgress >= 1 ? "checkmark.circle.fill" : "scope")
                    .foregroundStyle(controller.calibrationProgress >= 1 ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.calibrationProgress >= 1 ? "个人标定已完成" : "正在自动标定个人工作距离")
                    if controller.calibrationProgress < 1 {
                        ProgressView(value: controller.calibrationProgress)
                            .progressViewStyle(.linear)
                            .frame(width: 170)
                    } else if let scale = controller.personalPalmScale {
                        Text(String(format: "Palm baseline %.3f", scale))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("重置") { controller.resetPersonalCalibration() }
                    .controlSize(.small)
            }

            Text("V1.2 采用实时意图分段：采集帧与 Vision 解耦并始终处理最新帧；滚动按单向笔画锁定，回收不反向带动页面；可选双手辅助提供类似真实触控板“抬指重定位”的离合语义。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("首次使用仍建议自然伸出一根食指、在舒服距离保持约 1~2 秒完成个人标定。连续性一栏可直接观察丢帧、预测续接时长与恢复帧数；正常使用应长期保持在高连续性。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func trackpadGuideRow(_ symbol: String, _ gesture: String, _ action: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 20)
            Text(gesture)
                .frame(width: 128, alignment: .leading)
            Text(action)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private var gestureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("方向手势")
                .font(.subheadline.weight(.semibold))

            ForEach(GestureDirection.allCases) { direction in
                HStack {
                    Label(direction.displayName, systemImage: direction.symbolName)
                        .frame(width: 95, alignment: .leading)

                    Picker("", selection: Binding(
                        get: { controller.bindings[direction] },
                        set: { controller.setBinding($0, for: direction) }
                    )) {
                        ForEach(KeyActionPreset.allCases) { action in
                            Text(action.displayName).tag(action)
                        }
                    }
                    .labelsHidden()
                }
            }
        }
    }

    private var customGestureSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("自定义静态手势")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let pattern = controller.currentFingerPattern {
                    Text(pattern.shortDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text("翻页模式下可继续使用自定义静态手势。摆好姿势，输入名称后捕获。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                TextField("例如：V 手势", text: $newGestureName)
                Picker("动作", selection: $newGestureAction) {
                    ForEach(KeyActionPreset.allCases) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                .frame(width: 150)
            }

            Button("捕获当前手势") {
                if controller.addCurrentStaticGesture(name: newGestureName, action: newGestureAction) {
                    newGestureName = ""
                }
            }
            .disabled(!controller.handDetected || controller.currentFingerPattern == nil)

            if controller.customGestures.isEmpty {
                Text("尚未添加自定义手势。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.customGestures) { gesture in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { gesture.enabled },
                            set: { controller.setCustomGestureEnabled(gesture.id, enabled: $0) }
                        ))
                        .labelsHidden()

                        VStack(alignment: .leading, spacing: 1) {
                            Text(gesture.name)
                            Text(gesture.pattern.shortDescription)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Picker("", selection: Binding(
                            get: { gesture.action },
                            set: { controller.setCustomGestureAction(gesture.id, action: $0) }
                        )) {
                            ForEach(KeyActionPreset.allCases) { action in
                                Text(action.displayName).tag(action)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 135)

                        Button(role: .destructive) {
                            controller.deleteCustomGesture(gesture.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var pageTuningSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("灵敏度")
                Slider(value: $controller.sensitivity, in: 0...1)
                Text(String(format: "%.0f%%", controller.sensitivity * 100))
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }

            HStack {
                Text("冷却")
                Slider(value: $controller.cooldown, in: 0.35...1.8, step: 0.05)
                Text(String(format: "%.2fs", controller.cooldown))
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
        }
        .font(.caption)
    }
}
