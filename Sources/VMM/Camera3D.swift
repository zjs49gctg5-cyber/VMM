import AppKit
import CoreImage

enum CameraDepthOrder {
    /// Larger depths are farther away; ties preserve the original layer order.
    static func sorted(_ clips:[Clip])->[Clip] {
        clips.enumerated().sorted { a,b in
            let x=a.element.cameraDepth ?? 0,y=b.element.cameraDepth ?? 0
            return x == y ? a.offset < b.offset : x > y
        }.map(\.element)
    }
}

/// Camera coordinates use canvas-height units; layer depths increase away from the viewer.
struct Camera3D: Codable, Equatable {
    struct Key: Codable, Equatable, Identifiable {
        var id = UUID()
        var time: Double
        var x: Double, y: Double, z: Double, yaw: Double, pitch: Double, roll: Double, focalLength: Double
        init(time:Double,camera:Camera3D) {
            self.time=time;x=camera.x;y=camera.y;z=camera.z;yaw=camera.yaw;pitch=camera.pitch;roll=camera.roll;focalLength=camera.focalLength
        }
    }
    var enabled = false
    var keys: [Key]?
    var x = 0.0, y = 0.0, z = 0.0
    var yaw = 0.0, pitch = 0.0, roll = 0.0
    var focalLength = 2.0
    func validate() throws {
        guard [x,y,z].allSatisfy({$0.isFinite && (-8...8).contains($0)}),
              [yaw,pitch,roll].allSatisfy({$0.isFinite && (-80...80).contains($0)}),
              focalLength.isFinite, (0.5...10).contains(focalLength) else {
            throw VMMError.message("3Dカメラの設定が不正です。")
        }
        if let keys {
            guard keys.count <= 500, zip(keys,keys.dropFirst()).allSatisfy({$0.time < $1.time}) else {throw VMMError.message("3Dカメラのキーが不正です。")}
            for key in keys {
                guard key.time.isFinite, (0...86400).contains(key.time) else {throw VMMError.message("3Dカメラのキー時刻が不正です。")}
                var camera=self;camera.keys=nil;camera.x=key.x;camera.y=key.y;camera.z=key.z;camera.yaw=key.yaw;camera.pitch=key.pitch;camera.roll=key.roll;camera.focalLength=key.focalLength
                try camera.validate()
            }
        }
    }
    func evaluated(at time:Double)->Camera3D {
        guard let keys,!keys.isEmpty else{return self}
        let a=keys.last(where:{$0.time<=time}) ?? keys[0], b=keys.first(where:{$0.time>=time}) ?? keys[keys.count-1]
        let t=a.time == b.time ? 0 : min(1,max(0,(time-a.time)/(b.time-a.time)))
        func blend(_ x:Double,_ y:Double)->Double{x+(y-x)*t}
        var result=self;result.x=blend(a.x,b.x);result.y=blend(a.y,b.y);result.z=blend(a.z,b.z);result.yaw=blend(a.yaw,b.yaw);result.pitch=blend(a.pitch,b.pitch);result.roll=blend(a.roll,b.roll);result.focalLength=blend(a.focalLength,b.focalLength);return result
    }
    mutating func setValue(_ path:WritableKeyPath<Camera3D,Double>,value:Double,at time:Double) {
        guard keys?.isEmpty == false else {self[keyPath:path]=value;return}
        var current=evaluated(at:time);current[keyPath:path]=value
        var list=keys ?? [];list.removeAll{abs($0.time-time)<0.000001}
        list.append(Key(time:time,camera:current));list.sort{$0.time<$1.time};keys=list
    }
    func project(_ point: CGPoint, depth: Double, size: CGSize) -> CGPoint? {
        let h=Double(size.height), w=Double(size.width)
        guard h>0,w>0 else{return nil}
        var px=(Double(point.x)-w/2)/h-x, py=(Double(point.y)-h/2)/h-y
        var pz=focalLength+depth-z
        let a = -yaw * .pi / 180, b = -pitch * .pi / 180, c = -roll * .pi / 180
        (px,pz)=(px*cos(a)+pz*sin(a),-px*sin(a)+pz*cos(a))
        (py,pz)=(py*cos(b)-pz*sin(b),py*sin(b)+pz*cos(b))
        (px,py)=(px*cos(c)-py*sin(c),px*sin(c)+py*cos(c))
        guard pz > 0.05 else{return nil}
        return CGPoint(x:w/2+px*focalLength/pz*h,y:h/2+py*focalLength/pz*h)
    }
    /// Intersect a screen ray with the same depth plane used by `project`.
    func unproject(_ point: CGPoint, depth: Double, size: CGSize) -> CGPoint? {
        let h=Double(size.height),w=Double(size.width)
        guard h>0,w>0 else{return nil}
        var px=(Double(point.x)-w/2)/h/focalLength
        var py=(Double(point.y)-h/2)/h/focalLength
        var pz=1.0
        let a = -yaw * .pi / 180, b = -pitch * .pi / 180, c = -roll * .pi / 180
        (px,py)=(px*cos(c)+py*sin(c),-px*sin(c)+py*cos(c))
        (py,pz)=(py*cos(b)+pz*sin(b),-py*sin(b)+pz*cos(b))
        (px,pz)=(px*cos(a)-pz*sin(a),px*sin(a)+pz*cos(a))
        guard abs(pz)>1e-9 else{return nil}
        let distance=(focalLength+depth-z)/pz
        guard distance>0.05 else{return nil}
        return CGPoint(x:w/2+(px*distance+x)*h,y:h/2+(py*distance+y)*h)
    }
}

final class Camera3DRenderer {
    private let context=CIContext(options:[.cacheIntermediates:false])
    func render(_ raster:NodeRaster,camera:Camera3D,depth:Double,size:CGSize)->NodeRaster? {
        let rect=raster.rect
        let corners=[CGPoint(x:rect.minX,y:rect.maxY),CGPoint(x:rect.maxX,y:rect.maxY),CGPoint(x:rect.maxX,y:rect.minY),CGPoint(x:rect.minX,y:rect.minY)]
        let projected=corners.compactMap{camera.project($0,depth:depth,size:size)}
        guard projected.count==4 else{return nil}
        func vec(_ i:Int)->CIVector {CIVector(x:projected[i].x,y:projected[i].y)}
        let extent=CGRect(origin:.zero,size:size)
        let result=CIImage(cgImage:raster.image).applyingFilter("CIPerspectiveTransform",parameters:["inputTopLeft":vec(0),"inputTopRight":vec(1),"inputBottomRight":vec(2),"inputBottomLeft":vec(3)]).cropped(to:extent)
        guard let image=context.createCGImage(result,from:extent) else{return nil}
        return NodeRaster(image:image,rect:extent)
    }
}
