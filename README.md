# Gesture Control for macOS V1.2.0 — Realtime Intent Engine

纯本地 macOS 空中触控板 / 手势控制工具。使用 Swift + AVFoundation + Apple Vision + Core Graphics，本机处理摄像头画面，不依赖 Python、MediaPipe、Electron 或云端 AI。

## V1.2 的目标

V1.2 不再把“手往回收”当成反向操作，而是把空中操作建模成 **接触笔画 → 重定位 → 重新武装**。重点是连续、低延迟和可恢复，而不是继续增加固定阈值。

### 1. 单向滚动笔画锁：解决“滚完收手又滚回来”

一次双指滚动确认主轴和方向后，同一次接触中的反向位移只作为主手回位，不输出反向页面滚动。

```text
主方向滚动
    ↓
锁定本次笔画方向
    ↓
页面连续滚动
    ↓
手往回收（允许路径有横向偏差）
    ↓
反向位移被吞掉，页面不回弹
    ↓
回到宽松的主轴回中区域 + 稳定约 65ms
    ↓
重新武装下一笔
```

不要求沿原路精确返回；回中判定主要看滚动主轴，横向偏差不会造成误触。

如果希望立刻开始相反方向的新滚动，可短暂放松“双指姿势”，相当于真实触控板上的“抬指再落下”。

### 2. 离散方向手势也加入回程抑制

上一页 / 下一页、系统三/四指方向手势同样会阻止“触发后收手”被再次识别成反方向动作。

### 3. Realtime Capture Pipeline

V1.2 对摄像头 → Vision 链路做了低延迟重构：

```text
AVCapture 快速收帧
        ↓
latest-frame-wins mailbox
        ↓
独立 Vision 串行队列
        ↓
Continuity / Recovery Fusion
        ↓
Realtime Intent Engine
        ↓
120Hz Core Graphics 输出
```

- 移除额外的 `1/30s` 软件节流，避免 29.97~30FPS 输入因时间边界误差被意外降到约 15FPS；
- Vision 忙时不排队旧帧，只保留最新待处理帧；
- 每一帧 Vision 推理使用独立 `autoreleasepool`，避免长期循环中的临时对象积累造成周期性卡顿；
- 优先使用相机支持的原生 420f YUV，回退时才使用 BGRA；
- 若当前 active format 支持 60FPS，则采集层优先 60FPS，Vision 仍按自身吞吐 latest-frame-wins，只为了让待处理帧更新鲜；
- motion timestamp 使用摄像头帧到达时间，而不是 Vision 开始推理时间；显示的 latency 也包含 mailbox 等待 + Vision 推理，更接近真实 camera-to-control 延迟。

### 4. 细小滚动不再被 120Hz 输出层吃掉

低速滚动的输出阈值已显著降低，亚像素/小数滚动继续在 `TrackpadController` 中累积。慢慢移动双指时页面应持续细微移动，而不是“动一段、停一下”。

### 5. 可选双手辅助

为保证默认实时性能，**双手辅助默认关闭**；开启时 Vision 最多检测两只手。

- 主手：继续负责鼠标、滚动、拖拽；
- 辅助手张开并稳定约 85ms：进入 **离合/Clutch**；主手可以自由回到舒适位置，页面和指针完全冻结；
- 辅助手松开：从主手当前位置无跳变继续；
- 辅助手主动捏合：右键点击；
- 两只手使用时间连续性做 identity assignment，不依赖 Vision 返回数组顺序。

这个离合手势是空中输入对真实触控板“抬起手指重新放下”的等价语义，尤其适合长距离连续操作。

## 推荐设置

```text
控制模式              空中触控板
跟手响应              74%
精细稳定              68%
指针速度              1.00x
滚动速度              1.00x
滚动惯性              72%
自然滚动              开
单向滚动笔画锁        开（推荐）
双指张合缩放          关（推荐）
双手辅助              先关；需要离合/右键时再开
```

## 使用建议

### 双指连续滚动

1. 双指伸出；
2. 向目标方向移动完成主滚动；
3. 收手时无需精确原路返回，系统不会让页面反向回弹；
4. 回到大致原轴向区域停稳，或短暂放松双指姿势，即可开始下一笔。

### 双手离合重定位

1. 设置里打开 `双手辅助（离合 + 右键）`；
2. 主手正常操作；
3. 另一只手张开；
4. 指针/滚动冻结；
5. 主手移回舒适位置；
6. 辅助手松开；
7. 主手从新位置继续，无“回收反向移动”。

## 构建

```bash
./build_release.sh
./install_local.sh
pkill -x GestureControl 2>/dev/null || true
open /Applications/GestureControl.app
```

默认只编译当前 Mac 的本机架构。完整构建日志：

```text
build/xcodebuild.log
```

若编译失败，脚本末尾会输出 `REAL BUILD DIAGNOSTICS`。

## 实时性的边界

V1.2 已尽量把软件侧的排队、周期性回收卡顿和手势回程歧义压低，但摄像头 + Vision 与硬件触控板不同：相机帧周期和 Vision 推理仍构成物理延迟下限。因此“接近实时、连续可用”是目标，不能承诺与 MacBook 内建触控板完全相同的毫秒级延迟。界面中的 FPS、Vision latency、稳定度、Continuity 和 hold 指标用于继续实机调优。
