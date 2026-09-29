# GestureControl V1.2.0 Release Notes

## Realtime Intent Engine

V1.2 的核心目标是消除空中手势最影响可用性的语义冲突：**主运动完成以后，手为了回到舒适位置而产生的反向轨迹不应成为新的反向操作。**

### Scroll Stroke Direction Latch

- 一次双指接触建立主滚动方向后，反向回收位移立即抑制；
- 页面不会在“向下滚动 → 收手向上”过程中被带回；
- 同样适用于向上、向左、向右；
- 回中判定只看主轴投影，不要求精确沿原路径返回；
- 回到宽松回中区并稳定约 65ms 后重新武装；
- 短暂放松双指姿势等价于“抬指”，可立即开始新笔画。

### Discrete Gesture Return Suppression

- 页面翻页和系统方向手势同样增加单笔画/回程抑制；
- 触发一次方向动作以后，回收轨迹不会误触相反方向。

### Realtime Capture / Vision Pipeline

- AVCapture delegate 与 Vision 推理解耦；
- latest-frame-wins，不积压旧摄像头帧；
- 移除额外 30FPS 软件时间门，避免接近 30FPS 输入被错误抽成约 15FPS；
- 每帧 Vision 使用独立 autorelease pool，减少长期运行时的周期性内存压力；
- 优先相机原生 420f YUV，避免不必要 BGRA 转换；
- 支持时采集层优先 60FPS，以降低待处理帧年龄；
- capture arrival timestamp 随帧进入 Vision 队列，运动 dt 与 latency compensation 使用真实输入时刻；
- latency 指标现在包含 Vision 等待 + 推理时间。

### Fine Motion Output

- 120Hz pointer 最小输出门槛降低；
- 120Hz scroll 最小输出门槛降低；
- 小数滚动继续由 Core Graphics 控制层累积，改善慢速滚动断续感。

### Optional Bimanual Assist

默认关闭，避免无需求时承担第二只手的 Vision 成本。

开启后：
- 辅助手张开：Clutch / 冻结输出 / 主手重定位；
- 辅助手松开：从新位置平滑继续；
- 辅助手捏合：右键；
- 两手基于时间轨迹做稳定身份分配，不依赖 Vision 结果顺序。

### Compatibility retained

保留 V1.1.1 之后的：
- 双指缩放默认关闭与 zoom/scroll 互斥；
- Continuity Hold；
- Soft Confidence；
- Recovery Fusion；
- Semantic Hysteresis；
- α-β pointer state；
- Click Intent / rebound suppression；
- Precision Clutch；
- Personal Palm Scale calibration；
- Dynamic FPS / stability / continuity telemetry。
