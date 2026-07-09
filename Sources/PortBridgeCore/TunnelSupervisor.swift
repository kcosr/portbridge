import Foundation

public final class TunnelSupervisor: @unchecked Sendable {
    public struct Key: Hashable, Sendable {
        public var hostID: UUID
        public var bindAddress: String
        public var remotePort: Int
    }

    private let lock = NSLock()
    private var processes: [Key: Process] = [:]

    public init() {}

    public func start(host: HostProfile, service: ServiceRecord) throws {
        let key = Key(hostID: host.id, bindAddress: service.remotePort.bindAddress, remotePort: service.remotePort.port)
        lock.lock()
        if processes[key]?.isRunning == true {
            lock.unlock()
            return
        }
        lock.unlock()

        var args = [
            "-N",
            "-T",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            "-L", "127.0.0.1:\(service.localPort):\(service.remotePort.bindAddress):\(service.remotePort.port)",
        ]
        args += RemotePortScanner.sshArguments(for: host)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()

        lock.lock()
        processes[key] = process
        lock.unlock()
    }

    public func stop(service: ServiceRecord) {
        let key = Key(hostID: service.hostID, bindAddress: service.remotePort.bindAddress, remotePort: service.remotePort.port)
        stop(key)
    }

    private func stop(_ key: Key) {
        lock.lock()
        let process = processes.removeValue(forKey: key)
        lock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    public func stopHost(_ hostID: UUID) {
        lock.lock()
        let keys = processes.keys.filter { $0.hostID == hostID }
        lock.unlock()
        for key in keys {
            stop(key)
        }
    }

    public func stopAll() {
        lock.lock()
        let current = processes
        processes.removeAll()
        lock.unlock()
        for process in current.values where process.isRunning {
            process.terminate()
        }
    }

    public func isRunning(hostID: UUID, remotePort: Int) -> Bool {
        let key = Key(hostID: hostID, bindAddress: "127.0.0.1", remotePort: remotePort)
        lock.lock()
        defer { lock.unlock() }
        return processes[key]?.isRunning == true
    }
}
