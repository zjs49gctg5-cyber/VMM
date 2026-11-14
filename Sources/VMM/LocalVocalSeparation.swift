import Foundation

/// Keeps the separated stem in a private temporary directory until its caller finishes.
enum LocalVocalSeparation {
    static let pythonKey="lyricAlignmentPython",modelsKey="lyricAlignmentModels"
    static func withVocals<T>(source:URL,clip:Clip,python:String,models:String,operation:(URL,Clip) async throws->T) async throws->T {
        guard !python.isEmpty,FileManager.default.isExecutableFile(atPath:python),!models.isEmpty else{throw VMMError.message("歌声分離用のPythonとモデルフォルダを指定してください。")}
        let fallback=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("scripts/separate_vocals.py")
        let bundled=Bundle.main.resourceURL?.appendingPathComponent("separate_vocals.py")
        let script=(bundled.map{FileManager.default.fileExists(atPath:$0.path)} ?? false) ? bundled!:fallback
        guard FileManager.default.fileExists(atPath:script.path) else{throw VMMError.message("歌声分離スクリプトが見つかりません。")}
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-vocals-\(UUID())",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:folder)}
        let audio=folder.appendingPathComponent("source.m4a"),output=folder.appendingPathComponent("vocals.wav"),log=folder.appendingPathComponent("worker.log")
        try await LocalTranscription.audioRange(source:source,clip:clip,destination:audio,maximumSeconds:LyricAlignment.maximumSeconds)
        try Task.checkCancellation()
        _=FileManager.default.createFile(atPath:log.path,contents:nil)
        let errorFile=try FileHandle(forWritingTo:log);defer{try? errorFile.close()}
        let process=Process();process.executableURL=URL(fileURLWithPath:python)
        process.arguments=[script.path,"--audio",audio.path,"--models",models,"--output",output.path]
        var env=ProcessInfo.processInfo.environment;env["PATH"]="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin";env["HF_HUB_OFFLINE"]="1";env["PYTHONUNBUFFERED"]="1";process.environment=env
        process.standardOutput=FileHandle.nullDevice;process.standardError=errorFile
        try process.run()
        do {while process.isRunning {try await Task.sleep(nanoseconds:250_000_000)};try Task.checkCancellation()}
        catch {if process.isRunning {process.terminate();process.waitUntilExit()};throw error}
        process.waitUntilExit();try errorFile.synchronize()
        guard process.terminationStatus==0,FileManager.default.fileExists(atPath:output.path) else {
            let data=(try? Data(contentsOf:log)) ?? Data(),message=String(decoding:data.suffix(4096),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
            throw VMMError.message(message.isEmpty ? "歌声の分離に失敗しました。":String(message.suffix(1200)))
        }
        var relative=clip;relative.sourceOffset=0
        return try await operation(output,relative)
    }
    static func align(source:URL,clip:Clip,text:String,language:String,fps:Int,python:String,models:String,recognizer:(URL,Clip,String,[String]) async throws->[TranscriptToken]) async throws->[LyricAlignmentMatch] {
        _=try LyricAlignment.suggest(text:text,tokens:[],clip:clip,fps:fps)
        return try await withVocals(source:source,clip:clip,python:python,models:models) {url,relative in
            try await LyricAlignment.recognize(text:text,source:url,clip:relative,language:language,fps:fps,using:recognizer)
        }
    }
}
