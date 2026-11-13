# 音量の確認と正規化

プロジェクト設定のマスター音量は再生・動画出力に共通です。メーターの見方は[音量メーター](AUDIO-METERS.md)を参照してください。

選択音声の「LUFS正規化」は、範囲・速度・ピッチ・EQ・音量アニメーション・フェードを反映した音声をバックグラウンドで解析します。親音量・マスター音量・ダッキングは解析に含めません。元素材を書き換えず、Optionalの正規化ゲインを保存します。操作はUndoで戻せます。セリフ音声を再生成した時は古い解析結果を解除します。

解析は48kHzへデコード後、K-weighting、400msブロック・100ms刻み、−70LUFS絶対ゲートと−10LU相対ゲートを使用します。400ms未満と無音は測定不可です。目標−16LUFSは変更可能。ゲインをサンプルピーク−1dBFS以下・最大64倍に制限するので、目標へ届かない場合があります。このアイテム単位の正規化はTrue Peakを制限せず、番組全体のLUFS正規化は行いません。出力範囲のTrue Peak推定とマスターのサンプルピークリミッターは別途利用できます。重なった音声のピークはマスター音量で調整してください。

[アルゴリズムと48kHz係数の一次資料：ITU-R BS.1770-5](https://www.itu.int/rec/R-REC-BS.1770-5-202311-I)

Master volume affects both playback and export. The master meter measures the mixed output; per-layer readings are conservative sums of individual post-processing peaks. Selected-clip normalization uses K-weighting and gated integrated loudness, preserves source media, and limits gain to a −1dBFS sample peak. Parent gain, master volume and ducking are excluded from analysis. Clips shorter than 400ms and silence cannot be normalized. This normalization does not perform true-peak limiting or whole-program normalization. A separate master sample-peak limiter and output-range true-peak estimate are available.
