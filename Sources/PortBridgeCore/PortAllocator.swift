import Foundation
import Network

public actor PortAllocator {
    private let range: ClosedRange<Int>
    private var reserved: Set<Int>

    public init(range: ClosedRange<Int>, initiallyReserved: Set<Int> = []) {
        self.range = range
        reserved = initiallyReserved
    }

    public func reserve(preferred: Int?) async -> Int {
        if let preferred, preferred > 0, preferred < 65_536, !reserved.contains(preferred), await Self.isPortAvailable(preferred) {
            reserved.insert(preferred)
            return preferred
        }

        for _ in 0..<64 {
            let candidate = Int.random(in: range)
            if !reserved.contains(candidate), await Self.isPortAvailable(candidate) {
                reserved.insert(candidate)
                return candidate
            }
        }

        for candidate in range where !reserved.contains(candidate) {
            if await Self.isPortAvailable(candidate) {
                reserved.insert(candidate)
                return candidate
            }
        }

        return Int.random(in: 49_152...65_535)
    }

    public func release(_ port: Int) {
        reserved.remove(port)
    }

    public static func isPortAvailable(_ port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let listener: NWListener
            do {
                listener = try NWListener(using: .tcp, on: NWEndpoint.Port(integerLiteral: NWEndpoint.Port.IntegerLiteralType(port)))
            } catch {
                continuation.resume(returning: false)
                return
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.cancel()
                    continuation.resume(returning: true)
                case .failed:
                    listener.cancel()
                    continuation.resume(returning: false)
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue.global(qos: .utility))
        }
    }
}
