import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct MediaProbe {
    static let description = "画像：PNG・JPEG・TIFF・BMP・GIF・HEICなど（GIFアニメーション対応）。PSDとPSD入りZIP。動画：MP4・MOV・M4Vなど。音声：WAV・MP3・M4A・AIFF・CAFなど。画像はmacOSの画像デコーダー、動画・音声はAVFoundationの対応コーデックに依存します。ZIPはPSD素材用です。"
    static func inspect(_ url:URL) async throws -> (kind:ClipKind,duration:Double) {
        let type=UTType(filenameExtension:url.pathExtension)
        if type?.conforms(to:.image)==true {
            guard let image=NSImage(contentsOf:url),image.size.width>0,image.size.height>0 else {throw VMMError.message("画像「\(url.lastPathComponent)」をデコードできません。")}
            return (.image,5)
        }
        let asset=AVURLAsset(url:url),duration=try await asset.load(.duration).seconds
        let video=try await asset.loadTracks(withMediaType:.video),audio=try await asset.loadTracks(withMediaType:.audio)
        guard duration.isFinite,duration>0,!video.isEmpty || !audio.isEmpty else {throw VMMError.message("「\(url.lastPathComponent)」の形式・コーデックに対応していません。")}
        if !video.isEmpty {
            let generator=AVAssetImageGenerator(asset:asset);generator.appliesPreferredTrackTransform=true;generator.maximumSize=CGSize(width:64,height:64)
            guard (try? generator.copyCGImage(at:.zero,actualTime:nil)) != nil else {throw VMMError.message("「\(url.lastPathComponent)」の映像コーデックをデコードできません。")}
            return (.video,duration)
        }
        let reader=try AVAssetReader(asset:asset)
        let output=AVAssetReaderTrackOutput(track:audio[0],outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM])
        reader.add(output)
        guard reader.startReading(),output.copyNextSampleBuffer() != nil else {throw VMMError.message("「\(url.lastPathComponent)」の音声コーデックをデコードできません。") }
        reader.cancelReading()
        return (.audio,duration)
    }
}
