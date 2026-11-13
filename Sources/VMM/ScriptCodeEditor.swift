import SwiftUI
import AppKit

struct ScriptCodeEditor:NSViewRepresentable {
    @Binding var source:String
    var errorLine:Int?
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeNSView(context:Context)->NSScrollView {
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true
        scroll.borderType = .bezelBorder
        let text=NSTextView(frame:NSRect(x:0,y:0,width:700,height:260))
        text.isRichText=false;text.allowsUndo=true;text.isAutomaticQuoteSubstitutionEnabled=false
        text.isAutomaticDashSubstitutionEnabled=false;text.isAutomaticTextReplacementEnabled=false
        text.isAutomaticSpellingCorrectionEnabled=false;text.isContinuousSpellCheckingEnabled=false
        text.font = .monospacedSystemFont(ofSize:13,weight:.regular)
        text.backgroundColor = .textBackgroundColor;text.textColor = .textColor
        text.textContainerInset=NSSize(width:8,height:8)
        text.isHorizontallyResizable=true;text.isVerticallyResizable=true
        text.minSize=NSSize(width:0,height:260);text.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        text.textContainer?.containerSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView=false
        text.delegate=context.coordinator;text.setAccessibilityLabel(L("JavaScriptコード"))
        scroll.documentView=text
        scroll.verticalRulerView=ScriptLineRuler(scrollView:scroll,orientation:.verticalRuler)
        scroll.hasVerticalRuler=true;scroll.rulersVisible=true
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard let text=scroll.documentView as? NSTextView else{return}
        context.coordinator.parent=self;text.isEditable=enabled
        if text.string != source {
            text.string=source;text.undoManager?.removeAllActions()
        }
        context.coordinator.decorate(text)
        if let errorLine,context.coordinator.lastErrorLine != errorLine,let range=ScriptSourceLines.range(errorLine,in:source) {
            text.scrollRangeToVisible(range)
        }
        context.coordinator.lastErrorLine=errorLine
        scroll.verticalRulerView?.needsDisplay=true
    }
    final class Coordinator:NSObject,NSTextViewDelegate {
        var parent:ScriptCodeEditor
        var lastErrorLine:Int?
        init(_ parent:ScriptCodeEditor){self.parent=parent}
        func textDidChange(_ notification:Notification) {
            guard let text=notification.object as? NSTextView else{return}
            parent.source=text.string;decorate(text);text.enclosingScrollView?.verticalRulerView?.needsDisplay=true
        }
        func decorate(_ text:NSTextView) {
            guard let layout=text.layoutManager else{return}
            let entire=NSRange(location:0,length:(text.string as NSString).length)
            layout.removeTemporaryAttribute(.foregroundColor,forCharacterRange:entire)
            layout.removeTemporaryAttribute(.backgroundColor,forCharacterRange:entire)
            for (pattern,color) in [("\\b(function|const|let|var|return|if|else|throw|new|for|while|typeof|true|false|null|undefined)\\b",NSColor.systemPurple),("\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'",NSColor.systemGreen),("//[^\\n]*|/\\*[\\s\\S]*?\\*/",NSColor.secondaryLabelColor)] {
                guard let regex=try? NSRegularExpression(pattern:pattern) else{continue}
                for match in regex.matches(in:text.string,range:entire){layout.addTemporaryAttribute(.foregroundColor,value:color,forCharacterRange:match.range)}
            }
            if let line=parent.errorLine,let range=ScriptSourceLines.range(line,in:text.string) {
                layout.addTemporaryAttribute(.backgroundColor,value:NSColor.systemRed.withAlphaComponent(0.22),forCharacterRange:range)
            }
        }
    }
}

enum ScriptSourceLines {
    /// UTF-16 ranges match NSTextView, including Japanese text and emoji.
    static func range(_ line:Int,in source:String)->NSRange? {
        guard line>0 else{return nil}
        let text=source as NSString;var start=0,current=1
        while start<text.length {
            let range=text.lineRange(for:NSRange(location:start,length:0))
            if current==line{return range}
            start=NSMaxRange(range);current+=1
        }
        return current==line ? NSRange(location:text.length,length:0):nil
    }
}

private final class ScriptLineRuler:NSRulerView {
    override init(scrollView:NSScrollView?,orientation:NSRulerView.Orientation){super.init(scrollView:scrollView,orientation:orientation);ruleThickness=48}
    required init(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    override func drawHashMarksAndLabels(in rect:NSRect) {
        NSColor.windowBackgroundColor.setFill();bounds.fill()
        guard let text=scrollView?.documentView as? NSTextView,let layout=text.layoutManager,let container=text.textContainer else{return}
        let source=text.string as NSString;var index=0,line=1
        while index<source.length {
            let range=source.lineRange(for:NSRange(location:index,length:0))
            let glyph=layout.glyphRange(forCharacterRange:NSRange(location:index,length:1),actualCharacterRange:nil)
            let frame=layout.boundingRect(forGlyphRange:glyph,in:container)
            let position=convert(NSPoint(x:0,y:frame.minY+text.textContainerOrigin.y),from:text)
            if position.y>bounds.maxY{break}
            if position.y+frame.height>=bounds.minY{draw(line,at:position.y)}
            index=NSMaxRange(range);line+=1
        }
        if source.length==0 || source.hasSuffix("\n") {
            let position=convert(NSPoint(x:0,y:layout.extraLineFragmentRect.minY+text.textContainerOrigin.y),from:text)
            draw(line,at:position.y)
        }
    }
    private func draw(_ line:Int,at y:CGFloat) {
        let label=String(line) as NSString
        let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedSystemFont(ofSize:11,weight:.regular),.foregroundColor:NSColor.secondaryLabelColor]
        label.draw(at:NSPoint(x:ruleThickness-label.size(withAttributes:attributes).width-8,y:y),withAttributes:attributes)
    }
}
