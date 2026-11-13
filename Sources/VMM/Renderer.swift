import AppKit
import AVFoundation

extension NSColor {
    convenience init(hex: String) {
        let value = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0xFFFFFF
        self.init(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    var hex: String {
        let c = usingColorSpace(.sRGB) ?? .white
        return String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

final class FrameRenderer {
    let useProxies:Bool
    var previewParticleDetail:Double=1
    var previewPlaying=false
    private var temporalSamplingDepth=0
    var partialAdjustments=true
    var reuseStaticLayers=true
    var reuseSceneMetadata=true
    var reuseProjectLookups=true
    var reuseNeutralImages=true
    var boundNeutralTransforms=true
    var boundedNodes=true
    var reuseStaticBackgrounds=true {didSet{setCacheBudget(megabytes:cacheBudget/(1024*1024))}}
    private(set) var backgroundHits=0
    private(set) var boundedNodeRenders=0
    private(set) var staticHits=0
    private(set) var neutralImageHits=0
    private let staticLayers=RenderCache<NodeRaster>(budget:64*1024*1024)
    private let staticBackgrounds=RenderCache<CGImage>(budget:32*1024*1024)
    private var compositionScope:UUID?
    private var cachedProject:Project?
    private var cachedSceneMembers:Set<UUID> = []
    // Nested compositions and compound scenes share the top-level asset library.
    // Index it once per project revision instead of scanning it for every node.
    private var cachedAssets:[UUID:MediaAsset] = [:]
    private var potentialParents:Set<UUID> = []
    private let videoPrefetch=VideoPrefetch()
    /// Set for the current top-level draw, including nested compositions and effects.
    private(set) var videoDecodeFailure:String?
    var renderingFailure:String? {videoDecodeFailure ?? effectRenderer.failure}
    init(useProxies:Bool=true,effectRenderer:EffectRenderer=EffectRenderer()){self.useProxies=useProxies;self.effectRenderer=effectRenderer;setCacheBudget(megabytes:256)}
    private var cacheBudget=256*1024*1024
    func setCacheBudget(megabytes:Int){cacheBudget=max(16,min(2048,megabytes))*1024*1024;images.budget=cacheBudget/8;psdRenderer.setCacheBudget(cacheBudget/4);maskRenderer.setCacheBudget(cacheBudget/8);staticLayers.budget=cacheBudget*(reuseStaticBackgrounds ? 2:3)/8;staticBackgrounds.budget=reuseStaticBackgrounds ? cacheBudget/8:0;videoPrefetch.setBudget(cacheBudget/8);generators.budget=max(2,min(32,megabytes/16))}
    var cacheUsage:RenderCacheUsage {RenderCacheUsage(bytes:images.bytes+psdRenderer.cacheBytes+maskRenderer.cacheBytes+staticLayers.bytes+staticBackgrounds.bytes+videoPrefetch.bytes,budget:cacheBudget,decoderCount:generators.count+videoPrefetch.pendingCount)}
    private var cachedDirectory:URL?
    private let images=RenderCache<NSImage>(budget:128*1024*1024)
    private let gifs=RenderCache<AnimatedGIF>(budget:16)
    private let generators=RenderCache<AVAssetImageGenerator>(budget:16)
    private let psdRenderer = PSDRenderer()
    private let textPainter = TextPainter()
    private let effectRenderer:EffectRenderer
    private let maskRenderer = MaskRenderer()
    private let cameraRenderer = Camera3DRenderer()

    func draw(project: Project, directory: URL, time: Double, context: CGContext, size: CGSize) {
        videoDecodeFailure=nil;effectRenderer.beginFrame()
        if cachedDirectory != directory {images.clear();gifs.clear();generators.clear();maskRenderer.clearCache();staticLayers.clear();staticBackgrounds.clear();videoPrefetch.clear();cachedDirectory=directory}
        if cachedProject != project {
            staticLayers.clear();staticBackgrounds.clear();videoPrefetch.clear();cachedProject=project
            cachedSceneMembers=Set(project.clips.flatMap{$0.sceneMembers ?? []})
            cachedAssets=Dictionary(project.assets.map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
            potentialParents=Set(project.clips.compactMap(\.parentID))
            for composition in project.precompositions ?? [] {potentialParents.formUnion(composition.clips.compactMap(\.parentID))}
        }
        drawComposition(project:project,directory:directory,time:time,clips:project.visibleClips(at:time),context:context,size:size)
    }
    private func asset(_ id:UUID?,project:Project)->MediaAsset? {
        guard let id else{return nil}
        return reuseProjectLookups ? cachedAssets[id]:project.assets.first{$0.id==id}
    }
    private func hasVisibleChildren(_ id:UUID,clips:[Clip])->Bool {
        (!reuseProjectLookups || potentialParents.contains(id)) && clips.contains(where:{$0.parentID==id})
    }
    private func drawComposition(project:Project,directory:URL,time:Double,clips visible:[Clip],context:CGContext,size:CGSize,transparent:Bool=false,depth:Int=0) {
        let members=depth==0 && reuseSceneMetadata ? cachedSceneMembers:Set(project.clips.flatMap{$0.sceneMembers ?? []})
        // Timeline rows increase downward; only roots below the transition are affected.
        // Children stay with their parent, whose track determines compositing order.
        if let transition=visible.filter({$0.kind == .transition && !members.contains($0.id)}).min(by:{$0.track<$1.track}) {
            let byID=Dictionary(project.clips.map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
            func rootTrack(_ clip:Clip)->Int {
                var root=clip,visited:Set<UUID>=[]
                while let parent=root.parentID,visited.insert(parent).inserted,let next=byID[parent] {root=next}
                return root.track
            }
            let lower=visible.filter{rootTrack($0)>transition.track}
            let sourceTime=max(0,transition.start-1/Double(project.fps))
            let outgoing=project.visibleClips(at:sourceTime).filter{rootTrack($0)>transition.track}
            if let old=compositionImage(project:project,directory:directory,time:sourceTime,clips:outgoing,size:size,depth:depth),
               let new=compositionImage(project:project,directory:directory,time:time,clips:lower,size:size,depth:depth),
               let layer=bitmap(size) {
                let settings=transition.sceneTransition ?? SceneTransition()
                TransitionRenderer.draw(old:old,new:new,kind:settings.kind,progress:settings.easing.value((time-transition.start)/transition.duration),context:layer,size:size)
                let upper=visible.filter{rootTrack($0)<=transition.track && $0.kind != .transition}
                drawScene(project:project,directory:directory,time:time,clips:upper,context:context,size:size,transparent:transparent,depth:depth,sceneMembers:members)
                if let image=layer.makeImage(){context.draw(image,in:CGRect(origin:.zero,size:size))}
                return
            }
        }
        drawScene(project:project,directory:directory,time:time,clips:visible.filter{$0.kind != .transition},context:context,size:size,transparent:transparent,depth:depth,sceneMembers:members)
    }
    private func compositionImage(project:Project,directory:URL,time:Double,clips:[Clip],size:CGSize,depth:Int)->CGImage? {
        guard let context=bitmap(size) else{return nil}
        drawComposition(project:project,directory:directory,time:time,clips:clips,context:context,size:size,transparent:true,depth:depth)
        return context.makeImage()
    }
    private func bitmap(_ size: CGSize) -> CGContext? {
        let width = max(1, Int(size.width.rounded())), height = max(1, Int(size.height.rounded()))
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    private func prepare(_ context: CGContext, project: Project, size: CGSize) {
        context.scaleBy(x: size.width / CGFloat(project.width), y: size.height / CGFloat(project.height))
        context.translateBy(x: 0, y: CGFloat(project.height)); context.scaleBy(x: 1, y: -1)
    }
    private func drawScene(project: Project, directory: URL, time: Double, clips: [Clip], context: CGContext, size: CGSize,transparent:Bool=false,depth:Int=0,sceneMembers:Set<UUID>) {
        guard let scene = bitmap(size) else { return }
        if !transparent {scene.setFillColor(NSColor(hex:project.background).cgColor);scene.fill(CGRect(origin:.zero,size:size))}
        let roots=clips.filter { $0.parentID == nil && $0.kind != .audio && $0.kind != .transition && !sceneMembers.contains($0.id) }
        func projected(_ image:NodeRaster,_ clip:Clip)->NodeRaster? {
            guard depth==0,let camera=project.camera3D,camera.enabled else{return image}
            return cameraRenderer.render(image,camera:camera.evaluated(at:time),depth:clip.cameraDepth ?? 0,size:size)
        }
        // Partition once: both the background-prefix scan and compositing need
        // the same ordered clips for each track on every rendered frame.
        var rootsByTrack=[[Clip]](repeating:[],count:project.tracks.count)
        for clip in roots where rootsByTrack.indices.contains(clip.track) {rootsByTrack[clip.track].append(clip)}
        var prefixEnd=0
        if reuseStaticBackgrounds,reuseStaticLayers,!transparent,depth==0,project.camera3D?.enabled != true {
            for (index,track) in project.tracks.enumerated() {
                let items=rootsByTrack[index]
                if track.visible && (!items.allSatisfy({isStaticNode($0,clips:clips,project:project)}) || (track.effects ?? []).contains(where:{$0.enabled && (!$0.keys.isEmpty || $0.kind.timeVarying)})) {break}
                prefixEnd=index+1
            }
        }
        let prefixIDs=roots.filter{$0.track<prefixEnd}.map{$0.id.uuidString}
        let prefixKey=prefixIDs.isEmpty ? nil:"\(size.width)x\(size.height):\(prefixEnd):"+prefixIDs.joined(separator:",")
        var loadedPrefix=false,savedPrefix=false
        if let key=prefixKey,let cached=staticBackgrounds.value(key) {
            RasterTools.composite(cached,into:scene);loadedPrefix=true;backgroundHits+=1
        }
        func savePrefix() {
            guard renderingFailure == nil,!loadedPrefix,!savedPrefix,let key=prefixKey,let image=scene.makeImage() else {return}
            staticBackgrounds.insert(image,key:key,bytes:image.bytesPerRow*image.height);savedPrefix=true
        }
        // A track may recur when another track falls between its items in depth.
        // Apply track effects to each contiguous run, retaining depth order.
        var passes:[(Int,[Clip])]=[]
        if depth==0,project.camera3D?.enabled == true {
            for clip in CameraDepthOrder.sorted(roots) where project.tracks.indices.contains(clip.track) && project.tracks[clip.track].visible {
                if let last=passes.indices.last,passes[last].0==clip.track {passes[last].1.append(clip)}
                else {passes.append((clip.track,[clip]))}
            }
        } else {
            passes=project.tracks.indices.filter{project.tracks[$0].visible}.map{($0,rootsByTrack[$0])}
        }
        for (index,items) in passes {
            let track=project.tracks[index]
            if index>=prefixEnd {savePrefix()}
            if loadedPrefix,index<prefixEnd {continue}
            guard !items.isEmpty else {continue}
            if track.opacity==0,!items.contains(where:{$0.kind == .adjustment && $0.adjustmentOwnLayer != true}) {continue}
            if !(track.effects ?? []).contains(where:{$0.enabled}),
               (track.blendMode ?? .normal) == .normal,(track.opacity ?? 1) == 1,
               items.allSatisfy({($0.blendMode ?? .normal) == .normal && !($0.kind == .adjustment && $0.adjustmentOwnLayer == true)}) {
                // Source-over composition is associative at full opacity. No isolated layer
                // buffer is needed when there are no layer effects or special blend modes.
                for clip in items {
                    if clip.kind == .adjustment {adjust(clip,context:scene,project:project,directory:directory,time:time)}
                    else if let raw=nodeImage(clip,project:project,directory:directory,time:time,clips:clips,size:size,depth:depth),let image=projected(raw,clip) {image.composite(into:scene)}
                }
                continue
            }
            guard var layer=bitmap(size) else {continue}
            func flush() {
                guard let image=layer.makeImage() else {return}
                let filtered=effectRenderer.apply(image,effects:track.effects ?? [],time:time,pixelScale:Double(size.width)/Double(project.width))
                RasterTools.composite(filtered,into:scene,mode:track.blendMode ?? .normal,opacity:track.opacity ?? 1)
            }
            for clip in items {
                if clip.kind == .adjustment {
                    if clip.adjustmentOwnLayer == true { adjust(clip,context:layer,project:project,directory:directory,time:time) }
                    else {flush();layer=bitmap(size)!;adjust(clip,context:scene,project:project,directory:directory,time:time)}
                } else if let raw=nodeImage(clip,project:project,directory:directory,time:time,clips:clips,size:size,depth:depth),let image=projected(raw,clip) {
                    if clip.blendMode == .add {
                        flush();layer=bitmap(size)!
                        let filtered=effectRenderer.apply(image.image,effects:track.effects ?? [],time:time,pixelScale:Double(size.width)/Double(project.width))
                        RasterTools.composite(filtered,into:scene,mode:.add,opacity:track.opacity ?? 1)
                    } else if let mode=clip.blendMode,mode != .normal {RasterTools.blend(image.image,into:layer,backdrop:scene,mode:mode)}
                    else {image.composite(into:layer)}
                }
            }
            flush()
        }
        if prefixEnd==project.tracks.count {savePrefix()}
        // AppKit window contexts have no bitmap width/height; use the view's size.
        if let image=scene.makeImage() {
            context.saveGState();context.setBlendMode(.normal);context.setAlpha(1)
            context.draw(image,in:CGRect(origin:.zero,size:size));context.restoreGState()
        }
    }
    private func adjust(_ clip:Clip,context:CGContext,project:Project,directory:URL,time:Double) {
        guard let original=context.makeImage() else {return}
        let shown=clip.animated(at:time,aspectRatio:Double(project.width)/Double(project.height))
        if partialAdjustments,shown.adjustmentRegion?.feather==0,!(clip.masks ?? []).contains(where:{$0.enabled}),
           let bounds=PartialAdjustment.bounds(shown,size:CGSize(width:context.width,height:context.height)),
           let mask=maskRenderer.regionMask(clip:shown,project:project,size:CGSize(width:context.width,height:context.height)),
           let filtered=effectRenderer.partial(original,effects:clip.effects ?? [],time:clip.motionTime(at:time),pixelScale:Double(context.width)/Double(project.width),mask:mask,bounds:bounds) {
            RasterTools.composite(filtered,into:context,mode:shown.blendMode ?? .normal,opacity:shown.opacity,rect:bounds);return
        }
        var filtered=effectRenderer.apply(original,effects:clip.effects ?? [],time:clip.motionTime(at:time),pixelScale:Double(context.width)/Double(project.width))
        filtered=maskRenderer.apply(filtered,masks:clip.masks ?? [],project:project,directory:directory,time:clip.motionTime(at:time))
        filtered=maskRenderer.applyRegion(filtered,clip:clip.animated(at:time,aspectRatio:Double(project.width)/Double(project.height)),project:project)
        RasterTools.composite(filtered,into:context,mode:clip.blendMode ?? .normal,opacity:clip.animated(at:time,aspectRatio:Double(project.width)/Double(project.height)).opacity)
    }
    private func nodeImage(_ original:Clip,project:Project,directory:URL,time:Double,clips:[Clip],size:CGSize,depth:Int) -> NodeRaster? {
        if original.temporalMotion != nil,let temporal=original.animated(at:time,aspectRatio:Double(project.width)/Double(project.height)).temporalMotion,original.kind != .adjustment,temporalSamplingDepth==0,depth<16 {
            temporalSamplingDepth+=1;defer{temporalSamplingDepth-=1}
            var sample=original;sample.temporalMotion=nil
            if let compact=compactTemporal(sample,settings:temporal,project:project,directory:directory,time:time,clips:clips,size:size,depth:depth){return compact}
            guard let output=bitmap(size) else{return nil}
            // Draw older trails first; the current object stays crisp over the trails.
            if temporal.trailCount>0,temporal.trailOpacity>0 {
                for index in stride(from:temporal.trailCount,through:1,by:-1) {
                    let t=time-temporal.trailDuration*Double(index)/Double(temporal.trailCount)
                    guard t>=original.start,let frame=nodeImage(sample,project:project,directory:directory,time:t,clips:project.visibleClips(at:t),size:size,depth:depth) else{continue}
                    RasterTools.composite(frame.image,into:output,opacity:temporal.trailOpacity*pow(1-Double(index)/Double(temporal.trailCount+1),2),rect:frame.rect)
                }
            }
            let times=temporal.exposureTimes(at:time,clip:original,fps:project.fps,playing:previewPlaying)
            if let exposure=bitmap(size) {
                exposure.setBlendMode(.plusLighter);exposure.setAlpha(1/Double(times.count))
                for t in times {if let frame=nodeImage(sample,project:project,directory:directory,time:t,clips:project.visibleClips(at:t),size:size,depth:depth){exposure.draw(frame.image,in:frame.rect)}}
                if let image=exposure.makeImage(){RasterTools.composite(image,into:output)}
            }
            return output.makeImage().map{NodeRaster(image:$0,rect:CGRect(origin:.zero,size:size))}
        }
        if boundedNodes,original.animated(at:time,aspectRatio:Double(project.width)/Double(project.height)).opacity==0 {return nil}
        let cacheable=reuseStaticLayers && !isGIFNode(original,project:project) && (isStaticNode(original,clips:clips,project:project) || (boundedNodes && isDiscreteImageNode(original,clips:clips)))
        var key="\(compositionScope?.uuidString ?? "root"):\(original.id):\(size.width)x\(size.height)"
        if cacheable,!isStaticNode(original,clips:clips,project:project) {
            let asset=project.mouthIsOpen(for:original,at:time) ? asset(original.mouthAssetID,project:project) ?? asset(original.assetID,project:project):asset(original.assetID,project:project)
            if let asset {
                key+=":"+asset.id.uuidString
                if let document=asset.psd {
                    let state=original.psd ?? .initial(document)
                    let visible=state.visibility(document:document,speaking:project.mouthIsOpen(for:original,at:time),time:time-original.start+original.sourceOffset,selectionTime:original.motionTime(at:time),mouthCue:state.vowelAnimation == true ? project.mouthCue(for:original,at:time):nil)
                    key+=":"+visible.sorted().map(String.init).joined(separator:",")
                }
            }
        }
        if cacheable,let hit=staticLayers.value(key){staticHits+=1;return hit}
        let result:NodeRaster
        if boundedNodes,let compact=boundedNode(original,project:project,directory:directory,time:time,clips:clips,size:size,depth:depth) {result=compact;boundedNodeRenders+=1}
        else {
            guard let image=renderNode(original,project:project,directory:directory,time:time,clips:clips,size:size,depth:depth) else{return nil}
            result=NodeRaster(image:image,rect:CGRect(origin:.zero,size:size))
        }
        if cacheable,renderingFailure == nil {staticLayers.insert(result,key:key,bytes:result.image.bytesPerRow*result.image.height)}
        return result
    }
    /// Small leaf objects keep both the temporal samples and accumulation buffers bounded.
    /// Complex effects/groups retain streamed full-frame sampling to limit peak memory.
    private func compactTemporal(_ clip:Clip,settings:TemporalMotion,project:Project,directory:URL,time:Double,clips:[Clip],size:CGSize,depth:Int)->NodeRaster? {
        guard boundedNodes,[.shape,.text,.speech].contains(clip.kind),clip.textAnimation==nil,clip.shapeStyle?.path==nil,clip.audioReactive==nil,
              (clip.blendMode ?? .normal) == .normal,clip.sceneMembers==nil,clip.precompositionID==nil,
              !(clip.masks ?? []).contains(where:{$0.enabled}),!(clip.effects ?? []).contains(where:{$0.enabled}),clip.transform?.perspective != true,
              !hasVisibleChildren(clip.id,clips:clips) else{return nil}
        var trails:[(NodeRaster,Double)]=[],samples:[NodeRaster]=[],bounds=CGRect.null,bytes=0
        func frame(_ t:Double)->NodeRaster? {
            guard let image=nodeImage(clip,project:project,directory:directory,time:t,clips:project.visibleClips(at:t),size:size,depth:depth) else{return nil}
            bytes+=image.image.bytesPerRow*image.image.height;bounds=bounds.union(image.rect);return image
        }
        if settings.trailCount>0,settings.trailOpacity>0 {for index in stride(from:settings.trailCount,through:1,by:-1){let t=time-settings.trailDuration*Double(index)/Double(settings.trailCount);if t>=clip.start,let image=frame(t){trails.append((image,settings.trailOpacity*pow(1-Double(index)/Double(settings.trailCount+1),2)))};if bytes>32*1024*1024{return nil}}}
        let times=settings.exposureTimes(at:time,clip:clip,fps:project.fps,playing:previewPlaying)
        for t in times{if let image=frame(t){samples.append(image)};if bytes>32*1024*1024{return nil}}
        bounds=bounds.integral.intersection(CGRect(origin:.zero,size:size))
        guard !bounds.isEmpty,!bounds.isNull,let output=bitmap(bounds.size),let exposure=bitmap(bounds.size) else{return nil}
        for (image,alpha) in trails{RasterTools.composite(image.image,into:output,opacity:alpha,rect:image.rect.offsetBy(dx:-bounds.minX,dy:-bounds.minY))}
        exposure.setBlendMode(.plusLighter);exposure.setAlpha(1/Double(times.count))
        for image in samples{exposure.draw(image.image,in:image.rect.offsetBy(dx:-bounds.minX,dy:-bounds.minY))}
        if let image=exposure.makeImage(){RasterTools.composite(image,into:output)}
        return output.makeImage().map{NodeRaster(image:$0,rect:bounds)}
    }
    private func isGIFNode(_ clip:Clip,project:Project)->Bool {
        guard clip.kind == .image else {return false}
        return [asset(clip.assetID,project:project),asset(clip.mouthAssetID,project:project)].compactMap{$0}.contains { URL(fileURLWithPath:$0.file).pathExtension.lowercased() == "gif" }
    }
    private func isStaticNode(_ clip:Clip,clips:[Clip],project:Project)->Bool {
        !isGIFNode(clip,project:project) && [.shape,.text,.speech,.image].contains(clip.kind) && clip.audioReactive==nil && clip.temporalMotion==nil && clip.shapeStyle?.path==nil && !(clip.masks ?? []).contains(where:{$0.path != nil}) && clip.animation==nil && clip.spatialAnimation==nil && clip.textAnimation==nil && clip.textRevealRate==nil && clip.mouthAssetID==nil && clip.psd?.mouthAnimation != true && clip.psd?.blink != true && (clip.psd?.selectionKeys ?? []).isEmpty && !(clip.effects ?? []).contains(where:{$0.enabled && (!$0.keys.isEmpty || $0.kind.timeVarying)}) && clip.sceneMembers==nil && clip.precompositionID==nil && !hasVisibleChildren(clip.id,clips:clips)
    }
    private func isDiscreteImageNode(_ clip:Clip,clips:[Clip])->Bool {
        clip.kind == .image && clip.audioReactive==nil && clip.temporalMotion==nil && clip.shapeStyle?.path==nil && !(clip.masks ?? []).contains(where:{$0.path != nil}) && clip.animation==nil && clip.spatialAnimation==nil && clip.textAnimation==nil && clip.sceneMembers==nil && clip.precompositionID==nil && clip.textRevealRate==nil && !(clip.effects ?? []).contains(where:{$0.enabled && (!$0.keys.isEmpty || $0.kind.timeVarying)}) && !hasVisibleChildren(clip.id,clips:clips)
    }
    /// Keep masks, perspective, effects, groups and special blends on the full-frame path.
    /// The bounded path retains the original two raster stages and pixel alignment.
    private func boundedNode(_ original:Clip,project:Project,directory:URL,time:Double,clips:[Clip],size:CGSize,depth:Int)->NodeRaster? {
        let clip=original.animated(at:time,aspectRatio:Double(project.width)/Double(project.height))
        guard original.audioReactive==nil,original.shapeStyle?.path==nil,original.textAnimation==nil,depth<16,[.shape,.text,.speech,.image].contains(clip.kind),
              (clip.blendMode ?? .normal) == .normal,clip.sceneMembers==nil && clip.precompositionID==nil,
              !(original.effects ?? []).contains(where:{$0.enabled}),
              !(original.masks ?? []).contains(where:{$0.enabled}),clip.transform?.perspective != true,
              !hasVisibleChildren(original.id,clips:clips),
              size.width.rounded()==size.width,size.height.rounded()==size.height else {return nil}
        let canvas=CGRect(origin:.zero,size:size)
        var neutral=clip;neutral.x=0.5;neutral.y=0.5;neutral.scale=1;neutral.rotation=0;neutral.flipX=false;neutral.flipY=false;neutral.anchorPoint=nil
        var bounds:CGRect
        switch clip.kind {
        case .shape:
            let style=clip.shapeStyle ?? ShapeStyle()
            bounds=ShapePainter.path(style,in:ShapePainter.rect(style,project:project)).boundingBoxOfPath
            let outline=style.outline ? style.outlineWidth/2:0
            let shadow=style.shadow ? style.shadowBlur*3+max(abs(style.shadowX),abs(style.shadowY)):0
            bounds=bounds.insetBy(dx:-(outline+shadow),dy:-(outline+shadow))
        case .text,.speech:
            bounds=textPainter.renderBounds(neutral,projectWidth:project.width,visibleCharacters:original.textRevealRate.map{max(0,Int(original.motionTime(at:time)*$0))})
        case .image:
            let asset=project.mouthIsOpen(for:clip,at:time) ? asset(clip.mouthAssetID,project:project) ?? asset(clip.assetID,project:project):asset(clip.assetID,project:project)
            guard let asset else {return nil}
            let dimensions:CGSize
            if let document=asset.psd {dimensions=CGSize(width:document.width,height:document.height)}
            else {
                let path=directory.appendingPathComponent("Media").appendingPathComponent(useProxies && asset.proxyFile.map({FileManager.default.fileExists(atPath:directory.appendingPathComponent("Media").appendingPathComponent($0).path)}) == true ? asset.proxyFile!:asset.file)
                guard let image=images.value(path.path) ?? NSImage(contentsOf:path),image.size.width>0,image.size.height>0 else {return nil}
                images.insert(image,key:path.path,bytes:image.renderCacheBytes);dimensions=image.size
            }
            let fit=min(Double(project.width)/dimensions.width,Double(project.height)/dimensions.height)
            bounds=clip.nineSlice?.rect(project:project) ?? CGRect(x:-dimensions.width*fit/2,y:-dimensions.height*fit/2,width:dimensions.width*fit,height:dimensions.height*fit)
        default:return nil
        }
        guard !bounds.isNull,!bounds.isEmpty else {return nil}
        bounds=bounds.offsetBy(dx:Double(project.width)/2,dy:Double(project.height)/2)
        let sourceRect=NodeRasterGeometry.pixelRect(bounds,project:project,size:size).insetBy(dx:-2,dy:-2).integral.intersection(canvas)
        guard !sourceRect.isEmpty else {return nil}
        let affine=NodeRasterGeometry.affine(clip,project:project)
        let dx=affine.tx*size.width/Double(project.width),dy = -affine.ty*size.height/Double(project.height)
        if affine.a==1,affine.b==0,affine.c==0,affine.d==1,dx.rounded()==dx,dy.rounded()==dy,clip.opacity==1 {
            // Integer translation does not resample: draw only the source bounds and
            // place them directly, preserving the original frame's pixel grid.
            guard let local=bitmap(sourceRect.size) else {return nil}
            local.translateBy(x:-sourceRect.minX,y:-sourceRect.minY);prepare(local,project:project,size:size)
            RasterTools.appKit(local){drawClip(neutral,original:original,project:project,directory:directory,time:time,context:local,renderSize:size)}
            return local.makeImage().map{NodeRaster(image:$0,rect:sourceRect.offsetBy(dx:dx,dy:dy))}
        }
        // A still image whose content does not change can reuse the exact full-frame
        // source raster before its transform. Keep NSImage's original-sized input
        // and the second raster stage so its interpolation and clipping stay intact.
        // Share the existing LRU budget with static nodes; do not reserve memory.
        if reuseNeutralImages,reuseStaticLayers,original.kind == .image,original.parentID == nil,
           original.animation != nil || original.spatialAnimation != nil,
           original.nineSlice == nil,original.mouthAssetID == nil,original.temporalMotion == nil,original.psd == nil,
           let media=asset(original.assetID,project:project),media.psd == nil,
           URL(fileURLWithPath:media.file).pathExtension.lowercased() != "gif",
           !(original.animation.map{[$0.entrance.kind,$0.exit.kind].contains(where:{[.wipeLeft,.wipeRight,.iris].contains($0)})} ?? false) {
            let path=useProxies && media.proxyFile.map({FileManager.default.fileExists(atPath:directory.appendingPathComponent("Media").appendingPathComponent($0).path)}) == true ? media.proxyFile!:media.file
            if URL(fileURLWithPath:path).pathExtension.lowercased() == "gif" {return nil}
            // Prefix and length keep this key disjoint from node keys and paths
            // containing separators. Asset paths can be shared by multiple clips.
            let key="neutral:\(compositionScope?.uuidString ?? "root"):\(project.width)x\(project.height):\(size.width)x\(size.height):\(path.utf8.count):\(path)"
            let input:CGImage
            if let cached=staticLayers.value(key) {input=cached.image;neutralImageHits+=1}
            else {
                guard let source=bitmap(size) else{return nil}
                prepare(source,project:project,size:size)
                RasterTools.appKit(source){drawClip(neutral,original:original,project:project,directory:directory,time:time,context:source,renderSize:size)}
                guard let image=source.makeImage() else{return nil}
                let bytes=image.bytesPerRow*image.height
                // Opportunistic admission: a new neutral raster must not evict
                // static nodes (or cycle through too many images every frame).
                if renderingFailure == nil,bytes<=staticLayers.budget-staticLayers.bytes {
                    staticLayers.insert(NodeRaster(image:image,rect:canvas),key:key,bytes:bytes)
                }
                input=image
            }
            let logicalRect=NodeRasterGeometry.projectRect(sourceRect,project:project,size:size)
            let outputRect=NodeRasterGeometry.pixelRect(logicalRect.applying(affine),project:project,size:size).insetBy(dx:-2,dy:-2).integral.intersection(canvas)
            guard !outputRect.isEmpty else{return nil}
            if boundNeutralTransforms {
                guard let cropped=bitmap(outputRect.size) else{return nil}
                cropped.translateBy(x:-outputRect.minX,y:-outputRect.minY)
                prepare(cropped,project:project,size:size)
                cropped.concatenate(clip.objectMatrix(project:project,canvasInput:true))
                RasterTools.appKit(cropped){RasterTools.image(input,project:project,opacity:clip.opacity)}
                return cropped.makeImage().map{NodeRaster(image:$0,rect:outputRect)}
            }
            guard let transformed=bitmap(size) else{return nil}
            prepare(transformed,project:project,size:size)
            transformed.concatenate(clip.objectMatrix(project:project,canvasInput:true))
            RasterTools.appKit(transformed){RasterTools.image(input,project:project,opacity:clip.opacity)}
            guard let full=transformed.makeImage(),let cropped=bitmap(outputRect.size) else{return nil}
            cropped.draw(full,in:CGRect(x:-outputRect.minX,y:-outputRect.minY,width:size.width,height:size.height))
            return cropped.makeImage().map{NodeRaster(image:$0,rect:outputRect)}
        }
        // NSImage interpolation depends on the source raster. Retain both original
        // stages for fractional/affine transforms, then copy only the result's bounds.
        let logicalRect=NodeRasterGeometry.projectRect(sourceRect,project:project,size:size)
        let outputRect=NodeRasterGeometry.pixelRect(logicalRect.applying(affine),project:project,size:size).insetBy(dx:-2,dy:-2).integral.intersection(canvas)
        guard !outputRect.isEmpty,
              let image=renderNode(original,project:project,directory:directory,time:time,clips:clips,size:size,depth:depth),
              let cropped=bitmap(outputRect.size) else {return nil}
        cropped.draw(image,in:CGRect(x:-outputRect.minX,y:-outputRect.minY,width:size.width,height:size.height))
        return cropped.makeImage().map{NodeRaster(image:$0,rect:outputRect)}
    }
    private func renderNode(_ original:Clip,project:Project,directory:URL,time:Double,clips:[Clip],size:CGSize,depth:Int)->CGImage? {
        guard depth<16,let local=bitmap(size) else {return nil}
        let clip=original.animated(at:time,aspectRatio:Double(project.width)/Double(project.height))
        if let composition=project.composition(original) {
            let previousScope=compositionScope;compositionScope=composition.id;defer{compositionScope=previousScope}
            let scene=project.compositionProject(composition),localTime=original.sourceOffset+time-original.start
            let childSize=CGSize(width:Double(composition.width)/Double(project.width)*size.width,height:Double(composition.height)/Double(project.height)*size.height)
            let quality=min(1,4096/max(childSize.width,childSize.height)),rasterSize=CGSize(width:childSize.width*quality,height:childSize.height*quality)
            guard let child=bitmap(rasterSize) else{return nil}
            drawComposition(project:scene,directory:directory,time:localTime,clips:scene.visibleClips(at:localTime),context:child,size:rasterSize,transparent:true,depth:depth+1)
            if let image=child.makeImage(){local.draw(image,in:CGRect(x:(size.width-childSize.width)/2,y:(size.height-childSize.height)/2,width:childSize.width,height:childSize.height))}
        } else if let members=original.sceneMembers {
            let ids=Set(members)
            var scene=project
            scene.clips=project.clips.filter{ids.contains($0.id)}.map{c -> Clip in var child=c;if child.parentID==original.id {child.parentID=nil};return child}
            // Compound scenes keep their layer effects, masks, and transitions isolated.
            drawComposition(project:scene,directory:directory,time:time,clips:scene.visibleClips(at:time),context:local,size:size,transparent:true,depth:depth+1)
        } else {
        local.saveGState();prepare(local,project:project,size:size)
        var neutral=clip;neutral.x=0.5;neutral.y=0.5;neutral.scale=1;neutral.rotation=0;neutral.flipX=false;neutral.flipY=false;neutral.anchorPoint=nil
        RasterTools.appKit(local) { drawClip(neutral,original:original,project:project,directory:directory,time:time,context:local,renderSize:size) }
        local.restoreGState()
        for child in (!reuseProjectLookups || potentialParents.contains(original.id)) ? clips.filter({$0.parentID==original.id && $0.kind != .audio}) : [] {
            if let image=nodeImage(child,project:project,directory:directory,time:time,clips:clips,size:size,depth:depth+1) {image.composite(into:local,mode:child.blendMode ?? .normal)}
        }
        }
        if original.precompositionID != nil {for child in (!reuseProjectLookups || potentialParents.contains(original.id)) ? clips.filter({$0.parentID==original.id && $0.kind != .audio}) : [] {if let image=nodeImage(child,project:project,directory:directory,time:time,clips:clips,size:size,depth:depth+1){image.composite(into:local,mode:child.blendMode ?? .normal)}}}
        guard var image=local.makeImage() else {return nil}
        var effects=original.effects ?? []
        if let reactive=original.audioReactive,reactive.glowAmount>0 {var glow=VisualEffect(kind:.glow);glow.amount=reactive.glowAmount*reactive.value(at:original.motionTime(at:time));if glow.amount>0{effects.append(glow)}}
        image=effectRenderer.apply(image,effects:effects,time:original.motionTime(at:time),pixelScale:Double(size.width)/Double(project.width))
        image=maskRenderer.apply(image,masks:original.masks ?? [],project:project,directory:directory,time:original.motionTime(at:time))
        image=maskRenderer.perspective(image,settings:clip.transform)
        let transform=clip.transform ?? Transform2D()
        if clip.x==0.5,clip.y==0.5,clip.scale==1,(clip.rotation ?? 0)==0,
           clip.flipX != true,clip.flipY != true,clip.opacity==1,
           transform.scaleX==1,transform.scaleY==1,transform.skewX==0,transform.skewY==0 {return image}
        guard let transformed=bitmap(size) else {return image}
        prepare(transformed,project:project,size:size)
        transformed.concatenate(clip.objectMatrix(project:project,canvasInput:true))
        RasterTools.appKit(transformed) { RasterTools.image(image,project:project,opacity:clip.opacity) }
        return transformed.makeImage()
    }
    private func drawClip(_ clip: Clip, original: Clip, project: Project, directory: URL, time: Double, context: CGContext,renderSize:CGSize) {
        context.saveGState(); defer { context.restoreGState() }
        let center = CGPoint(x: clip.x * Double(project.width), y: clip.y * Double(project.height))
        if let animation = original.animation {
            let local = original.motionTime(at: time), span = animation.span ?? original.duration
            for (spec, progress) in [(animation.entrance, local / max(0.001, animation.entrance.duration)), (animation.exit, (span - local) / max(0.001, animation.exit.duration))] {
                let p = min(1, max(0, spec.easing.value(progress)))
                if spec.kind == .wipeLeft { context.clip(to: CGRect(x: 0, y: 0, width: Double(project.width) * p, height: Double(project.height))) }
                if spec.kind == .wipeRight { context.clip(to: CGRect(x: Double(project.width) * (1-p), y: 0, width: Double(project.width) * p, height: Double(project.height))) }
                if spec.kind == .iris {
                    let radius = hypot(Double(project.width), Double(project.height)) / 2 * p
                    context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)); context.clip()
                }
            }
        }
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: (clip.rotation ?? 0) * .pi / 180)
        context.scaleBy(x: clip.flipX == true ? -1 : 1, y: clip.flipY == true ? -1 : 1)
        context.translateBy(x: -center.x, y: -center.y)
            switch clip.kind {
            case .text, .speech:
                if clip.kind != .speech || clip.speechCaptionHidden != true {
                    textPainter.draw(clip, projectWidth: project.width, center: center, context: context,visibleCharacters:original.textRevealRate.map{max(0,Int(original.motionTime(at:time)*$0))},time:original.motionTime(at:time))
                }
            case .shape:
                ShapePainter.draw(clip,project:project,center:center,context:context,time:original.motionTime(at:time))
            case .image, .video:
                let visualAsset = project.mouthIsOpen(for: clip, at: time) ? asset(clip.mouthAssetID,project:project) ?? asset(clip.assetID,project:project) : asset(clip.assetID,project:project)
                if let asset = visualAsset {
                    // An image proxy is a still; animated GIFs need their original frames.
                    let isGIF=URL(fileURLWithPath:asset.file).pathExtension.lowercased() == "gif"
                    let path = directory.appendingPathComponent("Media").appendingPathComponent(!isGIF && useProxies && asset.proxyFile.map({FileManager.default.fileExists(atPath:directory.appendingPathComponent("Media").appendingPathComponent($0).path)}) == true ? asset.proxyFile!:asset.file)
                    var image: NSImage?
                    if let document = asset.psd {
                        image = psdRenderer.image(asset: asset, state: clip.psd ?? .initial(document), directory: directory,
                                                  speaking: project.mouthIsOpen(for: clip, at: time), time: time - clip.start + clip.sourceOffset, selectionTime:clip.motionTime(at:time),mouthCue:clip.psd?.vowelAnimation == true ? project.mouthCue(for:clip,at:time):nil)
                    } else if clip.kind == .image {
                        if let sequence=gifs.value(path.path) ?? AnimatedGIF(url:path) {
                            gifs.insert(sequence,key:path.path,bytes:1)
                            let sample=max(0,original.sourceTime(at:time)-(original.reversed == true ? 1.0/60000 : 0))
                            let index=sequence.frameIndex(at:sample),key="\(path.path)#gif-frame-\(index)"
                            image=images.value(key) ?? sequence.image(at:index)
                            if let image {images.insert(image,key:key,bytes:image.renderCacheBytes)}
                        } else {
                            image=images.value(path.path) ?? NSImage(contentsOf:path)
                            if let image {images.insert(image,key:path.path,bytes:image.renderCacheBytes)}
                        }
                    } else {
                        let generator:AVAssetImageGenerator
                        if let cached=generators.value(path.path){generator=cached} else {
                            generator = AVAssetImageGenerator(asset: AVURLAsset(url: path))
                            generator.appliesPreferredTrackTransform = true
                            generator.requestedTimeToleranceBefore = .zero
                            generator.requestedTimeToleranceAfter = .zero
                            generator.maximumSize = useProxies ? renderSize:CGSize(width:project.width,height:project.height)
                            generators.insert(generator,key:path.path,bytes:1)
                        }
                        if useProxies {generator.maximumSize=renderSize}
                        let previewTime=useProxies && previewPlaying ? floor(time*Double(project.fps))/Double(project.fps):time
                        // Source intervals have an exclusive upper bound: in reverse,
                        // sample just before each boundary instead of the next frame.
                        func videoTime(_ timelineTime:Double)->Double {
                            min(max(0,asset.duration-1.0/60000),max(0,original.sourceTime(at:timelineTime)-(original.reversed == true ? 1.0/60000 : 0)))
                        }
                        let sourceTime = videoTime(previewTime)
                        let stamp=CMTime(seconds:sourceTime,preferredTimescale:60000)
                        let cached=useProxies && previewPlaying ? videoPrefetch.image(path:path,size:renderSize,time:stamp):nil
                        if let cached {image = NSImage(cgImage:cached,size:.zero)}
                        else {
                            do {image = NSImage(cgImage:try generator.copyCGImage(at:stamp,actualTime:nil),size:.zero)}
                            catch {
                                if videoDecodeFailure == nil {
                                    videoDecodeFailure=String(format:"動画「%@」の %.3f 秒を読み込めませんでした。素材を確認してください。",asset.name,sourceTime)
                                }
                            }
                        }
                        if useProxies && previewPlaying {
                            let times=(1...2).map{CMTime(seconds:videoTime(previewTime+Double($0)/Double(project.fps)),preferredTimescale:60000)}
                            videoPrefetch.request(path:path,size:renderSize,times:times)
                        }
                    }
                    if let image, image.size.width > 0, image.size.height > 0 {
                        let fit = min(Double(project.width) / image.size.width, Double(project.height) / image.size.height) * clip.scale
                        if let slice=clip.nineSlice,clip.kind == .image {
                            let base=slice.rect(project:project),rect=CGRect(x:center.x+base.minX*clip.scale,y:center.y+base.minY*clip.scale,width:base.width*clip.scale,height:base.height*clip.scale)
                            NineSlicePainter.draw(image,in:rect,project:project,settings:slice)
                        } else {
                            let rect = CGRect(x: center.x - image.size.width * fit / 2, y: center.y - image.size.height * fit / 2, width: image.size.width * fit, height: image.size.height * fit)
                            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                        }
                    }
                }
            case .particles: ParticleRenderer.draw(clip,project:project,time:time,context:context,detail:previewParticleDetail)
            case .audio, .transition, .group, .adjustment: break
            }
    }
}

enum MovieExporter {
    static func export(project: Project, directory: URL, destination: URL, options:UserSettings=UserSettings(), overwrite:Bool=true, optimizeRendering:Bool=true, rendererOverride:FrameRenderer?=nil, phase:@escaping @Sendable (ExportPhase)->Void = {_ in}, progress: @escaping @Sendable (Double) -> Void) async throws {
        phase(.preparing)
        _ = try project.validated()
        try options.validateExportOverrides()
        let dimensions=options.exportDimensions(project)
        let fit=options.exportFitRect(project)
        guard project.duration > 0 else { throw VMMError.message("タイムラインにアイテムを追加してください。") }
        let report=ExportPreflight.inspect(project:project,directory:directory,options:options)
        guard report.canExport else {throw VMMError.message(report.issues.filter{$0.severity == .error}.map(\.message).joined(separator:"\n"))}
        let rangeStart=max(0,options.rangeStart),rangeEnd=options.rangeEnd>0 ? min(project.duration,options.rangeEnd):project.duration
        guard rangeStart.isFinite,rangeEnd.isFinite,rangeEnd>rangeStart,(0.1...1).contains(options.exportQuality),["H.264","HEVC","ProRes 422"].contains(options.exportCodec),["MP4","MOV"].contains(options.exportContainer) else {throw VMMError.message("書き出し範囲・形式が不正です。")}
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("vmm-export-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let silent = scratch.appendingPathComponent(options.exportCodec == "ProRes 422" ? "render.mov":"render.mp4")
        let writer = try AVAssetWriter(outputURL: silent, fileType: options.exportCodec == "ProRes 422" ? .mov:.mp4)
        var compression:[String:Any]=[AVVideoAverageBitRateKey:options.exportVideoMbps.map{Int($0*1_000_000)} ?? max(200_000,Int(Double(dimensions.width*dimensions.height*dimensions.fps)*(0.025+options.exportQuality*0.2)))]
        if options.usesExplicitExportEncoding && options.exportCodec == "H.264" {
            compression[AVVideoProfileLevelKey]=AVVideoProfileLevelH264HighAutoLevel
            compression[AVVideoMaxKeyFrameIntervalKey]=dimensions.fps*2
        }
        var videoSettings:[String:Any]=[
            AVVideoCodecKey: options.exportCodec == "ProRes 422" ? AVVideoCodecType.proRes422:options.exportCodec == "HEVC" ? AVVideoCodecType.hevc:AVVideoCodecType.h264,
            AVVideoWidthKey:dimensions.width,AVVideoHeightKey:dimensions.height,
            AVVideoColorPropertiesKey:[AVVideoColorPrimariesKey:AVVideoColorPrimaries_ITU_R_709_2,AVVideoTransferFunctionKey:AVVideoTransferFunction_ITU_R_709_2,AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_709_2]
        ]
        if options.exportCodec != "ProRes 422" {videoSettings[AVVideoCompressionPropertiesKey]=compression}
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: dimensions.width,
            kCVPixelBufferHeightKey as String: dimensions.height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? VMMError.message("動画の作成を開始できませんでした。") }
        writer.startSession(atSourceTime: .zero)
        phase(.rendering)
        let renderer = rendererOverride ?? FrameRenderer(useProxies:false)
        renderer.boundedNodes=optimizeRendering;renderer.reuseStaticBackgrounds=optimizeRendering
        let count = Int(ceil((rangeEnd-rangeStart) * Double(dimensions.fps)))
        do {
            for frame in 0..<count {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    if writer.status == .failed { throw writer.error ?? VMMError.message("エンコードに失敗しました。") }
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                try autoreleasepool {
                    var buffer: CVPixelBuffer?
                    guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
                        throw VMMError.message("動画用メモリを確保できませんでした。")
                    }
                    CVPixelBufferLockBaseAddress(buffer, [])
                    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: dimensions.width, height: dimensions.height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
                        throw VMMError.message("描画領域を作成できませんでした。")
                    }
                    context.setFillColor(NSColor.black.cgColor);context.fill(CGRect(x:0,y:0,width:dimensions.width,height:dimensions.height))
                    context.translateBy(x:fit.minX,y:fit.minY)
                    renderer.draw(project: project, directory: directory, time: rangeStart+Double(frame) / Double(dimensions.fps), context: context, size: fit.size)
                    if let failure=renderer.renderingFailure {throw VMMError.message(failure)}
                    guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(dimensions.fps))) else {
                        throw writer.error ?? VMMError.message("フレームを書き込めませんでした。")
                    }
                }
                if frame % 10 == 0 { progress(Double(frame) / Double(count) * 0.85) }
            }
            writer.endSession(atSourceTime: CMTime(value: Int64(count), timescale: Int32(dimensions.fps)))
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? VMMError.message("動画の保存に失敗しました。") }
        } catch { writer.cancelWriting(); throw error }
        try Task.checkCancellation()
        phase(.audioPreparing)
        progress(0.85)
        let composition = AVMutableComposition()
        let rendered = AVURLAsset(url: silent)
        let duration = try await rendered.load(.duration)
        guard let video = try await rendered.loadTracks(withMediaType: .video).first,
              let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VMMError.message("描画した動画を読み込めませんでした。")
        }
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: video, at:CMTime(seconds:rangeStart,preferredTimescale:600))
        let mix=try await AudioExportComposition.assemble(project:project,directory:directory,options:options,scratch:scratch,composition:composition){value in progress(0.85+0.05*value)}
        let output = scratch.appendingPathComponent(options.exportContainer == "MOV" ? "final.mov":"final.mp4")
        let range=CMTimeRange(start:CMTime(seconds:rangeStart,preferredTimescale:600),end:CMTime(seconds:rangeEnd,preferredTimescale:600))
        phase(.muxing)
        progress(0.90)
        if options.usesExplicitExportEncoding {
            try await ExportMuxer.write(composition:composition,mix:mix,range:range,output:output,options:options){value in progress(0.90+0.08*value)}
        } else {
            guard let session=AVAssetExportSession(asset:composition,presetName:options.exportCodec == "HEVC" ? AVAssetExportPresetHEVCHighestQuality:AVAssetExportPresetHighestQuality) else{throw VMMError.message("書き出しを開始できませんでした。")}
            session.outputURL=output;session.outputFileType=options.exportContainer == "MOV" ? .mov:.mp4
            session.audioMix=mix;session.timeRange=range
            let monitor=Task {
                while !Task.isCancelled {
                    progress(0.90+0.08*Double(min(1,max(0,session.progress))))
                    try? await Task.sleep(nanoseconds:200_000_000)
                }
            }
            await withTaskCancellationHandler(operation:{await session.export()},onCancel:{session.cancelExport()})
            monitor.cancel()
            _ = await monitor.value
            try Task.checkCancellation()
            guard session.status == .completed else{throw session.error ?? VMMError.message("音声の合成に失敗しました。")}
        }
        phase(.saving)
        progress(0.98)
        // The existing file is replaced only after a complete render is available.
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".vmm-\(UUID()).mp4")
        try FileManager.default.copyItem(at: output, to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        try ExportFileCommit.install(staging,to:destination,overwrite:overwrite)
        progress(1)
    }
}
