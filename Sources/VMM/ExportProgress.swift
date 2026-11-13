import Foundation

/// Transient UI state; never stored in a project or queue snapshot.
enum ExportPhase:Int,Sendable {
    case preparing,rendering,audioPreparing,muxing,saving
    var title:String {
        switch self {
        case .preparing:return "書き出しを準備中"
        case .rendering:return "映像を描画・エンコード中"
        case .audioPreparing:return "音声を準備中"
        case .muxing:return "映像と音声を合成中"
        case .saving:return "ファイルを保存中"
        }
    }
}
