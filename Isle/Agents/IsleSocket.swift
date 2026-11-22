import Foundation

/// Local-only IPC: a Unix domain socket in Isle's Application Support folder (mode 0600).
/// One message per connection: the client writes, closes its write side, and may read a reply.
enum IsleSocket {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Isle")
    }

    static var path: String { directory.appendingPathComponent("isle.sock").path }

    fileprivate static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        return addr
    }

    fileprivate static func readAll(_ fd: Int32, limit: Int = 4 << 20) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < limit {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    fileprivate static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard var p = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let n = write(fd, p, left)
                if n <= 0 { return }
                p += n
                left -= n
            }
        }
    }

    /// Client side. Returns the reply (if `expectReply`) or nil. Never blocks for long:
    /// if Isle isn't running the connect simply fails.
    @discardableResult
    static func send(_ data: Data, expectReply: Bool = false, timeout: TimeInterval = 2) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard var addr = address(path) else { return nil }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else { return nil }
        writeAll(fd, data)
        shutdown(fd, SHUT_WR)
        return expectReply ? readAll(fd) : nil
    }
}

/// Server side, owned by the running app.
final class IsleSocketServer: @unchecked Sendable {
    /// Called on the main queue with the request; call `reply` (once) with an optional response.
    typealias Handler = @MainActor (_ request: Data, _ reply: @escaping (Data?) -> Void) -> Void

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "app.isle.socket", attributes: .concurrent)
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() {
        guard fd < 0 else { return }
        try? FileManager.default.createDirectory(at: IsleSocket.directory, withIntermediateDirectories: true)
        let path = IsleSocket.path
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = IsleSocket.address(path) else { return }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bound, listen(fd, 32) == 0 else {
            close(fd)
            fd = -1
            return
        }
        chmod(path, 0o600)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.resume()
        self.source = source
    }

    private func acceptOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let request = IsleSocket.readAll(client)
        let handler = self.handler
        let queue = self.queue
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                handler(request) { response in
                    queue.async {
                        if let response { IsleSocket.writeAll(client, response) }
                        close(client)
                    }
                }
            }
        }
    }
}

/// `Isle --hook <source> [json]`: forward a hook event to the running app and exit.
/// Claude Code passes the event on stdin; Codex passes it as an argument. Prints nothing,
/// always exits 0 — a hook must never slow down or break the agent.
enum HookClient {
    static func run(arguments: [String]) -> Never {
        let source = arguments.first ?? "unknown"
        var payload: Data
        if arguments.count > 1 {
            payload = Data(arguments[1].utf8)
        } else {
            payload = FileHandle.standardInput.readDataToEndOfFile()
        }
        if payload.isEmpty { payload = Data("null".utf8) }
        var envelope = Data(#"{"type":"hook","source":""#.utf8)
        envelope.append(Data(source.filter { $0.isLetter || $0.isNumber }.utf8))
        envelope.append(Data(#"","payload":"#.utf8))
        envelope.append(payload)
        envelope.append(Data("}".utf8))
        IsleSocket.send(envelope, timeout: 1)
        exit(0)
    }
}
