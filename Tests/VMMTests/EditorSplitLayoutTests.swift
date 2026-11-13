import XCTest
import SwiftUI
import AppKit
@testable import VMM
final class EditorSplitLayoutTests: XCTestCase {
 @MainActor func testDividerAndImportedLibrary() async throws {
  guard ProcessInfo.processInfo.environment["VMM_SPLIT_QA"] == "1" else {throw XCTSkip("Opt-in native split view test")}
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-split-\(UUID())")
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  let store=EditorStore(preferencesDirectory:root);store.settings.autosaveSeconds=0;store.autoSpeech=false
  defer {try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
  for (name,color) in [("zebra.png",NSColor.red),("apple.png",NSColor.green),("blue.png",NSColor.blue)] {
   let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:32,pixelsHigh:32,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
   NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep);color.setFill();NSRect(x:0,y:0,width:32,height:32).fill();NSGraphicsContext.restoreGraphicsState()
   let url=root.appendingPathComponent(name);try rep.representation(using:.png,properties:[:])!.write(to:url)
   _ = try await store.importURLs([url])
  }
  _ = NSApplication.shared; NSApp.setActivationPolicy(.regular)
  let w=NSWindow(contentRect:NSRect(x:0,y:0,width:1250,height:800),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
  w.title="VMM isolated QA";w.isReleasedWhenClosed=false
  let host=NSHostingView(rootView:EditorView(store:store).frame(width:1250,height:800));w.contentView=host;w.center();w.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
  try await Task.sleep(nanoseconds:500_000_000); host.layoutSubtreeIfNeeded()
  func find(_ v:NSView)->NSSplitView? {
   if let s=v as? NSSplitView,s.isVertical {return s}
   for child in v.subviews {if let s=find(child) {return s}}
   return nil
  }
  let split=try XCTUnwrap(find(host)); XCTAssertEqual(split.dividerStyle,.thick);XCTAssertGreaterThan(split.dividerThickness,1)
  XCTAssertEqual(LibraryQuery.assets(store.libraryAssets,search:"blue",filter:.all,sort:.name,descending:false).map(\.name),["blue.png"])
  XCTAssertEqual(LibraryQuery.assets(store.libraryAssets,search:"",filter:.image,sort:.name,descending:false).map(\.name),["apple.png","blue.png","zebra.png"])
  w.close()
 }
}
