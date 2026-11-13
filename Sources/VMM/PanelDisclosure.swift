import SwiftUI

/// The entire panel heading is a button, including its trailing empty space.
struct PanelDisclosure<Content:View>:View {
    let title:String
    private let external:Binding<Bool>?
    @State private var local=false
    let content:Content
    init(_ title:String,isExpanded:Binding<Bool>? = nil,@ViewBuilder content:()->Content) {
        self.title=title;self.external=isExpanded;self.content=content()
    }
    private var expanded:Binding<Bool> {external ?? $local}
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Button {expanded.wrappedValue.toggle()} label:{
                HStack(spacing:6) {
                    Image(systemName:expanded.wrappedValue ? "chevron.down":"chevron.right").foregroundColor(.secondary)
                    Text(L(title))
                    Spacer(minLength:0)
                }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(expanded.wrappedValue ? "展開":"折りたたみ")
            if expanded.wrappedValue {content.padding(.leading,14)}
        }
    }
}
