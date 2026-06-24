import Foundation
import Combine

class PingManager: ObservableObject {
    private let userDefaultsIPKey = "lastIPInput"

    @Published var ipInput: String {
        didSet { UserDefaults.standard.set(ipInput, forKey: userDefaultsIPKey) }
    }
    @Published var results: [PingResult] = [] {
        didSet { Task { @MainActor in self.updateTotalCounts() } }
    }
    @Published var pingStarted = false
    @Published var isPaused = false
    @Published var pingStatus: String = "Stopped"
    @Published var reachableCount: Int = 0
    @Published var failedCount: Int = 0
    @Published var engineErrorMessage: String? = nil

    private var pingTaskGroup: Task<Void, Never>? = nil
    private var currentTimeout: String = "2000"
    private var currentInterval: String = "3"
    private var currentSize: String = "32"
    private var currentDscp: String = "0"
    private let fpingEngine = FpingEngine()
    private let maxEngineRestartAttempts = 2
    private let engineRestartDelayNs: UInt64 = 500_000_000

    init() {
        self.ipInput = UserDefaults.standard.string(forKey: userDefaultsIPKey) ?? ""
        Task { @MainActor in self.updateTotalCounts() }
    }

    deinit {
        print("PingManager deinit called. Current status: \(pingStatus)")
        pingTaskGroup?.cancel()
        pingTaskGroup = nil
    }

    func startPingTasks(timeout: String, interval: String, size: String, dscp: String) {
        guard !pingStarted else { return }

        let isResuming = (pingStatus == "Paused")
        self.currentTimeout = timeout
        self.currentInterval = interval
        self.currentSize = size
        self.currentDscp = dscp

        pingStarted = true
        isPaused = false
        pingStatus = "Pinging..."
        engineErrorMessage = nil

        Task { @MainActor in
            if !isResuming {
                for result in results {
                    result.resetStats(initialStatus: "Pinging...")
                }
                self.updateTotalCounts()
            } else {
                for result in results where result.responseTime.lowercased() == "paused" {
                    result.responseTime = "Pinging..."
                }
            }
        }

        pingTaskGroup?.cancel()
        pingTaskGroup = Task {
            await runPingLoop()
            if !Task.isCancelled {
                await MainActor.run {
                    if self.pingStarted && !self.isPaused {
                        self.pingStarted = false
                        self.pingStatus = "Completed"
                    }
                    if self.pingStatus != "Pinging..." {
                        for result in self.results where result.responseTime.lowercased() == "pinging..." {
                            result.responseTime = self.pingStatus
                            if ["Completed", "Stopped", "Cleared", "Cancelled"].contains(self.pingStatus) {
                                result.isSuccessful = false
                            }
                        }
                    }
                    self.updateTotalCounts()
                }
            }
        }
    }

    func togglePause() {
        guard (pingStatus == "Pinging..." && !isPaused) || (pingStatus == "Paused" && isPaused) else { return }

        if !isPaused {
            isPaused = true
            pingStarted = false
            pingStatus = "Paused"
            pingTaskGroup?.cancel()
            pingTaskGroup = nil

            Task { @MainActor [weak self] in
                guard let self = self else { return }
                for result in self.results where result.responseTime.lowercased() == "pinging..." {
                    result.responseTime = "Paused"
                }
                self.updateTotalCounts()
            }
        } else {
            startPingTasks(timeout: currentTimeout, interval: currentInterval, size: currentSize, dscp: currentDscp)
        }
    }

    func stopPingTasks(clearResults: Bool) {
        let previousStatus = self.pingStatus
        let wasEffectivelyRunning = pingStarted || previousStatus == "Pinging..." || previousStatus == "Paused"

        pingTaskGroup?.cancel()
        pingTaskGroup = nil
        pingStarted = false
        isPaused = false

        let newFinalStatus = clearResults ? "Cleared" : "Stopped"

        Task { @MainActor [weak self] in
            guard let self = self else { return }

            self.pingStatus = newFinalStatus
            if clearResults {
                self.engineErrorMessage = nil
            }

            if wasEffectivelyRunning || clearResults {
                for result in self.results {
                    let currentItemStatus = result.responseTime.lowercased()

                    if clearResults ||
                        ["pinging...", "paused", "pending", "restarting engine..."].contains(currentItemStatus) ||
                        (newFinalStatus == "Stopped" && wasEffectivelyRunning) {
                        result.responseTime = newFinalStatus
                        result.isSuccessful = false
                    }

                    if clearResults {
                        result.resetStats(initialStatus: "Cleared")
                    }
                }
            }
            self.updateTotalCounts()
        }
    }

    @MainActor func prepareForAppTermination(clearResults: Bool) {
        pingTaskGroup?.cancel()
        pingTaskGroup = nil
        pingStarted = false
        isPaused = false
        pingStatus = clearResults ? "Cleared" : "Stopped"
        if clearResults {
            engineErrorMessage = nil
            for result in results {
                result.resetStats(initialStatus: "Cleared")
            }
        } else {
            for result in results where ["pinging...", "paused", "pending", "restarting engine..."].contains(result.responseTime.lowercased()) {
                result.responseTime = "Stopped"
                result.isSuccessful = false
                result.clearCurrentLatency()
            }
        }
        updateTotalCounts()
    }

    private func runPingLoop() async {
        var consecutiveEngineRestartAttempts = 0

        while !Task.isCancelled && pingStarted && !isPaused {
            let roundStartTime = Date()
            let timeoutMs = Int(currentTimeout) ?? 2000
            let packetSize = Int(currentSize) ?? 32
            let dscpValue = Int(currentDscp) ?? 0
            let roundTargets = results.map {
                FpingTarget(id: $0.id, value: $0.targetValue, type: $0.targetType)
            }

            do {
                let roundResults = try await fpingEngine.probe(
                    targets: roundTargets,
                    timeoutMs: timeoutMs,
                    packetSize: packetSize,
                    dscp: dscpValue
                )

                guard !Task.isCancelled && pingStarted && !isPaused else { break }
                await apply(roundResults: roundResults)
                consecutiveEngineRestartAttempts = 0
            } catch is CancellationError {
                break
            } catch {
                if shouldRestartEngine(after: error, currentAttemptCount: consecutiveEngineRestartAttempts) {
                    consecutiveEngineRestartAttempts += 1
                    await markEngineRestartAttempt(error, attempt: consecutiveEngineRestartAttempts)
                    do {
                        try await Task.sleep(nanoseconds: engineRestartDelayNs)
                    } catch {
                        break
                    }
                    continue
                }

                await handleEngineFailure(error)
                break
            }

            guard !Task.isCancelled && pingStarted && !isPaused else { break }

            let roundDuration = Date().timeIntervalSince(roundStartTime)
            let baseIntervalSeconds = TimeInterval(Int(self.currentInterval) ?? 5)
            let sleepDuration = max(0.01, baseIntervalSeconds - roundDuration)

            do {
                try await Task.sleep(nanoseconds: UInt64(sleepDuration * 1_000_000_000.0))
            } catch {
                break
            }
        }
    }

    @MainActor private func apply(roundResults: [UUID: FpingProbeResult]) {
        guard pingStarted, !isPaused else { return }

        engineErrorMessage = nil

        for result in results {
            guard let probeResult = roundResults[result.id] else { continue }

            result.responseTime = probeResult.responseTime
            result.isSuccessful = probeResult.isSuccessful

            if probeResult.isSuccessful {
                result.successCount += 1
                if let latencyMilliseconds = probeResult.latencyMilliseconds {
                    result.recordLatency(milliseconds: latencyMilliseconds)
                } else {
                    result.clearCurrentLatency()
                }
            } else if !["paused", "stopped", "cancelled", "pinging...", "pending", "cleared"].contains(probeResult.responseTime.lowercased()) {
                result.clearCurrentLatency()
                result.failureCount += 1
            } else {
                result.clearCurrentLatency()
            }

            let totalPings = result.successCount + result.failureCount
            result.failureRate = totalPings > 0 ? (Double(result.failureCount) / Double(totalPings)) * 100.0 : 0.0
        }

        updateTotalCounts()
    }

    private func shouldRestartEngine(after error: Error, currentAttemptCount: Int) -> Bool {
        guard currentAttemptCount < maxEngineRestartAttempts else { return false }

        if case FpingEngineError.timedOut = error {
            return true
        }

        return false
    }

    @MainActor private func markEngineRestartAttempt(_ error: Error, attempt: Int) {
        guard pingStarted, !isPaused else { return }

        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        engineErrorMessage = "\(message) Restarting fping automatically (attempt \(attempt)/\(maxEngineRestartAttempts))."

        for result in results where ["pinging...", "pending", "restarting engine..."].contains(result.responseTime.lowercased()) {
            result.responseTime = "Restarting engine..."
            result.isSuccessful = false
            result.clearCurrentLatency()
        }

        updateTotalCounts()
    }

    @MainActor private func handleEngineFailure(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

        pingStarted = false
        isPaused = false
        pingStatus = "Engine Unavailable"
        engineErrorMessage = message

        for result in results where ["pinging...", "pending"].contains(result.responseTime.lowercased()) {
            result.responseTime = "Engine unavailable"
            result.isSuccessful = false
        }

        updateTotalCounts()
    }

    @MainActor private func updateTotalCounts() {
        let inactiveStatuses = ["pinging...", "pending", "paused", "stopped", "cleared", "cancelled", "engine unavailable", "restarting engine..."]
        reachableCount = results.filter { $0.isSuccessful && !inactiveStatuses.contains($0.responseTime.lowercased()) }.count
        failedCount = results.filter { !$0.isSuccessful && !inactiveStatuses.contains($0.responseTime.lowercased()) }.count
    }
}
