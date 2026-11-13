import SwiftUI
struct CharacterAnimationControls:View {
    @ObservedObject var store:EditorStore;let clip:Clip
    private func change(_ body:(inout CharacterAnimation)->Void){do{try store.mutateMotion(clip.id){c in var a=c.textAnimation ?? CharacterAnimation();body(&a);c.textAnimation=a}}catch{store.error=error.localizedDescription}}
    private func number(_ key:WritableKeyPath<CharacterAnimation,Double>)->Binding<Double>{Binding(get:{(clip.textAnimation ?? CharacterAnimation())[keyPath:key]},set:{v in change{$0[keyPath:key]=v}})}
    var body:some View {VStack(alignment:.leading,spacing:12){
        Text(L("文字単位のアニメーション")).fontWeight(.semibold)
        Toggle(L("有効"),isOn:Binding(get:{clip.textAnimation != nil},set:{v in do{try store.mutateMotion(clip.id){$0.textAnimation=v ? CharacterAnimation():nil}}catch{store.error=error.localizedDescription}}))
        if let animation=clip.textAnimation {
            VMMMenuPicker(L("動き"),selection:Binding(get:{animation.kind},set:{v in change{$0.kind=v}})){VMMOptions(CharacterMotion.allCases,id:\.self){VMMChoice(text:L($0.title),value:$0)}}
            NumberInput(title:"開始時刻",value:number(\.start),range:0...86400,unit:"秒")
            NumberInput(title:"文字ごとの遅延",value:number(\.delay),range:0...10,unit:"秒")
            NumberInput(title:animation.kind == .wave ? "波の周期":"1文字の動作時間",value:number(\.duration),range:0.01...60,unit:"秒")
            if [.rise,.bounce,.wave].contains(animation.kind){NumberInput(title:"移動量",value:number(\.distance),range:-2000...2000,unit:"px")}
            if animation.kind == .blur{NumberInput(title:"ぼかし半径",value:Binding(get:{animation.blurRadius ?? 12},set:{v in change{$0.blurRadius=v}}),range:0...64,unit:"px")}
            if animation.kind == .rotate{NumberInput(title:"開始角度",value:number(\.rotation),range:-3600...3600,unit:"°")}
            if animation.kind == .zoom{NumberInput(title:"開始倍率",value:number(\.initialScale),range:0.01...10,percent:true)}
            Toggle(L("末尾から動かす"),isOn:Binding(get:{animation.reverse},set:{v in change{$0.reverse=v}}))
            VStack{NumberInput(title:"対象の先頭文字",value:Binding(get:{Double(animation.first+1)},set:{v in change{$0.first=Int(v)-1;$0.last=max($0.first,$0.last)}}),range:1...Double(max(1,clip.text.count)));NumberInput(title:"対象の末尾文字",value:Binding(get:{Double(min(max(1,clip.text.count),animation.last+1))},set:{v in change{$0.last=max($0.first,Int(v)-1)}}),range:1...Double(max(1,clip.text.count)))}
            Button(L("全文字を対象にする")){change{$0.first=0;$0.last=10000}}
            VMMMenuPicker(L("イージング"),selection:Binding(get:{animation.easing},set:{v in change{$0.easing=v}})){VMMOptions(Easing.allCases,id:\.self){VMMChoice(text:L($0.title),value:$0)}}
            Text(L("改行・文字幅を保って一文字ずつ動かします。文字送り、縁取り、影、色のグラデーションと併用できます。")).foregroundColor(.secondary)
        }
    }}
}
