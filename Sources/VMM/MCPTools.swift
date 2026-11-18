import Foundation
import CoreFoundation

@MainActor enum MCPTools {
    static let reads=["state","capabilities","catalog","extensions","settings","exportQueue","job"]
    // Required arguments have '!'; nested model objects are validated by the shared editor commands.
    static let fields:[String:String]=[
        "karaoke.import":"text! track! beforeColor afterColor",
        "karaoke.align":"clipID! text! language method",
        "karaoke.separate":"clipID!",
        "karaoke.importParts":"parts!",
        "animation.analyzeAudio":"clipID! sourceClipID!","animation.track":"clipID! sourceClipID! region! sourceIn! duration! sampleRate followScale",
        "export.interchange":"path!",
        "export.audio":"path! overwrite","selection.crossfade":"",
        "media.placeRange":"assetID! sourceIn! sourceOut! start track mode","clip.slip":"clipID! delta!","clip.roll":"clipID! delta!",
        "clip.add":"kind! track properties","clip.update":"clipID! properties!","clip.delete":"clipID!","clip.duplicate":"clipID!","clip.split":"clipID!",
        "select":"clipID!","seek":"time!","play":"","pause":"","undo":"","redo":"","voice.connect":"",
        "speech.generate":"clipID!","speech.generateBatch":"force","speech.cancel":"","speech.retryFailed":"",
        "rhythm.quantize":"clipIDs! strength","rhythm.fit":"clipIDs! beats!","rhythm.pattern":"clipID! pattern! start gate",
        "rhythm.update":"properties!","rhythm.repeat":"clipID! count! onGrid","rhythm.slice":"clipID!",
        "extension.install":"package! replace","extension.enable":"packageID! enabled!","extension.remove":"packageID!",
        "animation.applyDefinition":"packageID! definitionID! clipID! values seed","animation.cancelGeneration":"","extension.applyPreset":"packageID! name! clipID!",
        "track.delete":"track! deleteItems","media.delete":"assetID! deleteItems","export.template":"template!",
        "selection.copy":"","selection.paste":"","selection.rippleDelete":"","clip.separateAudio":"clipID!",
        "media.tags":"assetID! tags!","media.cleanupUnused":"","caption.import":"text! format! start","caption.export":"format!",
        "script.import":"text! start track","dictionary.set":"entries!","character.capture":"name!","character.apply":"characterID!",
        "selection.set":"clipIDs!","selection.update":"properties!","selection.duplicate":"","selection.delete":"","selection.arrange":"mode!",
        "settings.update":"properties!","project.new":"name discardChanges","project.update":"properties!","project.save":"path! overwrite async","project.open":"path! discardChanges async",
        "project.autosave":"","media.import":"paths!","media.relink":"assetID! path!","media.proxy":"assetID!","library.saveTemplate":"name!",
        "library.addAsset":"assetID!","library.importAsset":"path!","track.add":"name","track.update":"track! properties!","track.move":"from! to!",
        "export.start":"path! overwrite","export.cancel":"","export.preflight":"path","selection.link":"","selection.unlink":"",
        "character.projectAdd":"character!","character.projectUpdate":"character!","character.portrait":"characterID!","character.applyAll":"characterID!",
        "character.captionTemplate":"characterID! template!","character.applyCaptions":"characterID!","character.selectCaptions":"characterID!","character.projectDelete":"characterID!",
        "export.queueAdd":"path! overwrite","export.queueStart":"","export.queuePause":"","export.queueCancel":"","export.queueRetry":"exportID!","export.queueRemove":"exportID!","export.queueMove":"exportID! offset!",
        "precomposition.create":"name!","precomposition.update":"compositionID! properties!","precomposition.place":"compositionID! start track","precomposition.makeUnique":"clipID!","precomposition.delete":"compositionID!",
        "scene.save":"name! path","scene.insert":"path! start","scene.dissolve":"clipID!","project.transaction":"operations! expectedRevision dryRun",
        "state":"","capabilities":"","catalog":"","extensions":"","settings":"","exportQueue":"","job":"jobID!"
    ]
    static let descriptions:[String:String]=[
        "karaoke.import":"Import LRC/KRA lyric text, including inline timing, @Ruby and @Offset, onto a zero-based track as editable alternating karaoke captions. Optional beforeColor and afterColor are six-digit RGB. Times are project-absolute. Atomic, one Undo.",
        "karaoke.align":"Suggest line timings; returns jobID and never edits the project. method speech (default) uses on-device recognition; method separated first separates vocals locally and then uses on-device recognition. Both ranges <=15 minutes. Poll vmm_job. Review all timings; unmatched lines have null times.",
        "karaoke.separate":"Separate vocals from the selected clip with locally configured Demucs and add the result to the project media library. Returns jobID and assetIDs. Source and timeline ranges must both be <=15 minutes.",
        "karaoke.importParts":"Import multiple simultaneous LRC/KRA parts atomically. Each part has text, zero-based track, optional beforeColor, afterColor, topY and bottomY (0..1). One Undo.",
        "animation.analyzeAudio":"Analyze a timeline audio/video/speech source and store amplitude, low-frequency RMS and onset envelopes on the visual target. Returns jobID. Max 1 hour of source audio; timing/rate captured at analysis time. Reanalyze after source edits. One Undo.",
        "animation.track":"Track an object rectangle in a video and create an editable spatial path on the target. region:{x,y,width,height}, normalized top-left video coordinates. sourceIn: seconds inside source clip; duration: 0.05..30, interval must overlap target. sampleRate:1..30 default15, followScale:false default. Position/size only. Stops on low confidence, holds last point. Returns jobID and confidence/lostAt. Replaces target spatial path; one Undo.",
        "export.interchange":"Export a new handoff folder: baked ProRes master, 48kHz/24-bit WAV, FCPXML 1.10 and Premiere/FCP7 XML. Cuts at VMM item boundaries and markers are preserved. Effects, captions, layers and audio processing are baked, not editable native parameters. Never overwrites an existing folder. Poll returned jobID.",
        "export.audio":"Export only audio as 48kHz/24-bit stereo WAV, using the movie mix, fades, EQ, speed, pitch and range. Existing files require overwrite:true; returns jobID.",
        "media.placeRange":"Place asset sourceIn..sourceOut (seconds) at start on track. mode append/insert/overwrite. Insert moves all later tracks and splits independent crossing items; overwrite replaces only target track. Locks and linked/hierarchy crossings reject atomically; one Undo.",
        "clip.slip":"Move source content by delta timeline seconds, leaving clip position/duration unchanged. Linked peers follow; rejects out-of-source bounds and locks. Sub-frame audio timing supported.",
        "clip.roll":"Move the boundary with the immediately adjacent right clip by delta seconds. Keeps combined span. Requires independent audio/video clips with source handles; rejects linked/hierarchy edits.",
        "selection.crossfade":"Apply equal-power fades to two selected overlapping audio-enabled clips. Requires staggered starts/ends and 0..60 seconds overlap. Preserves timing and source content; one Undo.",
        "rhythm.quantize":"Move selected clipIDs to beat grid, strength 0..1. Atomic undo; locked, linked or parent clips reject all targets.",
        "rhythm.fit":"Fit source regions to beats (quarter-note units 0.125..64), preserving pitch; allowed speed 0.25..4. Atomic undo.",
        "rhythm.pattern":"Copy one generated audio/video source to the grid at start seconds. pattern: whitespace-separated relative semitones -24..24; '-' is a rest. gate 0.05..1. Original remains; returns new clipIDs.",
        "state":"Read the current project, selection, revision, playback and generation state before editing.",
        "capabilities":"List supported editor commands and clip kinds.","catalog":"Read shared character presets, templates, assets and recovery paths.",
        "extensions":"Read installed animation extensions.","settings":"Read application/workspace/export settings.","exportQueue":"Read export queue jobs.",
        "job":"Read an asynchronous job by jobID. A timeout or disconnect does not mean the job failed; do not blindly resubmit.",
        "script.import":"Place UTF-8 dialogue (Character: text) at start seconds on a zero-based track. Matching character names assign caption and voice presets. Imported speech needs generation.",
        "clip.add":"Add an item. properties is a clip model patch: seconds for time, ratios for coordinates, zero-based track. Returns clipID.",
        "clip.update":"Update one clip using a model patch. Nested settings are replaced as a whole; read current state first. Locked tracks are protected. Undo supported.",
        "selection.update":"Atomically update selected clips. Read selection and model first; nested settings are replaced as a whole.",
        "character.captionTemplate":"Set a character's caption definition using white/green/blue/pink/yellow/orange. Existing captions stay unchanged until applyCaptions.",
        "character.applyCaptions":"Apply caption style and position to this character's captions only. Preserves voice, portraits, generated audio and keyframes. Locked targets reject the entire operation.",
        "character.applyAll":"Apply the full character definition to assigned captions and portraits, including voice settings. Use applyCaptions for caption-only requests.",
        "project.transaction":"Apply a batch atomically with one Undo step. expectedRevision prevents editing an outdated project. Supports the documented subset of commands.",
        "project.open":"Open an absolute .vmm path. Save existing unsaved edits first; discardChanges must reflect user authorization. Prefer async:true; poll returned jobID.",
        "project.new":"Create a project. Do not discard unrelated unsaved work; discardChanges must reflect user authorization.",
        "project.save":"Save to an absolute .vmm path. Existing other files require explicit overwrite:true. Prefer async:true and poll jobID.",
        "export.start":"Export video to an absolute path. Check speech state and export.preflight first. Explicit overwrite:true is needed for existing files. Returns jobID; poll job.",
        "export.preflight":"Check media, fonts, speech and output range without rendering. Returns an asynchronous jobID.",
        "media.import":"Import local absolute file paths. Returns asynchronous jobID; poll job for assetIDs.",
        "media.cleanupUnused":"Unregister unused library media; original files are retained. Only perform requested cleanup.",
        "speech.generateBatch":"Generate dirty/missing dialogue; force:true regenerates all. Monitor generatingSpeech and failures in state.",
        "speech.cancel":"Cancel the global speech generation queue, not an individual job.",
        "export.cancel":"Cancel the current direct export, not an arbitrary job.","export.queueCancel":"Cancel the currently running queued export, not an arbitrary job."
    ]
    static var names:[String]{reads+EditorCommands.commands}
    static func publicName(_ command:String)->String {"vmm_"+command.replacingOccurrences(of:".",with:"_")}
    static func command(for name:String)->String? {
        if name.hasPrefix("vmm."),names.contains(String(name.dropFirst(4))){return String(name.dropFirst(4))}
        return names.first{publicName($0)==name}
    }
    static func schema(_ command:String)->[String:Any] {
        var properties:[String:Any]=[:],required:[String]=[]
        for field in (fields[command] ?? "").split(separator:" ") {
            let key=String(field).replacingOccurrences(of:"!",with:"")
            if field.hasSuffix("!"){required.append(key)}
            var value:[String:Any]
            if ["properties","package","character","values","region"].contains(key){value=["type":"object"]}
            else if ["paths","clipIDs","tags","entries","operations","parts"].contains(key){value=["type":"array","items":["type":["entries","operations","parts"].contains(key) ? "object":"string"],"maxItems":key == "parts" ? 16:20000]}
            else if ["force","replace","enabled","onGrid","deleteItems","overwrite","async","discardChanges","dryRun","followScale"].contains(key){value=["type":"boolean"]}
            else if ["track","count","seed","from","to","expectedRevision","offset"].contains(key){value=["type":"integer"]}
            else if ["time","start","offset","strength","beats","gate","pitch","delta","sourceIn","sourceOut","duration","sampleRate"].contains(key){value=["type":"number"]}
            else{value=["type":"string"]}
            if key.hasSuffix("ID"){value["description"]="Stable identifier obtained from VMM state, catalog or a previous tool result."}
            if key=="path" || key=="paths"{value["description"]="Absolute local filesystem path(s)."}
            if key=="properties"{value["description"]="Model properties patch; nested objects replace existing nested settings. See VMM operation/model reference."}
            if key=="kind"{value["enum"]=ClipKind.allCases.map(\.rawValue)}
            if key=="method",command=="karaoke.align"{value["enum"]=["speech","separated"]}
            if key=="template",command=="character.captionTemplate"{value["enum"]=CharacterCaptionTemplate.allCases.map(\.rawValue)}
            properties[key]=value
        }
        return ["type":"object","properties":properties,"required":required,"additionalProperties":false]
    }
    static func list()->[[String:Any]] {
        names.map{command in
            ["name":publicName(command),"description":descriptions[command] ?? "VMM \(command). Uses the documented editor operation arguments; validate target IDs and requested scope before editing. Nested model objects replace the existing object. Locks and validation apply.","inputSchema":schema(command),"annotations":["readOnlyHint":reads.contains(command),"destructiveHint":!reads.contains(command),"openWorldHint":false]]
        }
    }
    static func validate(_ arguments:[String:Any],command:String)throws {
        let schema=schema(command),properties=schema["properties"] as! [String:[String:Any]],required=schema["required"] as! [String]
        guard Set(arguments.keys).isSubset(of:Set(properties.keys)),required.allSatisfy({arguments[$0] != nil}) else{throw VMMError.message("Missing or unknown tool arguments for \(command)")}
        for (key,value) in arguments {
            let field=properties[key]!,type=field["type"] as! String
            let number=value as? NSNumber,isBool=number.map{CFGetTypeID($0)==CFBooleanGetTypeID()} ?? false
            let valid:Bool
            switch type {
            case "object":valid=value is [String:Any]
            case "array":
                if let values=value as? [Any],values.count<=20000 {let item=(field["items"] as! [String:String])["type"]!;valid=values.allSatisfy{item=="string" ? $0 is String:$0 is [String:Any]}} else{valid=false}
            case "boolean":valid=isBool
            case "integer":valid=number != nil && !isBool && number!.doubleValue.isFinite && number!.doubleValue.rounded()==number!.doubleValue
            case "number":valid=number != nil && !isBool && number!.doubleValue.isFinite
            default:valid=value is String
            }
            guard valid else{throw VMMError.message("Invalid \(key): expected \(type)")}
            if let choices=field["enum"] as? [String],let value=value as? String,!choices.contains(value){throw VMMError.message("Invalid \(key)")}
        }
    }
}

/// State belongs to an authenticated local connection, never to the entire application.
final class MCPSession {
    private var initialized=false
    private var ready=false
    @MainActor func respond(_ data:Data,commands:EditorCommands)->Data? {
        func encode(_ object:[String:Any])->Data? {try? JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])}
        var id:Any=NSNull()
        func rpcError(_ code:Int,_ message:String)->Data? {encode(["jsonrpc":"2.0","id":id,"error":["code":code,"message":message]])}
        guard data.count<=1_048_576 else{return rpcError(-32600,"Request too large")}
        let raw:Any
        do {raw=try JSONSerialization.jsonObject(with:data)}catch{return rpcError(-32700,"Parse error")}
        guard let request=raw as? [String:Any],request["jsonrpc"] as? String=="2.0",let method=request["method"] as? String else{return rpcError(-32600,"Invalid Request")}
        let hasID=request["id"] != nil
        if let value=request["id"] {
            if let n=value as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() || !n.doubleValue.isFinite || n.doubleValue.rounded() != n.doubleValue {return rpcError(-32600,"Invalid request id")}
            guard value is String || value is NSNumber else{return rpcError(-32600,"Invalid request id")};id=value
        }
        if !hasID {
            if method=="notifications/initialized",initialized{ready=true}
            // Cancellation never cancels unrelated global editor jobs. Long operations return jobID immediately.
            return nil
        }
        if method=="ping" {return encode(["jsonrpc":"2.0","id":id,"result":[:]])}
        guard request["params"]==nil || request["params"] is [String:Any] else{return rpcError(-32602,"params must be an object")}
        let params=request["params"] as? [String:Any] ?? [:]
        if method=="initialize" {
            guard !initialized,let version=params["protocolVersion"] as? String,params["capabilities"] is [String:Any],let info=params["clientInfo"] as? [String:Any],info["name"] is String,info["version"] is String else{return rpcError(-32602,"Invalid initialization")}
            initialized=true
            let supported=["2025-11-25","2025-06-18","2025-03-26","2024-11-05"]
            return encode(["jsonrpc":"2.0","id":id,"result":["protocolVersion":supported.contains(version) ? version:supported[0],"capabilities":["tools":[:]],"serverInfo":["name":"VMM","version":AppVersion.current.protocolVersion],"instructions":"Read vmm_state before editing. Preserve unsaved projects and user media. Use only requested scope. Poll vmm_job for asynchronous operations; never blindly retry after timeout. Voice, export and animation cancellation are global operations. HTTP API is not available."]])
        }
        guard ready else{return rpcError(-32002,"Initialize the MCP session first")}
        switch method {
        case "tools/list":
            guard Set(params.keys).isSubset(of:["_meta","cursor"]),params["cursor"]==nil else{return rpcError(-32602,"This server returns the complete tool list without a cursor")}
            return encode(["jsonrpc":"2.0","id":id,"result":["tools":MCPTools.list()]])
        case "tools/call":
            guard let name=params["name"] as? String,let command=MCPTools.command(for:name) else{return rpcError(-32602,"Unknown tool")}
            guard params["arguments"]==nil || params["arguments"] is [String:Any] else{return rpcError(-32602,"arguments must be an object")}
            let arguments=params["arguments"] as? [String:Any] ?? [:]
            do {try MCPTools.validate(arguments,command:command)}catch{return rpcError(-32602,error.localizedDescription)}
            let outcome:ControlResult
            if MCPTools.reads.contains(command){outcome=commands.read(command,jobID:arguments["jobID"] as? String)}
            else {var arguments=arguments;arguments["command"]=command;outcome=commands.execute(body:(try? JSONSerialization.data(withJSONObject:arguments)) ?? Data())}
            let object=(try? JSONSerialization.jsonObject(with:outcome.body)) as? [String:Any] ?? ["error":"Invalid editor response"]
            return encode(["jsonrpc":"2.0","id":id,"result":["content":[["type":"text","text":String(data:outcome.body,encoding:.utf8) ?? "{}"]],"structuredContent":object,"isError":outcome.status>=400]])
        default:return rpcError(-32601,"Method not found")
        }
    }
}
