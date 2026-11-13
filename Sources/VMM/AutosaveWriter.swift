import Foundation

struct RecoveryRecord:Codable {
    var identity:String
    var name:String
    var savedPath:String?
    var date:Date
    var missingFiles:Int
}
struct RecoveryEntry:Identifiable {
    let url:URL
    let record:RecoveryRecord
    var id:String {url.path}
}
enum AutosaveWriter {
    private static let lock=NSLock()
    /// Rotation is scoped to one document. Legacy backups without metadata are retained.
    static func write(_ project:Project,media:URL,folder:URL,keep:Int,identity:String?=nil,savedPath:String?=nil)throws->URL {
        lock.lock();defer{lock.unlock()}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let key=identity ?? project.tracks.first?.id.uuidString ?? project.name
        let name="Autosave-\(Int(Date().timeIntervalSince1970))-\(UUID()).vmm",target=folder.appendingPathComponent(name)
        try ProjectPackage.write(project,media:media,to:target,allowMissing:true)
        let missing=Set(project.assets.flatMap(\.files)).filter{!FileManager.default.fileExists(atPath:target.appendingPathComponent("Media").appendingPathComponent($0).path)}.count
        let record=RecoveryRecord(identity:key,name:project.name,savedPath:savedPath,date:Date(),missingFiles:missing)
        do {try JSONEncoder().encode(record).write(to:target.appendingPathComponent("recovery.json"),options:.atomic)}
        catch {try? FileManager.default.removeItem(at:target);throw error}
        let previous=try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("Autosave-") && $0.pathExtension=="vmm"}.compactMap{url -> RecoveryEntry? in
            guard let record=metadata(url),record.identity==key else{return nil}
            return RecoveryEntry(url:url,record:record)
        }.sorted{$0.record.date>$1.record.date}
        for old in previous.dropFirst(max(1,keep)) {try? FileManager.default.removeItem(at:old.url)}
        return target
    }
    static func metadata(_ url:URL)->RecoveryRecord? {
        guard let reader=try? PackageMediaReader(url),let data=try? reader.metadata("recovery.json") else{return nil}
        return try? JSONDecoder().decode(RecoveryRecord.self,from:data)
    }
    static func entries(in folder:URL)->[RecoveryEntry] {
        ((try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.contentModificationDateKey])) ?? []).filter{$0.pathExtension=="vmm"}.compactMap{url in
            if let record=metadata(url){return RecoveryEntry(url:url,record:record)}
            guard let reader=try? PackageMediaReader(url),let data=try? reader.projectData(),let project=try? JSONDecoder().decode(Project.self,from:data) else{return nil}
            guard let missing=try? Set(project.assets.flatMap(\.files)).reduce(0, {try $0 + (reader.mediaSize($1)==nil ? 1:0)}) else{return nil}
            return RecoveryEntry(url:url,record:RecoveryRecord(identity:url.path,name:project.name,savedPath:nil,date:(try? url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast,missingFiles:missing))
        }.sorted{a,b in a.record.name==b.record.name ? a.record.date>b.record.date:a.record.name.localizedStandardCompare(b.record.name) == .orderedAscending}
    }
}
