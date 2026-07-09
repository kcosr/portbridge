import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
}

public enum ProcessRunner {
    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func string() -> String {
            lock.lock()
            let current = data
            lock.unlock()
            return String(data: current, encoding: .utf8) ?? ""
        }
    }

    private final class CompletionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private let continuation: CheckedContinuation<ProcessResult, Error>

        init(_ continuation: CheckedContinuation<ProcessResult, Error>) {
            self.continuation = continuation
        }

        func finish(_ result: Result<ProcessResult, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            continuation.resume(with: result)
        }
    }

    public static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval = 20
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let completion = CompletionBox(continuation)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let stdout = Pipe()
            let stderr = Pipe()
            let stdoutBuffer = OutputBuffer()
            let stderrBuffer = OutputBuffer()
            process.standardOutput = stdout
            process.standardError = stderr

            stdout.fileHandleForReading.readabilityHandler = { handle in
                stdoutBuffer.append(handle.availableData)
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                stderrBuffer.append(handle.availableData)
            }

            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                stdoutBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
                stderrBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
                let out = stdoutBuffer.string()
                let err = stderrBuffer.string()
                completion.finish(.success(ProcessResult(status: proc.terminationStatus, stdout: out, stderr: err)))
            }

            do {
                try process.run()
            } catch {
                completion.finish(.failure(error))
                return
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if process.isRunning {
                    process.terminate()
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if process.isRunning {
                        process.interrupt()
                    }
                }
            }
        }
    }
}
