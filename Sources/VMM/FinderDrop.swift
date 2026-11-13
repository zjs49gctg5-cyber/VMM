import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MediaDropPosition {
    var track:Int
    var time:Double
}
enum FinderFiles {
    static func accepts(_ url:URL)->Bool {
        guard url.isFileURL,(try? url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile)==true else{return false}
        if ["psd","zip"].contains(url.pathExtension.lowercased()){return true}
        guard let type=UTType(filenameExtension:url.pathExtension) else{return false}
        return type.conforms(to:.image) || type.conforms(to:.movie) || type.conforms(to:.audio)
    }
    static func urls(_ pasteboard:NSPasteboard)->[URL] {
        (pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL]) ?? []
    }
    static func valid(_ urls:[URL])->Bool { !urls.isEmpty && urls.count<=100 && urls.allSatisfy(accepts) }
    static func resolve(_ providers:[NSItemProvider])async throws->[URL] {
        guard !providers.isEmpty,providers.count<=100 else {throw VMMError.message("一度に100ファイルまでドロップできます。")}
        var urls:[URL]=[]
        for provider in providers {
            let data:Data=try await withCheckedThrowingContinuation{continuation in
                provider.loadDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier){data,error in
                    if let data{continuation.resume(returning:data)}else{continuation.resume(throwing:error ?? VMMError.message("ドロップしたファイルを取得できません。"))}
                }
            }
            guard let url=URL(dataRepresentation:data,relativeTo:nil),url.isFileURL else {throw VMMError.message("ローカルファイルをドロップしてください。")}
            urls.append(url)
        }
        return urls
    }
}
@MainActor extension EditorStore {
    @discardableResult func acceptFinderDrop(_ urls:[URL],at position:MediaDropPosition?=nil)->Bool {
        guard !busy,FinderFiles.valid(urls) else {return false}
        if let position {guard project.tracks.indices.contains(position.track),!project.tracks[position.track].locked else{return false}}
        Task {do {let ids=try await importURLs(urls,placement:position);status=position == nil ? "\(ids.count)個の素材を登録しました。":"\(ids.count)個の素材をドロップ位置に配置しました。"}catch{self.error=error.localizedDescription}}
        return true
    }
    @discardableResult func acceptFinderProviders(_ providers:[NSItemProvider])->Bool {
        guard !busy,!providers.isEmpty,providers.count<=100 else{return false}
        let session=directory
        Task {do {
            let urls=try await FinderFiles.resolve(providers)
            guard session==directory,!busy else{throw VMMError.message("読み込み先が変更されました。もう一度ドロップしてください。")}
            guard acceptFinderDrop(urls) else{throw VMMError.message("画像・動画・音声・PSDまたはPSD入りZIPをドロップしてください。")}
        }catch{self.error=error.localizedDescription}}
        return true
    }
}
