import XCTest
@testable import VMM

final class UITimelineTests:XCTestCase {
    @MainActor func testVerticalZoomKeepsClipTimesAndSeparatesTracks() {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-layer-zoom-\(UUID())")
        let store=EditorStore(preferencesDirectory:root),canvas=TimelineNSView();canvas.store=store
        defer{try? FileManager.default.removeItem(at:store.directory)}
        let clip=Clip(kind:.text,name:"clip",track:0,start:3,duration:5)
        var next=clip;next.track=1
        let baseline=canvas.rect(clip),header=canvas.header,ruler=canvas.ruler
        for zoom in [0.65,1,2,3] {
            store.layerZoom=zoom
            let rect=canvas.rect(clip),nextRect=canvas.rect(next)
            XCTAssertEqual(rect.minX,baseline.minX);XCTAssertEqual(rect.width,baseline.width)
            XCTAssertEqual(canvas.header,header);XCTAssertEqual(canvas.ruler,ruler)
            XCTAssertEqual(nextRect.minY-rect.minY,canvas.row,accuracy:0.001)
            XCTAssertLessThan(rect.maxY,nextRect.minY)
            XCTAssertEqual(rect.height,canvas.row-10,accuracy:0.001)
        }
    }
    func testRulerFitsLabelsAtEveryZoomAndFontSize() {
        for fps in [24,30,60] {for text in [12.0,18,24,36] {for zoom in [4.0,8,20,72,180,600,1200] {
            let ruler=TimelineRuler(zoom:zoom,fps:fps,textSize:text)
            XCTAssertGreaterThanOrEqual(Double(ruler.majorFrames)*zoom/Double(fps),110*text/12)
            XCTAssertEqual(ruler.majorFrames % ruler.minorFrames,0)
            let ticks=ruler.ticks(from:12.34,to:35.67)
            XCTAssertEqual(ticks,Array(Set(ticks)).sorted());XCTAssertTrue(ticks.allSatisfy{$0>=0})
            XCTAssertLessThan(ticks.count,4000)
        }}}
        let wide=TimelineRuler(zoom:4,fps:30,textSize:12),close=TimelineRuler(zoom:1200,fps:30,textSize:12)
        XCTAssertGreaterThanOrEqual(wide.majorFrames,30*15)
        XCTAssertLessThan(close.majorFrames,30)
        XCTAssertEqual(close.label(frame:1833),"00:01:01:03")
        XCTAssertEqual(wide.label(frame:108000),"01:00:00")
    }
    @MainActor func testAppearanceSettingsCompatibilityPersistenceAndValidation()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-ui-settings-\(UUID())")
        let store=EditorStore(preferencesDirectory:root),api=EditorCommands();api.store=store
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let legacy=try JSONDecoder().decode(UserSettings.self,from:JSONEncoder().encode(UserSettings()))
        XCTAssertNil(legacy.uiFontSize);XCTAssertNil(legacy.uiIconSize);XCTAssertEqual(legacy.textPoints,12);XCTAssertEqual(legacy.iconPoints,12)
        XCTAssertNil(legacy.uiTheme);XCTAssertNil(UITheme.system.appearance)
        XCTAssertEqual(UITheme.light.appearance?.name,.aqua);XCTAssertEqual(UITheme.dark.appearance?.name,.darkAqua)
        XCTAssertEqual(try CommandTests().command(api,["command":"settings.update","properties":["uiTheme":"light"]]).status,200)
        XCTAssertEqual(try JSONDecoder().decode(UserSettings.self,from:Data(contentsOf:root.appendingPathComponent("settings.json"))).uiTheme,.light)
        XCTAssertEqual(try CommandTests().command(api,["command":"settings.update","properties":["uiTheme":"invalid"]]).status,400)
        XCTAssertEqual(store.settings.uiTheme,.light)
        var custom=UserSettings();custom.exportWidth=1000;custom.exportHeight=600
        XCTAssertTrue(ExportWorkspace.outputSizeChoices(custom).contains("1000x600"))
        custom.exportWidth=720;custom.exportHeight=1280
        XCTAssertEqual(ExportWorkspace.outputSizeChoices(custom).filter{$0=="720x1280"}.count,1)
        XCTAssertEqual(try CommandTests().command(api,["command":"settings.update","properties":["uiFontSize":18,"uiIconSize":20]]).status,200)
        let saved=try JSONDecoder().decode(UserSettings.self,from:Data(contentsOf:root.appendingPathComponent("settings.json")))
        XCTAssertEqual(saved.uiFontSize,18);XCTAssertEqual(saved.uiIconSize,20)
        let canvas=TimelineNSView();canvas.store=store
        store.zoom=4
        let first=Clip(kind:.text,name:"first",track:0,start:0,duration:4)
        let next=Clip(kind:.text,name:"next",track:0,start:4,duration:4)
        XCTAssertEqual(canvas.rect(first).maxX,canvas.rect(next).minX,accuracy:0.001)
        XCTAssertGreaterThan(canvas.row,47);XCTAssertGreaterThan(canvas.header,160);XCTAssertGreaterThan(canvas.ruler,27)
        XCTAssertEqual(try CommandTests().command(api,["command":"settings.update","properties":["uiFontSize":8]]).status,400)
        XCTAssertEqual(store.settings.uiFontSize,18)
    }
}
