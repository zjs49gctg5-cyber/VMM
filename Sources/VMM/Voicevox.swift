import Foundation
import AVFoundation
import AudioToolbox

func audioEnvelope(url: URL) throws -> [Double] {
    // AVAudioFile.framePosition may raise an Objective-C exception for media
    // containers whose decoder cannot report its position. Swift's `try` does
    // not catch that exception. The Core Audio C API reports errors as OSStatus.
    func check(_ status:OSStatus)throws {
        guard status == noErr else {throw NSError(domain:NSOSStatusErrorDomain,code:Int(status),userInfo:[NSLocalizedDescriptionKey:"音声波形を読み込めませんでした（\(status)）。"])}
    }
    var opened:ExtAudioFileRef?
    try check(ExtAudioFileOpenURL(url as CFURL,&opened))
    guard let file=opened else {throw VMMError.message("音声波形を読み込めませんでした。")}
    defer{ExtAudioFileDispose(file)}
    var source=AudioStreamBasicDescription(),size=UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try check(ExtAudioFileGetProperty(file,kExtAudioFileProperty_FileDataFormat,&size,&source))
    guard source.mSampleRate.isFinite,(1...768000).contains(source.mSampleRate),(1...32).contains(source.mChannelsPerFrame) else {throw VMMError.message("音声の形式が不正です。")}
    let channels=source.mChannelsPerFrame,bytesPerFrame=channels*UInt32(MemoryLayout<Float>.size)
    var format=AudioStreamBasicDescription(mSampleRate:source.mSampleRate,mFormatID:kAudioFormatLinearPCM,
        mFormatFlags:kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
        mBytesPerPacket:bytesPerFrame,mFramesPerPacket:1,mBytesPerFrame:bytesPerFrame,
        mChannelsPerFrame:channels,mBitsPerChannel:32,mReserved:0)
    try check(ExtAudioFileSetProperty(file,kExtAudioFileProperty_ClientDataFormat,UInt32(MemoryLayout<AudioStreamBasicDescription>.size),&format))
    let window=max(1,UInt32(source.mSampleRate/30))
    var samples=[Float](repeating:0,count:Int(window)*Int(channels))
    var result: [Double] = []
    while true {
        try Task.checkCancellation()
        var frames=window
        let status=samples.withUnsafeMutableBytes { bytes in
            var list=AudioBufferList(mNumberBuffers:1,mBuffers:AudioBuffer(mNumberChannels:channels,mDataByteSize:UInt32(bytes.count),mData:bytes.baseAddress))
            return ExtAudioFileRead(file,&frames,&list)
        }
        try check(status)
        guard frames>0 else {break}
        var sum = 0.0
        for index in 0..<Int(frames) {let sample=samples[index*Int(channels)];if sample.isFinite {sum += Double(sample)*Double(sample)}}
        result.append(sqrt(sum / Double(frames)))
    }
    return result
}

struct VoiceSpeaker: Decodable {
    var name: String
    var styles: [VoiceStyle]
}
struct VoiceStyle: Decodable, Identifiable {
    var name: String
    var id: Int
}
struct VoiceChoice: Identifiable {
    var id: Int
    var name: String
    var configuration:SpeechConfiguration?
}

struct Voicevox {
    var base = URL(string: "http://127.0.0.1:50021")!
    func request(_ route: String, query: [URLQueryItem] = [], body: Data? = nil, post: Bool = false) async throws -> Data {
        var components = URLComponents(url: base.appendingPathComponent(route), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.httpMethod = post ? "POST" : "GET"
        request.timeoutInterval = post ? 120 : 5
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw VMMError.message("VOICEVOXで処理できませんでした。話者とセリフを確認してください。")
        }
        return data
    }
    func speakers() async throws -> [VoiceChoice] {
        let data = try await request("speakers")
        return try JSONDecoder().decode([VoiceSpeaker].self, from: data).flatMap { speaker in
            speaker.styles.map { VoiceChoice(id: $0.id, name: "\(speaker.name) / \($0.name)") }
        }
    }
    func synthesize(text: String, speaker: Int, speed: Double) async throws -> Data {
        let query = try await request("audio_query", query: [.init(name: "text", value: text), .init(name: "speaker", value: String(speaker))], post: true)
        guard var object = try JSONSerialization.jsonObject(with: query) as? [String: Any] else {
            throw VMMError.message("VOICEVOXの応答を読み取れませんでした。")
        }
        object["speedScale"] = speed
        return try await request("synthesis", query: [.init(name: "speaker", value: String(speaker))], body: JSONSerialization.data(withJSONObject: object), post: true)
    }
}
