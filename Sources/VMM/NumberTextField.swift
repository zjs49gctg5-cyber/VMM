import SwiftUI
import AppKit

/// Commit an active field before an action snapshots the current settings.
@MainActor func commitActiveFieldEditing() {
    NSApp.keyWindow?.makeFirstResponder(nil)
}

/// Handle arrows in the field editor, where SwiftUI move commands are consumed.
struct NumberTextField:NSViewRepresentable {
    @Binding var value:Double
    let formatter:NumberFormatter
    let range:ClosedRange<Double>
    let title:String
    let points:Double
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeNSView(context:Context)->NSTextField {
        let field=NSTextField();field.isEditable=true;field.isSelectable=true
        field.isBezeled=true;field.bezelStyle = .roundedBezel;field.alignment = .right
        field.delegate=context.coordinator;field.setAccessibilityLabel(title)
        field.setContentHuggingPriority(.defaultLow,for:.horizontal)
        return field
    }
    func updateNSView(_ field:NSTextField,context:Context){
        let coordinator=context.coordinator;coordinator.parent=self
        field.font = .systemFont(ofSize:points);field.isEnabled=enabled;field.setAccessibilityLabel(title)
        // Preserve unfinished text while typing, but reflect external changes
        // such as the stepper or selecting a different item.
        if field.currentEditor()==nil || coordinator.lastValue != value {
            field.stringValue=formatter.string(from:NSNumber(value:value)) ?? "\(value)"
            field.currentEditor()?.string=field.stringValue
        }
        coordinator.lastValue=value
    }
    final class Coordinator:NSObject,NSTextFieldDelegate {
        var parent:NumberTextField;var lastValue:Double?
        init(_ parent:NumberTextField){self.parent=parent}
        private func commit(_ field:NSTextField,delta:Double=0){
            let text=field.currentEditor()?.string ?? field.stringValue
            let entered=parent.formatter.number(from:text)?.doubleValue ?? parent.value
            guard entered.isFinite else{return}
            let value=min(parent.range.upperBound,max(parent.range.lowerBound,entered+delta))
            parent.value=value;lastValue=value
            field.stringValue=parent.formatter.string(from:NSNumber(value:value)) ?? "\(value)"
            if let editor=field.currentEditor() as? NSTextView {editor.string=field.stringValue;editor.setSelectedRange(NSRange(location:0,length:(editor.string as NSString).length))}
        }
        func controlTextDidEndEditing(_ notification:Notification){if let field=notification.object as? NSTextField{commit(field)}}
        func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector)->Bool {
            guard let field=control as? NSTextField,field.isEnabled else{return false}
            if selector == #selector(NSResponder.moveUp(_:)){commit(field,delta:1);return true}
            if selector == #selector(NSResponder.moveDown(_:)){commit(field,delta:-1);return true}
            if selector == #selector(NSResponder.insertNewline(_:)){commit(field);return true}
            return false
        }
    }
}
