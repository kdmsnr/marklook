# MarkLook

MarkLookは、ローカルにあるMarkdownとHTMLを読むためのmacOSアプリです。更新時にオートリロードします。

対応する拡張子は`.md`、`.markdown`、`.html`、`.htm`です。HTTP(S)リンクは既定のブラウザで開きます。

外部リソースは初期状態では読み込みません。必要な場合は「設定」→「Remote Content」で接続を許可するホストを追加できます。許可はホスト名の完全一致で、HTTPSの画像、スタイルシート、フォント、音声、動画に適用されます。スクリプトやiframeは許可されません。許可したホストにはIPアドレス、リクエスト時刻、リソースURLが伝わります。

## インストール

Xcode 26以降が必要です。ソースコードからReleaseビルドを作成します。

```sh
git clone https://github.com/kdmsnr/marklook.git
cd marklook
./script/build.sh
```

ビルドが完了すると、Finderに`MarkLook.app`が表示されます。「アプリケーション」フォルダへドラッグしてください。

## 開発

Xcode 26以降が必要です。Debugビルドを作成して起動します。

```sh
git clone https://github.com/kdmsnr/marklook.git
cd marklook
./script/build.sh --debug
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
