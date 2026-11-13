import SwiftUI

struct Camera3DControls:View {
    @ObservedObject var store:EditorStore
    @State private var expanded=true
    func binding<T>(_ key:WritableKeyPath<Camera3D,T>)->Binding<T> {
        Binding(get:{(store.project.camera3D ?? Camera3D())[keyPath:key]},set:{value in
            store.pause();store.checkpoint()
            var camera=store.project.camera3D ?? Camera3D();camera[keyPath:key]=value;store.project.camera3D=camera
        })
    }
    func valueBinding(_ key:WritableKeyPath<Camera3D,Double>)->Binding<Double> {
        Binding(get:{(store.project.camera3D ?? Camera3D()).evaluated(at:store.playhead)[keyPath:key]},set:{value in
            var camera=store.project.camera3D ?? Camera3D()
            guard camera.evaluated(at:store.playhead)[keyPath:key] != value else{return}
            let keys=camera.keys ?? []
            guard keys.count<500 || keys.contains(where:{abs($0.time-store.playhead)<0.000001}) else {
                store.error=L("カメラキーは500個までです。");return
            }
            store.pause();store.checkpoint()
            camera.setValue(key,value:value,at:store.playhead);store.project.camera3D=camera
        })
    }
    var body:some View {
        PanelDisclosure(L("3Dカメラ（2.5D）"),isExpanded:$expanded) {
            VStack(alignment:.leading,spacing:8) {
                Toggle(L("3Dカメラを有効化"),isOn:binding(\.enabled))
                if store.project.camera3D?.enabled == true {
                    NumberInput(title:"位置 X",value:valueBinding(\.x),range:-8...8)
                    NumberInput(title:"位置 Y",value:valueBinding(\.y),range:-8...8)
                    NumberInput(title:"位置 Z",value:valueBinding(\.z),range:-8...8)
                    NumberInput(title:"左右回転",value:valueBinding(\.yaw),range:-80...80,unit:"°")
                    NumberInput(title:"上下回転",value:valueBinding(\.pitch),range:-80...80,unit:"°")
                    NumberInput(title:"傾き",value:valueBinding(\.roll),range:-80...80,unit:"°")
                    NumberInput(title:"焦点距離",value:valueBinding(\.focalLength),range:0.5...10)
                    Button(L("現在位置にカメラキーを追加・更新")) {
                        var camera=store.project.camera3D ?? Camera3D()
                        var keys=camera.keys ?? [];let time=store.playhead
                        guard keys.count<500 || keys.contains(where:{abs($0.time-time)<0.000001}) else {
                            store.error=L("カメラキーは500個までです。");return
                        }
                        store.pause();store.checkpoint()
                        keys.removeAll { abs($0.time-time)<0.000001 }
                        keys.append(.init(time:time,camera:camera.evaluated(at:time)));keys.sort{$0.time<$1.time};camera.keys=keys;store.project.camera3D=camera
                    }
                    if let keys=store.project.camera3D?.keys,!keys.isEmpty {
                        Text(L("カメラキー")).vmmFont(weight:.semibold)
                        Text(L("時刻をクリックすると移動します。"))
                            .vmmFont(size:12).foregroundColor(.secondary)
                        ForEach(keys) { key in
                            HStack(spacing:8) {
                                Button {store.seek(key.time)} label: {
                                    HStack(spacing:6) {
                                        Image(systemName:abs(store.playhead-key.time)<0.5/Double(max(1,store.project.fps)) ? "diamond.fill":"diamond")
                                        Text(timecode(key.time,fps:store.project.fps)).monospacedDigit()
                                        Spacer(minLength:0)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .disabled(key.time > max(max(10,store.project.duration+5),store.project.markers?.map(\.time).max() ?? 0))
                                    .help(L(key.time > max(max(10,store.project.duration+5),store.project.markers?.map(\.time).max() ?? 0) ? "表示範囲外のキーです":"このキーの時刻へ移動"))
                                    .accessibilityLabel("\(L("キーの時刻へ移動")) \(timecode(key.time,fps:store.project.fps))")
                                Button {store.pause();store.checkpoint();store.project.camera3D?.keys?.removeAll{$0.id==key.id}} label: {
                                    Image(systemName:"trash")
                                }.buttonStyle(.borderless)
                                    .help(L("カメラキーを削除"))
                                    .accessibilityLabel("\(L("カメラキーを削除")) \(timecode(key.time,fps:store.project.fps))")
                            }
                        }
                    }
                    Text(L("数値は現在位置の値です。キーがある場合、変更すると現在位置のキーを追加・更新します。奥行きが同じ場合はレイヤー順です。"))
                        .vmmFont(size:12).foregroundColor(.secondary)
                }
            }.padding(.top,8)
        }
    }
}
