import SwiftUI
import AppKit

struct VMMChoice<Value> {let text:String;let value:Value}
@resultBuilder enum VMMChoicesBuilder<Value> {
    static func buildExpression(_ choice:VMMChoice<Value>)->[VMMChoice<Value>] {[choice]}
    static func buildExpression(_ choices:[VMMChoice<Value>])->[VMMChoice<Value>] {choices}
    static func buildBlock(_ parts:[VMMChoice<Value>]...)->[VMMChoice<Value>] {parts.flatMap{$0}}
    static func buildOptional(_ choices:[VMMChoice<Value>]?)->[VMMChoice<Value>] {choices ?? []}
    static func buildEither(first:[VMMChoice<Value>])->[VMMChoice<Value>] {first}
    static func buildEither(second:[VMMChoice<Value>])->[VMMChoice<Value>] {second}
}
func VMMOptions<C:Collection,V>(_ data:C,@VMMChoicesBuilder<V> content:(C.Element)->[VMMChoice<V>])->[VMMChoice<V>] {data.flatMap(content)}
func VMMOptions<C:Collection,V,ID>(_ data:C,id:KeyPath<C.Element,ID>,@VMMChoicesBuilder<V> content:(C.Element)->[VMMChoice<V>])->[VMMChoice<V>] {data.flatMap(content)}

struct VMMMenuPicker<Value:Hashable>:View {
    @Environment(\.vmmTextSize) private var points
    let title:String
    let selection:Binding<Value>
    let choices:[VMMChoice<Value>]
    private var hideLabel=false
    init(_ title:String,selection:Binding<Value>,@VMMChoicesBuilder<Value> content:()->[VMMChoice<Value>]) {self.title=title;self.selection=selection;self.choices=content()}
    func labelsHidden()->Self {var result=self;result.hideLabel=true;return result}
    var body:some View {
        HStack {
            if !hideLabel {Text(title).vmmFont()}
            NativeMenuPicker(title:title,selection:selection,choices:choices,points:points)
                .frame(minWidth:50,minHeight:max(24,points*1.6),maxHeight:max(24,points*1.6))
        }
    }
}
private struct NativeMenuPicker<Value:Hashable>:NSViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    let title:String
    let selection:Binding<Value>
    let choices:[VMMChoice<Value>]
    let points:Double
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeNSView(context:Context)->NSPopUpButton {
        let button=NSPopUpButton(frame:.zero,pullsDown:false)
        button.target=context.coordinator;button.action=#selector(Coordinator.choose(_:))
        button.setContentHuggingPriority(.defaultLow,for:.horizontal)
        button.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        button.cell?.lineBreakMode = .byTruncatingTail
        return button
    }
    func updateNSView(_ button:NSPopUpButton,context:Context) {
        context.coordinator.parent=self
        if button.itemTitles != choices.map(\.text) {
            button.removeAllItems()
            for choice in choices {button.menu?.addItem(NSMenuItem(title:choice.text,action:nil,keyEquivalent:""))}
        }
        // NSPopUpButton needs distinct menu items even for duplicate display names.
        let font=NSFont.systemFont(ofSize:points)
        if button.font != font {button.font=font;button.invalidateIntrinsicContentSize()}
        button.menu?.font=font
        button.controlSize=points>14 ? .large:.regular
        button.isEnabled=enabled && !choices.isEmpty
        button.setAccessibilityLabel(title)
        if let index=choices.firstIndex(where:{$0.value==selection.wrappedValue}) {button.selectItem(at:index)} else {button.select(nil)}
    }
    final class Coordinator:NSObject {
        var parent:NativeMenuPicker
        init(_ parent:NativeMenuPicker) {self.parent=parent}
        @objc func choose(_ button:NSPopUpButton) {let index=button.indexOfSelectedItem;guard parent.choices.indices.contains(index) else {return};parent.selection.wrappedValue=parent.choices[index].value}
    }
}
