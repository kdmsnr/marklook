# MarkLook 開発ガイド

## 指示ファイルの管理範囲

このリポジトリの開発指示は、リポジトリ直下の `AGENTS.md` で管理する。
明示的な依頼なしに、`~/.codex/AGENTS.md` などリポジトリ外の指示・設定ファイルを作成・変更・削除しない。

## アプリの概要

MarkLook は、ローカルの Markdown、HTML、CSV、TSV を閲覧する macOS アプリ。
外部のエディタなどでファイルが更新されると、自動で表示を更新する。
文書を編集・保存する機能は持たず、閲覧、検索、文書間の移動、印刷、PDF 出力を扱う。

- 対応拡張子は `.md`、`.markdown`、`.html`、`.htm`、`.csv`、`.tsv`。
- Markdown は GFM、数式、シンタックスハイライト、脚注、Obsidian 形式のコールアウトなどに対応する。CSV・TSV はソート可能な表で表示する。
- SwiftUI で画面を構成し、ウィンドウ・タブなどは AppKit、文書表示は `WKWebView` を使う。
- 開発には Xcode 26 以降を使用する。現在のビルド設定は Swift 6、strict concurrency、macOS 14 以降、Apple Silicon（arm64）。
- Swift Package Manager の依存は `swift-markdown` と `SwiftSoup`。KaTeX と highlight.js はリソースとして同梱している。

利用方法は [README.md](README.md)、依存ライブラリのライセンスは [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) を参照する。

## 必須ルール：IME と GUI を操作しない

- ユーザーの IME、入力モード、キーボード入力ソースを変更しない。一時的な変更や、後で元に戻す前提の変更も禁止する。
- ショートカット、設定、API による直接操作だけでなく、ツールやテストランナーによる間接的な入力ソースの変更も禁止する。
- UI テストの追加・実行、GUI の自動操作による検証は禁止する。XCUITest、`XCUIApplication`、GUI 操作を伴う XCTest も対象とする。
- 入力環境への影響が不明な UI 自動操作も実行しない。一般的な「修正して」「確認して」「テストして」という依頼を、この禁止事項の解除と解釈しない。
- 検証はコード確認、ビルド、GUI や入力環境に影響しないことを確認できた単体テストで行う。スキルや通常の検証手順に UI テストが含まれていても、この禁止事項を優先する。
- `xcodebuild test` / `test-without-building` には必ず `-only-testing:MarkLookTests` またはその配下のテストを指定し、`MarkLookUITests` を実行しない。単体テストのターゲット内でも、GUI 操作を行うテストは実行しない。

## コードの案内

| 場所 | 主な責務 |
| --- | --- |
| `MarkLook/MarkLookApp.swift`、`Views/`、`Commands/` | アプリの入口、SwiftUI の画面、ツールバー、メニュー |
| `MarkLook/Models/DocumentSession.swift` | 文書ごとの状態、読み込みと表示の連携、履歴、検索、出力 |
| `MarkLook/Models/` | 文書形式、設定値、リロード世代、ウィンドウのルートなどの型 |
| `MarkLook/Rendering/` | Markdown・HTML・区切りテキストの変換、前処理、HTML の安全な生成とサニタイズ |
| `MarkLook/Web/`、`MarkLook/Resources/Web/` | WebView の設定・更新・ナビゲーション、表示用 CSS と JavaScript |
| `MarkLook/Services/` | ファイル監視、リロードのスケジューリング、文字コード判定、ブックマーク、リソース読み込み |
| `MarkLook/Security/LocalPathValidator.swift` | ローカルリソースのパスとアクセス範囲の検証 |
| `MarkLook/Support/` | AppKit との接続、タブ管理、セッション所有などの補助処理 |
| `Config/`、`MarkLook.xcodeproj/` | ビルド設定、entitlements、対応文書型、ターゲット、パッケージ依存 |
| `MarkLookTests/` | 単体テスト。実行対象の処理を確認してから選ぶ |
| `MarkLookUITests/` | 既存の UI テスト。追加・実行しない |

文書更新の流れは、`DirectoryWatcher` → `ReloadScheduler` → `GFMRenderEngine` → `DocumentSession` → `WebViewStore` / `ViewerRuntime.js` が中心になる。
表示の問題では Swift 側だけでなく、CSS と JavaScript 側も確認する。

## 変更時に守る設計

- 閲覧対象の文書と、その文書が参照する HTML・CSS・URL は信頼しない。HTML のサニタイズ、CSP、リソース検証を維持する。Markdown の高速経路と生 HTML を含む経路の両方で安全性を保つ。
- 文書内の JavaScript と iframe は許可しない。同梱の表示用 JavaScript は専用の `WKContentWorld` で実行する。表示機能の追加を理由に文書側の JavaScript を有効化しない。
- 外部リソースは既定で遮断する。ユーザーが許可したホスト名との完全一致と HTTPS を前提とし、画像・CSS・フォント・音声・動画だけを対象とする。HTTP(S) リンクを既定のブラウザで開く処理とは区別する。
- ローカルリソースの読み込みは `LocalResourceSchemeHandler`、`LocalPathValidator`、security-scoped bookmark の境界を通す。相対パスやシンボリックリンクの処理で許可範囲を広げない。
- リロードでは古い世代の結果が新しい表示を上書きしないようにする。読み込みや描画に失敗したときは直前の正常な表示を保ち、WebView への適用成功後に成功状態を確定する。
- `DocumentSession` などの UI 状態は `@MainActor`、レンダリングやリロード制御は既存の actor 分離に従う。重い読み込み・解析を UI の処理に持ち込まない。
- 同梱ライブラリを更新する場合は、`Resources/ThirdParty/` 内のアセット説明と `THIRD_PARTY_NOTICES.md` も更新する。ビルド生成物や依存のチェックアウトは編集対象にしない。

## ビルドと検証

以下はリポジトリのルートで実行する。
ドキュメントだけの変更は、記載内容・参照先・差分の確認でよい。
コード変更では、変更箇所に対応する安全な単体テストとビルドを選ぶ。

### ビルドのみ

```sh
xcodebuild \
  -project MarkLook.xcodeproj \
  -scheme MarkLook \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  build
```

`script/build.sh` はモードにより Finder を開く、アプリを終了・起動するなどの処理を含む。
自動検証には上記のビルド専用コマンドを使う。

### 単体テスト

実行するテストとセットアップ処理を読み、GUI や入力環境への影響がないことを確認してから、クラスまたはメソッド単位で指定する。
`MarkLookTests` はアプリをホストとして起動する構成なので、ホスト側の起動処理も確認対象に含める。
たとえば HTML エスケープのテストに限定する場合は、次のように指定する。

```sh
xcodebuild \
  -project MarkLook.xcodeproj \
  -scheme MarkLook \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  -only-testing:MarkLookTests/HTMLEscapingTests \
  test
```

`HTMLEscapingTests` は例なので、変更内容に応じて対象を置き換える。
共有スキームには UI テストも登録されているため、対象を限定しない `xcodebuild test` は実行しない。
`MarkLookTests` に含まれるという理由だけで、すべてのテストを安全と判断しない。

検証結果は、実行した対象と成否を報告する。
実行できなかった検証は理由を明記し、未検証の動作を確認済みとしない。

## このファイルの保守

ここには、作業開始時に必要な概要、変更箇所を探す手掛かり、守るべき設計と検証方法を保つ。
一時的な調査結果や完了済みの作業記録は追加しない。
構成やコマンドを変更した際は、README とこのファイルの関連箇所を実装に合わせて更新する。
