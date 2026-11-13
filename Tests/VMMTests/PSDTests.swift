import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class PSDTests: XCTestCase {
    func sample() -> PSDDocument {
        PSDDocument(width: 10, height: 10, layers: [
            PSDLayer(id: 0, name: "!口", group: true, visible: false, opacity: 1, x: 0, y: 0, width: 0, height: 0),
            PSDLayer(id: 1, parent: 0, name: "*開き", group: false, visible: true, opacity: 1, x: 0, y: 0, width: 1, height: 1),
            PSDLayer(id: 2, parent: 0, name: "*閉じ", group: false, visible: true, opacity: 1, x: 0, y: 0, width: 1, height: 1),
            PSDLayer(id: 3, name: "髪/特殊%\\~", group: false, visible: true, opacity: 1, x: 0, y: 0, width: 1, height: 1),
            PSDLayer(id: 4, name: "髪/特殊%\\~", group: false, visible: false, opacity: 1, x: 0, y: 0, width: 1, height: 1)
        ])
    }
    func testForcedRadioAndEscapedDuplicatePaths() throws {
        let doc = sample()
        try doc.validate()
        XCTAssertEqual(doc.defaults, [0, 1, 3])
        XCTAssertEqual(doc.selecting(2, enabled: true, in: doc.defaults), [0, 2, 3])
        XCTAssertEqual(doc.selecting(0, enabled: false, in: doc.defaults), doc.defaults)
        XCTAssertEqual(doc.selecting(1, enabled: false, in: doc.defaults), doc.defaults)
        XCTAssertTrue(doc.path(for: 3).hasSuffix("\\1"))
        for layer in doc.layers { XCTAssertEqual(doc.resolve(doc.path(for: layer.id)), layer.id) }
        let favorite = PSDFavorite(name: "笑顔/テスト%", paths: [doc.path(for: 2), doc.path(for: 3)])
        let parsed = try PFV.read(PFV.write([favorite]))
        XCTAssertEqual(parsed[0].name, favorite.name)
        XCTAssertEqual(try doc.applying(parsed[0], to: []), [0, 2, 3])
        XCTAssertThrowsError(try doc.applying(.init(name: "bad", paths: ["missing"]), to: doc.defaults))
    }
    func testPFVFilterPreservesOtherPartsAndUnknownRecords() throws {
        let doc = sample()
        let text = "[PSDToolFavorites-v1]\nroot-name/test\n//表情~filter\n!口\n//表情/閉じ\n!口/*閉じ\n//未来~unknown\ninvalid\n"
        let favorites = try PFV.read(text)
        XCTAssertEqual(favorites.count, 1)
        XCTAssertEqual(try doc.applying(favorites[0], to: doc.defaults), [0, 2, 3])
        let roundTrip = try PFV.read(PFV.write(favorites))
        XCTAssertEqual(roundTrip[0].filters, favorites[0].filters)
        XCTAssertEqual(try doc.applying(roundTrip[0], to: doc.defaults), [0, 2, 3])
    }
    func testFlipVariantAndBlink() {
        var doc = sample()
        doc.layers += [PSDLayer(id: 5, name: "体", group: false, visible: true, opacity: 1, x: 0, y: 0, width: 1, height: 1),
                       PSDLayer(id: 6, name: "体:flipx", group: false, visible: false, opacity: 1, x: 0, y: 0, width: 1, height: 1)]
        var state = PSDState(selected: doc.defaults)
        state.flipX = true
        let selected = state.visibility(document: doc, speaking: false, time: 0)
        XCTAssertFalse(selected.contains(5)); XCTAssertTrue(selected.contains(6))
        state.mouthClosed = 2; state.mouthOpen = 1; state.mouthAnimation = true
        XCTAssertTrue(state.visibility(document: doc, speaking: false, time: 0).contains(2))
        XCTAssertTrue(state.visibility(document: doc, speaking: true, time: 0).contains(1))
        state.mouthAnimation = false; state.blink = true; state.eyeClosed = 2
        XCTAssertTrue(state.visibility(document: doc, speaking: false, time: 2.95).contains(2))
        XCTAssertTrue(state.visibility(document: doc, speaking: false, time: 3.1).contains(1))
    }
    func testMalformedInputAndRLEBounds() throws {
        XCTAssertThrowsError(try PSDZip.read(Data([0, 1, 2])))
        XCTAssertThrowsError(try PSDImporter.decodeChannel(Data([0, 1, 0, 2, 252, 255]), width: 2, height: 1))
        XCTAssertEqual(try PSDImporter.decodeChannel(Data([0, 1, 0, 3, 1, 10, 20]), width: 2, height: 1), [10, 20])
        var doc = sample(); doc.layers[0].parent = 0
        XCTAssertThrowsError(try doc.validate())
        doc = sample(); doc.layers[1].file = "../escape.png"
        XCTAssertThrowsError(try doc.validate())
    }
    func testAttachedPSDArchiveAndRender() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["VMM_PSD_FIXTURE"] else { throw XCTSkip("Set VMM_PSD_FIXTURE to the user-provided ZIP.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vmm-psd-test-\(UUID())")
        let media = folder.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let assets = try EditorStore.importPSD(URL(fileURLWithPath: fixture), into: media)
        XCTAssertEqual(assets.count, 3)
        let renderer = PSDRenderer()
        for (index, asset) in assets.enumerated() {
            let doc = try XCTUnwrap(asset.psd)
            XCTAssertEqual(doc.width, 1082); XCTAssertEqual(doc.height, 1594)
            XCTAssertGreaterThan(doc.layers.count, 60)
            var state = PSDState.initial(doc)
            let base = try XCTUnwrap(renderer.image(asset: asset, state: state, directory: folder, speaking: false, time: 0))
            let merged = try XCTUnwrap(NSImage(contentsOf: media.appendingPathComponent(asset.file)))
            let basePixels = try pixels(base, width: doc.width, height: doc.height)
            let mergedPixels = try pixels(merged, width: doc.width, height: doc.height)
            let error = zip(basePixels, mergedPixels).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(basePixels.count) / 255
            XCTAssertLessThan(error, 0.012, "Default composition diverges from the PSD merged image: \(asset.name), \(error)")
            state.mouthAnimation = true; state.blink = true
            let closed = try XCTUnwrap(renderer.image(asset: asset, state: state, directory: folder, speaking: false, time: 0))
            let speaking = try XCTUnwrap(renderer.image(asset: asset, state: state, directory: folder, speaking: true, time: 0))
            let blink = try XCTUnwrap(renderer.image(asset: asset, state: state, directory: folder, speaking: true, time: 2.95))
            XCTAssertFalse(try pixels(closed, width: doc.width, height: doc.height) == pixels(speaking, width: doc.width, height: doc.height))
            XCTAssertFalse(try pixels(blink, width: doc.width, height: doc.height) == pixels(speaking, width: doc.width, height: doc.height))
            if let output = testArtifactDirectory() {
                let target = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                for (name, image) in [("default", base), ("closed", closed), ("speaking", speaking), ("blink", blink)] {
                    let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                    try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!.write(to: target.appendingPathComponent("psd-\(index)-\(name).png"))
                }
            }
        }
        // Project reload must copy every decoded layer, not just the original PSD.
        let saved = folder.appendingPathComponent("roundtrip.vmm")
        try await MainActor.run {
            let store = EditorStore()
            defer { try? FileManager.default.removeItem(at: store.directory) }
            for asset in assets { for file in asset.files { try FileManager.default.copyItem(at: media.appendingPathComponent(file), to: store.directory.appendingPathComponent("Media").appendingPathComponent(file)) } }
            store.project = Project(); store.project.assets = assets
            store.add(.image, asset: assets[0]); store.savedURL = saved
            XCTAssertTrue(store.save(), store.error ?? "")
            let expected = store.project
            store.loadProject(saved)
            XCTAssertNil(store.error); XCTAssertEqual(store.project, expected)
            for asset in assets { for file in asset.files { XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("Media").appendingPathComponent(file).path)) } }
        }
        if let output = testArtifactDirectory() {
            let target = URL(fileURLWithPath: output).appendingPathComponent("Zundamon-PSD.vmm")
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: saved, to: target)
            if ProcessInfo.processInfo.environment["VMM_LIVE_VOICEVOX"] == "1" {
                let voices = try await Voicevox().speakers()
                let voice = try XCTUnwrap(voices.first { $0.name == "ずんだもん / ノーマル" })
                let text = "ずんだもんなのだ。Macでも、表情を変えてお話しできるのだ。"
                let wav = try await Voicevox().synthesize(text: text, speaker: voice.id, speed: 1)
                let audioURL = target.appendingPathComponent("Media/psd-demo-voice.wav")
                try wav.write(to: audioURL, options: .atomic)
                let duration = try await AVURLAsset(url: audioURL).load(.duration).seconds
                let audio = MediaAsset(name: "ずんだもん.wav", file: "psd-demo-voice.wav", kind: .audio, duration: duration, envelope: try audioEnvelope(url: audioURL))
                var project = Project()
                project.name = "ずんだもん PSD互換サンプル"; project.width = 1280; project.height = 720
                project.assets = assets + [audio]
                var character = Clip(kind: .image, name: "ずんだもん・PSD", track: 0, start: 0, duration: ceil(duration * 30) / 30)
                character.assetID = assets[0].id; character.characterSpeakerID = voice.id
                character.psd = .initial(assets[0].psd!); character.psd?.mouthAnimation = true; character.psd?.blink = true
                character.psd?.blinkInterval = 2; character.x = 0.28; character.y = 0.5; character.scale = 0.96
                var speech = Clip(kind: .speech, name: "ずんだもん", track: 1, start: 0, duration: character.duration)
                speech.assetID = audio.id; speech.speakerID = voice.id; speech.speakerName = voice.name
                speech.text = "ずんだもんなのだ。\nMacでも、表情を変えて\nお話しできるのだ。"; speech.fontSize = 38; speech.x = 0.67; speech.y = 0.48
                var title = Clip(kind: .text, name: "タイトル", track: 2, start: 0, duration: character.duration)
                title.text = "PSD × VOICEVOX"; title.x = 0.67; title.y = 0.2; title.fontSize = 48; title.color = "9FE870"
                var credit = Clip(kind: .text, name: "クレジット", track: 3, start: 0, duration: character.duration)
                credit.text = "立ち絵：坂本アヒル  /  VOICEVOX:ずんだもん"; credit.x = 0.66; credit.y = 0.9; credit.fontSize = 19
                project.clips = [character, speech, title, credit]
                let doc = assets[0].psd!
                let favorite = PSDFavorite(name: "通常の表情", paths: doc.layers.filter { doc.isVisible($0.id, in: Set(doc.defaults)) }.map { doc.path(for: $0.id) })
                project.clips[0].psd?.favorites = [favorite]
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(project).write(to: target.appendingPathComponent("project.json"), options: .atomic)
                try PFV.write([favorite]).write(to: URL(fileURLWithPath: output).appendingPathComponent("Zundamon-expression.pfv"), atomically: true, encoding: .utf8)
                let movie = URL(fileURLWithPath: output).appendingPathComponent("Zundamon-PSD.mp4")
                try await MovieExporter.export(project: project, directory: target, destination: movie) { _ in }
                let audioTracks = try await AVURLAsset(url: movie).loadTracks(withMediaType: .audio)
                XCTAssertEqual(audioTracks.count, 1)
            }
        }
    }
    private func pixels(_ image: NSImage, width: Int, height: Int) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }
}
