import Foundation

@MainActor
public final class AppState {
    public private(set) var configuration: AppConfiguration
    public private(set) var lastError: String?
    public private(set) var proxyRunning = false
    public private(set) var scanningHostIDs: Set<UUID> = []
    public private(set) var lastScanSummaries: [UUID: String] = [:]

    public let registry: RouteRegistry
    public let settingsStore: SettingsStore

    private let tunnelSupervisor: TunnelSupervisor
    private let probe: HTTPProbe
    private let allocator: PortAllocator
    private var scanTasks: [UUID: Task<Void, Never>] = [:]
    private var proxy: ReverseProxyServer?
    private var saveTask: Task<Void, Never>?

    public var onChange: (() -> Void)?

    public init(settingsStore: SettingsStore = SettingsStore()) {
        self.settingsStore = settingsStore
        var loadedConfiguration = (try? settingsStore.load()) ?? AppConfiguration()
        let unnormalizedConfiguration = loadedConfiguration
        loadedConfiguration.normalizeLegacyServices()
        configuration = loadedConfiguration
        if loadedConfiguration != unnormalizedConfiguration {
            try? settingsStore.save(loadedConfiguration)
        }
        registry = RouteRegistry()
        tunnelSupervisor = TunnelSupervisor()
        probe = HTTPProbe()
        allocator = PortAllocator(
            range: configuration.localPortRange,
            initiallyReserved: Set(configuration.services.map(\.localPort))
        )
        refreshRoutes()
    }

    deinit {
        tunnelSupervisor.stopAll()
    }

    public var hosts: [HostProfile] {
        configuration.hosts.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public var services: [ServiceRecord] {
        configuration.services.sorted { lhs, rhs in
            if lhs.hostName == rhs.hostName {
                return lhs.remotePort.port < rhs.remotePort.port
            }
            return lhs.hostName < rhs.hostName
        }
    }

    public var visibleServices: [ServiceRecord] {
        services.filter { $0.status != .notHTTP }
    }

    public func start() {
        startProxy()
        for host in configuration.hosts where host.enabled {
            startScanning(host.id)
        }
        notify()
    }

    public func stop() {
        for task in scanTasks.values {
            task.cancel()
        }
        scanTasks.removeAll()
        tunnelSupervisor.stopAll()
        proxy?.stop()
        proxyRunning = false
        notify()
    }

    public func startProxy() {
        proxy?.stop()
        let server = ReverseProxyServer(port: configuration.proxyPort, registry: registry)
        do {
            try server.start()
            proxy = server
            proxyRunning = true
            lastError = nil
        } catch {
            proxyRunning = false
            lastError = "Could not start proxy on port \(configuration.proxyPort): \(error.localizedDescription)"
        }
    }

    public func importSSHConfigHosts() {
        let imported = SSHConfigParser.hostProfilesFromUserConfig()
        let existingAliases = Set(configuration.hosts.map(\.alias))
        let fresh = imported.filter { !existingAliases.contains($0.alias) }
        configuration.hosts.append(contentsOf: fresh)
        persistAndNotify()
    }

    public func addManualHost(alias: String, hostname: String, user: String, port: Int) {
        let cleanAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanHost = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAlias.isEmpty || !cleanHost.isEmpty else { return }
        configuration.hosts.append(
            HostProfile(
                alias: cleanAlias.isEmpty ? cleanHost : cleanAlias,
                hostname: cleanHost,
                user: user.trimmingCharacters(in: .whitespacesAndNewlines),
                port: port,
                enabled: true
            )
        )
        persistAndNotify()
        if let id = configuration.hosts.last?.id {
            startScanning(id)
        }
    }

    public func removeHost(_ id: UUID) {
        scanTasks[id]?.cancel()
        scanTasks.removeValue(forKey: id)
        tunnelSupervisor.stopHost(id)
        configuration.hosts.removeAll { $0.id == id }
        for service in configuration.services where service.hostID == id {
            Task { await allocator.release(service.localPort) }
        }
        configuration.services.removeAll { $0.hostID == id }
        refreshRoutes()
        persistAndNotify()
    }

    public func setHost(_ id: UUID, enabled: Bool) {
        guard let index = configuration.hosts.firstIndex(where: { $0.id == id }) else { return }
        configuration.hosts[index].enabled = enabled
        if enabled {
            startScanning(id)
        } else {
            scanTasks[id]?.cancel()
            scanTasks.removeValue(forKey: id)
            tunnelSupervisor.stopHost(id)
            for serviceIndex in configuration.services.indices where configuration.services[serviceIndex].hostID == id {
                configuration.services[serviceIndex].status = .unknown
            }
            refreshRoutes()
        }
        persistAndNotify()
    }

    public func setHostAutoForward(_ id: UUID, enabled: Bool) {
        guard let index = configuration.hosts.firstIndex(where: { $0.id == id }) else { return }
        configuration.hosts[index].autoForward = enabled
        if !enabled {
            disableAllForwards(for: id, persist: false)
        }
        persistAndNotify()
        if enabled, configuration.hosts[index].enabled {
            scanNow(id)
        }
    }

    public func disableAllForwards(for hostID: UUID) {
        disableAllForwards(for: hostID, persist: true)
    }

    private func disableAllForwards(for hostID: UUID, persist: Bool) {
        for index in configuration.services.indices where configuration.services[index].hostID == hostID {
            configuration.services[index].enabled = false
            tunnelSupervisor.stop(service: configuration.services[index])
        }
        refreshRoutes()
        if persist {
            persistAndNotify()
        }
    }

    public func scanNow(_ id: UUID) {
        guard let host = configuration.hosts.first(where: { $0.id == id }) else { return }
        Task {
            await scan(host)
        }
    }

    public func setService(_ id: UUID, enabled: Bool) {
        guard let index = configuration.services.firstIndex(where: { $0.id == id }) else { return }
        configuration.services[index].enabled = enabled
        let service = configuration.services[index]
        if !enabled {
            tunnelSupervisor.stop(service: service)
        } else if let host = configuration.hosts.first(where: { $0.id == service.hostID }) {
            do {
                try tunnelSupervisor.start(host: host, service: service)
                configuration.services[index].status = .probing
                Task { await probeService(service.id) }
            } catch {
                configuration.services[index].lastError = error.localizedDescription
                configuration.services[index].status = .failed
            }
        }
        refreshRoutes()
        persistAndNotify()
    }

    public func forceHTTP(_ id: UUID, scheme: ServiceScheme = .http) {
        guard let index = configuration.services.firstIndex(where: { $0.id == id }) else { return }
        configuration.services[index].scheme = scheme
        configuration.services[index].status = .web
        configuration.services[index].enabled = true
        if let host = configuration.hosts.first(where: { $0.id == configuration.services[index].hostID }) {
            try? tunnelSupervisor.start(host: host, service: configuration.services[index])
        }
        refreshRoutes()
        persistAndNotify()
    }

    public func renameService(_ id: UUID, prettyName: String) {
        guard let index = configuration.services.firstIndex(where: { $0.id == id }) else { return }
        let sanitized = sanitizeDNSLabel(prettyName)
        configuration.services[index].prettyName = sanitized
        refreshRoutes()
        persistAndNotify()
    }

    public func url(for service: ServiceRecord) -> URL? {
        guard service.enabled, service.status == .web, service.scheme != nil else {
            return nil
        }
        let suffix = configuration.proxyPort == 80 ? "" : ":\(configuration.proxyPort)"
        return URL(string: "http://\(service.routeHost)\(suffix)/")
    }

    public func localhostURL(for service: ServiceRecord) -> URL? {
        guard service.enabled else {
            return nil
        }
        let scheme = service.scheme ?? .http
        return URL(string: "\(scheme.rawValue)://127.0.0.1:\(service.localPort)/")
    }

    public func isScanning(_ hostID: UUID) -> Bool {
        scanningHostIDs.contains(hostID)
    }

    public func lastScanSummary(for hostID: UUID) -> String? {
        lastScanSummaries[hostID]
    }

    private func startScanning(_ id: UUID) {
        guard scanTasks[id] == nil,
              let host = configuration.hosts.first(where: { $0.id == id }) else {
            return
        }
        scanTasks[id] = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.scan(host)
                let interval = max(5, host.scanInterval)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func scan(_ host: HostProfile) async {
        scanningHostIDs.insert(host.id)
        lastScanSummaries[host.id] = "Scanning remote ports..."
        notify()
        defer {
            scanningHostIDs.remove(host.id)
            notify()
        }

        do {
            let ports = try await RemotePortScanner.scan(host)
            lastError = nil
            lastScanSummaries[host.id] = "Found \(ports.count) listening port\(ports.count == 1 ? "" : "s")"
            for port in ports {
                await reconcile(host: host, remotePort: port)
            }
            let seen = Set(ports)
            for index in configuration.services.indices where configuration.services[index].hostID == host.id {
                if !seen.contains(configuration.services[index].remotePort) {
                    configuration.services[index].enabled = false
                    configuration.services[index].status = .unknown
                    tunnelSupervisor.stop(service: configuration.services[index])
                }
            }
            refreshRoutes()
            persistAndNotify()
        } catch {
            lastError = "\(host.displayName): \(error.localizedDescription)"
            lastScanSummaries[host.id] = "Scan failed"
            notify()
        }
    }

    private func reconcile(host: HostProfile, remotePort: RemotePort) async {
        if let index = configuration.services.firstIndex(where: { $0.hostID == host.id && $0.remotePort == remotePort }) {
            configuration.services[index].lastSeen = Date()
            let shouldRetryProbe = configuration.services[index].status == .failed
            if shouldRetryProbe, host.autoForward {
                configuration.services[index].enabled = true
            }
            if configuration.services[index].enabled {
                do {
                    try tunnelSupervisor.start(host: host, service: configuration.services[index])
                    configuration.services[index].status = .probing
                    await probeService(configuration.services[index].id)
                } catch {
                    configuration.services[index].lastError = error.localizedDescription
                    configuration.services[index].status = .failed
                }
            }
            return
        }

        let localPort = await allocator.reserve(preferred: remotePort.port)
        let service = ServiceRecord(
            hostID: host.id,
            hostName: host.displayName,
            remotePort: remotePort,
            localPort: localPort,
            enabled: host.autoForward,
            prettyName: defaultPrettyName(for: remotePort.port)
        )
        configuration.services.append(service)
        guard host.autoForward else {
            return
        }
        do {
            try tunnelSupervisor.start(host: host, service: service)
            await probeService(service.id)
        } catch {
            if let index = configuration.services.firstIndex(where: { $0.id == service.id }) {
                configuration.services[index].lastError = error.localizedDescription
                configuration.services[index].status = .failed
            }
        }
    }

    private func probeService(_ id: UUID) async {
        guard let index = configuration.services.firstIndex(where: { $0.id == id }) else { return }
        configuration.services[index].status = .probing
        notify()

        let service = configuration.services[index]
        if let result = await probe.probe(localPort: service.localPort),
           let currentIndex = configuration.services.firstIndex(where: { $0.id == id }) {
            configuration.services[currentIndex].scheme = result.scheme
            configuration.services[currentIndex].status = .web
            configuration.services[currentIndex].title = result.title
            configuration.services[currentIndex].lastError = nil
        } else if let currentIndex = configuration.services.firstIndex(where: { $0.id == id }) {
            configuration.services[currentIndex].scheme = nil
            configuration.services[currentIndex].status = .notHTTP
            configuration.services[currentIndex].enabled = false
            configuration.services[currentIndex].lastError = "No HTTP or HTTPS response detected"
            tunnelSupervisor.stop(service: configuration.services[currentIndex])
        }
        refreshRoutes()
        persistAndNotify()
    }

    private func refreshRoutes() {
        let routes = configuration.services.compactMap { service -> ProxyRoute? in
            guard service.enabled, service.status == .web, let scheme = service.scheme else {
                return nil
            }
            return ProxyRoute(hostname: service.routeHost, localPort: service.localPort, upstreamScheme: scheme)
        }
        registry.replace(with: routes)
    }

    private func persistAndNotify() {
        saveTask?.cancel()
        let config = configuration
        let store = settingsStore
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            try? store.save(config)
        }
        notify()
    }

    private func notify() {
        onChange?()
    }
}
