import SwiftUI
import AppKit
import MCPTransport
import Darwin

@MainActor final class VMMControlMCP:ObservableObject {
    @Published private(set) var running=false
    @Published private(set) var status="停止中"
    let commands=EditorCommands()
    let connectionURL:URL
    private var listener:LocalMCPListener?
    private var socketFolder:URL?
    private var generation=UUID()
    init(connectionURL:URL?=nil) {
        self.connectionURL=connectionURL ?? VMMPaths.support.appendingPathComponent("mcp-connection.json")
    }
    var helperURL:URL {
        let bundled=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/VMMMCPBridge")
        if FileManager.default.isExecutableFile(atPath:bundled.path){return bundled}
        return URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("VMMMCPBridge")
    }
    func clientConfiguration()->String {
        let object:[String:Any]=["mcpServers":["vmm":["command":helperURL.path,"args":["--connection",connectionURL.path]]]]
        return String(data:(try? JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])) ?? Data(),encoding:.utf8) ?? ""
    }
    func start(store:EditorStore) {
        guard !running else{return}
        do {
            if let existing=try? MCPConnectionDescriptor.load(connectionURL),FileManager.default.fileExists(atPath:existing.socket) {
                if let fd=try? LocalSocket.connect(existing.socket){Darwin.close(fd);throw VMMError.message("別のVMMでMCP接続が有効です。")}
            }
            let parent=connectionURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let folder=URL(fileURLWithPath:"/private/tmp/vmm-mcp-\(geteuid())-\(UUID())")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            socketFolder=folder
            let endpoint=folder.appendingPathComponent("s"),token=UUID().uuidString+UUID().uuidString,listener=LocalMCPListener(),sessionGeneration=UUID()
            self.generation=sessionGeneration;commands.store=store
            try listener.start(path:endpoint.path,token:token,makeHandler:Self.makeHandler(controller:self,generation:sessionGeneration))
            self.listener=listener
            let data=try JSONEncoder().encode(MCPConnectionDescriptor(socket:endpoint.path,token:token))
            // Atomic installation of a private descriptor; config snippets never include the token.
            let staged=parent.appendingPathComponent(".mcp-\(UUID()).json")
            defer{try? FileManager.default.removeItem(at:staged)}
            guard FileManager.default.createFile(atPath:staged.path,contents:data,attributes:[.posixPermissions:0o600]) else{throw VMMError.message("MCP接続情報を保存できません。")}
            if FileManager.default.fileExists(atPath:connectionURL.path){_=try FileManager.default.replaceItemAt(connectionURL,withItemAt:staged)}else{try FileManager.default.moveItem(at:staged,to:connectionURL)}
            running=true;status=L("MCP接続が有効です（ローカルstdio）")
        } catch {stop();status=L("起動失敗：")+error.localizedDescription}
    }
    nonisolated private static func makeHandler(controller:VMMControlMCP,generation:UUID)->()->(Data)async->Data? {
        return {[weak controller] in let session=MCPSession();return {data in await controller?.respond(session,data:data,generation:generation)}}
    }
    private func respond(_ session:MCPSession,data:Data,generation:UUID)->Data? {
        guard running,self.generation==generation else{return nil}
        return session.respond(data,commands:commands)
    }
    func stop() {
        generation=UUID();listener?.stop();listener=nil;running=false;commands.store=nil;status=L("停止中")
        if let folder=socketFolder {
            if let descriptor=try? MCPConnectionDescriptor.load(connectionURL),descriptor.socket==folder.appendingPathComponent("s").path {try? FileManager.default.removeItem(at:connectionURL)}
            try? FileManager.default.removeItem(at:folder)
        }
        socketFolder=nil
    }
}
struct ControlMCPSettings:View {
    @ObservedObject var mcp:VMMControlMCP
    @ObservedObject var store:EditorStore
    var body:some View {VStack(alignment:.leading,spacing:16){
        Text(L("VMM MCP接続")).vmmFont(size:18,weight:.bold)
        Text(L("MCP対応のAIから、脚本・字幕・素材の編集や動画出力を操作できます。")).foregroundColor(.secondary)
        Toggle(L("MCP接続を有効にする"),isOn:Binding(get:{mcp.running},set:{if $0{mcp.start(store:store)}else{mcp.stop()}}))
        Text(mcp.status).textSelection(.enabled)
        Text(L("起動時は無効です。同じMacのユーザーだけが接続できます。認証情報は非公開の接続ファイルで管理します。")).foregroundColor(.secondary)
        Button(L("MCPクライアント設定をコピー")){NSPasteboard.general.clearContents();NSPasteboard.general.setString(mcp.clientConfiguration(),forType:.string)}
        Text(L("設定のcommandとargsをMCPクライアントへ登録し、VMMを開いた状態で接続してください。")).foregroundColor(.secondary)
        Text(L("MCPを無効にすると接続を閉じます。開始済みの生成・書き出しはアプリ側で継続し、制作画面から中止できます。")).foregroundColor(.secondary)
    }.padding(24).frame(minWidth:520,minHeight:360).vmmAppearance(store.settings)}
}
