import Foundation
import Darwin

enum ExportFileCommit {
    static func install(_ staging:URL,to destination:URL,overwrite:Bool)throws {
        if overwrite {
            if FileManager.default.fileExists(atPath:destination.path) {
                _=try FileManager.default.replaceItemAt(destination,withItemAt:staging)
            } else {try FileManager.default.moveItem(at:staging,to:destination)}
        } else {
            // Atomic no-replace on the destination filesystem, including a file created mid-render.
            let status=staging.path.withCString{source in destination.path.withCString{target in
                renameatx_np(AT_FDCWD,source,AT_FDCWD,target,UInt32(RENAME_EXCL))
            }}
            guard status==0 else {
                let code=errno
                if code==EEXIST {throw VMMError.message("出力先にファイルが作成されました。上書きせず停止しました。")}
                throw NSError(domain:NSPOSIXErrorDomain,code:Int(code))
            }
        }
    }
}
