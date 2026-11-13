import AppKit
import SwiftUI

@MainActor extension EditorStore {
    func applyTextRunStyle(clipID:UUID,originalText:String,range:Range<Int>,change:(inout TextRunStyle)->Void)throws {
        guard !busy,let index=project.clips.firstIndex(where:{$0.id==clipID}),!project.tracks[project.clips[index].track].locked,project.clips[index].text==originalText else{throw VMMError.message("文章またはレイヤーが変更されました。もう一度開いてください。")}
        let value=try TextRunEditing.apply(project.clips[index].textRuns,text:originalText,range:range,change:change)
        guard value != project.clips[index].textRuns else{return}
        pause();checkpoint();project.clips[index].textRuns=value
    }
}

struct TextRunSelectionView:NSViewRepresentable {
    let text:String
    @Binding var selection:NSRange
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeNSView(context:Context)->NSScrollView {
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.drawsBackground=false
        let view=NSTextView();view.isEditable=false;view.isSelectable=true;view.isRichText=false;view.font=NSFont.systemFont(ofSize:16);view.string=text;view.delegate=context.coordinator
        view.isVerticallyResizable=true;view.isHorizontallyResizable=false;view.autoresizingMask=[.width];view.textContainer?.widthTracksTextView=true
        scroll.documentView=view;return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {context.coordinator.parent=self}
    final class Coordinator:NSObject,NSTextViewDelegate {
        var parent:TextRunSelectionView
        init(_ parent:TextRunSelectionView){self.parent=parent}
        func textViewDidChangeSelection(_ notification:Notification){if let view=notification.object as? NSTextView {parent.selection=view.selectedRange()}}
    }
}

struct TextRunStyleSheet:View {
    @ObservedObject var store:EditorStore
    @Environment(\.dismiss) private var dismiss
    let clip:Clip
    @State private var selection=NSRange(location:0,length:0)
    @State private var useColor=false
    @State private var color=Color.white
    @State private var useFont=false
    @State private var font="HiraginoSans-W6"
    @State private var useSize=false
    @State private var size:Double=64
    @State private var useOutline=false
    @State private var outline=true
    @State private var useOutlineColor=false
    @State private var outlineColor=Color.black
    @State private var useOutlineWidth=false
    @State private var outlineWidth:Double=3
    @State private var error:String?
    init(store:EditorStore,clip:Clip) {
        self.store=store;self.clip=clip
        _color=State(initialValue:Color(nsColor:NSColor(hex:clip.color)))
        _font=State(initialValue:clip.textStyle?.fontName ?? "HiraginoSans-W6")
        _size=State(initialValue:clip.fontSize)
        _outline=State(initialValue:clip.textStyle?.outline ?? true)
        _outlineColor=State(initialValue:Color(nsColor:NSColor(hex:clip.textStyle?.outlineColor ?? "000000")))
        _outlineWidth=State(initialValue:clip.textStyle?.outlineWidth ?? 3)
    }
    private var characterRange:Range<Int>? {
        let ns=clip.text as NSString
        guard selection.location != NSNotFound,selection.length>0,selection.location>=0,selection.location<=ns.length,selection.length<=ns.length-selection.location else{return nil}
        let expanded=ns.rangeOfComposedCharacterSequences(for:selection)
        guard let range=Range(expanded,in:clip.text) else{return nil}
        return clip.text.distance(from:clip.text.startIndex,to:range.lowerBound)..<clip.text.distance(from:clip.text.startIndex,to:range.upperBound)
    }
    private func apply(clear:Bool=false) {
        guard let range=characterRange else{error=L("装飾する文字を選択してください。");return}
        do {
            try store.applyTextRunStyle(clipID:clip.id,originalText:clip.text,range:range){value in
                if clear {value=TextRunStyle();return}
                if useColor {value.color=NSColor(color).hex}
                if useFont {value.fontName=font}
                if useSize {value.fontSize=size}
                if useOutline {value.outline=outline}
                if useOutlineColor {value.outlineColor=NSColor(outlineColor).hex}
                if useOutlineWidth {value.outlineWidth=outlineWidth}
            }
            dismiss()
        } catch {self.error=error.localizedDescription}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(L("文字ごとの装飾")).font(.title2)
            Text(L("文章から装飾する文字を選び、変更する項目にチェックを入れます。")).foregroundColor(.secondary)
            TextRunSelectionView(text:clip.text,selection:$selection).frame(minWidth:480,minHeight:110).border(Color.secondary.opacity(0.4))
            HStack {Toggle(L("文字色"),isOn:$useColor);ColorPicker(L("文字色"),selection:$color,supportsOpacity:false).labelsHidden().disabled(!useColor)}
            HStack {Toggle(L("フォント"),isOn:$useFont);VMMMenuPicker(L("フォント"),selection:$font){VMMOptions(NSFontManager.shared.availableFonts.sorted(),id:\.self){VMMChoice(text:$0,value:$0)}}.labelsHidden().disabled(!useFont)}
            HStack {Toggle(L("文字サイズ"),isOn:$useSize);NumberInput(title:"サイズ",value:$size,range:8...400,unit:"px").disabled(!useSize)}
            HStack {Toggle(L("縁取りを変更"),isOn:$useOutline);Toggle(L("縁取り"),isOn:$outline).disabled(!useOutline)}
            HStack {Toggle(L("縁の色"),isOn:$useOutlineColor);ColorPicker(L("縁の色"),selection:$outlineColor,supportsOpacity:false).labelsHidden().disabled(!useOutlineColor)}
            HStack {Toggle(L("縁の太さ"),isOn:$useOutlineWidth);NumberInput(title:"太さ（文字サイズ比）",value:$outlineWidth,range:0...20,unit:"%").disabled(!useOutlineWidth)}
            if let error {Text(error).foregroundColor(.red)}
            HStack {Button(L("選択範囲の装飾を解除")){apply(clear:true)}.disabled(characterRange == nil);Spacer();Button(L("キャンセル")){dismiss()};Button(L("適用")){apply()}.keyboardShortcut(.defaultAction).disabled(characterRange == nil || !(useColor || useFont || useSize || useOutline || useOutlineColor || useOutlineWidth))}
        }.padding(20).frame(minWidth:540)
    }
}
