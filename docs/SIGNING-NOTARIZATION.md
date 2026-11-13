# macOS配布用の署名・公証 / Signing and notarization

Developer ID署名・公証は未検証です。以下は資格情報を準備した後に実行する手順です。通常の `build-app.sh` はローカル検証用のアドホック署名です。

## 公開前の確認

`build-app.sh` は、アプリ本体と2つのヘルパーからデバッグ用シンボルを除去してから署名します。また、現在のホームディレクトリと実際のビルド作業ディレクトリのパスが3つの実行ファイル内に残っていれば、署名前に停止します。この検査は現在の環境のパスを対象とするもので、別の環境のパスやすべての秘密情報を検出する保証はありません。公開するアプリ、付属資料、画像やその他のファイルも確認してください。

Git履歴には、現行ファイルから削除した情報も残ることがあります。公開前に履歴も確認し、必要に応じて履歴を除いた公開用リポジトリを用意するか、関係者と調整して履歴を整理してください。履歴の書き換えはコミットIDを変更するため、バックアップと共有先への影響確認が必要です。既に公開済みの履歴がある場合、書き換え後もコピーやキャッシュが残る可能性があります。

`dist` はGitの追跡対象外ですが、過去のテスト用アプリなどを含むことがあります。旧ビルドには今回のデバッグシンボル除去が適用されていない場合があるので、フォルダごと共有せず、配布するアプリを個別に検査してください。通常ビルドはZIPを作成しません。

## 準備

1. Apple Developer ProgramでDeveloper ID Application証明書を発行し、秘密鍵とともにこのMacのキーチェーンへ登録します。秘密鍵・パスワードはチャットやGitへ保存しません。
2. Xcodeのコマンドラインツールを設定し、`xcrun --find notarytool` と `xcrun --find stapler` を確認します。
3. `security find-identity -v -p codesigning` で有効なDeveloper ID Application名を確認します。
4. ターミナルで `xcrun notarytool store-credentials "vmm-notary"` を実行し、対話入力でApple ID、Team ID、アプリ用パスワードを登録します。スクリプトにはキーチェーンのプロファイル名だけを渡します。

## 実行

まず新しい出力先を指定して `scripts/build-app.sh` でリリース用アプリを作ります。既存のdistは上書きできません。

```sh
zsh scripts/build-app.sh "$PWD/dist/VMM-new-build.app"
scripts/sign-notarize.sh --app "$PWD/dist/VMM-new-build.app" \
  --identity 'Developer ID Application: YOUR NAME (TEAMID)' \
  --profile vmm-notary --dry-run
```

資格情報を用意してから `--dry-run` を外すと、Appleへのアップロードを含む実処理が始まります。UUID相当のランダムな専用フォルダを作ってコピーを署名するため、入力アプリ・過去の配布物は保持されます。処理はHardened Runtimeとタイムスタンプ付き署名、検証、公証、Accepted判定、チケット添付、Gatekeeper評価、最終ZIP作成の順です。配布するのは `*-notarized.zip` です。`submission.zip` はチケット添付前の提出用です。

公証結果とログは同じフォルダに保存されます。失敗時はログを確認して修正し、新しいフォルダで再実行します。既存フォルダを再利用しません。将来FrameworkやXPCを同梱した場合は、スクリプトが処理を停止するので内側から明示的に署名する処理を追加してください。

署名後のアプリで動画プレビュー、音声再生、ローカル音声エンジン通信、MP4出力を確認し、別のMacへダウンロードしたZIPでも起動を確認します。追加のentitlementsは現在設定していません。実機検証なしに配布可能と断言しないでください。

## English

Developer ID signing and notarization have not been tested. Install your Developer ID Application certificate and private key in Keychain, configure Xcode command line tools, and run `xcrun notarytool store-credentials "vmm-notary"` interactively. Never put passwords or private keys in source control or chat.

The build removes debug symbols and checks the three executables for the current home and build-directory paths before signing; this is not a complete secrets scan. Git history and older local builds may retain information removed from current files. Review the history and each artifact you intend to publish. Rewriting history changes commit IDs and does not remove existing copies or caches.

Build to a new destination, then run the command above with your identity and Keychain profile. `--dry-run` makes no changes and does not contact Apple. Remove it only when ready to upload. The script works on a separate copy, verifies hardened-runtime signatures, requires an Accepted notarization result, staples and validates the ticket, assesses Gatekeeper, and packages the stapled app. Distribute the `*-notarized.zip`, not `submission.zip`. Keep the result and diagnostic logs. Test playback, speech engines and export in the signed app and launch the downloaded archive on another Mac before release.

## Appleの一次資料

- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)

## プラグイン対応との関係

Developer ID署名・公証なしでもアプリの公開・配布自体はできる。公開できるかと、Gatekeeperで警告なく起動できるかは別の条件である。ローカル開発・検証は現在のアドホック署名で進められる。プラグイン機能を作るためだけにDeveloper ID証明書を直ちに用意する必要はない。一方、第三者へダウンロード配布して通常のGatekeeper設定で起動してもらうための配布版では、プラグインの有無にかかわらずDeveloper ID署名・公証を整備する。今回のJSON拡張を利用するための必須条件ではない。[Apple：Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。

VMMのJSONアニメーション拡張は、パッケージ自体に署名を要求しません。JavaScriptを含む定義は、読み込み時には実行せず、ユーザーが生成を指示したときに専用ワーカーで実行します。配布元の確認や内容検証は別途行う。アプリ本体の配布署名とは別の話であり、拡張を追加するたびにアプリ本体を改変・再署名する構成にはしない。

ネイティブ実行コードを追加する段階では、アプリ・XPCホスト・配布する実行バイナリの署名／公証と権限設計を確認する。Hardened RuntimeのLibrary Validationは、本体と同じTeam IDまたはAppleで署名されたライブラリ等にロードを制限するため、他の開発者によるプラグインを本体へ直接ロードする方式には追加の設計が必要。[Apple：Disable Library Validation Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)。

VMMでは別プロセスのホストを候補とし、本体の保護を広く解除する方式は初期案にしない。XPCを利用するだけで第三者コードの署名や権限問題がすべて解消するわけではなく、ワーカー側の検証・署名・隔離を設計する。現在のsign-notarize.shはXPC等が含まれると停止するため、SDK／ホストを実装する時点で内側から署名する処理を追加する。

## ヘルパーの署名

`Contents/Helpers/VMMAnimationWorker` と `VMMMCPBridge` を同梱します。通常ビルドは両ヘルパー、本体の順でアドホック署名し、`sign-notarize.sh` でもヘルパーからDeveloper ID署名します。JIT用entitlementsやLibrary Validationの解除は追加していません。Developer ID署名・公証は未検証です。JavaScript定義は読み込み時には実行せず、生成時に専用ワーカーで実行します。[JavaScriptの仕様と検証](JAVASCRIPT-ANIMATIONS.md)
