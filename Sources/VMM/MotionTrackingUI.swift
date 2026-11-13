import SwiftUI

struct MotionTrackingControls:View {
    @ObservedObject var store:EditorStore;let clip:Clip
    @State private var source:UUID?;@State private var x=0.4;@State private var y=0.4;@State private var width=0.2;@State private var height=0.2
    @State private var from=0.0;@State private var duration=2.0;@State private var sampleRate=15.0;@State private var followScale=false
    @State private var stabilizeStrength=1.0;@State private var smoothing=0.5;@State private var zoom=1.1
    @State private var image:CGImage?;@State private var task:Task<Void,Never>?;@State private var analyzing=false;@State private var progress=0.0
    @State private var dragStart:CGPoint?
    private var sources:[Clip]{store.project.clips.filter{$0.kind == .video && store.project.asset(for:$0) != nil}}
    private var sourceClip:Clip?{sources.first{$0.id==source}}
    private var url:URL?{sourceClip.flatMap{store.project.asset(for:$0)}.map{store.directory.appendingPathComponent("Media").appendingPathComponent($0.file)}}
    var body:some View{VStack(alignment:.leading,spacing:12){
        Text(L("動画のモーショントラッキング")).fontWeight(.semibold)
        VMMMenuPicker(L("追跡する動画"),selection:$source){VMMChoice(text:L("動画を選択"),value:Optional<UUID>.none);VMMOptions(sources,id:\.id){c in VMMChoice(text:c.name,value:Optional(c.id))}}
        if let image {
            GeometryReader{g in let ratio=Double(image.width)/Double(image.height),w=min(g.size.width,g.size.height*ratio),h=w/ratio
                ZStack(alignment:.topLeading){Image(decorative:image,scale:1).resizable().frame(width:w,height:h);Rectangle().stroke(Color.orange,lineWidth:2).frame(width:width*w,height:height*h).offset(x:x*w,y:y*h).allowsHitTesting(false)}.frame(width:w,height:h).contentShape(Rectangle()).gesture(DragGesture(minimumDistance:2).onChanged{v in guard !analyzing else{return};if dragStart==nil{dragStart=v.startLocation};guard let start=dragStart else{return};x=min(0.99,max(0,min(start.x,v.location.x)/w));y=min(0.99,max(0,min(start.y,v.location.y)/h));width=min(1-x,max(0.01,abs(v.location.x-start.x)/w));height=min(1-y,max(0.01,abs(v.location.y-start.y)/h))}.onEnded{_ in dragStart=nil}).onHover{if $0{NSCursor.crosshair.set()}else{NSCursor.arrow.set()}}
            }.frame(height:220)
        }
        NumberInput(title:"範囲 X",value:$x,range:0...0.99,percent:true);NumberInput(title:"範囲 Y",value:$y,range:0...0.99,percent:true);NumberInput(title:"範囲の幅",value:$width,range:0.01...1,percent:true);NumberInput(title:"範囲の高さ",value:$height,range:0.01...1,percent:true)
        NumberInput(title:"動画アイテム内の開始時刻",value:$from,range:0...max(0.001,(sourceClip?.duration ?? 1)-0.05),unit:"秒")
        NumberInput(title:"解析する長さ",value:$duration,range:0.05...30,unit:"秒")
        NumberInput(title:"毎秒の解析回数",value:$sampleRate,range:1...30)
        Toggle(L("大きさも追従"),isOn:$followScale)
        HStack{Button(L("追跡して移動パスを作成")){analyze()}.disabled(sourceClip==nil || analyzing);if analyzing{Button(L("キャンセル")){task?.cancel()};ProgressView(value:progress).frame(width:110)}}
        if let result=clip.tracking{Text(String(format:L("追跡点: %d · 最低信頼度: %.0f%%"),result.samples.count,(result.samples.map(\.confidence).min() ?? 0)*100));if let lost=result.lostAt{Text(String(format:L("%.3f秒で追跡を失いました。それ以降は最後の位置を保持します。"),lost)).foregroundColor(.orange)}}
        if clip.kind == .video {
            Divider();Text(L("手ぶれ補正")).fontWeight(.semibold)
            Text(L("上の追跡動画でこの動画自身を選び、補正する範囲を指定します。")).foregroundColor(.secondary)
            NumberInput(title:"補正の強さ",value:$stabilizeStrength,range:0...1,percent:true)
            NumberInput(title:"平滑化時間",value:$smoothing,range:0.05...3,unit:"秒")
            NumberInput(title:"余白を減らす拡大率",value:$zoom,range:1...2,percent:true)
            Button(L("追跡して手ぶれを補正")){stabilize()}.disabled(sourceClip?.id != clip.id || analyzing)
            Text(L("位置のぶれのみ補正します。回転やズームのぶれは対象外です。解析範囲の前後は端点の補正を保持します。拡大しても映像の端に余白が残る場合があります。追跡を失った場合は適用しません。")).foregroundColor(.secondary)
        }
        Text(L("橙色の範囲をドラッグで指定します。動画の配置・回転・親変形を含めて移動パスへ変換します。生成後は「移動パス・支点」で修正できます。位置と大きさの追跡に対応し、回転・平面／カメラ解析は含みません。既存の移動パスは置き換わります。")).foregroundColor(.secondary)
    }.onAppear{source=sources.first(where:{$0.id==clip.id})?.id ?? sources.first?.id;resetRange()}.onChange(of:source){_ in task?.cancel();resetRange()}.onChange(of:[x,y,width,height,from,duration,sampleRate,followScale ? 1:0,stabilizeStrength,smoothing,zoom]){_ in if analyzing{task?.cancel()}}.task(id:"\(source?.uuidString ?? ""):\(from):\(store.directory.path)"){
        image=nil;guard let url,let source=sourceClip else{return};let frameTime=source.sourceOffset+from*source.mediaRate;let worker=Task.detached(priority:.utility){try MotionTracker.thumbnail(url:url,time:frameTime)};do{let result=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()});try Task.checkCancellation();image=result}catch{}
    }.onDisappear{task?.cancel()}}
    private func resetRange(){guard let source=sourceClip else{return};from=min(max(0,source.duration-0.05),max(0,max(clip.start,store.playhead)-source.start));duration=max(0.05,min(10,source.duration-from,clip.end-source.start-from))}
    private func analyze(){guard let source=sourceClip else{return};let targetID=clip.id,sourceID=source.id,region=CGRect(x:x,y:y,width:width,height:height),start=from,length=duration,rate=sampleRate,scale=followScale
        analyzing=true;progress=0;task=Task{@MainActor in defer{analyzing=false;task=nil}
            do{_=try await store.trackMotion(clipID:targetID,sourceClipID:sourceID,region:region,from:start,duration:length,sampleRate:rate,followScale:scale){value in Task{@MainActor in progress=value}}}catch is CancellationError{}catch{store.error=error.localizedDescription}
        }
    }
    private func stabilize(){guard let source=sourceClip,source.id==clip.id else{return};let region=CGRect(x:x,y:y,width:width,height:height),start=from,length=duration,rate=sampleRate,strength=stabilizeStrength,smooth=smoothing,crop=zoom
        analyzing=true;progress=0;task=Task{@MainActor in defer{analyzing=false;task=nil}
            do{_=try await store.stabilizeVideo(clipID:source.id,region:region,from:start,duration:length,sampleRate:rate,strength:strength,smoothing:smooth,zoom:crop){value in Task{@MainActor in progress=value}};store.status="手ぶれ補正のキーフレームを作成しました。"}catch is CancellationError{}catch{store.error=error.localizedDescription}
        }
    }
}
