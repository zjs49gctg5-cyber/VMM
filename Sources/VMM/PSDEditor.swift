import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension EditorStore {
    nonisolated static func importPSD(_ url: URL, into target: URL) throws -> [MediaAsset] {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 512_000_000 else { throw VMMError.message("PSD/ZIPは512MB以内にしてください。") }
        let data = try Data(contentsOf: url)
        let entries = url.pathExtension.lowercased() == "zip" ? try PSDZip.read(data) : [PSDZip.Entry(name: url.lastPathComponent, data: data)]
        let psds = entries.filter { $0.name.lowercased().hasSuffix(".psd") }
        guard !psds.isEmpty else { throw VMMError.message("ZIP内にPSDファイルがありません。") }
        let readme = entries.filter { $0.name.lowercased().hasSuffix(".txt") }.compactMap { String(data: $0.data, encoding: .utf8) ?? String(data: $0.data, encoding: .shiftJIS) }.joined(separator: "\n\n")
        let favorites = try entries.filter { $0.name.lowercased().hasSuffix(".pfv") }.flatMap { entry -> [PSDFavorite] in
            guard let text = String(data: entry.data, encoding: .utf8) else { throw VMMError.message("PFVはUTF-8で保存してください。") }
            return try PFV.read(text)
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("vmm-psd-\(UUID())")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var assets: [MediaAsset] = []
        for entry in psds {
            var document = try PSDImporter.importFile(data: entry.data, mediaDirectory: staging, readme: readme.isEmpty ? nil : readme)
            document.favorites = favorites.filter { favorite in (favorite.paths + favorite.filters.flatMap { $0 }).allSatisfy { document.resolve($0) != nil } }
            try document.validate()
            let filename = "\(UUID()).psd"
            try entry.data.write(to: staging.appendingPathComponent(filename))
            assets.append(MediaAsset(name: entry.name, file: filename, kind: .image, duration: 5, psd: document))
        }
        var written: [URL] = []
        do {
            for asset in assets { for file in asset.files {
                let destination = target.appendingPathComponent(file)
                try FileManager.default.copyItem(at: staging.appendingPathComponent(file), to: destination); written.append(destination)
            } }
        } catch { for file in written { try? FileManager.default.removeItem(at: file) }; throw error }
        return assets
    }
    func psdBinding<T>(_ key: WritableKeyPath<PSDState, T>, default fallback: T) -> Binding<T> {
        Binding(get: { self.selected?.psd?[keyPath: key] ?? fallback }, set: { value in
            guard let id = self.selectedID else { return }
            self.edit(id) { $0.psd?[keyPath: key] = value }
        })
    }
    func importPFV() {
        guard let clip = selected, let document = project.asset(for: clip)?.psd else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "pfv") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let favorites = try PFV.read(String(contentsOf: url, encoding: .utf8))
            for favorite in favorites { _ = try document.applying(favorite, to: clip.psd?.selected ?? document.defaults) }
            edit(clip.id) { $0.psd?.favorites.append(contentsOf: favorites) }
            status = "\(favorites.count)個のPSDToolお気に入りを読み込みました。"
        } catch { self.error = error.localizedDescription }
    }
    func applyFavorite(_ favorite: PSDFavorite) {
        guard let clip = selected, let document = project.asset(for: clip)?.psd else { return }
        do {
            let selection = try document.applying(favorite, to: clip.psd?.selected ?? document.defaults)
            edit(clip.id) { $0.psd?.selected = selection }
        } catch { self.error = error.localizedDescription }
    }
    func rememberExpression() {
        guard let clip = selected, let document = project.asset(for: clip)?.psd, let state = clip.psd else { return }
        let alert = NSAlert(); alert.messageText = "表情を保存"
        let field = NSTextField(string: "表情 \(state.favorites.count + 1)"); field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let favorite = PSDFavorite(name: field.stringValue.isEmpty ? "表情" : field.stringValue,
                                   paths: document.layers.filter { document.isVisible($0.id, in: Set(state.selected)) && !document.isFlipVariant($0) }.map { document.path(for: $0.id) })
        edit(clip.id) { $0.psd?.favorites.append(favorite) }
    }
    func exportPFV() {
        guard let clip = selected, let document = project.asset(for: clip)?.psd, let state = clip.psd else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "表情.pfv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let favorites = state.favorites.isEmpty ? [PSDFavorite(name: "現在の表情", paths: document.layers.filter { document.isVisible($0.id, in: Set(state.selected)) && !document.isFlipVariant($0) }.map { document.path(for: $0.id) })] : state.favorites
        do { try PFV.write(favorites).write(to: url, atomically: true, encoding: .utf8); status = "PSDTool互換PFVを書き出しました。" }
        catch { self.error = error.localizedDescription }
    }
}

struct PSDInspectorView: View {
    @ObservedObject var store: EditorStore
    var clip: Clip
    var document: PSDDocument
    @State private var search = ""
    @State private var layersExpanded = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("PSDTool互換レイヤー")).vmmFont(size:12, weight: .semibold).foregroundColor(.mint)
            HStack {
                Toggle(L("左右反転"), isOn: store.psdBinding(\.flipX, default: false))
                Toggle(L("上下反転"), isOn: store.psdBinding(\.flipY, default: false))
            }
            PanelDisclosure(L("表情・PFVお気に入り")) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Button(L("PFV読込")) { store.importPFV() }; Button(L("PFV出力")) { store.exportPFV() } }
                    Button(L("現在の表情を登録")) { store.rememberExpression() }
                    ForEach(clip.psd?.favorites ?? []) { favorite in
                        Button(favorite.name) { store.applyFavorite(favorite) }.lineLimit(2)
                    }
                }.padding(.top, 7)
            }
            PanelDisclosure("レイヤー選択（\(document.layers.count)）", isExpanded: $layersExpanded) {
                VStack(alignment: .leading, spacing: 5) {
                    TextField(L("レイヤーを検索"), text: $search).textFieldStyle(.roundedBorder)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(document.layers.filter { !document.isFlipVariant($0) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }) { layer in
                                HStack(spacing: 5) {
                                    if layer.forced {
                                        UIIcon(systemName: layer.group ? "folder.fill" : "lock.fill").foregroundColor(.secondary).frame(width: 14)
                                    } else {
                                        Button(action: {
                                            let current = clip.psd?.selected ?? document.defaults
                                            let selection = document.selecting(layer.id, enabled: layer.radio || !current.contains(layer.id), in: current)
                                            store.edit(clip.id) { $0.psd?.selected = selection }
                                        }) {
                                            UIIcon(systemName: layer.radio ? ((clip.psd?.selected.contains(layer.id) ?? false) ? "largecircle.fill.circle" : "circle") : ((clip.psd?.selected.contains(layer.id) ?? false) ? "checkmark.square.fill" : "square"))
                                        }.buttonStyle(.borderless).frame(width: 14)
                                    }
                                    Text(layer.label).fontWeight(layer.group ? .semibold : .regular).lineLimit(1)
                                }.padding(.leading, CGFloat(min(6, document.depth(layer))) * 10)
                                    .opacity(document.isVisible(layer.parent ?? layer.id, in: Set(clip.psd?.selected ?? document.defaults)) ? 1 : 0.5)
                            }
                        }
                    }.frame(height: 210)
                }.padding(.top, 7)
            }
            Divider()
            Toggle(L("音声エンジンで口パク"), isOn: store.psdBinding(\.mouthAnimation, default: false))
            VMMMenuPicker(L("話者"), selection:Binding(get:{clip.characterSpeakerID},set:{v in store.edit(clip.id){$0.characterSpeakerID=v;$0.characterSpeechEngine=store.speechConfiguration.engine}})) {
                VMMChoice(text:L("なし"),value:Optional<Int>.none)
                VMMOptions(store.voices) { VMMChoice(text:$0.name,value:Optional($0.id)) }
                if let id = clip.characterSpeakerID, !store.voices.contains(where: { $0.id == id }) { VMMChoice(text:"\(L("話者")) \(id)",value:Optional(id)) }
            }
            if store.voices.isEmpty { Button(L("音声エンジンに接続")) { store.connectVoicevox() } }
            layerPicker(L("閉じ口"), key: \.mouthClosed)
            layerPicker(L("開き口"), key: \.mouthOpen)
            Toggle(L("母音に合わせて口を切り替える"),isOn:Binding(get:{clip.psd?.vowelAnimation ?? false},set:{value in store.edit(clip.id){$0.psd?.vowelAnimation=value}})).disabled(clip.psd?.mouthAnimation != true)
            if clip.psd?.vowelAnimation == true {
                ForEach(MouthVowel.allCases,id:\.rawValue) {vowel in
                    VMMMenuPicker("\(L("母音")) \(vowel.title)",selection:Binding<Int?>(get:{clip.psd?.vowelLayers?[vowel.rawValue]},set:{value in store.edit(clip.id){c in var mappings=c.psd?.vowelLayers ?? [:];mappings[vowel.rawValue]=value;c.psd?.vowelLayers=mappings.isEmpty ? nil:mappings}})) {
                        VMMChoice(text:L("なし"),value:Optional<Int>.none)
                        VMMOptions(document.layers.filter{!$0.group && !document.isFlipVariant($0)}) {layer in
                            let parent=layer.parent.flatMap{id in document.layers.first{$0.id==id}?.label} ?? ""
                            VMMChoice(text:parent.isEmpty ? layer.label:"\(parent) / \(layer.label)",value:Optional(layer.id))
                        }
                    }
                }
                Text(L("VOICEVOXの音声生成時の音素情報から推定します。旧音声や他エンジンでは従来の音量開閉を使用します。" )).vmmFont(size:12).foregroundColor(.secondary)
            }
            Toggle(L("自動目パチ"), isOn: store.psdBinding(\.blink, default: false))
            layerPicker(L("閉じ目"), key: \.eyeClosed)
            NumberInput(title: "目パチの間隔", value: store.psdBinding(\.blinkInterval, default: 3), range: 0.5...10, step: 0.1, unit: "秒")
            Text(L("口・目は同じグループ内で切り替えます。自動口パクは口の表情キーフレームより優先し、目パチは独立して動きます。"))
                .vmmFont(size:12).foregroundColor(.secondary)
            if let readme = document.readme {
                PanelDisclosure(L("素材のreadme")) { Text(readme).vmmFont(size:12).textSelection(.enabled) }
            }
        }
    }
    private func layerPicker(_ title: String, key: WritableKeyPath<PSDState, Int?>) -> some View {
        VMMMenuPicker(title, selection: store.psdBinding(key, default: nil)) {
            VMMChoice(text:L("なし"),value:Optional<Int>.none)
            VMMOptions(document.layers.filter { !$0.group && !document.isFlipVariant($0) }) { layer in
                let parent = layer.parent.flatMap { id in document.layers.first { $0.id == id }?.label } ?? ""
                VMMChoice(text:"\(parent) / \(layer.label)",value:Optional(layer.id))
            }
        }
    }
}
