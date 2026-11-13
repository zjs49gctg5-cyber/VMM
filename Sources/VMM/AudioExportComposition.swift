import AVFoundation

enum AudioExportComposition {
    static func assemble(project:Project,directory:URL,options:UserSettings,scratch:URL,composition:AVMutableComposition,progress:@escaping @Sendable (Double)->Void = {_ in})async throws->AVMutableAudioMix {
        let project=project.audioRenderingProject
        let scope=ExportScope(project:project,options:options)
        let rangeStart=max(0,options.rangeStart),rangeEnd=options.rangeEnd>0 ? min(project.duration,options.rangeEnd):project.duration
        var parameters: [AVMutableAudioMixInputParameters] = []
        var decodedAudio: [UUID:URL] = [:]
        let audioClips=project.clips.filter{scope.audio.contains($0.id)}
        let hasMaster=project.masterDynamics?.active == true && rangeEnd>rangeStart
        for (index,clip) in audioClips.enumerated() {
            defer {progress((hasMaster ? 0.7:1)*Double(index+1)/Double(max(1,audioClips.count)))}
            try Task.checkCancellation()
            guard clip.end>rangeStart,clip.start<rangeEnd else {continue}
            guard let asset = project.asset(for: clip) else { continue }
            let originalURL=directory.appendingPathComponent("Media").appendingPathComponent(asset.file)
            var source=AVURLAsset(url:originalURL),offset=clip.sourceOffset
            let headroom=project.audioHeadroom(for:clip)
            let warped = (clip.reversed ?? false) || !(clip.speedPoints ?? []).isEmpty
            let audioClip=project.audioProcessingClip(clip)
            let effectsNeeded=(clip.pan ?? 0) != 0 || headroom>1 || (audioClip.pitchSemitones ?? 0) != 0 || (clip.equalizer?.enabled == true && clip.equalizer!.bands.contains(where:{$0.enabled && $0.gain != 0}))
            if warped || effectsNeeded || clip.mediaRate != 1 {
                let decoded:URL
                if let cached=decodedAudio[asset.id] {decoded=cached}
                else {
                    decoded=scratch.appendingPathComponent("decoded-\(asset.id).caf")
                    guard try await AudioProcessor.decode(source:originalURL,destination:decoded) else {continue}
                    decodedAudio[asset.id]=decoded
                }
                var input=decoded
                var processingClip=audioClip
                if warped {
                    input=scratch.appendingPathComponent("warped-\(clip.id).caf")
                    try TimeWarpAudio.render(input:decoded,output:input,curve:clip.timeWarpCurve,sourceStart:clip.sourceOffset,sourceEnd:clip.sourceOffset+clip.sourceDuration,duration:clip.duration,reversed:clip.reversed ?? false)
                    processingClip=AudioProcessor.warpedPlaybackClip(processingClip)
                }
                if warped && !effectsNeeded {
                    // The warp already produced the requested timeline duration.
                    // Bypass a second no-op audio graph and intermediate file.
                    source=AVURLAsset(url:input)
                } else {
                    let processed=scratch.appendingPathComponent("processed-\(clip.id).caf")
                    let processedLength=try AudioProcessor.process(decoded:input,clip:processingClip,destination:processed,gain:headroom)
                    guard processedLength>0 else {continue}
                    source=AVURLAsset(url:processed)
                }
                offset=0
            }
            guard let audio = try await source.loadTracks(withMediaType: .audio).first else {
                if clip.kind != .video { throw VMMError.message("音声素材「\(asset.name)」を読み込めませんでした。") }
                continue
            }
            let sourceDuration = try await source.load(.duration).seconds
            let length = min(clip.duration, sourceDuration - offset)
            guard length > 0, let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try track.insertTimeRange(CMTimeRange(start: CMTime(seconds: offset, preferredTimescale: 48000), duration: CMTime(seconds: length, preferredTimescale: 48000)), of: audio, at: CMTime(seconds: clip.start, preferredTimescale: 48000))
            let parameter = AVMutableAudioMixInputParameters(track: track)
            if clip.ducking != nil || clip.parentID != nil || clip.audioFade != nil || clip.animation?.tracks.contains(where: { $0.property == .volume && $0.enabled }) == true {
                parameter.setVolume(Float(project.effectiveAudioVolume(clip,at: clip.start)/headroom), at: .zero)
                let steps = max(1, Int(ceil(length * 30)))
                for step in 0..<steps {
                    let a = Double(step) * length / Double(steps), b = Double(step + 1) * length / Double(steps)
                    parameter.setVolumeRamp(fromStartVolume: Float(project.effectiveAudioVolume(clip,at: clip.start + a)/headroom), toEndVolume: Float(project.effectiveAudioVolume(clip,at: clip.start + b)/headroom), timeRange: CMTimeRange(start: CMTime(seconds: clip.start + a, preferredTimescale: 48000), end: CMTime(seconds: clip.start + b, preferredTimescale: 48000)))
                }
            } else { parameter.setVolume(Float(project.effectiveAudioVolume(clip,at:clip.start)/headroom), at: .zero) }
            parameters.append(parameter)
        }
        let mix=AVMutableAudioMix();mix.inputParameters=parameters
        if let settings=project.masterDynamics,settings.active,rangeEnd>rangeStart {
            let floatMix=scratch.appendingPathComponent("master-input.wav"),processed=scratch.appendingPathComponent("master-processed.caf")
            try await AudioOnlyExporter.renderMix(composition:composition,mix:mix,start:rangeStart,end:rangeEnd,destination:floatMix,floatPCM:true){value in progress(0.7+0.25*value)}
            try PlaybackAudioEngine.process(floatMix,to:processed,settings:settings)
            for track in composition.tracks(withMediaType:.audio){composition.removeTrack(track)}
            let asset=AVURLAsset(url:processed)
            if let audio=try await asset.loadTracks(withMediaType:.audio).first,let track=composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) {
                try track.insertTimeRange(CMTimeRange(start:.zero,duration:CMTime(seconds:rangeEnd-rangeStart,preferredTimescale:48000)),of:audio,at:CMTime(seconds:rangeStart,preferredTimescale:48000))
            }
            progress(1)
            return AVMutableAudioMix()
        }
        progress(1)
        return mix
    }
}
