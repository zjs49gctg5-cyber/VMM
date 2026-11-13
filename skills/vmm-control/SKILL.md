---
name: vmm-control
description: VMMのMCPツールを使って、Mac上の動画プロジェクトに脚本・字幕・素材を配置し、アニメーションやエフェクトを編集、保存、動画出力する。VMMでの動画制作・自動編集を依頼されたときに使う。
---

VMMを開いたMacでMCPツールを使う。VMMの「MCP接続…」から有効化し、コピーしたクライアント設定のcommand/argsをMCP対応クライアントに登録する。旧HTTP APIとVMM_API_TOKENは廃止済み。認証情報は同じユーザー専用の接続ファイルで管理され、チャットやコミットに出さない。

- 編集前に `vmm_state` と `vmm_capabilities` で現在の編集状態・素材・ID・レイヤー・生成状況を確認し、`vmm_catalog` で共有キャラ・素材・テンプレートを調べる。
- 必要な操作とモデルを [操作リファレンス](references/operations.md) で確認する。MCPツール名は `vmm_clip_add` のように、操作名のピリオドをアンダースコアにし `vmm_` を付ける。時間は秒、割合は1=100%、レイヤーは0起点。入れ子のpropertiesは全体置換なので、現在値を読み、依頼された項目だけ変更する。
- 脚本は `vmm_script_import` にUTF-8の「キャラ名：セリフ」を渡す。名前をキャラ定義と一致させる。字幕だけの変更は `vmm_character_applyCaptions` を使い、音声や立ち絵も変えるapplyAllと区別する。
- 非同期処理の戻り値のjobIDを `vmm_job` に渡して完了/失敗を調べる。切断・タイムアウトは失敗とは限らないので、既存ジョブ・状態を確認し、重複した素材追加や出力を起こす再送を避ける。MCPのキャンセル通知は全体の生成・書き出しを中止しない。明示的なspeech.cancel/export.cancel等は全体対象として扱う。
- 保存前に `vmm_state` で編集結果を確認する。出力前にgeneratingSpeechが空で、対象のspeechDirtyがfalseであることを確認し、`vmm_export_preflight` の結果を調べる。`vmm_project_save` はasync:trueを優先する。`vmm_export_start` のjob完了と出力を確認して報告する。

起動済みプロジェクトの未保存変更と元素材を保持し、ユーザーが依頼した編集範囲だけ操作する。切替前に `vmm_state` の `dirty` と `projectPath` を確認し、未保存なら適切な保存先に保存する。古いVMMでこれらの項目がない場合、保存済みとは判断しない。依頼から必要性を判断できないdiscardChangesや別ファイルへのoverwriteは指定しない。編集はUndo可能だが、設定・共有ライブラリの保存・出力はUndo対象外。busyやロックエラーは状態を調べ、無関係なアイテム削除などで回避しない。実音声エンジンの推論を実行していない場合は、推論成功として報告しない。

MCPツールが直接利用できない実行環境では、同じMCPを使う `scripts/vmm.py` をPython 3から実行できる。`--helper` にコピーした設定のcommand、`--connection` にargsの接続ファイルを指定する。`state` / `tools` / `command 編集JSON` / `script 原稿.txt` / `job ID --wait` を使える。HTTPには接続しない。既存編集を保存せず、検証目的で勝手にMCPを有効化しない。
