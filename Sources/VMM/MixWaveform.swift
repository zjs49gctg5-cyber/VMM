import AppKit
import AVFoundation
import SwiftUI

struct MixWaveform: Equatable {
    var peaks: [Double]
    var duration: Double
}

enum MixWaveformAnalyzer {
    static func analyze(project:Project,directory:URL) async throws -> MixWaveform {
        guard project.duration>0,project.duration<=3600 else {throw VMMError.message("全体波形の解析は1時間以内のプロジェクトに対応します。")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-mix-waveform-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("mix.wav")
        var settings=UserSettings();settings.rangeStart=0;settings.rangeEnd=0
        try await AudioOnlyExporter.export(project:project,directory:directory,destination:file,options:settings,floatPCM:true){_ in}
        return try waveform(file)
    }
    static func waveform(_ url:URL)throws->MixWaveform {
        let file=try AVAudioFile(forReading:url),format=file.processingFormat,length=file.length
        guard length>0,format.sampleRate>0,format.channelCount>0,let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096) else {throw VMMError.message("全体波形の音声を読み込めません。")}
        let count=Int(min(3000,length)),n=Int64(count);var peaks=[Double](repeating:0,count:count),offset:Int64=0
        while offset<length {
            try Task.checkCancellation();try file.read(into:buffer,frameCount:AVAudioFrameCount(min(4096,length-offset)))
            guard buffer.frameLength>0,let channels=buffer.floatChannelData else {throw VMMError.message("全体波形の音声を読み込めません。")}
            for i in 0..<Int(buffer.frameLength) {
                let index=min(count-1,Int((offset+Int64(i))*n/length))
                for channel in 0..<Int(format.channelCount) {peaks[index]=max(peaks[index],Double(abs(channels[channel][i])))}
            }
            offset+=Int64(buffer.frameLength)
        }
        return MixWaveform(peaks:peaks,duration:Double(length)/format.sampleRate)
    }
}

struct MixWaveformSheet:View {
    @ObservedObject var store:EditorStore
    @Environment(\.dismiss) private var dismiss
    @State private var result:MixWaveform?
    @State private var analyzed:Project?
    @State private var directory:URL?
    @State private var task:Task<Void,Never>?
    @State private var failure:String?
    var stale:Bool {analyzed != store.project || directory != store.directory}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(L("ミックス全体の波形")).font(.headline)
            Text(L("出力時の音声ミックスを全体解析します。クリックした位置へ移動します。" )).foregroundColor(.secondary)
            HStack {Button(L("波形を解析")){analyze()}.disabled(task != nil || store.busy)
                if task != nil {ProgressView().controlSize(.small);Button(L("中止")){task?.cancel()}}
                Spacer()
                if result != nil && stale {Text(L("編集が変更されています。再解析してください。")).foregroundColor(.orange)}
            }
            if let result {
                GeometryReader { geometry in
                    Canvas { context,size in
                        let mid=size.height/2;var path=Path()
                        for (index,peak) in result.peaks.enumerated() {
                            let x=(Double(index)+0.5)/Double(result.peaks.count)*size.width
                            let h=min(1,peak)*mid;path.move(to:CGPoint(x:x,y:mid-h));path.addLine(to:CGPoint(x:x,y:mid+h))
                        }
                        context.stroke(path,with:.color(.cyan),lineWidth:1)
                        if !stale {let x=min(1,max(0,store.playhead/result.duration))*size.width;var cursor=Path();cursor.move(to:CGPoint(x:x,y:0));cursor.addLine(to:CGPoint(x:x,y:size.height));context.stroke(cursor,with:.color(.orange),lineWidth:2)}
                    }.background(Color.black.opacity(0.35)).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance:0).onEnded{value in if !stale && geometry.size.width>0 {store.seek(max(0,min(result.duration,value.location.x/geometry.size.width*result.duration)))}})
                        .accessibilityLabel(L("ミックス全体の波形"))
                }.frame(minHeight:180)
                HStack {Text("0:00");Spacer();Text(timecode(result.duration,fps:store.project.fps))}.monospacedDigit().foregroundColor(.secondary)
            } else {Text(L("解析すると全体波形を表示します。" )).frame(maxWidth:.infinity,maxHeight:.infinity).foregroundColor(.secondary)}
            if let failure {Text(L(failure)).foregroundColor(.red)}
            Text(L("解析は1時間まで。長い動画では一時ディスク容量と処理時間が必要です。" )).foregroundColor(.secondary)
            HStack{Spacer();Button(L("閉じる")){dismiss()}}
        }.padding(20).frame(minWidth:620,minHeight:380).onDisappear{task?.cancel()}
    }
    private func analyze() {
        let project=store.project,folder=store.directory
        failure=nil;result=nil;analyzed=nil
        task=Task {
            defer{task=nil}
            do {
                let worker=Task.detached(priority:.userInitiated){try await MixWaveformAnalyzer.analyze(project:project,directory:folder)}
                let value=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
                try Task.checkCancellation();result=value;analyzed=project;directory=folder
            }catch is CancellationError {}catch{failure=error.localizedDescription}
        }
    }
}
