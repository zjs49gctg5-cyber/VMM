import XCTest
import Foundation
import AppKit
import AVFoundation
import MCPTransport
import Darwin
@testable import VMM

final class MCPTests:XCTestCase {
    @MainActor func send(_ session:MCPSession,_ commands:EditorCommands,_ method:String,_ params:[String:Any]=[:],id:Int?=1)throws->[String:Any]? {
        var request:[String:Any]=["jsonrpc":"2.0","method":method,"params":params]
        if let id{request["id"]=id}
        return try session.respond(JSONSerialization.data(withJSONObject:request),commands:commands).map{try XCTUnwrap(JSONSerialization.jsonObject(with:$0) as? [String:Any])}
    }
    @MainActor func initialize(_ session:MCPSession,_ commands:EditorCommands)throws {
        let response=try send(session,commands,"initialize",["protocolVersion":"2025-11-25","capabilities":[:],"clientInfo":["name":"test","version":"1"]])
        XCTAssertEqual((response?["result"] as? [String:Any])?["protocolVersion"] as? String,"2025-11-25")
        let server=(response?["result"] as? [String:Any])?["serverInfo"] as? [String:Any]
        XCTAssertEqual(server?["version"] as? String,AppVersion.current.protocolVersion)
        XCTAssertNil(try send(session,commands,"notifications/initialized",id:nil))
    }
    @MainActor func testLifecycleSchemasValidationMutationAndUndo()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-mcp-core-\(UUID())"),store=EditorStore(preferencesDirectory:root),commands=EditorCommands()
        commands.store=store;store.autoSpeech=false;store.project=Project()
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let session=MCPSession()
        XCTAssertNotNil(try send(session,commands,"tools/list")?["error"])
        try initialize(session,commands)
        XCTAssertEqual(Set(MCPTools.names),Set(MCPTools.fields.keys))
        XCTAssertEqual(Set(MCPTools.names).count,MCPTools.names.count)
        let listing=try send(session,commands,"tools/list",["_meta":["client":"metadata compatibility"]])?["result"] as? [String:Any]
        XCTAssertEqual((listing?["tools"] as? [[String:Any]])?.count,MCPTools.names.count)
        let publicNames=try XCTUnwrap(listing?["tools"] as? [[String:Any]]).compactMap{$0["name"] as? String}
        XCTAssertEqual(Set(publicNames).count,MCPTools.names.count,"Public names must not collide")
        XCTAssertTrue(publicNames.contains("vmm_state"));XCTAssertTrue(publicNames.contains("vmm_clip_add"))
        XCTAssertTrue(publicNames.allSatisfy{!$0.contains(".")})
        XCTAssertEqual(((try send(session,commands,"tools/call",["name":"vmm_state"]))?["result"] as? [String:Any])?["isError"] as? Bool,false)
        XCTAssertEqual(((try send(session,commands,"tools/call",["name":"vmm.state"]))?["result"] as? [String:Any])?["isError"] as? Bool,false,"Previously published names remain callable")
        let invalid=try send(session,commands,"tools/call",["name":"vmm.clip.add","arguments":["kind":"text","track":true]])
        XCTAssertNotNil(invalid?["error"]);XCTAssertTrue(store.project.clips.isEmpty)
        let added=try send(session,commands,"tools/call",["name":"vmm.clip.add","arguments":["kind":"text","properties":["text":"MCP subtitle","duration":0.3]]])
        XCTAssertEqual((added?["result"] as? [String:Any])?["isError"] as? Bool,false)
        XCTAssertEqual(store.project.clips.first?.text,"MCP subtitle")
        _=try send(session,commands,"tools/call",["name":"vmm.undo"]);XCTAssertTrue(store.project.clips.isEmpty)
        XCTAssertNotNil(try send(session,commands,"tools/call",["name":"vmm.caption.export","arguments":[:]])?["error"])
        XCTAssertNotNil(try send(session,commands,"unknown")?["error"])
        XCTAssertNotNil(MCPSession().respond(Data("bad json".utf8),commands:commands))
        let other=MCPSession();XCTAssertNotNil(try send(other,commands,"tools/list")?["error"],"Initialization is per connection")
        let before=store.project
        XCTAssertNil(try send(session,commands,"tools/call",["name":"vmm.clip.add","arguments":["kind":"text"]],id:nil))
        XCTAssertEqual(store.project,before,"Notifications cannot execute editor tools")
    }
    @MainActor func testPrivateConnectionAuthenticationStopAndStdioClient()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-mcp-ipc-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let store=EditorStore(preferencesDirectory:root),mcp=VMMControlMCP(connectionURL:root.appendingPathComponent("connection.json"))
        store.autoSpeech=false;store.project=Project()
        defer{mcp.stop();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        XCTAssertFalse(mcp.running);XCTAssertFalse(FileManager.default.fileExists(atPath:mcp.connectionURL.path))
        mcp.start(store:store);XCTAssertTrue(mcp.running,mcp.status)
        let descriptor=try MCPConnectionDescriptor.load(mcp.connectionURL)
        XCTAssertFalse(mcp.clientConfiguration().contains(descriptor.token))
        let socket=descriptor.socket
        let rejected=try await Task.detached{()throws->Bool in
            let fd=try LocalSocket.connect(socket);defer{Darwin.close(fd)}
            let lines=SocketLines(fd);try lines.write(Data("{\"token\":\"wrong\"}".utf8))
            return try lines.read()==nil
        }.value
        XCTAssertTrue(rejected);XCTAssertTrue(store.project.clips.isEmpty)
        let script=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("skills/vmm-control/scripts/vmm.py")
        let helper=try helperPath()
        let text=root.appendingPathComponent("script.txt");try "A：MCPからのセリフ".write(to:text,atomically:true,encoding:.utf8)
        let connection=mcp.connectionURL.path
        let data=try await Task.detached{()throws->Data in
            let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
            process.arguments=[script.path,"--helper",helper.path,"--connection",connection,"script",text.path]
            let out=Pipe(),err=Pipe();process.standardOutput=out;process.standardError=err
            try process.run();let result=out.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus,0,String(data:err.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? "")
            return result
        }.value
        XCTAssertEqual((try JSONSerialization.jsonObject(with:data) as? [String:Any])?["ok"] as? Bool,true)
        XCTAssertEqual(store.project.clips.first?.text,"MCPからのセリフ")
        let activeFD=try await Task.detached{()throws->Int32 in
            let fd=try LocalSocket.connect(socket),lines=SocketLines(fd)
            try lines.write(JSONSerialization.data(withJSONObject:["token":descriptor.token]))
            XCTAssertNotNil(try lines.read());return fd
        }.value
        defer{Darwin.close(activeFD)}
        mcp.stop();XCTAssertFalse(mcp.running)
        let closed=try await Task.detached{try SocketLines(activeFD).read()==nil}.value
        XCTAssertTrue(closed,"Stopping MCP must also close an authenticated existing connection")
        XCTAssertFalse(FileManager.default.fileExists(atPath:connection));XCTAssertFalse(FileManager.default.fileExists(atPath:socket))
        XCTAssertThrowsError(try LocalSocket.connect(socket))
    }
    func helperPath()throws->URL {
        // SwiftPM's executable products are siblings of the XCTest bundle.
        let bundle=Bundle(for:Self.self).bundleURL
        let candidates=[bundle.deletingLastPathComponent().appendingPathComponent("VMMMCPBridge"),URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/VMMMCPBridge")]
        return try XCTUnwrap(candidates.first{FileManager.default.isExecutableFile(atPath:$0.path)},"Build VMMMCPBridge before integration tests")
    }
    @MainActor func testMCPMediaJobSaveRenderAndExport()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-mcp-production-\(UUID())"),store=EditorStore(preferencesDirectory:root),commands=EditorCommands(),session=MCPSession()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        store.autoSpeech=false;store.project=Project();store.project.width=320;store.project.height=180;commands.store=store
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        try initialize(session,commands)
        func call(_ name:String,_ args:[String:Any])throws->[String:Any] {
            let result=try XCTUnwrap(try send(session,commands,"tools/call",["name":"vmm."+name,"arguments":args])?["result"] as? [String:Any])
            XCTAssertEqual(result["isError"] as? Bool,false,String(describing:result))
            return try XCTUnwrap(result["structuredContent"] as? [String:Any])
        }
        let bitmap=try XCTUnwrap(RasterTools.bitmap(CGSize(width:32,height:32)));bitmap.setFillColor(NSColor.green.cgColor);bitmap.fill(CGRect(x:0,y:0,width:32,height:32))
        let image=root.appendingPathComponent("image.png")
        try XCTUnwrap(NSBitmapImageRep(cgImage:try XCTUnwrap(bitmap.makeImage())).representation(using:.png,properties:[:])).write(to:image)
        let media=try call("media.import",["paths":[image.path]]),job=try XCTUnwrap(media["jobID"] as? String)
        for _ in 0..<200 where commands.jobs[job]?["state"] as? String=="running"{try await Task.sleep(nanoseconds:10_000_000)}
        let complete=try call("job",["jobID":job]);XCTAssertEqual(complete["state"] as? String,"completed")
        let asset=try XCTUnwrap(store.project.assets.first)
        _=try call("clip.add",["kind":"image","properties":["assetID":asset.id.uuidString,"duration":0.3]])
        let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)))
        FrameRenderer().draw(project:store.project,directory:store.directory,time:0,context:context,size:CGSize(width:320,height:180))
        let preview=NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage()))
        XCTAssertGreaterThan(try XCTUnwrap(preview.colorAt(x:160,y:90)?.usingColorSpace(.sRGB)).greenComponent,0.8)
        let save=try call("project.save",["path":root.appendingPathComponent("test.vmm").path,"async":true]),saveID=try XCTUnwrap(save["jobID"] as? String)
        for _ in 0..<200 where commands.jobs[saveID]?["state"] as? String=="running"{try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(commands.jobs[saveID]?["state"] as? String,"completed")
        let movie=root.appendingPathComponent("movie.mp4"),export=try call("export.start",["path":movie.path]),exportID=try XCTUnwrap(export["jobID"] as? String)
        for _ in 0..<500 where commands.jobs[exportID]?["state"] as? String=="running"{try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(commands.jobs[exportID]?["state"] as? String,"completed",String(describing:commands.jobs[exportID]))
        XCTAssertTrue(FileManager.default.fileExists(atPath:movie.path))
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:movie))
        let frame=NSBitmapImageRep(cgImage:try generator.copyCGImage(at:.zero,actualTime:nil))
        XCTAssertGreaterThan(try XCTUnwrap(frame.colorAt(x:160,y:90)?.usingColorSpace(.sRGB)).greenComponent,0.7)
    }
    @MainActor func testExportProtectsFileCreatedAfterMCPCall()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-mcp-export-race-\(UUID())"),store=EditorStore(preferencesDirectory:root),commands=EditorCommands(),session=MCPSession()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        store.autoSpeech=false;store.project=Project();store.project.width=320;store.project.height=180
        store.project.clips=[Clip(kind:.shape,name:"test",track:0,start:0,duration:1)];commands.store=store
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        try initialize(session,commands)
        let movie=root.appendingPathComponent("output.mp4")
        let response=try send(session,commands,"tools/call",["name":"vmm.export.start","arguments":["path":movie.path]])
        let value=try XCTUnwrap((response?["result"] as? [String:Any])?["structuredContent"] as? [String:Any]),id=try XCTUnwrap(value["jobID"] as? String)
        let marker=Data("existing file".utf8);try marker.write(to:movie)
        for _ in 0..<500 where commands.jobs[id]?["state"] as? String=="running"{try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(commands.jobs[id]?["state"] as? String,"failed")
        XCTAssertEqual(try Data(contentsOf:movie),marker)
    }
    func testCredentialFileRequiresPrivatePermissions()throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-mcp-auth-\(UUID()).json")
        defer{try? FileManager.default.removeItem(at:url)}
        try JSONEncoder().encode(MCPConnectionDescriptor(socket:"/private/tmp/example",token:String(repeating:"x",count:64))).write(to:url)
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:url.path)
        XCTAssertThrowsError(try MCPConnectionDescriptor.load(url))
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        XCTAssertEqual(try MCPConnectionDescriptor.load(url).socket,"/private/tmp/example")
    }
}
