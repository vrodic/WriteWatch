import AppKit
import WriteWatchCore

/// The large-writes log, newest first.
final class LogPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// The table shows a recent window; the complete log stays in the store and goes to the save file.
    static let displayLimit = 2000

    private enum Column: String, CaseIterable {
        case time = "Time"
        case size = "Size"
        case app = "App"
        case process = "Issued by"
        case path = "File"

        var width: CGFloat {
            switch self {
            case .time: return 108
            case .size: return 72
            case .app: return 150
            case .process: return 120
            case .path: return 460
            }
        }
    }

    private let table = NSTableView()
    private var entries: [LogEntry] = []
    private let emptyLabel = NSTextField(labelWithString: "No large writes logged yet.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.rawValue
            tableColumn.width = column.width
            table.addTableColumn(tableColumn)
        }
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = false

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used") }

    func update(entries newEntries: [LogEntry]) {
        entries = newEntries
        emptyLabel.isHidden = !entries.isEmpty
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell-" + column.rawValue)
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.font = column == .time || column == .size
                ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 11)
            field.lineBreakMode = column == .path ? .byTruncatingMiddle : .byTruncatingTail
            field.alignment = column == .size ? .right : .left
        }
        let entry = entries[row]
        switch column {
        case .time: field.stringValue = String(entry.write.timestamp.prefix(12))
        case .size: field.stringValue = ByteFormat.string(entry.write.bytes)
        case .app: field.stringValue = entry.owner
        case .process: field.stringValue = entry.write.process
        case .path:
            field.stringValue = entry.write.path
            field.toolTip = entry.write.path
        }
        return field
    }
}

/// SSD health, read directly from the drive's NVMe SMART log.
final class HealthPane: NSView {
    var onRefresh: (() -> Void)?

    private let icon = NSImageView()
    private let verdictLabel = NSTextField(labelWithString: "Reading drive…")
    private let driveLabel = NSTextField(labelWithString: "")
    private let wearBar = LevelBarView()
    private let wearLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton(title: "Check Again", target: nil, action: nil)
    private let grid = NSGridView(numberOfColumns: 4, rows: 0)
    private let note = NSTextField(wrappingLabelWithString: "")
    private var values: [String: NSTextField] = [:]

    private static let leftRows = ["Temperature", "Available spare", "Media errors", "Error log entries", "Unsafe shutdowns"]
    private static let rightRows = ["Data written", "Data read", "Written per powered-on day", "Power-on time", "Power cycles"]

    override init(frame: NSRect) {
        super.init(frame: frame)

        icon.symbolConfiguration = .init(pointSize: 26, weight: .medium)
        verdictLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        driveLabel.font = .systemFont(ofSize: 12)
        driveLabel.textColor = .secondaryLabelColor
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refresh)

        let titles = NSStackView(views: [verdictLabel, driveLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [icon, titles, spacer, refreshButton])
        header.orientation = .horizontal
        header.spacing = 12
        header.alignment = .centerY

        wearLabel.font = .systemFont(ofSize: 12)
        wearLabel.textColor = .labelColor
        wearBar.translatesAutoresizingMaskIntoConstraints = false

        for (left, right) in zip(Self.leftRows, Self.rightRows) {
            grid.addRow(with: [makeTitle(left), makeValue(left), makeTitle(right), makeValue(right)])
        }
        grid.rowSpacing = 9
        grid.columnSpacing = 14
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 3).xPlacement = .leading
        for (index, width) in [130, 190, 180, 170].enumerated() {
            grid.column(at: index).width = CGFloat(width)
        }
        grid.setContentHuggingPriority(.required, for: .horizontal)

        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [header, wearLabel, wearBar, grid, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: header)
        stack.setCustomSpacing(18, after: wearBar)
        stack.setCustomSpacing(16, after: grid)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            wearBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used") }

    @objc private func refresh() { onRefresh?() }

    private func makeTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func makeValue(_ key: String) -> NSTextField {
        let field = NSTextField(labelWithString: "–")
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        values[key] = field
        return field
    }

    func show(error: String) {
        icon.image = NSImage(systemSymbolName: "questionmark.circle.fill", accessibilityDescription: "Unknown")
        icon.contentTintColor = .secondaryLabelColor
        verdictLabel.stringValue = "Could not read the drive"
        driveLabel.stringValue = error
        wearLabel.stringValue = ""
        wearBar.fraction = 0
        note.stringValue = ""
    }

    func show(health: SSDHealth) {
        let symbol: String
        let tint: NSColor
        let title: String
        var explanation = ""
        switch health.verdict {
        case .healthy:
            (symbol, tint, title) = ("checkmark.seal.fill", Theme.good, "Healthy")
        case .warning(let message):
            (symbol, tint, title) = ("exclamationmark.triangle.fill", Theme.warning, "Wearing out")
            explanation = message
        case .critical(let message):
            (symbol, tint, title) = ("xmark.octagon.fill", Theme.critical, "Failing: back up now")
            explanation = message
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        icon.contentTintColor = tint
        verdictLabel.stringValue = title

        var drive = [health.model]
        if health.capacityBytes > 0 { drive.append(ByteFormat.string(Double(health.capacityBytes))) }
        if !health.firmware.isEmpty { drive.append("firmware \(health.firmware)") }
        driveLabel.stringValue = drive.joined(separator: "  ·  ")

        wearBar.fraction = CGFloat(health.percentageUsed) / 100
        wearBar.fill = health.percentageUsed >= 90 ? Theme.warning : Theme.series
        wearLabel.stringValue = "Rated endurance used: \(health.percentageUsed)%"

        values["Temperature"]?.stringValue = "\(health.temperatureCelsius) °C"
        values["Available spare"]?.stringValue = "\(health.availableSpare)%  (minimum \(health.availableSpareThreshold)%)"
        values["Media errors"]?.stringValue = "\(health.mediaErrors)"
        values["Error log entries"]?.stringValue = "\(health.errorLogEntries)"
        values["Unsafe shutdowns"]?.stringValue = "\(health.unsafeShutdowns)"
        values["Data written"]?.stringValue = ByteFormat.string(health.bytesWritten)
        values["Data read"]?.stringValue = ByteFormat.string(health.bytesRead)
        values["Written per powered-on day"]?.stringValue = health.averageBytesWrittenPerDay.map { ByteFormat.string($0) } ?? "–"
        values["Power-on time"]?.stringValue = Self.powerOnText(hours: health.powerOnHours)
        values["Power cycles"]?.stringValue = "\(health.powerCycles)"

        var lines = [String]()
        if !explanation.isEmpty { lines.append(explanation) }
        if let endurance = health.estimatedEnduranceBytes {
            lines.append("At this wear level, the drive might reach roughly \(ByteFormat.string(endurance)) of writes in total (rough estimate).")
        }
        lines.append("Read directly from the drive's NVMe SMART log, without smartctl. The drive reports wear and power-on time itself, and how it counts them varies by manufacturer. Time asleep may not count as powered on, so the per-day figure can run well above real daily use.")
        note.stringValue = lines.joined(separator: "\n")
    }

    private static func powerOnText(hours: UInt64) -> String {
        hours >= 48 ? "\(hours) h  (\(hours / 24) days)" : "\(hours) h"
    }
}
