# 语音输入 · Shengru

按住说话，松开就在光标处输入。适用于 macOS 14 及以上，支持 Apple 芯片和 Intel。内置中英听写模型，第一次打开也可以断网使用。

[下载安装镜像（DMG）](https://github.com/BurntRoses/shengru/releases/download/v2.0.0-preview/Shengru.dmg) · [English](#english) · [使用说明](源码/使用说明.md)

![悬浮窗设置，预览实际配色、材质和文字大小](docs/appearance.png)

## 开始使用

1. 打开镜像，把「语音输入」拖入「应用程序」，从那里打开。**此预览版尚未获 Apple 公证。** 若系统拦截首次打开，请先核对文件来自本项目的发布页；决定使用后，可按 [Apple 的说明](https://support.apple.com/zh-cn/102445) 在「系统设置 → 隐私与安全性」为「语音输入」选择「仍要打开」。
2. 按引导允许麦克风。需要在其他应用里输入时，再允许辅助功能。
3. 将光标放在要输入的位置，按住 **Control + Shift + 空格** 说话，松开定稿。

也可以用终端安装（需要 Git，无需管理员密码）：

```sh
git clone --depth 1 https://github.com/BurntRoses/shengru.git
bash shengru/install.sh
```

安装器会核对下载摘要，保留 macOS 的首次打开检查，不覆盖已有应用。以后在 **设置 → 更新** 检查，有新版时点「更新并重启」。

## 写完，直接改

- **点正文就能改。** 在听写页、历史记录或悬浮窗中点到哪个字，就从那里编辑。按 **⌘↩** 保存，**Esc** 取消。确认的词语订正默认记在本机；同音词参考当时的语境，不把一次改稿当作通用替换。
- **只替换刚输入的那一段。** 若原文和光标还对得上，当前定稿会同步回原处；光标移开了，就保留修改稿供复制。改历史不会碰其他应用。
- **没听准，再听一次。** 保留录音后，点「增强识别」用原声复听，直接点选合适的写法。中文专名、诗文熟语和自建词库可在本机使用。
- **听写不需要账户。** 语音、文字、词库和记忆都在 Mac 上。手动下载可选模型、检查或安装更新才会联网。

![悬浮窗里直接编辑定稿](docs/editing.png)

## English

**Shengru is offline Chinese and English dictation for macOS.** Hold **Control + Shift + Space** to speak and release to type into the current field. The bundled model works without an account or an internet connection. The interface is in Simplified Chinese.

[Download the DMG](https://github.com/BurntRoses/shengru/releases/download/v2.0.0-preview/Shengru.dmg), drag the app into Applications, then open it there. Requires macOS 14 or later; Apple silicon and Intel are supported. **This preview is not notarized by Apple.** If macOS blocks the first launch, check that the download came from this project’s release page. If you choose to run it, follow [Apple’s instructions](https://support.apple.com/en-us/102445) to select **Open Anyway** for Shengru in **System Settings → Privacy & Security**. The terminal installer above checks the SHA-256 digest and preserves the system’s security checks.

Click a word in the main window, history, or floating panel to edit it in place. **⌘↩** saves; **Esc** cancels. Confirmed spelling corrections are remembered locally in context. Edits to history stay in history; edits to the current dictation can replace the original passage only if its text and cursor still match. Keep a recording to recheck uncertain words against the audio.

[构建与第三方组件 / Build and credits](源码/使用说明.md#从源码构建) · [Third-party notices](源码/Resources/Licenses)
