import XCTest
import SwiftUI
import AppKit
@testable import VMM

final class DeliveryLayoutTests:XCTestCase {
    @MainActor func testSourceRangeAndExportPanelsNativeLayout()async throws {
        guard let output=testArtifactDirectory() else{throw XCTSkip("Opt-in delivery panel snapshots")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-delivery-layout-\(UUID())"),store=EditorStore(preferencesDirectory:root),playback=LibraryPlayback()
        defer{playback.stop();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        NSApplication.shared.setActivationPolicy(.regular)
        store.project=try AudioDeliveryTests().fixture(store.directory);store.settings.autosaveSeconds=0
        playback.open(store.project.assets[0],directory:store.directory);playback.player?.pause();playback.sourceIn=0.123456;playback.sourceOut=1.234567
        try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
        for (name,view,size) in [("source-range",AnyView(LibraryPlaybackPanel(playback:playback,store:store).padding(12)),CGSize(width:420,height:360)),("export-prores",AnyView(ExportWorkspace(store:store)),CGSize(width:900,height:800))] {
            store.settings.exportCodec="ProRes 422";store.settings.exportContainer="MOV"
            let host=NSHostingView(rootView:view.frame(width:size.width,height:size.height).preferredColorScheme(.dark).vmmAppearance(store.settings))
            let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.darkAqua);host.appearance=NSAppearance(named:.darkAqua);window.contentView=host;window.makeKeyAndOrderFront(nil);defer{window.close()}
            host.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:200_000_000)
            if name=="export-prores",ProcessInfo.processInfo.environment["VMM_DELIVERY_QA_HOLD"]=="1" {try await Task.sleep(nanoseconds:30_000_000_000)}
            let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap)
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:output).appendingPathComponent(name+".png"))
        }
    }
}
