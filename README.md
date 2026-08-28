# MarkLook

MarkLookは、ローカルにあるMarkdownとHTMLを読むためのmacOSアプリです。更新時にオートリロードします。

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
