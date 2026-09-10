# 作業ルール

- UI テストの追加・実行や、GUI の自動操作による検証は禁止する。
- 検証はコード確認、単体テスト、ビルドで行う。
- `xcodebuild test` を使う場合は `-only-testing:MarkLookTests`（またはその配下のテスト）を指定し、`MarkLookUITests` を実行しない。
