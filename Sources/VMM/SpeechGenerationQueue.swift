import Foundation

/// One synthesis per server, with at most two servers active. Waiting jobs cancel without reaching HTTP.
actor SpeechGenerationQueue {
    private struct Waiter {
        let id:UUID
        let key:String
        let continuation:CheckedContinuation<Void,Error>
    }
    private var waiters:[Waiter]=[]
    private var active:[UUID:String]=[:]
    func run<T>(key:String,operation:@Sendable ()async throws->T)async throws->T {
        let id=UUID()
        try await withTaskCancellationHandler(operation:{
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation{continuation in
                waiters.append(Waiter(id:id,key:key,continuation:continuation));pump()
            }
        },onCancel:{Task{await self.cancel(id)}})
        defer {active[id]=nil;pump()}
        try Task.checkCancellation()
        return try await operation()
    }
    private func cancel(_ id:UUID) {
        if let index=waiters.firstIndex(where:{$0.id==id}) {waiters.remove(at:index).continuation.resume(throwing:CancellationError());pump()}
    }
    private func pump() {
        while active.count<2,let index=waiters.firstIndex(where:{!active.values.contains($0.key)}) {
            let next=waiters.remove(at:index);active[next.id]=next.key;next.continuation.resume()
        }
    }
    static func key(_ configuration:SpeechConfiguration)->String {
        guard let components=URLComponents(string:configuration.endpoint) else{return configuration.endpoint}
        // All validated hosts are loopback aliases of this Mac.
        return "\(components.scheme ?? "http"):\(components.port ?? (components.scheme == "https" ? 443:80))/\(components.path.trimmingCharacters(in:CharacterSet(charactersIn:"/")))"
    }
}
