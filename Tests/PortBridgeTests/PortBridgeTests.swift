import Foundation
import Testing
@testable import PortBridgeCore

@Test func parsesSSHConfigHosts() async throws {
    let config = """
Host devbox
  HostName 192.0.2.10
  User kc
  Port 2222

Host *.internal
  User ignored

Host staging api-box
  HostName staging.example.com
  User deploy
"""

    let entries = SSHConfigParser.parse(config)
    #expect(entries.count == 2)
    #expect(entries[0].patterns == ["devbox"])
    #expect(entries[0].hostname == "192.0.2.10")
    #expect(entries[0].user == "kc")
    #expect(entries[0].port == 2222)
    #expect(entries[1].patterns == ["staging", "api-box"])
}

@Test func parsesListeningPortsFromSS() async throws {
    let ss = """
LISTEN 0 4096 127.0.0.1:3000 0.0.0.0:*
LISTEN 0 4096 [::1]:5173 [::]:*
LISTEN 0 4096 0.0.0.0:8080 0.0.0.0:*
LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*
"""

    let parsed = RemotePortScanner.parseListeningPorts(ss)
    #expect(parsed.contains(RemotePort(bindAddress: "127.0.0.1", port: 3000)))
    #expect(parsed.contains(RemotePort(bindAddress: "127.0.0.1", port: 5173)))
    #expect(parsed.contains(RemotePort(bindAddress: "127.0.0.1", port: 8080)))
    #expect(!parsed.contains(RemotePort(bindAddress: "127.0.0.1", port: 22)))
}

@Test func sanitizesLabels() async throws {
    #expect(sanitizeDNSLabel("Dev_Box.local") == "dev-box-local")
    #expect(sanitizeDNSLabel("...") == "host")
    #expect(defaultPrettyName(for: 3000) == "p3000")
}

@Test func configurationRoundTrip() async throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("config.json")
    let store = SettingsStore(configurationURL: url)
    let host = HostProfile(alias: "devbox", hostname: "", enabled: true)
    let config = AppConfiguration(hosts: [host], proxyPort: 8090)
    try store.save(config)
    let loaded = try store.load()
    #expect(loaded.hosts == [host])
    #expect(loaded.proxyPort == 8090)
}

@Test func hostProfileDefaultsAutoForwardOffWhenLoadingOldConfig() async throws {
    let json = """
{
  "id": "7FBE84DD-6796-4964-A100-74C4D56C3FC9",
  "alias": "aw-ubuntu",
  "hostname": "",
  "user": "",
  "port": 22,
  "enabled": true,
  "scanInterval": 15,
  "useSSHConfigAlias": true
}
"""
    let host = try JSONDecoder().decode(HostProfile.self, from: Data(json.utf8))
    #expect(!host.autoForward)
}

@Test func manualHostUsesHostnameNotFriendlyAlias() async throws {
    let host = HostProfile(alias: "friendly", hostname: "10.0.0.5", user: "dev", port: 2200)
    let args = RemotePortScanner.sshArguments(for: host)
    #expect(args.contains("dev@10.0.0.5"))
    #expect(args.contains("2200"))
    #expect(!args.contains("friendly"))
}

@Test func routeRegistryToleratesDuplicateHostnames() async throws {
    let registry = RouteRegistry()
    registry.replace(with: [
        ProxyRoute(hostname: "p3000.dev.localhost", localPort: 24_001, upstreamScheme: .http),
        ProxyRoute(hostname: "p3000.dev.localhost", localPort: 24_002, upstreamScheme: .http),
    ])
    #expect(registry.route(for: "p3000.dev.localhost")?.localPort == 24_002)
}

@Test func routeHostIncludesNonLoopbackBindAddressForDefaultNames() async throws {
    let hostID = UUID()
    let local = ServiceRecord(
        hostID: hostID,
        hostName: "devbox",
        remotePort: RemotePort(bindAddress: "127.0.0.1", port: 3000),
        localPort: 24_001,
        prettyName: "p3000"
    )
    let lan = ServiceRecord(
        hostID: hostID,
        hostName: "devbox",
        remotePort: RemotePort(bindAddress: "192.168.1.10", port: 3000),
        localPort: 24_002,
        prettyName: "p3000"
    )
    #expect(local.routeHost == "p3000.devbox.localhost")
    #expect(lan.routeHost == "p3000-192-168-1-10.devbox.localhost")
}

@Test func remoteScanCommandIsShellQuotedForSSH() async throws {
    let command = RemotePortScanner.remoteShellCommand("if command -v ss >/dev/null 2>&1; then\n  ss -H -ltn\nfi")
    #expect(command.hasPrefix("sh -lc 'if command -v ss"))
    #expect(command.contains("; then"))
    #expect(command.hasSuffix("\nfi'"))
}

@Test func filtersPermanentHostKeyWarningFromErrors() async throws {
    let stderr = """
Warning: Permanently added '[127.0.0.1]:56000' (ED25519) to the list of known hosts.
bash: -c: line 1: syntax error near unexpected token `then'
"""
    #expect(RemotePortScanner.sanitizedSSHError(stderr) == "bash: -c: line 1: syntax error near unexpected token `then'")
}

@Test func detectsPlainHTTPRequestToHTTPSPortResponse() async throws {
    let result = ProbeResult(
        scheme: .http,
        statusCode: 400,
        title: "400 The plain HTTP request was sent to HTTPS port",
        bodySnippet: nil
    )
    #expect(HTTPProbe.isPlainHTTPOnHTTPSResponse(result))
}

@Test func detectsPlainHTTPRequestToHTTPSPortResponseFromBody() async throws {
    let result = ProbeResult(
        scheme: .http,
        statusCode: 400,
        title: "400 Bad Request",
        bodySnippet: "The plain HTTP request was sent to HTTPS port"
    )
    #expect(HTTPProbe.isPlainHTTPOnHTTPSResponse(result))
}

@Test func normalizesDuplicateMisclassifiedHTTPSLegacyServices() async throws {
    let hostID = UUID()
    let disabled = ServiceRecord(
        hostID: hostID,
        hostName: "srv",
        remotePort: RemotePort(bindAddress: "127.0.0.1", port: 443),
        localPort: 60_174,
        enabled: false,
        scheme: .http,
        status: .web,
        title: "400 The plain HTTP request was sent to HTTPS port",
        prettyName: "p443",
        lastSeen: Date(timeIntervalSince1970: 20)
    )
    let enabled = ServiceRecord(
        hostID: hostID,
        hostName: "srv",
        remotePort: RemotePort(bindAddress: "127.0.0.1", port: 443),
        localPort: 53_602,
        enabled: true,
        scheme: .http,
        status: .web,
        title: "400 The plain HTTP request was sent to HTTPS port",
        prettyName: "p443",
        lastSeen: Date(timeIntervalSince1970: 10)
    )
    var config = AppConfiguration(services: [disabled, enabled])
    config.normalizeLegacyServices()
    #expect(config.services.count == 1)
    #expect(config.services[0].enabled)
    #expect(config.services[0].localPort == 53_602)
    #expect(config.services[0].scheme == nil)
    #expect(config.services[0].status == .notHTTP)
}

@Test func visibleServicesHideNonHTTPRecords() async throws {
    let hostID = UUID()
    let store = SettingsStore(
        configurationURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("config.json")
    )
    try store.save(
        AppConfiguration(
            services: [
                ServiceRecord(
                    hostID: hostID,
                    hostName: "srv",
                    remotePort: RemotePort(bindAddress: "127.0.0.1", port: 1234),
                    localPort: 24_001,
                    enabled: false,
                    status: .notHTTP,
                    prettyName: "p1234"
                ),
                ServiceRecord(
                    hostID: hostID,
                    hostName: "srv",
                    remotePort: RemotePort(bindAddress: "127.0.0.1", port: 3000),
                    localPort: 24_002,
                    enabled: false,
                    status: .unknown,
                    prettyName: "p3000"
                ),
            ]
        )
    )
    let state = await AppState(settingsStore: store)
    let visible = await state.visibleServices
    #expect(visible.count == 1)
    #expect(visible[0].remotePort.port == 3000)
}
