import Foundation

/// Use bundle metadata as the single source of truth for packaged builds.
struct AppVersion {
    let version:String?
    let build:String?
    let channel:String?
    init(info:[String:Any]?) {
        func value(_ key:String)->String? {
            guard let text=info?[key] as? String else{return nil}
            let trimmed=text.trimmingCharacters(in:.whitespacesAndNewlines)
            return trimmed.isEmpty ? nil:trimmed
        }
        version=value("CFBundleShortVersionString")
        build=value("CFBundleVersion")
        channel=value("VMMReleaseChannel")
    }
    static var current:AppVersion {AppVersion(info:Bundle.main.infoDictionary)}
    /// Protocol identifiers are stable and language-independent.
    var protocolVersion:String {
        guard let version else{return "0.0.0-dev"}
        let suffix=channel?.lowercased()=="beta" ? "-beta":""
        return version+suffix+(build.map{"+build."+$0} ?? "")
    }
    var display:String {
        guard let version else{return L("開発版")}
        let suffix=channel?.lowercased()=="beta" ? " β":""
        return version+suffix
    }
    var fullDisplay:String {
        guard let build else{return display}
        return display+" ("+L("ビルド")+" "+build+")"
    }
}
