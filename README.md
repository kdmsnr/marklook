# MarkLook

MarkLookは、ローカルにあるMarkdown、HTML、CSV、TSVを読むためのmacOSアプリです。更新時にオートリロードします。

対応する拡張子は`.md`、`.markdown`、`.html`、`.htm`、`.csv`、`.tsv`です。HTTP(S)リンクは既定のブラウザで開きます。

CSV・TSVは、スクロールとソートができる表で表示します。

「Window」→「Always on Top」で、現在のウインドウを常に手前に表示できます。もう一度選ぶと解除します。同じウインドウ内のすべてのタブに適用され、追加したタブにも引き継がれます。

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

単体テストの実行例（HTML エスケープ）：

```sh
xcodebuild \
  -project MarkLook.xcodeproj \
  -scheme MarkLook \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:MarkLookTests/HTMLEscapingTests \
  test
```

変更内容に応じて対象のテストクラスを置き換えてください。
UI テストと GUI の自動操作による検証は禁止しています。実行前に、対象の単体テストが GUI や入力環境に影響しないことを確認してください。
対象を限定しない `xcodebuild test` は UI テストも実行するため使用しません。

アプリを起動せずにビルドする場合：

```sh
xcodebuild \
  -project MarkLook.xcodeproj \
  -scheme MarkLook \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  build
```

## License

[MIT](LICENSE) © 2026 Masanori Kado

同梱ライブラリについては[Third-Party Notices](THIRD_PARTY_NOTICES.md)を参照してください。
