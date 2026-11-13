import XCTest
import SwiftUI
import AppKit
@testable import VMM

final class AudioMixLayoutTests:XCTestCase {
    @MainActor func testProcessingPanelAndActualMixMeters()async throws {
        guard let output=testArtifactDirectory() else{throw XCTSkip("Opt-in audio mix UI snapshots")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-mix-layout-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        NSApplication.shared.setActivationPolicy(.regular)
        var settings=MasterDynamics();settings.limiterEnabled=true;settings.compressorEnabled=true;store.project.masterDynamics=settings
        store.playbackClock.updateMeters(AudioMeterReading(leftPeak:0.7,rightPeak:0.4,leftRMS:0.3,rightRMS:0.15),tracks:[])
        try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
        for language in ["ja","en"] {
            store.settings.uiLanguage=UILanguage(rawValue:language)!
            for (name,view,size) in [("processing",AnyView(AudioProcessingPanel(store:store)),CGSize(width:460,height:500)),("meter",AnyView(TimelineAudioMeter(clock:store.playbackClock)),CGSize(width:150,height:300))] {
                let host=NSHostingView(rootView:view.frame(width:size.width,height:size.height).preferredColorScheme(.dark).vmmAppearance(store.settings))
                let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
                window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.darkAqua);window.contentView=host;window.makeKeyAndOrderFront(nil);defer{window.close()}
                host.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:200_000_000)
                let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap)
                try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:output).appendingPathComponent("audio-\(name)-\(language).png"))
            }
        }
    }
}
