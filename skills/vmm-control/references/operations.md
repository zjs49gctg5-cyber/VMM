# VMM MCP操作・モデルリファレンス

外部操作はMCPのみです。旧HTTP API・ポート39393・VMM_API_TOKENは使用しません。

VMMのメニュー「MCP接続…」で有効化し、「MCPクライアント設定をコピー」で取得したcommand/argsを対応するクライアントに登録します。VMMMCPBridgeはstdioのJSON-RPCを扱い、VMM内の編集処理へ認証付きUnixソケットで接続します。同じMacのユーザーのみ、起動時は無効です。接続ファイルはユーザー専用の0600、ソケット用フォルダーは0700です。設定JSONに認証トークンは含まれません。アプリを更新して場所が変わった場合は設定をコピーし直します。

読み取りツールは `vmm_state`、`vmm_capabilities`、`vmm_catalog`、`vmm_extensions`、`vmm_settings`、`vmm_exportQueue`、`vmm_job`（jobID）。初回接続にはinitialize → notifications/initializedが必要で、MCPクライアントと同梱CLIが処理します。対応版は2025-11-25、2025-06-18、2025-03-26、2024-11-05。リクエストは1MiB以内、同時接続上限8です。

## コマンド

| command | パラメーター |
|---|---|
| `clip.add` | `kind`、任意の `track`（0から始まる）、`properties`。戻り値に `clipID` |
| `clip.update` | `clipID`、`properties` |
| `clip.delete` / `clip.duplicate` / `clip.split` | `clipID`。分割は現在の再生位置で実行 |
| `select` | `clipID` |
| `seek` | `time`（秒） |
| `play` / `pause` | なし |
| `undo` / `redo` | なし |
| `voice.connect` | なし。VOICEVOXへの接続を開始 |
| `speech.generate` | セリフアイテムの `clipID`。非同期で生成を開始 |

`properties` はClipのJSONと同じ形式で、指定した項目を更新します。例：`text`、`name`、`start`、`duration`、`x`、`y`、`scale`、`rotation`、`opacity`、`color`、`fontSize`、`volume`、`speakerID`、`animation`、`effects`、`adjustmentRegion`、`parentID`など。x/yと幅・高さは0〜1を100%とする割合、回転は度、時刻は秒です。入れ子の設定はオブジェクト全体を指定してください。省略したプロパティは保持します。`id`や`kind`の更新はできません。

素材は `media.import` で読み込み、完了ジョブのassetIDsをclip.addのassetIDに指定します。

## 制作ワークフローのコマンド

| command | パラメーター |
|---|---|
| `script.import` | `text`、任意の`start`、`track` |
| `dictionary.set` | `entries`: `{id:UUID,word,reading}` の配列 |
| `character.capture` / `character.apply` | 選択字幕から`name`で保存 / `characterID`を選択へ適用 |
| `selection.set` | `clipIDs`配列。空で選択解除 |
| `selection.update` / `selection.delete` / `selection.duplicate` | `properties`を一括適用 / 選択削除 / 選択と子を複製 |
| `selection.arrange` | `mode`: 左揃え、上揃え、中央、開始揃え、順番 |
| `settings.update` | `properties`。UI・保存・出力設定 |
| `project.new` | 任意のname。空のプロジェクトを開始。未保存を破棄する場合だけdiscardChanges:true |
| `project.update` | `properties`: name,width,height,fps,background |
| `project.save` / `project.open` | 絶対`path`。別の既存保存先への上書きは`overwrite:true`、未保存を破棄して開くには`discardChanges:true`。`async:true`でjobID（大きいプロジェクトでは推奨）。省略時は互換性のため同期処理 |
| `project.autosave` | なし。復元履歴に保存 |
| `media.import` | 絶対パス配列`paths`。jobID |
| `media.relink` / `media.proxy` | `assetID`。再リンクは絶対`path`も指定。jobID |
| `library.saveTemplate` | `name`。素材込みテンプレートを保存 |
| `library.addAsset` / `library.importAsset` | `assetID` / catalogの共有素材フォルダー絶対`path` |
| `track.add` / `track.move` | `name` / `from`,`to` |
| `track.update` | `track`, `properties`: name,visible,muted,locked,effects,opacity,blendMode |
| `export.start` / `export.cancel` | 出力の絶対`path`（既存へ上書きは`overwrite:true`） / 中止。startはjobID |

読み取り: `vmm_settings`、`vmm_catalog`、`vmm_job`（jobID）。ジョブは`running`、`completed`（result付き）、`failed`（error付き）。状態取得はbusy中も可能です。処理中の編集はbusyエラー。export.cancelはbusy中も受け付けます。最大100件程度の完了ジョブをメモリに保持し、再起動で消えます。

字幕設定: `reading`は音声専用文字、`textRevealRate`は字/秒（nullで無効）、`textStyle.fontName`はmacOSのPostScript名、`tracking`は文字サイズ比（-0.2〜2）、`lineSpacing`は文字サイズ比（0〜2）、`captionWidth`は画面幅比（0.1〜1）。`textStyle.alignment`は`left`/`center`/`right`/`distributed`（省略時は中央）。`distributed`は最終行も含め文字間を配置幅に広げます。`ducking`はセリフ中の残り音量0〜1（audio/video、nullで無効）。

設定の例：`{ "command":"settings.update", "properties": { "exportContainer":"MOV", "exportCodec":"HEVC", "exportQuality":0.75, "rangeStart":0, "rangeEnd":10 } }`。rangeEnd=0は全体の終端。MP4/MOV、H.264/HEVCに対応。プロキシは720p以下の編集用MP4、出力は元素材を使用。フォント本体は共有パッケージに含みません。

## 付属CLI

`scripts/vmm.py` はPython 3標準ライブラリのみ使用。`state`、`capabilities`、`catalog`、`settings`、`command JSONファイル`、`script TXT --track 1 --start 0`、`job ID --wait`。commandのファイルを `-` にすると標準入力JSONを使用します。接続には `--helper` または `VMM_MCP_HELPER` で同梱VMMMCPBridgeを指定します。外部ネットワークへは接続しません。

## 呼び出しとエラー

以下の操作名はMCPツールでは `vmm_` を前に付け、ピリオドをアンダースコアにします。たとえば `clip.add` は `vmm_clip_add` です。`tools/list` で操作ごとの入力スキーマを取得できます。MCPの `tools/call` の `arguments` に表のパラメーターを渡します。command項目は不要です。

戻り値は `structuredContent`（同じJSONをtextにも含む）です。入力スキーマ不正はJSON-RPCエラー、編集時の不正モデル・ロック・busyは `isError:true` とエラー文字列を返します。非同期処理は `jobID` を返すので `vmm_job` に渡してください。切断・タイムアウト時に同じ編集を再送せず、先に状態・ジョブを確認します。

素材ライブラリの表示設定は `settings.update` の `properties` から変更できます。`libraryLayout`: `list` / `grid`、`librarySort`: `imported` / `name` / `kind` / `duration`、`libraryDescending`: Boolean、`libraryThumbnails`: Boolean。未指定時はリスト・登録順・昇順・サムネイル有効です。

UIサイズは `settings.update` の `properties` で `uiFontSize`（12〜24pt）、`uiIconSize`（12〜28pt）を指定できます。どちらも未指定時は12ptで、表示時に `uiScale` を掛けます。動画内の字幕の `fontSize` には影響しません。

画面のテーマは `settings.update` の `properties.uiTheme` に `system`、`light`、`dark` を指定します。未設定時は `system` です。

## PSDレイヤー・表情の時間指定

`clip.update` の `properties.psd` にPSD状態全体を渡すと、任意のレイヤー組み合わせを時間指定で切り替えられます。`vmm_state` の既存PSD状態を保持し、Optionalの `selectionKeys` に `{ "id":"UUID", "time":1.5, "name":"笑顔", "selected":[レイヤーID] }` を追加します。selectedはレイヤー選択全体のスナップショットです。timeはアニメーションの秒数で、通常はアイテム内の秒数、分割・左端トリム後はアイテム内秒数＋animationOffsetです。時刻は0〜86400秒、最大1024点、時刻・UUIDの重複は禁止です。PSD素材に存在するレイヤーIDを指定してください。

最初の点より前は基本のselected、指定時刻以降は直近の点を使用します。口パク・目パチは該当レイヤーへの自動切り替えが優先されます。

## 音MAD・拍グリッド

- `rhythm.update`：`properties` に `enabled`（有効／無効）、`bpm`（30〜300）、`division`（4分音符=1、8分=2、3連=3、16分=4、32分=8）、`offset`（開始秒）、`snap`、`visible` を指定。部分更新できます。
- `rhythm.quantize`：`clipIDs`、任意の`strength`（0〜1、既定1）。開始位置を拍に合わせます。
- `rhythm.fit`：`clipIDs`、`beats`（4分音符単位0.125〜64）。切り出し範囲と音程を保って長さを合わせます。速度25〜400%を超える場合は拒否します。
- `rhythm.pattern`：`clipID`、`pattern`（例 `0 0 - 7 12`）、任意の`start`秒、`gate`（0.05〜1、既定0.9）。半音差−24〜24、`-`は休符。拍間隔で新規コピーを配置しclipIDsを返します。元素材を保持します。
- 上記の拍合わせ・伸縮・パターンは、音MAD有効、生成済み音声／動画／セリフで、ロック・リンク・子のない素材を対象とします。一括操作は1回のUndo。歌唱の音高解析・母音のみの伸長は未対応です。
- `rhythm.repeat`：`clipID`、`count`（元アイテムを含む2〜64）、任意の `onGrid`（既定false）。trueなら先頭1グリッド以内に切り詰めて拍間隔で反復、falseなら選択区間を連続反復します。
- `rhythm.slice`：`clipID` の表示区間を拍グリッドで分割（最大512区間）。素材開始位置・速度・アニメーション時刻を保持します。
- `clip.update` の `properties.pitchSemitones`：−24〜＋24半音。再生と出力に反映し、再生速度とは独立。音声・動画・音声生成済みセリフに使用します。

拍はプロジェクトのフレームに丸めます。反復・分割はロック中、音声生成前、子を持つ親には適用できません。Optionalのproject.rhythm・clip.pitchSemitonesで保存され、旧プロジェクトは従来通り再生します。

音MAD設定は新規・従来のプロジェクトでは無効です。`rhythm.update` の `properties.enabled=true` で有効化します。falseで拍グリッド・拍スナップ・反復／分割・再生と出力のピッチ補正を停止し、保存値と配置済みアイテムを保持します。

## マーカー・字幕・素材の編集

`project.update`のpropertiesはOptionalの`masterVolume`（0〜2、省略時1）、`markers`（最大2,000点の `{id,time,name}`、timeは秒）、`timelineRange`（`{start,end,loop}`、start<end）にも対応します。`null`でマーカー・範囲を解除できます。字幕と書き出しは全プロジェクトの秒数、キーはanimationOffsetを含むアイテムのアニメーション秒数です。

| コマンド | 入力・結果 |
| --- | --- |
| `selection.copy` | 選択とその子をシステムクリップボードへコピー。同一プロジェクト専用 |
| `selection.paste` | 選択レイヤーの再生位置へ相対時間・内部親子関係を保って貼り付け |
| `selection.rippleDelete` | 選択と子の削除区間の和集合を詰め、全レイヤーの後続アイテム・マーカー・範囲を移動。選択外の重なり／ロックはエラー |
| `clip.separateAudio` | clipID。音声トラックを確認して別レイヤーへ分離。非同期jobを待つ |
| `media.tags` | assetID、tags文字列配列（最大32、各80文字）。UIはカンマ区切り |
| `media.cleanupUnused` | 未使用のライブラリ素材登録を解除。生成音声・口差分・マスク参照を保持。元ファイルは削除せずUndo可能 |
| `caption.import` | text、format=srt/vtt、start（任意、既定0）。選択レイヤーへテキスト字幕を配置 |
| `caption.export` | format=srt/vtt。JSONのtextに本文を返す。クライアントが指定場所へ保存する |

`clip.update`はOptionalの`audioDisabled`、`normalizationGain`（0〜64、省略時1）、`measuredLUFS`に対応。normalizationGainは親子音量計算後にマスター音量と掛け、プレビュー音声と動画出力に共通で反映します。LUFS解析は現在UIから行います。測定せずmeasuredLUFSを捏造しないでください。

数値・エフェクト・PSDのキー一括編集はアニメーション編集ウィンドウにあります。MCPではstateを読んで対象のanimation/effects/psdを更新し、全体をclip.updateへ渡します。選択キーの最初の時刻aを基準に `newTime=a+(oldTime-a)*scale+offset`。コピーは新しいUUIDを使い、同じ項目の既存時刻との衝突を避けます。

```json
{"command":"project.update","properties":{"masterVolume":0.8,"timelineRange":{"start":2,"end":5,"loop":true}}}
```

```json
{"command":"caption.import","format":"srt","start":0,"text":"1\n00:00:01,000 --> 00:00:03,000\n字幕テキスト\n"}
```

追加3音声エンジンの実推論は未検証です。Style-BERT-VITS2の既定5000はmacOSのAirPlayと衝突することがあります。エンジンを別ポートで起動し、speechConfiguration.endpointをそのループバックURLへ変えてください。

## 書き出しテンプレート

`export.template`の`template`に`youtube360/480/720/1080/1440/4K/8K`（各IDの末尾`High`で60fps）、`niconico`、`niconicoHigh`、`niconico720`、`niconico480`、`x`を指定。例：`{"command":"export.template","template":"youtube1080"}`。`template:"project"`で上書き解除。既存の開始／終了範囲は保持する。`settings.update`で`exportWidth/exportHeight/exportFPS/exportVideoMbps/exportAudioKbps`をカスタム変更する場合は`exportTemplate:null`を併記。実投稿は行わない。

## 素材・レイヤー削除

`track.delete`の`track`は0起点。`media.delete`の`assetID`は登録素材ID。使用／配置アイテムがある場合は`deleteItems:true`が必要で、子孫も削除対象。stateから使用範囲・親子・ロックを確認し、ユーザーが依頼した範囲に限定する。最後のレイヤーやロック対象は削除不可。素材の元ファイルや作業コピーは削除しない。`settings.update`の`toolbarDisplayMode`は`iconsAndLabels`／`iconsOnly`／`labelsOnly`、`toolbarIconScale`は0.5〜2（Optional）。旧設定の`toolbarLabels`（Bool）も利用可能。表示方式が未設定なら旧Boolから復元し、MCPで旧Boolのみ更新した場合は表示方式を解除して旧Boolを適用する。

## JSON拡張とカスタムアニメーション

`vmm_extensions` で導入済みパッケージと無効IDを取得します。`extension.install` は `package` に拡張JSON、同じIDの更新には `replace:true`。`extension.enable` は `packageID` と `enabled`、`extension.remove` は `packageID`。`animation.applyDefinition` は `clipID`、`packageID`、`definitionID`、任意の `values`（数値パラメータの辞書）を指定します。`extension.applyPreset` は `clipID`、`packageID`、プリセットの `name`。定義・プリセットの適用は有効な導入済みパッケージが必要です。定義の対象項目のキーを置換するので、既存の編集を確認してから適用してください。割合のJSON値は1=100％です。

[JSON形式と制限](../../../docs/DATA-EXTENSIONS.md)を参照してください。

### JavaScriptCore定義

JavaScript定義の `animation.applyDefinition` はジョブIDを返します。任意の `seed` は0〜4294967295の整数です。省略時に定義の `scriptSeed`、未指定なら1を使います。共有画面は現在の数値を定義の初期値にするので、`values` を省略して共有設定を使えます。`vmm_job（jobID）` で完了／失敗を確認し、`animation.cancelGeneration` でキャンセルできます。`vmm_state` に `generatingScript` を追加。適用は通常のキーを置換し、ソース・値・シードを保存します。コードを開く・導入するだけでは実行せず、明示的に生成した時だけヘルパーで実行します。[JavaScriptの仕様](../../../docs/JAVASCRIPT-ANIMATIONS.md)。

## 保存と音声生成キュー

`project.save` / `project.open` の `async:true` はファイル処理中の編集をbusyエラーで拒否し、`vmm_job（jobID）`に完了結果を返します。保存・読み込みに失敗した場合は元のファイルと編集状態を保持します。`vmm_state.projectIOProgress`は処理中の0〜1、処理していなければnullです。

`speech.generate`は従来どおり個別のセリフを生成します。`speech.generateBatch`は変更済み／音声未生成のセリフを生成し、`force:true`で全セリフを再生成します。ロック済み・空のセリフは対象外。`speech.cancel`は待機・実行中の生成を中止（busy中も可）、`speech.retryFailed`は失敗分を再試行します。各サーバー1件、全体2件まで同時に生成します。

`vmm_state`の`generatingSpeech`は待機・生成・反映中のID、`activeSpeech`はエンジン生成中のID、`speechFailures`はIDをキーとしたエラー文字列、`speechBatchTotal` / `speechBatchCompleted`はバッチの総数／処理済み数です。処理済み数には失敗も含みます。生成音声は素材ライブラリの一覧に登録せず、プロジェクト保存・再生・書き出しで使用します。

## 制作ワークフロー

- `export.preflight`: 任意の出力先 `path`。job結果 `report` にissues、estimatedBytesを返す。canExportはerrorの有無で判断する。
- `selection.link` / `selection.unlink`: 選択した映像と音声のリンク／解除。リンク後の時間編集と削除は相手にも反映されるため、stateで範囲とロックを確認する。
- `character.projectAdd` / `character.projectUpdate`: `character` にCharacterPresetオブジェクト。追加は新IDを返す。`character.applyAll` / `character.projectDelete` / `character.portrait`: `characterID`。既存の `character.apply` は選択と `characterID` でプロジェクト定義も適用できる。
- `export.queueAdd`: `path`、任意 `overwrite:true`。job結果 `exportID`。追加時の状態を保存する。`export.queueStart` / `export.queuePause` / `export.queueCancel`。`export.queueRetry` / `export.queueRemove` は `exportID`。`export.queueMove` は `exportID` と `offset`（−1／1など）。`vmm_exportQueue` で状態を確認する。
- `scene.save`: `name`、任意の新規 `.vmm` 保存先 `path`。選択の関連アイテムも保存。`scene.insert`: `.vmm` の `path` と任意 `start`。いずれも非同期ジョブ。`scene.dissolve`: `clipID`。
- `project.transaction`: `operations` 1〜100件、任意の `dryRun` と `expectedRevision`。対応コマンド・ref・Undo・revisionの例は [制作ワークフロー](../../../docs/PRODUCTION-WORKFLOWS.md#mcpの一括編集)を参照。ユーザーが依頼した範囲に限定してdryRunを確認し、実行時に最新revisionを指定する。

## キャラごとの字幕テンプレート

`character.captionTemplate` は `characterID` と `template`（white/green/blue/pink/yellow/orange）でプロジェクトのキャラ定義の字幕設定だけを更新します。既存セリフにはまだ反映しません。`character.applyCaptions` は `characterID` を指定し、そのキャラの字幕の文字色・装飾・サイズ・位置を更新します。声・音声生成状態・立ち絵・キーフレームは保持します。ロックが含まれれば全体を無変更にします。`character.selectCaptions` はキャラの字幕を選択します。

字幕だけの編集依頼では、音声設定や立ち絵も変更する `character.applyAll` と取り違えないでください。


## 素材範囲編集・音声・中間出力

- `media.placeRange`: `assetID`, `sourceIn`, `sourceOut`（素材内の秒）、任意の`start`（タイムライン秒）、`track`、`mode`（append/insert/overwrite、既定append）。insertは全レイヤーの後続を移動。overwriteは対象レイヤーだけ置換。ロックやリンク・親子・シーンをまたぐ分割／削除は無変更で拒否。
- `clip.slip`: `clipID`, `delta`（タイムライン秒）。位置・長さを保持して使用素材位置だけ移動、リンク先は追従。元素材端を超える場合は拒否。
- `clip.roll`: `clipID`（左側）, `delta`（秒）。独立した音声／映像と右隣の境界を動かし、全体の長さを保持。リンク・親子・シーンは現在非対応で拒否。
- `selection.crossfade`: 選択した重なりのある2音声に等パワーフェードを適用。時刻を動かさない。0〜60秒の重なりが必要。`audioFade.curve`はlinear/equalPower、省略時linear。
- `export.audio`: `path`（絶対パス）、任意`overwrite`。48 kHz/24 bitステレオWAV、現在の書き出し範囲・音声合成を使用。非同期jobID。
- `export.interchange`: `path`（新規フォルダの絶対パス）。ProRes MOV・WAV・FCPXML1.10・Premiere/FCP7 XMLを生成。既存フォルダは置換不可。非同期jobID。レイヤー・字幕・エフェクトは焼き込みで、編集パラメータのネイティブ変換ではない。
- `settings.update`: `exportCodec`に`ProRes 422`を設定する場合は同じpatchで`exportContainer`を`MOV`にする。映像ビットレートは使用せず、音声はPCMとなる。

操作詳細と受け渡し制限：[素材編集・出力](../../../docs/SOURCE-EDITING-AND-DELIVERY.md)。出力処理中の中止は`export.cancel`、結果は既存の`job`で確認する。
