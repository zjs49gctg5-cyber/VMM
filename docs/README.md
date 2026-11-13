# 機能一覧とマニュアル

VMMの編集機能と、詳しい操作説明の一覧です。初めて使う場合は[READMEの「はじめ方」](../README.md#はじめ方)から進み、必要な項目を開いてください。画像は説明用のサンプルで、画面の大きさや設定により表示が異なります。

## 基本の編集

| やりたいこと | 機能・案内 |
| --- | --- |
| 素材を読み込む・探す | [対応形式・プロジェクトを開けないとき](MEDIA-FORMATS.md)、[素材ライブラリと画面の使い分け](WORKFLOW-GUIDE.md) |
| タイムラインで編集する | [コピー・リップル削除・素材管理](P2-EDITING.md)、[素材のIn/Out・クロスフェード](SOURCE-EDITING-AND-DELIVERY.md) |
| 位置・サイズ・レイヤーを調整する | プレビューでの移動・回転・伸縮、タイムラインでの配置・トリム・レイヤー並べ替え。通常はレイヤー番号が大きいほど前面です。 |
| 動画・音声をリンクする | [動画・音声のリンク](PRODUCTION-WORKFLOWS.md#動画音声のリンク) |
| マーカーや編集範囲を使う | [マーカー編集](MARKER-EDITING.md)、[マーカー・範囲・字幕](CAPTIONS-NAVIGATION.md) |
| パネルの表示や配置を変える | [設定の分類](SETTINGS-ORGANIZATION.md)、[独立ウィンドウ](DETACHED-PANELS.md) |
| プレビュー再生が重いとき | [再生を軽くする](WORKFLOW-GUIDE.md#再生が重いとき) |
| AIからVMMを操作する | [クライアント別MCP・スキル設定](AI-CLIENT-SETUP.md)、[MCP接続と操作](CONTROL-MCP.md) |

## セリフ・立ち絵・文字

| やりたいこと | 機能・案内 |
| --- | --- |
| 音声を生成する | [音声エンジンの接続と検証範囲](SPEECH-ENGINES.md) |
| 複数のキャラを使う | [プロジェクトのキャラと字幕設定](PRODUCTION-WORKFLOWS.md#複数キャラの字幕編集)、[制作機能と画面の使い分け](WORKFLOW-GUIDE.md) |
| 立ち絵の表情・口パクを使う | [PSD・PSDToolKitの対応範囲](PSD-COMPATIBILITY.md)、[立ち絵の時間指定切り替え](ADVANCED-EDITING.md#立ち絵表情を時間指定で切り替える) |
| 文字や字幕を整える | [文字の配置](TEXT-ALIGNMENT.md)、[字幕の読み込み・書き出し](CAPTIONS-NAVIGATION.md) |

## 動き・映像加工

| やりたいこと | 機能・案内 |
| --- | --- |
| キーフレームやグラフを編集する | [アニメーション編集](ANIMATION-WORKSPACE.md)、[高度な2Dアニメーション](ADVANCED-ANIMATION.md) |
| モザイク・マスク・パーティクルを使う | [エフェクトと映像加工](ADVANCED-EDITING.md) |
| カメラと奥行きを使う | [2.5Dカメラ、キーフレーム、奥行き順](ADVANCED-EDITING.md#詳細な変形) |
| 逆再生や速度変化を使う | [再生速度・音程と制限](ADVANCED-EDITING.md#再生速度イコライザー) |
| 親子関係や入れ子を使う | [親子関係・グループ](ADVANCED-EDITING.md#親子関係グループ制御)、[プリコンポジション](PRECOMPOSITIONS.md)、[シーンライブラリ](PRODUCTION-WORKFLOWS.md#シーンライブラリ) |
| アニメーションを再利用する | [JSONアニメーション定義](DATA-EXTENSIONS.md)、[JavaScriptアニメーション](JAVASCRIPT-ANIMATIONS.md) |

場面切り替えは、そのアイテムよりタイムライン上で下にあるレイヤーに作用します。[対象範囲](ANIMATION-WORKSPACE.md#場面切り替えの範囲)

## 音声・書き出し

| やりたいこと | 機能・案内 |
| --- | --- |
| 拍や音程を編集する | [音MADモード](AUDIO-MAD-MODE.md) |
| 音量を確認・調整する | [音量メーター](AUDIO-METERS.md)、[ラウドネス](AUDIO-LOUDNESS.md)、[音声ミックス](AUDIO-MIX-IMPROVEMENTS.md) |
| 動画・音声を書き出す | [書き出しテンプレート](EXPORT-TEMPLATES.md)、[WAV・ProRes・XML](SOURCE-EDITING-AND-DELIVERY.md)、[事前チェックとキュー](PRODUCTION-WORKFLOWS.md#書き出しキュー) |

## 外部操作・開発

- [MCP接続と操作](CONTROL-MCP.md)：AIや外部ツールから同じMac上のVMMを操作します。接続は通常起動時に無効です。
- [MCP操作リファレンス](../skills/vmm-control/references/operations.md)：ツールとモデルの詳細。
- [署名・公証](SIGNING-NOTARIZATION.md)：アプリの配布手順。

VMMはβ版です。YMM4・AviUtlプロジェクト、Windows用プラグイン、PSDToolKitのLuaスクリプトを直接読み込む機能はありません。PSDと音声エンジンの対応範囲は、それぞれの案内を確認してください。
