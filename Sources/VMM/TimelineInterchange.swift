import AVFoundation

enum TimelineInterchange {
    static func escaped(_ text:String)->String {text.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;").replacingOccurrences(of:"'",with:"&apos;")}
    static func boundaries(project:Project,start:Double,frames:Int,fps:Int)->[Int] {
        let times=project.clips.flatMap{[$0.start,$0.end]}+(project.markers ?? []).map(\.time)
        return Set([0,frames]+times.map{Int((($0-start)*Double(fps)).rounded())}.filter{$0>0 && $0<frames}).sorted()
    }
    static func fcpxml(project:Project,movie:URL,start:Double,frames:Int,width:Int,height:Int,fps:Int,hasAudio:Bool)->String {
        func time(_ n:Int)->String {"\(n)/\(fps)s"}
        let cuts=boundaries(project:project,start:start,frames:frames,fps:fps)
        let clips=zip(cuts,cuts.dropFirst()).enumerated().map {index,pair in
            let (a,b)=pair
            let names=project.clips.filter{abs($0.start-(start+Double(a)/Double(fps)))<0.5/Double(fps)}.map(\.name).joined(separator:" / ")
            let markers=(project.markers ?? []).filter {m in let f=Int(((m.time-start)*Double(fps)).rounded());return f>=a && f<b}.map{m in "<marker start=\"\(time(Int(((m.time-start)*Double(fps)).rounded())))\" duration=\"\(time(1))\" value=\"\(escaped(m.name))\"/>"}.joined()
            return "<asset-clip name=\"\(escaped(names.isEmpty ? "VMM \(index+1)":names))\" ref=\"r2\" offset=\"\(time(a))\" start=\"\(time(a))\" duration=\"\(time(b-a))\" format=\"r1\">\(markers)</asset-clip>"
        }.joined(separator:"\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.10"><resources>
        <format id="r1" width="\(width)" height="\(height)" frameDuration="1/\(fps)s" colorSpace="1-1-1 (Rec. 709)"/>
        <asset id="r2" name="VMM rendered master" start="0s" duration="\(time(frames))" hasVideo="1" format="r1" hasAudio="\(hasAudio ? 1:0)"\(hasAudio ? " audioSources=\"1\" audioChannels=\"2\" audioRate=\"48000\"":"")><media-rep kind="original-media" src="\(escaped(movie.absoluteString))"/></asset>
        </resources><library><event name="VMM"><project name="\(escaped(project.name))"><sequence format="r1" duration="\(time(frames))" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k"><spine>
        \(clips)
        </spine></sequence></project></event></library></fcpxml>
        """
    }
    static func premiereXML(project:Project,movie:URL,start:Double,frames:Int,width:Int,height:Int,fps:Int,hasAudio:Bool)->String {
        let cuts=boundaries(project:project,start:start,frames:frames,fps:fps),rate="<rate><timebase>\(fps)</timebase><ntsc>FALSE</ntsc></rate>"
        let videoFormat="<samplecharacteristics>\(rate)<width>\(width)</width><height>\(height)</height><anamorphic>FALSE</anamorphic><pixelaspectratio>square</pixelaspectratio><fielddominance>none</fielddominance></samplecharacteristics>"
        let file="<file id=\"master\"><name>master.mov</name><pathurl>\(escaped(movie.absoluteString))</pathurl>\(rate)<duration>\(frames)</duration><media><video>\(videoFormat)</video><audio><samplecharacteristics><depth>24</depth><samplerate>48000</samplerate></samplecharacteristics><channelcount>2</channelcount></audio></media></file>"
        func items(_ channel:Int)->String {zip(cuts,cuts.dropFirst()).enumerated().map{index,pair in
            let(a,b)=pair,id=channel==0 ? "v\(index)":"a\(channel)-\(index)"
            let links=hasAudio ? "<link><linkclipref>v\(index)</linkclipref><mediatype>video</mediatype><trackindex>1</trackindex><clipindex>\(index+1)</clipindex></link>"+(1...2).map{"<link><linkclipref>a\($0)-\(index)</linkclipref><mediatype>audio</mediatype><trackindex>\($0)</trackindex><clipindex>\(index+1)</clipindex><groupindex>1</groupindex></link>"}.joined():""
            return "<clipitem id=\"\(id)\"><name>VMM \(index+1)</name><duration>\(frames)</duration>\(rate)<start>\(a)</start><end>\(b)</end><in>\(a)</in><out>\(b)</out>\(file)<sourcetrack><mediatype>\(channel==0 ? "video":"audio")</mediatype><trackindex>\(max(1,channel))</trackindex></sourcetrack>\(links)</clipitem>"
        }.joined()}
        let audio=hasAudio ? "<audio><numOutputChannels>2</numOutputChannels><format><samplecharacteristics><depth>24</depth><samplerate>48000</samplerate></samplecharacteristics></format><track>\(items(1))</track><track>\(items(2))</track></audio>":""
        let markers=(project.markers ?? []).filter{$0.time>=start && $0.time<start+Double(frames)/Double(fps)}.map{"<marker><name>\(escaped($0.name))</name><in>\(Int((($0.time-start)*Double(fps)).rounded()))</in><out>-1</out></marker>"}.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE xmeml><xmeml version=\"5\"><sequence id=\"vmm\"><name>\(escaped(project.name))</name><duration>\(frames)</duration>\(rate)<media><video><format>\(videoFormat)</format><track>\(items(0))</track></video>\(audio)</media>\(markers)</sequence></xmeml>"
    }
    static func export(project:Project,directory:URL,destination:URL,options:UserSettings,progress:@escaping @Sendable(Double)->Void)async throws {
        guard !FileManager.default.fileExists(atPath:destination.path) else{throw VMMError.message("受け渡し先には新しいフォルダ名を指定してください。")}
        let stage=destination.deletingLastPathComponent().appendingPathComponent(".vmm-handoff-\(UUID())")
        try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:stage)}
        var settings=options;settings.exportCodec="ProRes 422";settings.exportContainer="MOV";settings.exportVideoMbps=nil;settings.exportAudioKbps=nil
        let movie=stage.appendingPathComponent("master.mov")
        try await MovieExporter.export(project:project,directory:directory,destination:movie,options:settings,overwrite:false){progress($0*0.85)}
        try await AudioOnlyExporter.export(project:project,directory:directory,destination:stage.appendingPathComponent("audio.wav"),options:settings){progress(0.85+$0*0.1)}
        let asset=AVURLAsset(url:movie),duration=try await asset.load(.duration).seconds,hasAudio = !(try await asset.loadTracks(withMediaType:.audio)).isEmpty
        let d=settings.exportDimensions(project),frames=Int((duration*Double(d.fps)).rounded(.up)),start=max(0,settings.rangeStart),finalMovie=destination.appendingPathComponent("master.mov")
        try Data(fcpxml(project:project,movie:finalMovie,start:start,frames:frames,width:d.width,height:d.height,fps:d.fps,hasAudio:hasAudio).utf8).write(to:stage.appendingPathComponent("timeline.fcpxml"))
        try Data(premiereXML(project:project,movie:finalMovie,start:start,frames:frames,width:d.width,height:d.height,fps:d.fps,hasAudio:hasAudio).utf8).write(to:stage.appendingPathComponent("timeline-premiere.xml"))
        try JSONEncoder().encode(project).write(to:stage.appendingPathComponent("vmm-edit-reference.json"))
        try Data("""
        VMM 編集ソフトへの受け渡し（描画済み）
        Final Cut Pro: timeline.fcpxml / Premiere系: timeline-premiere.xml
        master.mov: ProRes 422 + PCM音声。audio.wav: 同じ音声の48 kHz/24 bitステレオ。
        XMLはVMMのアイテム境界でマスターを分割し、マーカーを保持します。
        立ち絵、字幕、合成、エフェクトと音声処理は焼き込みです。元のレイヤー・キーフレームは他ソフトの編集パラメータに変換されません。
        audio.wavとmaster.movの音声は同じです。両方を同時再生しないでください。
        vmm-edit-reference.jsonは参照用の元編集情報です。素材を含まないので.vmm保存の代わりにはなりません。
        フォルダを移動した場合、移行先でmaster.movを再リンクしてください。
        """.utf8).write(to:stage.appendingPathComponent("README.txt"))
        try Task.checkCancellation();try ExportFileCommit.install(stage,to:destination,overwrite:false);progress(1)
    }
}
