import XCTest
@testable import VMM

final class ValidationScalingTests:XCTestCase {
    func testReferencedAssetValidationRejectsMissingAndWrongKind() throws {
        var project=Project()
        let image=MediaAsset(name:"image",file:"image.png",kind:.image,duration:1)
        let audio=MediaAsset(name:"audio",file:"audio.wav",kind:.audio,duration:1)
        project.assets=[image,audio]
        var clip=Clip(kind:.image,name:"image",track:0,start:0,duration:1)
        clip.assetID=image.id;clip.mouthAssetID=image.id;project.clips=[clip]
        XCTAssertNoThrow(try project.validated())
        project.clips[0].assetID=UUID();XCTAssertThrowsError(try project.validated())
        project.clips[0].assetID=image.id;project.clips[0].mouthAssetID=audio.id
        XCTAssertThrowsError(try project.validated())
    }

    func testIndexedAdvancedValidationMatchesUnindexedForParentsAndMasks() throws {
        var project=Project()
        let image=MediaAsset(name:"image",file:"image.png",kind:.image,duration:1)
        let audio=MediaAsset(name:"audio",file:"audio.wav",kind:.audio,duration:1)
        project.assets=[image,audio]
        let parent=Clip(kind:.group,name:"parent",track:0,start:0,duration:1)
        var child=Clip(kind:.image,name:"child",track:1,start:0,duration:1)
        child.parentID=parent.id;child.assetID=image.id
        var mask=ClipMask();mask.assetID=image.id;child.masks=[mask]
        project.clips=[parent,child]
        func compare(_ candidate:Clip,_ project:Project) {
            let index=ProjectValidationIndex(project:project)
            let slow=Result{try candidate.validateAdvanced(project:project)}
            let fast=Result{try candidate.validateAdvanced(project:project,index:index)}
            switch (slow,fast) {
            case (.success,.success):break
            case (.failure(let a),.failure(let b)):XCTAssertEqual(a.localizedDescription,b.localizedDescription)
            default:XCTFail("Indexed validation disagrees with the original validation")
            }
        }
        compare(child,project)
        child.parentID=UUID();compare(child,project)
        child.parentID=parent.id;child.masks?[0].assetID=audio.id;compare(child,project)
        child.masks?[0].assetID=UUID();compare(child,project)
        project.clips[0].parentID=child.id;child.masks?[0].assetID=image.id;compare(child,project)
    }

    func testLargeProjectValidationBenchmark() throws {
        guard ProcessInfo.processInfo.environment["VMM_VALIDATION_BENCHMARK"] == "1" else {throw XCTSkip("Opt-in validation benchmark")}
        var project=Project()
        project.assets=(0..<2048).map{MediaAsset(name:"image\($0)",file:"image\($0).png",kind:.image,duration:1)}
        project.clips=(0..<8192).map { i in
            var clip=Clip(kind:.image,name:"clip\(i)",track:0,start:Double(i)/10,duration:0.1)
            clip.assetID=project.assets[(i*53)%project.assets.count].id
            return clip
        }
        var samples:[Double]=[]
        for _ in 0..<6 {
            let start=ProcessInfo.processInfo.systemUptime
            _=try project.validated()
            samples.append((ProcessInfo.processInfo.systemUptime-start)*1000)
        }
        let warm=samples.dropFirst().sorted()
        print("VALIDATION_SCALING clips=8192 assets=2048 median_ms=\(warm[warm.count/2]) samples_ms=\(warm)")
    }
}
