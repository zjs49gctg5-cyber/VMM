import Foundation

enum DiagnosticLocalization {
    static let english:[String:String] = {
        // Tab-separated entries keep long diagnostics readable and auditable.
        let source="""
        未対応のプロジェクト形式です。	Unsupported project format.
        プロジェクト設定が不正です。	Invalid project settings.
        素材のパスまたは長さが不正です。	Invalid media path or duration.
        不正なプロキシのファイル名です。	Invalid proxy filename.
        レイヤーの不透明度が不正です。	Invalid layer opacity.
        文字送りが不正です。	Invalid typewriter speed.
        BGM音量比が不正です。	Invalid music ducking ratio.
        文字組みが不正です。	Invalid typography settings.
        グラデーションの角度が不正です。	Invalid gradient angle.
        文字装飾の設定が不正です。	Invalid text decoration settings.
        PSDの表情設定が不正です。	Invalid PSD expression settings.
        PSDのレイヤー切り替えキーフレームが不正です。	Invalid PSD layer-switch keyframes.
        親アイテムが不正です。	Invalid parent item.
        親子関係が循環しています。	Parent relationships contain a cycle.
        親子関係は15段までにしてください。	Parent relationships are limited to 15 levels.
        マスクは8個までです。	Up to 8 masks are supported.
        マスクの設定が不正です。	Invalid mask settings.
        パーティクルの設定が不正です。	Invalid particle settings.
        変形の設定が不正です。	Invalid transform settings.
        透視変形の四隅は交差しない四角形にしてください。	Perspective corners must form a non-crossing quadrilateral.
        再生速度が不正です。	Invalid playback rate.
        音声ピッチが不正です。	Invalid audio pitch.
        イコライザーの設定が不正です。	Invalid equalizer settings.
        エフェクト範囲が不正です。	Invalid effect region.
        図形の設定が不正です。	Invalid shape settings.
        矢印の先端サイズは1〜100%で指定してください。	Arrowhead dimensions must be between 1% and 100%.
        キーフレームの設定が不正です。	Invalid keyframe settings.
        回転角が不正です。	Invalid rotation angle.
        アニメーションの開始位置が不正です。	Invalid animation offset.
        アニメーションの設定が不正です。	Invalid animation settings.
        エフェクトが多すぎるか重複しています。	Effects exceed the limit or contain duplicate IDs.
        エフェクトの設定が不正です。	Invalid effect settings.
        音声フェードの設定が不正です。	Invalid audio fade settings.
        未対応または不正なVMMプリセットです。	Unsupported or invalid VMM preset.
        プリセットは1MB以内にしてください。	Presets must be no larger than 1 MB.
        音声エンジンの接続先・設定が不正です。接続先はこのMacのループバックURLを指定してください。	Invalid speech engine settings. Use a loopback URL on this Mac.
        音声エンジンの応答が不正です。	Invalid speech engine response.
        音声エンジンの応答サイズが不正です。	Invalid speech engine response size.
        モデル一覧を読み込めませんでした。	Could not read the model list.
        話者IDが重複しています。モデル名を確認してください。	Duplicate voice IDs. Check model names.
        読み上げ文字・話速が不正です。	Invalid spoken text or speech speed.
        音声クエリを読み込めませんでした。	Could not read the speech query.
        接続してモデル・話者・スタイルを選択してください。	Connect and choose a model, voice and style.
        Qwen3-TTSの話者を選択してください。	Choose a Qwen3-TTS voice.
        音声エンジンからWAV音声が返されませんでした。	The speech engine did not return WAV audio.
        接続先はmacOSのAirPlayです。音声エンジンを別ポートで起動し、接続先URLを変更してください。	The endpoint is macOS AirPlay. Start the speech engine on another port and change its URL.
        接続先からJSONが返されませんでした。音声エンジンのURLを確認してください。	The endpoint did not return JSON. Check the speech engine URL.
        音声素材の終端です。	End of audio source reached.
        音声のデコードを開始できません。	Could not start audio decoding.
        音声を読み込めませんでした。	Could not read audio.
        未対応の音声加工状態です。	Unsupported audio processing state.
        音声加工が停止しました。	Audio processing stalled.
        音声加工の時刻が進みません。	Audio processing time is not advancing.
        音声の速度・EQ加工に失敗しました。	Audio speed/EQ processing failed.
        タイムラインにアイテムを追加してください。	Add items to the timeline first.
        音声が未生成、またはセリフが変更されています。音声を生成してから書き出してください。	Speech is missing or out of date. Generate speech before exporting.
        画像マスクの素材を選択してから書き出してください。	Choose image-mask media before exporting.
        書き出し範囲・形式が不正です。	Invalid export range or format.
        動画の作成を開始できませんでした。	Could not start video creation.
        エンコードに失敗しました。	Encoding failed.
        動画用メモリを確保できませんでした。	Could not allocate video memory.
        描画領域を作成できませんでした。	Could not create the rendering surface.
        フレームを書き込めませんでした。	Could not write a frame.
        動画の保存に失敗しました。	Could not save the video.
        描画した動画を読み込めませんでした。	Could not read the rendered video.
        書き出しを開始できませんでした。	Could not start export.
        音声の合成に失敗しました。	Audio mixing failed.
        素材ファイル名が衝突しています。	Media filenames conflict.
        脚本が空、長すぎる、またはレイヤーがロックされています。	The script is empty, too long, or the layer is locked.
        素材がありません。	Media not found.
        PSDまたはPSD入りZIPを指定してください。	Choose a PSD or ZIP containing a PSD.
        同じ種類の素材を指定してください。	Choose media of the same type.
        テンプレート名を指定してください。	Specify a template name.
        変更が未保存です。	Changes have not been saved.
        変更が未保存です。保存するかdiscardChanges:trueを指定してください。	Save changes or specify discardChanges:true.
        既存ファイルを置換するにはoverwrite:trueが必要です。	Replacing an existing file requires overwrite:true.
        保存先は.vmmにしてください。	Use a .vmm destination.
        動画素材を指定してください。	Choose video media.
        プロキシを作成できません。	Could not create a proxy.
        プロキシ生成に失敗しました。	Proxy generation failed.
        プレビューの最低解像度が不正です。	Invalid minimum preview resolution.
        設定値が範囲外です。	A setting is out of range.
        ドロップ先が不正、またはロックされています。	The drop destination is invalid or locked.
        ローカルファイルをドロップしてください。	Drop local files.
        ローカルファイルを指定してください。	Specify a local file.
        ドロップしたファイルを取得できません。	Could not retrieve the dropped file.
        画像・動画・音声・PSDまたはPSD入りZIPをドロップしてください。	Drop images, video, audio, PSD, or ZIP containing PSD.
        一度に100ファイルまでドロップできます。	Drop up to 100 files at a time.
        読み込み先が変更されました。もう一度ドロップしてください。	The destination changed. Drop the files again.
        レイヤーがロックされています。	The layer is locked.
        レイヤーは32個までです。	Up to 32 layers are supported.
        レイヤー番号が不正です。	Invalid layer index.
        レイヤー設定が不正です。	Invalid layer settings.
        選択にロックされたアイテムがあります。	The selection includes locked items.
        選択に存在しないアイテムがあります。	The selection includes missing items.
        移動先がロックされています。	The destination is locked.
        アイテムを選択してください。	Select an item.
        キャラがありません。	Character preset not found.
        辞書が不正です。	Invalid pronunciation dictionary.
        字幕を選択してキャラnameを指定してください。	Select a caption and specify the character name.
        整列modeを指定してください。	Specify an alignment mode.
        脚本textを指定してください。	Specify script text.
        nameを指定してください。	Specify name.
        pathsを絶対パスの配列で指定してください。	Specify paths as an array of absolute paths.
        有効なclipIDを指定してください。	Specify a valid clipID.
        propertiesはJSONオブジェクトで指定してください。	Specify properties as a JSON object.
        project propertiesが不正です。	Invalid project properties.
        settings propertiesが不正です。	Invalid settings properties.
        変更できないプロパティがあります。	Some properties cannot be changed.
        from/toが不正です。	Invalid from/to values.
        処理中です。	An operation is in progress.
        音声生成が完了していません。	Speech generation is not complete.
        書き出しは完了しませんでした。	Export did not complete.
        生成した音声を読み込めませんでした。	Could not read generated speech.
        VOICEVOXで処理できませんでした。話者とセリフを確認してください。	VOICEVOX could not process the request. Check the voice and text.
        VOICEVOXの応答を読み取れませんでした。	Could not read the VOICEVOX response.
        tagsは文字列配列で指定してください。	Specify tags as an array of strings.
        字幕textとformat（srt/vtt）を指定してください。	Specify caption text and format (srt/vtt).
        formatはsrt/vttで指定してください。	Specify format as srt or vtt.
        子アイテムの親を解除してから、この親アイテムを削除してください。	Detach child items before deleting their parent.
        選択外の子アイテムが残っています。子も選択してください。	Unselected child items remain. Select them too.
        同じ時刻には切り替えを1つだけ配置できます。	Only one layer switch can be placed at a given time.
        切り替え時刻は24時間以内にしてください。	Layer switches must be within 24 hours.
        1〜100ファイルを指定してください。	Specify between 1 and 100 files.
        BPM・拍グリッドの設定が不正です。	Invalid BPM or beat-grid settings.
        PFVはUTF-8で保存してください。	Save PFV files as UTF-8.
        PSD/ZIPは512MB以内にしてください。	PSD/ZIP files must be no larger than 512 MB.
        PSD/ZIPデータが途中で切れています。	PSD/ZIP data is truncated.
        PSDToolFavorites-v1形式のPFVではありません。	The PFV is not in PSDToolFavorites-v1 format.
        PSDがありません。	PSD not found.
        PSDが大きすぎます（上限512MB）。	PSD exceeds the 512 MB limit.
        PSDのRLE行が不正です。	Invalid PSD RLE row.
        PSDのRLE行の長さが不正です。	Invalid PSD RLE row length.
        PSDのグループが閉じていません。	A PSD group is not closed.
        PSDのグループ構造が不正です。	Invalid PSD group structure.
        PSDのサイズ・レイヤー情報が不正です。	Invalid PSD dimensions or layer information.
        PSDのチャンネル数が未対応です。	Unsupported PSD channel count.
        PSDのレイヤーサイズが不正です。	Invalid PSD layer dimensions.
        PSDのレイヤーレコードが不正です。	Invalid PSD layer record.
        PSDのレイヤー情報が不正です。	Invalid PSD layer information.
        PSDのレイヤー数が未対応です（1〜2000）。	PSD layer count must be between 1 and 2000.
        PSDの展開サイズが上限を超えています。	Expanded PSD exceeds the size limit.
        PSDレイヤーを画像に変換できません。	Could not convert a PSD layer to an image.
        PSDレイヤー名が長すぎます。	PSD layer name is too long.
        PSD形式に対応しています。PSB形式は未対応です。	PSD is supported; PSB is not supported.
        RGB・8bit、3200万画素以内のPSDを使用してください。	Use an 8-bit RGB PSD with at most 32 million pixels.
        ZIPが破損しています。	ZIP is corrupt.
        ZIPのサイズが未対応です。	Unsupported ZIP size.
        ZIPのチェックサムが一致しません。	ZIP checksum mismatch.
        ZIPのファイル名が不正です。	Invalid ZIP filename.
        ZIPのファイル数が多すぎます。	ZIP contains too many files.
        ZIPの圧縮データが不正です。	Invalid ZIP compressed data.
        ZIPの索引が不正です。	Invalid ZIP index.
        ZIP内にPSDファイルがありません。	No PSD found in ZIP.
        分割ZIPには対応していません。	Split ZIP archives are not supported.
        圧縮データが破損しています。	Compressed data is corrupt.
        展開を開始できません。	Could not start decompression.
        展開サイズが大きすぎます。	Expanded data exceeds the size limit.
        暗号化ZIP、ZIP64、または大きすぎるZIPは未対応です。	Encrypted ZIP, ZIP64, and oversized ZIP archives are not supported.
        未対応のPSDグループ形式です。	Unsupported PSD group format.
        エンドポイントがありません。	Endpoint not found.
        Undo履歴がありません。	No undo history.
        Redo履歴がありません。	No redo history.
        ジョブがありません。	Job not found.
        """
        return Dictionary(uniqueKeysWithValues:source.split(separator:"\n").compactMap{line in let fields=line.split(separator:"\t",maxSplits:1);return fields.count==2 ? (String(fields[0]),String(fields[1])):nil})
    }()
    static let patterns:[(NSRegularExpression,String)] = [
        (#"^(.+)：音声が未生成・変更済み、または生成中です。$"#,"$1: Speech is missing, out of date or being generated."),
        (#"^(.+)：画像マスクの素材が未指定です。$"#,"$1: Image-mask media is not selected."),
        (#"^フォント「(.+)」が見つかりません。代替フォントで出力されます。$"#,"Font “$1” is missing. A fallback font will be used."),
        (#"^(.+)：素材の末尾を超えています。映像は最終フレーム、音声は無音になります。$"#,"$1: Extends beyond the source. Video holds its final frame; audio becomes silent."),
        (#"^素材「(.+)」が見つかりません（([0-9]+)ファイル）。$"#,"Media “$1” is missing ($2 files)."),
        (#"^書き出し先の空き容量が不足しています。推定必要容量：約([0-9]+) MB$"#,"Insufficient output disk space. Estimated requirement: about $1 MB"),

        (#"^(.+)：音声エンジンに接続できません（(-?[0-9]+)）。$"#,"$1: Cannot connect to the speech engine ($2)."),
        (#"^素材「(.+)」が見つかりません。$"#,"Media “$1” is missing."),
        (#"^音声素材「(.+)」を読み込めませんでした。$"#,"Could not read audio media “$1”."),
        (#"^音声を準備しています：(.+)$"#,"Preparing audio: $1"),
        (#"^(.+)：([0-9]+)種類の声を読み込みました。$"#,"$1: Loaded $2 voices."),
        (#"^(.+)を絶対パスで指定してください。$"#,"Specify $1 as an absolute path."),
        (#"^有効な(.+)を指定してください。$"#,"Specify a valid $1."),
        (#"^音声データの変換に失敗しました（(-?[0-9]+)）。$"#,"Audio data conversion failed ($1)."),
        (#"^(.+)を起動してから、再接続してください。$"#,"Start $1, then reconnect."),
        (#"^接続先：(.+)$"#,"Endpoint: $1")
    ].map{(try! NSRegularExpression(pattern:$0.0),$0.1)}
    static func translate(_ value:String)->String? {
        if let hit=english[value]{return hit}
        for (pattern,replacement) in patterns {
            let range=NSRange(value.startIndex..<value.endIndex,in:value)
            if pattern.firstMatch(in:value,range:range) != nil{return pattern.stringByReplacingMatches(in:value,range:range,withTemplate:replacement)}
        }
        if value.contains("\n"){let lines=value.components(separatedBy:"\n"),translated=lines.map{VMMLocalization.text($0,language:.english)};if translated != lines{return translated.joined(separator:"\n")}}
        return nil
    }
}
