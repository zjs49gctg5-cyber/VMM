import Foundation
import Darwin

public enum LocalTransportError:Error,LocalizedError {
    case message(String)
    public var errorDescription:String? {if case let .message(value)=self{return value};return nil}
}
public enum LocalSocket {
    public static func address(_ path:String)throws->sockaddr_un {
        var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX)
        let bytes=Array(path.utf8)+[0]
        guard path.hasPrefix("/"),bytes.count<=MemoryLayout.size(ofValue:address.sun_path) else{throw LocalTransportError.message("Invalid local socket path")}
        address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of:&address.sun_path){$0.copyBytes(from:bytes)}
        return address
    }
    public static func open()throws->Int32 {
        let fd=Darwin.socket(AF_UNIX,SOCK_STREAM,0)
        guard fd>=0 else{throw error()}
        var yes:Int32=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,socklen_t(MemoryLayout<Int32>.size))
        _=fcntl(fd,F_SETFD,FD_CLOEXEC)
        return fd
    }
    public static func connect(_ path:String)throws->Int32 {
        let fd=try open()
        do {
            var address=try self.address(path)
            let status=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
            guard status==0 else{throw error()}
            var uid:uid_t=0,gid:gid_t=0
            guard getpeereid(fd,&uid,&gid)==0,uid==geteuid() else{throw LocalTransportError.message("Local peer is not owned by this user")}
            return fd
        } catch {Darwin.close(fd);throw error}
    }
    public static func error()->NSError {NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
}
/// Bounded newline framing. Each instance is used on one serial I/O worker.
public final class SocketLines {
    public let fd:Int32
    private var buffer=Data()
    public init(_ fd:Int32){self.fd=fd}
    public func read(limit:Int=1_048_576,deadline:Double?=nil)throws->Data? {
        while true {
            if let end=buffer.firstIndex(of:10) {
                guard end<=limit else{throw LocalTransportError.message("Message exceeds size limit")}
                let line=Data(buffer[..<end]);buffer.removeSubrange(...end);return line
            }
            guard buffer.count<=limit else{throw LocalTransportError.message("Message exceeds size limit")}
            if let deadline {
                let remaining=deadline-ProcessInfo.processInfo.systemUptime
                guard remaining>0 else{throw LocalTransportError.message("Local authentication timed out")}
                var descriptor=pollfd(fd:fd,events:Int16(POLLIN),revents:0)
                let ready=Darwin.poll(&descriptor,1,Int32(min(Double(Int32.max),ceil(remaining*1000))))
                if ready<0{if errno==EINTR{continue};throw LocalSocket.error()}
                guard ready>0 else{throw LocalTransportError.message("Local authentication timed out")}
            }
            var bytes=[UInt8](repeating:0,count:8192)
            let n=Darwin.recv(fd,&bytes,bytes.count,0)
            if n==0 {guard buffer.isEmpty else{throw LocalTransportError.message("Incomplete message")};return nil}
            if n<0 {if errno==EINTR{continue};throw LocalSocket.error()}
            buffer.append(contentsOf:bytes.prefix(n))
        }
    }
    public func write(_ data:Data)throws {
        var framed=data;framed.append(10)
        try framed.withUnsafeBytes {raw in
            var offset=0
            while offset<raw.count {
                let n=Darwin.send(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset,0)
                if n<0 {if errno==EINTR{continue};throw LocalSocket.error()}
                guard n>0 else{throw LocalTransportError.message("Local connection closed")}
                offset+=n
            }
        }
    }
}
public struct MCPConnectionDescriptor:Codable {
    public var socket:String;public var token:String
    public init(socket:String,token:String){self.socket=socket;self.token=token}
    public static func load(_ url:URL)throws->Self {
        let fd=Darwin.open(url.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        guard fd>=0 else{throw LocalSocket.error()}
        let file=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer{try? file.close()}
        var info=stat()
        guard fstat(fd,&info)==0,info.st_uid==geteuid(),info.st_mode & S_IFMT == S_IFREG,info.st_mode & 0o077 == 0,info.st_size>0,info.st_size<=8192 else{throw LocalTransportError.message("Connection file must be private and owned by this user")}
        let descriptor=try JSONDecoder().decode(Self.self,from:try file.readToEnd() ?? Data())
        guard descriptor.token.count>=32 else{throw LocalTransportError.message("Invalid connection credentials")}
        return descriptor
    }
}
/// App-side private IPC: peer UID + token authentication; no HTTP/TCP listener.
public final class LocalMCPListener {
    private let lock=NSLock()
    private var listening:Int32 = -1
    private var peers:Set<Int32>=[]
    public init(){}
    public func start(path:String,token:String,makeHandler:@escaping()->(Data)async->Data?)throws {
        let fd=try LocalSocket.open()
        do {
            var address=try LocalSocket.address(path)
            let status=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
            guard status==0,Darwin.chmod(path,0o600)==0,Darwin.listen(fd,8)==0 else{throw LocalSocket.error()}
            lock.lock();listening=fd;lock.unlock()
            DispatchQueue.global(qos:.utility).async{[weak self] in
                defer{Darwin.close(fd)}
                while let self {
                    self.lock.lock();let listening=self.listening==fd;self.lock.unlock()
                    guard listening else{break}
                    let peer=Darwin.accept(fd,nil,nil)
                    if peer<0 {if errno==EINTR{continue};break}
                    self.lock.lock()
                    let allowed=self.listening==fd && self.peers.count<8
                    if allowed{self.peers.insert(peer)}
                    self.lock.unlock()
                    guard allowed else{Darwin.close(peer);continue}
                    DispatchQueue.global(qos:.utility).async{[weak self] in
                        guard let self else{Darwin.close(peer);return}
                        defer{self.lock.lock();self.peers.remove(peer);self.lock.unlock();Darwin.close(peer)}
                        var yes:Int32=1;setsockopt(peer,SOL_SOCKET,SO_NOSIGPIPE,&yes,socklen_t(MemoryLayout<Int32>.size));_=fcntl(peer,F_SETFD,FD_CLOEXEC)
                        var timeout=timeval(tv_sec:3,tv_usec:0);setsockopt(peer,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
                        let lines=SocketLines(peer)
                        do {
                            var uid:uid_t=0,gid:gid_t=0
                            guard getpeereid(peer,&uid,&gid)==0,uid==geteuid(),let auth=try lines.read(limit:8192,deadline:ProcessInfo.processInfo.systemUptime+3),let object=try JSONSerialization.jsonObject(with:auth) as? [String:String],object["token"]==token else{throw LocalTransportError.message("Authentication failed")}
                            try lines.write(Data("{\"authenticated\":true}".utf8))
                            timeout=timeval(tv_sec:0,tv_usec:0);setsockopt(peer,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
                            let handler=makeHandler()
                            while let line=try lines.read() {
                                self.lock.lock();let active=self.listening==fd;self.lock.unlock()
                                guard active else{break}
                                let semaphore=DispatchSemaphore(value:0)
                                // Each connection executes messages in order, including initialization notifications.
                                Task {
                                    let response=await handler(line)
                                    do {try lines.write(try JSONSerialization.data(withJSONObject:["message":response.map{String(data:$0,encoding:.utf8) ?? ""} as Any? ?? NSNull()]))}catch{Darwin.shutdown(peer,SHUT_RDWR)}
                                    semaphore.signal()
                                }
                                semaphore.wait()
                            }
                        } catch { /* A bad/disconnected local peer cannot mutate the editor. */ }
                    }
                }
            }
        } catch {Darwin.close(fd);throw error}
    }
    public func stop() {
        lock.lock();let fd=listening;listening = -1
        if fd>=0{Darwin.shutdown(fd,SHUT_RDWR)}
        for peer in peers{Darwin.shutdown(peer,SHUT_RDWR)}
        lock.unlock()
    }
    deinit{stop()}
}
