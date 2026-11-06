# KEYI 终端草稿桥

在终端里翻译**还没提交的命令行草稿**。KEYI 不读取终端历史、不读屏幕、不自动发送按键，
也不修改你的 shell 配置文件；下面的绑定只在你主动 `source` 的那个 shell 里生效。

## 按需启用

在当前 shell 里执行一次（想长期使用，可自行加进 rc 文件）：

```sh
# zsh
source "/Applications/KEYI 可译.app/Contents/Resources/Terminal/keyi.zsh"
# bash 4+（macOS 自带的 bash 3.2 不支持）
source "/Applications/KEYI 可译.app/Contents/Resources/Terminal/keyi.bash"
# fish
source "/Applications/KEYI 可译.app/Contents/Resources/Terminal/keyi.fish"
```

之后在命令行里按 **Ctrl+X Ctrl+E**：当前草稿在 KEYI 草稿编辑器里打开，翻译并确认后写回命令行，
光标放到末尾。KEYI 不会替你按回车；草稿在编辑期间变了，就保留现状、不覆盖。

`keyi-zsh-draft.zsh` 是 Apple Terminal / Ghostty 交互 zsh 的可选接入，由 `KEYITerminal zsh-draft`
子命令配合 KEYI 可译的快捷键直接读写 ZLE 草稿，同样只在加载它的 shell 里生效。

## 命令行入口

```sh
"/Applications/KEYI 可译.app/Contents/MacOS/KEYITerminal" --help
```

- `KEYITerminal edit FILE`：编辑并翻译一个显式指定的草稿文件，确认后条件写回。
- `KEYITerminal edit -`：从 stdin 读取，确认后写到 stdout。
- `KEYITerminal compose`：通用草稿窗口，确认后复制译文，由你手动粘贴。

翻译走 KEYI 可译里已选的翻译风格与服务；文字只发给你配置的那个服务（本机风格不出本机）。
