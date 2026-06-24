import SwiftUI
import Combine // Needed for ObservableObject

// --- GridPingResultsView (Main View) ---
struct GridPingResultsView: View {
    // MARK: - Properties
    @ObservedObject var manager: PingManager
    var timeout: String
    var interval: String
    var size: String
    var dscp: String
    @Binding var viewMode: ResultsViewMode
    @Binding var filterText: String

    // MARK: - Sorting Enum (Unchanged)
    enum GridSortCriteria: String, CaseIterable, Identifiable {
        case targetValue = "Target"
        case successCount = "Success Count"
        case failureCount = "Failure Count"
        var id: String { self.rawValue }
    }

    // MARK: - UI State
    @State private var gridScale: CGFloat = 1.0
    private let minScale: CGFloat = 0.7
    private let maxScale: CGFloat = 1.5
    private let scaleStep: CGFloat = 0.1
    private var cellSpacing: CGFloat { 10 * gridScale }

    // MARK: - Sorting State (Unchanged)
    @State private var gridSortColumn: GridSortCriteria? = nil
    @State private var gridSortAscending: Bool = true

    // MARK: - Computed Properties
    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 170 * gridScale), spacing: cellSpacing)]
    }

    var sortedGridResults: [PingResult] { // Unchanged
        let resultsToSort = filter(results: manager.results, by: filterText)
        guard let sortColumn = gridSortColumn else { return resultsToSort }
        return resultsToSort.sorted { result1, result2 in
            let comparisonResult: Bool
            switch sortColumn {
            case .targetValue:
                comparisonResult = compareTargets(result1.targetValue, result1.targetType, result2.targetValue, result2.targetType)
            case .successCount:
                comparisonResult = result1.successCount < result2.successCount
            case .failureCount:
                comparisonResult = result1.failureCount < result2.failureCount
            }
            return gridSortAscending ? comparisonResult : !comparisonResult
        }
    }

    private var dscpStatusValue: String {
        guard let dscpValue = Int(dscp), dscpValue > 0 else { return "Off" }
        return dscp
    }

    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            ResultsFilterBar(filterText: $filterText, shownCount: sortedGridResults.count, totalCount: manager.results.count)

            ScrollView {
                if manager.results.isEmpty {
                    Text("No targets to display.")
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else if sortedGridResults.isEmpty {
                    Text("No targets match the current filter.")
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: cellSpacing) {
                        ForEach(sortedGridResults) { result in
                            GridCellView(result: result, scale: gridScale)
                        }
                    }
                    .padding(cellSpacing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let engineError = manager.engineErrorMessage {
                Text(engineError)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.08))
            }

            // Status Bar Area (Unchanged)
            HStack(spacing: 15) {
                StatusTextView(label: "Timeout:", value: "\(timeout) ms")
                StatusTextView(label: "Interval:", value: "\(interval) s")
                StatusTextView(label: "Size:", value: "\(size) B")
                StatusTextView(label: "DSCP:", value: dscpStatusValue)
                StatusTextView(label: "Status:", value: manager.pingStatus, color: .blue, weight: .bold)
                Spacer()
                StatusTextView(label: "Reachable:", value: "\(manager.reachableCount)", color: ResultStatusPalette.green, weight: .bold)
                StatusTextView(label: "Failed:", value: "\(manager.failedCount)", color: ResultStatusPalette.red, weight: .bold)
            }
            .font(.callout).padding(.horizontal, 12).padding(.vertical, 5).background(.bar)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                let isEffectivelyRunning = manager.pingStatus == "Pinging..." || manager.pingStatus == "Paused"

                Button {
                    if isEffectivelyRunning {
                        manager.stopPingTasks(clearResults: true)
                    } else {
                        manager.startPingTasks(timeout: timeout, interval: interval, size: size, dscp: dscp)
                    }
                } label: {
                    Label(isEffectivelyRunning ? "Stop & Clear" : "Start Ping",
                          systemImage: isEffectivelyRunning ? "stop.circle.fill" : "play.circle.fill")
                }
                .help(isEffectivelyRunning ? "Stop & Clear" : "Start Ping")
                .tint(isEffectivelyRunning ? ResultStatusPalette.red : ResultStatusPalette.green)

                Button {
                    manager.togglePause()
                } label: {
                    Label(manager.isPaused ? "Resume" : "Pause",
                          systemImage: manager.isPaused ? "play.circle.fill" : "pause.circle.fill")
                }
                .help(manager.isPaused ? "Resume" : "Pause")
                .tint(ResultStatusPalette.orange)
                .disabled(!(manager.pingStatus == "Pinging..." || manager.pingStatus == "Paused"))

                Button {
                    viewMode = .list
                } label: {
                    Label("List Layout", systemImage: "list.bullet")
                }
                .help("Switch to List Layout")

                Menu {
                    ForEach(PingResultsExportType.allCases) { type in
                        Button(type.menuTitle) {
                            PingResultsExporter.export(sortedGridResults, as: type)
                        }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .help("Export Ping Results")
                .disabled(manager.results.isEmpty)

                Menu {
                    Button("Default Order") { gridSortColumn = nil }
                    Divider()
                    ForEach(GridSortCriteria.allCases) { criteria in
                        Button(criteria.rawValue) {
                            if gridSortColumn == criteria {
                                gridSortAscending.toggle()
                            } else {
                                gridSortColumn = criteria
                                switch criteria {
                                case .targetValue: gridSortAscending = true
                                case .successCount, .failureCount: gridSortAscending = false
                                }
                            }
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down.circle")
                }
                .help("Sort Grid Results")

                Button {
                    gridScale = max(minScale, gridScale - scaleStep)
                } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .help("Zoom Out")
                .disabled(gridScale <= minScale)

                Button {
                    gridScale = min(maxScale, gridScale + scaleStep)
                } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .help("Zoom In")
                .disabled(gridScale >= maxScale)
            }
        }
        .labelStyle(.iconOnly)
    }

    // MARK: - Nested GridCellView (UPDATED for notes)
    internal struct GridCellView: View {
        @ObservedObject var result: PingResult
        let scale: CGFloat
        private let baseTargetFontSizeIPv4: CGFloat = 13
        private let baseTargetFontSizeOther: CGFloat = 11
        private let baseNoteFontSize: CGFloat = 10 // New
        private let baseTimeFontSize: CGFloat = 10
        private let baseCountFontSize: CGFloat = 12
        private var cellHeight: CGFloat { 108 * scale }

        internal init(result: PingResult, scale: CGFloat) {
            self.result = result
            self.scale = scale
        }

        private var backgroundColor: Color {
            if ResultStatusPalette.isInactive(result.responseTime) {
                return ResultStatusPalette.orange.opacity(0.14)
            }
            return result.isSuccessful ? ResultStatusPalette.green.opacity(0.14) : ResultStatusPalette.red.opacity(0.14)
        }
        private var successColor: Color { ResultStatusPalette.green }
        private var failureColor: Color { ResultStatusPalette.red }

        private var targetDisplayNameFontSize: CGFloat {
            switch result.targetType {
            case .ipv4: return baseTargetFontSizeIPv4 * scale
            case .ipv6, .domain, .unknown: return baseTargetFontSizeOther * scale
            }
        }

        internal var body: some View {
            VStack(alignment: .leading, spacing: 4 * scale) {
                Text(result.displayName)
                    .font(.system(size: targetDisplayNameFontSize, weight: .medium, design: .monospaced))
                    .foregroundColor(ResultStatusPalette.swiftColor(for: result))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, (result.note != nil ? 0 : 2) * scale) // Adjust padding if note exists

                if let note = result.note, !note.isEmpty { // Display note if present [cite: 5]
                    Text(note)
                        .font(.system(size: baseNoteFontSize * scale, design: .monospaced))
                        .foregroundColor(ResultStatusPalette.swiftColor(for: result).opacity(0.82))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 2 * scale)
                }

                Text(result.responseTime)
                    .font(.system(size: baseTimeFontSize * scale, design: .monospaced))
                    .foregroundColor(ResultStatusPalette.swiftColor(for: result))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                HStack {
                    HStack(spacing: 2 * scale) { Image(systemName: "checkmark.circle").foregroundColor(successColor); Text("\(result.successCount)").fontWeight(.bold).foregroundColor(successColor) }
                        .font(.system(size: baseCountFontSize * scale))
                    Spacer()
                    HStack(spacing: 2 * scale) { Image(systemName: "xmark.circle").foregroundColor(failureColor); Text("\(result.failureCount)").fontWeight(.bold).foregroundColor(failureColor) }
                        .font(.system(size: baseCountFontSize * scale))
                }
            }
            .padding(8 * scale).background(backgroundColor).cornerRadius(6 * scale)
            .frame(height: cellHeight, alignment: .top).clipShape(RoundedRectangle(cornerRadius: 6 * scale))
        }
    }

    // Helper View for Status Text (Unchanged)
    struct StatusTextView: View {
        let label: String, value: String; var color: Color? = nil; var weight: Font.Weight = .regular
        var body: some View { Text(label + " ") + Text(value).fontWeight(weight).foregroundColor(color) }
    }
}

// MARK: - Extension for Sorting Helpers (Unchanged)
extension GridPingResultsView {
    private func compareTargets(_ t1Val: String, _ t1Type: TargetType, _ t2Val: String, _ t2Type: TargetType) -> Bool {
        if t1Type == .ipv4 && t2Type == .ipv4 { return compareIPAddresses(t1Val, t2Val) }
        return t1Val.localizedStandardCompare(t2Val) == .orderedAscending
    }
    private func compareIPAddresses(_ ip1: String, _ ip2: String) -> Bool {
        let p1 = ip1.split(separator: ".").compactMap { UInt32($0) }, p2 = ip2.split(separator: ".").compactMap { UInt32($0) }
        guard p1.count == 4, p2.count == 4 else { return ip1.localizedStandardCompare(ip2) == .orderedAscending }
        for i in 0..<4 { if p1[i] != p2[i] { return p1[i] < p2[i] } }; return false
    }
}
