import SwiftUI

/// Float output keeps overloads measurable before integer/AAC delivery clips them.
enum MixLoudnessAnalyzer {
    static func analyze(project:Project,directory:URL,options:UserSettings)async throws->LoudnessResult {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-mix-analysis-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("mix.wav")
        try await AudioOnlyExporter.export(project:project,directory:directory,destination:file,options:options,floatPCM:true){_ in}
        return try LoudnessAnalyzer.analyze(file)
    }
}
struct MixLoudnessControls:View {
    @ObservedObject var store:EditorStore
    @State private var task:Task<Void,Never>?
    @State private var result:LoudnessResult?
    @State private var measuredProject:Project?
    @State private var measuredOptions:UserSettings?
    @State private var failure:String?
    var body:some View {
        VStack(alignment:.leading,spacing:6){
            HStack {
                Button(L("出力範囲の音量を解析")){analyze()}.disabled(task != nil || store.busy)
                if task != nil {ProgressView().controlSize(.small);Button(L("中止")){task?.cancel()}}
            }
            if let result {
                Text(String(format:"LUFS: %@   Sample Peak: %.2f dBFS",result.integratedLUFS.map{String(format:"%.2f",$0)} ?? "—",AudioMeterReading.decibels(result.samplePeak))).monospacedDigit()
                if let peak=result.truePeakEstimate {Text(String(format:L("True Peak推定（4倍）：%.2f dBTP"),AudioMeterReading.decibels(peak))).monospacedDigit()}
                if result.clippedFrames>0 {Label(String(format:L("0 dBFS以上のサンプル：%lld"),result.clippedFrames),systemImage:"exclamationmark.triangle.fill").foregroundColor(.orange)}
                if measuredProject != store.project || measuredOptions != store.settings {Text(L("編集・設定が変更されています。再解析してください。")).foregroundColor(.orange)}
            }
            if let failure {Text(failure).foregroundColor(.red)}
            Text(L("出力範囲の実ミックスを解析します。マスター音量・親・ダッキングを含みます。True Peakは4倍補間による推定値です。")).foregroundColor(.secondary).fixedSize(horizontal:false,vertical:true)
        }.vmmFont(size:12)
        .onDisappear{task?.cancel()}
    }
    private func analyze() {
        commitActiveFieldEditing()
        let project=store.project,directory=store.directory,options=store.settings
        failure=nil;result=nil
        task=Task {
            defer{task=nil}
            do {
                let worker=Task.detached{try await MixLoudnessAnalyzer.analyze(project:project,directory:directory,options:options)}
                let value=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
                try Task.checkCancellation();result=value;measuredProject=project;measuredOptions=options
            }catch is CancellationError {}catch{failure=error.localizedDescription}
        }
    }
}
