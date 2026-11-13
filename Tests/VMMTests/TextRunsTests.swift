import XCTest
import AppKit
import AVFoundation
import SwiftUI
@testable import VMM

final class TextRunsTests:XCTestCase {
    @MainActor func testStyleSheetSnapshot()async throws {
        guard let output=testArtifactDirectory() else{throw XCTSkip("Opt-in text style UI snapshot")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-text-style-sheet-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let clip=Clip(kind:.text,name:"subtitle",track:1,start:0,duration:3,text:"大切な部分の色とサイズを変更します。")
        store.project=Project();store.project.clips=[clip]
        let size=CGSize(width:640,height:540),host=NSHostingView(rootView:TextRunStyleSheet(store:store,clip:clip).frame(width:size.width,height:size.height).preferredColorScheme(.dark).vmmAppearance(store.settings))
        let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.titled,.resizable],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.darkAqua);window.contentView=host;window.makeKeyAndOrderFront(nil);defer{window.close()}
        host.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:150_000_000)
        let rep=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:rep);try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
        try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:output).appendingPathComponent("character-style.png"))
    }
    func testUnicodeRangeApplyRebaseAndValidation()throws {
        let text="A👨‍👩‍👧‍👦Bか\u{3099}C"
        let runs=try TextRunEditing.apply(nil,text:text,range:1..<3){$0.color="00FF00";$0.fontSize=80}
        XCTAssertEqual(runs?.first?.start,1);XCTAssertEqual(runs?.first?.end,3)
        let updated=TextRunEditing.rebase(runs,old:text,new:"X"+text)
        XCTAssertEqual(updated?.first?.start,2);XCTAssertEqual(updated?.first?.end,4)
        try TextRunEditing.validate(updated,text:"X"+text)
        let slice=TextRunEditing.slice(updated,range:2..<4);XCTAssertEqual(slice?.first?.start,0);XCTAssertEqual(slice?.first?.end,2)
        XCTAssertThrowsError(try TextRunEditing.validate([TextRun(start:1,end:99,style:TextRunStyle(color:"FF0000"))],text:text))
        XCTAssertThrowsError(try TextRunEditing.apply(nil,text:text,range:5..<7){$0.color="FF0000"})
    }
    @MainActor func testEditingUndoMCPAndCaptionSplit()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-text-runs-\(UUID())"),s=EditorStore(preferencesDirectory:root)
        defer{s.cancelSpeech();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:s.directory)}
        s.autoSpeech=false;s.project=Project();var clip=Clip(kind:.speech,name:"text",track:1,start:0,duration:2,text:"Hello World")
        s.project.clips=[clip]
        try s.applyTextRunStyle(clipID:clip.id,originalText:clip.text,range:6..<11){$0.color="00FF00";$0.outlineColor="0000FF";$0.outline=true}
        clip=try XCTUnwrap(s.project.clips.first);XCTAssertEqual(clip.textRuns?.first?.start,6)
        s.edit(clip.id){$0.text="Hi "+$0.text};XCTAssertEqual(s.project.clips[0].textRuns?.first?.start,9)
        s.undo();XCTAssertEqual(s.project.clips[0].textRuns,clip.textRuns)
        let api=EditorCommands();api.store=s
        let updated=try api.patched(clip,["text":"X"+clip.text],project:s.project);XCTAssertEqual(updated.textRuns?.first?.start,7)
        s.project.tracks[1].locked=true;XCTAssertThrowsError(try s.applyTextRunStyle(clipID:clip.id,originalText:clip.text,range:0..<2){$0.color="FF0000"});s.project.tracks[1].locked=false
        let parts=[CaptionSplitPart(text:"Hello",start:0,end:1),CaptionSplitPart(text:"World",start:1,end:2)]
        try s.applyCaptionSplit(original:clip,fps:30,parts:parts)
        let captions=s.project.clips.filter{$0.kind == .text};XCTAssertEqual(captions.count,2);XCTAssertNil(captions[0].textRuns);XCTAssertEqual(captions[1].textRuns?.first?.start,0);XCTAssertEqual(captions[1].textRuns?.first?.end,5)
        _=try s.project.validated();XCTAssertEqual(try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(s.project)),s.project)
    }
    @MainActor func testPreviewEditingRebasesCharacterStyles()throws {
        let (store,view,_)=PreviewEditingTests().fixture();defer{try? FileManager.default.removeItem(at:store.directory)}
        var clip=Clip(kind:.text,name:"caption",track:0,start:0,duration:2,text:"こんにちは",fontSize:48)
        clip.textRuns=[TextRun(start:2,end:4,style:TextRunStyle(color:"FF0000"))];store.project.clips=[clip];store.selectedID=clip.id
        view.beginTextEditing(clip);try XCTUnwrap(view.textInput).string="新"+clip.text;view.finishTextEditing(commit:true)
        XCTAssertEqual(store.selected?.textRuns?.first?.start,3);XCTAssertEqual(store.selected?.textRuns?.first?.end,5)
        store.undo();XCTAssertEqual(store.selected?.textRuns,clip.textRuns)
    }
    func testRenderingRevealGradientAndCacheInvalidation()throws {
        var p=Project();p.width=640;p.height=360;p.background="000000"
        var clip=Clip(kind:.text,name:"mixed",track:0,start:0,duration:2,text:"ABC",fontSize:90,color:"FF0000")
        clip.textRuns=[TextRun(start:1,end:2,style:TextRunStyle(color:"00FF00",fontSize:110,outline:true,outlineColor:"0000FF",outlineWidth:4))]
        var style=TextStyle();style.shadow=true;style.fillGradient=TextGradient(enabled:true,endColor:"FFFFFF",angle:0);clip.textStyle=style;p.clips=[clip];_=try p.validated()
        let renderer=FrameRenderer()
        func render(_ project:Project,_ time:Double)throws->[UInt8] {
            let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:640,height:360)))
            renderer.draw(project:project,directory:FileManager.default.temporaryDirectory,time:time,context:context,size:CGSize(width:640,height:360))
            return try AdvancedTests().pixels(context)
        }
        let first=try render(p,0.5);p.clips[0].textRuns?[0].style.color="0000FF";let changed=try render(p,0.5);XCTAssertNotEqual(first,changed)
        p.clips[0].textRevealRate=2;let early=try render(p,1),late=try render(p,2-1/30);XCTAssertNotEqual(early,late)
        p.clips[0].textRuns=nil;let without=try render(p,2-1/30);XCTAssertNotEqual(late,without)
    }
    func testMissingPerCharacterFontIsReported() {
        var p=Project();p.clips=[Clip(kind:.text,name:"font",track:0,start:0,duration:1,text:"AB")]
        p.clips[0].textRuns=[TextRun(start:1,end:2,style:TextRunStyle(fontName:"VMM-Definitely-Missing-Font-9B2E"))]
        let report=ExportPreflight.inspect(project:p,directory:FileManager.default.temporaryDirectory,options:UserSettings())
        XCTAssertTrue(report.issues.contains{$0.id=="font-VMM-Definitely-Missing-Font-9B2E" && $0.severity == .warning})
    }
    func testMixedStylesExportMP4()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-text-runs-export-\(UUID())");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        var p=Project();p.width=640;p.height=360;p.background="000000"
        var clip=Clip(kind:.text,name:"mixed",track:0,start:0,duration:0.5,text:"AB",fontSize:130,color:"FF0000")
        clip.textRuns=[TextRun(start:1,end:2,style:TextRunStyle(color:"00FF00",fontSize:110))];p.clips=[clip]
        let output=root.appendingPathComponent("mixed.mp4");try await MovieExporter.export(project:p,directory:root,destination:output){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:output)),image=try generator.copyCGImage(at:.zero,actualTime:nil)
        let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:640,height:360)));context.draw(image,in:CGRect(x:0,y:0,width:640,height:360));let pixels=try AdvancedTests().pixels(context)
        var red=0,green=0
        for i in stride(from:0,to:pixels.count,by:4) {let r=Int(pixels[i]),g=Int(pixels[i+1]);if r>100 && r>g+30 {red+=1};if g>100 && g>r+30 {green+=1}}
        XCTAssertGreaterThan(red,100);XCTAssertGreaterThan(green,100)
    }
}
