import SwiftUI
import AppKit
import Foundation

// Enum for View Modes (Unchanged)
enum ResultsViewMode: String, CaseIterable, Identifiable {
    case list = "≡ List Layout"
    case grid = "# Grid Layout"
    var id: String { self.rawValue }
}

struct IPInputView: View {
    @ObservedObject var manager: PingManager
    @State var timeout: String = "2000"
    @State var size: String = "32"
    @State var interval: String = "3"
    @State var dscp: String = "0"
    @State private var selectedViewMode: ResultsViewMode = .list

    private var placeholderText: String = """
e.g.,
8.8.8.8
2001:db8::1
example.com
192.168.1.1, Home Router
10.0.0.2    Office Server
ff00::1\tLab IPv6 Gateway

Notes are optional. Use comma, space, or tab to separate target from note.
"""
    
    init(manager: PingManager) {
        self.manager = manager
    }

    var validTargetCount: Int {
        return parseTargets(from: manager.ipInput).count
    }

    var suggestedInterval: Int {
        let timeoutMs = Int(timeout) ?? 2000
        return max(1, (timeoutMs / 1000) + 1)
    }

    var dscpMarkDescription: String {
        guard let value = Int(dscp.trimmingCharacters(in: .whitespacesAndNewlines)), (0...63).contains(value) else {
            return "Invalid"
        }
        return DSCPMark.name(for: value)
    }
    

    var body: some View {
        VStack(spacing: 15) {
            // Settings Row
            HStack(alignment: .bottom, spacing: 15) {
                VStack(alignment: .leading) { Text("Timeout (ms)").font(.caption); TextField("2000", text: $timeout).textFieldStyle(RoundedBorderTextFieldStyle()).frame(width: 80) }
                VStack(alignment: .leading) { Text("Size (bytes)").font(.caption); TextField("32", text: $size).textFieldStyle(RoundedBorderTextFieldStyle()).frame(width: 80) }
                VStack(alignment: .leading) { Text("Interval (s)").font(.caption); TextField("", text: $interval).textFieldStyle(RoundedBorderTextFieldStyle()).frame(width: 80) }
                VStack(alignment: .leading) {
                    Text("DSCP (0-63)").font(.caption)
                    HStack(spacing: 6) {
                        TextField("0", text: $dscp)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 80)
                        Text(dscpMarkDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 64, alignment: .leading)
                    }
                }
                Spacer()
            }.padding(.top).padding(.horizontal)

            // Engine Notice Text
            Text("Notice:\nMultiPing now uses a bundled fping engine for bulk ICMP probing. If the engine is unavailable, the test will stop and show repair guidance instead of falling back to legacy ping.")
                .font(.footnote).fontWeight(.bold).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal).padding(.bottom, 5)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Target Input Area Label
            Text("Enter Targets (Each target on a separate line; notes optional)").font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $manager.ipInput).frame(maxWidth: .infinity, maxHeight: .infinity).border(Color.gray.opacity(0.5), width: 1)
                if manager.ipInput.isEmpty { Text(placeholderText).foregroundColor(.secondary).padding(.leading, 5).padding(.top, 8).allowsHitTesting(false) }
            }.padding(.horizontal).layoutPriority(1)

            // Bottom Row (Controls)
            HStack {
                Text("Count of Targets: \(validTargetCount)")
                    .font(.callout).foregroundColor(.secondary).padding(.trailing, 20)
                Text("                           Monitoring layout:").font(.callout).padding(.trailing, 10)
                Picker("", selection: $selectedViewMode) {
                    ForEach(ResultsViewMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }.pickerStyle(.segmented).frame(maxWidth: 200)
                Spacer()
                Button("Start ping") { prepareAndStartPing() }
                    .buttonStyle(.borderedProminent).disabled(validTargetCount == 0)
            }.padding(.horizontal).padding(.bottom)

        }
        .padding(.top).frame(minWidth: 500, minHeight: 380)
        .onChange(of: validTargetCount) { _ in interval = String(suggestedInterval) }
        .onChange(of: timeout) { _ in
            if validTargetCount > 0 {
                interval = String(suggestedInterval)
            }
        }
        .onAppear { interval = String(suggestedInterval) }
    }

    func validateSettings() {
        let timeoutValue = max(1, Int(timeout) ?? 2000)
        let sizeValue = max(0, Int(size) ?? 32)
        let minimumInterval = max(1, (timeoutValue / 1000) + 1)
        let intervalValue = max(minimumInterval, Int(interval) ?? minimumInterval)
        let dscpValue = min(63, max(0, Int(dscp) ?? 0))

        timeout = String(timeoutValue)
        size = String(sizeValue)
        interval = String(intervalValue)
        dscp = String(dscpValue)
    }

    func dscpDescription() -> String {
        guard let dscpValue = Int(dscp), dscpValue > 0 else {
            return "Off"
        }
        return "\(dscpValue)"
    }
    
    private func identifyTargetType(_ targetString: String) -> TargetType {
        let trimmedTarget = targetString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTarget.isEmpty { return .unknown }
        let ipv4Parts = trimmedTarget.split(separator: ".")
        if ipv4Parts.count == 4 && ipv4Parts.allSatisfy({ part in
            if let n = Int(part), String(n) == part, n >= 0 && n <= 255 { return true }
            return false
        }) {
            if ipv4Parts.joined(separator: ".").count == trimmedTarget.count {
                 return .ipv4
            }
        }
        if trimmedTarget.contains(":") {
            if !trimmedTarget.lowercased().hasPrefix("http://") &&
               !trimmedTarget.lowercased().hasPrefix("https://") &&
               trimmedTarget.components(separatedBy: "/").count == 1 &&
               trimmedTarget.components(separatedBy: "?").count == 1 &&
               trimmedTarget.components(separatedBy: "#").count == 1 {
                 let colonCount = trimmedTarget.filter { $0 == ":" }.count
                 if colonCount >= 1 && colonCount <= 7 {
                     if colonCount == 1 {
                         let parts = trimmedTarget.split(separator: ":")
                         if parts.count == 2, let lastPart = parts.last, Int(lastPart) != nil {
                             if parts.first?.contains(".") ?? false {
                             } else {
                                return .ipv6
                             }
                         } else {
                            return .ipv6
                         }
                     } else {
                        return .ipv6
                     }
                 }
            }
        }
        if !trimmedTarget.contains(" ") {
            return .domain
        }
        return .unknown
    }

    private func parseTargets(from input: String) -> [(value: String, note: String?, type: TargetType)] {
        return input.split { $0.isNewline }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { line -> (value: String, note: String?, type: TargetType) in
                var targetValue = line
                var noteValue: String? = nil
                if let commaRange = line.range(of: ",") {
                    targetValue = String(line[..<commaRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    noteValue = String(line[commaRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let tabRange = line.range(of: "\t") {
                    targetValue = String(line[..<tabRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    noteValue = String(line[tabRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    if let firstSpaceRange = line.range(of: " ") {
                        let potentialTarget = String(line[..<firstSpaceRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                        let potentialNote = String(line[firstSpaceRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !potentialTarget.isEmpty && !potentialNote.isEmpty {
                            targetValue = potentialTarget
                            noteValue = potentialNote
                        }
                    }
                }
                if noteValue?.isEmpty ?? true { noteValue = nil }
                if targetValue.isEmpty {
                    return (value: line, note: nil, type: identifyTargetType(line))
                }
                return (value: targetValue, note: noteValue, type: identifyTargetType(targetValue))
            }
    }

    func prepareAndStartPing() {
        validateSettings()
        let inputWindow = NSApp.keyWindow // Get a reference to the current input window
        manager.results.removeAll()
        manager.pingStarted = false // Reset pingStarted state
        let targetsWithNotes = parseTargets(from: manager.ipInput)
        guard !targetsWithNotes.isEmpty else { return }

        for targetInfo in targetsWithNotes {
            manager.results.append(PingResult(targetValue: targetInfo.value,
                                              targetType: targetInfo.type,
                                              note: targetInfo.note,
                                              responseTime: "Pending",
                                              successCount: 0, failureCount: 0,
                                              failureRate: 0.0, isSuccessful: false))
        }
        manager.startPingTasks(timeout: self.timeout, interval: self.interval, size: self.size, dscp: self.dscp)
        openResultsWindow(mode: selectedViewMode)
        inputWindow?.close() // Close the input window after starting pings
    }

    func openResultsWindow(mode: ResultsViewMode) {
        let windowTitle: String
        switch mode {
        case .list: windowTitle = "Ping Results"
        case .grid: windowTitle = "Ping Results"
        }
        let newWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 520), styleMask: [.titled, .closable, .resizable, .miniaturizable, .unifiedTitleAndToolbar], backing: .buffered, defer: false)
        newWindow.center(); newWindow.setFrameAutosaveName("Ping Results Window - \(mode.rawValue)");
        newWindow.title = windowTitle
        newWindow.identifier = NSUserInterfaceItemIdentifier("ping-results")
        newWindow.contentView = NSHostingView(rootView: PingResultsContainerView(manager: manager, timeout: timeout, interval: interval, size: size, dscp: dscpDescription(), initialMode: mode)
            .onDisappear { // Add onDisappear to the root view of the results window
                print("Results window (\(windowTitle)) disappearing. Stopping pings for this session (if active).")
                // Only stop if pings were actually running for this session.
                // The manager's global pingStatus might be "Pinging..." due to this session.
                if manager.pingStatus == "Pinging..." || manager.pingStatus == "Paused" {
                     // Check if this window closing means no other relevant windows are open.
                     // If so, the app termination will handle full cleanup.
                     // Otherwise, just stop the current tasks without clearing all results.
                    let relevantWindows = NSApp.windows.filter { win in
                        let isRelevantType = win.identifier?.rawValue == "ip-input" || win.title.starts(with: "Ping Results")
                        return isRelevantType && win.isVisible && win != newWindow // Exclude the window being closed
                    }
                    if relevantWindows.isEmpty {
                        print("This was the last relevant window, app termination will handle full cleanup.")
                        // NSApp.terminate(nil) // This might be too aggressive here, let windowShouldClose handle it.
                    } else {
                         print("Other relevant windows still open. Stopping pings for this specific results window session.")
                         manager.stopPingTasks(clearResults: false) // Stop pings but don't clear results from other potential sessions.
                    }
                }
            }
        )
        
        // MODIFIED: Explicitly set the AppDelegate as the delegate for the new results window.
        if let appDelegate = NSApp.delegate as? AppDelegate {
            print("IPInputView: Assigning AppDelegate as delegate to new results window: '\(windowTitle)'")
            newWindow.delegate = appDelegate
        } else {
            print("IPInputView: Could not find AppDelegate to assign to new results window.")
        }
        
        newWindow.makeKeyAndOrderFront(nil)
    }
}
