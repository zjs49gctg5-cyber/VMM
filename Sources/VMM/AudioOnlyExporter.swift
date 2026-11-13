import AVFoundation

enum AudioOnlyExporter {
    // The same mix as video export, with sample-accurate bounds and silence padding.
    static func export(project:Project,directory:URL,destination:URL,options:UserSettings=UserSettings(),overwrite:Bool=false,floatPCM:Bool=false,progress:@escaping @Sendable(Double)->Void)async throws {
        _=try project.validated();try options.validateExportOverrides()
        let start=max(0,options.rangeStart),end=options.rangeEnd>0 ? min(project.duration,options.rangeEnd):project.duration
        guard end>start else{throw VMMError.message("音声の書き出し範囲が空です。")}
        let scope=ExportScope(project:project,options:options)
        for c in project.clips where scope.audio.contains(c.id) {
            if c.kind == .speech && (c.speechDirty || c.assetID==nil) {throw VMMError.message("音声が未生成です：\(c.name)")}
            if let asset=project.asset(for:c),!FileManager.default.fileExists(atPath:directory.appendingPathComponent("Media").appendingPathComponent(asset.file).path) {throw VMMError.message("音声素材が見つかりません：\(asset.name)")}
        }
        let scratch=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-wav-\(UUID())")
        try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:scratch)}
        let composition=AVMutableComposition()
        let mix=try await AudioExportComposition.assemble(project:project,directory:directory,options:options,scratch:scratch,composition:composition)
        let stage=destination.deletingLastPathComponent().appendingPathComponent(".vmm-\(UUID()).wav")
        defer{try? FileManager.default.removeItem(at:stage)}
        try await renderMix(composition:composition,mix:mix,start:start,end:end,destination:stage,floatPCM:floatPCM,progress:progress)
        try ExportFileCommit.install(stage,to:destination,overwrite:overwrite);progress(1)
    }
    static func renderMix(composition:AVMutableComposition,mix:AVMutableAudioMix,start:Double,end:Double,destination:URL,floatPCM:Bool,progress:@escaping @Sendable(Double)->Void)async throws {
        let total=Int64(((end-start)*48000).rounded())
        let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
        let stage=destination
        var settings=format.settings;settings[AVLinearPCMIsFloatKey]=floatPCM;settings[AVLinearPCMBitDepthKey]=floatPCM ? 32:24;settings[AVLinearPCMIsNonInterleaved]=false
        var file:AVAudioFile?=try AVAudioFile(forWriting:stage,settings:settings,commonFormat:.pcmFormatFloat32,interleaved:false)
        var written:Int64=0
        func silence(_ frames:Int64)throws {
            var remaining=frames;let blank=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096)!
            for channel in 0..<2 {memset(blank.floatChannelData![channel],0,4096*MemoryLayout<Float>.size)}
            while remaining>0 {try Task.checkCancellation();blank.frameLength=AVAudioFrameCount(min(4096,remaining));try file!.write(from:blank);remaining -= Int64(blank.frameLength);written += Int64(blank.frameLength)}
        }
        let tracks=try await composition.loadTracks(withMediaType:.audio)
        if !tracks.isEmpty {
            // Pad the composition before requesting a range that includes trailing silence.
            if composition.duration.seconds<end {composition.insertEmptyTimeRange(CMTimeRange(start:composition.duration,end:CMTime(seconds:end,preferredTimescale:48000)))}
            let reader=try AVAssetReader(asset:composition)
            reader.timeRange=CMTimeRange(start:CMTime(seconds:start,preferredTimescale:48000),duration:CMTime(value:total,timescale:48000))
            let output=AVAssetReaderAudioMixOutput(audioTracks:tracks,audioSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsNonInterleaved:true]);output.audioMix=mix;reader.add(output)
            guard reader.startReading() else{throw reader.error ?? VMMError.message("音声を読み込めません。")}
            do {
                while let sample=output.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    let count=CMSampleBufferGetNumSamples(sample),stamp=CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    let at=Int64(((stamp-start)*48000).rounded());if at>written {try silence(min(total,at)-written)}
                    let skip=Int(min(Int64(count),max(0,written-at))),available=min(count-skip,Int(max(0,total-written)))
                    guard available>0 else{continue}
                    let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(available))!;buffer.frameLength=AVAudioFrameCount(available)
                    guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample,at:Int32(skip),frameCount:Int32(available),into:buffer.mutableAudioBufferList)==noErr else{throw VMMError.message("音声データの変換に失敗しました。")}
                    try file!.write(from:buffer);written += Int64(available);progress(Double(written)/Double(max(1,total)))
                }
                guard reader.status == .completed else{throw reader.error ?? VMMError.message("音声の合成に失敗しました。")}
            } catch {reader.cancelReading();throw error}
        }
        try silence(max(0,total-written));file=nil;try Task.checkCancellation()
        progress(1)
    }
}
@MainActor extension EditorStore {
    func crossfadeSelection()throws {
        guard !busy else{return}
        let clips=project.clips.filter{selection.contains($0.id)}.sorted{$0.start<$1.start}
        guard clips.count==2,clips.allSatisfy({[.audio,.video,.speech].contains($0.kind) && $0.audioDisabled != true && !project.tracks[$0.track].locked}),clips[0].start<clips[1].start,clips[0].end<clips[1].end else{throw VMMError.message("先頭・末尾が重なる2つの音声アイテムを選択してください。")}
        let overlap=clips[0].end-clips[1].start
        guard overlap>0,overlap<=60 else{throw VMMError.message("クロスフェードする重なりを0〜60秒の範囲にしてください。")}
        var candidate=project
        for (index,c) in clips.enumerated() {
            var fade=c.audioFade ?? AudioFade();fade.curve = .equalPower
            if index==0 {fade.fadeOut=overlap}else{fade.fadeIn=overlap}
            candidate.clips[candidate.clips.firstIndex{$0.id==c.id}!].audioFade=fade
        }
        _=try candidate.validated();pause();checkpoint();project=candidate
    }
}
