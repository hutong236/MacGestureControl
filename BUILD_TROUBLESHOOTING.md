# GestureControl V0.9.1 构建说明

V0.9.1 将本地构建默认改为 **当前 Mac 本机架构**，并使用 Release + incremental Swift compilation。

## 推荐构建

```bash
./build_release.sh
```

Apple Silicon MacBook Pro 默认只编译 `arm64`；Intel Mac 默认只编译 `x86_64`。

若确实需要 Universal Binary：

```bash
GESTURECONTROL_UNIVERSAL=1 ./build_release.sh
```

若机器内存较小或 Xcode 编译器占用过高：

```bash
GESTURECONTROL_XCODE_JOBS=1 ./build_release.sh
```

## 构建失败时

脚本会把完整日志保存到：

```text
build/xcodebuild.log
```

并在末尾自动重新打印 `error:`、`fatal error:`、Swift compiler signal 等真正诊断，不再只剩 `BUILD FAILED`。

快速提取：

```bash
grep -nE 'error:|fatal error:|failed due to signal|SwiftCompile.*failed' build/xcodebuild.log | tail -n 120
```

V0.9.1 同时把 Xcode Project 的 Release 配置改成 `SWIFT_COMPILATION_MODE=incremental` 和 `ONLY_ACTIVE_ARCH=YES`，因此从 Xcode GUI 直接 Build 也不会默认同时跑两套 Whole-Module 编译。
