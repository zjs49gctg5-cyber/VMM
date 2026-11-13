import XCTest
import AVFoundation
@testable import VMM
final class ExportQueueTests:XCTestCase {
    @MainActor func wait(_ queue:ExportQueue)async throws {
        for _ in 0..<500 {if queue.paused,queue.runningID==nil {return};try await Task.sleep(nanoseconds:20_000_000)}
        XCTFail("Queue did not finish")
    }
    func project(_ color:String)->Project {var p=Project();p.width=320;p.height=180;p.background=color;p.clips=[Clip(kind:.shape,name:"shape",track:0,start:0,duration:0.2)];return p}
    @MainActor func testIndependentSnapshotsActualMoviesAndPersistence()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-queue-\(UUID())");try FileManager.default.createDirectory(at:root.appendingPathComponent("Session/Media"),withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let queue=ExportQueue(root:root.appendingPathComponent("Queue"))
        var p=project("FF0000");p.name="Red"
        let first=try await queue.add(project:p,directory:root.appendingPathComponent("Session"),options:UserSettings(),destination:root.appendingPathComponent("red.mp4"))
        p.background="0000FF";p.name="Blue"
        let second=try await queue.add(project:p,directory:root.appendingPathComponent("Session"),options:UserSettings(),destination:root.appendingPathComponent("blue.mp4"))
        XCTAssertEqual(try JSONDecoder().decode(Project.self,from:Data(contentsOf:queue.snapshot(first).appendingPathComponent("project.json"))).name,"Red")
        try queue.move(second,offset:-1);XCTAssertEqual(queue.jobs.first?.id,second)
        queue.resume();try await wait(queue)
        XCTAssertTrue(queue.jobs.allSatisfy{$0.state == .completed})
        var pixels:[[UInt8]]=[]
        for job in queue.jobs {
            let generator=AVAssetImageGenerator(asset:AVURLAsset(url:job.destination)),image=try generator.copyCGImage(at:.zero,actualTime:nil)
            XCTAssertEqual(image.width,320);let bitmap=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)));bitmap.draw(image,in:CGRect(x:0,y:0,width:320,height:180))
            pixels.append(Array(UnsafeBufferPointer(start:try XCTUnwrap(bitmap.data).assumingMemoryBound(to:UInt8.self),count:bitmap.bytesPerRow*bitmap.height)))
            XCTAssertFalse(FileManager.default.fileExists(atPath:queue.snapshot(job.id).path))
        }
        XCTAssertNotEqual(pixels[0],pixels[1])
        let restored=ExportQueue(root:queue.root);XCTAssertTrue(restored.paused);XCTAssertEqual(restored.jobs.count,2);XCTAssertTrue(restored.jobs.allSatisfy{$0.state == .completed})
    }
    @MainActor func testCompletedSnapshotIsRetainedUntilQueueStateIsSaved()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-queue-save-\(UUID())")
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Session/Media"),withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let queue=ExportQueue(root:root.appendingPathComponent("Queue"))
        let id=try await queue.add(project:project("FFFFFF"),directory:root.appendingPathComponent("Session"),options:UserSettings(),destination:root.appendingPathComponent("out.mp4"))
        let state=queue.root.appendingPathComponent("queue.json")
        try FileManager.default.removeItem(at:state)
        try FileManager.default.createDirectory(at:state,withIntermediateDirectories:true)
        XCTAssertFalse(queue.complete(id))
        XCTAssertTrue(FileManager.default.fileExists(atPath:queue.snapshot(id).path))
        try FileManager.default.removeItem(at:state)
        XCTAssertTrue(queue.complete(id))
        XCTAssertFalse(FileManager.default.fileExists(atPath:queue.snapshot(id).path))
        XCTAssertEqual(ExportQueue(root:queue.root).jobs.first?.state,.completed)
    }
    @MainActor func testDestinationRaceFailsWithoutOverwriteAndRetryAfterRemoval()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-queue-race-\(UUID())");try FileManager.default.createDirectory(at:root.appendingPathComponent("Session/Media"),withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let queue=ExportQueue(root:root.appendingPathComponent("Queue")),destination=root.appendingPathComponent("out.mp4")
        let id=try await queue.add(project:project("FFFFFF"),directory:root.appendingPathComponent("Session"),options:UserSettings(),destination:destination)
        let original=Data("preserve existing file".utf8);try original.write(to:destination)
        queue.resume();try await wait(queue);XCTAssertEqual(queue.jobs.first?.state,.failed);XCTAssertEqual(try Data(contentsOf:destination),original)
        try FileManager.default.removeItem(at:destination);try queue.retry(id);queue.resume();try await wait(queue);XCTAssertEqual(queue.jobs.first?.state,.completed)
    }
    @MainActor func testCancelKeepsSnapshotAndPendingItems()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-queue-cancel-\(UUID())");try FileManager.default.createDirectory(at:root.appendingPathComponent("Session/Media"),withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let queue=ExportQueue(root:root.appendingPathComponent("Queue"));var p=project("FFFFFF");p.width=1920;p.height=1080;p.clips[0].duration=4
        let first=try await queue.add(project:p,directory:root.appendingPathComponent("Session"),options:UserSettings(),destination:root.appendingPathComponent("first.mp4"))
        _=try await queue.add(project:p,directory:root.appendingPathComponent("Session"),options:UserSettings(),destination:root.appendingPathComponent("second.mp4"))
        queue.resume();for _ in 0..<100 where queue.runningID==nil {try await Task.sleep(nanoseconds:5_000_000)}
        XCTAssertEqual(queue.runningID,first);queue.cancelCurrent();try await wait(queue)
        XCTAssertEqual(queue.jobs[0].state,.cancelled);XCTAssertEqual(queue.jobs[1].state,.queued);XCTAssertTrue(FileManager.default.fileExists(atPath:queue.snapshot(first).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:queue.jobs[0].destination.path))
    }
}
