import XCTest
import Foundation
import AVFoundation
@testable import VMM

final class TimelineInterchangeTests:XCTestCase {
    func testXMLCutContinuityEscapingURLsMarkersAndOptionalDTD()throws {
        var p=Project();p.name="字幕 & <example> \"日本語\"";p.clips=[Clip(kind:.text,name:"A & B",track:0,start:0,duration:1),Clip(kind:.text,name:"two",track:1,start:1,duration:1.5)]
        p.markers=[TimelineMarker(time:0.5,name:"cue & <台詞>")]
        let movie=URL(fileURLWithPath:"/tmp/日本語 テスト/master.mov")
        let f=TimelineInterchange.fcpxml(project:p,movie:movie,start:0,frames:75,width:1920,height:1080,fps:30,hasAudio:true)
        let doc=try XMLDocument(xmlString:f,options:[])
        XCTAssertEqual(try doc.nodes(forXPath:"//project").first?.attributeValue("name"),p.name)
        let clips=try doc.nodes(forXPath:"//spine/asset-clip");XCTAssertEqual(clips.count,3)
        XCTAssertEqual(clips.map{$0.attributeValue("duration")},["15/30s","15/30s","45/30s"])
        XCTAssertEqual(try doc.nodes(forXPath:"//media-rep").first?.attributeValue("src"),movie.absoluteString)
        XCTAssertEqual(try doc.nodes(forXPath:"//marker").first?.attributeValue("value"),p.markers?.first?.name)
        if let path=ProcessInfo.processInfo.environment["VMM_FCPXML_DTD"] {
            let dtd=try XMLDTD(contentsOf:URL(fileURLWithPath:path),options:[]);dtd.name="fcpxml";doc.dtd=dtd;try doc.validate()
        }
        let legacy=try XMLDocument(xmlString:TimelineInterchange.premiereXML(project:p,movie:movie,start:0,frames:75,width:1920,height:1080,fps:30,hasAudio:true),options:[])
        XCTAssertEqual(try legacy.nodes(forXPath:"//video/track/clipitem").count,3)
        XCTAssertEqual(try legacy.nodes(forXPath:"//audio/track/clipitem").count,6)
        XCTAssertEqual(try legacy.nodes(forXPath:"//sequence/name").first?.stringValue,p.name)
    }
    func testHandoffWritesCompletePackageAndNeverOverwrites()async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-handoff-test-\(UUID())");defer{try? FileManager.default.removeItem(at:folder)}
        var p=try AudioDeliveryTests().fixture(folder);p.clips[1].duration=0.6
        var settings=UserSettings();settings.rangeEnd=0.6
        let output=folder.appendingPathComponent("handoff")
        try await TimelineInterchange.export(project:p,directory:folder,destination:output,options:settings){_ in}
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath:output.path)),["master.mov","audio.wav","timeline.fcpxml","timeline-premiere.xml","README.txt","vmm-edit-reference.json"])
        let doc=try XMLDocument(contentsOf:output.appendingPathComponent("timeline.fcpxml"),options:[])
        XCTAssertEqual(try doc.nodes(forXPath:"//media-rep").first?.attributeValue("src"),output.appendingPathComponent("master.mov").absoluteString)
        do{try await TimelineInterchange.export(project:p,directory:folder,destination:output,options:settings){_ in};XCTFail("existing folder must reject")}catch{}
        XCTAssertTrue(FileManager.default.fileExists(atPath:output.appendingPathComponent("master.mov").path))
    }
}
private extension XMLNode {
    func attributeValue(_ name:String)->String? {(self as? XMLElement)?.attribute(forName:name)?.stringValue}
}
