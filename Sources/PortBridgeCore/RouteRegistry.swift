import Foundation

public final class RouteRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var routesByHostname: [String: ProxyRoute] = [:]

    public init() {}

    public func replace(with routes: [ProxyRoute]) {
        lock.lock()
        var next: [String: ProxyRoute] = [:]
        for route in routes {
            next[route.hostname.lowercased()] = route
        }
        routesByHostname = next
        lock.unlock()
    }

    public func route(for hostHeader: String) -> ProxyRoute? {
        let hostname = hostHeader.split(separator: ":").first.map { String($0).lowercased() } ?? hostHeader.lowercased()
        lock.lock()
        defer { lock.unlock() }
        return routesByHostname[hostname]
    }

    public func allRoutes() -> [ProxyRoute] {
        lock.lock()
        defer { lock.unlock() }
        return routesByHostname.values.sorted { $0.hostname < $1.hostname }
    }
}
