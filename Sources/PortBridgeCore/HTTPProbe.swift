import Foundation

public struct ProbeResult: Sendable {
    public var scheme: ServiceScheme
    public var statusCode: Int
    public var title: String?
    public var bodySnippet: String?

    public init(scheme: ServiceScheme, statusCode: Int, title: String? = nil, bodySnippet: String? = nil) {
        self.scheme = scheme
        self.statusCode = statusCode
        self.title = title
        self.bodySnippet = bodySnippet
    }
}

public final class HTTPProbe: NSObject, URLSessionDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.5
        config.timeoutIntervalForResource = 4
        config.httpShouldUsePipelining = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    public override init() {
        super.init()
    }

    public func probe(localPort: Int) async -> ProbeResult? {
        let delays: [UInt64] = [0, 150_000_000, 300_000_000, 600_000_000, 1_000_000_000]
        for delay in delays {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            if let result = await probeOnce(localPort: localPort) {
                return result
            }
        }
        return nil
    }

    private func probeOnce(localPort: Int) async -> ProbeResult? {
        if let http = await probe(scheme: .http, localPort: localPort) {
            return http
        }
        if let https = await probe(scheme: .https, localPort: localPort) {
            return https
        }
        return nil
    }

    private func probe(scheme: ServiceScheme, localPort: Int) async -> ProbeResult? {
        guard let url = URL(string: "\(scheme.rawValue)://127.0.0.1:\(localPort)/") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("PortBridge", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                let titled = await probeGET(scheme: scheme, localPort: localPort)
                if scheme == .http, Self.isPlainHTTPOnHTTPSResponse(titled) {
                    return nil
                }
                return titled ?? ProbeResult(scheme: scheme, statusCode: http.statusCode, title: nil)
            }
        } catch {
            let result = await probeGET(scheme: scheme, localPort: localPort)
            if scheme == .http, Self.isPlainHTTPOnHTTPSResponse(result) {
                return nil
            }
            return result
        }
        return nil
    }

    private func probeGET(scheme: ServiceScheme, localPort: Int) async -> ProbeResult? {
        guard let url = URL(string: "\(scheme.rawValue)://127.0.0.1:\(localPort)/") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("PortBridge", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return nil
            }
            let prefix = String(data: data.prefix(128_000), encoding: .utf8) ?? ""
            return ProbeResult(
                scheme: scheme,
                statusCode: http.statusCode,
                title: extractTitle(prefix),
                bodySnippet: prefix
            )
        } catch {
            return nil
        }
    }

    public static func isPlainHTTPOnHTTPSResponse(_ result: ProbeResult?) -> Bool {
        guard let result, result.scheme == .http else {
            return false
        }
        let text = [
            result.title ?? "",
            result.bodySnippet ?? "",
        ].joined(separator: "\n").lowercased()
        return result.statusCode == 400 && text.contains("plain http request") && text.contains("https port")
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
    }

    private func extractTitle(_ html: String) -> String? {
        guard let startRange = html.range(of: "<title", options: [.caseInsensitive]) else {
            return nil
        }
        guard let closeOpen = html[startRange.upperBound...].firstIndex(of: ">") else {
            return nil
        }
        guard let endRange = html[closeOpen...].range(of: "</title>", options: [.caseInsensitive]) else {
            return nil
        }
        let raw = html[html.index(after: closeOpen)..<endRange.lowerBound]
        let title = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}
