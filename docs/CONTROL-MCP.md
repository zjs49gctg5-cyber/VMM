# VMM MCP接続

VMMの外部操作はMCPを使用します。MCPツールはアプリ内の編集処理を直接呼び出します。公開HTTP操作APIはありません。

Codex・Claude Code・Gemini CLI・Claude Desktopの設定場所と、操作スキルの導入は[AIクライアント別の設定手順](AI-CLIENT-SETUP.md)を参照してください。

MCPを使ったVMMの編集操作はCodex（ChatGPT）で確認しています。Antigravity CLI 1.5.7では隔離環境で `vmm-control` スキルを指定し、素材の読み込み・配置、字幕、保存・再読み込み、VOICEVOXでの音声生成・書き出し、未保存変更とロック済みレイヤーの保護を確認しました。Gemini CLI 0.68.0では隔離環境でMCP接続とスキル検出を確認しましたが、Geminiによるツール呼び出し・編集は未確認です。Claude Code・Claude Desktopでの接続や編集操作は未確認です。

## 接続

1. 新しいVMMを起動し、メニュー「VMM → MCP接続…」で有効にします。起動時は毎回無効です。
2. 「MCPクライアント設定をコピー」で取得したJSONを、stdioに対応するMCPクライアントへ登録します。クライアントによって設定ファイルの外側の形式は異なります。必要なcommand/argsは共通です。
3. VMMを開いた状態で接続します。ツール一覧に `vmm_state`、`vmm_clip_add` 等が出ます。アプリを別の場所へ移動/更新した場合はhelperのcommandを更新してください。

配布アプリには `Contents/Helpers/VMMMCPBridge` を同梱します。stdioのJSON-RPCを認証付きのUnixソケットへ中継します。編集処理・MCPのツール実行はVMMアプリ内です。同じユーザーのみ接続可能で、socketの親フォルダーは0700、socketと接続情報ファイルは0600です。認証トークンは設定JSONに含まず、再度有効化すると更新されます。TCP/HTTPポートは開きません。

接続情報は既定で `~/Library/Application Support/VMM/mcp-connection.json`。停止時に自分の接続ファイルとソケットを削除し、接続済みクライアントも閉じます。MCPの停止だけでは既に開始した編集ジョブを取り消しません。制作画面から生成/書き出しを中止できます。

## 操作

[操作・モデルリファレンス](../skills/vmm-control/references/operations.md)に全コマンドとモデル設定を記載しています。操作名のピリオドをアンダースコアに変えて `vmm_` を付け、パラメーターをMCP tools/callのargumentsへ渡します。旧形式の `vmm.state` などの呼び出しも受け付けます。たとえば:

```json
{"name":"vmm_clip_add","arguments":{"kind":"text","track":1,"properties":{"text":"MCPから追加","duration":3}}}
```

初期化応答の `serverInfo.version` はアプリのバージョン・リリース区分・ビルド番号を使用します（例：`0.1.0-beta+build.1`）。取得できない開発環境では `0.0.0-dev` です。

`tools/list` は操作ごとのJSON Schemaを返します。読み取りはstate/capabilities/catalog/extensions/settings/exportQueue/job。戻り値はstructuredContentと同内容のtextです。非同期処理はjobIDを返し、`vmm_job`に渡すと完了/失敗を確認できます。MCP TasksやResources、Promptsは現段階では提供していません。MCPキャンセル通知で全体の生成・出力を中止することはありません。中止は明示的な専用ツールで行います。

`vmm_state` の `dirty` は未保存の変更の有無、`projectPath` は現在の保存先（未保存ならnull）です。プロジェクトを切り替える前に確認してください。

プロトコルは2025-11-25、2025-06-18、2025-03-26、2024-11-05に対応。initialize/initialized、ping、tools/list、tools/callを実装。リクエストは1MiB、同時接続は8までです。認証前の接続には3秒の制限があります。標準出力にはMCPメッセージだけを出します。

## バッチ操作と操作スキル

[操作スキル](../skills/vmm-control/SKILL.md)と[AGENTS.md雛形](../automation/AGENTS.md.template)を用意しています。Python CLIもHTTPではなくMCPクライアントとして動きます。

VMMの「MCPクライアント設定をコピー」で示されるヘルパーのパスを、環境変数 `VMM_MCP_HELPER` に設定してから、リポジトリのルートで実行します。

```sh
python3 skills/vmm-control/scripts/vmm.py state
```

`--connection`を省略すると標準の接続ファイルを使います。`VMM_MCP_HELPER` / `VMM_MCP_CONNECTION`でも指定できます。`command 編集.json`は従来のcommand項目をMCPのツール名に変換します。プロバイダーのAPIキーは不要です。

未保存編集の保持、ロック判定、Undo、一括編集の原子性、上書きの明示指定、ジョブ管理は維持します。切断/タイムアウトのあと同じ編集を無条件に再送せず、状態と既存jobIDを確認してください。

仕様の参照元：[MCP lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)、[stdio transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)、[tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)。

## 音MADモード

VMMでは `vmm_rhythm_quantize`・`fit`・`pattern` を使用できます。詳細は[音MADモード](AUDIO-MAD-MODE.md)と操作リファレンスを参照してください。


### 音声連動・動画追跡

- `vmm_animation_analyzeAudio`: `clipID`, `sourceClipID`。音量／低音／アタックを解析して対象へ記録。最大1時間。jobIDを返す。
- `vmm_animation_track`: `clipID`, `sourceClipID`, `region:{x,y,width,height}`, `sourceIn`, `duration`, 任意の`sampleRate`（既定15）, `followScale`（既定false）。動画の矩形を追跡し、編集可能な移動パスへ変換。最大30秒。低信頼度で停止。jobIDを返す。

解析開始時の対象が変更された場合は適用を拒否する。`vmm_job`で完了／失敗と結果を読む。描画設定は `vmm_clip_update` のOptional項目 `shapeStyle.path`, `masks[].path`, `temporalMotion`, `audioReactive`, `tracking` に保存する。詳しい時刻・座標・制限は[高度なアニメーション](ADVANCED-ANIMATION.md)を参照。


### ブラー・残像の中間点

`vmm_clip_update` で `temporalMotion` と `animation.tracks` を更新する。追加したAnimatedPropertyは `shutterAngle`（0〜360°）, `blurSamples`（2〜16）, `trailCount`（0〜12）, `trailDuration`（0.001〜3秒）, `trailOpacity`（0〜1）。temporalMotionを追加した描画アイテムでのみ使用できる。数は描画時に整数へ丸め、時間軸は従来と同じanimationOffsetを基準にする。ネスト設定は全体置換なので既存の他のトラック・値を保持して更新する。旧プロジェクトに必須フィールドは追加しない。
