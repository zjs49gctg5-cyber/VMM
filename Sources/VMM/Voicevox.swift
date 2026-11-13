import Foundation
import AVFoundation

func audioEnvelope(url: URL) throws -> [Double] {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let window = max(1, AVAudioFrameCount(format.sampleRate / 30))
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: window) else { return [] }
    var result: [Double] = []
    while file.framePosition < file.length {
        try Task.checkCancellation()
        try file.read(into: buffer, frameCount: window)
        guard buffer.frameLength > 0, let samples = buffer.floatChannelData else { break }
        var sum = 0.0
        for index in 0..<Int(buffer.frameLength) { sum += Double(samples[0][index] * samples[0][index]) }
        result.append(sqrt(sum / Double(buffer.frameLength)))
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
