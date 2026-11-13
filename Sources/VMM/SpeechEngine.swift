import Foundation
import AVFoundation

enum SpeechEngine:String,Codable,CaseIterable,Identifiable {
    case voicevox,aivisSpeech,styleBertVITS2,qwen3TTS
    var id:String {rawValue}
    var title:String {switch self {case .voicevox:return "VOICEVOX";case .aivisSpeech:return "AivisSpeech";case .styleBertVITS2:return "Style-BERT-VITS2";case .qwen3TTS:return "Qwen3-TTS"}}
    var defaultURL:String {switch self {case .voicevox:return "http://127.0.0.1:50021";case .aivisSpeech:return "http://127.0.0.1:10101";case .styleBertVITS2:return "http://127.0.0.1:5000";case .qwen3TTS:return "http://127.0.0.1:8001"}}
}
struct SpeechConfiguration:Codable,Equatable {
    var engine:SpeechEngine = .voicevox
    var endpoint="http://127.0.0.1:50021"
    var modelName:String?;var modelID:Int?;var speaker:String?;var style:String?
    var language:String?;var instruction:String?
    static func defaults(_ engine:SpeechEngine)->Self {Self(engine:engine,endpoint:engine.defaultURL)}
    func validated()throws->Self {
        guard let url=URLComponents(string:endpoint),["http","https"].contains(url.scheme?.lowercased() ?? ""),["127.0.0.1","localhost","::1","[::1]"].contains(url.host?.lowercased() ?? ""),url.user==nil,url.password==nil,url.query==nil,url.fragment==nil,url.port.map({(1...65535).contains($0)}) ?? true,modelID.map({(0...100000).contains($0)}) ?? true,[modelName,speaker,style,language].compactMap({$0}).allSatisfy({$0.count<=256}),(instruction?.count ?? 0)<=4000 else {throw VMMError.message("音声エンジンの接続先・設定が不正です。接続先はこのMacのループバックURLを指定してください。")}
        return self
    }
}
struct SpeechService {
    var session:URLSession = .shared
    func request(_ config:SpeechConfiguration,_ route:String,query:[URLQueryItem]=[],body:Data?=nil,post:Bool=false)async throws->Data {
        let config=try config.validated()
        var url=URLComponents(url:URL(string:config.endpoint)!.appendingPathComponent(route),resolvingAgainstBaseURL:false)!
        url.queryItems=query.isEmpty ? nil:query
        var request=URLRequest(url:url.url!);request.httpMethod=post ? "POST":"GET";request.timeoutInterval=post ? 600:10;request.httpBody=body
        if body != nil {request.setValue("application/json",forHTTPHeaderField:"Content-Type")}
        let data:Data,response:URLResponse
        do{(data,response)=try await session.data(for:request)}
        catch let error as URLError{if error.code == .cancelled{throw CancellationError()};throw VMMError.message("\(config.engine.title)：音声エンジンに接続できません（\(error.errorCode)）。")}
        if (response as? HTTPURLResponse)?.value(forHTTPHeaderField:"Server")?.hasPrefix("AirTunes/")==true {throw VMMError.message("接続先はmacOSのAirPlayです。音声エンジンを別ポートで起動し、接続先URLを変更してください。") }
        guard let http=response as? HTTPURLResponse else {throw VMMError.message("音声エンジンの応答が不正です。")}
        guard (200...299).contains(http.statusCode) else {throw VMMError.message("\(config.engine.title)：HTTP \(http.statusCode)\n\(String(data:data.prefix(512),encoding:.utf8) ?? "")")}
        guard !data.isEmpty,data.count<=100_000_000 else {throw VMMError.message("音声エンジンの応答サイズが不正です。")}
        if ["speakers","models/info","audio_query"].contains(route),(try? JSONSerialization.jsonObject(with:data))==nil{throw VMMError.message("接続先からJSONが返されませんでした。音声エンジンのURLを確認してください。")}
        return data
    }
    func speakers(_ config:SpeechConfiguration)async throws->[VoiceChoice] {
        switch config.engine {
        case .voicevox,.aivisSpeech:
            return try JSONDecoder().decode([VoiceSpeaker].self,from:await request(config,"speakers")).flatMap {s in s.styles.map {VoiceChoice(id:$0.id,name:"\(s.name) / \($0.name)",configuration:config)}}
        case .styleBertVITS2:
            let raw=try await request(config,"models/info")
            guard let models=try JSONSerialization.jsonObject(with:raw) as? [String:[String:Any]] else {throw VMMError.message("モデル一覧を読み込めませんでした。")}
            var choices:[VoiceChoice]=[]
            for key in models.keys.sorted(by:{(Int($0) ?? 0)<(Int($1) ?? 0)}) {
                guard let id=Int(key),let model=models[key],let speakers=model["spk2id"] as? [String:Int],let styles=model["style2id"] as? [String:Int] else {throw VMMError.message("モデル一覧を読み込めませんでした。")}
                let name=(model["model_path"] as? String).map{URL(fileURLWithPath:$0).deletingLastPathComponent().lastPathComponent} ?? key
                for speaker in speakers.keys.sorted() {for style in styles.keys.sorted() {
                    var c=config;c.modelID=id;c.modelName=(model["model_path"] as? String).map{URL(fileURLWithPath:$0).deletingLastPathComponent().lastPathComponent};c.speaker=speaker;c.style=style
                    choices.append(VoiceChoice(id:Self.voiceID("\(name)/\(speaker)/\(style)"),name:"\(name) / \(speaker) / \(style)",configuration:c))
                }}
            }
            guard Set(choices.map(\.id)).count==choices.count else {throw VMMError.message("話者IDが重複しています。モデル名を確認してください。")};return choices
        case .qwen3TTS:
            struct Voices:Decodable {var speakers:[String]}
            return try JSONDecoder().decode(Voices.self,from:await request(config,"speakers")).speakers.map {name in var c=config;c.speaker=name;return VoiceChoice(id:Self.voiceID(name),name:name,configuration:c)}
        }
    }
    func synthesize(text:String,speaker:Int,speed:Double,configuration:SpeechConfiguration)async throws->Data {
        try await synthesizeWithTiming(text:text,speaker:speaker,speed:speed,configuration:configuration).data
    }
    struct SynthesisResult {var data:Data;var vowelTiming:VowelTiming?}
    func synthesizeWithTiming(text:String,speaker:Int,speed:Double,configuration:SpeechConfiguration)async throws->SynthesisResult {
        guard !text.isEmpty,text.count<=50000,speed.isFinite,(0.5...2).contains(speed) else {throw VMMError.message("読み上げ文字・話速が不正です。")}
        let c=try configuration.validated(),data:Data
        var vowelTiming:VowelTiming?
        switch c.engine {
        case .voicevox,.aivisSpeech:
            let query=try await request(c,"audio_query",query:[.init(name:"text",value:text),.init(name:"speaker",value:String(speaker))],post:true)
            guard var object=try JSONSerialization.jsonObject(with:query) as? [String:Any] else {throw VMMError.message("音声クエリを読み込めませんでした。")}
            // Retain engine-specific fields (especially AivisSpeech query fields).
            object["speedScale"]=speed
            if c.engine == .voicevox {vowelTiming=VoicevoxVowelTiming.parse(object,speed:speed)}
            data=try await request(c,"synthesis",query:[.init(name:"speaker",value:String(speaker))],body:JSONSerialization.data(withJSONObject:object),post:true)
        case .styleBertVITS2:
            guard let model=c.modelID,let name=c.speaker,let style=c.style else {throw VMMError.message("接続してモデル・話者・スタイルを選択してください。")}
            var query:[URLQueryItem]=[.init(name:"text",value:text),.init(name:"model_id",value:String(model)),.init(name:"speaker_name",value:name),.init(name:"style",value:style),.init(name:"language",value:c.language ?? "JP"),.init(name:"length",value:String(1/speed))]
            if let name=c.modelName,!name.isEmpty {query.append(.init(name:"model_name",value:name))}
            data=try await request(c,"voice",query:query,post:true)
        case .qwen3TTS:
            guard let speaker=c.speaker else {throw VMMError.message("Qwen3-TTSの話者を選択してください。")}
            data=try await request(c,"synthesis",body:JSONSerialization.data(withJSONObject:["text":text,"speaker":speaker,"language":c.language ?? "Japanese","instruct":c.instruction ?? ""]),post:true)
        }
        guard data.count>=12,String(data:data.prefix(4),encoding:.ascii)=="RIFF",String(data:data.subdata(in:8..<12),encoding:.ascii)=="WAVE" else {throw VMMError.message("音声エンジンからWAV音声が返されませんでした。")}
        if c.engine == .qwen3TTS,speed != 1 {return SynthesisResult(data:try await Task.detached {try Self.adjustSpeed(data,speed:speed)}.value,vowelTiming:nil)}
        return SynthesisResult(data:data,vowelTiming:vowelTiming)
    }
    static func voiceID(_ value:String)->Int {Int(value.utf8.reduce(UInt32(2166136261)){($0 ^ UInt32($1)) &* 16777619} & 0x7fffffff)}
    static func adjustSpeed(_ data:Data,speed:Double)throws->Data {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-tts-speed-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let input=root.appendingPathComponent("source.wav"),output=root.appendingPathComponent("output.wav");try data.write(to:input)
        let file=try AVAudioFile(forReading:input)
        var clip=Clip(kind:.audio,name:"TTS",track:0,start:0,duration:Double(file.length)/file.processingFormat.sampleRate/speed);clip.playbackRate=speed
        _=try AudioProcessor.process(decoded:input,clip:clip,destination:output)
        return try Data(contentsOf:output)
    }
}
