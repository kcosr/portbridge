import Foundation

public struct HostProfile: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var alias: String
    public var hostname: String
    public var user: String
    public var port: Int
    public var enabled: Bool
    public var scanInterval: TimeInterval
    public var useSSHConfigAlias: Bool
    public var autoForward: Bool

    public init(
        id: UUID = UUID(),
        alias: String,
        hostname: String,
        user: String = "",
        port: Int = 22,
        enabled: Bool = false,
        scanInterval: TimeInterval = 15,
        useSSHConfigAlias: Bool = false,
        autoForward: Bool = false
    ) {
        self.id = id
        self.alias = alias
        self.hostname = hostname
        self.user = user
        self.port = port
        self.enabled = enabled
        self.scanInterval = scanInterval
        self.useSSHConfigAlias = useSSHConfigAlias
        self.autoForward = autoForward
    }

    enum CodingKeys: String, CodingKey {
        case id
        case alias
        case hostname
        case user
        case port
        case enabled
        case scanInterval
        case useSSHConfigAlias
        case autoForward
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        alias = try container.decode(String.self, forKey: .alias)
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        user = try container.decodeIfPresent(String.self, forKey: .user) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        scanInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .scanInterval) ?? 15
        useSSHConfigAlias = try container.decodeIfPresent(Bool.self, forKey: .useSSHConfigAlias) ?? false
        autoForward = try container.decodeIfPresent(Bool.self, forKey: .autoForward) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(alias, forKey: .alias)
        try container.encode(hostname, forKey: .hostname)
        try container.encode(user, forKey: .user)
        try container.encode(port, forKey: .port)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(scanInterval, forKey: .scanInterval)
        try container.encode(useSSHConfigAlias, forKey: .useSSHConfigAlias)
        try container.encode(autoForward, forKey: .autoForward)
    }

    public var displayName: String {
        alias.isEmpty ? sshTarget : alias
    }

    public var sshTarget: String {
        if !alias.isEmpty, hostname.isEmpty {
            return alias
        }
        if user.isEmpty {
            return hostname
        }
        return "\(user)@\(hostname)"
    }

    public var usesSSHConfigAlias: Bool {
        useSSHConfigAlias || (!alias.isEmpty && hostname.isEmpty)
    }
}

public struct RemotePort: Codable, Equatable, Hashable, Sendable {
    public var bindAddress: String
    public var port: Int

    public init(bindAddress: String, port: Int) {
        self.bindAddress = bindAddress
        self.port = port
    }
}

public enum ServiceScheme: String, Codable, Sendable {
    case http
    case https
}

public enum ProbeStatus: String, Codable, Sendable {
    case unknown
    case probing
    case web
    case notHTTP
    case failed
}

public struct ServiceRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var hostID: UUID
    public var hostName: String
    public var remotePort: RemotePort
    public var localPort: Int
    public var enabled: Bool
    public var scheme: ServiceScheme?
    public var status: ProbeStatus
    public var title: String?
    public var prettyName: String
    public var lastError: String?
    public var lastSeen: Date

    public init(
        id: UUID = UUID(),
        hostID: UUID,
        hostName: String,
        remotePort: RemotePort,
        localPort: Int,
        enabled: Bool = true,
        scheme: ServiceScheme? = nil,
        status: ProbeStatus = .unknown,
        title: String? = nil,
        prettyName: String,
        lastError: String? = nil,
        lastSeen: Date = Date()
    ) {
        self.id = id
        self.hostID = hostID
        self.hostName = hostName
        self.remotePort = remotePort
        self.localPort = localPort
        self.enabled = enabled
        self.scheme = scheme
        self.status = status
        self.title = title
        self.prettyName = prettyName
        self.lastError = lastError
        self.lastSeen = lastSeen
    }

    public var routeHost: String {
        "\(routeLabel).\(sanitizeDNSLabel(hostName)).localhost"
    }

    public var routeLabel: String {
        guard remotePort.bindAddress != "127.0.0.1",
              prettyName == defaultPrettyName(for: remotePort.port) else {
            return prettyName
        }
        return "\(prettyName)-\(sanitizeDNSLabel(remotePort.bindAddress))"
    }
}

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var hosts: [HostProfile]
    public var services: [ServiceRecord]
    public var proxyPort: Int
    public var localPortRange: ClosedRange<Int>
    public var hideNonHTTPPorts: Bool

    public init(
        hosts: [HostProfile] = [],
        services: [ServiceRecord] = [],
        proxyPort: Int = 8088,
        localPortRange: ClosedRange<Int> = 24_000...39_999,
        hideNonHTTPPorts: Bool = true
    ) {
        self.hosts = hosts
        self.services = services
        self.proxyPort = proxyPort
        self.localPortRange = localPortRange
        self.hideNonHTTPPorts = hideNonHTTPPorts
    }

    enum CodingKeys: String, CodingKey {
        case hosts
        case services
        case proxyPort
        case localPortRangeStart
        case localPortRangeEnd
        case hideNonHTTPPorts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hosts = try container.decodeIfPresent([HostProfile].self, forKey: .hosts) ?? []
        services = try container.decodeIfPresent([ServiceRecord].self, forKey: .services) ?? []
        proxyPort = try container.decodeIfPresent(Int.self, forKey: .proxyPort) ?? 8088
        let start = try container.decodeIfPresent(Int.self, forKey: .localPortRangeStart) ?? 24_000
        let end = try container.decodeIfPresent(Int.self, forKey: .localPortRangeEnd) ?? 39_999
        localPortRange = start...end
        hideNonHTTPPorts = try container.decodeIfPresent(Bool.self, forKey: .hideNonHTTPPorts) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hosts, forKey: .hosts)
        try container.encode(services, forKey: .services)
        try container.encode(proxyPort, forKey: .proxyPort)
        try container.encode(localPortRange.lowerBound, forKey: .localPortRangeStart)
        try container.encode(localPortRange.upperBound, forKey: .localPortRangeEnd)
        try container.encode(hideNonHTTPPorts, forKey: .hideNonHTTPPorts)
    }

    public mutating func normalizeLegacyServices() {
        var byKey: [ServiceIdentity: ServiceRecord] = [:]
        for service in services {
            let key = ServiceIdentity(service)
            let cleaned = service.invalidatingMisclassifiedHTTPS()
            guard let existing = byKey[key] else {
                byKey[key] = cleaned
                continue
            }
            byKey[key] = ServiceRecord.preferred(existing, cleaned)
        }
        services = byKey.values.sorted { lhs, rhs in
            if lhs.hostName == rhs.hostName {
                if lhs.remotePort.port == rhs.remotePort.port {
                    return lhs.remotePort.bindAddress < rhs.remotePort.bindAddress
                }
                return lhs.remotePort.port < rhs.remotePort.port
            }
            return lhs.hostName < rhs.hostName
        }
    }
}

private struct ServiceIdentity: Hashable {
    var hostID: UUID
    var bindAddress: String
    var port: Int

    init(_ service: ServiceRecord) {
        hostID = service.hostID
        bindAddress = service.remotePort.bindAddress
        port = service.remotePort.port
    }
}

private extension ServiceRecord {
    func invalidatingMisclassifiedHTTPS() -> ServiceRecord {
        var copy = self
        let result = ProbeResult(
            scheme: scheme ?? .http,
            statusCode: 400,
            title: title,
            bodySnippet: lastError
        )
        if scheme == .http, HTTPProbe.isPlainHTTPOnHTTPSResponse(result) {
            copy.scheme = nil
            copy.status = .notHTTP
            copy.title = nil
            copy.lastError = "HTTPS service needs reprobe"
        }
        return copy
    }

    static func preferred(_ lhs: ServiceRecord, _ rhs: ServiceRecord) -> ServiceRecord {
        if lhs.enabled != rhs.enabled {
            return lhs.enabled ? lhs : rhs
        }
        if lhs.status == .web, rhs.status != .web {
            return lhs
        }
        if rhs.status == .web, lhs.status != .web {
            return rhs
        }
        return lhs.lastSeen >= rhs.lastSeen ? lhs : rhs
    }
}

public struct ProxyRoute: Equatable, Sendable {
    public var hostname: String
    public var localPort: Int
    public var upstreamScheme: ServiceScheme

    public init(hostname: String, localPort: Int, upstreamScheme: ServiceScheme) {
        self.hostname = hostname
        self.localPort = localPort
        self.upstreamScheme = upstreamScheme
    }
}

public func sanitizeDNSLabel(_ value: String) -> String {
    let lowered = value.lowercased()
    var scalars: [Character] = []
    var previousWasDash = false
    for char in lowered {
        let isAllowed = char.isASCII && (char.isLetter || char.isNumber)
        if isAllowed {
            scalars.append(char)
            previousWasDash = false
        } else if !previousWasDash {
            scalars.append("-")
            previousWasDash = true
        }
    }
    let trimmed = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let base = trimmed.isEmpty ? "host" : trimmed
    if base.count <= 63 {
        return base
    }
    return String(base.prefix(56)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) + "-long"
}

public func defaultPrettyName(for port: Int) -> String {
    "p\(port)"
}
