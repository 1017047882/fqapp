# iOS 版：构建与已知限制

仓库原本只有 Android / Windows 两个平台。iOS 15 端重点复用 Android 的读书、
智能朗读/真人音频听书及独立系统 TTS 链路；视频不在本次适配范围。
下述原生适配已加入源码，仍需 Actions 的 Apple 构建及 iOS 15 真机验收。

## 构建环境

| 组件 | 版本 | 备注 |
|---|---|---|
| macOS | runner 提供的版本 | 需支持所选 Xcode |
| Xcode | 26.6 | `sudo xcode-select -s /Applications/Xcode_26.6.app/Contents/Developer` |
| Flutter | **3.47.9** | 与当前项目及依赖锁文件保持一致 |
| CocoaPods | 1.17.0 | `brew install cocoapods`（系统 Ruby 太旧，别用 gem 装） |
| Rust | 1.99.1 | `rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios` |
| flutter_rust_bridge_codegen | 2.13.0 | 必须与 `rust/Cargo.toml` 里的版本一致 |

## 构建

### GitHub Actions：iOS 15 未签名 IPA

在 GitHub → Actions → **iOS 15 unsigned IPA** → **Run workflow** 手动运行
`.github/workflows/build-ios15.yml`。流程参照 `tvbox-silicon` 的 iOS 15 构建：
记录工具链、编译真机产物、逐个检查内嵌 Mach-O 的 arm64 架构与最低系统版本，再打包。
同时运行共用媒体服务的 Rust 回归、阅读/听书 Dart 回归，以及可用 iPhone 模拟器的
原生 XCTest。模拟器的系统版本由 runner 提供，不代表已经在 iOS 15 真机验证。

- 使用当前项目锁定的 Flutter 3.47.9、Rust 1.99.1 和 Xcode 26.6；runner 必须提供
  `/Applications/Xcode_26.6.app`。该版本来自实际运行日志中的可用工具链列表；
  完整构建结果仍以 Actions 为准，缺失时明确失败。
- 使用现有 Flutter Runner 工程与 Rust 静态库，不使用 Swift 参考项目的
  `.ios15-project.generated.yml`（该文件是 XcodeGen 配置，并非 Actions 工作流）。
- 成功后下载 `fqapp-iOS15-unsigned-<运行编号>`，包含 IPA 与 SHA-256 校验文件；
  日志位于 `fqapp-ios15-logs-<运行编号>`，产物保留 14 天。
- 最低系统版本为 iOS 15.0。依赖二进制如要求更高版本或包含模拟器切片，打包前失败；
  不强制降低第三方依赖声明来掩盖不兼容。
- IPA 未签名，须自行签名后安装。工作流通过仍需在 iOS 15 真机验证启动、搜书、
  阅读、书架持久化和前后台切换；现有视频等平台限制见下文。

### 本地构建

```bash
flutter pub get
./scripts/build_rust_ios.sh          # Rust → ios/Frameworks/libfqapi_core.a
flutter build ios --release --no-codesign
```

产物在 `build/ios/iphoneos/Runner.app`（未签名）。

打包成未签名 IPA：

```bash
PACK_DIR="$(mktemp -d /tmp/fqapp-ipa.XXXXXX)"
mkdir -p "$PACK_DIR/Payload"
ditto build/ios/iphoneos/Runner.app "$PACK_DIR/Payload/Runner.app"
(cd "$PACK_DIR" && zip -qry fqapp_ios_unsigned.ipa Payload)
echo "$PACK_DIR/fqapp_ios_unsigned.ipa"
```

## 签名

`DEVELOPMENT_TEAM` 不入库。首次构建前把它放进本地文件：

```bash
cp ios/Flutter/Signing.xcconfig.example ios/Flutter/Signing.xcconfig
# 把 DEVELOPMENT_TEAM 改成自己的 Team ID；该文件已被 ios/.gitignore 忽略
```

只要改 `Signing.xcconfig` 就够了，别在 Xcode 的 Signing 页里再选一次 Team——那样
Xcode 会把 `DEVELOPMENT_TEAM` 写回 `ios/Runner.xcodeproj/project.pbxproj`，让工程文件变脏。
`CODE_SIGN_STYLE` 仍是 Automatic，Team 由 xcconfig 供值。

装到真机可以走自签（免费 Apple ID 7 天有效，过期后 App 闪退，重新签一次即可）。
下面的命令按你自己的签名脚本替换：

```bash
BUNDLE_ID=com.fqapp.fqapp IPA="$PACK_DIR/fqapp_ios_unsigned.ipa" ./your-sign-script.sh
```

## iOS 专用改动（为什么需要）

1. **Rust 核心以静态库链接**。iOS 不允许从 App 包内 dlopen 共享库，所以：
   - `scripts/build_rust_ios.sh` 用 `--crate-type staticlib` 编出 `ios/Frameworks/libfqapi_core.a`（`CARGO_PROFILE_RELEASE_STRIP=debuginfo`，因为 release profile 的 `strip = true` 会裁掉符号）；
   - `ios/Flutter/{Debug,Release}.xcconfig` 追加三个必需设置：
     - `-force_load` 把静态库目标文件全部装进来；
     - `DEAD_CODE_STRIPPING = NO`，否则「只在运行时 dlsym」的符号会被 dead_strip 删掉；
     - `-Wl,-export_dynamic`，主可执行文件默认不导出全局符号，dlsym 会找不到 Rust 入口；
   - `lib/services/rust_bootstrap_io.dart` 在 iOS 上改用 `ExternalLibrary.process()`（接缝在 `lib/services/backend_transport.dart` 的 `runtimeInitializer`）。
   - Runner 的 Debug 设置 `ENABLE_DEBUG_DYLIB = NO`，使调试构建也保持主二进制链接布局，
     不将应用代码拆入 `Runner.debug.dylib`。模拟器 CI 在 Flutter 构建前检查静态库的
     三个 `fq_desktop_media_*` 导出，并保存有效构建设置和详细链接日志；
     符号检查使用同一 Rust 工具链的 `llvm-tools-preview` 中的 `llvm-nm`，
     避免 Apple `nm` 无法解析较新 Rust LLVM 位码而中断检查。
     该 Debug 调整仍需 Actions 重跑确认，不能仅凭静态设置认定链接错误已消除。
2. **桌面专用依赖**（`webview_windows` / `smtc_windows` / `window_manager` / `screen_retriever`）不需要条件导入：它们都能在 iOS 上编译，运行时只在 `isWindowsDesktop` 分支调用。
3. **读书和听书原生桥**：AppDelegate 注册 `FQReaderPlugin`、`FQAudioPlayerPlugin` 和
   `FQSystemTtsPlugin`，使用现有 Flutter 方法/事件通道。视频能力判断仍为 false。
4. **图标与应用名**：`scripts/generate_ios_app_icon.py` 从 `assets/branding/app_icon_source.png` 生成 1024 无 alpha 图标（复用 Android 生成器的「去纸张外框」逻辑），`CFBundleDisplayName` 设为「什锦铺」。
5. **关掉 Swift Package Manager**：`flutter config --no-enable-swift-package-manager`（Xcode 27 + SPM 有已知构建失败）。

## 读书与听书实现

| 能力 | iOS 实现 |
|---|---|
| 阅读排版、书架、进度、章节缓存 | 共用 Flutter/Rust 逻辑 |
| 智能朗读、真人讲书 | 共用服务端音源，AVPlayer 播放；明文 URL 直接交给系统 |
| CENC 加密音频 | 共用 Rust `desktop_media` 与 native C 核心，按 Range 提供明文，不写明文文件 |
| 系统朗读 | AVSpeechSynthesizer 中文音色，支持队列和 UTF-16 进度事件 |
| 后台与锁屏 | playback 音频会话、audio 后台模式、Now Playing 和远程命令 |
| 阅读设备 | 会话亮度恢复、常亮、电量与时间状态；旧会话不能关闭新会话 |
| 文件交互 | TXT/EPUB/字体选择，备份导入导出，TXT 导出与系统分享 |

默认仍是服务端智能朗读，没有改成系统 TTS。iOS 使用原生语音变速算法，Android 的
Sonic/系统混音器/WSOLA 选择项仅在 Android 显示，不能据此承诺相同音色和倍速听感。
自定义阅读亮度期间，系统亮度字段是进入阅读时的恢复快照。

### 验收清单

- iOS 15 真机冷启动、搜书、翻页、正文替换、离线重启续读、书架和进度持久化。
- UTF-8/UTF-16/GB18030 TXT、EPUB、字体导入；备份导出/恢复往返；取消文件选择和分享。
- 明文 HTTP 200/206 音频、本地音频、CENC 音频首播、seek、倍速、切章和离线播放。
- TTS 连续句/连续章节、中文音色、段落高亮、暂停、定时关闭。
- 后台/锁屏播放，锁屏上一章/下一章/暂停，耳机拔出、来电中断及用户暂停后不误恢复。
- 快速切章、创建中关闭、连续 seek，确认迟到回调不会移动当前进度或泄漏媒体会话。

## 已知限制

- **视频不可用**：短剧/漫剧页显示「暂不支持」。要补需要接 `media_kit` + `media_kit_libs_ios_video`（播放走 Rust 的 `/src/*` 回环解密），或写 AVPlayer 插件。
- 加密音频沿用 native C 库的格式限制：非分片 CENC AES-CTR MP4、单内容密钥；
  不支持的格式明确失败，不切换到未解密的地址。
- iOS 没有任意跨应用悬浮窗或 Android TTS 引擎安装机制；音量键翻页未适配。
- 原生通道和 XCTest 已写入，但本次 Windows 环境没有 Xcode/Flutter/Rust 工具链，
  未在本机运行 Apple 编译、XCTest 或真机测试；不得把代码完成当作功能验收通过。
- 当前 XCTest 主要覆盖状态与纯辅助函数，Rust Range 回归使用明文样本；
  原生通道、实际播放/TTS 和 CENC 音频首播及 seek 仍须端到端验证。
- LAN 分享、番茄账号登录和书架采集尚未补齐 iOS 对应实现。
- 免费 Apple ID 签名 7 天过期，过期后 App 闪退，重跑一次自签脚本即可。

## 与 Android 构建的关系

iOS 需要 Flutter 3.47+（Xcode 27 适配），因此 `pubspec.lock` 的传递依赖被一并升级到
3.47.9 能解析的版本，Android / Windows 的 CI 也统一到 3.47.9（见 `chore(deps)` 那个
commit）。若上游要保留旧 SDK，把那一个 commit 整体回退、再在 3.44.6 上重新生成
`pubspec.lock` 即可，iOS 侧的改动不受影响。
