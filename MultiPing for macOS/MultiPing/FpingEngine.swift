import Foundation

struct FpingTarget {
    let id: UUID
    let value: String
    let type: TargetType
}

struct FpingProbeResult {
    let responseTime: String
    let isSuccessful: Bool
    let latencyMilliseconds: Double?
}

enum FpingEngineError: LocalizedError {
    case bundledExecutableMissing
    case bundledExecutableNotExecutable(String)
    case failedToStart(String)
    case timedOut
    case fatalOutput(String)

    var errorDescription: String? {
        switch self {
        case .bundledExecutableMissing:
            return "The bundled fping engine is missing. Please reinstall MultiPing from a complete app package."
        case .bundledExecutableNotExecutable(let path):
            return "The bundled fping engine is not executable at \(path). Please reinstall MultiPing from a complete app package."
        case .failedToStart(let message):
            return "The bundled fping engine failed to start: \(message)"
        case .timedOut:
            return "The bundled fping engine did not respond in time. Please restart MultiPing and try again."
        case .fatalOutput(let output):
            return "The bundled fping engine returned a fatal error: \(output)"
        }
    }
}

final class FpingEngine {
    private enum AddressFamily {
        case ipv4
        case ipv6
    }

    func probe(targets: [FpingTarget], timeoutMs: Int, packetSize: Int, dscp: Int) async throws -> [UUID: FpingProbeResult] {
        guard !targets.isEmpty else { return [:] }

        let executableURL = try bundledExecutableURL()
        let ipv6Targets = targets.filter { $0.type == .ipv6 }
        let ipv4Targets = targets.filter { $0.type != .ipv6 }

        var mergedResults: [UUID: FpingProbeResult] = [:]
        if !ipv4Targets.isEmpty {
            let results = try await runFping(
                executableURL: executableURL,
                targets: ipv4Targets,
                family: .ipv4,
                timeoutMs: timeoutMs,
                packetSize: packetSize,
                dscp: dscp
            )
            mergedResults.merge(results) { _, new in new }
        }
        if !ipv6Targets.isEmpty {
            let results = try await runFping(
                executableURL: executableURL,
                targets: ipv6Targets,
                family: .ipv6,
                timeoutMs: timeoutMs,
                packetSize: packetSize,
                dscp: dscp
            )
            mergedResults.merge(results) { _, new in new }
        }

        return mergedResults
    }

    private func bundledExecutableURL() throws -> URL {
        let bundle = Bundle.main
        let candidates = [
            bundle.url(forResource: "fping", withExtension: nil),
            bundle.resourceURL?.appendingPathComponent("fping"),
            bundle.resourceURL?.appendingPathComponent("Resources/fping")
        ].compactMap { $0 }

        guard let executableURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw FpingEngineError.bundledExecutableMissing
        }

        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw FpingEngineError.bundledExecutableNotExecutable(executableURL.path)
        }

        return executableURL
    }

    private func runFping(
        executableURL: URL,
        targets: [FpingTarget],
        family: AddressFamily,
        timeoutMs: Int,
        packetSize: Int,
        dscp: Int
    ) async throws -> [UUID: FpingProbeResult] {
        let safeTimeoutMs = max(1, timeoutMs)
        let safePacketSize = max(0, packetSize)
        let safeDscp = min(63, max(0, dscp))
        let safePeriodMs = max(20, safeTimeoutMs + 1)
        let processTimeoutMs = max(10_000, safePeriodMs + safeTimeoutMs + targets.count * 5 + 5_000)
        let processTimeoutNs = UInt64(processTimeoutMs) * 1_000_000
        let process = Process()
        let outputPipe = Pipe()
        let inputPipe = Pipe()

        process.executableURL = executableURL
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.standardInput = inputPipe
        process.arguments = self.arguments(
            for: family,
            timeoutMs: safeTimeoutMs,
            packetSize: safePacketSize,
            periodMs: safePeriodMs,
            dscp: safeDscp
        )

        return try await withTaskCancellationHandler {
            try await withTimeout(
                nanoseconds: processTimeoutNs,
                onTimeout: {
                    if process.isRunning {
                        process.terminate()
                    }
                },
                operation: {
                    try await self.run(process: process, inputPipe: inputPipe, outputPipe: outputPipe, targets: targets)
                }
            )
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    private func run(
        process: Process,
        inputPipe: Pipe,
        outputPipe: Pipe,
        targets: [FpingTarget]
    ) async throws -> [UUID: FpingProbeResult] {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { [weak self] _ in
                guard let self = self else { return }

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                try? outputPipe.fileHandleForReading.close()

                let output = String(data: outputData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if let fatalMessage = self.fatalMessage(from: output) {
                    continuation.resume(throwing: FpingEngineError.fatalOutput(fatalMessage))
                    return
                }

                continuation.resume(returning: self.parse(output: output, targets: targets))
            }

            do {
                try process.run()

                let input = targets.map(\.value).joined(separator: "\n") + "\n"
                if let inputData = input.data(using: .utf8) {
                    inputPipe.fileHandleForWriting.write(inputData)
                }
                try? inputPipe.fileHandleForWriting.close()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: FpingEngineError.failedToStart(error.localizedDescription))
            }
        }
    }

    private func arguments(for family: AddressFamily, timeoutMs: Int, packetSize: Int, periodMs: Int, dscp: Int) -> [String] {
        var arguments = [
            family == .ipv6 ? "-6" : "-4",
            "-C", "1",
            "-q",
            "-r", "0",
            "-t", String(timeoutMs),
            "-p", String(periodMs),
            "-i", "1",
            "-b", String(packetSize),
            "-f", "-"
        ]

        if dscp > 0 {
            arguments.insert(contentsOf: ["-O", String(dscp << 2)], at: arguments.count - 2)
        }

        return arguments
    }

    private func parse(output: String, targets: [FpingTarget]) -> [UUID: FpingProbeResult] {
        var pendingIDsByValue = Dictionary(grouping: targets, by: \.value).mapValues { $0.map(\.id) }
        var results: [UUID: FpingProbeResult] = [:]

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            guard let parsedLine = parseResultLine(line) else { continue }
            guard var pendingIDs = pendingIDsByValue[parsedLine.target], !pendingIDs.isEmpty else { continue }

            let id = pendingIDs.removeFirst()
            pendingIDsByValue[parsedLine.target] = pendingIDs
            results[id] = result(from: parsedLine.value)
        }

        for target in targets where results[target.id] == nil {
            results[target.id] = FpingProbeResult(
                responseTime: target.type == .domain ? "Host unknown" : "Timeout",
                isSuccessful: false,
                latencyMilliseconds: nil
            )
        }

        return results
    }

    private func parseResultLine(_ line: String) -> (target: String, value: String)? {
        guard let separatorRange = line.range(of: #"\s+:\s+"#, options: .regularExpression) else {
            return nil
        }

        let target = String(line[..<separatorRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(line[separatorRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !target.isEmpty, !value.isEmpty else { return nil }
        return (target, value)
    }

    private func result(from value: String) -> FpingProbeResult {
        if value == "-" {
            return FpingProbeResult(responseTime: "Timeout", isSuccessful: false, latencyMilliseconds: nil)
        }

        if let milliseconds = Double(value) {
            return FpingProbeResult(
                responseTime: format(milliseconds: milliseconds),
                isSuccessful: true,
                latencyMilliseconds: milliseconds
            )
        }

        return FpingProbeResult(responseTime: "Failed", isSuccessful: false, latencyMilliseconds: nil)
    }

    private func format(milliseconds: Double) -> String {
        if milliseconds < 1 {
            return String(format: "%.3f ms", milliseconds)
        }
        if milliseconds < 10 {
            return String(format: "%.2f ms", milliseconds)
        }
        return String(format: "%.1f ms", milliseconds)
    }

    private func fatalMessage(from output: String) -> String? {
        let lowerOutput = output.lowercased()
        let fatalPatterns = [
            "can't create socket",
            "cannot create socket",
            "operation not permitted",
            "permission denied",
            "must run as root",
            "usage:"
        ]

        guard fatalPatterns.contains(where: { lowerOutput.contains($0) }) else {
            return nil
        }

        return output.isEmpty ? "unknown fping error" : output
    }

    private func withTimeout<T: Sendable>(
        nanoseconds: UInt64,
        onTimeout: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                onTimeout()
                throw FpingEngineError.timedOut
            }

            guard let result = try await group.next() else {
                throw FpingEngineError.timedOut
            }

            group.cancelAll()
            return result
        }
    }
}
