import SwiftUI

struct AudioReactiveControls:View {
    @ObservedObject var store:EditorStore;let clip:Clip
    @State private var source:UUID?;@State private var task:Task<Void,Never>?;@State private var analyzing=false
    private var sources:[Clip]{store.project.clips.filter{[.audio,.video,.speech].contains($0.kind) && store.project.asset(for:$0) != nil}}
    private func change(_ body:(inout AudioReactive)->Void){do{try store.mutateMotion(clip.id){if var a=$0.audioReactive{body(&a);$0.audioReactive=a}}}catch{store.error=error.localizedDescription}}
    private func number(_ key:WritableKeyPath<AudioReactive,Double>)->Binding<Double>{Binding(get:{clip.audioReactive?[keyPath:key] ?? 0},set:{v in change{$0[keyPath:key]=v}})}
    var body:some View{VStack(alignment:.leading,spacing:12){
        Text(L("音声からアニメーションを作る")).fontWeight(.semibold)
        VMMMenuPicker(L("解析する音声・動画"),selection:$source){VMMChoice(text:L("素材を選択"),value:Optional<UUID>.none);VMMOptions(sources,id:\.id){c in VMMChoice(text:c.name,value:Optional(c.id))}}
        HStack{Button(L(analyzing ? "解析中…":"音声を解析")){analyze()}.disabled(source==nil || analyzing);if analyzing{Button(L("キャンセル")){task?.cancel()}};if clip.audioReactive != nil{Button(L("音声連動を解除")){do{try store.mutateMotion(clip.id){$0.audioReactive=nil}}catch{store.error=error.localizedDescription}}}}
        if let a=clip.audioReactive {
            VMMMenuPicker(L("連動する信号"),selection:Binding(get:{a.signal},set:{v in change{$0.signal=v}})){VMMOptions(ReactiveSignal.allCases,id:\.self){VMMChoice(text:L($0.title),value:$0)}}
            NumberInput(title:"感度",value:number(\.gain),range:0...10,percent:true)
            NumberInput(title:"反応しない音量",value:number(\.threshold),range:0...0.99,percent:true)
            NumberInput(title:"拡大率の変化",value:number(\.scaleAmount),range:-0.99...4,percent:true)
            NumberInput(title:"振動の強さ",value:number(\.shakeAmount),range:0...1,percent:true)
            NumberInput(title:"発光の強さ",value:number(\.glowAmount),range:0...100,unit:"px")
            NumberInput(title:"音声開始位置",value:number(\.timelineOffset),range:-86400...86400,unit:"秒")
            Text(L("解析済みの音量・低音・アタックを保存するので出力でも同じ動きになります。アタックは拍の候補でありBPM解析ではありません。音声の配置や速度、音声ファイルを変更した後は再解析してください。")).foregroundColor(.secondary)
        }
    }.onAppear{source=sources.first?.id}.onChange(of:source){_ in task?.cancel()}.onDisappear{task?.cancel()}}
    private func analyze(){
        guard let source=sources.first(where:{$0.id==source}) else{return}
        let targetID=clip.id,sourceID=source.id;analyzing=true
        task=Task{@MainActor in defer{analyzing=false;task=nil}
            do{try await store.analyzeReactiveAudio(clipID:targetID,sourceClipID:sourceID)}catch is CancellationError{}catch{store.error=error.localizedDescription}
        }
    }
}
