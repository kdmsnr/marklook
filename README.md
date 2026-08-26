# MarkLook

**保存しても、読みかけの場所はそのまま。**

MarkLookは、ローカルのMarkdownとHTMLに特化したmacOS用の読み取り専用ビューアです。
エディタでファイルを保存すると、白いフラッシュやページ先頭への巻き戻りを起こさず、表示だけを更新します。

> macOS 14以降 / Apple Silicon / ローカルファイル専用

## 特長

- **スクロール位置を保った自動更新** — 見出しや段落を基準に、読んでいた位置を維持したまま変更を反映します。通常保存とatomic saveの両方に対応しています。

- **読むことに専念できる表示** — GFM、脚注、数式、タスクリスト、表、ローカル画像、コードハイライトに対応。ライト／ダークモードにも追従します。

- **ローカルで完結** — 文書や依存素材を外部へ送信しません。HTMLは静的DOMとしてサニタイズし、文書に含まれるJavaScriptやリモート資源を実行・取得しません。

- **macOSらしいファイル操作** — Finder、`⌘O`、ドラッグ＆ドロップ、Open Recentから開けます。標準のウィンドウタブ、検索、ズーム、印刷にも対応しています。

- **表示を好みに合わせて調整** — Settingsから本文の最大幅とMarkdownの改行方法を変更でき、ウィンドウ全幅表示にも切り替えられます。

## 対応形式

| 形式 | 拡張子 | 主な対応内容 |
| --- | --- | --- |
| Markdown | `.md`, `.markdown` | GFM、脚注、インライン／ブロック数式、安全な生HTML |
| HTML | `.html`, `.htm` | インラインCSS、許可されたローカルCSSと画像 |

リンク先のHTTP(S) URLはアプリ内で読み込まず、クリックしたときだけ既定のブラウザへ渡します。

## ショートカット

| 操作 | キー |
| --- | --- |
| ファイルを開く | `⌘O` |
| 新しいタブ | `⌘T` |
| 再読み込み | `⌘R` |
| 本文検索 | `⌘F` |
| ズームイン／アウト／リセット | `⌘+` / `⌘-` / `⌘0` |
| 戻る／進む | `⌘[` / `⌘]` |
| 印刷 | `⌘P` |

## ビルド

必要なもの：

- macOS 14以降
- Apple Silicon Mac
- Xcode 26以降

```sh
git clone https://github.com/kdmsnr/marklook.git
cd marklook

xcodebuild \
  -project MarkLook.xcodeproj \
  -scheme MarkLook \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  build
```

ビルドされたアプリは次の場所に生成されます。

```text
.build/DerivedData/Build/Products/Release/MarkLook.app
```

Xcodeで開発する場合は`MarkLook.xcodeproj`を開き、`MarkLook` schemeを選択してください。

## テスト

```sh
xcodebuild \
  -project MarkLook.xcodeproj \
  -scheme MarkLook \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  test
```

Release構成のリロードベンチマーク：

```sh
./script/run_reload_benchmarks.sh
```

## プライバシーと安全性

MarkLookはApp Sandbox内で動作し、ユーザーが選択したファイルと許可したフォルダだけを読み取ります。ローカル依存素材は専用スキーム経由で配信し、正規化後の実パスを許可範囲と照合します。WebViewは非永続データストアを使用し、文書内容、テレメトリ、分析履歴を保存・送信しません。

同梱ライブラリとライセンスは[Third-Party Notices](THIRD_PARTY_NOTICES.md)を参照してください。

## License

[MIT](LICENSE) © 2026 Masanori Kado
