import Foundation

public enum RemotePortScanner {
    public static let neverForwardPorts: Set<Int> = [22]

    public static let scanCommand = """
if command -v ss >/dev/null 2>&1; then
  ss -H -ltn
elif command -v netstat >/dev/null 2>&1; then
  netstat -an -p tcp 2>/dev/null | grep LISTEN || netstat -ltn 2>/dev/null
elif command -v lsof >/dev/null 2>&1; then
  lsof -nP -iTCP -sTCP:LISTEN
else
  exit 127
fi
"""

    public static func scan(_ host: HostProfile) async throws -> [RemotePort] {
        let result = try await ProcessRunner.run(
            "/usr/bin/ssh",
            arguments: sshArguments(for: host) + [remoteShellCommand(scanCommand)],
            timeout: 12
        )
        guard result.status == 0 else {
            let message = sanitizedSSHError(result.stderr)
            throw NSError(
                domain: "PortBridge.RemotePortScanner",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "Remote scan failed" : message]
            )
        }
        return parseListeningPorts(result.stdout)
    }

    public static func sshArguments(for host: HostProfile) -> [String] {
        var args = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "LogLevel=ERROR",
        ]

        if host.usesSSHConfigAlias {
            args.append(host.alias)
        } else {
            if host.port != 22 {
                args += ["-p", String(host.port)]
            }
            args.append(host.sshTarget)
        }
        return args
    }

    public static func remoteShellCommand(_ command: String) -> String {
        "sh -lc \(shellQuote(command))"
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func sanitizedSSHError(_ stderr: String) -> String {
        stderr
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("Warning: Permanently added ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func parseListeningPorts(_ output: String) -> [RemotePort] {
        var ports = Set<RemotePort>()
        for line in output.split(separator: "\n").map(String.init) {
            guard line.localizedCaseInsensitiveContains("listen") || line.split(whereSeparator: { $0 == " " || $0 == "\t" }).count >= 4 else {
                continue
            }
            for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
                if let parsed = parseAddressPort(token) {
                    ports.insert(parsed)
                    break
                }
            }
        }
        return ports
            .filter { $0.port > 0 && $0.port < 65_536 }
            .filter { !neverForwardPorts.contains($0.port) }
            .sorted { lhs, rhs in
                if lhs.port == rhs.port {
                    return lhs.bindAddress < rhs.bindAddress
                }
                return lhs.port < rhs.port
            }
    }

    private static func parseAddressPort(_ token: String) -> RemotePort? {
        let value = token.trimmingCharacters(in: CharacterSet(charactersIn: ","))
        guard value.contains(":") || value.contains(".") else { return nil }
        if value.hasPrefix("[") {
            guard let close = value.lastIndex(of: "]") else { return nil }
            let address = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            guard rest.first == ":" else { return nil }
            let portText = String(rest.dropFirst())
            guard let port = Int(portText) else { return nil }
            return RemotePort(bindAddress: normalizeBindAddress(address), port: port)
        }

        if let lastColon = value.lastIndex(of: ":") {
            let address = String(value[..<lastColon])
            let portText = String(value[value.index(after: lastColon)...])
            guard let port = Int(portText) else { return nil }
            return RemotePort(bindAddress: normalizeBindAddress(address), port: port)
        }

        if let lastDot = value.lastIndex(of: ".") {
            let address = String(value[..<lastDot])
            let portText = String(value[value.index(after: lastDot)...])
            guard let port = Int(portText) else { return nil }
            return RemotePort(bindAddress: normalizeBindAddress(address), port: port)
        }

        return nil
    }

    private static func normalizeBindAddress(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if trimmed == "*" || trimmed == "0.0.0.0" || trimmed == "::" {
            return "127.0.0.1"
        }
        if trimmed == "localhost" || trimmed == "::1" {
            return "127.0.0.1"
        }
        return trimmed.isEmpty ? "127.0.0.1" : trimmed
    }
}
