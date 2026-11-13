import Foundation
import CryptoKit

/// Drafts intentionally allow invalid source/parameter JSON: editing must not lose unfinished work.
struct ScriptAnimationDraft:Codable,Equatable {
    var definitionID:String
    var packageID:String
    var name:String
    var source:String
    var parameterJSON:String
    var values:[String:Double]
    var outputs:[ScriptAnimationOutput]
    var seed:Double

    init(definition:AnimationDefinition,values:[String:Double]=[:],seed:UInt32?=nil,packageID:String?=nil) {
        definitionID=definition.id
        self.packageID=packageID ?? "user.javascript."+UUID().uuidString
        name=definition.name;source=definition.script ?? ""
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        parameterJSON=String(data:(try? encoder.encode(definition.parameters)) ?? Data("[]".utf8),encoding:.utf8) ?? "[]"
        self.values=values;outputs=definition.scriptOutputs ?? [];self.seed=Double(seed ?? definition.scriptSeed ?? 1)
    }
    var parameters:[AnimationParameter]? {try? JSONDecoder().decode([AnimationParameter].self,from:Data(parameterJSON.utf8))}
    var seedValue:UInt32? {guard seed.isFinite,seed.rounded(.towardZero)==seed,(0...4294967295).contains(seed) else{return nil};return UInt32(seed)}
    func definition(available:[AnimatedProperty])throws->AnimationDefinition {
        guard let parameters,seedValue != nil else{throw VMMError.message("パラメータJSONまたは乱数シードが不正です。")}
        return try AnimationDefinition(id:definitionID,name:name,parameters:parameters,tracks:[],script:source,scriptOutputs:outputs.filter{available.contains($0.property)},scriptSeed:seedValue).validated()
    }
    func sharedPackage(available:[AnimatedProperty])throws->DataExtensionPackage {
        var definition=try definition(available:available)
        let resolved=try definition.resolved(values.filter{key,_ in definition.parameters.contains{$0.id==key}})
        for i in definition.parameters.indices {definition.parameters[i].defaultValue=resolved[definition.parameters[i].id]!}
        return try DataExtensionPackage(version:2,id:packageID,name:name,author:"",revision:"1.0",animations:[definition],presets:[]).validated()
    }
}

struct ScriptDraftSession:Codable,Equatable {
    var active:String
    var drafts:[String:ScriptAnimationDraft]
    var origin:String?
    init(_ draft:ScriptAnimationDraft){active=draft.definitionID;drafts=[active:draft]}
    mutating func select(_ draft:ScriptAnimationDraft) {active=draft.definitionID;if drafts[active]==nil{drafts[active]=draft}}
    mutating func update(_ draft:ScriptAnimationDraft) {drafts[active]=draft}
    mutating func mergeIncoming(_ values:[String:Double],definitionID:String) {
        guard active==definitionID else{return}
        drafts[active]?.values.merge(values){_,new in new}
    }
}

struct ScriptDraftRepository {
    let url:URL
    init(directory:URL,scope:String,clipID:UUID,origin:String) {
        let hash=SHA256.hash(data:Data((scope+"\n"+clipID.uuidString+"\n"+origin).utf8)).map{String(format:"%02x",$0)}.joined()
        url=directory.appendingPathComponent("AnimationDrafts").appendingPathComponent(hash+".json")
    }
    func load()throws->ScriptDraftSession? {
        guard FileManager.default.fileExists(atPath:url.path) else{return nil}
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)<=8_388_608 else{throw VMMError.message("アニメーション下書きが大きすぎます。")}
        let session=try JSONDecoder().decode(ScriptDraftSession.self,from:Data(contentsOf:url))
        guard session.drafts.count<=32,session.drafts[session.active] != nil else{throw VMMError.message("アニメーション下書きの形式が不正です。")}
        return session
    }
    func save(_ session:ScriptDraftSession)throws {
        let data=try JSONEncoder().encode(session)
        guard data.count<=8_388_608,session.drafts.count<=32 else{throw VMMError.message("アニメーション下書きが大きすぎます。")}
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try data.write(to:url,options:.atomic)
    }
}

enum ScriptGenerationLimits {
    static let maximumFrames=20_000
    static func validate(duration:Double,fps:Int)throws {
        guard duration.isFinite,duration>0,(1...60).contains(fps),ceil(duration*Double(fps))<=Double(maximumFrames) else {
            throw VMMError.message("生成は20,000フレームまでです。アイテムを短い区間に分割してください。")
        }
    }
    static func summary(duration:Double,fps:Int)->String {
        let count=duration.isFinite && duration>0 ? ceil(duration*Double(fps)):0
        return String(format:L("生成対象 %.0fフレーム（上限20,000）・%dfps／最長%.1f秒\n実行上限5秒・各項目500キー。超過時は区間を分割してください。"),count,fps,Double(maximumFrames)/Double(max(1,fps)))
    }
}

enum ScriptDiagnostics {
    static func display(_ message:String)->String {
        guard VMMLocalization.language == .japanese else{return message}
        let translations=[
            "JavaScript execution timed out.":"JavaScriptの実行が5秒以内に完了しませんでした。コードを簡略化するか、区間を分割してください。",
            "JavaScript worker exceeded the 512MiB memory limit.":"JavaScriptの使用メモリが512MiBを超えました。大きな配列などを減らしてください。",
            "JavaScript output exceeds the limit.":"JavaScriptの出力が8MiBを超えました。区間を分割してください。",
            "Error: Define a synchronous animate(input) function.":"同期関数 animate(input) を定義してください。",
            "Error: animate must return a synchronous object of numeric properties.":"animateは数値を持つオブジェクトを返してください。async・Promiseは使えません。",
            "Error: Returned properties must match the declared outputs.":"返す項目と「出力する項目」を一致させてください。"
        ]
        return translations[message] ?? message
    }
}
