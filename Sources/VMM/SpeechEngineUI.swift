import SwiftUI

struct SpeechConnectionControls:View {
    @ObservedObject var store:EditorStore
    @State private var endpoint=""
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            VMMMenuPicker(L("音声エンジン"),selection:Binding(get:{store.speechConfiguration.engine},set:{store.updateSpeechConnection(.defaults($0));endpoint=$0.defaultURL})) {
                VMMOptions(SpeechEngine.allCases){VMMChoice(text:$0.title,value:$0)}
            }
            HStack {
                TextField(L("接続先URL"),text:$endpoint).textFieldStyle(.roundedBorder)
                Button(L("接続")) {var c=store.speechConfiguration;c.endpoint=endpoint;store.updateSpeechConnection(c);if store.speechConfiguration==c {store.connectVoicevox()}}
            }
            Text(L("エンジンを先に起動してください。Qwen3-TTSは付属のローカル接続スクリプトを使用します。")).foregroundColor(.secondary)
        }.onAppear{endpoint=store.speechConfiguration.endpoint}.onChange(of:store.speechConfiguration.endpoint){endpoint=$0}
    }
}
struct SpeechClipOptions:View {
    @ObservedObject var store:EditorStore;let clip:Clip
    var configuration:SpeechConfiguration {clip.speechConfiguration ?? .defaults(.voicevox)}
    var body:some View {
        if configuration.engine == .styleBertVITS2 || configuration.engine == .qwen3TTS {
            VMMMenuPicker(L("読み上げ言語"),selection:Binding(get:{configuration.language ?? (configuration.engine == .styleBertVITS2 ? "JP":"Japanese")},set:{v in store.edit(clip.id){var c=configuration;c.language=v;$0.speechConfiguration=c}})) {
                if configuration.engine == .styleBertVITS2 {VMMChoice(text:L("日本語 / Japanese"),value:"JP");VMMChoice(text:"English",value:"EN")}
                else {VMMChoice(text:L("日本語 / Japanese"),value:"Japanese");VMMChoice(text:"English",value:"English");VMMChoice(text:"Auto",value:"Auto")}
            }
        }
        if configuration.engine == .qwen3TTS {
            TextField(L("声の指示（任意）"),text:Binding(get:{configuration.instruction ?? ""},set:{v in store.edit(clip.id){var c=configuration;c.instruction=v;$0.speechConfiguration=c}})).textFieldStyle(.roundedBorder)
        }
        if configuration.engine != store.speechConfiguration.engine {Text(L("このセリフのエンジンと接続中のエンジンが異なります。話者を選び直すと変更できます。")).foregroundColor(.secondary)}
    }
}
