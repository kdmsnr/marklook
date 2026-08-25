# MarkLook

MarkLook は、macOS 14 以降でローカルの Markdown／HTML を安全に閲覧するための読み取り専用ビューアです。v1 の名称、Bundle ID、アイコン、配布方法は仮設定です。

## 対応環境

- macOS 14 以降
- Apple Silicon（arm64）のみ
- Xcode 26 以降

## ビルド

```sh
xcodebuild \
  -project MarkLook.xcodeproj \
  -scheme MarkLook \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  build
```

Xcode からは `MarkLook.xcodeproj` を開き、`MarkLook` scheme を選択します。開発用のビルド・起動・ログ確認には `script/build_and_run.sh` も使えます。

## テスト

```sh
xcodebuild \
  -project MarkLook.xcodeproj \
  -scheme MarkLook \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  test
```

Release 構成のリロード・ベンチマークは次で実行します。

```sh
./script/run_reload_benchmarks.sh
```

## セキュリティ設計

- App Sandbox と security-scoped bookmark で、ユーザーが選択したファイル／フォルダだけを読み取ります。
- `WKWebView` の補助プロセスを起動するため、App Sandbox のネットワーククライアント権限を有効にしています。文書からの外部通信を許可するものではありません。
- 文書の JavaScript は無効です。アプリ管理の DOM 更新コードだけを隔離された `WKContentWorld` で実行します。
- HTML は同梱サニタイザーを通し、実行要素、イベント属性、フォーム、リモート資源を除去します。
- ローカル依存素材は `mark-resource:` scheme から配信し、正規化後の実パスを許可範囲と照合します。
- WebView は非永続データストアと厳格な CSP を使用し、HTTP(S) をアプリ内では読み込みません。
- 文書内容、テレメトリ、分析履歴は永続化しません。

同梱ライブラリとライセンスは [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) を参照してください。
