import AppKit
import CoreText
import CoreImage

/// One combined glyph path prevents a later glyph's shadow from covering an
/// earlier glyph. Shadow, outline, and fill are composited in that order.
final class TextPainter {
    private struct LayoutKey: Equatable {
        let text: String
        let size: Double
        let width: Double
        let font:String
        let tracking:Double
        let spacing:Double
        let visible:Int?
        let alignment:TextAlignment
        let animated:Bool
        let runs:[TextRun]?
        let ruby:[LyricRuby]?
        let scale:Double
    }
    private struct GlyphPiece {var index:Int;var path:CGPath;var ruby:Bool=false}
    private struct GlyphLayout {var path:CGPath;var pieces:[GlyphPiece]}
    private struct PaintPiece {var path:CGPath;var alpha:Double;var blur:Double;var style:TextRunStyle;var index:Int?=nil;var ruby:Bool=false}
    private let ci=CIContext(options:[.cacheIntermediates:false])
    private var cache: [UUID: (LayoutKey, GlyphLayout)] = [:]
    private func layout(_ clip:Clip,projectWidth:Int,visibleCharacters:Int?)->(glyphs:GlyphLayout,size:Double) {
        let style=clip.textStyle ?? TextStyle()
        let key = LayoutKey(text: clip.text, size: clip.fontSize * clip.scale, width: Double(projectWidth) * (style.captionWidth ?? 0.9),font:style.fontName ?? "HiraginoSans-W6",tracking:style.tracking ?? 0,spacing:style.lineSpacing ?? 0,visible:visibleCharacters,alignment:style.alignment ?? .center,animated:clip.textAnimation != nil || clip.lyricWipe?.segments != nil,runs:clip.textRuns,ruby:clip.lyricRuby,scale:clip.scale)
        let path: GlyphLayout
        if let hit = cache[clip.id], hit.0 == key { path = hit.1 }
        else {
            var layout=glyphPath(text: key.text, size: key.size, width: key.width,fontName:key.font,tracking:key.tracking,spacing:key.spacing,visible:key.visible,alignment:key.alignment,animated:key.animated,runs:key.runs,scale:key.scale)
            if let ruby=key.ruby,!ruby.isEmpty {
                let combined=CGMutablePath();combined.addPath(layout.path)
                for item in ruby where item.startIndex>=0 && item.endIndex>item.startIndex && item.endIndex<=key.text.count && (key.visible == nil || item.endIndex<=key.visible!) {
                    let base=layout.pieces.filter{$0.index>=item.startIndex && $0.index<item.endIndex}.reduce(CGRect.null){$0.union($1.path.boundingBoxOfPath)}
                    guard !base.isNull,base.width>0 else{continue}
                    let size=key.size*0.42,width=min(key.width,max(base.width,size*Double(item.text.count)))
                    let annotation=glyphPath(text:item.text,size:size,width:width,fontName:key.font,tracking:0,spacing:0,visible:nil,alignment:.center)
                    let bounds=annotation.path.boundingBoxOfPath
                    guard !bounds.isNull else{continue}
                    var transform=CGAffineTransform(translationX:base.midX-bounds.midX,y:base.minY-bounds.maxY-key.size*0.06)
                    if let shape=annotation.path.copy(using:&transform) {combined.addPath(shape);layout.pieces.append(GlyphPiece(index:item.startIndex,path:shape,ruby:true))}
                }
                layout.path=combined
            }
            path=layout
            if cache.count > 256 { cache.removeAll() }
            cache[clip.id] = (key, path)
        }
        return (path,key.size)
    }
    func draw(_ clip: Clip, projectWidth: Int, center: CGPoint, context: CGContext, visibleCharacters:Int? = nil, time:Double = 0) {
        let style=clip.textStyle ?? TextStyle()
        let (glyphs,fontSize)=layout(clip,projectWidth:projectWidth,visibleCharacters:visibleCharacters)
        guard !glyphs.path.isEmpty else { return }
        var pieces:[PaintPiece]
        if clip.textAnimation == nil && clip.lyricWipe?.segments == nil && (clip.textRuns ?? []).isEmpty {pieces=[PaintPiece(path:glyphs.path,alpha:1,blur:0,style:TextRunStyle())]}
        else {
            let styles=TextRunEditing.styles(clip.textRuns,count:clip.text.count)
            pieces=glyphs.pieces.compactMap{piece in
                let custom=styles.indices.contains(piece.index) ? styles[piece.index]:TextRunStyle()
                guard let animation=clip.textAnimation else{return PaintPiece(path:piece.path,alpha:1,blur:0,style:custom,index:piece.index,ruby:piece.ruby)}
                let pose=animation.pose(index:piece.index,count:clip.text.count,time:time),box=piece.path.boundingBoxOfPath
                guard pose.opacity>0 else{return nil}
                var transform=CGAffineTransform(translationX:box.midX,y:box.midY+pose.y*clip.scale).rotated(by:pose.rotation * .pi/180).scaledBy(x:pose.scale,y:pose.scale).translatedBy(x:-box.midX,y:-box.midY)
                return piece.path.copy(using:&transform).map{PaintPiece(path:$0,alpha:pose.opacity,blur:pose.blur*clip.scale,style:custom,index:piece.index,ruby:piece.ruby)}
            }
        }
        if clip.lyricWipe?.segments == nil,pieces.count>1,pieces.allSatisfy({$0.alpha==1 && $0.blur==0 && $0.style==pieces[0].style}) {let combined=CGMutablePath();for piece in pieces{combined.addPath(piece.path)};pieces=[PaintPiece(path:combined,alpha:1,blur:0,style:pieces[0].style)]}
        let gradientBounds=pieces.reduce(CGRect.null){$0.union($1.path.boundingBoxOfPath)}
        context.saveGState();defer{context.restoreGState()}
        context.translateBy(x:center.x,y:center.y)
        context.beginTransparencyLayer(auxiliaryInfo:nil)
        func stroke(_ piece:PaintPiece)->Double {(piece.style.outline ?? style.outline) ? (piece.style.fontSize.map{$0*clip.scale} ?? fontSize)*(piece.style.outlineWidth ?? style.outlineWidth)/100:0}
        // Composite all shadows before any glyph fill or outline.
        if style.shadow {for piece in pieces {
            let path=piece.path,strokeWidth=stroke(piece)
            context.saveGState();context.setAlpha(piece.alpha)
            let margin=strokeWidth/2+style.shadowBlur*clip.scale*3+max(abs(style.shadowX),abs(style.shadowY))*clip.scale
            blurred(path,amount:piece.blur,margin:margin,context:context){c in
                c.setLineWidth(strokeWidth);c.setLineJoin(.round)
                c.setShadow(offset:CGSize(width:style.shadowX*clip.scale,height:-style.shadowY*clip.scale),blur:style.shadowBlur*clip.scale,color:NSColor(hex:style.shadowColor).withAlphaComponent(style.shadowOpacity).cgColor)
                c.setFillColor(NSColor.black.cgColor);c.setStrokeColor(NSColor.black.cgColor)
                c.addPath(path);c.drawPath(using:strokeWidth>0 ? .fillStroke:.fill)
            };context.restoreGState()
        }}
        for piece in pieces where stroke(piece)>0 {context.saveGState();context.setAlpha(piece.alpha)
            let outline=piece.path.copy(strokingWithWidth:stroke(piece),lineCap:.round,lineJoin:.round,miterLimit:10)
            blurred(outline,amount:piece.blur,context:context){c in self.paint(outline,color:piece.style.outlineColor ?? style.outlineColor,gradient:style.outlineGradient,context:c,bounds:gradientBounds)};context.restoreGState()
        }
        for piece in pieces {context.saveGState();context.setAlpha(piece.alpha)
            blurred(piece.path,amount:piece.blur,context:context){c in self.paint(piece.path,color:piece.style.color ?? clip.color,gradient:style.fillGradient,context:c,bounds:gradientBounds)};context.restoreGState()
        }
        if let wipe=clip.lyricWipe,let segments=wipe.segments {
            for segment in segments {
                let members=pieces.filter{piece in !piece.ruby && (piece.index.map{$0>=segment.startIndex && $0<segment.endIndex} ?? false)}
                let bounds=members.reduce(CGRect.null){$0.union($1.path.boundingBoxOfPath)}
                let progress=segment.end==segment.start ? (time>=segment.end ? 1.0:0.0):min(1,max(0,(time-segment.start)/(segment.end-segment.start)))
                guard !bounds.isNull,bounds.width>0,progress>0 else{continue}
                context.saveGState();context.clip(to:CGRect(x:bounds.minX,y:bounds.minY-1,width:bounds.width*progress,height:bounds.height+2))
                for piece in members {context.saveGState();context.setAlpha(piece.alpha);blurred(piece.path,amount:piece.blur,context:context){c in self.paint(piece.path,color:wipe.color,gradient:nil,context:c,bounds:gradientBounds)};context.restoreGState()}
                context.restoreGState()
            }
            for item in clip.lyricRuby ?? [] {
                let related=segments.filter{max($0.startIndex,item.startIndex)<min($0.endIndex,item.endIndex)}
                guard let first=related.first,let last=related.last,let piece=pieces.first(where:{$0.ruby && $0.index==item.startIndex}) else{continue}
                let bounds=piece.path.boundingBoxOfPath,progress=item.progress(at:time,start:first.start,end:last.end)
                guard !bounds.isNull,bounds.width>0,progress>0 else{continue}
                context.saveGState();context.clip(to:CGRect(x:bounds.minX,y:bounds.minY-1,width:bounds.width*progress,height:bounds.height+2));context.setAlpha(piece.alpha)
                blurred(piece.path,amount:piece.blur,context:context){c in self.paint(piece.path,color:wipe.color,gradient:nil,context:c,bounds:gradientBounds)}
                context.restoreGState()
            }
        } else if let wipe=clip.lyricWipe,gradientBounds.width>0 {
            let progress=wipe.progress(at:time)
            if progress>0 {
                context.saveGState()
                context.clip(to:CGRect(x:gradientBounds.minX,y:gradientBounds.minY-1,width:gradientBounds.width*progress,height:gradientBounds.height+2))
                for piece in pieces {context.saveGState();context.setAlpha(piece.alpha)
                    blurred(piece.path,amount:piece.blur,context:context){c in self.paint(piece.path,color:wipe.color,gradient:nil,context:c,bounds:gradientBounds)}
                    context.restoreGState()
                }
                context.restoreGState()
            }
        }
        context.endTransparencyLayer()
    }
    /// Blur only the changing character bounds, never an entire project-sized frame.
    private func blurred(_ path:CGPath,amount:Double,margin:Double=0,context:CGContext,paint:(CGContext)->Void) {
        guard amount>0.15 else{context.saveGState();paint(context);context.restoreGState();return}
        let rect=path.boundingBoxOfPath.insetBy(dx:-(ceil(amount*3)+margin+2),dy:-(ceil(amount*3)+margin+2)).integral
        guard rect.width>0,rect.height>0,rect.width<=8192,rect.height<=8192,let raster=RasterTools.bitmap(rect.size) else{return}
        raster.translateBy(x:-rect.minX,y:rect.maxY);raster.scaleBy(x:1,y:-1);paint(raster)
        guard let source=raster.makeImage() else{return}
        let image=CIImage(cgImage:source),filtered=image.applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:amount]).cropped(to:image.extent)
        guard let result=ci.createCGImage(filtered,from:image.extent) else{return}
        RasterTools.appKit(context){NSImage(cgImage:result,size:rect.size).draw(in:rect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)}
    }
    /// Bounds of the same cached glyph path used by draw(), including outline and shadow.
    func renderBounds(_ clip:Clip,projectWidth:Int,visibleCharacters:Int?)->CGRect {
        let (glyphs,size)=layout(clip,projectWidth:projectWidth,visibleCharacters:visibleCharacters)
        let path=glyphs.path
        guard !path.isEmpty else {return .null}
        let style=clip.textStyle ?? TextStyle()
        let baseWidth=style.outline ? size*style.outlineWidth/200:0
        let maxWidth=(clip.textRuns ?? []).map{r in (r.style.outline ?? style.outline) ? (r.style.fontSize.map{$0*clip.scale} ?? size)*(r.style.outlineWidth ?? style.outlineWidth)/200:0}.max() ?? 0
        var rect=path.boundingBoxOfPath.insetBy(dx:-max(baseWidth,maxWidth),dy:-max(baseWidth,maxWidth))
        if style.shadow {
            let margin=style.shadowBlur*clip.scale*3+max(abs(style.shadowX),abs(style.shadowY))*clip.scale
            rect=rect.insetBy(dx:-margin,dy:-margin)
        }
        return rect
    }
    func bounds(_ clip:Clip,projectWidth:Int)->CGRect {
        var unscaled=clip;unscaled.scale=1
        return layout(unscaled,projectWidth:projectWidth,visibleCharacters:nil).glyphs.path.boundingBoxOfPath
    }
    private func paint(_ path: CGPath, color: String, gradient: TextGradient?, context: CGContext,bounds:CGRect?=nil) {
        context.saveGState(); defer { context.restoreGState() }
        guard let gradient, gradient.enabled else {
            context.setFillColor(NSColor(hex: color).cgColor); context.addPath(path); context.fillPath(); return
        }
        let box = bounds ?? path.boundingBoxOfPath
        let angle = gradient.angle * .pi / 180
        let dx = cos(angle), dy = sin(angle)
        let extent = (abs(dx) * box.width + abs(dy) * box.height) / 2
        let center = CGPoint(x: box.midX, y: box.midY)
        let colors = [NSColor(hex: color).cgColor, NSColor(hex: gradient.endColor).cgColor] as CFArray
        guard let ramp = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
        context.addPath(path); context.clip()
        context.drawLinearGradient(ramp, start: CGPoint(x: center.x - dx * extent, y: center.y - dy * extent), end: CGPoint(x: center.x + dx * extent, y: center.y + dy * extent), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    private func glyphPath(text: String, size: Double, width: Double,fontName:String,tracking:Double,spacing:Double,visible:Int?,alignment:TextAlignment,animated:Bool=false,runs:[TextRun]?=nil,scale:Double=1) -> GlyphLayout {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = alignment == .center ? .center : (alignment == .right ? .right : .left); paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing=spacing*size
        let font = NSFont(name: fontName, size: size) ?? NSFont.systemFont(ofSize: size, weight: .bold)
        let string = NSMutableAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraph, .kern:tracking*size, .ligature:alignment == .distributed || animated || !(runs ?? []).isEmpty ? 0:1])
        let chars=Array(text);var offsets=[Int](repeating:0,count:chars.count+1)
        for i in chars.indices {offsets[i+1]=offsets[i]+String(chars[i]).utf16.count}
        for run in runs ?? [] where run.start>=0 && run.start<chars.count && run.end>run.start {
            let end=min(chars.count,run.end),runFont=NSFont(name:run.style.fontName ?? fontName,size:(run.style.fontSize.map{$0*scale} ?? size)) ?? NSFont.systemFont(ofSize:(run.style.fontSize.map{$0*scale} ?? size),weight:.bold)
            string.addAttribute(.font,value:runFont,range:NSRange(location:offsets[run.start],length:offsets[end]-offsets[run.start]))
        }
        let setter = CTFramesetterCreateWithAttributedString(string)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        let height = ceil(measured.height) + 4
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let result = CGMutablePath()
        var clusters:[Int:Int]=[:],utf16=0
        for (i,char) in text.enumerated(){for u in 0..<String(char).utf16.count{clusters[utf16+u]=i};utf16+=String(char).utf16.count}
        var pieces:[Int:CGMutablePath]=[:]
        for (index, line) in lines.enumerated() {
            // Spread grapheme clusters across the full caption width, including
            // the final line. Keep reveal positions stable while hiding glyphs.
            let range=CTLineGetStringRange(line)
            var lineText=(text as NSString).substring(with:NSRange(location:range.location,length:range.length))
            while let last=lineText.last,last.isWhitespace{lineText.removeLast()}
            var slots:[Int:Int]=[:],offset=range.location
            for (slot,character) in lineText.enumerated(){for unit in 0..<String(character).utf16.count{slots[offset+unit]=slot};offset+=String(character).utf16.count}
            let extra=alignment == .distributed && lineText.count>1 ? max(0,width-CTLineGetTypographicBounds(line,nil,nil,nil)+CTLineGetTrailingWhitespaceWidth(line))/Double(lineText.count-1):0

            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let runFont = attributes[kCTFontAttributeName] as! CTFont
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                var indices=[CFIndex](repeating:0,count:count);CTRunGetStringIndices(run,CFRange(location:0,length:0),&indices)
                let visibleUTF16=visible.map{String(text.prefix($0)).utf16.count} ?? text.utf16.count
                for i in 0..<count where indices[i]<visibleUTF16 {
                    if let glyph = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) {
                        var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: origins[index].x + positions[i].x - width / 2 + extra*Double(slots[indices[i]] ?? 0), ty: height / 2 - origins[index].y - positions[i].y)
                        if let placed = glyph.copy(using: &transform) { result.addPath(placed);let slot=clusters[indices[i]] ?? 0;let part=pieces[slot] ?? CGMutablePath();part.addPath(placed);pieces[slot]=part }
                    }
                }
            }
        }
        return GlyphLayout(path:result,pieces:pieces.keys.sorted().map{GlyphPiece(index:$0,path:pieces[$0]!)})
    }
}
