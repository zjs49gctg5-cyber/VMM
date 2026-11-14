import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let panelColor = Color(nsColor: .windowBackgroundColor)
private let lineColor = Color.primary.opacity(0.12)
private let accent = Color.accentColor

extension ClipKind {
    var tint: Color {
        switch self {
        case .text: return Color(red: 0.38, green: 0.57, blue: 0.95)
        case .speech: return Color(red: 0.6, green: 0.47, blue: 0.9)
        case .image: return Color(red: 0.26, green: 0.7, blue: 0.63)
        case .video: return Color(red: 0.22, green: 0.61, blue: 0.76)
        case .audio: return Color(red: 0.8, green: 0.61, blue: 0.3)
        case .shape: return Color(red: 0.55, green: 0.59, blue: 0.68)
        case .group: return .purple
        case .particles: return .orange
        case .adjustment: return .pink
        case .transition: return Color(red: 0.95, green: 0.45, blue: 0.5)
        }
    }
}

struct EditorView: View {
    @ObservedObject var store: EditorStore
    var showToolbar=true
    var body: some View {
        VStack(spacing: 0) {
            if showToolbar && !EditorPanel.preview.isDetached(in:store.settings){EditorToolbar(store:store);Divider()}
            VSplitView {
            if EditorPanel.embeddedTopPanels(in:store.settings) {
                HSplitView {
                    if store.settings.showInspector && store.settings.inspectorLeft && !EditorPanel.inspector.isDetached(in:store.settings) {InspectorView(store:store).frame(minWidth:250*store.settings.panelScale,idealWidth:276*store.settings.panelScale,maxWidth:.infinity)}
                    if store.settings.showLibrary && !EditorPanel.library.isDetached(in:store.settings) {MediaLibraryPanel(store:store).background(EditorSplitDividerStyle()).frame(minWidth:190*store.settings.panelScale,idealWidth:218*store.settings.panelScale,maxWidth:.infinity)}
                    if !EditorPanel.preview.isDetached(in:store.settings) {PreviewPanel(store:store).background(EditorSplitDividerStyle()).frame(minWidth:380,maxWidth:.infinity)}
                    if store.settings.showInspector && !store.settings.inspectorLeft && !EditorPanel.inspector.isDetached(in:store.settings) {InspectorView(store:store).frame(minWidth:250*store.settings.panelScale,idealWidth:276*store.settings.panelScale,maxWidth:.infinity)}
                }.frame(minHeight:300,maxHeight:.infinity)
            }
            if !EditorPanel.timeline.isDetached(in:store.settings) {
                TimelinePanel(store:store).frame(minHeight:160,idealHeight:285)
            }
            if store.showAnimationPanel && !EditorPanel.animation.isDetached(in:store.settings) {
                AnimationWorkspace(store:store,onClose:{store.showAnimationPanel=false}).frame(minHeight:240,idealHeight:320)
            }
            if (!store.showAnimationPanel || EditorPanel.animation.isDetached(in:store.settings)) && !EditorPanel.embeddedTopPanels(in:store.settings) && EditorPanel.timeline.isDetached(in:store.settings) {
                VStack(spacing:16) {
                    Text(L("編集パネルは独立ウィンドウで表示しています。"))
                    Button(L("ワークスペース設定…")){store.workspaceWindows.show(.workspaceSettings)}
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }
            }
            Divider()
            HStack(spacing: 8) {
                Circle().fill(store.busy ? Color.orange : accent).frame(width: 5, height: 5)
                Text(L(store.status)).lineLimit(1)
                Spacer()
                Text("\(store.project.width) × \(store.project.height)  /  \(store.project.fps) fps").monospacedDigit()
                Text("VMM " + AppVersion.current.fullDisplay).foregroundColor(.secondary).help(L("設定の一般タブでもバージョンを確認できます。"))
            }.vmmFont(size:12).padding(.horizontal, 16).frame(height:max(28,store.settings.textPoints*2.3)).background(panelColor)
        }
        .vmmAppearance(store.settings)
        .background(Color(nsColor: .windowBackgroundColor))
        .foregroundColor(.primary)
        .tint(accent)
        .alert(L("確認してください"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(L(store.error ?? "")) }
        .overlay {
            if let progress=store.projectIOProgress {
                ZStack {Color.black.opacity(0.6);VStack(spacing:18){Text(L(store.status));ProgressView(value:progress).frame(width:320)}.padding(28).background(panelColor).cornerRadius(14)}
            } else if let progress = store.exportProgress {
                ZStack {
                    Color.black.opacity(0.6)
                    VStack(alignment: .leading, spacing: 18) {
                        Label(L(store.exportPhase?.title ?? store.status), systemImage: "film").vmmFont(size:14,weight:.semibold)
                        ProgressView(value: progress).frame(width: 320)
                        HStack {
                            Text("\(Int(progress * 100))%  •  \(store.settings.exportContainer) / \(store.settings.exportCodec)").vmmFont().monospacedDigit()
                            Spacer()
                            Button(L("中止")) { store.cancelExport() }
                        }
                    }.padding(28).background(panelColor).cornerRadius(14)
                }
            }
        }
    }
}

// SwiftUI's default one-point divider is easy to miss. Give the native split view
// a visible, wider resize target without replacing its built-in drag behaviour.
private struct EditorSplitDividerStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> DividerProbe { DividerProbe() }
    func updateNSView(_ view: DividerProbe, context: Context) { view.configure() }

    final class DividerProbe: NSView {
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); configure() }
        func configure() {
            DispatchQueue.main.async { [weak self] in
                var ancestor = self?.superview
                while let view = ancestor {
                    if let split = view as? NSSplitView, split.isVertical {
                        if split.dividerStyle != .thick { split.dividerStyle = .thick }
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
    }
}

struct EditorToolbar:View {
    @ObservedObject var store:EditorStore
    @State private var showSettingsMenu=false
    var body: some View {
        GeometryReader { geometry in
        ScrollView(.horizontal,showsIndicators:true) {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                UIIcon(systemName: "play.rectangle.fill",size:21).vmmFont(size:21).foregroundColor(accent)
                Text("VMM").vmmFont(size:17, weight: .heavy, design: .rounded)
            }
            Rectangle().fill(lineColor).frame(width: 1, height: 22)
            Button(action: { store.newProject() }) { toolbarLabel("新規",symbol:"doc.badge.plus") }.help(L("新規プロジェクト ⌘N"))
            Button(action: { store.openProject() }) { toolbarLabel("開く",symbol:"folder") }.help(L("開く ⌘O"))
            Button(action: { store.requestSave() }) { toolbarLabel("保存",symbol:"square.and.arrow.down") }.help(L("保存 ⌘S"))
            Button {store.toggleAnimationPanel()} label:{toolbarLabel("アニメーション",symbol:"diamond.fill")}.help(L(EditorPanel.animation.isDetached(in:store.settings) ? "アニメーション編集を前面に表示":"アニメーション編集を表示 / 非表示"))
            Button {store.workspaceWindows.show(.mad)} label:{toolbarLabel("音MAD",symbol:"waveform")}.help(L("音MADモード"))
            Button {store.workspaceWindows.show(.script)} label:{toolbarLabel("セリフ制作",symbol:"list.bullet.rectangle")}.help(L("台本・キャラ・発音辞書"))
            Button {store.workspaceWindows.show(.library)} label:{toolbarLabel("共有ライブラリ",symbol:"books.vertical")}.help(L("共有ライブラリ"))
            Button {showSettingsMenu.toggle()} label:{toolbarLabel("設定",symbol:"gearshape")}
                .help(L("設定"))
                .popover(isPresented:$showSettingsMenu,arrowEdge:.bottom) {
                    VStack(alignment:.leading,spacing:8) {
                        Button(L("アプリの設定…")){showSettingsMenu=false;store.workspaceWindows.show(.settings)}
                        Button(L("ワークスペース設定…")){showSettingsMenu=false;store.workspaceWindows.show(.workspaceSettings)}
                        Button(L("書き出し設定…")){showSettingsMenu=false;store.workspaceWindows.show(.export)}
                    }.frame(minWidth:180,alignment:.leading).padding(12).vmmAppearance(store.settings)
                }
            Spacer()
            Button(action: { store.connectVoicevox() }) {
                HStack(spacing: 6) {
                    Circle().fill(store.voiceState == "接続済み" ? Color.green : Color.gray).frame(width: 6, height: 6)
                    Text("\(store.speechConfiguration.engine.title)  \(L(store.voiceState))").vmmFont(size:12)
                }
            }.help(L("選択した音声エンジンを起動してクリック"))
            Button(action: { store.workspaceWindows.show(.export) }) {
                Label(L("動画を書き出す"), systemImage: "square.and.arrow.up").vmmFont(size:12, weight: .semibold).padding(.horizontal, 6).padding(.vertical,6)
            }.buttonStyle(.borderedProminent).disabled(store.project.clips.isEmpty)
        }.buttonStyle(.borderless)
            .frame(minWidth:max(0,geometry.size.width-36),alignment:.leading).fixedSize(horizontal:true,vertical:false).padding(.horizontal,18)
            .frame(height:toolbarHeight)
        }
        }.frame(height:toolbarHeight).background(panelColor).disabled(store.busy)
    }
    private var toolbarHeight:Double {max(56,(store.settings.toolbarMode == .labelsOnly ? 0:store.settings.iconPoints*(store.settings.toolbarIconScale ?? 1.75))+(store.settings.toolbarMode == .iconsOnly ? 0:store.settings.textPoints*1.4)+18)}
    private func toolbarLabel(_ title:String,symbol:String)->some View {
        VStack(spacing:3){
            if store.settings.toolbarMode != .labelsOnly {ToolbarSymbol(systemName:symbol,points:store.settings.iconPoints*(store.settings.toolbarIconScale ?? 1.75))}
            if store.settings.toolbarMode != .iconsOnly {Text(L(title)).vmmFont().lineLimit(1).fixedSize(horizontal:true,vertical:false)}
        }.padding(.horizontal,3).accessibilityElement(children:.ignore).accessibilityLabel(L(title))
    }
}

struct MediaLibraryPanel:View {
    @ObservedObject var store:EditorStore
    @State private var libraryDropTarget=false
    @State private var showProjectSettings=false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing:8) {
                Text(L("素材ライブラリ")).vmmFont(size:12,weight:.semibold).lineLimit(1)
                Spacer(minLength:0)
                Button(action:{store.importMedia()}) {ViewThatFits(in:.horizontal){Label(L("読み込む"),systemImage:"plus").fixedSize();UIIcon(systemName:"plus")}}
                    .help(MediaProbe.description).accessibilityLabel(L("素材を読み込む"))
            }.padding(.horizontal,12).frame(minHeight:max(42,store.settings.textPoints*2.5))
            MediaLibraryBrowser(store:store)
            Divider()
            PanelDisclosure(L("プロジェクト設定"),isExpanded:$showProjectSettings) {
                VStack(alignment: .leading, spacing: 12) {
                if store.editingPrecompositionID==nil {RhythmProjectControls(store:store);AudioMasterControls(store:store)}
                VMMMenuPicker(L("サイズ"), selection: Binding(get: { "\(store.project.width)x\(store.project.height)" }, set: { value in
                    let dimensions = value.split(separator: "x").compactMap { Int($0) }
                    if dimensions.count == 2 { store.pause(); store.checkpoint(); store.project.width = dimensions[0]; store.project.height = dimensions[1] }
                })) {
                    VMMChoice(text:"3840 × 2160",value:"3840x2160")
                    VMMChoice(text:"2560 × 1440",value:"2560x1440")
                    VMMChoice(text:"1920 × 1080",value:"1920x1080")
                    VMMChoice(text:"1280 × 720",value:"1280x720")
                    VMMChoice(text:L("1080 × 1920（縦）"),value:"1080x1920")
                }.vmmFont(size:12)
                VMMMenuPicker("FPS", selection: Binding(get: { store.project.fps }, set: { store.pause(); store.checkpoint(); store.project.fps = $0 })) {
                    VMMChoice(text:"24",value:24); VMMChoice(text:"30",value:30); VMMChoice(text:"60",value:60)
                }.vmmFont(size:12)
                ColorPicker(L("背景色"), selection: Binding(get: { Color(nsColor: NSColor(hex: store.project.background)) }, set: { store.checkpoint(); store.project.background = NSColor($0).hex }), supportsOpacity: false).vmmFont(size:12)
                }.padding(.top,10)
            }.vmmFont(size:12,weight:.semibold).padding(14)
        }.background(panelColor).disabled(store.busy)
        .onDrop(of:[UTType.fileURL.identifier],isTargeted:$libraryDropTarget){store.acceptFinderProviders($0)}
        .overlay {if libraryDropTarget && !store.busy {RoundedRectangle(cornerRadius:8).stroke(accent,lineWidth:2).padding(3).allowsHitTesting(false)}}
    }
}

struct PreviewPanel:View {
    @ObservedObject var store:EditorStore
    @State private var showCamera=false
    var body:some View {PlaybackContent(clock:store.playbackClock){_ in previewContent}}
    private var previewContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("プレビュー")).vmmFont(size:12, weight: .medium)
                if store.editingPrecompositionID==nil {
                    Button {showCamera.toggle()} label:{Label(L("3Dカメラ"),systemImage:"camera.viewfinder")}
                        .buttonStyle(.borderless).help(L("3Dカメラの設定"))
                        .popover(isPresented:$showCamera,arrowEdge:.bottom) {
                            ScrollView {Camera3DControls(store:store).padding(16)}.frame(width:340,height:500).vmmAppearance(store.settings)
                        }
                }
                Spacer()
                if store.playing,let performance=store.previewPerformance {
                    Text(performance.label).foregroundColor(.secondary)
                        .help(performance.detail+" — "+L("再生時のみ画質を調整します。停止時と書き出しは全品質です。"))
                }
                Text("FIT").vmmFont(size:12, weight: .semibold, design: .monospaced).foregroundColor(.secondary)
            }.padding(.horizontal, 18).frame(height: 37)
            GeometryReader { geometry in
                let ratio = CGFloat(store.project.width) / CGFloat(store.project.height)
                let width = min(max(10, geometry.size.width - 36), max(10, geometry.size.height - 24) * ratio)
                PreviewCanvas(store: store)
                    .frame(width: width, height: width / ratio)
                    .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.12)))
                    .overlay(ObjectEditingOverlay(store:store))
                    .help(L("クリックで選択、ドラッグで移動。テキストをダブルクリックで編集。四隅・辺で伸縮、丸いハンドルで回転。Shiftで比率固定／15°刻み、Escで取消。"))
                    .overlay(AdjustmentRegionOverlay(store:store))
                    .overlay {if store.settings.safeArea {Rectangle().stroke(Color.yellow.opacity(0.7),style:StrokeStyle(lineWidth:1,dash:[5,5])).padding(EdgeInsets(top:width/ratio*0.05,leading:width*0.05,bottom:width/ratio*0.05,trailing:width*0.05)).allowsHitTesting(false)}}
                    .coordinateSpace(name:"effect-preview")
                    .shadow(color: .black.opacity(0.4), radius: 15, y: 5)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            ViewThatFits(in:.horizontal) {
                HStack(spacing:18) {playbackTime;Spacer();playbackButtons;Spacer();playbackDuration}
                VStack(spacing:8) {HStack{playbackTime;Spacer();playbackDuration};playbackButtons}
            }.buttonStyle(.borderless).padding(.horizontal,18).padding(.vertical,10).disabled(store.busy)
        }
    }
    private var playbackTime:some View {Text(timecode(store.playhead,fps:store.project.fps)).foregroundColor(accent).vmmFont(weight:.medium,design:.monospaced).lineLimit(1).fixedSize()}
    private var playbackDuration:some View {Text(timecode(store.project.duration,fps:store.project.fps)).vmmFont(design:.monospaced).foregroundColor(.secondary).lineLimit(1).fixedSize()}
    private var playbackButtons:some View {
        HStack(spacing:18) {
            Button(action:{store.seek(0)}){UIIcon(systemName:"backward.end.fill")}.help(L("先頭に戻る"))
            Button(action:{store.seek(store.playhead-1/Double(store.project.fps))}){UIIcon(systemName:"backward.frame.fill")}.help(L("1フレーム戻る"))
            Button(action:{store.togglePlayback()}){UIIcon(systemName:store.playing ? "pause.fill":"play.fill",size:17).foregroundColor(accent)}.help(L("再生 / 一時停止（Space）"))
            Button(action:{store.seek(store.playhead+1/Double(store.project.fps))}){UIIcon(systemName:"forward.frame.fill")}.help(L("1フレーム進む"))
        }.fixedSize()
    }
}

func sectionHeading(_ title: String, subtitle: String) -> some View {
    HStack {
        Text(L(title)).vmmFont(size:12, weight: .semibold)
        Spacer()
        Text(subtitle).vmmFont(size:12, weight: .medium, design: .monospaced).foregroundColor(.secondary)
    }.padding(.horizontal, 14).frame(height: 42)
}

struct InspectorView: View {
    @ObservedObject var store: EditorStore
    @State private var tab = 0
    var body: some View {
        VStack(spacing: 0) {
            sectionHeading("アイテムの設定", subtitle: "INSPECTOR")
            Divider()
            if let clip = store.selected {
                Picker(L("設定の種類"), selection: $tab) {
                    Text(L("基本")).vmmFont().tag(0); Text(L("アニメーション")).vmmFont().tag(1); Text(L("エフェクト")).vmmFont().tag(2)
                }.pickerStyle(.segmented).padding(10)
                ScrollView {
                    VStack(alignment: .leading, spacing: 17) {
                        HStack {
                            Label(clip.precompositionID == nil ? clip.kind.title:L("プリコンポジション"), systemImage: clip.kind.symbol).foregroundColor(clip.kind.tint)
                            Spacer()
                            if store.project.tracks[clip.track].locked { UIIcon(systemName: "lock.fill") }
                        }.vmmFont(size:12, weight: .semibold)
                        if tab == 0 {
                        TextField(L("名前"), text: store.binding(\.name, default: "")).textFieldStyle(.roundedBorder)
                        if clip.kind == .text || clip.kind == .speech {
                            VStack(alignment: .leading, spacing: 6) {
                                caption(L("セリフ / テキスト"))
                                TextEditor(text: store.binding(\.text, default: "")).vmmFont(size:12).frame(height: 82).padding(5).background(Color.primary.opacity(0.08)).cornerRadius(5)
                            }
                        }
                        if clip.precompositionID != nil {Button(L("プリコンポジションを編集…")){store.precompositionWindows.show(clip.id)};Button(L("独立したコピーにする")){store.reportEditing{try store.makePrecompositionUnique(clip.id)}}}
                        if clip.kind == .speech { speechControls(clip) }
                        if let document = store.project.asset(for: clip)?.psd {
                            PSDInspectorView(store: store, clip: clip, document: document)
                        }
                        if clip.kind == .image {NineSliceControls(store:store,clip:clip)}
                        if clip.kind == .image && store.project.asset(for: clip)?.psd == nil {
                            Divider(); caption(L("立ち絵の口パク"))
                            VMMMenuPicker(L("口を開いた画像"), selection: store.binding(\.mouthAssetID, default: nil)) {
                                VMMChoice(text:L("なし"),value:Optional<UUID>.none)
                                VMMOptions(store.project.assets.filter { $0.kind == .image }) { asset in VMMChoice(text:asset.name,value:Optional(asset.id)) }
                            }
                            VMMMenuPicker(L("連動する話者"), selection:Binding(get:{clip.characterSpeakerID},set:{v in store.edit(clip.id){$0.characterSpeakerID=v;$0.characterSpeechEngine=store.speechConfiguration.engine}})) {
                                VMMChoice(text:L("なし"),value:Optional<Int>.none)
                                VMMOptions(store.voices) { voice in VMMChoice(text:voice.name,value:Optional(voice.id)) }
                                if let id = clip.characterSpeakerID, !store.voices.contains(where: { $0.id == id }) { VMMChoice(text:"\(L("話者")) \(id)",value:Optional(id)) }
                            }
                            Text(L("閉じ口・開き口の同じサイズの画像を用意すると、生成音声の音量に合わせて切り替わります。")).vmmFont(size:12).foregroundColor(.secondary)
                        }
                        Divider()
                        caption(L("タイミング"))
                        number("開始（秒）", key: \.start, range: 0...86400)
                        number("長さ（秒）", key: \.duration, range: (1 / Double(store.project.fps))...86400)
                        if [.audio, .video, .speech].contains(clip.kind) {
                            number("素材の開始（秒）", key: \.sourceOffset, range: 0...86400)
                        }
                        if ![.audio,.transition,.adjustment].contains(clip.kind) {
                            Divider(); caption(L("表示"))
                            number("X位置", key: \.x, range: -2...3, percent: true)
                            number("Y位置", key: \.y, range: -2...3, percent: true)
                            number("拡大率", key: \.scale, range: 0.01...10, percent: true)
                            number("不透明度", key: \.opacity, range: 0...1, percent: true)
                            NumberInput(title: "回転", value: Binding(get: { store.selected?.rotation ?? 0 }, set: { value in store.edit(clip.id) { $0.rotation = value } }), range: -3600...3600, unit: "°")
                            Toggle(L("左右反転"), isOn: Binding(get: { store.selected?.flipX ?? false }, set: { value in store.edit(clip.id) { $0.flipX = value } }))
                            Toggle(L("上下反転"), isOn: Binding(get: { store.selected?.flipY ?? false }, set: { value in store.edit(clip.id) { $0.flipY = value } }))
                            if [.text, .speech, .shape, .particles].contains(clip.kind) {
                                ColorPicker(L("色"), selection: Binding(get: { Color(nsColor: NSColor(hex: clip.color)) }, set: { color in store.edit(clip.id) { $0.color = NSColor(color).hex } }), supportsOpacity: false)
                            }
                            if clip.kind == .shape {ShapeControls(store:store,clip:clip)}
                            if clip.kind == .text || clip.kind == .speech {
                                number("文字サイズ", key: \.fontSize, range: 8...400)
                                TypographyControls(store:store,clip:clip)
                                TextStyleControls(store: store, clip: clip)
                            }
                        }
                        if [.audio, .video, .speech, .group].contains(clip.kind) {
                            Divider(); caption(L("音声"))
                            number("音量", key: \.volume, range: 0...2, percent: true)
                            NumberInput(title:"パン（左 −100／右 100）",value:Binding(get:{clip.pan ?? 0},set:{v in store.edit(clip.id){$0.pan=v}}),range:(-1)...1,percent:true)
                            LoudnessControls(store:store,clip:clip)
                            if [.audio,.video].contains(clip.kind) {
                                Toggle(L("セリフ中は音量を下げる"),isOn:Binding(get:{clip.ducking != nil},set:{v in store.edit(clip.id){$0.ducking=v ? 0.25:nil}}))
                                if clip.ducking != nil {NumberInput(title:"セリフ中の音量",value:Binding(get:{clip.ducking ?? 0.25},set:{v in store.edit(clip.id){$0.ducking=v}}),range:0...1,percent:true)}
                            }
                        }
                        if ![.transition,.adjustment].contains(clip.kind) { ParentControls(store:store,clip:clip) }
                        if [.audio,.video,.speech].contains(clip.kind) { MediaTimingControls(store:store,clip:clip) }
                        if clip.kind == .adjustment { AdjustmentRegionControls(store:store,clip:clip) }
                        } else if tab == 1 {
                            Button {store.openAnimationPanel()} label:{Label(L("アニメーションを編集"),systemImage:"diamond") }
                            Text(L("選択したアイテムのキーフレームや設定を編集します。")).foregroundColor(.secondary)
                            Text("\(L("キーフレーム")): \(clip.animation?.tracks.flatMap(\.keys).count ?? 0)").monospacedDigit()
                        } else {
                            if clip.kind == .adjustment { AdjustmentRegionControls(store:store,clip:clip) }
                            if ![.audio,.transition].contains(clip.kind) { EffectStackControls(store:store,clip:clip) }
                            AdvancedInspector(store:store,clip:clip)
                        }
                    }.vmmFont(size:12).padding(14).disabled(store.busy || store.project.tracks[clip.track].locked)
                }
            } else {
                LayerInspector(store:store)
            }
        }.background(panelColor)

    }
    private func caption(_ value: String) -> some View { Text(L(value)).vmmFont(size:12, weight: .semibold).foregroundColor(.secondary) }
    private func number(_ title: String, key: WritableKeyPath<Clip, Double>, range: ClosedRange<Double>, percent: Bool = false) -> some View {
        NumberInput(title: title, value: store.binding(key, default: range.lowerBound), range: range,
                    step: [\Clip.start, \Clip.duration, \Clip.sourceOffset].contains(key) ? 1 / Double(store.project.fps) : nil, percent: percent)
    }
    private func voiceKey(_ config:SpeechConfiguration?,_ id:Int)->String {"\((config ?? .defaults(.voicevox)).engine.rawValue)/\(config?.endpoint ?? SpeechEngine.voicevox.defaultURL)/\(id)"}
    private func speechControls(_ clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            caption("\((clip.speechConfiguration ?? .defaults(.voicevox)).engine.title)")
            SpeechConnectionControls(store:store)
            Toggle(L("音声を自動生成"), isOn: $store.autoSpeech)
            if store.generatingSpeech.contains(clip.id) { Text(L("音声を生成中…")).foregroundColor(.orange) }
            if store.voices.isEmpty {
                Button(L("音声エンジンに接続")) { store.connectVoicevox() }
                Text(L("先に音声エンジンを起動してください。保存済みの音声は未接続でも再生できます。")).vmmFont(size:12).foregroundColor(.secondary)
            } else {
                VMMMenuPicker(L("話者"), selection:Binding(get:{voiceKey(clip.speechConfiguration,clip.speakerID)},set:{key in if let voice=store.voices.first(where:{voiceKey($0.configuration,$0.id)==key}) {store.selectVoice(voice.id,clipID:clip.id)}})) {
                    if !store.voices.contains(where:{voiceKey($0.configuration,$0.id)==voiceKey(clip.speechConfiguration,clip.speakerID)}) {
                        VMMChoice(text:clip.speakerName.isEmpty ? "\(L("話者")) \(clip.speakerID)":clip.speakerName,value:voiceKey(clip.speechConfiguration,clip.speakerID))
                    }
                    VMMOptions(store.voices) {voice in VMMChoice(text:voice.name,value:voiceKey(voice.configuration,voice.id))}
                }
            }
            SpeechClipOptions(store:store,clip:clip)
            Toggle(L("セリフの字幕を表示"),isOn:Binding(get:{clip.speechCaptionHidden != true},set:{value in store.edit(clip.id){$0.speechCaptionHidden = !value}}))
            Toggle(L("音声生成時に長さを維持"),isOn:Binding(get:{clip.preserveSpeechDuration ?? false},set:{value in store.edit(clip.id){$0.preserveSpeechDuration=value}}))
            if clip.preserveSpeechDuration == true {Text(L("音声が長い場合、アイテムの終わりで切れます。" )).vmmFont(size:12).foregroundColor(.secondary)}
            TextField(L("読み上げ文字（空欄なら字幕と同じ）"),text:Binding(get:{clip.reading ?? ""},set:{v in store.edit(clip.id){$0.reading=v.isEmpty ? nil:v}}))
            number("話速", key: \.speed, range: 0.5...2, percent: true)
            Button(action: { store.generateSpeech() }) {
                Label(L(clip.assetID == nil ? "音声を生成" : "音声を再生成"), systemImage: "waveform").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent)
            if clip.speechDirty { Text(L("音声の生成が必要です")).vmmFont(size:12).foregroundColor(.orange) }
            if !clip.speakerName.isEmpty { Text("\(L("クレジット"))：\((clip.speechConfiguration ?? .defaults(.voicevox)).engine.title):\(clip.speakerName)").vmmFont(size:12).foregroundColor(.secondary).textSelection(.enabled) }
        }
    }
}

struct TimelineView: View {
    @ObservedObject var store: EditorStore
    private var length: Double { max(20, store.project.duration + 8) }
    private var canvasWidth: Double { length * store.zoom }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 15) {
                Text(L("タイムライン")).vmmFont(size:12, weight: .semibold)
                Rectangle().fill(lineColor).frame(width: 1, height: 16)
                ViewThatFits(in:.horizontal) {
                    actions.fixedSize(horizontal:true,vertical:false)
                    actions.labelStyle(.iconOnly).fixedSize(horizontal:true,vertical:false)
                }
                Spacer()
                Toggle(isOn: $store.snapping) { Text(L("スナップ")) }.toggleStyle(.checkbox)
                HStack(spacing:8) {
                UIIcon(systemName:"arrow.left.and.right").foregroundColor(.secondary).help(L("タイムライン拡大率"))
                Slider(value:Binding(get:{log2(store.zoom)},set:{store.zoom=pow(2,$0)}),in:log2(TimelineRuler.zoomRange.lowerBound)...log2(TimelineRuler.zoomRange.upperBound)).frame(width:90).accessibilityLabel(L("タイムライン拡大率")).help(String(format:"%.0f pt/秒",store.zoom))
                Divider().frame(height:18)
                UIIcon(systemName:"arrow.up.and.down").foregroundColor(.secondary).help(L("タイムライン縦拡大率"))
                Slider(value:$store.layerZoom,in:0.65...3).frame(width:90).accessibilityLabel(L("タイムライン縦拡大率"))
                Button(String(format:"%.0f%%",store.layerZoom*100)){store.layerZoom=1}.monospacedDigit().help(L("レイヤー高さを100%に戻す"))
                }.fixedSize().layoutPriority(1)
            }.vmmFont(size:12).buttonStyle(.borderless).padding(.horizontal,16).frame(height:max(42,max(store.settings.textPoints,store.settings.iconPoints)*2.5)).background(panelColor)
            Divider()
            TimelineCanvas(store: store)
        }.disabled(store.busy)
    }
    private var actions:some View {HStack(spacing:12) {
                Button(action: { store.add(.speech) }) { Label(L("セリフ"), systemImage: "waveform.badge.plus") }
                Button(action: { store.add(.text) }) { Label(L("テキスト"), systemImage: "text.badge.plus") }
                Menu {
                    Button(L("図形")) {store.add(.shape)}
                    Button(L("グループ制御")) {store.add(.group)}
                    Button(L("パーティクル")) {store.add(.particles)}
                    Button(L("調整エフェクト")) {store.add(.adjustment)}
                } label: {Label(L("追加"),systemImage:"plus.square")}
                Button(action: { store.add(.transition) }) { Label(L("場面切替"), systemImage: "rectangle.on.rectangle") }
                Button(action: { store.splitSelected() }) { UIIcon(systemName: "scissors") }.help(L("再生位置で分割 ⌘B"))
                Button(action: { store.undo() }) { UIIcon(systemName: "arrow.uturn.backward") }.disabled(!store.canUndo).help(L("元に戻す ⌘Z"))
                Button(action: { store.redo() }) { UIIcon(systemName: "arrow.uturn.forward") }.disabled(!store.canRedo).help(L("やり直す ⇧⌘Z"))
    }}
}

struct TextStyleControls: View {
    @ObservedObject var store: EditorStore
    let clip: Clip
    @State private var showTextRuns=false
    @State private var showLyricSegments=false
    @State private var showLyricRuby=false
    func binding<T>(_ key: WritableKeyPath<TextStyle, T>) -> Binding<T> {
        Binding(get: { (store.project.clips.first { $0.id == clip.id }?.textStyle ?? TextStyle())[keyPath: key] }, set: { value in
            store.edit(clip.id) { c in var style = c.textStyle ?? TextStyle(); style[keyPath: key] = value; c.textStyle = style }
        })
    }
    func color(_ title: String, _ key: WritableKeyPath<TextStyle, String>) -> some View {
        ColorPicker(title, selection: Binding(get: { Color(nsColor: NSColor(hex: binding(key).wrappedValue)) }, set: { binding(key).wrappedValue = NSColor($0).hex }), supportsOpacity: false)
    }
    func gradientBinding<T>(_ key: WritableKeyPath<TextStyle, TextGradient?>, _ field: WritableKeyPath<TextGradient, T>) -> Binding<T> {
        Binding(get: { (binding(key).wrappedValue ?? TextGradient())[keyPath: field] }, set: { value in
            var gradient = binding(key).wrappedValue ?? TextGradient()
            gradient[keyPath: field] = value; binding(key).wrappedValue = gradient
        })
    }
    func gradient(_ title: String, _ key: WritableKeyPath<TextStyle, TextGradient?>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle(title + "のグラデーション", isOn: gradientBinding(key, \.enabled))
            if (binding(key).wrappedValue ?? TextGradient()).enabled {
                ColorPicker(L("終点の色"), selection: Binding(get: { Color(nsColor: NSColor(hex: gradientBinding(key, \.endColor).wrappedValue)) }, set: { gradientBinding(key, \.endColor).wrappedValue = NSColor($0).hex }), supportsOpacity: false)
                NumberInput(title: "角度", value: gradientBinding(key, \.angle), range: 0...360, unit: "°")
                Text(L("0°：左→右　90°：上→下")).vmmFont(size:12).foregroundColor(.secondary)
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            Button(L("ルビを編集…")){showLyricRuby=true}.sheet(isPresented:$showLyricRuby){LyricRubyEditor(store:store,clip:clip)}
            Toggle(L("歌詞ワイプ"),isOn:Binding(get:{clip.lyricWipe != nil},set:{enabled in store.edit(clip.id){$0.lyricWipe=enabled ? LyricWipe(end:max(0.001,$0.duration)):nil}}))
            if let wipe=clip.lyricWipe {
                ColorPicker(L("ワイプ後の文字色"),selection:Binding(get:{Color(nsColor:NSColor(hex:wipe.color))},set:{value in store.edit(clip.id){$0.lyricWipe?.color=NSColor(value).hex}}),supportsOpacity:false)
                NumberInput(title:"ワイプ開始",value:Binding(get:{wipe.start},set:{value in store.edit(clip.id){$0.lyricWipe?.start=min(value,max(0,wipe.end-0.001))}}),range:0...86400,unit:"秒")
                NumberInput(title:"ワイプ終了",value:Binding(get:{wipe.end},set:{value in store.edit(clip.id){$0.lyricWipe?.end=max(wipe.start+0.001,value)}}),range:0...86400,unit:"秒")
                Button(L("文字・単語のタイミング…")){showLyricSegments=true}.sheet(isPresented:$showLyricSegments){LyricSegmentEditor(store:store,clip:clip)}
                if wipe.segments != nil {Button(L("行全体のワイプに戻す")){store.edit(clip.id){$0.lyricWipe?.segments=nil}}}
            }
            Button(L("選択した文字を装飾…")){showTextRuns=true}.sheet(isPresented:$showTextRuns){TextRunStyleSheet(store:store,clip:clip)}
            gradient("文字色", \.fillGradient)
            Toggle(L("縁取り"), isOn: binding(\.outline))
            if (clip.textStyle ?? TextStyle()).outline {
                color("縁の色", \.outlineColor)
                gradient("縁取り", \.outlineGradient)
                NumberInput(title: "太さ（文字サイズ比）", value: binding(\.outlineWidth), range: 0...20, unit: "%")
            }
            Toggle(L("影"), isOn: binding(\.shadow))
            if (clip.textStyle ?? TextStyle()).shadow {
                color("影の色", \.shadowColor)
                NumberInput(title: "影の濃さ", value: binding(\.shadowOpacity), range: 0...1, percent: true)
                NumberInput(title: "ぼかし", value: binding(\.shadowBlur), range: 0...100, unit: "px")
                NumberInput(title: "影の横位置", value: binding(\.shadowX), range: -100...100, unit: "px")
                NumberInput(title: "影の縦位置", value: binding(\.shadowY), range: -100...100, unit: "px")
            }
        }
    }
}

struct PreviewCanvas: NSViewRepresentable {
    @ObservedObject var store: EditorStore
    @ObservedObject var clock:PlaybackClock
    init(store:EditorStore){self.store=store;self.clock=store.playbackClock}
    func makeNSView(context: Context) -> PreviewNSView { PreviewNSView() }
    func updateNSView(_ view: PreviewNSView, context: Context) {
        view.update(store:store)
    }
}
