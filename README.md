# MarkLook

**保存しても、読みかけの場所はそのまま。**

MarkLookは、ローカルのMarkdownとHTMLを読むためのmacOSアプリです。
ファイルを保存すると、スクロール位置を保ったまま表示を更新します。

> macOS 14以降 / Apple Silicon / ローカルファイル専用

## 特長

- GFM、Obsidian互換のCallout、脚注、数式、タスクリスト、表、ローカル画像、コードハイライトに対応
- Finder、`⌘O`、ドラッグ＆ドロップ、Open Recentからファイルを開ける
- 検索、ズーム、印刷、ライト／ダークモード、表示幅とMarkdown改行の設定に対応
- 文書を外部へ送信せず、HTML内のJavaScriptやリモート資源を実行・取得しない

対応する拡張子は`.md`、`.markdown`、`.html`、`.htm`です。HTTP(S)リンクは既定のブラウザで開きます。

## 開発

Xcode 26以降が必要です。

```sh
git clone https://github.com/kdmsnr/marklook.git
cd marklook
./script/build_and_run.sh
```

テスト：

```sh
xcodebuild \
  -project MarkLook.xcodeproj \
  -scheme MarkLook \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  test
```

## License

[MIT](LICENSE) © 2026 Masanori Kado

同梱ライブラリについては[Third-Party Notices](THIRD_PARTY_NOTICES.md)を参照してください。
