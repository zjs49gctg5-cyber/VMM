import Foundation
import JavaScriptCore
import CAnimationSupport
import Darwin

public struct ScriptRequest:Codable {
    public var source:String
    public var duration:Double
    public var fps:Int
    public var width:Int
    public var height:Int
    public var seed:UInt32
    public var parameters:[String:Double]
    public var base:[String:Double]
    public var properties:[String]
    public init(source:String,duration:Double,fps:Int,width:Int,height:Int,seed:UInt32,parameters:[String:Double],base:[String:Double],properties:[String]) {
        self.source=source;self.duration=duration;self.fps=fps;self.width=width;self.height=height;self.seed=seed;self.parameters=parameters;self.base=base;self.properties=properties
    }
    public func validate()throws {
        guard source.utf8.count<=65536,!source.isEmpty,duration.isFinite,duration>0,duration<=86400,(1...60).contains(fps),ceil(duration*Double(fps))<=20000,(1...8192).contains(width),(1...8192).contains(height),!properties.isEmpty,properties.count<=12,Set(properties).count==properties.count,properties.allSatisfy({base[$0] != nil}),base.count<=32,parameters.count<=12,(Array(base.values)+Array(parameters.values)).allSatisfy({$0.isFinite && abs($0)<=10000}) else {throw ScriptError("Invalid JavaScript animation request.")}
    }
}
public struct ScriptResponse:Codable {
    public var samples:[[Double]]?
    public var error:String?
    public var sourceLine:Int?
    public init(samples:[[Double]]?=nil,error:String?=nil,sourceLine:Int?=nil){self.samples=samples;self.error=error;self.sourceLine=sourceLine}
}
public struct ScriptError:LocalizedError {
    public let message:String
    public let sourceLine:Int?
    public init(_ message:String,sourceLine:Int?=nil){self.message=message;self.sourceLine=sourceLine}
    public var errorDescription:String?{message}
}

/// Only the worker executable calls this evaluator. No application objects are exposed.
public enum ScriptWorkerMain {
    public static func run(arguments:[String]) -> Int32 {
        guard arguments.count==3 else{return 2}
        let input=URL(fileURLWithPath:arguments[1]),output=URL(fileURLWithPath:arguments[2])
        do {
            guard (try input.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)<=1_048_576 else{throw ScriptError("Request is too large.")}
            let request=try JSONDecoder().decode(ScriptRequest.self,from:Data(contentsOf:input));try request.validate()
            guard let context=JSContext() else{throw ScriptError("JavaScriptCore context could not be created.")}
            // Warm the engine before removing filesystem/network/process access.
            context.evaluateScript("1 + 1")
            var message=[CChar](repeating:0,count:1024)
            guard vmm_isolate_worker(output.path,&message,message.count)==0 else{throw ScriptError("Worker isolation failed: "+String(cString:message))}
            let response=try evaluate(request,context:context)
            try JSONEncoder().encode(response).write(to:output)
            return 0
        }catch {
            let response=ScriptResponse(error:String(error.localizedDescription.prefix(1000)),sourceLine:(error as? ScriptError)?.sourceLine)
            if let data=try? JSONEncoder().encode(response){try? data.write(to:output)}
            return 1
        }
    }
    private static func evaluate(_ request:ScriptRequest,context:JSContext)throws->ScriptResponse {
        let input=String(data:try JSONEncoder().encode(request),encoding:.utf8)!
        let literal=String(data:try JSONEncoder().encode(input),encoding:.utf8)!
        // Capture builtins before user code can change them. Inputs are plain, frozen JS data.
        // Randomness is seeded per frame; wall-clock APIs are intentionally unavailable.
        let prefix="""
        (() => {
          "use strict";
          const req=JSON.parse(\(literal)), stringify=JSON.stringify, finite=Number.isFinite;
          const freeze=Object.freeze, keys=Object.keys, imul=Math.imul;
          const params=freeze(req.parameters), base=freeze(req.base);
          let randomState=req.seed>>>0;
          const random=()=>{randomState=(imul(randomState,1664525)+1013904223)>>>0;return randomState/4294967296;};
          Object.defineProperty(Math,"random",{value:random,writable:false,configurable:false});
          Object.defineProperty(globalThis,"Date",{value:undefined,writable:false,configurable:false});
          const fn=(function(){
        """
        let suffix="""
          ;return typeof animate === 'function' ? animate : null;})();
          if(!fn) throw new Error("Define a synchronous animate(input) function.");
          const samples=[], count=Math.ceil(req.duration*req.fps);
          for(let frame=0;frame<=count;frame++) {
            const seconds=Math.min(req.duration,frame/req.fps);
            randomState=(req.seed ^ imul(frame+1,2654435761))>>>0;
            const result=fn(freeze({t:seconds/req.duration,seconds,duration:req.duration,fps:req.fps,
                frame,seed:req.seed,width:req.width,height:req.height,params,base,random}));
            if(!result || typeof result!=='object' || Array.isArray(result) || result.then)
              throw new Error("animate must return a synchronous object of numeric properties.");
            const returned=keys(result);
            if(returned.length!==req.properties.length || returned.some(k=>!req.properties.includes(k)))
              throw new Error("Returned properties must match the declared outputs.");
            const row=req.properties.map(k=>{const value=result[k];if(typeof value!=='number' || !finite(value) || Math.abs(value)>1e9) throw new Error("Invalid result for "+k+" at frame "+frame);return value;});
            samples.push(row);
          }
          return stringify(samples);
        })()
        """
        let bootstrap=prefix+"\n"+request.source+"\n"+suffix
        let sourceStart=prefix.components(separatedBy:"\n").count+1
        let sourceEnd=sourceStart+request.source.components(separatedBy:"\n").count-1
        let value=context.evaluateScript(bootstrap,withSourceURL:URL(string:"vmm-script:///animation.js"))
        if let exception=context.exception {
            let line=Int(exception.forProperty("line")?.toInt32() ?? 0)
            let sourceLine=(sourceStart...sourceEnd).contains(line) ? line-sourceStart+1:nil
            throw ScriptError(String((exception.toString() ?? "JavaScript error").prefix(1000)),sourceLine:sourceLine)
        }
        guard let text=value?.toString(),let data=text.data(using:.utf8),data.count<=8_388_608 else{throw ScriptError("JavaScript output exceeds the limit.")}
        return ScriptResponse(samples:try JSONDecoder().decode([[Double]].self,from:data))
    }
}

public enum ScriptRunner {
    public static func evaluate(_ request:ScriptRequest,worker:URL,timeout:Double=5)async throws->[[Double]] {
        try request.validate();try Task.checkCancellation()
        let root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("vmm-js-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let input=root.appendingPathComponent("input.json"),output=root.appendingPathComponent("output.json")
        let process=Process()
        let diagnostic=root.appendingPathComponent("worker-stderr.txt")
        FileManager.default.createFile(atPath:diagnostic.path,contents:Data())
        let diagnosticHandle=try FileHandle(forWritingTo:diagnostic)
        defer{try? diagnosticHandle.close()}
        defer {
            // Foundation observes/reaps child exit asynchronously. Do not block a
            // cooperative executor on waitUntilExit during timeout/cancellation cleanup.
            if process.isRunning{kill(process.processIdentifier,SIGKILL)}
            try? FileManager.default.removeItem(at:root)
        }
        try JSONEncoder().encode(request).write(to:input)
        FileManager.default.createFile(atPath:output.path,contents:Data())
        process.executableURL=worker;process.arguments=[input.path,output.path]
        process.standardInput=FileHandle.nullDevice;process.standardOutput=FileHandle.nullDevice;process.standardError=diagnosticHandle
        // JSC uses its interpreter in the helper; no JIT entitlements are needed.
        process.environment=["JSC_useJIT":"false","JSC_useWasm":"false","LANG":"en_US.UTF-8"]
        try process.run()
        let deadline=ProcessInfo.processInfo.systemUptime+timeout
        while process.isRunning {
            try Task.checkCancellation()
            if ProcessInfo.processInfo.systemUptime>=deadline{throw ScriptError("JavaScript execution timed out.")}
            if vmm_worker_memory(process.processIdentifier)>536_870_912{throw ScriptError("JavaScript worker exceeded the 512MiB memory limit.")}
            try await Task.sleep(nanoseconds:20_000_000)
        }
        guard (try output.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)<=8_388_608 else{throw ScriptError("JavaScript output exceeds the limit.")}
        guard let response=try? JSONDecoder().decode(ScriptResponse.self,from:Data(contentsOf:output)) else{let detail=(try? String(contentsOf:diagnostic,encoding:.utf8)) ?? ""
            throw ScriptError("JavaScript worker stopped without a result (status \(process.terminationStatus)). "+String(detail.suffix(600)))}
        if let error=response.error{throw ScriptError(error,sourceLine:response.sourceLine)}
        let count=Int(ceil(request.duration*Double(request.fps)))+1
        guard process.terminationStatus==0,let samples=response.samples,samples.count==count,samples.allSatisfy({$0.count==request.properties.count && $0.allSatisfy{$0.isFinite && abs($0)<=1e9}}) else{throw ScriptError("Invalid JavaScript worker result.")}
        return samples
    }
}
