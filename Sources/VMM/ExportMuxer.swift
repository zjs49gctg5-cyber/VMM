import AVFoundation

// Keep the already encoded video stream; mix and encode audio once at the requested rate.
enum ExportMuxer {
    static func write(composition:AVComposition,mix:AVAudioMix,range:CMTimeRange,output:URL,options:UserSettings,progress:@escaping @Sendable (Double)->Void = {_ in})async throws {
        let reader=try AVAssetReader(asset:composition)
        reader.timeRange=range
        let video=try await composition.loadTracks(withMediaType:.video)
        guard let track=video.first,let format=try await track.load(.formatDescriptions).first else{throw VMMError.message("描画した動画を読み込めませんでした。")}
        let videoOutput=AVAssetReaderTrackOutput(track:track,outputSettings:nil)
        videoOutput.alwaysCopiesSampleData=false
        let writer=try AVAssetWriter(outputURL:output,fileType:options.exportContainer == "MOV" ? .mov:.mp4)
        writer.shouldOptimizeForNetworkUse=true
        let videoInput=AVAssetWriterInput(mediaType:.video,outputSettings:nil,sourceFormatHint:format)
        videoInput.expectsMediaDataInRealTime=false
        reader.add(videoOutput);writer.add(videoInput)
        var streams:[(AVAssetReaderOutput,AVAssetWriterInput)]=[(videoOutput,videoInput)]
        let audio=try await composition.loadTracks(withMediaType:.audio)
        if !audio.isEmpty {
            let audioOutput=AVAssetReaderAudioMixOutput(audioTracks:audio,audioSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsNonInterleaved:false])
            audioOutput.audioMix=mix
            let audioSettings:[String:Any]=options.exportCodec == "ProRes 422" ? [AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVLinearPCMBitDepthKey:24,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false,AVLinearPCMIsNonInterleaved:false]:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVEncoderBitRateKey:(options.exportAudioKbps ?? 192)*1000]
            let audioInput=AVAssetWriterInput(mediaType:.audio,outputSettings:audioSettings)
            audioInput.expectsMediaDataInRealTime=false
            reader.add(audioOutput);writer.add(audioInput);streams.append((audioOutput,audioInput))
        }
        guard writer.startWriting(),reader.startReading() else{writer.cancelWriting();reader.cancelReading();throw writer.error ?? reader.error ?? VMMError.message("書き出しを開始できませんでした。")}
        writer.startSession(atSourceTime:range.start)
        do {
            var finished=Set<Int>()
            var positions=[Double](repeating:0,count:streams.count)
            var lastProgress = -1.0
            while finished.count<streams.count {
                try Task.checkCancellation()
                if reader.status == .failed || writer.status == .failed{throw reader.error ?? writer.error ?? VMMError.message("音声の合成に失敗しました。")}
                var advanced=false
                for i in streams.indices where !finished.contains(i) && streams[i].1.isReadyForMoreMediaData {
                    if let sample=streams[i].0.copyNextSampleBuffer() {
                        let time=CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        if time.isFinite,range.duration.seconds>0 {positions[i]=max(positions[i],min(1,max(0,(time-range.start.seconds)/range.duration.seconds)))}
                        guard streams[i].1.append(sample) else{throw writer.error ?? VMMError.message("フレームを書き込めませんでした。")}
                    } else {streams[i].1.markAsFinished();finished.insert(i);positions[i]=1}
                    advanced=true
                }
                let fraction=positions.min() ?? 0
                if fraction-lastProgress>=0.01 {lastProgress=fraction;progress(fraction)}
                if !advanced{try await Task.sleep(nanoseconds:2_000_000)}
            }
            guard reader.status == .completed else{throw reader.error ?? VMMError.message("音声の合成に失敗しました。")}
            writer.endSession(atSourceTime:range.end)
            await withTaskCancellationHandler(operation:{await writer.finishWriting()},onCancel:{writer.cancelWriting()})
            try Task.checkCancellation()
            guard writer.status == .completed else{throw writer.error ?? VMMError.message("動画の保存に失敗しました。")}
        } catch {reader.cancelReading();writer.cancelWriting();throw error}
    }
}
