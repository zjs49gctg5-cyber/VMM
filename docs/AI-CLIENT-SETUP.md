# AIクライアント別のMCP・スキル設定

VMMのMCPは、同じMac・同じユーザーで動くローカルのクライアント向けです。MCPはVMMを操作する接続、`vmm-control` スキルはAIに操作手順を伝えるファイルです。それぞれ別に設定します。Web上の会話や別マシンのクラウド実行から、このローカル接続には直接つながりません。

このページは各クライアントの公式仕様に基づく設定例です。VMMのMCPを使った編集操作はCodex（ChatGPT）で確認しています。Gemini CLI 0.68.0では隔離したテスト環境でMCP接続とスキルの検出を確認しましたが、Geminiによるツール呼び出し・編集は未確認です。Claude Code・Claude Desktopでの接続や編集操作は未確認です。クライアントのバージョンや実行環境により表示や設定方法が変わる場合があります。ChatGPTやGeminiのWeb版にはローカルstdioブリッジを直接登録できません。

## 共通の準備

1. MacでVMMを起動し、メニュー「VMM → MCP接続…」を開いて「MCP接続を有効にする」をオンにします。VMMを開いたままにしてください。起動時は毎回オフです。
2. 「MCPクライアント設定をコピー」を押します。コピーされるJSONには `mcpServers` → `vmm` の `command` と `args` が入っています。以下の例の値は自分のMacでコピーした値に置き換えてください。アプリを移動した場合は再取得します。
3. 操作スキルを使うには、このリポジトリをMacに用意します。`skills/vmm-control` フォルダ全体に `SKILL.md`、リファレンス、補助スクリプトが入っています。アプリだけを入れてもスキルは自動登録されません。
4. 接続後、まずAIに「VMMの現在の状態を確認して」と依頼します。`vmm_state` が利用できることを確認してから編集を依頼してください。

設定例の `<...>` は説明用の印です。実際の設定に山括弧を残さず、コピーした絶対パスを使用してください。接続情報ファイルには認証トークンがあるため、その中身をチャットやGitへ掲載しないでください。コピーされるクライアント設定にはトークン自体は含まれません。

## Codex CLI・アプリ

### MCP接続

Codex CLIのインストール済み環境では、ターミナルで次を実行します。`<command>` と `--connection` の次の値は、VMMからコピーした `command` と `args` に置き換えます。パスは引用符で囲んでください。

```sh
codex mcp add vmm -- "<command>" --connection "<接続情報ファイルの絶対パス>"
codex mcp list
```

または `~/.codex/config.toml` に以下を追加します。既存の設定を消さず、`vmm` が既にある場合はその項目を更新します。JSONをTOMLへそのまま貼り付けることはできません。

```toml
[mcp_servers.vmm]
command = "<コピーしたcommand>"
args = ["--connection", "<コピーした接続情報ファイルの絶対パス>"]
```

新しいCodexセッションを開始し、MCPの一覧や状態を確認します。Codexアプリでもローカル実行環境からこの設定を利用できますが、使用する環境やバージョンによって設定・承認画面が異なる場合があります。

### スキル

Codexを起動する作業フォルダの `.agents/skills/vmm-control/`、またはユーザー共通の `~/.agents/skills/vmm-control/` に、同梱の `skills/vmm-control` フォルダを丸ごとコピーします。既存の同名フォルダを上書きする前に内容を確認してください。新しいセッションで `$vmm-control` を指定して利用できます。

たとえばリポジトリのルートをターミナルで開いた状態なら、ユーザー共通への新規コピーは次のように行えます。すでに同名フォルダがある場合は停止します。

```sh
mkdir -p "$HOME/.agents/skills"
test ! -e "$HOME/.agents/skills/vmm-control" && cp -R skills/vmm-control "$HOME/.agents/skills/"
```

公式： [Codex MCP](https://developers.openai.com/codex/mcp/)・[Codexのスキル](https://developers.openai.com/codex/skills/)

## Claude Code

### MCP接続

ターミナルで、コピーした値に置き換えて実行します。`--scope user` は現在のユーザーの複数プロジェクトで利用する設定です。

```sh
claude mcp add --scope user --transport stdio vmm -- "<command>" --connection "<接続情報ファイルの絶対パス>"
claude mcp list
```

Claude Codeのセッション内では `/mcp` でも接続を確認できます。プロジェクト単位で使う場合は、公式ドキュメントのスコープ設定を参照してください。

### スキル

使用するプロジェクトの `.claude/skills/vmm-control/`、またはユーザー共通の `~/.claude/skills/vmm-control/` に同梱の `skills/vmm-control` フォルダ全体をコピーします。既存の同名フォルダは確認してから更新します。新しいセッションで `/vmm-control` を指定できます。`agents/openai.yaml` はCodex向けの表示設定で、Claude CodeでのMCP登録とは別です。

リポジトリのルートからユーザー共通へ新規コピーする例です。同名フォルダがある場合は停止します。

```sh
mkdir -p "$HOME/.claude/skills"
test ! -e "$HOME/.claude/skills/vmm-control" && cp -R skills/vmm-control "$HOME/.claude/skills/"
```

公式： [Claude CodeのMCP](https://code.claude.com/docs/en/mcp)・[Claude Codeのスキル](https://code.claude.com/docs/en/skills)

## Gemini CLI

### MCP接続

ユーザー設定 `~/.gemini/settings.json`、または使用する作業フォルダの `.gemini/settings.json` の `mcpServers` に、VMMからコピーした `vmm` の項目を追加します。新規ファイルの形は次のとおりです。既存のJSONがある場合は、全体を置き換えず `mcpServers` の中へ統合してください。

```json
{
  "mcpServers": {
    "vmm": {
      "command": "<コピーしたcommand>",
      "args": ["--connection", "<コピーした接続情報ファイルの絶対パス>"]
    }
  }
}
```

Gemini CLIを起動して `/mcp` で接続状態を確認します。クライアント側で表示されるツール名にはサーバー名などの接頭辞が付く場合があります。

個人向けGoogleアカウントによるGemini CLIの利用は終了しています。Googleは個人ユーザーに[Antigravity CLIへの移行](https://github.com/google-gemini/gemini-cli/discussions/28017)を案内しています。Gemini CLIはGemini APIキーによる認証にも対応しています。

Gemini CLIで作業フォルダが未信頼と判定されるとMCPサーバーが無効になることがあります。信頼できる作業フォルダであることを確認し、Gemini CLIの信頼確認に従ってから接続状態を再確認してください。テスト用フォルダでのみ信頼設定を変更して検証しました。

### スキル

作業フォルダの `.gemini/skills/vmm-control/`、またはユーザー共通の `~/.gemini/skills/vmm-control/` に、同梱の `skills/vmm-control` フォルダ全体をコピーします。Gemini CLIは `.agents/skills/` も検出します。既存の同名フォルダを確認し、新しいセッションの `/skills list` で確認してください。スキルを有効にする際に確認が表示される場合があります。

公式： [Gemini CLIのMCP](https://geminicli.com/docs/tools/mcp-server/)・[Gemini CLIのスキル](https://geminicli.com/docs/cli/skills/)

## Antigravity CLI

Antigravity CLI 1.5.7の隔離環境で、ユーザー共通の `vmm-control` スキルを指定し、状態取得、画像・動画・音声の読み込みと配置、字幕用テキストの配置、プロジェクトの保存と再読み込み、VOICEVOXによる音声生成とMP4書き出しを確認しました。未保存の変更とロック済みレイヤーを保護する操作も確認しました。テストした入力動画・音声はMP4とWAVです。その他すべての素材形式や編集機能を検証したわけではありません。

接続設定は、使用する作業フォルダの `.agents/mcp_config.json`、またはユーザー共通の `~/.gemini/config/mcp_config.json` の `mcpServers` に、上記のGemini CLIと同じ形式でVMMからコピーした項目を統合します。既存ファイルは上書きせず、新しいセッションの `/mcp` で接続状態を確認してください。

ツール名は、すべてのクライアントで `vmm_state`、`vmm_clip_add` のようにアンダースコアを使います。以前の `--compatible-tool-names` オプションもそのまま使えます。スキルは作業フォルダの `.agents/skills/vmm-control/` またはユーザー共通の `~/.gemini/config/skills/vmm-control/` に同梱フォルダをコピーし、新しいセッションで `/vmm-control` と指定します。既存の同名スキルを更新するときは、内容を確認してから入れ替えてください。詳しくは[AntigravityのMCP設定](https://antigravity.google/docs/mcp?tab=cli)を参照してください。

## Claude DesktopのローカルMCP

Claude DesktopのローカルMCP設定では、VMMがコピーした `mcpServers.vmm` 項目を、macOSの `~/Library/Application Support/Claude/claude_desktop_config.json` の `mcpServers` に統合します。ファイルがない場合は上記のGemini CLIと同じJSONの形で作成できます。既存項目を消さず、設定後にClaude Desktopを再起動し、接続画面で確認してください。

これはClaude DesktopのローカルMCP設定です。Claude Codeの設定とは別で、Coworkやclaude.aiのリモート接続はこのMac上のstdioブリッジへ直接接続できません。Claude Desktopへのスキル登録はClaude Codeのローカルスキル配置と同じとは限りません。対応画面・プランについては公式案内を確認し、未対応ならMCP操作の指示を会話に明示してください。

公式： [Claude DesktopのローカルMCP](https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop)・[ローカルとリモート接続の違い](https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp)

## つながらないとき

- VMMが起動中で、MCP接続がオンか確認します。再起動後は再度オンにしてください。
- コピーした `command` と `args` が現在のアプリの場所を指しているか確認します。移動・更新後は設定を見直してください。
- VMMとクライアントが同じMac・同じユーザーで動いているか確認します。コンテナやクラウド環境からは接続情報やローカルソケットにアクセスできない場合があります。
- 設定ファイルのJSON/TOMLの構文と、既存の `vmm` 設定の重複を確認し、クライアントを再起動します。認証情報ファイルの内容は共有しないでください。
- 接続の停止は、すでに開始した生成・書き出しジョブの中止とは別です。必要な場合はVMM側の制作画面から中止します。

詳しいMCPの動作とツールは [VMM MCP接続](CONTROL-MCP.md) と [操作リファレンス](../skills/vmm-control/references/operations.md) を参照してください。
