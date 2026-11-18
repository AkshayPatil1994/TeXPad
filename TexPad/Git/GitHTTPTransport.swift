// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import Foundation

/// One smart-HTTP request/response for libgit2, carried by URLSession (so iOS does TLS 1.3 and certificate validation).
/// libgit2 calls open → write* → read* → close from its own worker thread; `read` blocks until bytes arrive.
final class GitHTTPStream: NSObject, URLSessionDataDelegate {
    let url: URL
    let service: Int32
    private var body = Data()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var started = false

    private let cond = NSCondition()
    private var pending: [Data] = []
    private var current = Data()
    private var finished = false
    private var failure: String?
    private(set) var errorCString: UnsafeMutablePointer<CChar>?

    init(url: URL, service: Int32) { self.url = url; self.service = service }

    deinit { errorCString?.deallocate() }

    // MARK: request

    private var isUpload: Bool { service == 2 || service == 4 }

    private var requestURL: URL? {
        var base = url.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        switch service {
        case 1: return URL(string: base + "/info/refs?service=git-upload-pack")
        case 2: return URL(string: base + "/git-upload-pack")
        case 3: return URL(string: base + "/info/refs?service=git-receive-pack")
        case 4: return URL(string: base + "/git-receive-pack")
        default: return nil
        }
    }

    func append(_ d: Data) { body.append(d) }

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        guard let u = requestURL, u.scheme == "https" else { finish(error: "Only https:// remotes are supported."); return }
        var req = URLRequest(url: u)
        req.httpMethod = isUpload ? "POST" : "GET"
        req.setValue("git/2.0 (TexPad)", forHTTPHeaderField: "User-Agent")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if isUpload {
            let kind = service == 2 ? "upload" : "receive"
            req.setValue("application/x-git-\(kind)-pack-request", forHTTPHeaderField: "Content-Type")
            req.setValue("application/x-git-\(kind)-pack-result", forHTTPHeaderField: "Accept")
            req.httpBody = body
        } else {
            req.setValue("*/*", forHTTPHeaderField: "Accept")
        }
        // Credentials only ever go to the host the user entered them for.
        if let host = url.host, let c = GitHTTP.credentials(host) {
            let raw = Data("\(c.username):\(c.token)".utf8).base64EncodedString()
            req.setValue("Basic \(raw)", forHTTPHeaderField: "Authorization")
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 3600
        cfg.httpCookieStorage = nil
        cfg.urlCredentialStorage = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let extra = GitHTTP.protocolClasses { cfg.protocolClasses = extra + (cfg.protocolClasses ?? []) }
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        task = s.dataTask(with: req)
        task?.resume()
    }

    // MARK: reading (called by libgit2)

    /// Returns 0 on success (bytes == 0 at end of response) or -1 on failure.
    func read(into buffer: UnsafeMutablePointer<CChar>, size: Int, bytesRead: inout Int) -> Int32 {
        startIfNeeded()
        cond.lock(); defer { cond.unlock() }
        while current.isEmpty && pending.isEmpty && !finished { cond.wait() }
        if current.isEmpty, !pending.isEmpty { current = pending.removeFirst() }
        if !current.isEmpty {
            let n = min(size, current.count)
            current.copyBytes(to: UnsafeMutableRawBufferPointer(start: buffer, count: n).bindMemory(to: UInt8.self), count: n)
            current.removeFirst(n)
            bytesRead = n
            return 0
        }
        if let f = failure { setError(f); bytesRead = 0; return -1 }
        bytesRead = 0
        return 0
    }

    private func setError(_ s: String) {
        errorCString?.deallocate()
        let bytes = Array(s.utf8CString)
        let p = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
        p.initialize(from: bytes, count: bytes.count)
        errorCString = p
    }

    func cancel() { task?.cancel(); session?.invalidateAndCancel() }

    private func finish(error: String?) {
        cond.lock()
        if failure == nil { failure = error }
        finished = true
        cond.broadcast()
        cond.unlock()
    }

    // MARK: URLSession delegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 { completionHandler(.allow); return }
        let host = url.host ?? "the server"
        switch status {
        case 401, 403: finish(error: "Authentication failed (HTTP \(status)). Check the access token saved for \(host) and its permissions.")
        case 404: finish(error: "Repository not found at \(host) (HTTP 404). Check the URL — private repositories need an access token.")
        default: finish(error: "The server answered HTTP \(status).")
        }
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        cond.lock(); pending.append(data); cond.broadcast(); cond.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error as NSError?, e.code != NSURLErrorCancelled { finish(error: "Network error: \(e.localizedDescription)") }
        else { finish(error: nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Follow redirects only within the same host over https, so the token can't be forwarded elsewhere.
        if let new = request.url, new.scheme == "https", new.host?.lowercased() == url.host?.lowercased() { completionHandler(request) }
        else { finish(error: "Blocked a redirect to another host."); completionHandler(nil) }
    }
}

enum GitHTTP {
    /// Looks up the saved credential for a host (overridable in tests).
    /// Test hook: URLProtocol stubs that stand in for a git server.
    nonisolated(unsafe) static var protocolClasses: [AnyClass]?
    nonisolated(unsafe) static var credentials: (String) -> GitCredential? = { GitCredentialStore.load(host: $0) }

    private static let registered: Bool = {
        var ops = texpad_http_ops(ctx: nil, open: gitOpen, write: gitWrite, read: gitRead, last_error: gitLastError, close: gitClose)
        return texpad_git_register_https(&ops) == 0
    }()

    /// Registers the transport with libgit2 (once).
    static func install() -> Bool { registered }
}

// C callbacks (no captures allowed): the stream travels through the opaque handle.
private func gitOpen(_ ctx: UnsafeMutableRawPointer?, _ url: UnsafePointer<CChar>?, _ service: Int32) -> UnsafeMutableRawPointer? {
    guard let url, let u = URL(string: String(cString: url)), u.scheme == "https", u.host != nil, u.user == nil, u.password == nil else { return nil }
    return Unmanaged.passRetained(GitHTTPStream(url: u, service: service)).toOpaque()
}

private func gitWrite(_ stream: UnsafeMutableRawPointer?, _ buf: UnsafePointer<CChar>?, _ len: Int) -> Int32 {
    guard let stream, let buf else { return -1 }
    Unmanaged<GitHTTPStream>.fromOpaque(stream).takeUnretainedValue().append(Data(bytes: buf, count: len))
    return 0
}

private func gitRead(_ stream: UnsafeMutableRawPointer?, _ buf: UnsafeMutablePointer<CChar>?, _ size: Int, _ bytesRead: UnsafeMutablePointer<Int>?) -> Int32 {
    guard let stream, let buf, let bytesRead else { return -1 }
    var n = 0
    let rc = Unmanaged<GitHTTPStream>.fromOpaque(stream).takeUnretainedValue().read(into: buf, size: size, bytesRead: &n)
    bytesRead.pointee = n
    return rc
}

private func gitLastError(_ stream: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? {
    guard let stream else { return nil }
    return UnsafePointer(Unmanaged<GitHTTPStream>.fromOpaque(stream).takeUnretainedValue().errorCString)
}

private func gitClose(_ stream: UnsafeMutableRawPointer?) {
    guard let stream else { return }
    let s = Unmanaged<GitHTTPStream>.fromOpaque(stream)
    s.takeUnretainedValue().cancel()
    s.release()
}
