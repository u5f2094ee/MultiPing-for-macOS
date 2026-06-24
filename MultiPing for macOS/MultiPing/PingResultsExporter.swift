import AppKit
import Foundation
import UniformTypeIdentifiers

enum PingResultsExportType: String, CaseIterable, Identifiable {
    case excel
    case csv
    case html

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .excel: return "Excel (.xls)"
        case .csv: return "CSV (.csv)"
        case .html: return "HTML (.html)"
        }
    }

    var fileExtension: String {
        switch self {
        case .excel: return "xls"
        case .csv: return "csv"
        case .html: return "html"
        }
    }

    var contentType: UTType {
        switch self {
        case .excel: return UTType(filenameExtension: "xls") ?? .data
        case .csv: return .commaSeparatedText
        case .html: return .html
        }
    }
}

enum PingResultsExporter {
    static func export(_ results: [PingResult], as type: PingResultsExportType) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [type.contentType]
        panel.nameFieldStringValue = defaultFileName(for: type)

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            do {
                let data = exportData(for: results, type: type)
                try data.write(to: url, options: .atomic)
            } catch {
                showExportError(error)
            }
        }
    }

    private static func defaultFileName(for type: PingResultsExportType) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "MultiPing Results \(formatter.string(from: Date())).\(type.fileExtension)"
    }

    private static func exportData(for results: [PingResult], type: PingResultsExportType) -> Data {
        switch type {
        case .csv:
            return Data(("\u{FEFF}" + csvString(for: results)).utf8)
        case .html, .excel:
            return Data(htmlString(for: results, excelCompatible: type == .excel).utf8)
        }
    }

    private static func csvString(for results: [PingResult]) -> String {
        let rows = exportRows(for: results).map { row in
            row.map(csvEscape).joined(separator: ",")
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func htmlString(for results: [PingResult], excelCompatible: Bool) -> String {
        let rows = exportRows(for: results)
        let header = rows.first ?? []
        let bodyRows = rows.dropFirst()
            .map { row in
                "<tr>" + row.map { "<td>\(htmlEscape($0))</td>" }.joined() + "</tr>"
            }
            .joined(separator: "\n")

        let excelMeta = excelCompatible ? "<meta name=\"ProgId\" content=\"Excel.Sheet\">" : ""
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        \(excelMeta)
        <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #999; padding: 4px 8px; text-align: left; }
        th { background: #efefef; }
        td.number, th.number { text-align: right; }
        </style>
        </head>
        <body>
        <table>
        <thead><tr>\(header.map { "<th>\(htmlEscape($0))</th>" }.joined())</tr></thead>
        <tbody>
        \(bodyRows)
        </tbody>
        </table>
        </body>
        </html>
        """
    }

    private static func exportRows(for results: [PingResult]) -> [[String]] {
        let header = [
            "Target",
            "Type",
            "Note",
            "Current",
            "Average",
            "Minimum",
            "Maximum",
            "Success",
            "Failures",
            "Fail Rate",
            "Status"
        ]

        let dataRows = results.map { result in
            [
                result.targetValue,
                result.targetType.rawValue,
                result.note ?? "",
                result.currentLatencyMs.map { PingResult.formatLatency(milliseconds: $0) } ?? result.responseTime,
                PingResult.latencyDisplay(result.averageLatencyMs),
                PingResult.latencyDisplay(result.minimumLatencyMs),
                PingResult.latencyDisplay(result.maximumLatencyMs),
                "\(result.successCount)",
                "\(result.failureCount)",
                String(format: "%.1f%%", result.failureRate),
                result.responseTime
            ]
        }

        return [header] + dataRows
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    private static func htmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func showExportError(_ error: Error) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Export Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}
