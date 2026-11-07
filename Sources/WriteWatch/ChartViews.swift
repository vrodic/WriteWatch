import AppKit
import WriteWatchCore

enum Theme {
    private static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha)
    }

    private static func dynamic(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light)
        }
    }

    static let surface = dynamic("wwSurface", light: 0xfcfcfb, dark: 0x1a1a19)
    static let panel = dynamic("wwPanel", light: 0xf4f3f0, dark: 0x262624)
    static let series = dynamic("wwSeries", light: 0x2a78d6, dark: 0x3987e5)
    static let good = color(0x0ca30c)
    static let warning = color(0xfab219)
    static let critical = color(0xd03b3b)
}

/// Rolling write rate: one series, one axis, newest sample at the right edge.
final class RateChartView: NSView {
    private let capacity = 120
    private var samples: [Double] = []
    private var hoverX: CGFloat?

    override var isFlipped: Bool { true }

    func append(_ bytesPerSecond: Double) {
        samples.append(bytesPerSecond)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hoverX = convert(event.locationInWindow, from: nil).x
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverX = nil
        needsDisplay = true
    }

    private func niceMaximum(_ value: Double) -> Double {
        let floorValue = max(value, 100_000)  // Keeps a quiet disk from looking busy.
        let magnitude = pow(10, floor(log10(floorValue)))
        for step in [1.0, 2.0, 5.0, 10.0] where step * magnitude >= floorValue {
            return step * magnitude
        }
        return 10 * magnitude
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = NSRect(x: 58, y: 28, width: max(bounds.width - 72, 10), height: max(bounds.height - 50, 10))
        drawText("Write rate, internal SSD", at: NSPoint(x: 0, y: 0), font: .systemFont(ofSize: 12, weight: .semibold), color: .labelColor)

        let maximum = niceMaximum(samples.max() ?? 0)
        let gridFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

        for tick in 0...2 {
            let fraction = CGFloat(tick) / 2
            let y = plot.maxY - fraction * plot.height
            NSColor.separatorColor.setFill()
            NSRect(x: plot.minX, y: y, width: plot.width, height: 0.5).fill()
            let label = ByteFormat.string(maximum * Double(fraction)) + "/s"
            let size = (label as NSString).size(withAttributes: [.font: gridFont])
            drawText(label, at: NSPoint(x: plot.minX - size.width - 8, y: y - size.height / 2), font: gridFont, color: .tertiaryLabelColor)
        }

        for (seconds, label) in [(capacity, "2 min ago"), (capacity / 2, "1 min ago"), (0, "now")] {
            let x = plot.maxX - CGFloat(seconds) / CGFloat(capacity - 1) * plot.width
            let size = (label as NSString).size(withAttributes: [.font: gridFont])
            let origin = min(max(plot.minX, x - size.width / 2), plot.maxX - size.width)
            drawText(label, at: NSPoint(x: origin, y: plot.maxY + 5), font: gridFont, color: .tertiaryLabelColor)
        }

        guard !samples.isEmpty else { return }

        func point(_ index: Int) -> NSPoint {
            let age = samples.count - 1 - index
            let x = plot.maxX - CGFloat(age) / CGFloat(capacity - 1) * plot.width
            let y = plot.maxY - CGFloat(samples[index] / maximum) * plot.height
            return NSPoint(x: x, y: y)
        }

        let line = NSBezierPath()
        line.lineWidth = 2
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        line.move(to: point(0))
        for index in 1..<max(samples.count, 1) { line.line(to: point(index)) }

        if samples.count > 1, let area = line.copy() as? NSBezierPath {
            area.line(to: NSPoint(x: plot.maxX, y: plot.maxY))
            area.line(to: NSPoint(x: point(0).x, y: plot.maxY))
            area.close()
            Theme.series.withAlphaComponent(0.13).setFill()
            area.fill()
        }
        Theme.series.setStroke()
        line.stroke()

        let last = point(samples.count - 1)
        NSColor.clear.setFill()
        Theme.surface.setFill()
        NSBezierPath(ovalIn: NSRect(x: last.x - 6, y: last.y - 6, width: 12, height: 12)).fill()
        Theme.series.setFill()
        NSBezierPath(ovalIn: NSRect(x: last.x - 4, y: last.y - 4, width: 8, height: 8)).fill()

        if let hoverX, plot.contains(NSPoint(x: hoverX, y: plot.midY)) {
            drawHover(atX: hoverX, plot: plot, point: point)
        }
    }

    private func drawHover(atX x: CGFloat, plot: NSRect, point: (Int) -> NSPoint) {
        let age = Int(((plot.maxX - x) / plot.width * CGFloat(capacity - 1)).rounded())
        let index = samples.count - 1 - age
        guard samples.indices.contains(index) else { return }
        let marker = point(index)

        NSColor.tertiaryLabelColor.setFill()
        NSRect(x: marker.x, y: plot.minY, width: 1, height: plot.height).fill()
        Theme.surface.setFill()
        NSBezierPath(ovalIn: NSRect(x: marker.x - 6, y: marker.y - 6, width: 12, height: 12)).fill()
        Theme.series.setFill()
        NSBezierPath(ovalIn: NSRect(x: marker.x - 4, y: marker.y - 4, width: 8, height: 8)).fill()

        let when = age == 0 ? "now" : "\(age) s ago"
        let label = "\(ByteFormat.string(samples[index]))/s  ·  \(when)"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let size = (label as NSString).size(withAttributes: [.font: font])
        var box = NSRect(x: marker.x + 10, y: plot.minY + 2, width: size.width + 16, height: size.height + 8)
        if box.maxX > plot.maxX { box.origin.x = marker.x - box.width - 10 }
        Theme.panel.setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).stroke()
        drawText(label, at: NSPoint(x: box.minX + 8, y: box.minY + 4), font: font, color: .labelColor)
    }

    private func drawText(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }
}

/// A ranked list drawn as thin horizontal bars sharing one scale.
final class BarListView: NSView {
    struct Row {
        let title: String
        let detail: String
        let bytes: Int
        let tooltip: String
    }

    var title = "" { didSet { needsDisplay = true } }
    var emptyMessage = "" { didSet { needsDisplay = true } }
    private var rows: [Row] = []
    private var hoverIndex: Int?

    private let headerHeight: CGFloat = 26
    private let rowHeight: CGFloat = 36

    override var isFlipped: Bool { true }

    func update(rows: [Row]) {
        self.rows = rows
        updateHover()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self))
    }

    private var pointer: NSPoint?

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        updateHover()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        updateHover()
        needsDisplay = true
    }

    private func updateHover() {
        guard let pointer, pointer.y >= headerHeight else {
            hoverIndex = nil
            toolTip = nil
            return
        }
        let index = Int((pointer.y - headerHeight) / rowHeight)
        hoverIndex = rows.indices.contains(index) && index < visibleRowCount ? index : nil
        toolTip = hoverIndex.map { rows[$0].tooltip }
    }

    private var visibleRowCount: Int {
        min(rows.count, max(0, Int((bounds.height - headerHeight) / rowHeight)))
    }

    override func draw(_ dirtyRect: NSRect) {
        (title as NSString).draw(
            at: .zero,
            withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor])

        guard !rows.isEmpty else {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            (emptyMessage as NSString).draw(
                in: bounds.insetBy(dx: 24, dy: 0).offsetBy(dx: 0, dy: bounds.height / 2 - 10),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: style,
                ])
            return
        }

        let maximum = max(rows.map(\.bytes).max() ?? 1, 1)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.lineBreakMode = .byTruncatingMiddle

        for index in 0..<visibleRowCount {
            let row = rows[index]
            let top = headerHeight + CGFloat(index) * rowHeight
            let rect = NSRect(x: 0, y: top, width: bounds.width, height: rowHeight)

            if index == hoverIndex {
                Theme.panel.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: -6, dy: 1), xRadius: 5, yRadius: 5).fill()
            }

            let value = ByteFormat.string(row.bytes)
            let valueSize = (value as NSString).size(withAttributes: [.font: valueFont])
            (value as NSString).draw(
                at: NSPoint(x: bounds.width - valueSize.width, y: top + 4),
                withAttributes: [.font: valueFont, .foregroundColor: NSColor.secondaryLabelColor])

            let text = NSMutableAttributedString(
                string: row.title,
                attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: titleStyle])
            if !row.detail.isEmpty {
                text.append(
                    NSAttributedString(
                        string: "   " + row.detail,
                        attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: titleStyle]))
            }
            text.draw(
                with: NSRect(x: 0, y: top + 3, width: bounds.width - valueSize.width - 12, height: 17),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

            let width = max(4, CGFloat(row.bytes) / CGFloat(maximum) * bounds.width)
            Theme.series.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: top + 22, width: width, height: 6), xRadius: 3, yRadius: 3).fill()
        }
    }
}

/// A stat tile: small label, large value, quiet caption.
final class TileView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "–")
    private let caption = NSTextField(labelWithString: "")

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10

        label.stringValue = title
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        value.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        value.textColor = .labelColor
        value.lineBreakMode = .byClipping
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [label, value, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used") }

    override func updateLayer() {
        layer?.backgroundColor = Theme.panel.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    func update(value newValue: String, caption newCaption: String) {
        value.stringValue = newValue
        caption.stringValue = newCaption
    }
}

/// A slim level meter for a percentage.
final class LevelBarView: NSView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    var fill: NSColor = Theme.series { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 8) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        guard fraction > 0 else { return }
        fill.setFill()
        let width = max(8, bounds.width * min(fraction, 1))
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height), xRadius: 4, yRadius: 4).fill()
    }
}
