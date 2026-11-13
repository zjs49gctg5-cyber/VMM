import SwiftUI

struct DataExtensionSettings:View {
    @ObservedObject var store:EditorStore
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text(L("JSON拡張")).vmmFont(size:16,weight:.semibold)
            Text(L("JSON定義・プリセットとJavaScriptアニメーションを読み込みます。コードは生成時だけ別プロセスで実行します。")).foregroundColor(.secondary)
            HStack {
                Button(L("拡張JSONを読み込む…")){store.importDataExtension()}
                Button(L("サンプル拡張を追加")){attempt{try store.installDataExtension(.sample)}}.disabled(store.dataExtensions.contains{$0.id==DataExtensionPackage.sample.id})
            }
            Button(L("JavaScriptサンプルを追加")){attempt{try store.installDataExtension(.scriptSample)}}.disabled(store.dataExtensions.contains{$0.id==DataExtensionPackage.scriptSample.id})
            if store.dataExtensions.isEmpty {Text(L("拡張はまだ導入されていません。")).foregroundColor(.secondary)}
            ForEach(store.dataExtensions){package in
                VStack(alignment:.leading,spacing:8) {
                    HStack {
                        Toggle(package.name,isOn:Binding(get:{store.enabledDataExtensions.contains{$0.id==package.id}},set:{v in attempt{try store.setDataExtensionEnabled(package.id,v)}}))
                        Spacer();Button(L("書き出す…")){store.exportDataExtension(package)}
                        Button(L("削除")){attempt{try store.removeDataExtension(package.id)}}
                    }
                    Text("\(package.author) · \(package.revision) · \(package.id)").foregroundColor(.secondary).textSelection(.enabled)
                    Text("\(L("アニメーション")): \(package.animations.count) / \(L("プリセット")): \(package.presets.count)")
                }.padding(12).background(Color.primary.opacity(0.04)).cornerRadius(8)
            }
            Text(L("無効化・削除しても、適用済みのキーフレームとプロジェクト内の定義は保持します。")).foregroundColor(.secondary)
        }.disabled(store.busy)
    }
    private func attempt(_ action:()throws->Void){do{try action()}catch{store.error=error.localizedDescription}}
}
private struct DefinedAnimationChoice:Identifiable {
    var packageID:String;var definition:AnimationDefinition;var projectCopy=false
    var id:String {(projectCopy ? "saved:":"")+packageID+":"+definition.id}
    var title:String {definition.name+(projectCopy ? " · "+L("プロジェクト内の定義"):"")}
}
struct CustomAnimationControls:View {
    @ObservedObject var store:EditorStore
    let clip:Clip
    @State private var scriptEditor=false
    @State private var selected=""
    @State private var values:[String:Double]=[:]
    private var choices:[DefinedAnimationChoice] {
        var result=store.enabledDataExtensions.flatMap{p in p.animations.filter{a in a.targetProperties.allSatisfy{clip.availableAnimatedProperties.contains($0)}}.map{DefinedAnimationChoice(packageID:p.id,definition:$0)}}
        if let saved=clip.customAnimation {result.insert(DefinedAnimationChoice(packageID:saved.packageID,definition:saved.definition,projectCopy:true),at:0)}
        return result
    }
    private var current:DefinedAnimationChoice? {choices.first{$0.id==selected}}
    private var currentSeed:UInt32 {current?.projectCopy == true ? clip.customAnimation?.seed ?? current?.definition.scriptSeed ?? 1:current?.definition.scriptSeed ?? 1}
    private var valueOverrides:[String:Double] {
        guard let choice=current else{return [:]}
        let baseline=choice.projectCopy ? clip.customAnimation?.values ?? [:]:Dictionary(uniqueKeysWithValues:choice.definition.parameters.map{($0.id,$0.defaultValue)})
        return values.filter{key,value in baseline[key] != value}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text(L("カスタムアニメーション")).vmmFont(size:16,weight:.semibold)
            if choices.isEmpty {
                Text(L("設定の「拡張」でJSON拡張を導入してください。")).foregroundColor(.secondary)
            }else {
                VMMMenuPicker(L("アニメーション定義"),selection:$selected){VMMOptions(choices,id:\.id){VMMChoice(text:$0.title,value:$0.id)}}
                if let choice=current {
                    if let text=choice.definition.description {Text(text).foregroundColor(.secondary)}
                    ForEach(choice.definition.parameters){p in
                        NumberInput(title:p.title,value:Binding(get:{values[p.id] ?? p.defaultValue},set:{values[p.id]=$0}),range:p.minimum...p.maximum,unit:p.unit == "%" ? "":p.unit ?? "",percent:p.unit == "%")
                    }
                    HStack {
                        Button(L("パラメータを初期値に戻す")){values=Dictionary(uniqueKeysWithValues:choice.definition.parameters.map{($0.id,$0.defaultValue)})}
                        Button(L("キーフレームを生成・適用")){
                            if choice.definition.script != nil {
                                Task {do{try await store.runScriptAnimation(choice.definition,packageID:choice.packageID,values:values,seed:currentSeed,clipID:clip.id,apply:true)}catch is CancellationError{}catch{store.error=error.localizedDescription}}
                            }else{do{try store.applyDefinedAnimation(choice.definition,packageID:choice.packageID,values:values,clipID:clip.id)}catch{store.error=error.localizedDescription}}
                        }.buttonStyle(.borderedProminent).disabled(store.scriptGenerating)
                    }
                    Text(L("定義に含まれる項目のキーフレームを置き換えます。生成後は通常のキーとして編集できます。")).foregroundColor(.secondary)
                }
            }
            if store.scriptGenerating{HStack{ProgressView().controlSize(.small);Text(L("JavaScriptを生成中…"));Button(L("生成をキャンセル")){store.cancelScriptAnimation()}}}
            Button(L("JavaScriptで作成・編集…")){scriptEditor=true}.disabled(store.scriptGenerating)
            Button(L("拡張の設定を開く")){store.settingsTab = .extensions;store.workspaceWindows.show(.settings)}
        }.sheet(isPresented:$scriptEditor){ScriptAnimationEditor(store:store,clip:clip,initialDefinition:current?.definition.script == nil ? nil:current?.definition,initialValues:values,valueOverrides:valueOverrides,initialSeed:current?.definition.script == nil ? nil:currentSeed)}
        .onChange(of:clip.customAnimation){_ in selected=choices.first?.id ?? "";resetValues()}
        .onAppear{resetSelection()}.onChange(of:selected){_ in resetValues()}.onChange(of:store.dataExtensions){_ in reconcileChoices()}.onChange(of:store.settings.disabledExtensions){_ in reconcileChoices()}
    }
    private func resetSelection(){if !choices.contains(where:{$0.id==selected}){selected=choices.first?.id ?? ""};resetValues()}
    private func resetValues(){guard let choice=current else{values=[:];return};if choice.projectCopy,let saved=clip.customAnimation{values=saved.values}else{values=Dictionary(uniqueKeysWithValues:choice.definition.parameters.map{($0.id,$0.defaultValue)})}}
    private func reconcileChoices(){if !choices.contains(where:{$0.id==selected}){resetSelection()}}
}
