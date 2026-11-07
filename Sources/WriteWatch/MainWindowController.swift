import AppKit
import UniformTypeIdentifiers
import WriteWatchCore

final class MainWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    private enum Access {
        case none
        case requesting
        case granted
    }

    private enum ToolbarItem {
        static let capture = NSToolbarItem.Identifier("capture")
        static let threshold = NSToolbarItem.Identifier("threshold")
        static let access = NSToolbarItem.Identifier("access")
        static let clear = NSToolbarItem.Identifier("clear")
        static let save = NSToolbarItem.Identifier("save")
    }

    private static let thresholds: [(String, Int)] = [
        ("Log writes ≥ 4 KB", 4 * 1024),
        ("Log writes ≥ 64 KB", 64 * 1024),
        ("Log writes ≥ 256 KB", 256 * 1024),
        ("Log writes ≥ 1 MB", 1024 * 1024),
        ("Log writes ≥ 16 MB", 16 * 1024 * 1024),
    ]

    private let store = CaptureStore()
    private let counters = DiskCounters()
    private let sampler = ProcessSampler()

    private var helper: HelperConnection?
    private var access = Access.none
    private var isCapturing = false
    private var lastDiagnostic: String?
    private var traceRestarts = 0

    private var timer: Timer?
    private var lastCounter: UInt64?
    private var lastTick = Date()
    private var peakRate = 0.0
    private var captureDiskBytes: UInt64 = 0
    private var captureSeconds = 0.0
    private var savedAtTracedBytes = 0
    private var healthAge = 0

    private let rateTile = TileView(title: "Writing now")
    private let peakTile = TileView(title: "Peak this capture")
    private let captureTile = TileView(title: "Written this capture")
    private let bootTile = TileView(title: "Written since boot")
    private let ownTile = TileView(title: "WriteWatch's own disk writes")

    private let chart = RateChartView()
    private let appsList = BarListView()
    private let filesList = BarListView()
    private let logPane = LogPane()
    private let healthPane = HealthPane()
    private let writersPane = NSStackView()
    private let segments = NSSegmentedControl(
        labels: ["Top Writers", "Large Writes", "SSD Health"], trackingMode: .selectOne, target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    private let captureButton = NSButton(title: "", target: nil, action: nil)
    private let accessButton = NSButton(title: "", target: nil, action: nil)
    private let thresholdPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let clearButton = NSButton(title: "", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save…", target: nil, action: nil)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "WriteWatch"
        window.minSize = NSSize(width: 860, height: 640)
        // Saving window state would write to disk, so the window never restores or remembers its frame.
        window.isRestorable = false
        window.center()
        self.init(window: window)
        window.delegate = self
        buildToolbar(window)
        buildContent(window)
        startTimer()
        readHealth()
        updateControls()
    }

    /// Asks for root on launch, then begins capturing either way.
    func beginInitialCapture() {
        startCapture()
    }

    // MARK: - Layout

    private func buildToolbar(_ window: NSWindow) {
        let toolbar = NSToolbar(identifier: "WriteWatchToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        for button in [captureButton, accessButton, clearButton, saveButton] {
            button.bezelStyle = .texturedRounded
            button.target = self
        }
        captureButton.action = #selector(toggleCapture)
        captureButton.imagePosition = .imageLeading
        accessButton.action = #selector(grantAccess)
        accessButton.imagePosition = .imageLeading
        clearButton.action = #selector(clearCapture)
        clearButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Clear capture")
        clearButton.toolTip = "Clear this capture from memory"
        saveButton.action = #selector(saveCapture)
        saveButton.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
        saveButton.imagePosition = .imageLeading
        saveButton.toolTip = "Save this capture to a file you choose"

        thresholdPopup.addItems(withTitles: Self.thresholds.map(\.0))
        thresholdPopup.selectItem(at: 1)
        thresholdPopup.target = self
        thresholdPopup.action = #selector(thresholdChanged)
        thresholdPopup.toolTip = "Writes at least this big go in the Large Writes log. All writes count toward the rankings."
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarItem.capture, ToolbarItem.threshold, .flexibleSpace, ToolbarItem.access, ToolbarItem.clear, ToolbarItem.save]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case ToolbarItem.capture: item.view = captureButton; item.label = "Capture"
        case ToolbarItem.threshold: item.view = thresholdPopup; item.label = "Log threshold"
        case ToolbarItem.access: item.view = accessButton; item.label = "Access"
        case ToolbarItem.clear: item.view = clearButton; item.label = "Clear"
        case ToolbarItem.save: item.view = saveButton; item.label = "Save"
        default: return nil
        }
        return item
    }

    private func buildContent(_ window: NSWindow) {
        let root = BackgroundView()
        window.contentView = root

        let tiles = NSStackView(views: [rateTile, peakTile, captureTile, bootTile, ownTile])
        tiles.orientation = .horizontal
        tiles.distribution = .fillEqually
        tiles.spacing = 10

        appsList.title = "Apps writing the most"
        filesList.title = "Files written the most"
        writersPane.orientation = .horizontal
        writersPane.distribution = .fillEqually
        writersPane.spacing = 28
        writersPane.addArrangedSubview(appsList)
        writersPane.addArrangedSubview(filesList)

        segments.selectedSegment = 0
        segments.target = self
        segments.action = #selector(paneChanged)

        let panes = NSView()
        for pane in [writersPane, logPane, healthPane] as [NSView] {
            pane.translatesAutoresizingMaskIntoConstraints = false
            panes.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: panes.topAnchor),
                pane.bottomAnchor.constraint(equalTo: panes.bottomAnchor),
                pane.leadingAnchor.constraint(equalTo: panes.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: panes.trailingAnchor),
            ])
        }
        logPane.isHidden = true
        healthPane.isHidden = true
        healthPane.onRefresh = { [weak self] in self?.readHealth() }

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [tiles, chart, segments, panes, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        let guide = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            tiles.widthAnchor.constraint(equalTo: stack.widthAnchor),
            chart.widthAnchor.constraint(equalTo: stack.widthAnchor),
            chart.heightAnchor.constraint(equalToConstant: 170),
            panes.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        panes.setContentHuggingPriority(.init(1), for: .vertical)
        panes.setContentCompressionResistancePriority(.init(1), for: .vertical)
        chart.setContentHuggingPriority(.required, for: .vertical)
    }

    private final class BackgroundView: NSView {
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() { layer?.backgroundColor = Theme.surface.cgColor }
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Not used") }
    }

    // MARK: - Live updates

    private func startTimer() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        lastCounter = counters.bytesWritten()
        tick()
    }

    private func tick() {
        let now = Date()
        let elapsed = max(now.timeIntervalSince(lastTick), 0.001)
        lastTick = now

        var rate = 0.0
        let total = counters.bytesWritten()
        if let total, let previous = lastCounter, total >= previous {
            let delta = total - previous
            rate = Double(delta) / elapsed
            if isCapturing {
                captureDiskBytes += delta
                captureSeconds += elapsed
                peakRate = max(peakRate, rate)
            }
        }
        lastCounter = total
        chart.append(rate)

        if isCapturing, access != .granted {
            sampler.sample { [store] name, bytes in store.addProcessBytes(name: name, bytes: bytes) }
        }

        rateTile.update(value: ByteFormat.string(rate) + "/s", caption: "internal SSD")
        peakTile.update(value: ByteFormat.string(peakRate) + "/s", caption: isCapturing ? "capturing" : "not capturing")
        captureTile.update(value: ByteFormat.string(Double(captureDiskBytes)), caption: Self.durationText(captureSeconds))
        bootTile.update(value: total.map { ByteFormat.string(Double($0)) } ?? "–", caption: Self.perDayText(total))
        let own = OwnUsage.read()
        refreshCaptureViews(memory: own.memoryBytes)
        let ownBytes = Double(own.diskBytesWritten) + Double(store.snapshot(top: 0).ownFlushedBytes)
        ownTile.update(value: ByteFormat.string(ownBytes), caption: "\(ByteFormat.string(Double(own.memoryBytes))) of RAM")

        healthAge += 1
        if healthAge >= 60 { readHealth() }
    }

    private func refreshCaptureViews(memory: UInt64) {
        let snapshot = store.snapshot(top: 15)

        appsList.update(
            rows: snapshot.apps.map {
                BarListView.Row(
                    title: $0.name, detail: "", bytes: $0.bytes,
                    tooltip: "\($0.name)\n\(ByteFormat.string($0.bytes)) in \($0.writes) writes")
            })
        filesList.update(
            rows: snapshot.files.map {
                let name = ($0.path as NSString).lastPathComponent
                return BarListView.Row(
                    title: name, detail: $0.owner, bytes: $0.bytes,
                    tooltip: "\($0.path)\n\($0.owner): \(ByteFormat.string($0.bytes)) in \($0.writes) writes")
            })
        appsList.emptyMessage = isCapturing ? "Waiting for writes…" : "Start a capture to rank apps by writes."
        filesList.emptyMessage = access == .granted || access == .requesting
            ? (isCapturing ? "Waiting for writes…" : "Start a capture to rank files by writes.")
            : "File names need administrator access.\nClick Grant Access in the toolbar."

        if !logPane.isHidden {
            logPane.update(entries: store.recentLog(limit: LogPane.displayLimit))
        }

        var parts = ["In memory only: \(snapshot.logCount) large writes logged"]
        if snapshot.droppedLogEntries > 0 { parts.append("\(snapshot.droppedLogEntries) oldest dropped") }
        if snapshot.flushedBytes > 0 {
            parts.append("launchd flushed \(ByteFormat.string(snapshot.flushedBytes)) (credited to apps where known)")
        }
        if traceRestarts > 0 {
            let times = traceRestarts == 1 ? "once" : "\(traceRestarts) times"
            parts.append("trace restarted \(times) to limit its memory, missing a moment of writes each time")
        }
        if let lastDiagnostic { parts.append(lastDiagnostic) }
        statusLabel.stringValue = parts.joined(separator: "  ·  ")
        saveButton.isEnabled = snapshot.tracedBytes > 0 || snapshot.logCount > 0
        clearButton.isEnabled = saveButton.isEnabled
    }

    private static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds)
        if total >= 3600 { return "over \(total / 3600) h \(total % 3600 / 60) min" }
        if total >= 60 { return "over \(total / 60) min \(total % 60) s" }
        return "over \(total) s"
    }

    private static func perDayText(_ total: UInt64?) -> String {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard let total, uptime >= 3600 else { return "" }
        return "about \(ByteFormat.string(Double(total) / uptime * 86400)) a day"
    }

    private func readHealth() {
        healthAge = 0
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = SMARTReader.read()
            DispatchQueue.main.async {
                switch result {
                case .success(let health): self?.healthPane.show(health: health)
                case .failure(let failure): self?.healthPane.show(error: failure.message)
                }
            }
        }
    }

    // MARK: - Capture and permission

    @objc private func toggleCapture() {
        if isCapturing { stopCapture() } else { startCapture() }
    }

    private func startCapture() {
        lastDiagnostic = nil
        if access == .granted {
            beginTrace()
        } else if access == .none {
            requestAccess(thenStartCapture: true)
        }
    }

    private func beginTrace() {
        markCaptureStart()
        helper?.startTrace()
        updateControls()
    }

    private func beginLimitedCapture() {
        markCaptureStart()
        sampler.sample({ _, _ in }, isBaseline: true)
        updateControls()
    }

    /// Starts the capture's clock and byte count from now. The permission prompt blocks the main
    /// thread, and that time must not be counted as part of the capture.
    private func markCaptureStart() {
        isCapturing = true
        lastTick = Date()
        lastCounter = counters.bytesWritten()
    }

    func stopCapture() {
        isCapturing = false
        if access == .granted { helper?.stopTrace() }
        updateControls()
    }

    @objc private func grantAccess() {
        requestAccess(thenStartCapture: isCapturing)
    }

    private func requestAccess(thenStartCapture: Bool) {
        guard access == .none else { return }
        guard let path = Bundle.main.url(forAuxiliaryExecutable: "WriteWatchHelper")?.path else {
            lastDiagnostic = "The helper is missing from the app bundle."
            if thenStartCapture { beginLimitedCapture() }
            return
        }

        access = .requesting
        updateControls()

        let connection = HelperConnection()
        connection.onWrite = { [store] write in store.ingest(write) }
        connection.onDiagnostic = { [weak self] text in self?.handleDiagnostic(text) }
        connection.onConnected = { [weak self] in
            guard let self else { return }
            self.access = .granted
            self.lastDiagnostic = nil
            if thenStartCapture { self.beginTrace() }
            else if self.isCapturing { self.helper?.startTrace() }
            self.updateControls()
        }
        connection.onDisconnected = { [weak self] in
            guard let self else { return }
            self.helper = nil
            self.access = .none
            if self.isCapturing {
                self.lastDiagnostic = "The trace helper stopped."
                self.beginLimitedCapture()
            }
            self.updateControls()
        }

        guard connection.listen() else {
            access = .none
            lastDiagnostic = "Could not open a loopback connection for the helper."
            if thenStartCapture { beginLimitedCapture() }
            updateControls()
            return
        }
        helper = connection

        // Lets the window finish drawing before the prompt blocks the main thread.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var memoryLimitMB: Int?
            #if DEBUG
            memoryLimitMB = ProcessInfo.processInfo.environment["WW_MEMORY_LIMIT_MB"].flatMap { Int($0) }
            #endif
            switch connection.launchHelper(executable: path, memoryLimitMB: memoryLimitMB) {
            case .launched:
                // If the helper never connects, fall back rather than waiting forever.
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in
                    guard let self, let connection, self.helper === connection, self.access == .requesting else { return }
                    self.abandonRequest(connection, message: "The helper did not connect.", startLimited: thenStartCapture)
                }
            case .cancelled:
                self.abandonRequest(connection, message: nil, startLimited: thenStartCapture)
            case .failed(let message):
                self.abandonRequest(connection, message: message, startLimited: thenStartCapture)
            }
        }
    }

    private func abandonRequest(_ connection: HelperConnection, message: String?, startLimited: Bool) {
        connection.onDisconnected = nil
        connection.disconnect()
        helper = nil
        access = .none
        lastDiagnostic = message
        if startLimited { beginLimitedCapture() }
        updateControls()
    }

    private func handleDiagnostic(_ text: String) {
        if text == "#restarted" {
            traceRestarts += 1
        } else if text == "#stopped" {
            lastDiagnostic = lastDiagnostic ?? "The trace stopped unexpectedly."
            isCapturing = false
        } else if text.hasPrefix("#error ") {
            lastDiagnostic = String(text.dropFirst(7))
            isCapturing = false
        } else if text.lowercased().contains("fs_usage") || text.lowercased().contains("ktrace") {
            lastDiagnostic = text
        }
        updateControls()
    }

    private func updateControls() {
        let symbol = isCapturing ? "stop.circle.fill" : "record.circle"
        captureButton.title = isCapturing ? "Stop Capture" : "Start Capture"
        captureButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        captureButton.contentTintColor = isCapturing ? Theme.critical : nil
        captureButton.isEnabled = access != .requesting

        switch access {
        case .granted:
            accessButton.title = "Full Access"
            accessButton.image = NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: nil)
            accessButton.contentTintColor = Theme.good
            accessButton.isEnabled = false
            accessButton.toolTip = "Tracing every process through the root helper, until WriteWatch quits."
        case .requesting:
            accessButton.title = "Requesting…"
            accessButton.image = NSImage(systemSymbolName: "shield", accessibilityDescription: nil)
            accessButton.contentTintColor = nil
            accessButton.isEnabled = false
            accessButton.toolTip = nil
        case .none:
            accessButton.title = "Grant Access…"
            accessButton.image = NSImage(systemSymbolName: "exclamationmark.shield.fill", accessibilityDescription: nil)
            accessButton.contentTintColor = Theme.warning
            accessButton.isEnabled = true
            accessButton.toolTip = "Without administrator access, only your own processes are visible and files are not named."
        }
        let own = OwnUsage.read()
        refreshCaptureViews(memory: own.memoryBytes)
    }

    @objc private func thresholdChanged() {
        store.setThreshold(Self.thresholds[thresholdPopup.indexOfSelectedItem].1)
    }

    @objc private func paneChanged() {
        let selected = segments.selectedSegment
        writersPane.isHidden = selected != 0
        logPane.isHidden = selected != 1
        healthPane.isHidden = selected != 2
        if selected == 1 { logPane.update(entries: store.recentLog(limit: LogPane.displayLimit)) }
    }

    // MARK: - Save, clear, quit

    private var hasUnsavedData: Bool {
        let traced = store.snapshot(top: 0).tracedBytes
        return traced > 0 && traced != savedAtTracedBytes
    }

    /// Writes only here, to the file the user picks in the save panel.
    @objc func saveCapture() {
        guard let window else { return }
        let panel = NSSavePanel()
        let stamp = Self.fileStamp()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "WriteWatch-log-\(stamp).csv"
        panel.message = "Save this capture. WriteWatch writes nothing to disk except this file."

        let contents = NSPopUpButton(frame: .zero, pullsDown: false)
        contents.addItems(withTitles: ["Large-writes log", "App and file totals"])
        let label = NSTextField(labelWithString: "Contents:")
        let accessory = NSStackView(views: [label, contents])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = accessory
        contents.target = self
        contents.action = #selector(saveContentsChanged(_:))
        activeSavePanel = panel
        activeSaveStamp = stamp

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.activeSavePanel = nil
            guard response == .OK, let url = panel.url else { return }
            let data = contents.indexOfSelectedItem == 0 ? self.store.logCSV() : self.store.totalsCSV()
            do {
                try data.write(to: url, options: .atomic)
                self.savedAtTracedBytes = self.store.snapshot(top: 0).tracedBytes
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    private var activeSavePanel: NSSavePanel?
    private var activeSaveStamp = ""

    @objc private func saveContentsChanged(_ sender: NSPopUpButton) {
        let kind = sender.indexOfSelectedItem == 0 ? "log" : "totals"
        activeSavePanel?.nameFieldStringValue = "WriteWatch-\(kind)-\(activeSaveStamp).csv"
    }

    private static func fileStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }

    @objc private func clearCapture() {
        guard let window else { return }
        guard hasUnsavedData else {
            resetCapture()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Clear this capture?"
        alert.informativeText = "It hasn't been saved, and it exists only in memory."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.resetCapture() }
        }
    }

    private func resetCapture() {
        store.reset()
        savedAtTracedBytes = 0
        traceRestarts = 0
        captureDiskBytes = 0
        captureSeconds = 0
        peakRate = 0
        logPane.update(entries: [])
        updateControls()
    }

    /// Returns true when it's fine to quit. The user may be asked first if data would be lost.
    func confirmQuit() -> Bool {
        guard hasUnsavedData else { return true }
        let alert = NSAlert()
        alert.messageText = "Quit without saving this capture?"
        alert.informativeText = "It exists only in memory and will be lost."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Quit Without Saving")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveCapture()
            return false
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func shutDown() {
        timer?.invalidate()
        helper?.onDisconnected = nil
        helper?.disconnect()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    #if DEBUG
    /// Development aid: feeds a recorded fs_usage text file through the real pipeline.
    func loadReplay(path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        access = .granted
        for line in text.split(separator: "\n") {
            if let write = FSUsageParser.parse(String(line)) { store.ingest(write) }
        }
        peakRate = 1_200_000
        captureDiskBytes = 152_092_672
        captureSeconds = 300
        for i in 0..<120 { chart.append(Double(abs((i * 37) % 11 == 0 ? 900_000 : (i * 13) % 180_000))) }
        updateControls()
    }

    func selectPaneForDebug(_ index: Int) {
        segments.selectedSegment = index
        paneChanged()
    }

    func writeWindowSnapshot(to path: String) {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #endif
}
