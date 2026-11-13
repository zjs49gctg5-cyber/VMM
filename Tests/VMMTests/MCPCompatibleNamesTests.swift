import XCTest
import Foundation
@testable import VMM

final class MCPCompatibleNamesTests: XCTestCase {
    @MainActor func testPreviousBridgeOptionPreservesEditing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vmm-mcp-alias-\(UUID())")
        let store = EditorStore(preferencesDirectory: root)
        let mcp = VMMControlMCP(connectionURL: root.appendingPathComponent("connection.json"))
        store.autoSpeech = false; store.project = Project()
        defer { mcp.stop(); try? FileManager.default.removeItem(at: store.directory); try? FileManager.default.removeItem(at: root) }
        let helper = try MCPTests().helperPath()
        mcp.start(store: store); XCTAssertTrue(mcp.running, mcp.status)
        let script = #"""
import json, subprocess, sys
p = subprocess.Popen([sys.argv[1], '--connection', sys.argv[2], '--compatible-tool-names'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def request(method, params=None, ident=1):
    d = {'jsonrpc':'2.0','method':method,'params':params or {}}
    if ident is not None: d['id'] = ident
    p.stdin.write(json.dumps(d)+'\n'); p.stdin.flush()
    return json.loads(p.stdout.readline()) if ident is not None else None
request('initialize', {'protocolVersion':'2025-03-26','capabilities':{},'clientInfo':{'name':'test','version':'1'}})
request('notifications/initialized', ident=None)
tools = request('tools/list')['result']['tools']
names = [t['name'] for t in tools]
assert 'vmm_state' in names and 'vmm_clip_add' in names and len(names)==len(set(names))
assert all('.' not in n for n in names)
state = request('tools/call', {'name':'vmm_state','arguments':{}})
assert not state['result']['isError']
added = request('tools/call', {'name':'vmm_clip_add','arguments':{'kind':'text','properties':{'text':'Alias test','duration':3}}})
assert not added['result']['isError']
p.stdin.close(); p.wait(timeout=5)
assert p.returncode == 0
"""#
        let connection = mcp.connectionURL.path
        let result: (Int32, String) = try await Task.detached {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", script, helper.path, connection]
            let output = Pipe(); process.standardOutput = output; process.standardError = output
            try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
        XCTAssertEqual(result.0, 0, result.1)
        XCTAssertEqual(store.project.clips.first?.text, "Alias test")
    }
}
