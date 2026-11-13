import Foundation
import AppKit
import UniformTypeIdentifiers
import Darwin

/// File work is independent of the editor actor. Each operation uses its own staging directory.
enum ProjectIO {
    static func preflight(files:[URL],destination:URL,availableCapacity:Int64?=nil)throws {
        let sizes=try files.map{Int64(try $0.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)}
        try preflight(sizes:sizes,destination:destination,availableCapacity:availableCapacity)
    }
    static func preflight(sizes:[Int64],destination:URL,availableCapacity:Int64?=nil)throws {
        let required=try sizes.reduce(Int64(1_048_576)){sum,size in
            let (result,overflow)=sum.addingReportingOverflow(size)
            guard !overflow,size>=0 else {throw VMMError.message("素材の容量が不正です。")}
            return result
        }
        // Some sandboxed URL resource providers report important-usage capacity as zero.
        // File-system free bytes remain reliable and also cover external/non-APFS volumes.
        let available=try availableCapacity ?? (FileManager.default.attributesOfFileSystem(forPath:destination.path)[.systemFreeSize] as? NSNumber)?.int64Value
        if let available,available<required {
            throw VMMError.message("保存先の空き容量が不足しています。必要容量：約\(required / 1_048_576 + 1) MB")
        }
    }
    static func copy(_ source:URL,to target:URL)throws {
        let cloned=source.path.withCString{src in target.path.withCString{dst in clonefile(src,dst,0)==0}}
        if !cloned {try FileManager.default.copyItem(at:source,to:target)}
    }
    static func read(_ url:URL,progress:@Sendable (Double)->Void = {_ in})throws->(Project,URL) {
        let package=try PackageMediaReader(url)
        let project=try JSONDecoder().decode(Project.self,from:package.projectData()).validated()
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-session-\(UUID())")
        var files:[String]=[],sizes:[Int64]=[]
        for file in Set(project.assets.flatMap(\.files)).sorted() {if let size=try package.mediaSize(file) {files.append(file);sizes.append(size)}}
        try preflight(sizes:sizes,destination:FileManager.default.temporaryDirectory)
        try FileManager.default.createDirectory(at:folder.appendingPathComponent("Media"),withIntermediateDirectories:true)
        do {
            for (index,file) in files.enumerated() {
                guard try package.copyMedia(file,to:folder.appendingPathComponent("Media").appendingPathComponent(file)) else {throw VMMError.message("読み込み中に素材が見つからなくなりました。")}
                progress(Double(index+1)/Double(max(1,files.count)))
            }
            progress(1);return (project,folder)
        } catch {try? FileManager.default.removeItem(at:folder);throw error}
    }
}

/// A package is untrusted input. Open the package and its Media directory once,
/// then open only regular files by name without following symlinks. Copy from
/// the opened descriptor so replacing a path between validation and copying
/// cannot redirect a later read outside the package.
final class PackageMediaReader {
    private let root:Int32
    private let media:Int32
    init(_ url:URL)throws {
        root=Darwin.open(url.path,O_RDONLY|O_DIRECTORY|O_CLOEXEC)
        guard root>=0 else{throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        let descriptor=Darwin.openat(root,"Media",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        if descriptor<0 && errno != ENOENT {let code=errno;Darwin.close(root);throw POSIXError(POSIXErrorCode(rawValue:code) ?? .EIO)}
        media=descriptor
    }
    deinit {if media>=0 {Darwin.close(media)};Darwin.close(root)}
    private func file(_ name:String,in directory:Int32)throws->Int32? {
        guard !name.isEmpty,name != ".",name != "..",!name.contains("/"),!name.utf8.contains(0) else {throw VMMError.message("不正な素材ファイル名です。")}
        guard directory>=0 else{return nil}
        let descriptor=Darwin.openat(directory,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        if descriptor<0 {
            if errno==ENOENT{return nil}
            throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)
        }
        var info=stat()
        guard fstat(descriptor,&info)==0,info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor);throw VMMError.message("パッケージの素材は通常のファイルである必要があります。")
        }
        return descriptor
    }
    func metadata(_ name:String)throws->Data {
        guard let descriptor=try file(name,in:root) else{throw VMMError.message("パッケージの情報ファイルが見つかりません。")}
        let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        defer{try? handle.close()}
        return try handle.readToEnd() ?? Data()
    }
    func projectData()throws->Data {try metadata("project.json")}
    func mediaSize(_ name:String)throws->Int64? {
        guard let descriptor=try file(name,in:media) else{return nil}
        defer{Darwin.close(descriptor)}
        var info=stat();guard fstat(descriptor,&info)==0 else{throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        return info.st_size
    }
    @discardableResult func copyMedia(_ name:String,to destination:URL)throws->Bool {
        guard let descriptor=try file(name,in:media) else{return false}
        defer{Darwin.close(descriptor)}
        if fclonefileat(descriptor,AT_FDCWD,destination.path,0)==0 {return true}
        let output=Darwin.open(destination.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard output>=0 else{throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        defer{Darwin.close(output)}
        guard fcopyfile(descriptor,output,nil,copyfile_flags_t(COPYFILE_DATA))==0 else {
            let code=errno;try? FileManager.default.removeItem(at:destination);throw POSIXError(POSIXErrorCode(rawValue:code) ?? .EIO)
        }
        return true
    }
}

@MainActor extension EditorStore {
    func retainSession(_ url:URL) {sessionReaders[url,default:0]+=1}
    func releaseSession(_ url:URL) {
        sessionReaders[url,default:0]-=1
        if sessionReaders[url,default:0]<=0 {
            sessionReaders[url]=nil
            if retiredSessions.remove(url) != nil {try? FileManager.default.removeItem(at:url)}
        }
    }
    func retireSession(_ url:URL) {
        if sessionReaders[url,default:0]>0 {retiredSessions.insert(url)}
        else {try? FileManager.default.removeItem(at:url)}
    }
    func saveDestination(asNew:Bool)->URL? {
        if !asNew,let savedURL {return savedURL}
        let panel=NSSavePanel()
        panel.allowedContentTypes=[UTType(exportedAs:"app.vmm.project",conformingTo:.package)]
        panel.nameFieldStringValue=project.name+".vmm";panel.canCreateDirectories=true
        return panel.runModal() == .OK ? panel.url:nil
    }
    func requestSave(asNew:Bool=false) {requestSave(chooseDestination:{self.saveDestination(asNew:asNew)})}
    func requestSave(chooseDestination:()->URL?) {guard !busy,finishPendingPreviewText(),let url=chooseDestination() else{return};Task{_=await saveProject(to:url)}}
    @discardableResult func saveProject(to destination:URL)async->Bool {
        guard !busy,finishPendingPreviewText() else{return false}
        pause();busy=true;projectIOProgress=0;let operationID=UUID();projectIOID=operationID;status="プロジェクトを保存しています…"
        let source=directory;retainSession(source)
        var snapshot=project;snapshot.name=destination.deletingPathExtension().lastPathComponent
        defer {releaseSession(source);busy=false;projectIOProgress=nil}
        do {
            try await Task.detached(priority:.userInitiated) {
                try ProjectPackage.write(snapshot,media:source.appendingPathComponent("Media"),to:destination) {value in
                    Task{@MainActor in if self.projectIOID==operationID,self.projectIOProgress != nil {self.projectIOProgress=value}}
                }
            }.value
            project.name=snapshot.name;savedURL=destination;dirty=false;status="保存しました：\(destination.lastPathComponent)";return true
        } catch {self.error="保存できませんでした。\n\(error.localizedDescription)";return false}
    }
    @discardableResult func loadProjectAsync(_ url:URL)async->Bool {
        guard !busy,finishPendingPreviewText() else{return false}
        pause();busy=true;projectIOProgress=0;let operationID=UUID();projectIOID=operationID;status="プロジェクトを読み込んでいます…"
        defer{busy=false;projectIOProgress=nil}
        do {
            let (snapshot,folder)=try await Task.detached(priority:.userInitiated) {
                try ProjectIO.read(url){value in Task{@MainActor in if self.projectIOID==operationID,self.projectIOProgress != nil {self.projectIOProgress=value}}}
            }.value
            reset(to:snapshot,directory:folder,savedURL:url);status="\(snapshot.name) を開きました。"
            if !missingAssets.isEmpty {status += " 未検出の素材は素材管理から再リンクしてください。"}
            return true
        } catch {self.error="プロジェクトを開けませんでした。\n\(error.localizedDescription)";return false}
    }
    func requestDiscard(_ completion:@escaping @MainActor (Bool)->Void) {
        guard !busy,finishPendingPreviewText() else{completion(false);return}
        guard dirty else{completion(true);return}
        let alert=NSAlert();alert.messageText="変更を保存しますか？";alert.informativeText="保存しない変更は失われます。"
        alert.addButton(withTitle:"保存");alert.addButton(withTitle:"キャンセル");alert.addButton(withTitle:"保存しない")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard let url=saveDestination(asNew:false) else{completion(false);return}
            Task{completion(await saveProject(to:url))}
        case .alertThirdButtonReturn:completion(true)
        default:completion(false)
        }
    }
    func requestLoad(_ url:URL,asCopy:Bool=false) {
        requestDiscard{allowed in guard allowed else{return};Task{if await self.loadProjectAsync(url),asCopy {self.savedURL=nil;self.dirty=true}}}
    }
}
