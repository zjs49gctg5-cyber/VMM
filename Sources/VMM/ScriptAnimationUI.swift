import SwiftUI
import AnimationScriptRuntime

struct ScriptAnimationEditor:View {
    @ObservedObject var store:EditorStore
    let clip:Clip
    let initialDefinition:AnimationDefinition?
    var initialValues:[String:Double]=[:]
    var valueOverrides:[String:Double]=[:]
    var initialSeed:UInt32?
    @Environment(\.dismiss) private var dismiss
    @State private var draft=ScriptAnimationDraft(definition:AnimationDefinition.scriptSamples[0])
    @State private var session:ScriptDraftSession?
    @State private var repository:ScriptDraftRepository?
    @State private var report=""
    @State private var failed=false
    @State private var errorLine:Int?
    @State private var saveError:String?
    @State private var restored=false
    @State private var showJSON=false
    @State private var showDiscard=false
    private var parameters:[AnimationParameter]? {draft.parameters}
    private var samples:[AnimationDefinition] {AnimationDefinition.scriptSamples(for:clip)}
    private var withinLimit:Bool {(try? ScriptGenerationLimits.validate(duration:clip.duration,fps:store.project.fps)) != nil}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(L("JavaScriptアニメーション")).vmmFont(size:16,weight:.semibold)
                Spacer()
                Menu(L("サンプル")){ForEach(samples){sample in Button(sample.name){select(sample)}}}.disabled(store.scriptGenerating)
                Button(L("下書きを破棄…")){showDiscard=true}.disabled(store.scriptGenerating)
                Button(L("閉じる")){if persist(){if store.scriptGenerating{store.cancelScriptAnimation()};dismiss()}}
            }
            Text(L(restored ? "下書きを復元しました。変更は自動保存されます。":"変更は下書きに自動保存されます。適用するまでプロジェクトは変わりません。"))
                .foregroundColor(.secondary)
            if let saveError {Text(L("下書きを保存できません：")+saveError).foregroundColor(.red).textSelection(.enabled)}
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    TextField(L("アニメーション名"),text:$draft.name).textFieldStyle(.roundedBorder)
                    Text(L("animate(input)で対象項目の数値を返します。input.tは0〜1、paramsはパラメータ、baseは基準値です。")).foregroundColor(.secondary)
                    ScriptCodeEditor(source:$draft.source,errorLine:errorLine).frame(minHeight:280)
                    PanelDisclosure(L("出力する項目")) {
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:210))],alignment:.leading,spacing:8) {
                            ForEach(clip.availableAnimatedProperties,id:\.self){p in HStack {
                                Toggle(L(p.title),isOn:Binding(get:{draft.outputs.contains{$0.property==p}},set:{v in if v{draft.outputs.append(ScriptAnimationOutput(property:p,offset:true))}else{draft.outputs.removeAll{$0.property==p}}}))
                                if draft.outputs.contains(where:{$0.property==p}) {
                                    Toggle(L("基準値に加算"),isOn:Binding(get:{draft.outputs.first{$0.property==p}?.offset ?? true},set:{v in if let i=draft.outputs.firstIndex(where:{$0.property==p}){draft.outputs[i].offset=v}})).toggleStyle(.checkbox)
                                }
                            }}
                        }
                        Text(L("返す項目：")+draft.outputs.filter{clip.availableAnimatedProperties.contains($0.property)}.map{$0.property.rawValue}.joined(separator:", ")).font(.system(.body,design:.monospaced)).textSelection(.enabled)
                    }
                    parameterControls
                    if let parameters {
                        ForEach(Array(parameters.prefix(12).enumerated()),id:\.offset){_,p in
                            if p.minimum.isFinite,p.maximum.isFinite,p.minimum<p.maximum {
                                NumberInput(title:p.title,value:Binding(get:{draft.values[p.id] ?? p.defaultValue},set:{draft.values[p.id]=$0}),range:p.minimum...p.maximum,unit:p.unit == "%" ? "":p.unit ?? "",percent:p.unit == "%")
                            }
                        }
                    }
                    NumberInput(title:"乱数シード",value:$draft.seed,range:0...4294967295)
                    Text(ScriptGenerationLimits.summary(duration:clip.duration,fps:store.project.fps)).foregroundColor(withinLimit ? .secondary:.orange)
                    Text(L("テスト生成はプロジェクトを変更しません。適用すると対象項目のキーを置換し、コードと値をプロジェクトに保存します。")).foregroundColor(.secondary)
                }.disabled(store.scriptGenerating)
            }
            if !report.isEmpty {Text(report).foregroundColor(failed ? .red:.secondary).textSelection(.enabled)}
            HStack {
                if store.scriptGenerating {ProgressView().controlSize(.small);Text(L("JavaScriptを生成中…"));Button(L("生成をキャンセル")){store.cancelScriptAnimation()}}
                Button(L("現在の設定を拡張JSONに書き出す…")){
                    do{let package=try draft.sharedPackage(available:clip.availableAnimatedProperties);if persist(){store.exportDataExtension(package)}}catch{fail(error)}
                }.disabled(store.scriptGenerating)
                Spacer()
                Button(L("テスト生成")){run(apply:false)}.disabled(store.scriptGenerating || store.busy || !withinLimit)
                Button(L("キーフレームを生成・適用")){run(apply:true)}.buttonStyle(.borderedProminent).disabled(store.scriptGenerating || store.busy || !withinLimit)
            }
        }.padding(20).frame(minWidth:820,minHeight:720).vmmAppearance(store.settings)
        .onAppear{initialize()}
        .onDisappear{_ = persist()}
        .task(id:draft){guard session != nil else{return};do{try await Task.sleep(nanoseconds:300_000_000);try Task.checkCancellation();_ = persist()}catch{}}
        .onChange(of:draft.source){_ in errorLine=nil}
        .onChange(of:store.savedURL){_ in migrateRepository()}
        .alert(L("現在の下書きを破棄しますか？"),isPresented:$showDiscard){
            Button(L("破棄"),role:.destructive){discard()};Button(L("キャンセル"),role:.cancel){}
        }message:{Text(L("現在の定義を初期状態に戻します。適用済みのキーフレームは変わりません。"))}
    }
    private var parameterControls:some View {
        PanelDisclosure(L("パラメータ定義")) {
            Toggle(L("JSONを直接編集"),isOn:$showJSON).toggleStyle(.checkbox)
            if showJSON {
                Text(L("id・title・minimum・maximum・defaultValueを指定します。unitの%は内部値1が100%です。")).foregroundColor(.secondary)
                TextEditor(text:$draft.parameterJSON).font(.system(size:12,design:.monospaced)).frame(minHeight:130).accessibilityLabel(L("パラメータ定義JSON"))
            }else if let parameters {
                ForEach(Array(parameters.prefix(12).enumerated()),id:\.offset){index,p in
                    VStack(alignment:.leading,spacing:8) {
                        HStack {
                            TextField(L("ID（コードで参照）"),text:parameterBinding(index,\.id,fallback:p.id))
                            TextField(L("表示名"),text:parameterBinding(index,\.title,fallback:p.title))
                            Picker(L("単位"),selection:parameterBinding(index,\.unit,fallback:p.unit)) {
                                Text(L("なし")).tag(String?.none)
                                ForEach(["%","°","秒","回"],id:\.self){Text(L($0)).tag(Optional($0))}
                            }.frame(width:120)
                            Button(L("削除")){var list=parameters;list.remove(at:index);setParameters(list)}
                        }
                        HStack {
                            NumberInput(title:"最小値",value:parameterBinding(index,\.minimum,fallback:p.minimum),range:-10000...10000,percent:p.unit == "%")
                            NumberInput(title:"最大値",value:parameterBinding(index,\.maximum,fallback:p.maximum),range:-10000...10000,percent:p.unit == "%")
                            NumberInput(title:"初期値",value:parameterBinding(index,\.defaultValue,fallback:p.defaultValue),range:-10000...10000,percent:p.unit == "%")
                        }
                    }.padding(8).background(Color.primary.opacity(0.04)).cornerRadius(6)
                }
                Button(L("パラメータを追加")){
                    var list=parameters;var n=list.count+1;while list.contains(where:{$0.id=="param\(n)"}){n+=1}
                    list.append(AnimationParameter(id:"param\(n)",title:L("パラメータ")+" \(n)",minimum:0,maximum:1,defaultValue:0.5));setParameters(list)
                }.disabled(parameters.count>=12)
                if parameters.count>12{Text(L("パラメータは12件までです。JSONを直接編集して減らしてください。")).foregroundColor(.red)}
            }else {Text(L("パラメータJSONが不正です。JSONを直接編集して修正してください。")).foregroundColor(.red)}
        }
    }
    private func parameterBinding<T>(_ index:Int,_ key:WritableKeyPath<AnimationParameter,T>,fallback:T)->Binding<T> {
        Binding(get:{guard let list=parameters,list.indices.contains(index) else{return fallback};return list[index][keyPath:key]},set:{v in guard var list=parameters,list.indices.contains(index) else{return};list[index][keyPath:key]=v;setParameters(list)})
    }
    private func setParameters(_ list:[AnimationParameter]) {
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        if let data=try? encoder.encode(list),let json=String(data:data,encoding:.utf8){draft.parameterJSON=json}
    }
    private func initialize() {
        guard session==nil else{return}
        let definition=initialDefinition ?? clip.customAnimation?.definition.script.flatMap{_ in clip.customAnimation?.definition} ?? samples[0]
        let saved=clip.customAnimation?.definition==definition ? clip.customAnimation:nil
        let initial=ScriptAnimationDraft(definition:definition,values:initialDefinition != nil ? initialValues:saved?.values ?? [:],seed:initialSeed ?? saved?.seed,packageID:saved?.packageID.hasPrefix("user.javascript.")==true ? saved?.packageID:nil)
        let repo=makeRepository()
        repository=repo
        do {
            session=try repo.load();restored=session != nil
            if session==nil{session=ScriptDraftSession(initial)}
            let origin=initialDefinition?.id ?? "new"
            if let initialDefinition,session?.active != initialDefinition.id,session?.origin != origin{session?.select(initial)}
            session?.origin=origin
            session?.mergeIncoming(valueOverrides,definitionID:definition.id)
            draft=session!.drafts[session!.active]!
            _ = persist()
        }catch {
            // Preserve damaged drafts before creating a fresh one, never silently overwrite them.
            do {
                if FileManager.default.fileExists(atPath:repo.url.path){try FileManager.default.copyItem(at:repo.url,to:repo.url.deletingPathExtension().appendingPathExtension("preserved-\(UUID()).json"))}
                session=ScriptDraftSession(initial);draft=initial;_ = persist();fail(error)
            }catch{draft=initial;saveError=error.localizedDescription}
        }
    }
    private func makeRepository()->ScriptDraftRepository {
        ScriptDraftRepository(directory:store.preferencesDirectory,scope:(store.savedURL ?? store.directory).standardizedFileURL.path,clipID:clip.id,origin:"workspace")
    }
    private func migrateRepository() {
        guard store.project.clips.contains(where:{$0.id==clip.id}),persist(),let session else{return}
        let next=makeRepository();guard next.url != repository?.url else{return}
        do {
            if FileManager.default.fileExists(atPath:next.url.path){try FileManager.default.copyItem(at:next.url,to:next.url.deletingPathExtension().appendingPathExtension("preserved-\(UUID()).json"))}
            try next.save(session);repository=next;saveError=nil
        }catch{saveError=error.localizedDescription}
    }
    @discardableResult private func persist()->Bool {
        guard var session,let repository else{return false}
        session.update(draft);self.session=session
        do{try repository.save(session);saveError=nil;return true}catch{saveError=error.localizedDescription;return false}
    }
    private func select(_ definition:AnimationDefinition) {
        guard persist() else{return}
        session?.select(ScriptAnimationDraft(definition:definition))
        draft=session!.drafts[session!.active]!;report="";failed=false;errorLine=nil;_ = persist()
    }
    private func discard() {
        let definition=samples.first{$0.id==draft.definitionID} ?? initialDefinition ?? clip.customAnimation?.definition
        guard let definition else{return}
        let saved=clip.customAnimation?.definition==definition ? clip.customAnimation:nil
        draft=ScriptAnimationDraft(definition:definition,values:saved?.values ?? [:],seed:saved?.seed,packageID:draft.packageID)
        report="";failed=false;errorLine=nil;restored=false;_ = persist()
    }
    private func fail(_ error:Error) {
        failed=true
        if let scriptError=error as? ScriptError {
            errorLine=scriptError.sourceLine
            report=(errorLine.map{String(format:L("コード %d行目："),$0)} ?? "")+ScriptDiagnostics.display(scriptError.message)
        }else{report=error.localizedDescription}
    }
    private func run(apply:Bool) {
        do {
            let definition=try draft.definition(available:clip.availableAnimatedProperties)
            let values=try definition.resolved(draft.values.filter{key,_ in definition.parameters.contains{$0.id==key}})
            guard let seed=draft.seedValue,persist() else{return}
            report="";failed=false;errorLine=nil
            let packageID=draft.packageID
            Task {do {
                let count=try await store.runScriptAnimation(definition,packageID:packageID,values:values,seed:seed,clipID:clip.id,apply:apply)
                report=L(apply ? "適用しました。":"テスト生成が成功しました。")+" \(count) "+L("キーフレーム")
            }catch is CancellationError{failed=false;report=L("生成をキャンセルしました。")}
             catch{fail(error)}}
        }catch{fail(error)}
    }
}
