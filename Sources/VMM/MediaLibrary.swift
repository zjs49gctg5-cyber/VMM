import SwiftUI
import AppKit

// UI preferences remain optional in saved settings so older settings decode unchanged.
enum LibraryLayout:String,Codable,CaseIterable {case list,grid}
enum LibraryFilter:String,CaseIterable {case all,image,psd,video,audio
    var title:String {switch self {case .all:return "すべて";case .image:return "画像";case .psd:return "PSD立ち絵";case .video:return "動画";case .audio:return "音声・BGM"}}
    func includes(_ a:MediaAsset)->Bool {switch self {case .all:return true;case .image:return a.kind == .image && a.psd == nil;case .psd:return a.psd != nil;case .video:return a.kind == .video;case .audio:return a.kind == .audio}}
}
enum LibrarySort:String,Codable,CaseIterable {case imported,name,kind,duration
    var title:String {switch self {case .imported:return "登録順";case .name:return "名前順";case .kind:return "種類順";case .duration:return "長さ順"}}
}
enum LibraryQuery {
    static func assets(_ source:[MediaAsset],search:String,filter:LibraryFilter,sort:LibrarySort,descending:Bool,usage:LibraryUsageFilter = .all,usedIDs:Set<UUID>=[])->[MediaAsset] {
        func normalized(_ text:String)->String {text.folding(options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive],locale:Locale(identifier:"ja_JP"))}
        let words=normalized(search).split(whereSeparator:{$0.isWhitespace}).map(String.init)
        let filtered=source.enumerated().filter{_,a in
            guard filter.includes(a),usage == .all || (usage == .used)==usedIDs.contains(a.id) else{return false}
            guard !words.isEmpty else{return true}
            let searchable=normalized(a.name+" "+(a.tags ?? []).joined(separator:" "))
            return words.allSatisfy{searchable.contains($0)}
        }
        if sort == .imported {
            let result=filtered.map(\.element)
            return descending ? Array(result.reversed()):result
        }
        let sorted=filtered.sorted {a,b in
            var comparison:ComparisonResult = .orderedSame
            switch sort {
            case .imported:break
            case .name:comparison=a.element.name.localizedStandardCompare(b.element.name)
            case .kind:comparison=kindTitle(a.element).localizedStandardCompare(kindTitle(b.element))
            case .duration:comparison=a.element.duration==b.element.duration ? .orderedSame:(a.element.duration<b.element.duration ? .orderedAscending:.orderedDescending)
            }
            if comparison == .orderedSame {comparison=a.offset<b.offset ? .orderedAscending:.orderedDescending}
            return descending ? comparison == .orderedDescending:comparison == .orderedAscending
        }
        return sorted.map(\.element)
    }
    static func kindTitle(_ a:MediaAsset)->String {a.psd != nil ? "PSD立ち絵":a.kind == .image ? "画像":a.kind.title}
}
struct MediaLibraryBrowser:View {
    @ObservedObject var store:EditorStore
    @StateObject private var playback=LibraryPlayback()
    @StateObject private var hover=LibraryHoverPreview()
    @State private var search=""
    @State private var filter=LibraryFilter.all
    @State private var usage=LibraryUsageFilter.all
    var layout:LibraryLayout {store.settings.libraryLayout ?? .list}
    private var filtersVisible:Bool {store.settings.libraryFiltersVisible ?? true}
    private var filtering:Bool {!search.isEmpty || filter != .all || usage != .all}
    var body:some View {
        let assets=store.libraryAssets
        let visibleAssets=LibraryQuery.assets(assets,search:search,filter:filter,sort:store.settings.librarySort ?? .imported,descending:store.settings.libraryDescending ?? false,usage:usage,usedIDs:usage == .all ? []:store.project.usedAssetIDs)
        return VStack(alignment:.leading,spacing:7) {
            HStack(spacing:4) {
                Button {
                    store.settings.libraryFiltersVisible = !filtersVisible
                    store.persistSettings()
                } label:{UIIcon(systemName:filtering ? "line.3.horizontal.decrease.circle.fill":"line.3.horizontal.decrease.circle").foregroundColor(filtering ? .orange:(filtersVisible ? .accentColor:.secondary))}
                    .buttonStyle(.borderless).frame(width:22,height:26)
                    .help(L(filtersVisible ? "検索・絞り込みを隠す":"検索・絞り込みを表示"))
                    .accessibilityLabel(L("検索・絞り込み"))
                    .accessibilityValue(L(filtering ? (filtersVisible ? "表示中・絞り込み中":"非表示・絞り込み中"):(filtersVisible ? "表示中":"非表示")))
                if filtering {
                    Button(action:resetFilters){UIIcon(systemName:"xmark.circle.fill")}.buttonStyle(.borderless)
                        .frame(width:22,height:26).help(L("検索・絞り込みをリセット")).accessibilityLabel(L("検索・絞り込みをリセット"))
                }
                Text("\(visibleAssets.count) / \(assets.count)").vmmFont().foregroundColor(.secondary).lineLimit(1).minimumScaleFactor(0.75)
                    .accessibilityLabel("\(visibleAssets.count) / \(assets.count) \(L("素材"))")
                Spacer(minLength:0)
                Picker(L("表示形式"),selection:Binding(get:{layout},set:{store.settings.libraryLayout=$0;store.persistSettings()})) {UIIcon(systemName:"list.bullet").tag(LibraryLayout.list);UIIcon(systemName:"square.grid.2x2").tag(LibraryLayout.grid)}.pickerStyle(.segmented).labelsHidden().frame(width:68).accessibilityLabel(L("リスト／グリッド表示"))
                Menu {
                    Toggle(L("素材ライブラリのサムネイルを表示"),isOn:Binding(get:{store.settings.libraryThumbnails ?? true},set:{store.setLibraryThumbnails($0)}))
                    Toggle(L("動画をホバーでプレビュー"),isOn:Binding(get:{store.settings.libraryHoverPreview ?? true},set:{store.settings.libraryHoverPreview=$0;store.persistSettings()}))
                    Button(L("サムネイルを再読み込み")){TimelineMediaCache.shared.clear()}
                    Button(L("素材管理…")){store.workspaceWindows.show(.media)}
                    Button(L("素材ライブラリの表示設定…")){store.workspaceSettingsTab = .library;store.workspaceWindows.show(.workspaceSettings)}
                    Divider()
                    Button("\(L("未使用素材の登録を解除")) (\(store.unusedLibraryAssets.count))"){store.removeUnusedMedia()}.disabled(store.unusedLibraryAssets.isEmpty)
                } label:{UIIcon(systemName:"ellipsis").frame(width:32,height:30).contentShape(Rectangle())}
                    .menuStyle(.borderlessButton).help(L("素材ライブラリの操作")).accessibilityLabel(L("素材ライブラリの操作"))
            }
            if filtersVisible {
            HStack(spacing:6) {
                UIIcon(systemName:"magnifyingglass").foregroundColor(.secondary)
                TextField(L("素材を検索"),text:$search).textFieldStyle(.plain).accessibilityLabel(L("素材を検索"))
                if !search.isEmpty {Button {search=""} label:{UIIcon(systemName:"xmark.circle.fill")}.buttonStyle(.borderless).help(L("検索をクリア"))}
            }.padding(8).background(Color.black.opacity(0.2)).cornerRadius(6)
            GeometryReader { geometry in
            let fieldWidth=max(max(70,store.settings.textPoints*5.8),(geometry.size.width-38)/3)
            ScrollView(.horizontal,showsIndicators:true) {
                HStack(alignment:.bottom,spacing:6) {
                    VStack(alignment:.leading,spacing:4) {
                        Text(L("種類")).vmmFont().foregroundColor(.secondary).lineLimit(1)
                        VMMMenuPicker(L("種類"),selection:$filter){VMMOptions(LibraryFilter.allCases,id:\.self){VMMChoice(text:L($0.title),value:$0)}}.labelsHidden().accessibilityLabel(L("素材の種類"))
                    }.frame(width:fieldWidth)
                    VStack(alignment:.leading,spacing:4) {
                        Text(L("使用状況")).vmmFont().foregroundColor(.secondary).lineLimit(1)
                        VMMMenuPicker(L("使用状況"),selection:$usage){VMMOptions(LibraryUsageFilter.allCases,id:\.self){VMMChoice(text:L($0 == .all ? "すべて":$0.title),value:$0)}}.labelsHidden()
                    }.frame(width:fieldWidth)
                    VStack(alignment:.leading,spacing:4) {
                        Text(L("並び順")).vmmFont().foregroundColor(.secondary).lineLimit(1)
                        VMMMenuPicker(L("並び順"),selection:Binding(get:{store.settings.librarySort ?? .imported},set:{store.settings.librarySort=$0;store.persistSettings()})){VMMOptions(LibrarySort.allCases,id:\.self){VMMChoice(text:L($0.title),value:$0)}}.labelsHidden().accessibilityLabel(L("素材の並び順"))
                    }.frame(width:fieldWidth)
                    Button {store.settings.libraryDescending = !(store.settings.libraryDescending ?? false);store.persistSettings()} label:{UIIcon(systemName:store.settings.libraryDescending == true ? "arrow.down":"arrow.up")}.buttonStyle(.borderless).frame(height:max(24,store.settings.textPoints*1.6)).help(L(store.settings.libraryDescending == true ? "降順（クリックで昇順）":"昇順（クリックで降順）"))
                }.fixedSize(horizontal:true,vertical:false)
            }.overlay(alignment:.topTrailing) {
                if fieldWidth*3+38>geometry.size.width+0.5 {
                    UIIcon(systemName:"arrow.left.and.right").vmmFont(size:10).padding(3)
                        .background(Color(nsColor:.windowBackgroundColor)).cornerRadius(4)
                        .help(L("横にスクロール")).allowsHitTesting(false)
                }
            }
            }.frame(height:max(48,store.settings.textPoints*3.7))
            }
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing:8) {
                LibraryPlaybackPanel(playback:playback,store:store).id("library-playback")
                if assets.isEmpty {
                    empty("Finderから素材をドロップ","画像・立ち絵・動画・BGM")
                } else if visibleAssets.isEmpty {
                    VStack {empty("一致する素材がありません","検索語や種類フィルタを変更してください。")
                        Button(L("検索・絞り込みをリセット")){resetFilters()}}
                } else if layout == .grid {
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:140),spacing:8)],spacing:8){ForEach(visibleAssets){asset in cell(asset,grid:true)}}
                } else {
                    LazyVStack(spacing:6){ForEach(visibleAssets){asset in cell(asset,grid:false)}}
                }
                }
            }.onChange(of:playback.asset?.id){id in if id != nil {proxy.scrollTo("library-playback",anchor:.top)}}
            }
        }.padding(.horizontal,12).padding(.bottom,10)
        .onDisappear{playback.stop();hover.stop()}
        .onChange(of:store.directory){_ in playback.stop();hover.stop()}
        .onChange(of:store.settings.libraryHoverPreview){enabled in if enabled == false{hover.stop()}}
        .onChange(of:store.settings.libraryThumbnails){enabled in if enabled != false {TimelineMediaCache.shared.clear()}}
        .onChange(of:search){_ in hover.stop()}
        .onChange(of:filter){_ in hover.stop()}
        .onChange(of:usage){_ in hover.stop()}
        .onChange(of:layout){_ in hover.stop()}
        .onChange(of:playback.asset?.id){id in if id != nil{hover.stop()}}
        .onChange(of:store.project.assets.map{"\($0.id):\($0.file)"}){_ in
            if let asset=playback.asset,!store.project.assets.contains(where:{$0.id==asset.id && $0.file==asset.file}) {playback.stop()}
            hover.stop()
        }
        .onChange(of:store.playing){active in if active {playback.stop();hover.stop()}}
        .onChange(of:store.busy){active in if active {playback.stop();hover.stop()}}
    }
    private func resetFilters(){search="";filter = .all;usage = .all}
    private func empty(_ title:String,_ detail:String)->some View {VStack(spacing:10){UIIcon(systemName:"square.stack.3d.up").vmmFont(size:28,weight:.ultraLight);Text(L(title)).vmmFont();Text(detail).vmmFont().foregroundColor(.secondary)}.frame(maxWidth:.infinity).padding(.vertical,28)}
    private func cell(_ asset:MediaAsset,grid:Bool)->some View {
        Group {
            if grid {
                VStack(alignment:.leading,spacing:7) {
                    thumbnail(asset).frame(height:84).frame(maxWidth:.infinity)
                    HStack {details(asset);Spacer(minLength:0);tagButton(asset);playButton(asset);addButton(asset)}
                }.padding(8).overlay(alignment:.top){AssetDragSource(asset:asset,store:store,preview:{store.pause();hover.stop();playback.open(asset,directory:store.directory)},hover:{active in setHover(active,asset:asset)}).frame(height:84).padding(.top,8)}
            } else {
                HStack(spacing:9){thumbnail(asset).frame(width:64,height:44);details(asset);Spacer(minLength:0);tagButton(asset);playButton(asset);addButton(asset)}.padding(8)
                    .overlay{AssetDragSource(asset:asset,store:store,preview:{store.pause();hover.stop();playback.open(asset,directory:store.directory)},hover:{active in setHover(active,asset:asset)}).padding(.trailing,[.audio,.video].contains(asset.kind) ? 108:70)}
            }
        }.background(Color.primary.opacity(0.045)).cornerRadius(7).help(asset.name).onHover{active in setHover(active,asset:asset)}.onDisappear{hover.exit(asset.id)}
        .contextMenu {Button(L("タイムラインに追加")){store.add(asset.kind,asset:asset)};if [.audio,.video].contains(asset.kind){Button(L("素材を再生")){store.pause();hover.stop();playback.open(asset,directory:store.directory)}};Button(L("Finderで素材を表示")){store.revealMedia(asset)};Divider();Button(L("素材を削除")){store.confirmDeleteMedia(asset)};Button(L("素材タグ")){store.editMediaTags(asset)};Text("\(L("使用数")): \(store.project.usageCount(asset.id))")}
    }
    private func tagButton(_ asset:MediaAsset)->some View {Button{store.editMediaTags(asset)}label:{UIIcon(systemName:"tag")}.buttonStyle(.borderless).help(L("素材タグ"))}
    private func setHover(_ active:Bool,asset:MediaAsset) {
        if active,store.settings.libraryHoverPreview != false,!store.playing,!store.busy,playback.asset==nil {
            hover.enter(asset,directory:store.directory,seconds:store.settings.libraryHoverSeconds ?? 3)
        } else {hover.exit(asset.id)}
    }
    @ViewBuilder private func thumbnail(_ asset:MediaAsset)->some View {
        if hover.assetID==asset.id,let player=hover.player {LibraryVideoView(player:player).background(Color.black).cornerRadius(4)}
        else {MediaLibraryThumbnail(asset:asset,directory:store.directory,limitMB:store.settings.cacheMB,enabled:store.settings.libraryThumbnails ?? true).background(Color.black.opacity(0.25)).cornerRadius(4)}
    }
    private func details(_ a:MediaAsset)->some View {VStack(alignment:.leading,spacing:3){Text(a.name).vmmFont(size:12).lineLimit(2);if !(a.tags ?? []).isEmpty{Text(a.tags!.joined(separator:" · ")).vmmFont(size:12).foregroundColor(.secondary).lineLimit(1)};Text(a.psd.map{"PSD · \($0.layers.count)レイヤー"} ?? (a.kind == .image ? "画像":String(format:"%@ · %.1f秒",LibraryQuery.kindTitle(a),a.duration))).vmmFont().foregroundColor(.secondary)}.frame(maxWidth:.infinity,alignment:.leading)}
    @ViewBuilder private func playButton(_ asset:MediaAsset)->some View {
        if [.audio,.video].contains(asset.kind) {
            Button {store.pause();hover.stop();playback.open(asset,directory:store.directory)} label:{UIIcon(systemName:"play.circle")}.buttonStyle(.borderless).disabled(store.busy).help(L("素材を再生")).accessibilityLabel("\(asset.name)を素材ライブラリで再生")
        }
    }
    private func addButton(_ a:MediaAsset)->some View {Button{store.add(a.kind,asset:a)} label:{UIIcon(systemName:"plus.circle")}.buttonStyle(.borderless).help(L("選択中のレイヤー・再生位置に追加")).accessibilityLabel("\(a.name)をタイムラインに追加")}
}
struct MediaLibraryThumbnail:View {
    let asset:MediaAsset;let directory:URL;let limitMB:Int;let enabled:Bool
    @ObservedObject private var cache=TimelineMediaCache.shared
    var body:some View {GeometryReader{geometry in
        if enabled && [.image,.video].contains(asset.kind),let image=cache.thumbnail(asset:asset,directory:directory,time:asset.kind == .video ? min(1,asset.duration/2):0,limitMB:limitMB,onReady:{}) {
            Image(nsImage:image).resizable().scaledToFit().frame(width:geometry.size.width,height:geometry.size.height)
        } else if enabled && asset.kind == .audio,let values=cache.envelope(asset:asset,directory:directory,onReady:{}),!values.isEmpty {
            LibraryWaveform(values:values).stroke(asset.kind.tint,lineWidth:1).padding(6)
        } else {
            UIIcon(systemName:asset.psd == nil ? asset.kind.symbol:"person.crop.rectangle",size:22).vmmFont(size:22).foregroundColor(asset.kind.tint).frame(width:geometry.size.width,height:geometry.size.height)
        }
    }.accessibilityHidden(true)}
}
struct LibraryWaveform:Shape {
    let values:[Double]
    func path(in r:CGRect)->Path {var path=Path();let peak=max(0.001,values.max() ?? 0.001),steps=max(1,Int(r.width/2));for i in 0..<steps {let a=i*values.count/steps,b=max(a+1,(i+1)*values.count/steps);let value=values[a..<min(values.count,b)].max() ?? 0;let h=max(0.5,value/peak*r.height/2),x=r.minX+CGFloat(i)*r.width/CGFloat(steps);path.move(to:CGPoint(x:x,y:r.midY-h));path.addLine(to:CGPoint(x:x,y:r.midY+h))};return path}
}
