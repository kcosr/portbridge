import Foundation
import Network

public final class ReverseProxyServer: @unchecked Sendable {
    public enum ServerError: Error {
        case invalidPort
    }

    private let registry: RouteRegistry
    private let queue = DispatchQueue(label: "PortBridge.Proxy")
    private var listener: NWListener?
    private var activeConnections: Set<ObjectIdentifier> = []
    private let connectionLock = NSLock()

    public private(set) var port: Int

    public init(port: Int, registry: RouteRegistry) {
        self.port = port
        self.registry = registry
    }

    public func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw ServerError.invalidPort
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connectionLock.lock()
        activeConnections.insert(id)
        connectionLock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                self?.connectionLock.lock()
                self?.activeConnections.remove(id)
                self?.connectionLock.unlock()
            }
        }
        connection.start(queue: queue)
        receiveHeader(from: connection, buffer: Data())
    }

    private func receiveHeader(from client: NWConnection, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil || isComplete {
                client.cancel()
                return
            }
            var next = buffer
            if let data {
                next.append(data)
            }
            if let range = next.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = next[..<range.upperBound]
                let bodyPrefix = next[range.upperBound...]
                self.proxy(headerData: Data(headerData), bodyPrefix: Data(bodyPrefix), client: client)
            } else if next.count > 64_000 {
                self.sendSimpleResponse(431, "Request Header Fields Too Large", to: client)
            } else {
                self.receiveHeader(from: client, buffer: next)
            }
        }
    }

    private func proxy(headerData: Data, bodyPrefix: Data, client: NWConnection) {
        guard let header = String(data: headerData, encoding: .isoLatin1) else {
            sendSimpleResponse(400, "Bad Request", to: client)
            return
        }
        let host = parseHeader("Host", in: header)
        if let host, let route = registry.route(for: host) {
            proxy(route: route, headerData: headerData, bodyPrefix: bodyPrefix, client: client)
        } else if host.map(isIndexHost) ?? true {
            sendIndex(status: 200, reason: "OK", message: nil, to: client)
        } else {
            sendIndex(status: 404, reason: "Not Found", message: "No PortBridge route for \(htmlEscaped(host ?? "this host")).", to: client)
        }
    }

    private func proxy(route: ProxyRoute, headerData: Data, bodyPrefix: Data, client: NWConnection) {
        let upstream = NWConnection(
            host: .ipv4(IPv4Address("127.0.0.1")!),
            port: NWEndpoint.Port(integerLiteral: NWEndpoint.Port.IntegerLiteralType(route.localPort)),
            using: upstreamParameters(for: route.upstreamScheme)
        )

        upstream.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard let server = self else {
                    upstream.cancel()
                    client.cancel()
                    return
                }
                let patched = server.patchRequestHeaders(headerData, route: route)
                upstream.send(content: patched + bodyPrefix, completion: .contentProcessed { error in
                    if error != nil {
                        client.cancel()
                        upstream.cancel()
                    } else {
                        server.pump(from: client, to: upstream)
                        server.pump(from: upstream, to: client)
                    }
                })
            case .failed:
                self?.sendSimpleResponse(502, "Bad Gateway", to: client)
                upstream.cancel()
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    private func upstreamParameters(for scheme: ServiceScheme) -> NWParameters {
        guard scheme == .https else {
            return .tcp
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, queue)
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let server = self else { return }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil {
                        source.cancel()
                        destination.cancel()
                    } else if !isComplete && error == nil {
                        server.pump(from: source, to: destination)
                    }
                })
            } else {
                if isComplete || error != nil {
                    source.cancel()
                    destination.cancel()
                } else {
                    server.pump(from: source, to: destination)
                }
            }
        }
    }

    private func patchRequestHeaders(_ data: Data, route: ProxyRoute) -> Data {
        guard var text = String(data: data, encoding: .isoLatin1) else {
            return data
        }
        if !text.lowercased().contains("\r\nx-forwarded-proto:") {
            text = text.replacingOccurrences(of: "\r\n\r\n", with: "\r\nX-Forwarded-Proto: http\r\nX-Forwarded-Host: \(route.hostname)\r\n\r\n")
        }
        return Data(text.utf8)
    }

    private func sendIndex(status: Int, reason: String, message: String?, to client: NWConnection) {
        let routes = registry.allRoutes()
        let items = routes.isEmpty
            ? "<li class=\"empty\">No active forwards yet.</li>"
            : routes.map(routeListItem).joined()
        let messageHTML = message.map { "<p class=\"notice\">\($0)</p>" } ?? ""
        let body = """
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PortBridge</title>
<style>
:root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
body { margin: 0; padding: 40px; background: Canvas; color: CanvasText; }
main { max-width: 880px; margin: 0 auto; }
h1 { margin: 0 0 6px; font-size: 32px; letter-spacing: 0; }
p { margin: 0 0 24px; color: color-mix(in srgb, CanvasText 68%, transparent); }
.notice { margin: 18px 0; padding: 12px 14px; border: 1px solid color-mix(in srgb, CanvasText 20%, transparent); border-radius: 8px; }
ul { list-style: none; margin: 0; padding: 0; display: grid; gap: 10px; }
li { border: 1px solid color-mix(in srgb, CanvasText 16%, transparent); border-radius: 8px; }
a { display: grid; grid-template-columns: 1fr auto; gap: 10px; padding: 14px 16px; color: inherit; text-decoration: none; }
a:hover { background: color-mix(in srgb, LinkText 8%, transparent); }
.host { font-weight: 650; overflow-wrap: anywhere; }
.meta { color: color-mix(in srgb, CanvasText 58%, transparent); font-variant-numeric: tabular-nums; }
.empty { padding: 14px 16px; color: color-mix(in srgb, CanvasText 58%, transparent); }
</style>
</head>
<body>
<main>
<h1>PortBridge</h1>
<p>Available forwards</p>
\(messageHTML)
<ul>\(items)</ul>
</main>
</body>
</html>
"""
        sendResponse(status: status, reason: reason, body: body, to: client)
    }

    private func routeListItem(_ route: ProxyRoute) -> String {
        let href = "http://\(route.hostname):\(port)/"
        return """
<li><a href="\(htmlEscaped(href))"><span class="host">\(htmlEscaped(route.hostname))</span><span class="meta">\(route.upstreamScheme.rawValue.uppercased()) -> 127.0.0.1:\(route.localPort)</span></a></li>
"""
    }

    private func isIndexHost(_ hostHeader: String) -> Bool {
        let host = hostHeader.split(separator: ":").first.map { String($0).lowercased() } ?? hostHeader.lowercased()
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func htmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func sendSimpleResponse(_ status: Int, _ reason: String, to client: NWConnection) {
        sendResponse(status: status, reason: reason, body: reason, to: client)
    }

    private func sendResponse(status: Int, reason: String, body: String, to client: NWConnection) {
        let data = Data(body.utf8)
        let response = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(data.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        client.send(content: Data(response.utf8) + data, isComplete: true, completion: .contentProcessed { _ in
            client.cancel()
        })
    }

    private func parseHeader(_ name: String, in header: String) -> String? {
        let prefix = name.lowercased() + ":"
        for line in header.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
