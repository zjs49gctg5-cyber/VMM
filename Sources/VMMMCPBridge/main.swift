import Foundation
import Darwin
import MCPTransport

// stdout is exclusively MCP JSON-RPC. No token or socket traffic is exposed to the client.
do {
    let args=CommandLine.arguments
    guard (args.count==3 || (args.count==4 && args[3]=="--compatible-tool-names")),args[1]=="--connection" else{throw LocalTransportError.message("Usage: VMMMCPBridge --connection /absolute/path/to/mcp-connection.json [--compatible-tool-names]")}
    let descriptor=try MCPConnectionDescriptor.load(URL(fileURLWithPath:args[2]))
    let fd=try LocalSocket.connect(descriptor.socket);defer{Darwin.close(fd)}
    let socket=SocketLines(fd)
    try socket.write(JSONSerialization.data(withJSONObject:["token":descriptor.token]))
    guard let auth=try socket.read(limit:8192),let value=try JSONSerialization.jsonObject(with:auth) as? [String:Any],value["authenticated"] as? Bool==true else{throw LocalTransportError.message("VMM MCP authentication failed")}
    var buffer=Data()
    func forward(_ line:Data)throws {
        try socket.write(line)
        guard let reply=try socket.read(limit:33_554_432),let wrapper=try JSONSerialization.jsonObject(with:reply) as? [String:Any] else{throw LocalTransportError.message("VMM MCP disconnected")}
        if let message=wrapper["message"] as? String {try FileHandle.standardOutput.write(contentsOf:Data((message+"\n").utf8))}
    }
    while true {
        var bytes=[UInt8](repeating:0,count:8192)
        let count=Darwin.read(STDIN_FILENO,&bytes,bytes.count)
        if count==0{break}
        if count<0{if errno==EINTR{continue};throw LocalSocket.error()}
        buffer.append(contentsOf:bytes.prefix(count))
        while let end=buffer.firstIndex(of:10) {
            guard end<=1_048_576 else{throw LocalTransportError.message("MCP request exceeds size limit")}
            let line=Data(buffer[..<end]);buffer.removeSubrange(...end)
            if !line.isEmpty{try forward(line)}
        }
        guard buffer.count<=1_048_576 else{throw LocalTransportError.message("MCP request exceeds size limit")}
    }
    guard buffer.isEmpty else{throw LocalTransportError.message("Incomplete MCP request")}
} catch {
    try? FileHandle.standardError.write(contentsOf:Data("VMM MCP connection failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
