# Typeless.app 逆向工程报告与轻量化重构方案 (基于 REA & 原生工具链)

## 1. 逆向工程方法与工具链

本次逆向目标为本机安装的 `/Applications/Typeless.app` (`now.typeless.desktop`，版本 `2.12.0`，Build `2.12.0.140`)。我们结合了以下工具链完成从 Electron ASAR 到原生 Swift 动态库的全链路分析：

1. **REA (`morluto/rea`, `rea-agents@6.9.0`)**：
   - 使用 `rea analyze-javascript-application /Applications/Typeless.app/Contents/Resources/app.asar --integrity-policy record-and-continue` 对 Electron 归档进行清单盘点与结构解析。
   - REA 识别出 `app.asar` 内共包含 **10,355** 个文件，并自动捕获了 ASAR 清单中 `node_modules/better-sqlite3/bin/darwin-arm64-148/better-sqlite3.node` 的完整性签名差异（打包后重新签名的常见特征）。
2. **JavaScript 字符串混淆还原 (`dist/main/index.js` & `dist/preload/index.mjs`)**：
   - `dist/main/index.js`（759,557 字节）采用了字符串数组旋转表 + 十六进制索引解码器（`_0x15fa()` + `_0x49fe()`）。
   - 通过提取解码器上下文并在隔离 VM 中批量还原，恢复了 **3,379** 条明文字符串、全部 **66** 个 `ipcMain.handle` IPC 通道及核心云端接口协议。
3. **macOS Mach-O / Swift 原生动态库符号分析 (`nm` + `xcrun swift-demangle` + `strings`)**：
   - 对 `Contents/Resources/lib/` 下的原生 `.dylib` 执行导出符号反修饰与字符串提取，精准定位了其无障碍上下文提取、全局按键监听与文本注入机制。
4. **本地数据库与多语言资源解析**：
   - 读取 `Contents/Resources/drizzle/*.sql` 获取完整本地 SQLite 表结构，读取 `Contents/Resources/locales/zh-CN/index.json` 映射全部 UI 模块。

---

## 2. 原版体积与复杂度剖析 (为何需要轻量化替代)

原版 `Typeless.app` 总占用磁盘高达 **549 MB**，主要开销集中在 Electron 运行时与大量非核心业务代码：

| 组件路径 | 占用大小 | 说明与可裁剪评估 |
| :--- | :--- | :--- |
| `/Applications/Typeless.app` (总计) | **549 MB** | Electron Framework + Chromium + Node + 原生库 |
| `Contents/Resources/app.asar` | **253 MB** (265,119,296 B) | 10,355 个 JS/资源文件，含 ECharts、Sentry、Drizzle、Cloud Sync、Paywall |
| `lib/bluetooth/libBluetoothHelper.dylib` | 576 KB | Soundcore 蓝牙耳机硬件配件专有协议（非通用必需） |
| `lib/keyboard-helper/libKeyboardHelper.dylib` | 528 KB | **核心**：`CGEventTap` 全局热键与状态机 |
| `lib/libopusenc` + `lib/libopuschunk` | 1.0 MB | Opus 音频分片编码，用于上传云端服务器 |
| `lib/util-helper/libUtilHelper.dylib` | 468 KB | 权限检查、音频设备枚举、静音控制、合盖监听 |
| `lib/context-helper/libContextHelper.dylib` | 420 KB | **核心**：`AXUIElement` 焦点窗口、浏览器 URL 与上下文提取 |
| `lib/input-helper/libInputHelper.dylib` | 416 KB | **核心**：选中文本读取与无损剪贴板文本注入 |
| `lib/child-process-helper/macosCheckAccessibility` | 164 KB | 独立子进程辅助检查无障碍权限 |

此外，原版中包含大量与纯本地高效语音输入无关的重型模块：
- **强制云端依赖与付费墙**：`https://api.typeless.com/ai/voice_flow`、`important_notification` / `paywall` 限额提示、账户登录态与订阅校验。
- **遥测与云同步引擎**：Sentry 遥测 (`ingest.us.sentry.io`)、录音日志埋点、本地历史双向云同步引擎 (`/transcription_history/push`, `/load_older`, `/wipe`)、用户画像调研 (`/user/submit_survey`)、推广联盟与返利横幅。

---

## 3. 核心原理逆向还原

剔除 Electron 壳与商业化逻辑后，Typeless 之所以“好用”的底层技术秘密全部集中在 **3 个 Swift 原生模块 + 1 个上下文感知 AI 流程**：

### 3.1 全局键盘监听：`libKeyboardHelper.dylib`
- **导出 C 接口**：`startMonitor`, `stopMonitor`, `processEvents`, `updateTargetShortcuts`, `setWatcherInterval`, `resetPressingKeycodes`, `getKeyboardDeviceList`。
- **内部 Swift 实现**：`KeyboardMonitor` + `ShortcutDetector` + `KeyboardUtils`，通过 `CGEventTap` (`CFMachPortRef` + `CFRunLoopSourceRef`) 监听底层硬件按键事件与修饰键（如 `Fn` 键、单修饰键），支持：
  - **按住说话 (Hold-to-Talk)**：按下即录，松开即停。
  - **轻按/双击免提 (Hands-Free)**：快速触发后持续录音，再次触发结束，`Esc` 取消。

### 3.2 跨应用上下文提取：`libContextHelper.dylib`
- **导出 C 接口**：`getFocusedAppInfoAsync`, `getFocusedAppIdentityAsync`, `getFocusedElementInfoAsync`, `getFocusedVisibleTextAsync`, `getFocusedElementRelatedContentAsync`, `setFocusedWindowEnhancedUserInterface`。
- **内部 Swift 实现**：
  1. 通过 `AXFocusedApplication` 与 `AXFocusedUIElement` 获取当前焦点应用与输入控件。
  2. 调用 `setFocusedWindowEnhancedUserInterface` 设置 `AXEnhancedUserInterface`，迫使 Chrome / Electron 应用暴露内部无障碍树。
  3. 针对浏览器应用（`isBrowserApp` + `bottomUpURLTraversalWhitelist` + `findWebArea`），向上遍历读取 `AXURL` 与 `AXTitle`，以识别用户当前正在操作 Gmail、Notion、Google Docs 还是 Figma。
  4. 通过 `collectContentBefore` / `collectContentAfter` 在超时预算 (`CaptureTimeout`) 内截取光标前后文，用于指导 AI 调整口述格式、标点与语气。

### 3.3 选中读取与文本注入：`libInputHelper.dylib`
- **导出 C 接口**：`insertText`, `insertRichText`, `deleteBackward`, `getCurrentInputState`, `getSelectedText`, `getSelectedTextBySimulateCopyAsync`。
- **内部 Swift 实现**：
  1. **读取选中文本**：优先读取 `AXSelectedTextRange` / `AXSelectedTextMarkerRange` / `AXStringForTextMarkerRange`；若目标应用不支持 AX 文本属性（如部分 Electron/终端/网页编辑器），则通过 `getSelectedTextBySimulateCopyAsync`：备份剪贴板 -> 发送 `Cmd+C` -> 读取剪贴板 -> 恢复原剪贴板。
  2. **极速文本注入 (`performTextInsertion`)**：调用 `savePasteboard()` 完整保存 `NSPasteboard.general` 中的所有项与数据类型，将目标文本写入剪贴板，发送 `simulatePasteCommand` (`Cmd+V` 虚拟按键)，最后调用 `restorePasteboard()` 恢复用户原有剪贴板，实现“全 App 通用 + 不污染剪贴板”。

### 3.4 AI 语音流接口协议 (`/ai/voice_flow`)
从 `dist/main/index.js` 的 `audio:ai-voice-flow` IPC 处理器中提取出完整请求参数与响应结构：
- **请求 (`multipart/form-data`)**：
  - `audio_id`、`mode`（三大模式：`voice_transcript` 口述润色、`voice_command` Ask Anything 指令、`voice_translation` 翻译模式）
  - `audio_file`（压缩音频）、`audio_context`（聚焦 App/网页/前后文信息）、`audio_metadata`（时长等）、`device_name`
  - `parameters` JSON：当 `mode == VOICE_COMMAND` 时携带 `selected_text`；当 `mode == VOICE_TRANSLATION` 时携带 `output_language`
- **响应**：
  - `data.refine_text`：润色/改写/翻译/回答文本
  - `data.delivery`：投递方式（直接替换/插入光标，或在 `voice_command` 为问答型指令时使用 `external` 弹出 `interactive-card.html` 浮窗卡片）
  - `data.user_prompt`、`data.external_action`、`data.web_metadata`

### 3.5 主要 IPC 通道与本地数据库 Schema
- **66 个 `ipcMain.handle` 通道**涵盖：
  - `audio:*`（录音采集、Opus 压缩、`audio:ai-voice-flow`、`audio:abort-ai-voice-flow-request`）
  - `keyboard:*`（监听启停、`keyboard:type-transcript`）
  - `context:*`、`clipboard:*`、`permission:*`
  - `page:*`（管理 `floating-bar.html` 灵动悬浮胶囊、`interactive-card.html` 回答浮窗、`hub.html` 主控制台）
  - `db:history-*`、`store:use`、`sync-engine:*`、`updater:*`
- **本地 SQLite (`drizzle/*.sql`)**：核心表 `history` 与 `history_v2`，记录 `id`、`mode`、`refined_text`、`duration`、`focused_app_name`、`focused_app_bundle_id`、`focused_app_window_web_domain`、`mode_meta` 等字段。

---

## 4. 我们的轻量级原生复刻版：`TypelessLite` 设计对比

基于以上逆向结论，我们完全摒弃 253 MB 的 Electron 壳和云端绑定，使用 **纯原生 macOS Swift + SwiftUI + AppKit** 构建 `TypelessLite`：

| 维度 | 原版 Typeless.app (v2.12.0) | 复刻版 TypelessLite (原生 Swift) |
| :--- | :--- | :--- |
| **应用体积** | **549 MB** (Electron + 10,355 文件) | **< 3 MB** (单一原生 arm64 Mach-O 二进制) |
| **架构层级** | Electron Main + Preload + 4 个 Renderer + Koffi FFI -> Swift dylib | **单进程原生 Swift**：直接调用 `CGEventTap`、`AXUIElement`、`NSPasteboard`、`AVFoundation` |
| **ASR 语音识别** | 强制上传 Typeless 私有云接口 | **灵活可配**：Groq Whisper / OpenAI Whisper / 自定义接口 + **macOS 原生 `SFSpeechRecognizer` 离线兜底** |
| **AI 润色引擎** | 绑定付费订阅 + Paywall | **自带 Key (BYOK)**：Groq / OpenAI / DeepSeek / Gemini / 任意兼容接口 + **零依赖本地正则去口癖引擎** |
| **隐私与数据** | 含 Sentry 遥测、云同步上传、账号追踪 | **100% 本地存储**（JSON 历史与词典），无账号体系、无遥测、无推广 |
| **核心交互复刻** | Hold/Tap 热键、灵动悬浮条、Ask Anything 浮窗卡片、上下文感知 | **完整复刻**：不抢焦点 `NSPanel` 悬浮条、Ask Anything 智能判断直替或弹卡、App 语气自动适配、无损剪贴板注入 |
