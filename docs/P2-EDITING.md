# コピー・リップル削除・素材管理

- ⌘C／⌘Vで同じプロジェクトのアイテムをコピーし、選択レイヤーの再生位置へ貼り付けます。親をコピーすると子もコピーし、内部の親IDを対応付けます。親を含めず子だけコピーすると貼り付け時は親から独立します。プロジェクトをまたぐ素材移動は既存の共有ライブラリを使用してください。
- Shift＋Deleteまたは右クリックのリップル削除は、選択したアイテムの削除区間を重複分まとめて詰め、全レイヤーの後続アイテム・マーカー・範囲を移動します。重なる選択外アイテムと後続のロック済みアイテムがある場合は適用を止め、説明します。親を選択すると子も対象です。
- 動画を右クリックして「映像と音声を分離」。素材をコピーせず音声アイテムを別レイヤーに置き、元動画の音声を無効化します。素材オフセット、速度、EQ、音量を保ち、二重再生を防ぎます。音声トラックがない動画は説明します。
- 素材のタグアイコンで最大32個のタグを編集できます。検索は名前とタグを対象にします。使用中／未使用フィルタは、立ち絵の口差分・画像マスクの参照も含めます。
- 「未使用素材の登録を解除」は生成音声を除く未使用素材を一覧から外す操作です。Finderの元ファイル・プロジェクトのMediaファイルは削除せず、Undoで戻せます。次回保存するパッケージは現在の登録素材だけを含みます。

MCPの対応操作は `selection.copy/paste/rippleDelete`、`clip.separateAudio`（job）、`media.tags`（assetIDとtags配列）、`media.cleanupUnused`、`caption.import`（text/format/start）、`caption.export`（format。本文をJSONで返す）です。`project.update` にはmasterVolume/markers/timelineRange、`clip.update`にはaudioDisabled/normalizationGain/measuredLUFSを使用できます。外部操作は通常起動時に無効で、同一ユーザーの認証付きローカルMCP接続を使用します。

Copy/paste operates within one project, retaining relative timing and internal parent relationships. Ripple deletion closes the union of selected intervals across all layers, with overlap and locked-layer protection. Video/audio separation creates an audio clip referencing the same source and disables the original video's audio. Tag search and used/unused filters include mouth and mask references. Unused-media cleanup removes registrations only; source and Media files remain intact and Undo restores registrations.
