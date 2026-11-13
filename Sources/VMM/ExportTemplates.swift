import Foundation
import CoreGraphics

enum ExportTemplate:String,CaseIterable,Identifiable {
    case youtube360,youtube360High,youtube480,youtube480High,youtube720,youtube720High
    case youtube1080,youtube1080High,youtube1440,youtube1440High,youtube4K,youtube4KHigh,youtube8K,youtube8KHigh
    case niconico,niconicoHigh,niconico720,niconico480,x
    var id:String{rawValue}
    var title:String {
        let service=rawValue.hasPrefix("youtube") ? "YouTube":(self == .x ? "X":L("ニコニコ"))
        let size=height==4320 ? "8K":(height==2160 ? "4K":"\(height)p")
        return "\(service) · \(size) / \(fps) fps"
    }
    var height:Int {
        switch self {
        case .youtube360,.youtube360High:return 360
        case .youtube480,.youtube480High,.niconico480:return 480
        case .youtube720,.youtube720High,.niconico720:return 720
        case .youtube1440,.youtube1440High:return 1440
        case .youtube4K,.youtube4KHigh:return 2160
        case .youtube8K,.youtube8KHigh:return 4320
        default:return 1080
        }
    }
    var width:Int {switch height {case 360:return 640;case 480:return 854;case 720:return 1280;case 1440:return 2560;case 2160:return 3840;case 4320:return 7680;default:return 1920}}
    var fps:Int{rawValue.hasSuffix("High") ? 60:30}
    var videoMbps:Double {
        switch self {
        case .youtube360:return 1
        case .youtube360High:return 1.5
        case .youtube480:return 2.5
        case .youtube480High:return 4
        case .youtube720:return 5
        case .youtube720High:return 7.5
        case .youtube1080,.x:return 8
        case .youtube1080High,.niconico,.niconicoHigh:return 12
        case .youtube1440:return 16
        case .youtube1440High:return 24
        case .youtube4K:return 40
        case .youtube4KHigh:return 60
        case .youtube8K:return 120
        case .youtube8KHigh:return 180
        case .niconico720:return 6
        case .niconico480:return 2
        }
    }
    // macOS AAC-LC encoder rejects 384 kbps stereo; 320 kbps was verified with actual MP4.
    var audioKbps:Int{rawValue.hasPrefix("youtube") ? 320:192}
    func apply(to settings:inout UserSettings) {
        settings.exportTemplate=rawValue;settings.exportContainer="MP4";settings.exportCodec="H.264"
        settings.exportWidth=width;settings.exportHeight=height;settings.exportFPS=fps
        settings.exportVideoMbps=videoMbps;settings.exportAudioKbps=audioKbps
        // Preserve the user's chosen export range and all unrelated preferences.
    }
}
extension UserSettings {
    func validateExportOverrides()throws {
        guard exportCodec != "ProRes 422" || exportContainer == "MOV" else{throw VMMError.message("ProRes 422はMOV形式を選択してください。")}
        guard (exportWidth == nil) == (exportHeight == nil),
              exportWidth.map({(32...8192).contains($0) && $0%2==0}) ?? true,
              exportHeight.map({(32...8192).contains($0) && $0%2==0}) ?? true,
              (exportWidth == nil || exportWidth!*exportHeight! <= 7680*4320),
              exportFPS.map({(1...60).contains($0)}) ?? true,
              exportVideoMbps.map({$0.isFinite && (0.2...240).contains($0)}) ?? true,
              exportAudioKbps.map({(64...320).contains($0)}) ?? true,
              exportTemplate.map({ExportTemplate(rawValue:$0) != nil}) ?? true
        else {throw VMMError.message("書き出しサイズ・FPS・ビットレートが不正です。")}
    }
    func exportDimensions(_ project:Project)->(width:Int,height:Int,fps:Int) {
        (exportWidth ?? project.width,exportHeight ?? project.height,exportFPS ?? project.fps)
    }
    mutating func clearExportTemplate() {
        exportTemplate=nil;exportWidth=nil;exportHeight=nil;exportFPS=nil;exportVideoMbps=nil;exportAudioKbps=nil
    }
    func exportFitRect(_ project:Project)->CGRect {
        let d=exportDimensions(project),scale=min(Double(d.width)/Double(project.width),Double(d.height)/Double(project.height))
        let w=Double(project.width)*scale,h=Double(project.height)*scale
        return CGRect(x:(Double(d.width)-w)/2,y:(Double(d.height)-h)/2,width:w,height:h)
    }
    var usesExplicitExportEncoding:Bool{exportCodec == "ProRes 422" || exportVideoMbps != nil || exportAudioKbps != nil}
}
