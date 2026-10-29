import AppKit
import Foundation
import Vision
import ImageIO
import Carbon
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Entry Point

var isStandaloneMode = false

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.count < 2 {
            isStandaloneMode = false
            runTray()
            return
        }

        let cmd = args[1]
        switch cmd {
        case "tray", "app":
            isStandaloneMode = false
            runTray()
        case "update":
            isStandaloneMode = true
            runUpdate()
        case "settings", "shortcuts", "preferences":
            isStandaloneMode = true
            runShortcuts()
        case "annotate", "edit":
            isStandaloneMode = true
            guard args.count >= 3 else {
                fputs("Error: annotate requires an image file path\n", stderr)
                exit(1)
            }
            runAnnotate(imagePath: args[2])
        case "color", "picker", "eyedropper":
            isStandaloneMode = true
            runColorPicker()
        case "gif":
            isStandaloneMode = true
            guard args.count >= 3 else {
                fputs("Error: gif requires a video file path (.mov)\n", stderr)
                exit(1)
            }
            runGifExport(videoPath: args[2])
        case "overlay":
            isStandaloneMode = true
            let outPath = args.count >= 3 ? args[2] : nil
            runOverlay(outputPath: outPath)
        case "fullscreen":
            isStandaloneMode = true
            guard args.count >= 3 else {
                fputs("Error: fullscreen requires an image file path\n", stderr)
                exit(1)
            }
            runFullscreen(outputPath: args[2])
        case "card":
            isStandaloneMode = true
            guard args.count >= 3 else {
                fputs("Error: card requires an image file path\n", stderr)
                exit(1)
            }
            runCard(imagePath: args[2])
        case "pin":
            isStandaloneMode = true
            guard args.count >= 3 else {
                fputs("Error: pin requires an image file path\n", stderr)
                exit(1)
            }
            runPin(imagePath: args[2])
        case "ocr":
            isStandaloneMode = true
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
        fputs("Usage: snip-ui <tray | update | settings | annotate <image> | color | gif <video> | overlay | card <image> | pin <image> | ocr <image>>\n", stderr)
    }

    var singleInstanceLockFD: Int32 = -1

    func acquireSingleInstanceLock() -> Bool {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "com.trinhhaox.xchup"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.contains(where: { $0.processIdentifier != currentPID }) {
            return false
        }

        let path = "/tmp/xchup_tray.lock"
        singleInstanceLockFD = Darwin.open(path, O_CREAT | O_RDWR, 0o666)
        if singleInstanceLockFD >= 0 {
            var fl = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
            if fcntl(singleInstanceLockFD, F_SETLK, &fl) != 0 {
                Darwin.close(singleInstanceLockFD)
                return false
            }
        }
        return true
    }

    var isShowingPermissionAlert = false

    func checkScreenCapturePermission(prompt: Bool = false) -> Bool {
        if #available(macOS 10.15, *) {
            if CGPreflightScreenCaptureAccess() {
                return true
            }
            if prompt && !isShowingPermissionAlert {
                isShowingPermissionAlert = true
                DispatchQueue.main.async {
                    // App chạy dạng accessory (LSUIElement) nên phải kích hoạt, nếu không alert bị che sau cửa sổ khác
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = "Cần cấp quyền Ghi lại màn hình cho xChup"
                    alert.informativeText = "Để chụp ảnh màn hình, bạn cần bật quyền 'Ghi màn hình & Âm thanh hệ thống' cho xChup trong Cài đặt hệ thống.\n\nmacOS chỉ áp dụng quyền mới sau khi xChup khởi động lại: bật xong hãy bấm \"Khởi động lại xChup\"."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Mở Cài đặt hệ thống")
                    alert.addButton(withTitle: "Khởi động lại xChup")
                    alert.addButton(withTitle: "Để sau")
                    let response = alert.runModal()
                    self.isShowingPermissionAlert = false
                    switch response {
                    case .alertFirstButtonReturn:
                        // Đăng ký xChup vào danh sách quyền (lần đầu macOS hiện thêm hộp thoại hệ thống) rồi mở đúng mục
                        CGRequestScreenCaptureAccess()
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    case .alertSecondButtonReturn:
                        self.relaunchApp()
                    default:
                        break
                    }
                }
            }
            return false
        }
        return true
    }

    /// Chờ tiến trình hiện tại thoát (để nhả khoá single-instance) rồi mở lại app.
    func relaunchApp() {
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        open "\(Bundle.main.bundlePath)" --args tray
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script]
        do {
            try proc.run()
            NSApp.terminate(nil)
        } catch {
            fputs("xChup relaunch failed: \(error)\n", stderr)
        }
    }

    func runTray() {
        guard acquireSingleInstanceLock() else {
            fputs("xChup tray is already running.\n", stderr)
            exit(0)
        }
        NSApp.setActivationPolicy(.accessory)
        _ = checkScreenCapturePermission(prompt: true)
        TrayController.shared.show()
    }

    func runShortcuts() {
        NSApp.setActivationPolicy(.regular)
        ShortcutPreferencesWindowController.shared.show()
    }

    func runAnnotate(imagePath: String) {
        NSApp.setActivationPolicy(.regular)
        AnnotationWindowController.shared.show(imagePath: imagePath)
    }

    func runColorPicker() {
        NSApp.setActivationPolicy(.accessory)
        ColorPickerWindowController.shared.show()
    }

    func runGifExport(videoPath: String) {
        NSApp.setActivationPolicy(.accessory)
        GifConverter.convert(movUrl: URL(fileURLWithPath: videoPath)) { res in
            switch res {
            case .success(let gifUrl):
                print("GIF exported successfully: \(gifUrl.path)")
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([gifUrl as NSURL])
                exit(0)
            case .failure(let err):
                fputs("Failed to export GIF: \(err.localizedDescription)\n", stderr)
                exit(1)
            }
        }
    }

    func runUpdate() {
        NSApp.setActivationPolicy(.accessory)
        UpdateManager.shared.checkForUpdates(silent: false)
    }

    func runOverlay(outputPath: String? = nil) {
        NSApp.setActivationPolicy(.accessory)
        OverlayController.shared.show(outputPath: outputPath)
    }

    func runFullscreen(outputPath: String) {
        NSApp.setActivationPolicy(.accessory)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", outputPath]
        try? task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            fputs("screencapture fullscreen failed with status \(task.terminationStatus)\n", stderr)
            exit(1)
        }
        exit(0)
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

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayController {
    static let shared = OverlayController()
    private var windows: [NSWindow] = []
    private var outputPath: String?
    private var completion: ((String, NSRect) -> Void)?
    private var watchdog: DispatchWorkItem?

    func show(outputPath: String? = nil, completion: ((String, NSRect) -> Void)? = nil) {
        // Bấm phím tắt lần nữa khi overlay đang mở sẽ ghi đè `windows` và bỏ rơi
        // các overlay cũ ở level .screenSaver: chúng phủ kín mọi màn hình, không
        // còn ai đóng được, kể cả hộp Force Quit -> phải khởi động lại máy.
        guard windows.isEmpty else { return }
        self.outputPath = outputPath
        self.completion = completion
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        windows = NSScreen.screens.map { screen in
            let window = OverlayWindow(
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
            window.makeFirstResponder(overlayView)
            window.orderFrontRegardless()
            return window
        }

        // Lưới an toàn: nếu overlay không nhận được phím/chuột (app không được
        // kích hoạt), tự huỷ sau 60 giây thay vì khoá màn hình vĩnh viễn.
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, !self.windows.isEmpty else { return }
            self.finish(rect: nil)
        }
        watchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: item)
    }

    func finish(rect: NSRect?) {
        guard !windows.isEmpty else { return }
        watchdog?.cancel()
        watchdog = nil
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()

        // Đợi 60ms để WindowServer dọn sạch frame overlay khỏi màn hình
        usleep(60_000)

        guard let r = rect, r.width > 2 && r.height > 2 else {
            if completion != nil {
                // In-app mode: user cancelled, don't exit app
                self.completion = nil
                return
            } else {
                fputs("Cancelled\n", stderr)
                if isStandaloneMode {
                    exit(1)
                }
                return
            }
        }

        // Chụp màn hình bằng screencapture từ ngữ cảnh của ứng dụng macOS
        if let outPath = outputPath {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            let rArg = "-R\(Int(r.origin.x)),\(Int(r.origin.y)),\(Int(r.width)),\(Int(r.height))"
            task.arguments = ["-x", rArg, outPath]
            try? task.run()
            task.waitUntilExit()

            if task.terminationStatus != 0 {
                fputs("screencapture failed with status \(task.terminationStatus)\n", stderr)
                showNotification(title: "xChup Lỗi", text: "Không thể chụp màn hình. Vui lòng cấp quyền Ghi màn hình trong Cài đặt hệ thống.")
                if completion == nil && isStandaloneMode {
                    exit(1)
                }
                return
            }
        }

        if let cb = completion, let outPath = outputPath {
            self.completion = nil
            cb(outPath, r)
            return
        }

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
        if isStandaloneMode {
            exit(0)
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

    // Overlay mở khi app chưa active: không có dòng này, cú click đầu tiên chỉ
    // dùng để kích hoạt app và bị nuốt mất.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas {
            removeTrackingArea(ta)
        }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            OverlayController.shared.finish(rect: nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        OverlayController.shared.finish(rect: nil)
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

        let primaryHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height
        let quartzY = primaryHeight - (screenFrame.origin.y + y + h)
        let quartzX = screenFrame.origin.x + x
        let finalRect = NSRect(x: quartzX, y: quartzY, width: w, height: h)

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
    private var dismissWorkItem: DispatchWorkItem?

    func show(imagePath: String) {
        self.imagePath = imagePath
        guard let screen = NSScreen.main, let image = NSImage(contentsOfFile: imagePath) else {
            if isStandaloneMode {
                exit(1)
            }
            return
        }

        let maxCardW: CGFloat = 280
        let maxCardH: CGFloat = 170
        let imgSize = image.size
        let aspect = imgSize.width / max(imgSize.height, 1)

        var cardW = maxCardW
        var cardH = cardW / aspect
        if cardH > maxCardH {
            cardH = maxCardH
            cardW = cardH * aspect
        }

        let totalW = max(cardW, 240) + 16
        let totalH = cardH + 60

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
        win.orderFrontRegardless()
        self.window = win

        // Auto dismiss after 6 seconds
        let work = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        self.dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: work)
    }

    func openAnnotation() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        window?.orderOut(nil)
        window = nil
        AnnotationWindowController.shared.show(imagePath: imagePath)
    }

    func openPin() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        window?.orderOut(nil)
        window = nil
        PinController.shared.show(imagePath: imagePath)
    }

    func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            self.window?.animator().alphaValue = 0.0
        }, completionHandler: {
            self.window?.orderOut(nil)
            self.window = nil
            if isStandaloneMode {
                exit(0)
            }
        })
    }
}

final class CardView: NSView, NSDraggingSource {
    private let image: NSImage
    private let filePath: String
    private var editButton: NSButton!
    private var pinButton: NSButton!

    init(frame: NSRect, image: NSImage, filePath: String) {
        self.image = image
        self.filePath = filePath
        super.init(frame: frame)

        pinButton = makeActionButton(title: "Ghim", symbol: "pin.fill", action: #selector(actionPin))
        pinButton.frame = NSRect(x: bounds.width - 12 - 72, y: 9, width: 72, height: 26)
        addSubview(pinButton)

        editButton = makeActionButton(title: "Sửa", symbol: "pencil", action: #selector(actionAnnotate))
        editButton.frame = NSRect(x: pinButton.frame.minX - 6 - 66, y: 9, width: 66, height: 26)
        addSubview(editButton)

        // Nút đóng tròn ở góc trên bên trái ảnh xem trước
        let closeButton = NSButton(frame: NSRect(x: 16, y: bounds.height - 16 - 24, width: 24, height: 24))
        closeButton.isBordered = false
        closeButton.title = ""
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Đóng")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        closeButton.contentTintColor = .white
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 12
        closeButton.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.65).cgColor
        closeButton.layer?.borderWidth = 1
        closeButton.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.35).cgColor
        closeButton.toolTip = "Đóng"
        closeButton.target = self
        closeButton.action = #selector(actionClose)
        addSubview(closeButton)
    }

    private func makeActionButton(title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: " " + title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ])
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        button.imagePosition = .imageLeading
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.18).cgColor
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.25).cgColor
        return button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func actionAnnotate() {
        QuickAccessController.shared.openAnnotation()
    }

    @objc private func actionPin() {
        QuickAccessController.shared.openPin()
    }

    @objc private func actionClose() {
        // Gọi thẳng trong action của nút thì animation mờ dần không bao giờ chạy
        // completion, thẻ đứng yên: đẩy sang vòng run loop sau.
        DispatchQueue.main.async { QuickAccessController.shared.dismiss() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Glass background card
        let bgPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 12, yRadius: 12)
        NSColor(calibratedWhite: 0.11, alpha: 0.96).setFill()
        bgPath.fill()
        NSColor(calibratedWhite: 1.0, alpha: 0.18).setStroke()
        bgPath.lineWidth = 1.0
        bgPath.stroke()

        // Draw image thumbnail (clip chỉ cho ảnh, nếu không chữ bên dưới bị cắt mất)
        let imgRect = NSRect(x: 10, y: 44, width: bounds.width - 20, height: bounds.height - 54)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: imgRect, xRadius: 8, yRadius: 8).addClip()
        image.draw(in: imgRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        // Actions bar at bottom
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor(calibratedRed: 0.45, green: 0.88, blue: 0.55, alpha: 1.0)
        ]
        let info = "✓ Đã copy" as NSString
        let infoSize = info.size(withAttributes: titleAttrs)
        info.draw(at: NSPoint(x: 16, y: 9 + (26 - infoSize.height) / 2), withAttributes: titleAttrs)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            actionAnnotate()
            return
        }

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
            if isStandaloneMode {
                exit(1)
            }
            return
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
        if isStandaloneMode {
            exit(0)
        }
    }
}

// MARK: - Annotation & Markup Editor

enum AnnotationTool {
    case arrow
    case rectangle
    case blur
    case step
    case pen
    case text
}

enum AnnotationItem {
    case arrow(start: CGPoint, end: CGPoint, color: NSColor, width: CGFloat)
    case rectangle(rect: CGRect, color: NSColor, width: CGFloat)
    case blur(rect: CGRect)
    case step(center: CGPoint, number: Int, color: NSColor)
    case pen(points: [CGPoint], color: NSColor, width: CGFloat)
    case text(origin: CGPoint, text: String, color: NSColor, fontSize: CGFloat)
}

final class AnnotationCanvasView: NSView {
    var baseImage: NSImage
    private var baseCGImage: CGImage?
    private let ciContext = CIContext()

    var currentTool: AnnotationTool = .arrow
    var currentColor: NSColor = .systemRed
    var currentLineWidth: CGFloat = 3.5

    var annotations: [AnnotationItem] = []
    var redoStack: [AnnotationItem] = []
    private var nextStepNumber: Int = 1

    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var currentPenPoints: [CGPoint] = []

    init(image: NSImage) {
        self.baseImage = image
        super.init(frame: NSRect(origin: .zero, size: image.size))
        if let tiff = image.tiffRepresentation, let source = CGImageSourceCreateWithData(tiff as CFData, nil) {
            self.baseCGImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func undo() {
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
        if case .step = last {
            nextStepNumber = max(1, nextStepNumber - 1)
        }
        needsDisplay = true
    }

    func redo() {
        guard let item = redoStack.popLast() else { return }
        annotations.append(item)
        if case .step = item {
            nextStepNumber += 1
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        baseImage.draw(in: bounds)

        for item in annotations {
            drawItem(item, in: ctx)
        }

        if let start = dragStart, let current = dragCurrent {
            switch currentTool {
            case .arrow:
                drawArrow(ctx: ctx, start: start, end: current, color: currentColor, width: currentLineWidth)
            case .rectangle:
                let r = CGRect(
                    x: min(start.x, current.x),
                    y: min(start.y, current.y),
                    width: abs(current.x - start.x),
                    height: abs(current.y - start.y)
                )
                drawRect(ctx: ctx, rect: r, color: currentColor, width: currentLineWidth)
            case .blur:
                let r = CGRect(
                    x: min(start.x, current.x),
                    y: min(start.y, current.y),
                    width: abs(current.x - start.x),
                    height: abs(current.y - start.y)
                )
                drawBlur(ctx: ctx, rect: r)
                ctx.saveGState()
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineDash(phase: 0, lengths: [4, 4])
                ctx.stroke(r)
                ctx.restoreGState()
            case .pen:
                drawPen(ctx: ctx, points: currentPenPoints, color: currentColor, width: currentLineWidth)
            default:
                break
            }
        }
    }

    private func drawItem(_ item: AnnotationItem, in ctx: CGContext) {
        switch item {
        case .arrow(let start, let end, let color, let width):
            drawArrow(ctx: ctx, start: start, end: end, color: color, width: width)
        case .rectangle(let rect, let color, let width):
            drawRect(ctx: ctx, rect: rect, color: color, width: width)
        case .blur(let rect):
            drawBlur(ctx: ctx, rect: rect)
        case .step(let center, let number, let color):
            drawStep(ctx: ctx, center: center, number: number, color: color)
        case .pen(let points, let color, let width):
            drawPen(ctx: ctx, points: points, color: color, width: width)
        case .text(let origin, let text, let color, let fontSize):
            drawText(origin: origin, text: text, color: color, fontSize: fontSize)
        }
    }

    private func drawArrow(ctx: CGContext, start: CGPoint, end: CGPoint, color: NSColor, width: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)

        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowLen = max(width * 4.5, 18.0)
        let arrowAngle: CGFloat = .pi / 6.5

        let shaftEnd = CGPoint(
            x: end.x - (arrowLen * 0.7) * cos(angle),
            y: end.y - (arrowLen * 0.7) * sin(angle)
        )

        ctx.move(to: start)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()

        let p1 = CGPoint(
            x: end.x - arrowLen * cos(angle - arrowAngle),
            y: end.y - arrowLen * sin(angle - arrowAngle)
        )
        let p2 = CGPoint(
            x: end.x - arrowLen * cos(angle + arrowAngle),
            y: end.y - arrowLen * sin(angle + arrowAngle)
        )

        ctx.move(to: end)
        ctx.addLine(to: p1)
        ctx.addLine(to: p2)
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }

    private func drawRect(ctx: CGContext, rect: CGRect, color: NSColor, width: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        let path = CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawBlur(ctx: CGContext, rect: CGRect) {
        guard let baseCG = baseCGImage, rect.width > 2, rect.height > 2 else { return }

        let scaleX = CGFloat(baseCG.width) / bounds.width
        let scaleY = CGFloat(baseCG.height) / bounds.height

        let cropRect = CGRect(
            x: rect.origin.x * scaleX,
            y: (bounds.height - rect.origin.y - rect.height) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )

        if let cropped = baseCG.cropping(to: cropRect) {
            let ci = CIImage(cgImage: cropped)
            let filter = CIFilter(name: "CIPixellate")!
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(max(rect.width, rect.height) * 0.12 * scaleX, forKey: kCIInputScaleKey)

            if let outCI = filter.outputImage,
               let pixCG = ciContext.createCGImage(outCI, from: ci.extent) {
                ctx.saveGState()
                let path = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
                ctx.addPath(path)
                ctx.clip()
                ctx.draw(pixCG, in: rect)
                ctx.restoreGState()
            }
        }
    }

    private func drawStep(ctx: CGContext, center: CGPoint, number: Int, color: NSColor) {
        let radius: CGFloat = 14.0
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 3.0, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2.0)
        ctx.strokeEllipse(in: rect)
        ctx.restoreGState()

        let str = "\(number)" as NSString
        let font = NSFont.systemFont(ofSize: 13, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let size = str.size(withAttributes: attrs)
        let textPt = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2 + 1)
        str.draw(at: textPt, withAttributes: attrs)
    }

    private func drawPen(ctx: CGContext, points: [CGPoint], color: NSColor, width: CGFloat) {
        guard points.count > 1 else { return }
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: points[0])
        for pt in points.dropFirst() {
            ctx.addLine(to: pt)
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawText(origin: CGPoint, text: String, color: NSColor, fontSize: CGFloat) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .strokeColor: NSColor.black.withAlphaComponent(0.8),
            .strokeWidth: -2.0
        ]
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        dragStart = pt
        dragCurrent = pt

        if currentTool == .pen {
            currentPenPoints = [pt]
        } else if currentTool == .step {
            let item = AnnotationItem.step(center: pt, number: nextStepNumber, color: currentColor)
            annotations.append(item)
            redoStack.removeAll()
            nextStepNumber += 1
            dragStart = nil
            dragCurrent = nil
            needsDisplay = true
        } else if currentTool == .text {
            promptTextInput(at: pt)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        dragCurrent = pt
        if currentTool == .pen {
            currentPenPoints.append(pt)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart, let current = dragCurrent else { return }
        let dx = abs(current.x - start.x)
        let dy = abs(current.y - start.y)

        if dx > 4 || dy > 4 {
            switch currentTool {
            case .arrow:
                let item = AnnotationItem.arrow(start: start, end: current, color: currentColor, width: currentLineWidth)
                annotations.append(item)
                redoStack.removeAll()
            case .rectangle:
                let r = CGRect(
                    x: min(start.x, current.x),
                    y: min(start.y, current.y),
                    width: abs(current.x - start.x),
                    height: abs(current.y - start.y)
                )
                let item = AnnotationItem.rectangle(rect: r, color: currentColor, width: currentLineWidth)
                annotations.append(item)
                redoStack.removeAll()
            case .blur:
                let r = CGRect(
                    x: min(start.x, current.x),
                    y: min(start.y, current.y),
                    width: abs(current.x - start.x),
                    height: abs(current.y - start.y)
                )
                let item = AnnotationItem.blur(rect: r)
                annotations.append(item)
                redoStack.removeAll()
            case .pen:
                if currentPenPoints.count > 1 {
                    let item = AnnotationItem.pen(points: currentPenPoints, color: currentColor, width: currentLineWidth)
                    annotations.append(item)
                    redoStack.removeAll()
                }
            default:
                break
            }
        }

        dragStart = nil
        dragCurrent = nil
        currentPenPoints.removeAll()
        needsDisplay = true
    }

    private func promptTextInput(at pt: CGPoint) {
        let alert = NSAlert()
        alert.messageText = "Nhập văn bản chú thích:"
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "Nhập chữ..."
        alert.accessoryView = input
        alert.addButton(withTitle: "Thêm")
        alert.addButton(withTitle: "Hủy")

        if alert.runModal() == .alertFirstButtonReturn {
            let str = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !str.isEmpty {
                let item = AnnotationItem.text(origin: pt, text: str, color: currentColor, fontSize: 16)
                annotations.append(item)
                redoStack.removeAll()
                needsDisplay = true
            }
        }
        dragStart = nil
        dragCurrent = nil
    }

    func renderFlattenedImage() -> NSImage {
        let size = bounds.size
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            baseImage.draw(in: bounds)
            for item in annotations {
                drawItem(item, in: ctx)
            }
        }
        image.unlockFocus()
        return image
    }
}

final class AnnotationWindowController: NSWindowController {
    static let shared = AnnotationWindowController()
    private var canvasView: AnnotationCanvasView?
    private var imagePath: String = ""
    private var toolSegment: NSSegmentedControl!
    private var colorSegment: NSSegmentedControl!

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "xChup • Chú thích ảnh (Annotation Editor)"
        win.isReleasedWhenClosed = false
        super.init(window: win)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(imagePath: String) {
        self.imagePath = imagePath
        guard let image = NSImage(contentsOfFile: imagePath),
              let screen = NSScreen.main,
              let win = window else { return }

        let screenFrame = screen.visibleFrame
        let maxW = screenFrame.width * 0.85
        let maxH = screenFrame.height * 0.85

        var winW = image.size.width + 40
        var winH = image.size.height + 100

        winW = min(max(winW, 640), maxW)
        winH = min(max(winH, 480), maxH)

        win.setContentSize(NSSize(width: winW, height: winH))
        win.center()

        let root = NSView(frame: win.contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        win.contentView = root

        let toolbarView = NSVisualEffectView()
        toolbarView.material = .headerView
        toolbarView.blendingMode = .withinWindow
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbarView)

        toolSegment = NSSegmentedControl(
            labels: ["↗ Mũi tên", "⬜ Khung", "⬛ Làm mờ", "① Đánh số", "✏ Bút", "T Chữ"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(toolChanged(_:))
        )
        toolSegment.selectedSegment = 0
        toolSegment.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.addSubview(toolSegment)

        colorSegment = NSSegmentedControl(
            labels: ["🔴", "🟡", "🟢", "🔵", "🟣", "⚪", "⚫"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(colorChanged(_:))
        )
        colorSegment.selectedSegment = 0
        colorSegment.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.addSubview(colorSegment)

        let undoBtn = NSButton(title: "↶", target: self, action: #selector(actionUndo))
        undoBtn.bezelStyle = .rounded
        undoBtn.toolTip = "Hoàn tác (⌘Z)"
        undoBtn.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.addSubview(undoBtn)

        let redoBtn = NSButton(title: "↷", target: self, action: #selector(actionRedo))
        redoBtn.bezelStyle = .rounded
        redoBtn.toolTip = "Làm lại (⌘⇧Z)"
        redoBtn.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.addSubview(redoBtn)

        let copyBtn = NSButton(title: "📋 Sao chép", target: self, action: #selector(actionCopy))
        copyBtn.bezelStyle = .rounded
        copyBtn.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.addSubview(copyBtn)

        let saveBtn = NSButton(title: "💾 Lưu", target: self, action: #selector(actionSave))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.addSubview(saveBtn)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = NSColor.underPageBackgroundColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)

        let canvas = AnnotationCanvasView(image: image)
        scroll.documentView = canvas
        self.canvasView = canvas

        NSLayoutConstraint.activate([
            toolbarView.topAnchor.constraint(equalTo: root.topAnchor),
            toolbarView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbarView.heightAnchor.constraint(equalToConstant: 46),

            toolSegment.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor, constant: 14),
            toolSegment.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            colorSegment.leadingAnchor.constraint(equalTo: toolSegment.trailingAnchor, constant: 12),
            colorSegment.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            undoBtn.leadingAnchor.constraint(equalTo: colorSegment.trailingAnchor, constant: 12),
            undoBtn.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            redoBtn.leadingAnchor.constraint(equalTo: undoBtn.trailingAnchor, constant: 4),
            redoBtn.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            saveBtn.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor, constant: -14),
            saveBtn.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            copyBtn.trailingAnchor.constraint(equalTo: saveBtn.leadingAnchor, constant: -8),
            copyBtn.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: canvasView?.currentTool = .arrow
        case 1: canvasView?.currentTool = .rectangle
        case 2: canvasView?.currentTool = .blur
        case 3: canvasView?.currentTool = .step
        case 4: canvasView?.currentTool = .pen
        case 5: canvasView?.currentTool = .text
        default: break
        }
    }

    @objc private func colorChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: canvasView?.currentColor = .systemRed
        case 1: canvasView?.currentColor = .systemYellow
        case 2: canvasView?.currentColor = .systemGreen
        case 3: canvasView?.currentColor = .systemBlue
        case 4: canvasView?.currentColor = .systemPurple
        case 5: canvasView?.currentColor = .white
        case 6: canvasView?.currentColor = .black
        default: break
        }
    }

    @objc private func actionUndo() {
        canvasView?.undo()
    }

    @objc private func actionRedo() {
        canvasView?.redo()
    }

    @objc private func actionCopy() {
        guard let canvas = canvasView else { return }
        let finalImg = canvas.renderFlattenedImage()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([finalImg])
        showNotification(title: "xChup", text: "Đã sao chép ảnh có chú thích vào Clipboard.")
        window?.orderOut(nil)
    }

    @objc private func actionSave() {
        guard let canvas = canvasView else { return }
        let finalImg = canvas.renderFlattenedImage()
        if let tiff = finalImg.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: imagePath))
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([finalImg])
        showNotification(title: "xChup", text: "Đã lưu ảnh có chú thích.")
        window?.orderOut(nil)
    }
}

// MARK: - Color Eyedropper & Magnifier

final class ColorPickerWindowController: NSObject {
    static let shared = ColorPickerWindowController()
    private var windows: [NSWindow] = []

    enum ColorFormat: Int, CaseIterable {
        case hex = 0
        case rgb = 1
        case nsColor = 2

        var name: String {
            switch self {
            case .hex: return "HEX"
            case .rgb: return "RGB"
            case .nsColor: return "Swift"
            }
        }
    }

    var currentFormat: ColorFormat = .hex

    static func captureScreenImage(screen: NSScreen) -> CGImage? {
        let tempPath = "/tmp/xchup_colorpicker_\(ProcessInfo.processInfo.processIdentifier).png"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            task.arguments = ["-x", "-D", "\(screenNumber)", tempPath]
        } else {
            task.arguments = ["-x", tempPath]
        }
        try? task.run()
        task.waitUntilExit()

        guard FileManager.default.fileExists(atPath: tempPath) else { return nil }
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let url = URL(fileURLWithPath: tempPath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return cgImage
    }

    func show() {
        close()
        currentFormat = .hex

        for screen in NSScreen.screens {
            let screenRect = screen.frame
            guard let screenshot = ColorPickerWindowController.captureScreenImage(screen: screen) else {
                continue
            }

            let win = NSWindow(
                contentRect: screenRect,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.level = .popUpMenu
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            win.ignoresMouseEvents = false
            win.acceptsMouseMovedEvents = true

            let overlayView = MagnifierOverlayView(
                frame: NSRect(origin: .zero, size: screenRect.size),
                screen: screen,
                screenshot: screenshot,
                controller: self
            )
            win.contentView = overlayView
            win.makeKeyAndOrderFront(nil)
            windows.append(win)
        }

        NSApp.activate(ignoringOtherApps: true)
        NSCursor.hide()
    }

    func close() {
        NSCursor.unhide()
        for win in windows {
            win.orderOut(nil)
        }
        windows.removeAll()
    }

    func cycleFormat() {
        let all = ColorFormat.allCases
        let nextIndex = (currentFormat.rawValue + 1) % all.count
        currentFormat = all[nextIndex]
        for win in windows {
            win.contentView?.needsDisplay = true
        }
    }

    func copyColor(_ color: NSColor) {
        close()

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)

        let rInt = Int(round(r * 255.0))
        let gInt = Int(round(g * 255.0))
        let bInt = Int(round(b * 255.0))

        let hex = String(format: "#%02X%02X%02X", rInt, gInt, bInt)
        let rgb = "rgb(\(rInt), \(gInt), \(bInt))"
        let swift = String(format: "NSColor(red: %.2f, green: %.2f, blue: %.2f, alpha: 1.0)", r, g, b)

        let resultString: String
        switch currentFormat {
        case .hex: resultString = hex
        case .rgb: resultString = rgb
        case .nsColor: resultString = swift
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(resultString, forType: .string)

        NSSound(named: "Pop")?.play()
        showNotification(
            title: "xChup • Đã sao chép mã màu",
            text: "\(resultString) (\(currentFormat.name)) đã được lưu vào Clipboard."
        )
    }
}

final class MagnifierOverlayView: NSView {
    private let screenObj: NSScreen
    private let screenshot: CGImage
    private weak var controller: ColorPickerWindowController?
    private var mousePoint: CGPoint?

    init(frame: NSRect, screen: NSScreen, screenshot: CGImage, controller: ColorPickerWindowController) {
        self.screenObj = screen
        self.screenshot = screenshot
        self.controller = controller
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            controller?.close()
        } else if event.keyCode == 49 { // Space
            controller?.cycleFormat()
        } else if event.keyCode == 36 { // Enter
            if let color = currentColorAtMouse() {
                controller?.copyColor(color)
            }
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        mousePoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if let color = currentColorAtMouse() {
            controller?.copyColor(color)
        }
    }

    private func currentColorAtMouse() -> NSColor? {
        guard let pt = mousePoint else { return nil }
        let scaleX = CGFloat(screenshot.width) / max(bounds.width, 1)
        let scaleY = CGFloat(screenshot.height) / max(bounds.height, 1)
        let px = Int(round(pt.x * scaleX))
        let py = Int(round((bounds.height - pt.y) * scaleY))
        return getPixelColor(cgImage: screenshot, x: px, y: py)
    }

    private func getPixelColor(cgImage: CGImage, x: Int, y: Int) -> NSColor? {
        guard x >= 0, x < cgImage.width, y >= 0, y < cgImage.height else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var rawData = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &rawData,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: -x, y: -(cgImage.height - 1 - y), width: cgImage.width, height: cgImage.height))
        let r = CGFloat(rawData[0]) / 255.0
        let g = CGFloat(rawData[1]) / 255.0
        let b = CGFloat(rawData[2]) / 255.0
        let a = CGFloat(rawData[3]) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: a)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext, let pt = mousePoint else { return }

        let scaleX = CGFloat(screenshot.width) / max(bounds.width, 1)
        let scaleY = CGFloat(screenshot.height) / max(bounds.height, 1)
        let px = Int(round(pt.x * scaleX))
        let py = Int(round((bounds.height - pt.y) * scaleY))
        guard let currentColor = getPixelColor(cgImage: screenshot, x: px, y: py) else { return }

        let loupeRadius: CGFloat = 65
        let loupeDiameter = loupeRadius * 2

        var loupeOrigin = CGPoint(x: pt.x + 28, y: pt.y + 28)
        if loupeOrigin.x + loupeDiameter + 20 > bounds.maxX {
            loupeOrigin.x = pt.x - loupeDiameter - 28
        }
        if loupeOrigin.y + loupeDiameter + 65 > bounds.maxY {
            loupeOrigin.y = pt.y - loupeDiameter - 28
        }
        if loupeOrigin.x < 10 { loupeOrigin.x = 10 }
        if loupeOrigin.y < 10 { loupeOrigin.y = 10 }

        let loupeRect = CGRect(origin: loupeOrigin, size: CGSize(width: loupeDiameter, height: loupeDiameter))

        // 1. Draw outer shadow
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 14, color: NSColor(calibratedWhite: 0, alpha: 0.45).cgColor)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillEllipse(in: loupeRect)
        ctx.restoreGState()

        // 2. Crop screenshot pixels (13x13 grid)
        let gridSize = 13
        let halfGrid = gridSize / 2
        let cropRect = CGRect(x: px - halfGrid, y: py - halfGrid, width: gridSize, height: gridSize)

        if let cropCG = screenshot.cropping(to: cropRect) {
            ctx.saveGState()
            ctx.addEllipse(in: loupeRect)
            ctx.clip()

            ctx.interpolationQuality = .none
            ctx.draw(cropCG, in: loupeRect)

            // Draw pixel grid
            let cellSize = loupeDiameter / CGFloat(gridSize)
            ctx.setStrokeColor(NSColor(calibratedWhite: 0.5, alpha: 0.28).cgColor)
            ctx.setLineWidth(0.6)

            for i in 1..<gridSize {
                let xPos = loupeRect.minX + CGFloat(i) * cellSize
                ctx.move(to: CGPoint(x: xPos, y: loupeRect.minY))
                ctx.addLine(to: CGPoint(x: xPos, y: loupeRect.maxY))

                let yPos = loupeRect.minY + CGFloat(i) * cellSize
                ctx.move(to: CGPoint(x: loupeRect.minX, y: yPos))
                ctx.addLine(to: CGPoint(x: loupeRect.maxX, y: yPos))
            }
            ctx.strokePath()

            // Highlight center crosshair cell
            let centerCellRect = CGRect(
                x: loupeRect.minX + CGFloat(halfGrid) * cellSize,
                y: loupeRect.minY + CGFloat(halfGrid) * cellSize,
                width: cellSize,
                height: cellSize
            )
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.8)
            ctx.stroke(centerCellRect.insetBy(dx: 0.5, dy: 0.5))

            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(0.8)
            ctx.stroke(centerCellRect.insetBy(dx: 1.5, dy: 1.5))

            ctx.restoreGState()
        }

        // 3. Draw outer glass rim
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(3.5)
        ctx.strokeEllipse(in: loupeRect)

        ctx.setStrokeColor(NSColor(calibratedWhite: 0.2, alpha: 0.6).cgColor)
        ctx.setLineWidth(1.0)
        ctx.strokeEllipse(in: loupeRect.insetBy(dx: -1.5, dy: -1.5))
        ctx.restoreGState()

        // 4. Draw HUD Info Badge below / above loupe
        let badgeW: CGFloat = 165
        let badgeH: CGFloat = 48
        var badgeX = loupeRect.midX - badgeW / 2
        var badgeY = loupeRect.minY - badgeH - 10

        if badgeY < 10 {
            badgeY = loupeRect.maxY + 10
        }
        if badgeX < 10 { badgeX = 10 }
        if badgeX + badgeW > bounds.maxX - 10 { badgeX = bounds.maxX - badgeW - 10 }

        let badgeRect = CGRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH)
        let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 10, yRadius: 10)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: NSColor(calibratedWhite: 0, alpha: 0.4).cgColor)
        NSColor(calibratedWhite: 0.12, alpha: 0.92).setFill()
        badgePath.fill()
        ctx.restoreGState()

        NSColor(calibratedWhite: 0.35, alpha: 0.6).setStroke()
        badgePath.lineWidth = 1.0
        badgePath.stroke()

        // Color preview square in badge
        let chipRect = CGRect(x: badgeRect.minX + 10, y: badgeRect.minY + badgeH - 24, width: 15, height: 15)
        let chipPath = NSBezierPath(roundedRect: chipRect, xRadius: 3.5, yRadius: 3.5)
        currentColor.setFill()
        chipPath.fill()
        NSColor.white.withAlphaComponent(0.8).setStroke()
        chipPath.lineWidth = 1.0
        chipPath.stroke()

        // Format strings
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        currentColor.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        let rInt = Int(round(r * 255.0))
        let gInt = Int(round(g * 255.0))
        let bInt = Int(round(b * 255.0))

        let hex = String(format: "#%02X%02X%02X", rInt, gInt, bInt)
        let rgb = "rgb(\(rInt), \(gInt), \(bInt))"
        let swift = String(format: "NSColor(%.2f, %.2f, %.2f)", r, g, b)

        let fmt = controller?.currentFormat ?? .hex
        let displayText: String
        switch fmt {
        case .hex: displayText = "\(hex) [HEX]"
        case .rgb: displayText = "\(rgb) [RGB]"
        case .nsColor: displayText = "\(swift)"
        }

        let codeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        (displayText as NSString).draw(at: CGPoint(x: badgeRect.minX + 32, y: badgeRect.minY + badgeH - 24), withAttributes: codeAttrs)

        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5),
            .foregroundColor: NSColor(calibratedWhite: 0.70, alpha: 1.0)
        ]
        let hint = "Click: Copy • Space: Kiểu • Esc: Huỷ"
        (hint as NSString).draw(at: CGPoint(x: badgeRect.minX + 10, y: badgeRect.minY + 8), withAttributes: hintAttrs)
    }
}

// MARK: - Screen Video & GIF Exporter

final class GifConverter {
    static func findFFmpeg() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        for p in candidates {
            if FileManager.default.fileExists(atPath: p) {
                return p
            }
        }
        return nil
    }

    static func convert(movUrl: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        let outUrl = movUrl.deletingPathExtension().appendingPathExtension("gif")

        if let ffmpeg = findFFmpeg() {
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: ffmpeg)
                task.arguments = [
                    "-y",
                    "-i", movUrl.path,
                    "-vf", "fps=15,scale=flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=128:stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3",
                    outUrl.path
                ]
                do {
                    try task.run()
                    task.waitUntilExit()
                    if task.terminationStatus == 0 && FileManager.default.fileExists(atPath: outUrl.path) {
                        DispatchQueue.main.async {
                            completion(.success(outUrl))
                        }
                    } else {
                        convertNative(movUrl: movUrl, outUrl: outUrl, completion: completion)
                    }
                } catch {
                    convertNative(movUrl: movUrl, outUrl: outUrl, completion: completion)
                }
            }
        } else {
            convertNative(movUrl: movUrl, outUrl: outUrl, completion: completion)
        }
    }

    static func convertNative(movUrl: URL, outUrl: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let asset = AVURLAsset(url: movUrl)
            let duration = CMTimeGetSeconds(asset.duration)
            guard duration > 0 && !duration.isNaN else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "xChup", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video duration is invalid"])))
                }
                return
            }

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 800, height: 800)

            let fps: Double = 12.0
            let frameCount = min(Int(duration * fps), 180)
            guard frameCount > 0 else { return }

            guard let destination = CGImageDestinationCreateWithURL(outUrl as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "xChup", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize GIF destination"])))
                }
                return
            }

            let frameDelay = 1.0 / fps
            let frameProps = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: frameDelay,
                    kCGImagePropertyGIFUnclampedDelayTime: frameDelay
                ]
            ] as CFDictionary

            let gifProps = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFLoopCount: 0
                ]
            ] as CFDictionary
            CGImageDestinationSetProperties(destination, gifProps)

            for i in 0..<frameCount {
                let time = CMTime(seconds: Double(i) * frameDelay, preferredTimescale: 600)
                if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                    CGImageDestinationAddImage(destination, cgImage, frameProps)
                }
            }

            if CGImageDestinationFinalize(destination) && FileManager.default.fileExists(atPath: outUrl.path) {
                DispatchQueue.main.async {
                    completion(.success(outUrl))
                }
            } else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "xChup", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to write GIF file"])))
                }
            }
        }
    }
}

final class VideoCompletedController: NSObject {
    static let shared = VideoCompletedController()
    private var window: NSWindow?
    private var videoPath: String = ""
    private var dismissWorkItem: DispatchWorkItem?

    func show(videoPath: String) {
        self.videoPath = videoPath
        guard let screen = NSScreen.main, FileManager.default.fileExists(atPath: videoPath) else { return }

        let cardW: CGFloat = 310
        let cardH: CGFloat = 115
        let margin: CGFloat = 20
        let originX = screen.visibleFrame.maxX - cardW - margin
        let originY = screen.visibleFrame.minY + margin

        let win = NSWindow(
            contentRect: NSRect(x: originX, y: originY, width: cardW, height: cardH),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .floating
        win.hasShadow = true

        let cardView = VideoCardView(frame: NSRect(x: 0, y: 0, width: cardW, height: cardH), videoPath: videoPath)
        win.contentView = cardView
        win.makeKeyAndOrderFront(nil)
        self.window = win

        let work = DispatchWorkItem { [weak self] in
            self?.close()
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: work)
    }

    func cancelAutoDismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}

final class VideoCardView: NSView, NSDraggingSource {
    private let videoPath: String
    private var gifButton: NSButton!
    private var playButton: NSButton!
    private var folderButton: NSButton!
    private var closeButton: NSButton!
    private var thumbnailImage: NSImage?
    private var generatedGifUrl: URL?

    init(frame: NSRect, videoPath: String) {
        self.videoPath = videoPath
        super.init(frame: frame)

        // Generate thumbnail
        let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        if let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil) {
            self.thumbnailImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }

        // Close button (X)
        closeButton = NSButton(title: "✕", target: self, action: #selector(actionClose))
        closeButton.isBordered = false
        closeButton.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        closeButton.contentTintColor = NSColor(calibratedWhite: 0.6, alpha: 1.0)
        closeButton.frame = NSRect(x: bounds.width - 24, y: bounds.height - 24, width: 18, height: 18)
        addSubview(closeButton)

        // GIF button
        gifButton = NSButton(title: "🎞 Xuất GIF", target: self, action: #selector(actionExportGif))
        gifButton.bezelStyle = .rounded
        gifButton.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        gifButton.frame = NSRect(x: 104, y: 12, width: 90, height: 26)
        addSubview(gifButton)

        // Play button
        playButton = NSButton(title: "▶️ Xem", target: self, action: #selector(actionPlayVideo))
        playButton.bezelStyle = .rounded
        playButton.font = NSFont.systemFont(ofSize: 11)
        playButton.frame = NSRect(x: 198, y: 12, width: 50, height: 26)
        addSubview(playButton)

        // Folder button
        folderButton = NSButton(title: "📁", target: self, action: #selector(actionOpenFolder))
        folderButton.bezelStyle = .rounded
        folderButton.font = NSFont.systemFont(ofSize: 11)
        folderButton.frame = NSRect(x: 252, y: 12, width: 44, height: 26)
        addSubview(folderButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func actionClose() {
        VideoCompletedController.shared.close()
    }

    @objc private func actionPlayVideo() {
        NSWorkspace.shared.open(URL(fileURLWithPath: videoPath))
    }

    @objc private func actionOpenFolder() {
        let capturesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/snip/captures")
        NSWorkspace.shared.open(capturesDir)
    }

    @objc private func actionExportGif() {
        VideoCompletedController.shared.cancelAutoDismiss()
        gifButton.isEnabled = false
        gifButton.title = "⏳ Đang xuất..."

        GifConverter.convert(movUrl: URL(fileURLWithPath: videoPath)) { [weak self] res in
            guard let self = self else { return }
            self.gifButton.isEnabled = true
            switch res {
            case .success(let gifUrl):
                self.generatedGifUrl = gifUrl
                self.gifButton.title = "✓ Đã copy GIF"
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([gifUrl as NSURL])

                NSSound(named: "Glass")?.play()
                showNotification(
                    title: "xChup • Đã xuất ảnh GIF",
                    text: "File GIF đã được lưu và sao chép vào Clipboard. Bạn có thể dán (⌘V) ngay."
                )
            case .failure(let err):
                self.gifButton.title = "Lỗi xuất GIF"
                showNotification(
                    title: "xChup • Lỗi xuất GIF",
                    text: err.localizedDescription
                )
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Glass background card
        let bgPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 14, yRadius: 14)
        NSColor(calibratedWhite: 0.14, alpha: 0.94).setFill()
        bgPath.fill()
        NSColor(calibratedWhite: 0.35, alpha: 0.50).setStroke()
        bgPath.lineWidth = 1.0
        bgPath.stroke()

        // Draw video thumbnail box
        let thumbRect = NSRect(x: 14, y: 16, width: 80, height: 75)
        let thumbPath = NSBezierPath(roundedRect: thumbRect, xRadius: 8, yRadius: 8)

        if let thumb = thumbnailImage {
            thumbPath.addClip()
            thumb.draw(in: thumbRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        } else {
            NSColor(calibratedWhite: 0.22, alpha: 1.0).setFill()
            thumbPath.fill()
            let icon = "🎥"
            let iconAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26)]
            (icon as NSString).draw(at: NSPoint(x: thumbRect.midX - 14, y: thumbRect.midY - 16), withAttributes: iconAttrs)
        }

        // Draw title
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        ("🎥 Đã quay xong video" as NSString).draw(at: NSPoint(x: 104, y: 72), withAttributes: titleAttrs)

        // Draw subtitle
        let fileName = URL(fileURLWithPath: videoPath).lastPathComponent
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: NSColor(calibratedWhite: 0.70, alpha: 1.0)
        ]
        (fileName as NSString).draw(at: NSPoint(x: 104, y: 52), withAttributes: subAttrs)
    }

    override func mouseDown(with event: NSEvent) {
        let fileToDrag = generatedGifUrl?.path ?? videoPath
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(URL(fileURLWithPath: fileToDrag).absoluteString, forType: .fileURL)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let dragBounds = NSRect(x: 14, y: 16, width: 80, height: 75)
        draggingItem.setDraggingFrame(dragBounds, contents: thumbnailImage ?? NSImage())

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .copy
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

// MARK: - Global HotKeys & Shortcut Preferences

struct ShortcutItem: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt32

    var displayString: String {
        return stringForCarbonModifiers(modifiers) + stringForKeyCode(keyCode)
    }
}

func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var mods: UInt32 = 0
    if flags.contains(.command) { mods |= UInt32(cmdKey) }
    if flags.contains(.shift) { mods |= UInt32(shiftKey) }
    if flags.contains(.option) { mods |= UInt32(optionKey) }
    if flags.contains(.control) { mods |= UInt32(controlKey) }
    return mods
}

func nsModifierFlags(from carbonMods: UInt32) -> NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if (carbonMods & UInt32(cmdKey)) != 0 { flags.insert(.command) }
    if (carbonMods & UInt32(shiftKey)) != 0 { flags.insert(.shift) }
    if (carbonMods & UInt32(optionKey)) != 0 { flags.insert(.option) }
    if (carbonMods & UInt32(controlKey)) != 0 { flags.insert(.control) }
    return flags
}

func stringForCarbonModifiers(_ mods: UInt32) -> String {
    var str = ""
    if (mods & UInt32(controlKey)) != 0 { str += "⌃" }
    if (mods & UInt32(optionKey)) != 0 { str += "⌥" }
    if (mods & UInt32(shiftKey)) != 0 { str += "⇧" }
    if (mods & UInt32(cmdKey)) != 0 { str += "⌘" }
    return str
}

func stringForKeyCode(_ keyCode: UInt16) -> String {
    switch Int(keyCode) {
    case kVK_ANSI_A: return "A"
    case kVK_ANSI_B: return "B"
    case kVK_ANSI_C: return "C"
    case kVK_ANSI_D: return "D"
    case kVK_ANSI_E: return "E"
    case kVK_ANSI_F: return "F"
    case kVK_ANSI_G: return "G"
    case kVK_ANSI_H: return "H"
    case kVK_ANSI_I: return "I"
    case kVK_ANSI_J: return "J"
    case kVK_ANSI_K: return "K"
    case kVK_ANSI_L: return "L"
    case kVK_ANSI_M: return "M"
    case kVK_ANSI_N: return "N"
    case kVK_ANSI_O: return "O"
    case kVK_ANSI_P: return "P"
    case kVK_ANSI_Q: return "Q"
    case kVK_ANSI_R: return "R"
    case kVK_ANSI_S: return "S"
    case kVK_ANSI_T: return "T"
    case kVK_ANSI_U: return "U"
    case kVK_ANSI_V: return "V"
    case kVK_ANSI_W: return "W"
    case kVK_ANSI_X: return "X"
    case kVK_ANSI_Y: return "Y"
    case kVK_ANSI_Z: return "Z"
    case kVK_ANSI_0: return "0"
    case kVK_ANSI_1: return "1"
    case kVK_ANSI_2: return "2"
    case kVK_ANSI_3: return "3"
    case kVK_ANSI_4: return "4"
    case kVK_ANSI_5: return "5"
    case kVK_ANSI_6: return "6"
    case kVK_ANSI_7: return "7"
    case kVK_ANSI_8: return "8"
    case kVK_ANSI_9: return "9"
    case kVK_ANSI_Equal: return "="
    case kVK_ANSI_Minus: return "-"
    case kVK_ANSI_RightBracket: return "]"
    case kVK_ANSI_LeftBracket: return "["
    case kVK_ANSI_Quote: return "'"
    case kVK_ANSI_Semicolon: return ";"
    case kVK_ANSI_Backslash: return "\\"
    case kVK_ANSI_Comma: return ","
    case kVK_ANSI_Slash: return "/"
    case kVK_ANSI_Period: return "."
    case kVK_ANSI_Grave: return "`"
    case kVK_Space: return "Space"
    case kVK_Return: return "↩"
    case kVK_Tab: return "⇥"
    case kVK_F1: return "F1"
    case kVK_F2: return "F2"
    case kVK_F3: return "F3"
    case kVK_F4: return "F4"
    case kVK_F5: return "F5"
    case kVK_F6: return "F6"
    case kVK_F7: return "F7"
    case kVK_F8: return "F8"
    case kVK_F9: return "F9"
    case kVK_F10: return "F10"
    case kVK_F11: return "F11"
    case kVK_F12: return "F12"
    default:
        return "?"
    }
}

func keyEquivalentString(_ item: ShortcutItem) -> String {
    let keyStr = stringForKeyCode(item.keyCode)
    if keyStr.count == 1 {
        return keyStr.lowercased()
    }
    return ""
}

struct ShortcutSettings: Codable {
    var area: ShortcutItem
    var fullscreen: ShortcutItem
    var ocr: ShortcutItem
    var pin: ShortcutItem
    var record: ShortcutItem
    var color: ShortcutItem

    enum CodingKeys: String, CodingKey {
        case area, fullscreen, ocr, pin, record, color
    }

    init(area: ShortcutItem, fullscreen: ShortcutItem, ocr: ShortcutItem, pin: ShortcutItem, record: ShortcutItem, color: ShortcutItem) {
        self.area = area
        self.fullscreen = fullscreen
        self.ocr = ocr
        self.pin = pin
        self.record = record
        self.color = color
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.area = try container.decode(ShortcutItem.self, forKey: .area)
        self.fullscreen = try container.decode(ShortcutItem.self, forKey: .fullscreen)
        self.ocr = try container.decode(ShortcutItem.self, forKey: .ocr)
        self.pin = try container.decode(ShortcutItem.self, forKey: .pin)
        self.record = try container.decode(ShortcutItem.self, forKey: .record)
        self.color = try container.decodeIfPresent(ShortcutItem.self, forKey: .color) ?? ShortcutItem(keyCode: UInt16(kVK_ANSI_C), modifiers: UInt32(controlKey | shiftKey))
    }

    static var defaultSettings: ShortcutSettings {
        let cmdShift = UInt32(cmdKey | shiftKey)
        let ctrlShift = UInt32(controlKey | shiftKey)
        return ShortcutSettings(
            area: ShortcutItem(keyCode: UInt16(kVK_ANSI_4), modifiers: cmdShift),
            fullscreen: ShortcutItem(keyCode: UInt16(kVK_ANSI_3), modifiers: cmdShift),
            ocr: ShortcutItem(keyCode: UInt16(kVK_ANSI_6), modifiers: cmdShift),
            pin: ShortcutItem(keyCode: UInt16(kVK_ANSI_5), modifiers: cmdShift),
            record: ShortcutItem(keyCode: UInt16(kVK_ANSI_7), modifiers: cmdShift),
            color: ShortcutItem(keyCode: UInt16(kVK_ANSI_C), modifiers: ctrlShift)
        )
    }

    static func load() -> ShortcutSettings {
        if let data = UserDefaults.standard.data(forKey: "xChup_Shortcuts"),
           let decoded = try? JSONDecoder().decode(ShortcutSettings.self, from: data) {
            return decoded
        }
        return defaultSettings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "xChup_Shortcuts")
        }
    }
}

final class KeyRecorderButton: NSButton {
    var shortcut: ShortcutItem {
        didSet {
            updateTitle()
        }
    }
    private(set) var isRecording = false
    var onShortcutChanged: ((ShortcutItem) -> Void)?

    init(shortcut: ShortcutItem) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(buttonClicked)
        font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func buttonClicked() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        ShortcutPreferencesWindowController.shared.cancelAllRecordings(except: self)
        isRecording = true
        title = "Nhấn tổ hợp phím..."
        window?.makeFirstResponder(self)
    }

    func stopRecording() {
        isRecording = false
        updateTitle()
    }

    private func updateTitle() {
        title = shortcut.displayString.isEmpty ? "Chưa đặt" : shortcut.displayString
    }

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            isRecording = false
            updateTitle()
        }
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isRecording {
            handleKeyEvent(event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isRecording {
            handleKeyEvent(event)
        } else {
            super.keyDown(with: event)
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let keyCode = event.keyCode
        if keyCode == 53 { // Escape
            stopRecording()
            return
        }

        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let carbonMods = carbonModifiers(from: flags)

        guard carbonMods != 0 else {
            NSSound.beep()
            return
        }

        let newItem = ShortcutItem(keyCode: keyCode, modifiers: carbonMods)
        self.shortcut = newItem
        stopRecording()
        onShortcutChanged?(newItem)
    }
}

final class ShortcutPreferencesWindowController: NSWindowController {
    static let shared = ShortcutPreferencesWindowController()

    private var areaButton: KeyRecorderButton!
    private var fullButton: KeyRecorderButton!
    private var ocrButton: KeyRecorderButton!
    private var pinButton: KeyRecorderButton!
    private var recordButton: KeyRecorderButton!
    private var colorButton: KeyRecorderButton!

    private var buttons: [KeyRecorderButton] {
        return [areaButton, fullButton, ocrButton, pinButton, recordButton, colorButton].compactMap { $0 }
    }

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 490, height: 490),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Cài đặt phím tắt • xChup"
        win.center()
        win.isReleasedWhenClosed = false
        super.init(window: win)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        refreshUI()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func cancelAllRecordings(except current: KeyRecorderButton?) {
        for btn in buttons where btn != current {
            if btn.isRecording {
                btn.stopRecording()
            }
        }
    }

    private func setupUI() {
        guard let win = window else { return }
        let root = NSView(frame: win.contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        win.contentView = root

        let titleLabel = NSTextField(labelWithString: "Cài đặt phím tắt toàn cầu")
        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(titleLabel)

        let descLabel = NSTextField(labelWithString: "Nhấp vào ô phím tắt và nhấn tổ hợp phím mong muốn (ESC để hủy).")
        descLabel.font = NSFont.systemFont(ofSize: 12)
        descLabel.textColor = .secondaryLabelColor
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(descLabel)

        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 10
        card.borderWidth = 1
        card.borderColor = .separatorColor
        card.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6)
        card.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(card)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fillEqually
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView = stack

        let settings = ShortcutSettings.load()

        areaButton = KeyRecorderButton(shortcut: settings.area)
        areaButton.onShortcutChanged = { [weak self] item in
            self?.updateShortcut(\.area, to: item)
        }

        fullButton = KeyRecorderButton(shortcut: settings.fullscreen)
        fullButton.onShortcutChanged = { [weak self] item in
            self?.updateShortcut(\.fullscreen, to: item)
        }

        ocrButton = KeyRecorderButton(shortcut: settings.ocr)
        ocrButton.onShortcutChanged = { [weak self] item in
            self?.updateShortcut(\.ocr, to: item)
        }

        pinButton = KeyRecorderButton(shortcut: settings.pin)
        pinButton.onShortcutChanged = { [weak self] item in
            self?.updateShortcut(\.pin, to: item)
        }

        recordButton = KeyRecorderButton(shortcut: settings.record)
        recordButton.onShortcutChanged = { [weak self] item in
            self?.updateShortcut(\.record, to: item)
        }

        colorButton = KeyRecorderButton(shortcut: settings.color)
        colorButton.onShortcutChanged = { [weak self] item in
            self?.updateShortcut(\.color, to: item)
        }

        stack.addArrangedSubview(makeRow(title: "Chụp vùng (Area)", subtitle: "Kéo chuột chọn vùng cần chụp", button: areaButton))
        stack.addArrangedSubview(makeRow(title: "Chụp toàn màn hình (Fullscreen)", subtitle: "Chụp tức thì toàn bộ màn hình", button: fullButton))
        stack.addArrangedSubview(makeRow(title: "Nhận diện chữ & QR (OCR)", subtitle: "Trích xuất văn bản vào clipboard", button: ocrButton))
        stack.addArrangedSubview(makeRow(title: "Ghim ảnh nổi (Pin Image)", subtitle: "Ghim ảnh chụp nổi trên màn hình", button: pinButton))
        stack.addArrangedSubview(makeRow(title: "Quay màn hình (Record)", subtitle: "Bật / Dừng quay video màn hình", button: recordButton))
        stack.addArrangedSubview(makeRow(title: "Chấm màu màn hình (Color Eyedropper)", subtitle: "Kính lúp phóng to pixel & sao chép mã màu", button: colorButton))

        let resetBtn = NSButton(title: "↺ Đặt lại mặc định", target: self, action: #selector(actionReset))
        resetBtn.bezelStyle = .rounded
        resetBtn.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(resetBtn)

        let closeBtn = NSButton(title: "Đóng", target: self, action: #selector(actionClose))
        closeBtn.bezelStyle = .rounded
        closeBtn.keyEquivalent = "\r"
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(closeBtn)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            descLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            descLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            descLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            card.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 14),
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),

            resetBtn.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            resetBtn.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            closeBtn.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            closeBtn.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            closeBtn.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 16)
        ])
    }

    private func makeRow(title: String, subtitle: String, button: NSButton) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let tLabel = NSTextField(labelWithString: title)
        tLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        tLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(tLabel)

        let sLabel = NSTextField(labelWithString: subtitle)
        sLabel.font = NSFont.systemFont(ofSize: 11)
        sLabel.textColor = .secondaryLabelColor
        sLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(sLabel)

        button.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(button)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 44),

            tLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 4),
            tLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),

            sLabel.topAnchor.constraint(equalTo: tLabel.bottomAnchor, constant: 2),
            sLabel.leadingAnchor.constraint(equalTo: tLabel.leadingAnchor),

            button.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4),
            button.widthAnchor.constraint(equalToConstant: 130),
            button.heightAnchor.constraint(equalToConstant: 28),

            button.leadingAnchor.constraint(greaterThanOrEqualTo: tLabel.trailingAnchor, constant: 10)
        ])
        return row
    }

    private func updateShortcut(_ keyPath: WritableKeyPath<ShortcutSettings, ShortcutItem>, to item: ShortcutItem) {
        var settings = ShortcutSettings.load()

        let all: [(String, ShortcutItem)] = [
            ("Chụp vùng", settings.area),
            ("Chụp toàn màn hình", settings.fullscreen),
            ("Nhận diện chữ & QR", settings.ocr),
            ("Ghim ảnh nổi", settings.pin),
            ("Quay màn hình", settings.record),
            ("Chấm màu màn hình", settings.color)
        ]

        for (name, existing) in all {
            if existing == item && settings[keyPath: keyPath] != existing {
                NSSound.beep()
                let alert = NSAlert()
                alert.messageText = "Phím tắt bị trùng"
                alert.informativeText = "Tổ hợp phím \(item.displayString) đang được sử dụng cho chức năng '\(name)'. Vui lòng chọn tổ hợp phím khác."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Đã hiểu")
                alert.runModal()
                refreshUI()
                return
            }
        }

        settings[keyPath: keyPath] = item
        settings.save()
        HotKeyManager.shared.reload()
        TrayController.shared.buildMenu()
        showNotification(title: "xChup", text: "Đã lưu phím tắt mới: \(item.displayString)")
    }

    func refreshUI() {
        let settings = ShortcutSettings.load()
        areaButton?.shortcut = settings.area
        fullButton?.shortcut = settings.fullscreen
        ocrButton?.shortcut = settings.ocr
        pinButton?.shortcut = settings.pin
        recordButton?.shortcut = settings.record
        colorButton?.shortcut = settings.color
    }

    @objc private func actionReset() {
        let def = ShortcutSettings.defaultSettings
        def.save()
        refreshUI()
        HotKeyManager.shared.reload()
        TrayController.shared.buildMenu()
        showNotification(title: "xChup", text: "Đã khôi phục phím tắt mặc định.")
    }

    @objc private func actionClose() {
        window?.close()
    }
}

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
        case color = 6
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

        reload()
    }

    func reload() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()

        let settings = ShortcutSettings.load()
        registerItem(settings.area, id: .area)
        registerItem(settings.fullscreen, id: .fullscreen)
        registerItem(settings.ocr, id: .ocr)
        registerItem(settings.pin, id: .pin)
        registerItem(settings.record, id: .record)
        registerItem(settings.color, id: .color)

        // Đăng ký bổ sung Control+Shift nếu dùng mặc định Command+Shift
        let cmdShift = UInt32(cmdKey | shiftKey)
        let ctrlShift = UInt32(controlKey | shiftKey)
        if settings.area.modifiers == cmdShift {
            registerKey(keyCode: Int(settings.area.keyCode), modifiers: ctrlShift, id: .area)
        }
        if settings.fullscreen.modifiers == cmdShift {
            registerKey(keyCode: Int(settings.fullscreen.keyCode), modifiers: ctrlShift, id: .fullscreen)
        }
        if settings.ocr.modifiers == cmdShift {
            registerKey(keyCode: Int(settings.ocr.keyCode), modifiers: ctrlShift, id: .ocr)
        }
        if settings.pin.modifiers == cmdShift {
            registerKey(keyCode: Int(settings.pin.keyCode), modifiers: ctrlShift, id: .pin)
        }
        if settings.record.modifiers == cmdShift {
            registerKey(keyCode: Int(settings.record.keyCode), modifiers: ctrlShift, id: .record)
        }
    }

    private func registerItem(_ item: ShortcutItem, id: Action) {
        registerKey(keyCode: Int(item.keyCode), modifiers: item.modifiers, id: id)
    }

    private func registerKey(keyCode: Int, modifiers: UInt32, id: Action) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: 0x534E4950, id: id.rawValue)
        let err = RegisterEventHotKey(UInt32(keyCode), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if err == noErr, let r = ref {
            hotKeyRefs.append(r)
        }
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

var daemonProcess: Process?

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
            proc.environment = ProcessInfo.processInfo.environment
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            daemonProcess = proc
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

// MARK: - Auto Updater (GitHub Releases)

final class UpdateManager {
    static let shared = UpdateManager()
    let repo = "trinhhaox/x-chup"
    var currentVersion: String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    struct ReleaseInfo {
        let version: String
        let title: String
        let notes: String
        let zipURL: URL
    }

    var availableUpdate: ReleaseInfo?

    static func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        let clean1 = v1.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let clean2 = v2.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let p1 = clean1.split(separator: ".").compactMap { Int($0) }
        let p2 = clean2.split(separator: ".").compactMap { Int($0) }
        for (a, b) in zip(p1, p2) {
            if a > b { return true }
            if a < b { return false }
        }
        return p1.count > p2.count
    }

    func checkForUpdates(silent: Bool, completion: ((Bool) -> Void)? = nil) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("xChup-AutoUpdater", forHTTPHeaderField: "User-Agent")

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                if !silent {
                    DispatchQueue.main.async {
                        self.showErrorAlert("Không thể kiểm tra cập nhật. Vui lòng kiểm tra lại kết nối mạng.")
                    }
                }
                completion?(false)
                return
            }

            let releaseTitle = json["name"] as? String ?? tagName
            let notes = json["body"] as? String ?? ""
            let assets = json["assets"] as? [[String: Any]] ?? []

            guard let zipAsset = assets.first(where: {
                ($0["name"] as? String)?.contains(".zip") == true
            }),
            let downloadStr = zipAsset["browser_download_url"] as? String,
            let downloadURL = URL(string: downloadStr) else {
                if !silent {
                    DispatchQueue.main.async {
                        self.showErrorAlert("Không tìm thấy gói cập nhật tương thích trên GitHub.")
                    }
                }
                completion?(false)
                return
            }

            let release = ReleaseInfo(
                version: tagName,
                title: releaseTitle,
                notes: notes,
                zipURL: downloadURL
            )

            let hasNewVersion = Self.isVersion(tagName, newerThan: self.currentVersion)

            DispatchQueue.main.async {
                if hasNewVersion {
                    self.availableUpdate = release
                    if !silent {
                        self.promptUpdate(release: release)
                    } else {
                        showNotification(
                            title: "xChup - Có bản cập nhật mới",
                            text: "Phiên bản \(release.version) đã sẵn sàng. Nhấp Menu Bar để cập nhật."
                        )
                    }
                } else if !silent {
                    self.showUpToDateAlert()
                }
                completion?(hasNewVersion)
            }
        }
        task.resume()
    }

    func promptUpdate(release: ReleaseInfo) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Có bản cập nhật mới: \(release.version)"
        alert.informativeText = "Phiên bản hiện tại: v\(currentVersion)\nPhiên bản mới nhất: \(release.version)\n\nNội dung cập nhật:\n\(release.notes)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Cập nhật ngay")
        alert.addButton(withTitle: "Để sau")

        if alert.runModal() == .alertFirstButtonReturn {
            self.downloadAndApplyUpdate(release: release)
        }
    }

    private func showUpToDateAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Bạn đang dùng phiên bản mới nhất"
        alert.informativeText = "xChup hiện đang ở phiên bản v\(currentVersion)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Đã hiểu")
        alert.runModal()
    }

    private func showErrorAlert(_ msg: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Kiểm tra cập nhật"
        alert.informativeText = msg
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Đóng")
        alert.runModal()
    }

    func downloadAndApplyUpdate(release: ReleaseInfo) {
        showNotification(title: "xChup Update", text: "Đang tải bản cập nhật \(release.version)...")

        let session = URLSession.shared
        let downloadTask = session.downloadTask(with: release.zipURL) { tempURL, response, error in
            guard let tempURL = tempURL, error == nil else {
                DispatchQueue.main.async {
                    self.showErrorAlert("Tải bản cập nhật thất bại: \(error?.localizedDescription ?? "Lỗi không xác định")")
                }
                return
            }

            let updateZip = "/tmp/xChup_update.zip"
            let extractedDir = "/tmp/xChup_extracted"

            try? FileManager.default.removeItem(atPath: updateZip)
            try? FileManager.default.removeItem(atPath: extractedDir)
            try? FileManager.default.moveItem(at: tempURL, to: URL(fileURLWithPath: updateZip))
            try? FileManager.default.createDirectory(atPath: extractedDir, withIntermediateDirectories: true)

            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", updateZip, extractedDir]
            try? ditto.run()
            ditto.waitUntilExit()

            let newApp = "\(extractedDir)/xChup.app"
            guard FileManager.default.fileExists(atPath: newApp) else {
                DispatchQueue.main.async {
                    self.showErrorAlert("Gói cập nhật không hợp lệ.")
                }
                return
            }

            let myPid = ProcessInfo.processInfo.processIdentifier
            let script = """
            while kill -0 \(myPid) 2>/dev/null; do sleep 0.2; done
            rm -rf "/Applications/xChup.app"
            mv "\(newApp)" "/Applications/xChup.app"
            xattr -cr "/Applications/xChup.app" 2>/dev/null || true
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/xChup.app"
            open "/Applications/xChup.app"
            rm -rf "\(extractedDir)" "\(updateZip)"
            """

            let scriptURL = URL(fileURLWithPath: "/tmp/apply_xchup_update.sh")
            try? script.write(to: scriptURL, atomically: true, encoding: .utf8)

            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["+x", scriptURL.path]
            try? chmod.run()
            chmod.waitUntilExit()

            let bg = Process()
            bg.executableURL = URL(fileURLWithPath: "/bin/sh")
            bg.arguments = [scriptURL.path]
            try? bg.run()

            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
        downloadTask.resume()
    }
}

final class TrayController: NSObject, NSMenuDelegate {
    static let shared = TrayController()
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private let recentMenu = NSMenu()
    private var isRecording = false
    private var recordProcess: Process?
    private var currentRecordingPath: String?

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

        // Background check for updates (silent)
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 3.0) { [weak self] in
            UpdateManager.shared.checkForUpdates(silent: true) { hasNewVersion in
                if hasNewVersion {
                    DispatchQueue.main.async {
                        self?.buildMenu()
                    }
                }
            }
        }
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

    func buildMenu() {
        menu.removeAllItems()

        let titleItem = NSMenuItem(title: "xChup • CleanShot X", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())

        let settings = ShortcutSettings.load()

        let areaItem = NSMenuItem(title: "Chụp vùng (Area)", action: #selector(actionArea), keyEquivalent: keyEquivalentString(settings.area))
        areaItem.keyEquivalentModifierMask = nsModifierFlags(from: settings.area.modifiers)
        areaItem.target = self
        menu.addItem(areaItem)

        let fullItem = NSMenuItem(title: "Chụp toàn màn hình (Fullscreen)", action: #selector(actionFullscreen), keyEquivalent: keyEquivalentString(settings.fullscreen))
        fullItem.keyEquivalentModifierMask = nsModifierFlags(from: settings.fullscreen.modifiers)
        fullItem.target = self
        menu.addItem(fullItem)

        let ocrItem = NSMenuItem(title: "Nhận diện chữ & QR (OCR)", action: #selector(actionOCR), keyEquivalent: keyEquivalentString(settings.ocr))
        ocrItem.keyEquivalentModifierMask = nsModifierFlags(from: settings.ocr.modifiers)
        ocrItem.target = self
        menu.addItem(ocrItem)

        let colorItem = NSMenuItem(title: "🔍 Chấm màu màn hình (Color Eyedropper)", action: #selector(actionColorPicker), keyEquivalent: keyEquivalentString(settings.color))
        colorItem.keyEquivalentModifierMask = nsModifierFlags(from: settings.color.modifiers)
        colorItem.target = self
        menu.addItem(colorItem)

        let pinItem = NSMenuItem(title: "Ghim ảnh nổi (Pin Image)", action: #selector(actionPin), keyEquivalent: keyEquivalentString(settings.pin))
        pinItem.keyEquivalentModifierMask = nsModifierFlags(from: settings.pin.modifiers)
        pinItem.target = self
        menu.addItem(pinItem)

        let recordItem = NSMenuItem(
            title: isRecording ? "⏹ Dừng quay màn hình (Stop Recording)" : "🎥 Quay màn hình (Record Screen)",
            action: #selector(actionToggleRecord),
            keyEquivalent: keyEquivalentString(settings.record)
        )
        recordItem.keyEquivalentModifierMask = nsModifierFlags(from: settings.record.modifiers)
        recordItem.target = self
        menu.addItem(recordItem)

        menu.addItem(NSMenuItem.separator())

        let annotateRecentItem = NSMenuItem(title: "✏️ Chú thích ảnh gần đây (Annotate)...", action: #selector(actionAnnotateRecent), keyEquivalent: "")
        annotateRecentItem.target = self
        menu.addItem(annotateRecentItem)

        let gifRecentItem = NSMenuItem(title: "🎞 Chuyển video gần đây thành GIF...", action: #selector(actionConvertRecentVideoToGif), keyEquivalent: "")
        gifRecentItem.target = self
        menu.addItem(gifRecentItem)

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

        let shortcutsItem = NSMenuItem(title: "Cài đặt phím tắt...", action: #selector(actionOpenShortcuts), keyEquivalent: ",")
        shortcutsItem.keyEquivalentModifierMask = [.command]
        shortcutsItem.target = self
        menu.addItem(shortcutsItem)

        let guideItem = NSMenuItem(title: "Phím tắt & Hướng dẫn", action: #selector(actionShowGuide), keyEquivalent: "")
        guideItem.target = self
        menu.addItem(guideItem)

        menu.addItem(NSMenuItem.separator())

        if let update = UpdateManager.shared.availableUpdate {
            let updateItem = NSMenuItem(
                title: "🔴 Có bản cập nhật mới (\(update.version))...",
                action: #selector(actionCheckUpdates),
                keyEquivalent: ""
            )
            updateItem.target = self
            menu.addItem(updateItem)
        } else {
            let updateItem = NSMenuItem(
                title: "Kiểm tra cập nhật...",
                action: #selector(actionCheckUpdates),
                keyEquivalent: ""
            )
            updateItem.target = self
            menu.addItem(updateItem)
        }

        let quitItem = NSMenuItem(title: "Thoát xChup", action: #selector(actionQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc func actionCheckUpdates() {
        if let update = UpdateManager.shared.availableUpdate {
            UpdateManager.shared.promptUpdate(release: update)
        } else {
            UpdateManager.shared.checkForUpdates(silent: false) { [weak self] hasNew in
                if hasNew {
                    self?.buildMenu()
                }
            }
        }
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

    private func copyImageToClipboard(filePath: String) {
        let url = URL(fileURLWithPath: filePath)
        let pb = NSPasteboard.general
        pb.clearContents()
        if let img = NSImage(contentsOf: url) {
            pb.writeObjects([img, url as NSURL])
        }
        if let data = try? Data(contentsOf: url) {
            pb.setData(data, forType: NSPasteboard.PasteboardType("public.png"))
        }
    }

    @objc func actionArea() {
        if let del = NSApp.delegate as? AppDelegate, !del.checkScreenCapturePermission(prompt: true) {
            return
        }
        let saveDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Screenshots")
        try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let filename = "Capture-\(formatter.string(from: Date())).png"
        let filePath = saveDir.appendingPathComponent(filename).path

        // Chờ 150ms để NSMenu đóng mượt mà trước khi mở Overlay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            OverlayController.shared.show(outputPath: filePath) { path, rect in
                self?.copyImageToClipboard(filePath: path)
                DispatchQueue.main.async {
                    QuickAccessController.shared.show(imagePath: path)
                }
            }
        }
    }

    @objc func actionFullscreen() {
        if let del = NSApp.delegate as? AppDelegate, !del.checkScreenCapturePermission(prompt: true) {
            return
        }
        let saveDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Screenshots")
        try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let filename = "Capture-\(formatter.string(from: Date())).png"
        let filePath = saveDir.appendingPathComponent(filename).path

        // Chờ 150ms để NSMenu đóng mượt mà trước khi chụp toàn màn hình
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", filePath]
            try? task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                self?.copyImageToClipboard(filePath: filePath)
                DispatchQueue.main.async {
                    QuickAccessController.shared.show(imagePath: filePath)
                }
            } else {
                showNotification(title: "xChup Lỗi", text: "Không thể chụp màn hình. Vui lòng kiểm tra quyền Ghi màn hình.")
            }
        }
    }

    @objc func actionOCR() {
        if let del = NSApp.delegate as? AppDelegate, !del.checkScreenCapturePermission(prompt: true) {
            return
        }
        let tempPath = "/tmp/xchup_ocr_\(ProcessInfo.processInfo.processIdentifier).png"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            OverlayController.shared.show(outputPath: tempPath) { path, rect in
                let text = OCRController.shared.recognize(imagePath: path)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                showNotification(title: "xChup OCR", text: text.isEmpty ? "Không tìm thấy văn bản" : "Đã sao chép: \(text.prefix(60))...")
                try? FileManager.default.removeItem(atPath: path)
            }
        }
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
        currentRecordingPath = outputPath
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
        let videoPath = currentRecordingPath
        proc.interrupt()
        recordProcess = nil
        isRecording = false
        currentRecordingPath = nil
        updateButtonIcon()
        buildMenu()

        if let path = videoPath, FileManager.default.fileExists(atPath: path) {
            VideoCompletedController.shared.show(videoPath: path)
        } else {
            showNotification(
                title: "xChup - Đã dừng quay màn hình",
                text: "Video đã được lưu vào thư mục captures."
            )
        }
    }

    @objc func actionColorPicker() {
        ColorPickerWindowController.shared.show()
    }

    @objc func actionConvertRecentVideoToGif() {
        let capturesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/snip/captures")
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: capturesDir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else {
            showNotification(title: "xChup", text: "Chưa có video nào trong thư mục lưu trữ.")
            return
        }

        let videoFiles = files.filter { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) }
        let sorted = videoFiles.sorted {
            let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            return d1 > d2
        }

        guard let latest = sorted.first else {
            showNotification(title: "xChup", text: "Chưa có video nào gần đây để chuyển sang GIF.")
            return
        }

        VideoCompletedController.shared.show(videoPath: latest.path)
    }

    @objc func actionAnnotateRecent() {
        let capturesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/snip/captures")
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: capturesDir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else {
            showNotification(title: "xChup", text: "Chưa có ảnh chụp nào trong thư mục lưu trữ.")
            return
        }

        let imageFiles = files.filter { ["png", "jpg", "jpeg", "webp"].contains($0.pathExtension.lowercased()) }
        let sorted = imageFiles.sorted {
            let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            return d1 > d2
        }

        guard let latest = sorted.first else {
            showNotification(title: "xChup", text: "Chưa có ảnh chụp nào để chú thích.")
            return
        }

        AnnotationWindowController.shared.show(imagePath: latest.path)
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
        let settings = ShortcutSettings.load()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "xChup - CleanShot X for Mac"
        alert.informativeText = """
        Phím tắt toàn cầu (Global Shortcuts):
        • \(settings.area.displayString): Chụp vùng màn hình (Area Capture)
        • \(settings.fullscreen.displayString): Chụp toàn màn hình (Fullscreen)
        • \(settings.ocr.displayString): Nhận diện chữ & mã QR (OCR Text)
        • \(settings.color.displayString): Chấm màu màn hình (Color Eyedropper)
        • \(settings.pin.displayString): Ghim ảnh nổi lên màn hình (Pin Image)
        • \(settings.record.displayString): Bật / Dừng quay màn hình (Screen Record)

        Công cụ hỗ trợ Designer & Developer:
        • Kính lúp lấy mã màu (Eyedropper): Phóng to từng pixel, hiển thị tâm ngắm chính xác. Bấm Space để đổi định dạng (HEX / RGB / NSColor), Click để sao chép vào Clipboard.
        • Xuất video sang GIF: Sau khi dừng quay màn hình, Quick Card sẽ hiển thị nút '🎞 Xuất GIF' để chuyển video sang ảnh GIF sắc nét, tối ưu dung lượng dán vào GitHub/Slack.

        Bộ công cụ chú thích ảnh tức thì (Instant Annotation):
        • Quick Card sau khi chụp: Bấm '✏️ Sửa' hoặc nhấp đúp thumbnail để mở Editor.
        • Công cụ vẽ: Mũi tên (Arrow), Khung (Box), Làm mờ bảo mật (Blur Pixelate), Đánh số thứ tự tự tăng ① ② ③ (Step Counter), Bút vẽ tự do (Pen) & Chữ (Text).
        • Phím tắt Editor: ⌘Z (Undo), ⇧⌘Z (Redo), ⌘C (Sao chép), ⌘S (Lưu đè).

        Tính năng nâng cao:
        • Quick Access Card: Kéo thả file trực tiếp vào Telegram, Slack, VSCode.
        • Floating Pin: Cuộn chuột để chỉnh độ mờ (opacity), chuột phải để đóng.
        • Clean Desktop: Ẩn/Hiện icon rác trên màn hình nền.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Đã hiểu")
        alert.addButton(withTitle: "Cài đặt phím tắt...")
        if alert.runModal() == .alertSecondButtonReturn {
            actionOpenShortcuts()
        }
    }

    @objc func actionOpenShortcuts() {
        ShortcutPreferencesWindowController.shared.show()
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
        case .color:
            actionColorPicker()
        }
    }
}

// Start Cocoa Event Loop
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

