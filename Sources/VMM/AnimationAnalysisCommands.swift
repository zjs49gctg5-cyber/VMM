import Foundation

@MainActor extension EditorStore {
    func analyzeReactiveAudio(clipID:UUID,sourceClipID:UUID)async throws {
        guard !busy,let target=project.clips.first(where:{$0.id==clipID}),let source=project.clips.first(where:{$0.id==sourceClipID}),let asset=project.asset(for:source),[.audio,.video,.speech].contains(source.kind),!project.tracks[target.track].locked else{throw VMMError.message("音声連動の対象を確認してください。")}
        guard !source.hasTimeWarp else {throw VMMError.message("逆再生・可変速度の素材は音声連動解析に対応していません。")}
        let directory=self.directory,url=directory.appendingPathComponent("Media").appendingPathComponent(asset.file)
        let worker=Task.detached(priority:.userInitiated){try await ReactiveAudioAnalyzer.analyze(url:url)}
        let data=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()});try Task.checkCancellation()
        guard self.directory==directory,project.clips.first(where:{$0.id==target.id})==target,project.clips.first(where:{$0.id==source.id})==source,project.assets.first(where:{$0.id==asset.id})==asset else{throw VMMError.message("解析中に対象が変更されました。もう一度解析してください。")}
        var a=target.audioReactive ?? AudioReactive(assetID:asset.id,data:data);a.assetID=asset.id;a.data=data;a.sourceOffset=source.sourceOffset;a.timelineOffset=source.start-target.start+target.motionStart;a.sourceDuration=source.duration;a.rate=source.mediaRate
        try mutateMotion(target.id){$0.audioReactive=a}
    }
    func trackMotion(clipID:UUID,sourceClipID:UUID,region:CGRect,from:Double,duration:Double,sampleRate:Double,followScale:Bool,progress:@escaping @Sendable(Double)->Void={_ in})async throws->MotionTrackingResult {
        guard !busy,let target=project.clips.first(where:{$0.id==clipID}),let source=project.clips.first(where:{$0.id==sourceClipID}),let asset=project.asset(for:source),source.kind == .video,!project.tracks[target.track].locked else{throw VMMError.message("追跡元と配置先を確認してください。")}
        let snapshot=project,directory=self.directory,url=directory.appendingPathComponent("Media").appendingPathComponent(asset.file)
        let worker=Task.detached(priority:.userInitiated){try MotionTracker.analyze(url:url,source:source,region:region,from:from,duration:duration,sampleRate:sampleRate,progress:progress)}
        let result=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()});try Task.checkCancellation()
        guard self.directory==directory,project==snapshot else{throw VMMError.message("解析中にプロジェクトが変更されました。もう一度解析してください。")}
        let clip=try MotionTracker.applying(result,to:target,source:source,project:project,followScale:followScale);try mutateMotion(target.id){$0=clip};return result
    }
    func stabilizeVideo(clipID:UUID,region:CGRect,from:Double,duration:Double,sampleRate:Double,strength:Double,smoothing:Double,zoom:Double,progress:@escaping @Sendable(Double)->Void={_ in})async throws->MotionTrackingResult {
        guard !busy,let source=project.clips.first(where:{$0.id==clipID}),let asset=project.asset(for:source),source.kind == .video,!project.tracks[source.track].locked else{throw VMMError.message("補正する動画とレイヤーを確認してください。")}
        try VideoStabilizer.validateSource(source,project:project,strength:strength,smoothing:smoothing,zoom:zoom)
        let snapshot=project,folder=directory,url=folder.appendingPathComponent("Media").appendingPathComponent(asset.file)
        let worker=Task.detached(priority:.userInitiated){try MotionTracker.analyze(url:url,source:source,region:region,from:from,duration:duration,sampleRate:sampleRate,progress:progress)}
        let result=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()});try Task.checkCancellation()
        guard directory==folder,project==snapshot else{throw VMMError.message("解析中にプロジェクトが変更されました。もう一度解析してください。")}
        let corrected=try VideoStabilizer.applying(result,to:source,project:project,strength:strength,smoothing:smoothing,zoom:zoom)
        try mutateMotion(source.id){$0=corrected};return result
    }
}
