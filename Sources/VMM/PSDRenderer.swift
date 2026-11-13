import AppKit

final class PSDRenderer {
    private var cachedDirectory:URL?
    private let images=RenderCache<NSImage>(budget:64*1024*1024)
    private let composites=RenderCache<NSImage>(budget:64*1024*1024)
    var cacheBytes:Int {images.bytes+composites.bytes}
    func setCacheBudget(_ bytes:Int){images.budget=bytes/2;composites.budget=bytes-bytes/2}
    func image(asset: MediaAsset, state: PSDState, directory: URL, speaking: Bool, time: Double, maximumSize: CGSize? = nil, selectionTime:Double? = nil, mouthCue:ProjectMouthCue? = nil) -> NSImage? {
        guard let document = asset.psd else { return nil }
        if cachedDirectory != directory {images.clear();composites.clear();cachedDirectory=directory}
        let scale = maximumSize.map { min(1, $0.width / CGFloat(document.width), $0.height / CGFloat(document.height)) } ?? 1
        let width = max(1, Int(ceil(CGFloat(document.width) * scale)))
        let height = max(1, Int(ceil(CGFloat(document.height) * scale)))
        let visible = state.visibility(document: document, speaking: speaking, time: time, selectionTime:selectionTime, mouthCue:mouthCue)
        let key = directory.appendingPathComponent("Media").appendingPathComponent(asset.file).path + ":\(width)x\(height):\(state.flipX):\(state.flipY):" + visible.sorted().map(String.init).joined(separator: ",")
        if let cached = composites.value(key) { return cached }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: state.flipX ? CGFloat(document.width) : 0, y: state.flipY ? 0 : CGFloat(document.height))
        context.scaleBy(x: state.flipX ? -1 : 1, y: state.flipY ? 1 : -1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.current = previous }
        func drawChildren(_ parent: Int?) {
            for layer in document.layers.reversed() where layer.parent == parent && visible.contains(layer.id) {
                if layer.group {
                    if layer.blend == "pass" { drawChildren(layer.id) }
                    else {
                        context.saveGState(); context.setAlpha(layer.opacity)
                        context.beginTransparencyLayer(auxiliaryInfo: nil)
                        drawChildren(layer.id)
                        context.endTransparencyLayer(); context.restoreGState()
                    }
                } else if let filename = layer.file {
                    let path=directory.appendingPathComponent("Media").appendingPathComponent(filename).path
                    let image=images.value(path) ?? NSImage(contentsOfFile:path)
                    if let image {images.insert(image,key:path,bytes:image.renderCacheBytes)}
                    image?.draw(in: CGRect(x: layer.x, y: layer.y, width: layer.width, height: layer.height), from: .zero, operation: .sourceOver, fraction: layer.opacity, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                }
            }
        }
        drawChildren(nil)
        guard let cg = context.makeImage() else { return nil }
        let image = NSImage(cgImage: cg, size: CGSize(width: width, height: height))
        composites.insert(image,key:key,bytes:width*height*4)
        return image
    }
}
