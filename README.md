# TypelessLite

基于对 `/Applications/Typeless.app` 的 REA 逆向工程分析（详见 [docs/REA_REVERSE_REPORT.md](docs/REA_REVERSE_REPORT.md)），使用纯原生 **Swift + SwiftUI + AppKit** 从零复刻的轻量级 macOS AI 语音输入与指令助手。

## 为什么做 TypelessLite？

- **极致轻量**：原版 Typeless 为 549 MB（含 253 MB `app.asar` 与 Electron 壳）；TypelessLite 编译为单一原生 macOS App，体积仅数 MB。
- **完全自由 (BYOK + 本地兜底)**：
  - **语音识别 (ASR)**：开箱即用支持 **macOS 原生 `SFSpeechRecognizer`**，也支持 **Groq Whisper**（极速）、**OpenAI Whisper** 或任意 Whisper 兼容接口。
  - **文本润色与指令 (LLM)**：支持 **Groq / OpenAI / DeepSeek / Google Gemini / 本地 Ollama**，无 Key 时自动启用本地正则去口癖与纠错引擎。
- **零隐私上传**：无账号登录、无付费墙、无 Sentry 遥测、无云同步，所有配置与历史记录仅保存于本地 `~/Library/Application Support/TypelessLite/`。

## 核心功能

1. **口述润色 (Dictation)**：按住快捷键说话（松手自动停止并上屏），或轻触一次进入免提模式（再按一次结束，`Esc` 取消）。自动去除“嗯/啊/那个/um/uh”等口癖、处理自我纠错并修正标点。
2. **选中改写 / Ask Anything**：选中任意 App 中的文字后按 `⌥ + Space`（可自定义），口述“帮我改得礼貌一点”、“翻译成英文”或“解释这段代码”。编辑类指令直接替换原文，问答类指令弹出悬浮卡片回答。
3. **实时翻译口述 (Translation)**：按 `F5` 说中文，直接将地道的目标语言（英文/日文等）注入当前光标位置。
4. **上下文感知与无损剪贴板注入**：通过 `AXUIElement` 识别当前聚焦应用（如 Xcode/VSCode 自动保留英文代码术语、飞书/邮件自动切换正式书面语），并通过剪贴板快照 + `Cmd+V` + 快照还原实现跨应用通用注入且不覆盖你的剪贴板。

## 构建与运行

### 运行单元测试
```bash
swift test
```

### 一键编译并打包 `.app`
```bash
bash scripts/build_app.sh
open build/TypelessLite.app
```

> 首次使用全局热键与跨应用自动上屏时，请在「工作台」顶部授予 **麦克风权限** 与 **辅助功能 (Accessibility)** 权限；在测试前也可以直接在「工作台」内置的 **实时演练场** 中点击按钮直接体验全流程。
