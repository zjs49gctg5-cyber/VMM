import Foundation
import AnimationScriptRuntime

extension AnimationDefinition {
    static func scriptSamples(for clip:Clip)->[AnimationDefinition] {
        let supported=scriptSamples.filter{$0.targetProperties.allSatisfy{clip.availableAnimatedProperties.contains($0)}}
        if !supported.isEmpty{return supported}
        return [AnimationDefinition(id:"js.volume",name:"JavaScript · 音量フェード",parameters:[],tracks:[],script:"function animate(input) {\n  return { volume: input.base.volume * input.t };\n}",scriptOutputs:[ScriptAnimationOutput(property:.volume,offset:false)])]
    }
    static var scriptSamples:[AnimationDefinition] {
        let amplitude=AnimationParameter(id:"amplitude",title:"振幅",minimum:0,maximum:0.5,defaultValue:0.08,unit:"%")
        let cycles=AnimationParameter(id:"cycles",title:"繰り返し回数",minimum:0.25,maximum:10,defaultValue:2,unit:"回")
        return [
            AnimationDefinition(id:"js.wave",name:"JavaScript · 上下の波",description:"JavaScriptCoreで波形を生成します。",parameters:[amplitude,cycles],tracks:[],script:"""
            function animate(input) {
              const phase = input.t * Math.PI * 2 * input.params.cycles;
              return { y: Math.sin(phase) * input.params.amplitude };
            }
            """,scriptOutputs:[ScriptAnimationOutput(property:.y,offset:true)]),
            AnimationDefinition(id:"js.orbit",name:"JavaScript · 周回",description:"幅と高さの比を補正して円形に周回します。",parameters:[amplitude,cycles],tracks:[],script:"""
            function animate(input) {
              const phase = input.t * Math.PI * 2 * input.params.cycles;
              const radius = input.params.amplitude;
              return {
                x: Math.cos(phase) * radius * input.height / input.width,
                y: Math.sin(phase) * radius
              };
            }
            """,scriptOutputs:[ScriptAnimationOutput(property:.x,offset:true),ScriptAnimationOutput(property:.y,offset:true)]),
            AnimationDefinition(id:"js.vibration",name:"JavaScript · 減衰振動",description:"回転を揺らしながら元の角度に戻します。",parameters:[AnimationParameter(id:"angle",title:"角度",minimum:0,maximum:180,defaultValue:20,unit:"°"),cycles],tracks:[],script:"""
            function animate(input) {
              const envelope = Math.pow(1 - input.t, 3);
              return { rotation: Math.sin(input.t * Math.PI * 2 * input.params.cycles) * input.params.angle * envelope };
            }
            """,scriptOutputs:[ScriptAnimationOutput(property:.rotation,offset:true)])
        ]
    }
}
extension DataExtensionPackage {
    static var scriptSample:DataExtensionPackage {DataExtensionPackage(version:2,id:"vmm.sample.javascript",name:"JavaScriptモーション",author:"VMM",revision:"1.0",animations:AnimationDefinition.scriptSamples,presets:[])}
}

@MainActor extension EditorStore {
    func scriptWorkerURL()throws->URL {
        if let scriptWorkerExecutable{return scriptWorkerExecutable}
        let bundled=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/VMMAnimationWorker")
        if FileManager.default.isExecutableFile(atPath:bundled.path){return bundled}
        if let executable=Bundle.main.executableURL {
            let sibling=executable.deletingLastPathComponent().appendingPathComponent("VMMAnimationWorker")
            if FileManager.default.isExecutableFile(atPath:sibling.path){return sibling}
        }
        let development=Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("VMMAnimationWorker")
        if FileManager.default.isExecutableFile(atPath:development.path){return development}
        throw VMMError.message("JavaScript実行ヘルパーが見つかりません。アプリを再ビルドしてください。")
    }
    func cancelScriptAnimation(){scriptGenerationTask?.cancel()}
    /// No JS runs while opening, playing or exporting a project. Baking is an explicit action.
    @discardableResult func runScriptAnimation(_ definition:AnimationDefinition,packageID:String,values:[String:Double],seed:UInt32?=nil,clipID:UUID,apply:Bool,worker:URL?=nil)async throws->Int {
        guard !busy,!scriptGenerating,let clip=project.clips.first(where:{$0.id==clipID}),project.tracks.indices.contains(clip.track),!project.tracks[clip.track].locked else{throw VMMError.message("レイヤーがロックされているか、処理中です。")}
        _=try definition.validated()
        guard DataExtensionPackage.validID(packageID),let source=definition.script,let outputs=definition.scriptOutputs,outputs.allSatisfy({clip.availableAnimatedProperties.contains($0.property)}) else{throw VMMError.message("このアイテムにはJavaScriptアニメーションを適用できません。")}
        try ScriptGenerationLimits.validate(duration:clip.duration,fps:project.fps)
        let values=try definition.resolved(values),snapshot=project,seed=seed ?? definition.scriptSeed ?? 1
        let request=ScriptRequest(source:source,duration:clip.duration,fps:project.fps,width:project.width,height:project.height,seed:seed,parameters:values,base:Dictionary(uniqueKeysWithValues:clip.availableAnimatedProperties.map{($0.rawValue,$0.get(clip))}),properties:outputs.map{$0.property.rawValue})
        let executable=try worker ?? scriptWorkerURL()
        pause();scriptGenerating=true
        let task=Task.detached {()throws->[AnimationTrack] in
            let rows=try await ScriptRunner.evaluate(request,worker:executable)
            return try outputs.enumerated().map {index,output in
                try Task.checkCancellation()
                let property=output.property,base=property.get(clip)
                let samples=rows.enumerated().map {i,row in
                    AnimationKeyframe(time:clip.animationTimeOffset+min(clip.duration,Double(i)/Double(request.fps)),value:min(property.range.upperBound,max(property.range.lowerBound,row[index]+(output.offset ? base:0))),easing:.linear)
                }
                return try AnimationDefinition.reduce(samples,property:property)
            }
        }
        scriptGenerationTask=task
        defer{scriptGenerationTask=nil;scriptGenerating=false}
        let tracks=try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})
        try Task.checkCancellation()
        guard !busy,project==snapshot else{throw VMMError.message("生成中にプロジェクトが変更されました。もう一度生成してください。")}
        if apply {
            try mutateMotion(clipID){c in
                var animation=c.animation ?? ClipAnimation()
                for track in tracks {animation.tracks.removeAll{$0.property==track.property};animation.tracks.append(track)}
                c.animation=animation;c.customAnimation=CustomAnimationInstance(packageID:packageID,definition:definition,values:values,seed:seed)
            }
            status="JavaScriptアニメーションを適用しました。"
        }
        return tracks.reduce(0){$0+$1.keys.count}
    }
}
