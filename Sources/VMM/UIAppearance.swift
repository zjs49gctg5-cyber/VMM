import SwiftUI

private struct UITextSizeKey:EnvironmentKey {static let defaultValue:Double=12}
private struct UIIconSizeKey:EnvironmentKey {static let defaultValue:Double=12}
extension EnvironmentValues {
    var vmmTextSize:Double {get{self[UITextSizeKey.self]}set{self[UITextSizeKey.self]=newValue}}
    var vmmIconSize:Double {get{self[UIIconSizeKey.self]}set{self[UIIconSizeKey.self]=newValue}}
}
extension UserSettings {
    var toolbarMode:ToolbarDisplayMode {toolbarDisplayMode ?? (toolbarLabels ?? true ? .iconsAndLabels:.iconsOnly)}
    var textPoints:Double {(uiFontSize ?? 12)*uiScale}
    var iconPoints:Double {(uiIconSize ?? 12)*uiScale}
    var panelScale:Double {max(1,max(textPoints,iconPoints)/12)}
}
private struct UIFontModifier:ViewModifier {
    @Environment(\.vmmTextSize) private var points
    let size:Double;let weight:Font.Weight;let design:Font.Design
    func body(content:Content)->some View {content.font(.system(size:max(12,size)/12*points,weight:weight,design:design))}
}
struct UIIcon:View {
    @Environment(\.vmmIconSize) private var points
    let systemName:String
    var size:Double=12
    var body:some View {Image(systemName:systemName).font(.system(size:max(12,size)/12*points))}
}
private struct UILabelStyle:LabelStyle {
    @Environment(\.vmmIconSize) private var points
    func makeBody(configuration:Configuration)->some View {HStack(spacing:6){configuration.icon.font(.system(size:points));configuration.title}}
}
extension View {
    func vmmFont(size:Double=12,weight:Font.Weight = .regular,design:Font.Design = .default)->some View {modifier(UIFontModifier(size:size,weight:weight,design:design))}
    func vmmAppearance(_ settings:UserSettings)->some View {
        environment(\.locale,Locale(identifier:(settings.uiLanguage ?? .japanese).rawValue)).environment(\.vmmTextSize,settings.textPoints).environment(\.vmmIconSize,settings.iconPoints)
            .font(.system(size:settings.textPoints)).labelStyle(UILabelStyle())
            .controlSize(settings.textPoints > 14 ? .large : .regular)
    }
}
