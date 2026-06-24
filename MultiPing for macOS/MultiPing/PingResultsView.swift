import AppKit
import Combine
import SwiftUI

enum ResultStatusPalette {
    static let green = Color(red: 0.24, green: 0.56, blue: 0.38)
    static let red = Color(red: 0.72, green: 0.28, blue: 0.24)
    static let orange = Color(red: 0.72, green: 0.50, blue: 0.22)

    static let nsGreen = NSColor(calibratedRed: 0.24, green: 0.56, blue: 0.38, alpha: 1.0)
    static let nsRed = NSColor(calibratedRed: 0.72, green: 0.28, blue: 0.24, alpha: 1.0)
    static let nsOrange = NSColor(calibratedRed: 0.72, green: 0.50, blue: 0.22, alpha: 1.0)

    static func isInactive(_ responseTime: String) -> Bool {
        ["pending", "pinging...", "paused", "stopped", "cleared", "cancelled", "engine unavailable", "restarting engine..."].contains(responseTime.lowercased())
    }

    static func swiftColor(for result: PingResult) -> Color {
        isInactive(result.responseTime) ? orange : (result.isSuccessful ? green : red)
    }

    static func nsColor(for result: PingResult) -> NSColor {
        isInactive(result.responseTime) ? nsOrange : (result.isSuccessful ? nsGreen : nsRed)
    }
}

struct PingResultsContainerView: View {
    @ObservedObject var manager: PingManager
    let timeout: String
    let interval: String
    let size: String
    let dscp: String
    @State private var viewMode: ResultsViewMode
    @State private var filterText: String = ""

    init(manager: PingManager, timeout: String, interval: String, size: String, dscp: String, initialMode: ResultsViewMode) {
        self.manager = manager
        self.timeout = timeout
        self.interval = interval
        self.size = size
        self.dscp = dscp
        self._viewMode = State(initialValue: initialMode)
    }

    var body: some View {
        if viewMode == .list {
            PingResultsView(manager: manager, timeout: timeout, interval: interval, size: size, dscp: dscp, viewMode: $viewMode, filterText: $filterText)
        } else {
            GridPingResultsView(manager: manager, timeout: timeout, interval: interval, size: size, dscp: dscp, viewMode: $viewMode, filterText: $filterText)
        }
    }
}

// List View - Refactored to use PingManager for logic
struct PingResultsView: View {
    // MARK: - Properties
    @ObservedObject var manager: PingManager
    var timeout: String
    var interval: String
    var size: String
    var dscp: String
    @Binding var viewMode: ResultsViewMode
    @Binding var filterText: String

    // MARK: - UI State
    @State private var sortColumn: SortColumn? = nil
    @State private var sortAscending: Bool = true
    @State private var listScale: CGFloat = 1.0
    private let minScale: CGFloat = 0.7
    private let maxScale: CGFloat = 1.5
    private let scaleStep: CGFloat = 0.1

    // MARK: - Sorting Enum
    enum SortColumn: String, CaseIterable, Equatable {
        case targetValue = "Target"
        case current = "Current"
        case average = "Average"
        case minimum = "Minimum"
        case maximum = "Maximum"
        case success = "Success"
        case failures = "Failures"
        case failRate = "Fail Rate"

        var tableKey: String {
            switch self {
            case .targetValue: return "target"
            case .current: return "current"
            case .average: return "average"
            case .minimum: return "minimum"
            case .maximum: return "maximum"
            case .success: return "success"
            case .failures: return "failures"
            case .failRate: return "failRate"
            }
        }

        init?(tableKey: String) {
            switch tableKey {
            case "target": self = .targetValue
            case "current": self = .current
            case "average": self = .average
            case "minimum": self = .minimum
            case "maximum": self = .maximum
            case "success": self = .success
            case "failures": self = .failures
            case "failRate": self = .failRate
            default: return nil
            }
        }
    }

    // MARK: - Computed Sorted Results
    var sortedResults: [PingResult] {
        sort(results: filteredResults, by: sortColumn, ascending: sortAscending)
    }

    private var filteredResults: [PingResult] {
        filter(results: manager.results, by: filterText)
    }

    private var dscpStatusValue: String {
        guard let dscpValue = Int(dscp), dscpValue > 0 else { return "Off" }
        return dscp
    }

    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            ResultsFilterBar(filterText: $filterText, shownCount: sortedResults.count, totalCount: manager.results.count)

            if manager.results.isEmpty {
                Spacer()
                Text("No targets to display.")
                    .foregroundColor(.gray)
                Spacer()
            } else if sortedResults.isEmpty {
                Spacer()
                Text("No targets match the current filter.")
                    .foregroundColor(.gray)
                Spacer()
            } else {
                ListResultsTableView(
                    results: sortedResults,
                    sortColumn: $sortColumn,
                    sortAscending: $sortAscending,
                    scale: listScale
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

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
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.bar)
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
                    viewMode = .grid
                } label: {
                    Label("Grid Layout", systemImage: "square.grid.2x2")
                }
                .help("Switch to Grid Layout")

                Menu {
                    ForEach(PingResultsExportType.allCases) { type in
                        Button(type.menuTitle) {
                            PingResultsExporter.export(sortedResults, as: type)
                        }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .help("Export Ping Results")
                .disabled(manager.results.isEmpty)

                Button {
                    listScale = max(minScale, listScale - scaleStep)
                } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .help("Zoom Out")
                .disabled(listScale <= minScale)

                Button {
                    listScale = min(maxScale, listScale + scaleStep)
                } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .help("Zoom In")
                .disabled(listScale >= maxScale)
            }
        }
        .labelStyle(.iconOnly)
    }

    struct StatusTextView: View {
        let label: String
        let value: String
        var color: Color? = nil
        var weight: Font.Weight = .regular

        var body: some View {
            Text(label + " ") + Text(value).fontWeight(weight).foregroundColor(color)
        }
    }
}

struct ResultsFilterBar: View {
    @Binding var filterText: String
    let shownCount: Int
    let totalCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundColor(.secondary)
            TextField("Filter targets, notes, or status", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220)
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Clear Filter")
            }
            Spacer()
            Text("\(shownCount)/\(totalCount)")
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Native List Table
private struct ListResultsTableView: NSViewRepresentable {
    let results: [PingResult]
    @Binding var sortColumn: PingResultsView.SortColumn?
    @Binding var sortAscending: Bool
    let scale: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let tableView = NSTableView()

        tableView.identifier = NSUserInterfaceItemIdentifier("PingResultsListTable")
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = true
        tableView.allowsMultipleSelection = false
        tableView.selectionHighlightStyle = .none
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.autosaveName = "PingResultsListTableColumnsV3"
        tableView.autosaveTableColumns = true
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator

        for column in context.coordinator.orderedColumnDefinitions() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column.minWidth
            tableColumn.maxWidth = column.maxWidth
            if let sortColumn = column.sortColumn {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                    key: sortColumn.tableKey,
                    ascending: sortColumn == .targetValue
                )
            }
            tableView.addTableColumn(tableColumn)
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        context.coordinator.tableView = tableView
        context.coordinator.reload(from: self)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.reload(from: self)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        struct ColumnDefinition {
            let id: String
            let title: String
            let width: CGFloat
            let minWidth: CGFloat
            let maxWidth: CGFloat
            let alignment: NSTextAlignment
            let sortColumn: PingResultsView.SortColumn?
        }

        var parent: ListResultsTableView
        var results: [PingResult]
        weak var tableView: NSTableView?
        private var cancellables: [AnyCancellable] = []
        private var subscribedIDs: [UUID] = []
        private let columnOrderDefaultsKey = "PingResultsListTableColumnOrderV3"

        let columnDefinitions: [ColumnDefinition] = [
            ColumnDefinition(id: "target", title: "Target", width: 190, minWidth: 120, maxWidth: 500, alignment: .left, sortColumn: .targetValue),
            ColumnDefinition(id: "note", title: "Note", width: 170, minWidth: 80, maxWidth: 500, alignment: .left, sortColumn: nil),
            ColumnDefinition(id: "success", title: "Success", width: 76, minWidth: 62, maxWidth: 120, alignment: .right, sortColumn: .success),
            ColumnDefinition(id: "failures", title: "Failures", width: 78, minWidth: 64, maxWidth: 120, alignment: .right, sortColumn: .failures),
            ColumnDefinition(id: "failRate", title: "Fail Rate", width: 82, minWidth: 68, maxWidth: 130, alignment: .right, sortColumn: .failRate),
            ColumnDefinition(id: "current", title: "Current", width: 95, minWidth: 76, maxWidth: 160, alignment: .right, sortColumn: .current),
            ColumnDefinition(id: "average", title: "Average", width: 95, minWidth: 76, maxWidth: 160, alignment: .right, sortColumn: .average),
            ColumnDefinition(id: "minimum", title: "Minimum", width: 95, minWidth: 76, maxWidth: 160, alignment: .right, sortColumn: .minimum),
            ColumnDefinition(id: "maximum", title: "Maximum", width: 95, minWidth: 76, maxWidth: 160, alignment: .right, sortColumn: .maximum)
        ]

        init(parent: ListResultsTableView) {
            self.parent = parent
            self.results = parent.results
            super.init()
        }

        func reload(from parent: ListResultsTableView) {
            self.parent = parent
            self.results = parent.results
            syncSubscriptions()

            guard let tableView = tableView else { return }
            tableView.rowHeight = max(22, 24 * parent.scale)
            applySortDescriptors(to: tableView)
            tableView.reloadData()
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            sortedResults.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < sortedResults.count, let tableColumn = tableColumn else { return nil }

            let columnID = tableColumn.identifier.rawValue
            let reuseID = NSUserInterfaceItemIdentifier("cell-\(columnID)")
            let cell = (tableView.makeView(withIdentifier: reuseID, owner: self) as? NSTableCellView) ?? makeCell(identifier: reuseID)
            guard let textField = cell.textField else { return cell }

            let result = sortedResults[row]
            configure(textField: textField, columnID: columnID, result: result)
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key,
                  let column = PingResultsView.SortColumn(tableKey: key) else {
                parent.sortColumn = nil
                tableView.reloadData()
                return
            }

            parent.sortColumn = column
            parent.sortAscending = descriptor.ascending
            tableView.reloadData()
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            saveColumnOrder()
        }

        func orderedColumnDefinitions() -> [ColumnDefinition] {
            let definitionsByID = Dictionary(uniqueKeysWithValues: columnDefinitions.map { ($0.id, $0) })
            let defaultIDs = columnDefinitions.map(\.id)

            guard let savedIDs = UserDefaults.standard.array(forKey: columnOrderDefaultsKey) as? [String] else {
                return columnDefinitions
            }

            let validSavedIDs = savedIDs.filter { definitionsByID[$0] != nil }
            guard Set(validSavedIDs) == Set(defaultIDs), validSavedIDs.count == defaultIDs.count else {
                return columnDefinitions
            }

            return validSavedIDs.compactMap { definitionsByID[$0] }
        }

        private var sortedResults: [PingResult] {
            sort(results: results, by: parent.sortColumn, ascending: parent.sortAscending)
        }

        private func syncSubscriptions() {
            let ids = results.map(\.id)
            guard ids != subscribedIDs else { return }

            subscribedIDs = ids
            cancellables = results.map { result in
                result.objectWillChange
                    .receive(on: RunLoop.main)
                    .sink { [weak self] _ in
                        self?.tableView?.reloadData()
                    }
            }
        }

        private func applySortDescriptors(to tableView: NSTableView) {
            guard let sortColumn = parent.sortColumn else {
                if !tableView.sortDescriptors.isEmpty {
                    tableView.sortDescriptors = []
                }
                return
            }

            let descriptors = [NSSortDescriptor(key: sortColumn.tableKey, ascending: parent.sortAscending)]
            if tableView.sortDescriptors != descriptors {
                tableView.sortDescriptors = descriptors
            }
        }

        private func saveColumnOrder() {
            guard let tableView = tableView else { return }
            let orderedIDs = tableView.tableColumns.map { $0.identifier.rawValue }
            UserDefaults.standard.set(orderedIDs, forKey: columnOrderDefaultsKey)
        }

        private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            cell.textField = textField
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])

            return cell
        }

        private func configure(textField: NSTextField, columnID: String, result: PingResult) {
            let baseFontSize = max(9, 12 * parent.scale)
            textField.font = NSFont.monospacedSystemFont(ofSize: baseFontSize, weight: .regular)
            textField.alignment = columnDefinitions.first(where: { $0.id == columnID })?.alignment ?? .left
            textField.textColor = ResultStatusPalette.nsColor(for: result)

            switch columnID {
            case "target":
                textField.stringValue = result.displayName
            case "note":
                textField.stringValue = result.note ?? ""
            case "current":
                textField.stringValue = result.currentLatencyMs.map { PingResult.formatLatency(milliseconds: $0) } ?? result.responseTime
            case "average":
                textField.stringValue = PingResult.latencyDisplay(result.averageLatencyMs)
            case "minimum":
                textField.stringValue = PingResult.latencyDisplay(result.minimumLatencyMs)
            case "maximum":
                textField.stringValue = PingResult.latencyDisplay(result.maximumLatencyMs)
            case "success":
                textField.stringValue = "\(result.successCount)"
            case "failures":
                textField.stringValue = "\(result.failureCount)"
            case "failRate":
                textField.stringValue = String(format: "%.1f%%", result.failureRate)
            default:
                textField.stringValue = ""
            }
        }
    }
}

// MARK: - Sorting Helpers
func filter(results: [PingResult], by filterText: String) -> [PingResult] {
    let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return results }

    return results.filter { result in
        result.displayName.lowercased().contains(query) ||
        (result.note?.lowercased().contains(query) ?? false) ||
        result.responseTime.lowercased().contains(query) ||
        result.targetType.rawValue.lowercased().contains(query)
    }
}

private func sort(
    results: [PingResult],
    by sortColumn: PingResultsView.SortColumn?,
    ascending: Bool
) -> [PingResult] {
    guard let sortColumn = sortColumn else { return results }

    return results.sorted { result1, result2 in
        let comparisonResult: Bool
        switch sortColumn {
        case .targetValue:
            comparisonResult = compareTargets(result1.targetValue, result1.targetType, result2.targetValue, result2.targetType)
        case .current:
            comparisonResult = compareLatency(result1.currentLatencyMs, result2.currentLatencyMs)
        case .average:
            comparisonResult = compareLatency(result1.averageLatencyMs, result2.averageLatencyMs)
        case .minimum:
            comparisonResult = compareLatency(result1.minimumLatencyMs, result2.minimumLatencyMs)
        case .maximum:
            comparisonResult = compareLatency(result1.maximumLatencyMs, result2.maximumLatencyMs)
        case .success:
            comparisonResult = result1.successCount < result2.successCount
        case .failures:
            comparisonResult = result1.failureCount < result2.failureCount
        case .failRate:
            comparisonResult = result1.failureRate < result2.failureRate
        }
        return ascending ? comparisonResult : !comparisonResult
    }
}

private func compareLatency(_ latency1: Double?, _ latency2: Double?) -> Bool {
    (latency1 ?? Double.infinity) < (latency2 ?? Double.infinity)
}

private func compareTargets(_ t1Val: String, _ t1Type: TargetType, _ t2Val: String, _ t2Type: TargetType) -> Bool {
    if t1Type == .ipv4 && t2Type == .ipv4 {
        return compareIPAddresses(t1Val, t2Val)
    }
    return t1Val.localizedStandardCompare(t2Val) == .orderedAscending
}

private func compareIPAddresses(_ ip1: String, _ ip2: String) -> Bool {
    let p1 = ip1.split(separator: ".").compactMap { UInt32($0) }
    let p2 = ip2.split(separator: ".").compactMap { UInt32($0) }
    guard p1.count == 4, p2.count == 4 else {
        return ip1.localizedStandardCompare(ip2) == .orderedAscending
    }
    for i in 0..<4 {
        if p1[i] != p2[i] { return p1[i] < p2[i] }
    }
    return false
}
