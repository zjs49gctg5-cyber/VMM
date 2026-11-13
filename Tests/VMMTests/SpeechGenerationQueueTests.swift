import XCTest
@testable import VMM

private actor QueueProbe {
    var active:[String:Int]=[:]
    var peak=0
    var keyPeak=0
    var started:[Int]=[]
    func start(_ id:Int,key:String) {active[key,default:0]+=1;started.append(id);peak=max(peak,active.values.reduce(0,+));keyPeak=max(keyPeak,active[key]!)}
    func end(_ key:String){active[key,default:0]-=1}
    func values()->(Int,Int,[Int]) {(peak,keyPeak,started)}
}
final class SpeechGenerationQueueTests:XCTestCase {
    func testSerialPerEndpointGlobalBoundAndQueuedCancellation()async throws {
        let queue=SpeechGenerationQueue(),probe=QueueProbe()
        let first=Task{try await queue.run(key:"A") {await probe.start(0,key:"A");try await Task.sleep(nanoseconds:150_000_000);await probe.end("A")}}
        while !(await probe.values().2.contains(0)) {await Task.yield()}
        let cancelled=Task{try await queue.run(key:"A"){await probe.start(999,key:"A");await probe.end("A")}}
        await Task.yield();cancelled.cancel()
        var jobs:[Task<Void,Error>]=[]
        for i in 1...12 {let key=i % 2 == 0 ? "A":"B";jobs.append(Task{try await queue.run(key:key){await probe.start(i,key:key);try await Task.sleep(nanoseconds:10_000_000);await probe.end(key)}})}
        try await first.value;for job in jobs {try await job.value}
        do {try await cancelled.value;XCTFail("Cancelled waiter must throw")}catch is CancellationError{}catch{XCTFail("\(error)")}
        let (peak,keyPeak,started)=await probe.values()
        XCTAssertEqual(peak,2);XCTAssertEqual(keyPeak,1);XCTAssertEqual(started.count,13);XCTAssertFalse(started.contains(999))
    }
    func testActiveFailureAndCancellationReleasePermit()async throws {
        let queue=SpeechGenerationQueue()
        let task=Task{try await queue.run(key:"A"){try await Task.sleep(nanoseconds:10_000_000_000)}}
        try await Task.sleep(nanoseconds:20_000_000);task.cancel()
        do {try await task.value;XCTFail()}catch{}
        do {let _:Int=try await queue.run(key:"A"){throw VMMError.message("failure")};XCTFail()}catch{}
        let result=try await queue.run(key:"A"){42};XCTAssertEqual(result,42)
    }
    func testLoopbackAliasesShareServerPermit() {
        var a=SpeechConfiguration(),b=a;b.endpoint="http://localhost:50021/"
        XCTAssertEqual(SpeechGenerationQueue.key(a),SpeechGenerationQueue.key(b))
        a.endpoint="http://127.0.0.1:10101";XCTAssertNotEqual(SpeechGenerationQueue.key(a),SpeechGenerationQueue.key(b))
    }
}
