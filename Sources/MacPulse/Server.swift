import Foundation
import Network

final class Server {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "macpulse.http")
    private let page: Data
    private let metrics: () -> Data
    private let port: UInt16

    init(port: UInt16, page: Data, metrics: @escaping () -> Data) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
        self.page = page
        self.metrics = metrics
        self.port = port
    }

    func start(onReady: @escaping () -> Void) {
        listener.stateUpdateHandler = { [port] state in
            switch state {
            case .ready: onReady()
            case .failed(.posix(.EADDRINUSE)):
                FileHandle.standardError.write(Data("macpulse: port \(port) is already in use. Stop the other copy or pass --port.\n".utf8))
                exit(1)
            case .failed(let error):
                FileHandle.standardError.write(Data("macpulse: cannot listen on 127.0.0.1:\(port): \(error.localizedDescription)\n".utf8))
                exit(1)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.receive(conn, Data())
        }
        listener.start(queue: queue)
    }

    private func receive(_ conn: NWConnection, _ buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(conn, String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if done || error != nil || buffer.count > 65_536 {
                conn.cancel()
            } else {
                self.receive(conn, buffer)
            }
        }
    }

    private func respond(_ conn: NWConnection, _ head: String) {
        let parts = head.split(separator: " ", maxSplits: 2)
        let path = parts.count > 1 ? String(parts[1]) : ""
        let (status, type, body): (String, String, Data) = switch (parts.first, path) {
        case ("GET", "/"), ("GET", "/index.html"): ("200 OK", "text/html; charset=utf-8", page)
        case ("GET", _) where path.hasPrefix("/api/metrics"): ("200 OK", "application/json", metrics())
        default: ("404 Not Found", "text/plain", Data("not found".utf8))
        }
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }
}
