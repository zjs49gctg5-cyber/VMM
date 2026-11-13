import Foundation
import AppKit
import CryptoKit

struct Precomposition:Codable,Equatable,Identifiable {
    var id=UUID()
    var name:String
    var width:Int
    var height:Int
    var fps:Int
    var duration:Double
    var tracks:[Track]
    var clips:[Clip]
    var markers:[TimelineMarker]?
    var timelineRange:TimelineRange?
    var background:String?
}
extension Project {
    func composition(_ clip:Clip)->Precomposition? {clip.precompositionID.flatMap{id in precompositions?.first{$0.id==id}}}
    func compositionProject(_ c:Precomposition)->Project {
        var p=self;p.name=c.name;p.width=c.width;p.height=c.height;p.fps=c.fps;p.tracks=c.tracks;p.clips=c.clips;p.markers=c.markers;p.timelineRange=c.timelineRange;p.background=c.background ?? background;p.masterVolume=nil;p.masterDynamics=nil
        return p
    }
    func validatePrecompositions()throws {
        let list=precompositions ?? []
        guard Set(clips.map(\.id)).count==clips.count else{throw VMMError.message("アイテムのIDが重複しています。") }
        if list.isEmpty {guard clips.allSatisfy({$0.precompositionID==nil}) else{throw VMMError.message("プリコンポジションの参照先がありません。")};return}
        guard list.count<=128,Set(list.map(\.id)).count==list.count,clips.count+list.reduce(0,{$0+$1.clips.count})<=20000 else{throw VMMError.message("プリコンポジションが多すぎるかIDが重複しています。")}
        let table=Dictionary(uniqueKeysWithValues:list.map{($0.id,$0)})
        for c in list {
            guard !c.name.isEmpty,c.name.count<=200,c.duration.isFinite,c.duration>0,c.duration<=86400,c.clips.allSatisfy({$0.end<=c.duration+0.000001}) else{throw VMMError.message("プリコンポジションの名前・長さが不正です。")}
            _=try compositionProject(c).validated(validateCompositions:false)
        }
        var visiting:Set<UUID>=[],heights:[UUID:Int]=[:]
        func height(_ id:UUID)throws->Int {
            if let n=heights[id]{return n};guard let c=table[id],visiting.insert(id).inserted else{throw VMMError.message("プリコンポジションが循環しているか参照先がありません。")};defer{visiting.remove(id)}
            var n=1;for child in c.clips.compactMap(\.precompositionID){n=max(n,1+(try height(child)));guard n<=15 else{throw VMMError.message("プリコンポジションの入れ子は15段までにしてください。")}}
            heights[id]=n;return n
        }
        for c in list {_=try height(c.id)}
        var counts:[UUID:Int]=[:]
        func count(_ id:UUID)throws->Int {if let n=counts[id]{return n};guard let c=table[id] else{throw VMMError.message("プリコンポジションの参照先がありません。")};var n=c.clips.count;for child in c.clips.compactMap(\.precompositionID){n+=try count(child);guard n<=40000 else{throw VMMError.message("プリコンポジション展開後のアイテムが多すぎます。")}};counts[id]=n;return n}
        var total=clips.count;for id in clips.compactMap(\.precompositionID){total+=try count(id);guard total<=40000 else{throw VMMError.message("プリコンポジション展開後のアイテムが多すぎます。")}}
        var renderHeights:[UUID:Int]=[:]
        func hierarchyHeight(_ items:[Clip])throws->Int {
            let nodes=Dictionary(uniqueKeysWithValues:items.map{($0.id,$0)}),parents=Dictionary(grouping:items.filter{$0.parentID != nil},by:{$0.parentID!})
            var cache:[UUID:Int]=[:],visiting:Set<UUID>=[]
            func node(_ id:UUID)throws->Int {
                if let n=cache[id]{return n};guard let c=nodes[id],visiting.insert(id).inserted else{throw VMMError.message("プリコンポジションの親子・シーン構造が不正です。")};defer{visiting.remove(id)}
                var n=1
                for child in Set((c.sceneMembers ?? [])+(parents[id] ?? []).map(\.id)){n=max(n,1+(try node(child)))}
                if let reference=c.precompositionID {let h:Int;if let cached=renderHeights[reference]{h=cached}else{guard let composition=table[reference] else{throw VMMError.message("参照先がありません。")};h=try hierarchyHeight(composition.clips);renderHeights[reference]=h};n=max(n,1+h)}
                guard n<=16 else{throw VMMError.message("親子・シーンを含むプリコンポジションの入れ子は15段までにしてください。")};cache[id]=n;return n
            }
            var maximum=0;for c in items{maximum=max(maximum,try node(c.id))};return maximum
        }
        _=try hierarchyHeight(clips)

    }
    /// Expand independent time domains once for the shared playback/export audio graph.
    /// IDs are stable per instance, so players and decoded-source caches survive ticks.
    var audioRenderingProject:Project {
        guard !(precompositions ?? []).isEmpty else{return self}
        var result=self
        func mapped(_ instance:UUID,_ id:UUID)->UUID {
            let bytes=Array(SHA256.hash(data:Data((instance.uuidString+id.uuidString).utf8)).prefix(16))
            return UUID(uuid:(bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
        }
        func expand(_ owner:Clip,depth:Int) {
            guard depth<15,result.clips.count<40000,let c=composition(owner) else{return}
            let base=result.tracks.count;result.tracks+=c.tracks.map{var t=$0;t.id=mapped(owner.id,t.id);return t}
            let mapping=Dictionary(uniqueKeysWithValues:c.clips.map{($0.id,mapped(owner.id,$0.id))})
            for original in c.clips {
                let originalStart=owner.start-owner.sourceOffset+original.start
                var a=max(owner.start,originalStart),b=min(owner.end,originalStart+original.duration),parent=original.parentID,seen:Set<UUID>=[]
                while let id=parent,seen.insert(id).inserted,let p=c.clips.first(where:{$0.id==id}){a=max(a,owner.start-owner.sourceOffset+p.start);b=min(b,owner.start-owner.sourceOffset+p.end);parent=p.parentID}
                guard b>a else{continue}
                var shifted=original;shifted.start=originalStart
                var child=SourceEditing.fragment(shifted,start:a,end:b);child.id=mapping[original.id]!;child.track+=base
                child.parentID=original.parentID.flatMap{mapping[$0]} ?? owner.id;child.sceneMembers=original.sceneMembers?.compactMap{mapping[$0]};child.linkID=nil
                // Keep the original fade timing when an instance is cropped inside a fade.
                if original.audioFade != nil {
                    let steps=min(480,max(2,Int(ceil(child.duration*30)))),offset=a-originalStart
                    child.audioFade=nil
                    var animation=child.animation ?? ClipAnimation();animation.tracks.removeAll{$0.property == .volume}
                    var times=Set((0...steps).map{child.duration*Double($0)/Double(steps)})
                    if let fade=original.audioFade{for t in [fade.fadeIn-offset,original.duration-fade.fadeOut-offset]{if t>0,t<child.duration{times.insert(t)}}}
                    animation.tracks.append(AnimationTrack(property:.volume,keys:times.sorted().map{t in AnimationKeyframe(time:child.animationTimeOffset+t,value:original.audioVolume(at:original.start+offset+t),easing:.linear)}));child.animation=animation
                }
                result.clips.append(child);if child.precompositionID != nil{expand(child,depth:depth+1)}
            }
        }
        for c in clips where c.precompositionID != nil{expand(c,depth:0)}
        return result
    }
}
@MainActor extension EditorStore {
    @discardableResult func createPrecomposition(name:String)throws->UUID {
        guard !busy else{throw VMMError.message("処理中です。")}
        let ids=sceneSelection(),items=project.clips.filter{ids.contains($0.id)}
        guard !items.isEmpty,items.allSatisfy({!project.tracks[$0.track].locked}),let start=items.map(\.start).min(),let end=items.map(\.end).max(),let track=items.map(\.track).max() else{throw VMMError.message("ロックされていないアイテムを選択してください。")}
        let layers=Set(items.map(\.track)).sorted(),map=Dictionary(uniqueKeysWithValues:layers.enumerated().map{($0.element,$0.offset)})
        guard project.tracks.count<32 else{throw VMMError.message("プリコンポジションを配置するレイヤーの空きがありません。不要なレイヤーを削除してください。") }
        let c=Precomposition(name:name,width:project.width,height:project.height,fps:project.fps,duration:end-start,tracks:layers.map{project.tracks[$0]},clips:items.map{var c=$0;c.start-=start;c.track=map[c.track]!;return c})
        var candidate=project;candidate.removeClips(ids);candidate.precompositions=(candidate.precompositions ?? [])+[c]
        let layer=track+1;candidate.tracks.insert(Track(name:name),at:layer);for i in candidate.clips.indices where candidate.clips[i].track>=layer{candidate.clips[i].track+=1}
        var instance=Clip(kind:.group,name:name,track:layer,start:start,duration:c.duration);instance.precompositionID=c.id;candidate.clips.append(instance)
        _=try candidate.validated();pause();checkpoint();project=candidate;selectedID=instance.id;selectedIDs=[];selectedTrack=track
        status="選択した素材をプリコンポジションにまとめました。";return instance.id
    }
    func promptPrecomposition(){
        let alert=NSAlert();alert.messageText=L("プリコンポジションを作成");let field=NSTextField(string:L("プリコンポジション"));field.frame=CGRect(x:0,y:0,width:280,height:24);alert.accessoryView=field;alert.addButton(withTitle:L("作成"));alert.addButton(withTitle:L("キャンセル"))
        if alert.runModal() == .alertFirstButtonReturn{reportEditing{_ = try createPrecomposition(name:field.stringValue)}}
    }
    func makePrecompositionUnique(_ clipID:UUID)throws {
        guard let clip=project.clips.first(where:{$0.id==clipID}),var c=project.composition(clip),!busy,!project.tracks[clip.track].locked else{throw VMMError.message("編集可能なプリコンポジションを選択してください。")}
        c.id=UUID();c.name+=" (コピー)";var candidate=project;candidate.precompositions=(candidate.precompositions ?? [])+[c];candidate.clips[candidate.clips.firstIndex{$0.id==clipID}!].precompositionID=c.id
        _=try candidate.validated();pause();checkpoint();project=candidate
    }
}

@MainActor extension EditorStore {
    func updatePrecomposition(_ id:UUID,properties:[String:Any])throws {
        guard !busy,let index=project.precompositions?.firstIndex(where:{$0.id==id}),Set(properties.keys).isSubset(of:["name","width","height","fps","duration","tracks","clips","markers","timelineRange","background"]) else{throw VMMError.message("プリコンポジションの更新項目が不正です。")}
        let old=project.precompositions![index];var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(old)) as! [String:Any]
        for (key,value) in properties{json[key]=value}
        let updated=try JSONDecoder().decode(Precomposition.self,from:JSONSerialization.data(withJSONObject:json))
        var candidate=project;candidate.precompositions![index]=updated
        for i in candidate.clips.indices where candidate.clips[i].precompositionID==id && candidate.clips[i].sourceOffset==0 && abs(candidate.clips[i].duration-old.duration)<0.000001{candidate.clips[i].duration=updated.duration}
        _=try candidate.validated();pause();checkpoint();project=candidate
    }
}
@MainActor extension EditorStore {
    func deletePrecomposition(_ id:UUID)throws {
        guard !busy,project.precompositions?.contains(where:{$0.id==id}) == true else{throw VMMError.message("プリコンポジションが見つかりません。")}
        guard !(project.clips+(project.precompositions ?? []).flatMap(\.clips)).contains(where:{$0.precompositionID==id}) else{throw VMMError.message("配置されているプリコンポジションは削除できません。")}
        var candidate=project;candidate.precompositions?.removeAll{$0.id==id};_=try candidate.validated();pause();checkpoint();project=candidate
    }
}
