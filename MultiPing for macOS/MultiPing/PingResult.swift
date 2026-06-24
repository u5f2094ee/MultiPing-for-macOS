import Foundation
import Combine // Needed for ObservableObject

// Define an enum for target types
enum TargetType: String, Codable, CaseIterable { // Added CaseIterable for potential future use
    case ipv4 = "IPv4"
    case ipv6 = "IPv6"
    case domain = "Domain"
    case unknown = "Unknown" // For fallback or initial state
}

// Converted to a class conforming to ObservableObject
class PingResult: ObservableObject, Identifiable, Equatable { // Added Equatable
    let id = UUID() // Stays the same for Identifiable & Equatable
    let targetValue: String  // Renamed from 'ip' to be more generic
    let targetType: TargetType // New property to store the type
    let note: String? // New property for notes [cite: 1]

    // Properties that change are marked @Published
    @Published var responseTime: String
    @Published var successCount: Int
    @Published var failureCount: Int
    @Published var failureRate: Double
    @Published var isSuccessful: Bool
    @Published var currentLatencyMs: Double?
    @Published var averageLatencyMs: Double?
    @Published var minimumLatencyMs: Double?
    @Published var maximumLatencyMs: Double?

    var latencyTotalMs: Double = 0
    var latencySampleCount: Int = 0

    // Initializer for the class (UPDATED for note)
    init(targetValue: String, targetType: TargetType, note: String?, responseTime: String, successCount: Int, failureCount: Int, failureRate: Double, isSuccessful: Bool) {
        self.targetValue = targetValue
        self.targetType = targetType
        self.note = note // Initialize the new note property
        self.responseTime = responseTime
        self.successCount = successCount
        self.failureCount = failureCount
        self.failureRate = failureRate
        self.isSuccessful = isSuccessful
        self.currentLatencyMs = nil
        self.averageLatencyMs = nil
        self.minimumLatencyMs = nil
        self.maximumLatencyMs = nil
    }

    // Equatable conformance based on ID
    static func == (lhs: PingResult, rhs: PingResult) -> Bool {
        return lhs.id == rhs.id
    }

    // Helper to reset counts and status (useful for start/clear)
    func resetStats(initialStatus: String = "Pending") {
        // Ensure updates happen on the main thread if called from background
        // However, since @Published handles this, direct assignment is okay here.
        self.responseTime = initialStatus
        self.successCount = 0
        self.failureCount = 0
        self.failureRate = 0.0
        self.isSuccessful = false
        self.currentLatencyMs = nil
        self.averageLatencyMs = nil
        self.minimumLatencyMs = nil
        self.maximumLatencyMs = nil
        self.latencyTotalMs = 0
        self.latencySampleCount = 0
    }

    func recordLatency(milliseconds: Double) {
        currentLatencyMs = milliseconds
        latencyTotalMs += milliseconds
        latencySampleCount += 1
        averageLatencyMs = latencyTotalMs / Double(latencySampleCount)
        minimumLatencyMs = min(minimumLatencyMs ?? milliseconds, milliseconds)
        maximumLatencyMs = max(maximumLatencyMs ?? milliseconds, milliseconds)
    }

    func clearCurrentLatency() {
        currentLatencyMs = nil
    }

    static func formatLatency(milliseconds: Double) -> String {
        if milliseconds < 1 {
            return String(format: "%.3f ms", milliseconds)
        }
        if milliseconds < 10 {
            return String(format: "%.2f ms", milliseconds)
        }
        return String(format: "%.1f ms", milliseconds)
    }

    static func latencyDisplay(_ milliseconds: Double?) -> String {
        guard let milliseconds = milliseconds else { return "-" }
        return formatLatency(milliseconds: milliseconds)
    }

    // Convenience accessor for display name, which is always the targetValue
    var displayName: String {
        return targetValue
    }
}
