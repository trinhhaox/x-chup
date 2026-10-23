import AppKit
import Foundation
import Vision
import ImageIO
import Carbon

// MARK: - Entry Point

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.count < 2 {
            runTray()
            return
        }

        let cmd = args[1]
        switch cmd {
        case "tray", "app":
            runTray()
        case "overlay":
            runOverlay()
        case "card":
            guard args.count >= 3 else {
                fputs("Error: card requires an image file path\n", stderr)
                exit(1)
            }
            runCard(imagePath: args[2])
        case "pin":
            guard args.count >= 3 else {
                fputs("Error: pin requires an image file path\n", stderr)
                exit(1)
            }
            runPin(imagePath: args[2])
        case "ocr":
            guard args.count >= 3 else {
                fputs("Error: ocr requires an image file path\n", stderr)
                exit(1)
            }
            runOCR(imagePath: args[2])
        default:
            printUsage()
            exit(1)
        }
    }

    func printUsage() {
        fputs("Usage: snip-ui <tray | overlay | card <image-path> | pin <image-path> | ocr <image-path>>\n", stderr)
    }

    func runTray() {
        NSApp.setActivationPolicy(.accessory)
        TrayController.shared.show()
    }

    func runOverlay() {
        NSApp.setActivationPolicy(.accessory)
        OverlayController.shared.show()
    }

    func runCard(imagePath: String) {
        NSApp.setActivationPolicy(.accessory)
        QuickAccessController.shared.show(imagePath: imagePath)
    }

    func runPin(imagePath: String) {
        NSApp.setActivationPolicy(.accessory)
        PinController.shared.show(imagePath: imagePath)
    }

    func runOCR(imagePath: String) {
        let text = OCRController.shared.recognize(imagePath: imagePath)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        print(text)
        exit(0)
    }
}

// MARK: - Selection Overlay

final class OverlayController {
    static let shared = OverlayController()
    private var windows: [NSWindow] = []

    func show() {
        windows = NSScreen.screens.map { screen in
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true

            let overlayView = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), screenFrame: screen.frame)
            window.contentView = overlayView
            window.makeKeyAndOrderFront(nil)
            return window
        }
    }

    func finish(rect: NSRect?) {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()

        if let r = rect, r.width > 2 && r.height > 2 {
            let json: [String: Any] = [
                "x": Int(r.origin.x),
                "y": Int(r.origin.y),
                "w": Int(r.width),
                "h": Int(r.height)
            ]
            if let data = try? JSONSerialization.data(withJSONObject: json),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            exit(0)
        } else {
            fputs("Cancelled\n", stderr)
            exit(1)
        }
    }
}

final class OverlayView: NSView {
    private let screenFrame: NSRect
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var isDragging = false

    init(frame: NSRect, screenFrame: NSRect) {
        self.screenFrame = screenFrame
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            OverlayController.shared.finish(rect: nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        isDragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging, let start = startPoint, let current = currentPoint else { return }
        isDragging = false

        let x = min(start.x, current.x)
        let y = min(start.y, current.y)
        let w = abs(current.x - start.x)
        let h = abs(current.y - start.y)

        // Convert AppKit (bottom-left) to display coordinate (top-left)
        let topY = screenFrame.height - (y + h)
        let finalRect = NSRect(x: screenFrame.origin.x + x, y: screenFrame.origin.y + topY, width: w, height: h)

        OverlayController.shared.finish(rect: finalRect)
    }

    override func mouseMoved(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Dim background
        ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.25).cgColor)
        ctx.fill(bounds)

        // Selection rectangle
        if let start = startPoint, let curr = currentPoint, isDragging {
            let x = min(start.x, curr.x)
            let y = min(start.y, curr.y)
            let w = abs(curr.x - start.x)
            let h = abs(curr.y - start.y)
            let selRect = NSRect(x: x, y: y, width: w, height: h)

            // Clear selected area to reveal screen underneath
            ctx.setBlendMode(.clear)
            ctx.fill(selRect)
            ctx.setBlendMode(.normal)

            // White border
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(selRect)

            // Size badge
            let sizeText = "\(Int(w)) × \(Int(h))"
            drawPillBadge(text: sizeText, at: NSPoint(x: selRect.midX, y: max(selRect.minY - 26, 10)))
        } else if let curr = currentPoint {
            // Draw crosshairs
            ctx.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.6).cgColor)
            ctx.setLineWidth(1.0)
            ctx.strokeLineSegments(between: [
                CGPoint(x: curr.x, y: 0), CGPoint(x: curr.x, y: bounds.height),
                CGPoint(x: 0, y: curr.y), CGPoint(x: bounds.width, y: curr.y)
            ])
        }
    }

    private func drawPillBadge(text: String, at center: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let pillRect = NSRect(
            x: center.x - (textSize.width + 16) / 2,
            y: center.y,
            width: textSize.width + 16,
            height: 20
        )

        let path = NSBezierPath(roundedRect: pillRect, xRadius: 10, yRadius: 10)
        NSColor(calibratedWhite: 0.1, alpha: 0.85).setFill()
        path.fill()

        (text as NSString).draw(
            at: NSPoint(x: pillRect.origin.x + 8, y: pillRect.origin.y + (20 - textSize.height) / 2),
            withAttributes: attrs
        )
    }
}

// MARK: - Quick Access Card (QAO)

final class QuickAccessController: NSObject {
    static let shared = QuickAccessController()
    private var window: NSWindow?
    private var imagePath: String = ""

    func show(imagePath: String) {
        self.imagePath = imagePath
        guard let screen = NSScreen.main, let image = NSImage(contentsOfFile: imagePath) else {
            exit(1)
        }

        let maxCardW: CGFloat = 260
        let maxCardH: CGFloat = 160
        let imgSize = image.size
        let aspect = imgSize.width / max(imgSize.height, 1)

        var cardW = maxCardW
        var cardH = cardW / aspect
        if cardH > maxCardH {
            cardH = maxCardH
            cardW = cardH * aspect
        }

        let totalW = max(cardW, 140) + 16
        let totalH = cardH + 48

        let margin: CGFloat = 20
        let originX = screen.visibleFrame.maxX - totalW - margin
        let originY = screen.visibleFrame.minY + margin

        let win = NSWindow(
            contentRect: NSRect(x: originX, y: originY, width: totalW, height: totalH),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .floating
        win.hasShadow = true

        let cardView = CardView(frame: NSRect(x: 0, y: 0, width: totalW, height: totalH), image: image, filePath: imagePath)
        win.contentView = cardView
        win.makeKeyAndOrderFront(nil)
        self.window = win

        // Auto dismiss after 6 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            self?.dismiss()
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            self.window?.animator().alphaValue = 0.0
        }, completionHandler: {
            self.window?.orderOut(nil)
            exit(0)
        })
    }
}

final class CardView: NSView, NSDraggingSource {
    private let image: NSImage
    private let filePath: String

    init(frame: NSRect, image: NSImage, filePath: String) {
        self.image = image
        self.filePath = filePath
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Glass background card
        let bgPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 12, yRadius: 12)
        NSColor(calibratedWhite: 0.15, alpha: 0.90).setFill()
        bgPath.fill()
        NSColor(calibratedWhite: 0.35, alpha: 0.50).setStroke()
        bgPath.lineWidth = 1.0
        bgPath.stroke()

        // Draw image thumbnail
        let imgRect = NSRect(x: 10, y: 38, width: bounds.width - 20, height: bounds.height - 48)
        let imgPath = NSBezierPath(roundedRect: imgRect, xRadius: 8, yRadius: 8)
        imgPath.addClip()
        image.draw(in: imgRect, from: .zero, operation: .sourceOver, fraction: 1.0)

        // Actions bar at bottom
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.8, alpha: 1.0)
        ]
        let info = "✓ Copied to Clipboard"
        (info as NSString).draw(at: NSPoint(x: 14, y: 12), withAttributes: titleAttrs)
    }

    override func mouseDown(with event: NSEvent) {
        // Support Drag & Drop of the file out of the card
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(URL(fileURLWithPath: filePath).absoluteString, forType: .fileURL)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: image)

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .copy
    }
}

// MARK: - Pin Window

final class PinController: NSObject {
    static let shared = PinController()
    private var window: NSWindow?

    func show(imagePath: String) {
        guard let screen = NSScreen.main, let image = NSImage(contentsOfFile: imagePath) else {
            exit(1)
        }

        let initialW = min(image.size.width / 2, 600)
        let initialH = initialW / (image.size.width / max(image.size.height, 1))

        let win = NSWindow(
            contentRect: NSRect(
                x: screen.frame.midX - initialW / 2,
                y: screen.frame.midY - initialH / 2,
                width: initialW,
                height: initialH
            ),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .floating
        win.hasShadow = true
        win.isMovableByWindowBackground = true

        let pinView = PinView(frame: NSRect(origin: .zero, size: CGSize(width: initialW, height: initialH)), image: image)
        win.contentView = pinView
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }
}

final class PinView: NSView {
    private let image: NSImage

    init(frame: NSRect, image: NSImage) {
        self.image = image
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        path.addClip()
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    override func scrollWheel(with event: NSEvent) {
        // Adjust opacity on scroll wheel (PIN-04)
        guard let win = window else { return }
        let delta = event.scrollingDeltaY * 0.01
        var newAlpha = win.alphaValue + delta
        newAlpha = max(0.15, min(1.0, newAlpha))
        win.alphaValue = newAlpha
    }

    override func rightMouseDown(with event: NSEvent) {
        // Right click to close
        window?.orderOut(nil)
        exit(0)
    }
}

// MARK: - OCR & QR Code Detection

final class OCRController {
    static let shared = OCRController()

    func recognize(imagePath: String) -> String {
        let url = URL(fileURLWithPath: imagePath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return ""
        }
        return recognize(cgImage: cgImage)
    }

    func recognize(cgImage: CGImage) -> String {
        var recognizedLines: [String] = []

        let textRequest = VNRecognizeTextRequest { request, error in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            for obs in observations {
                if let candidate = obs.topCandidates(1).first {
                    recognizedLines.append(candidate.string)
                }
            }
        }
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true

        var barcodeStrings: [String] = []
        let barcodeRequest = VNDetectBarcodesRequest { request, error in
            guard let observations = request.results as? [VNBarcodeObservation] else { return }
            for obs in observations {
                if let payload = obs.payloadStringValue {
                    barcodeStrings.append(payload)
                }
            }
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([barcodeRequest, textRequest])

        if !barcodeStrings.isEmpty {
            let qrText = barcodeStrings.joined(separator: "\n")
            if !recognizedLines.isEmpty {
                return qrText + "\n" + recognizedLines.joined(separator: "\n")
            }
            return qrText
        }

        return recognizedLines.joined(separator: "\n")
    }
}

// MARK: - Global HotKeys (Carbon API)

final class HotKeyManager {
    static let shared = HotKeyManager()
    private var handlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []

    enum Action: UInt32 {
        case area = 1
        case fullscreen = 2
        case ocr = 3
        case pin = 4
        case record = 5
    }

    var onHotKey: ((Action) -> Void)?

    func setup() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, event, userData in
            guard let event = event, let userData = userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if status == noErr {
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                if let action = Action(rawValue: hotKeyID.id) {
                    DispatchQueue.main.async {
                        manager.onHotKey?(action)
                    }
                }
            }
            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, selfPtr, &handlerRef)

        registerKeys()
    }

    private func registerKey(keyCode: Int, modifiers: UInt32, id: Action) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: 0x534E4950, id: id.rawValue)
        let err = RegisterEventHotKey(UInt32(keyCode), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if err == noErr, let r = ref {
            hotKeyRefs.append(r)
        }
    }

    private func registerKeys() {
        let cmdShift = UInt32(cmdKey | shiftKey)
        let ctrlShift = UInt32(controlKey | shiftKey)

        // 3: Fullscreen
        registerKey(keyCode: kVK_ANSI_3, modifiers: cmdShift, id: .fullscreen)
        registerKey(keyCode: kVK_ANSI_3, modifiers: ctrlShift, id: .fullscreen)

        // 4: Area Capture
        registerKey(keyCode: kVK_ANSI_4, modifiers: cmdShift, id: .area)
        registerKey(keyCode: kVK_ANSI_4, modifiers: ctrlShift, id: .area)

        // 5: Pin
        registerKey(keyCode: kVK_ANSI_5, modifiers: cmdShift, id: .pin)
        registerKey(keyCode: kVK_ANSI_5, modifiers: ctrlShift, id: .pin)

        // 6: OCR
        registerKey(keyCode: kVK_ANSI_6, modifiers: cmdShift, id: .ocr)
        registerKey(keyCode: kVK_ANSI_6, modifiers: ctrlShift, id: .ocr)

        // 7: Record
        registerKey(keyCode: kVK_ANSI_7, modifiers: cmdShift, id: .record)
        registerKey(keyCode: kVK_ANSI_7, modifiers: ctrlShift, id: .record)
    }

    deinit {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        if let h = handlerRef {
            RemoveEventHandler(h)
        }
    }
}

// MARK: - Menu Bar Status Item (Tray Controller)

func createMenuBarIcon() -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 18))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setStrokeColor(NSColor.black.cgColor)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.setLineWidth(1.3)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    let bodyRect = CGRect(x: 1.5, y: 2.0, width: 15.0, height: 11.5)
    let bodyPath = CGPath(roundedRect: bodyRect, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
    ctx.addPath(bodyPath)
    ctx.strokePath()

    let topRect = CGRect(x: 4.5, y: 13.5, width: 4.0, height: 1.8)
    let topPath = CGPath(roundedRect: topRect, cornerWidth: 1.0, cornerHeight: 1.0, transform: nil)
    ctx.addPath(topPath)
    ctx.fillPath()

    let lensRect = CGRect(x: 6.0, y: 4.75, width: 6.0, height: 6.0)
    ctx.strokeEllipse(in: lensRect)

    img.unlockFocus()
    img.isTemplate = true
    return img
}

func ensureDaemonRunning() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-x", "snipd"]
    task.standardOutput = Pipe()
    try? task.run()
    task.waitUntilExit()
    if task.terminationStatus != 0 {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let bundle = Bundle.main.bundleURL
        let candidates = [
            bundle.appendingPathComponent("Contents/MacOS/snipd").path,
            bundle.deletingLastPathComponent().appendingPathComponent("snipd").path,
            "\(home)/.local/bin/snipd"
        ]
        if let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bin)
            try? proc.run()
        }
    }
}

func findSnipBinary() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let bundle = Bundle.main.bundleURL
    let candidates = [
        bundle.appendingPathComponent("Contents/MacOS/snip").path,
        bundle.deletingLastPathComponent().appendingPathComponent("snip").path,
        "\(home)/.local/bin/snip",
        "/usr/local/bin/snip"
    ]
    for c in candidates {
        if FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
    }
    return "snip"
}

func runSnipCommand(_ args: [String]) {
    let bin = findSnipBinary()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: bin)
    proc.arguments = args
    try? proc.run()
}

func showNotification(title: String, text: String) {
    let script = "display notification \"\(text)\" with title \"\(title)\""
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", script]
    try? task.run()
}

final class TrayController: NSObject, NSMenuDelegate {
    static let shared = TrayController()
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private let recentMenu = NSMenu()
    private var isRecording = false
    private var recordProcess: Process?

    func show() {
        ensureDaemonRunning()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }

        button.image = createMenuBarIcon()
        button.toolTip = "xChup - CleanShot X for Mac"
        button.imagePosition = .imageLeft

        buildMenu()
        statusItem?.menu = menu
        menu.delegate = self

        // Setup Global HotKeys
        HotKeyManager.shared.onHotKey = { [weak self] action in
            self?.handleHotKey(action)
        }
        HotKeyManager.shared.setup()
    }

    private func updateButtonIcon() {
        guard let button = statusItem?.button else { return }
        if isRecording {
            button.title = "🔴"
            button.image = nil
        } else {
            button.image = createMenuBarIcon()
            button.title = ""
            button.toolTip = "xChup - CleanShot X for Mac"
        }
    }

    private func buildMenu() {
        menu.removeAllItems()

        let titleItem = NSMenuItem(title: "xChup • CleanShot X", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())

        let areaItem = NSMenuItem(title: "Chụp vùng (Area)", action: #selector(actionArea), keyEquivalent: "4")
        areaItem.keyEquivalentModifierMask = [.command, .shift]
        areaItem.target = self
        menu.addItem(areaItem)

        let fullItem = NSMenuItem(title: "Chụp toàn màn hình (Fullscreen)", action: #selector(actionFullscreen), keyEquivalent: "3")
        fullItem.keyEquivalentModifierMask = [.command, .shift]
        fullItem.target = self
        menu.addItem(fullItem)

        let ocrItem = NSMenuItem(title: "Nhận diện chữ & QR (OCR)", action: #selector(actionOCR), keyEquivalent: "6")
        ocrItem.keyEquivalentModifierMask = [.command, .shift]
        ocrItem.target = self
        menu.addItem(ocrItem)

        let pinItem = NSMenuItem(title: "Ghim ảnh nổi (Pin Image)", action: #selector(actionPin), keyEquivalent: "5")
        pinItem.keyEquivalentModifierMask = [.command, .shift]
        pinItem.target = self
        menu.addItem(pinItem)

        let recordItem = NSMenuItem(
            title: isRecording ? "⏹ Dừng quay màn hình (Stop Recording)" : "🎥 Quay màn hình (Record Screen)",
            action: #selector(actionToggleRecord),
            keyEquivalent: "7"
        )
        recordItem.keyEquivalentModifierMask = [.command, .shift]
        recordItem.target = self
        menu.addItem(recordItem)

        menu.addItem(NSMenuItem.separator())

        let recentItem = NSMenuItem(title: "Ảnh gần đây (Recent)", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        let folderItem = NSMenuItem(title: "Mở thư mục lưu ảnh", action: #selector(actionOpenFolder), keyEquivalent: "")
        folderItem.target = self
        menu.addItem(folderItem)

        let cleanDesktopItem = NSMenuItem(title: "Ẩn / Hiện icon Desktop", action: #selector(actionToggleDesktop), keyEquivalent: "")
        cleanDesktopItem.target = self
        menu.addItem(cleanDesktopItem)

        menu.addItem(NSMenuItem.separator())

        let guideItem = NSMenuItem(title: "Phím tắt & Hướng dẫn", action: #selector(actionShowGuide), keyEquivalent: "")
        guideItem.target = self
        menu.addItem(guideItem)

        let quitItem = NSMenuItem(title: "Thoát xChup", action: #selector(actionQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateRecentMenu()
    }

    private func updateRecentMenu() {
        recentMenu.removeAllItems()
        let capturesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/snip/captures")

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: capturesDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else {
            let empty = NSMenuItem(title: "Chưa có ảnh chụp nào", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
            return
        }

        let sorted = files.sorted { f1, f2 in
            let d1 = (try? f1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let d2 = (try? f2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return d1 > d2
        }

        let recents = Array(sorted.prefix(8))
        if recents.isEmpty {
            let empty = NSMenuItem(title: "Chưa có ảnh chụp nào", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
            return
        }

        for file in recents {
            let name = file.lastPathComponent
            let item = NSMenuItem(title: name, action: #selector(openRecentFile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = file.path

            if let img = NSImage(contentsOf: file) {
                img.size = NSSize(width: 20, height: 20)
                item.image = img
            }
            recentMenu.addItem(item)
        }
    }

    @objc func openRecentFile(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    @objc func actionArea() {
        runSnipCommand(["area"])
    }

    @objc func actionFullscreen() {
        runSnipCommand(["fullscreen"])
    }

    @objc func actionOCR() {
        runSnipCommand(["text"])
    }

    @objc func actionPin() {
        let capturesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/snip/captures")
        if let files = try? FileManager.default.contentsOfDirectory(
            at: capturesDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) {
            let sorted = files.sorted { f1, f2 in
                let d1 = (try? f1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let d2 = (try? f2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                return d1 > d2
            }
            if let latest = sorted.first {
                runSnipCommand(["pin", latest.path])
                return
            }
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url {
            runSnipCommand(["pin", url.path])
        }
    }

    @objc func actionToggleRecord() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        let capturesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/snip/captures")
        try? FileManager.default.createDirectory(at: capturesDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let outputPath = capturesDir.appendingPathComponent("snip_rec_\(timestamp).mov").path

        isRecording = true
        updateButtonIcon()
        buildMenu()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-v", outputPath]
        self.recordProcess = task
        try? task.run()

        showNotification(
            title: "xChup - Bắt đầu quay màn hình",
            text: "Nhấp vào icon Menu Bar hoặc bấm ⌘⇧7 để dừng quay."
        )
    }

    private func stopRecording() {
        guard isRecording, let proc = recordProcess else { return }
        proc.interrupt()
        recordProcess = nil
        isRecording = false
        updateButtonIcon()
        buildMenu()

        showNotification(
            title: "xChup - Đã dừng quay màn hình",
            text: "Video đã được lưu vào thư mục captures."
        )
    }

    @objc func actionOpenFolder() {
        let capturesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/snip/captures")
        try? FileManager.default.createDirectory(at: capturesDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(capturesDir)
    }

    @objc func actionToggleDesktop() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", """
            VAL=$(defaults read com.apple.finder CreateDesktop 2>/dev/null || echo "true")
            if [ "$VAL" = "false" ]; then
                defaults write com.apple.finder CreateDesktop -bool true
            else
                defaults write com.apple.finder CreateDesktop -bool false
            fi
            killall Finder
        """]
        try? task.run()
    }

    @objc func actionShowGuide() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "xChup - CleanShot X for Mac"
        alert.informativeText = """
        Phím tắt toàn cầu (Global Shortcuts):
        • ⌘⇧4 (hoặc ⌃⇧4): Chụp vùng màn hình (Area Capture)
        • ⌘⇧3 (hoặc ⌃⇧3): Chụp toàn màn hình (Fullscreen)
        • ⌘⇧6 (hoặc ⌃⇧6): Nhận diện chữ & mã QR (OCR Text)
        • ⌘⇧5 (hoặc ⌃⇧5): Ghim ảnh nổi lên màn hình (Pin Image)
        • ⌘⇧7 (hoặc ⌃⇧7): Bật / Dừng quay màn hình (Screen Record)

        Tính năng nâng cao:
        • Quick Access Card: Kéo thả file trực tiếp vào Telegram, Slack, VSCode.
        • Floating Pin: Cuộn chuột để chỉnh độ mờ (opacity), chuột phải để đóng.
        • Clean Desktop: Ẩn/Hiện icon rác trên màn hình nền.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Đã hiểu")
        alert.runModal()
    }

    @objc func actionQuit() {
        NSApp.terminate(nil)
    }

    private func handleHotKey(_ action: HotKeyManager.Action) {
        switch action {
        case .area:
            actionArea()
        case .fullscreen:
            actionFullscreen()
        case .ocr:
            actionOCR()
        case .pin:
            actionPin()
        case .record:
            actionToggleRecord()
        }
    }
}

// Start Cocoa Event Loop
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

