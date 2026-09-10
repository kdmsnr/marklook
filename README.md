# MarkLook

MarkLookは、ローカルにあるMarkdown、HTML、CSV、TSVを読むためのmacOSアプリです。更新時にオートリロードします。

対応する拡張子は`.md`、`.markdown`、`.html`、`.htm`、`.csv`、`.tsv`です。HTTP(S)リンクは既定のブラウザで開きます。

CSV・TSVは、先頭行を固定見出しにした、縦横にスクロールできる表で表示します。セル内の改行、引用符、空欄を保持し、数式やHTMLは文字列として表示します。文字コードはUTF-8とBOM付きUTF-16に対応しています。大きな表はデータ10,000行または見出しを含む100,000セルまでのプレビューとなり、上限に達した場合は通知します。検索とPDF書き出しの対象も表示中のプレビューです。

CSV・TSVの列見出しをクリックすると、昇順、降順、ファイルの元の順序に切り替わります。数値だけの列は数値順で、それ以外は文字列として並べ替えます。空欄は昇順・降順とも末尾に置き、行番号は元の行を示します。オートリロード後も選択中の並べ替えを維持します。プレビュー表示時は、表示中の行を対象に並べ替えます。

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
