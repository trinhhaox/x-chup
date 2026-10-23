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
        case "update":
            runUpdate()
        case "settings", "shortcuts", "preferences":
            runShortcuts()
        case "annotate", "edit":
            guard args.count >= 3 else {
                fputs("Error: annotate requires an image file path\n", stderr)
                exit(1)
            }
            runAnnotate(imagePath: args[2])
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
        fputs("Usage: snip-ui <tray | update | settings | annotate <image-path> | overlay | card <image-path> | pin <image-path> | ocr <image-path>>\n", stderr)
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

    func runTray() {
        guard acquireSingleInstanceLock() else {
            fputs("xChup tray is already running.\n", stderr)
            exit(0)
        }
        NSApp.setActivationPolicy(.accessory)
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

    func runUpdate() {
        NSApp.setActivationPolicy(.accessory)
        UpdateManager.shared.checkForUpdates(silent: false)
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
    private var dismissWorkItem: DispatchWorkItem?

    func show(imagePath: String) {
        self.imagePath = imagePath
        guard let screen = NSScreen.main, let image = NSImage(contentsOfFile: imagePath) else {
            exit(1)
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

        let totalW = max(cardW, 200) + 16
        let totalH = cardH + 54

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
        let work = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        self.dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: work)
    }

    func openAnnotation() {
        dismissWorkItem?.cancel()
        window?.orderOut(nil)
        AnnotationWindowController.shared.show(imagePath: imagePath)
    }

    func openPin() {
        dismissWorkItem?.cancel()
        window?.orderOut(nil)
        PinController.shared.show(imagePath: imagePath)
    }

    func dismiss() {
        dismissWorkItem?.cancel()
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
    private var editButton: NSButton!
    private var pinButton: NSButton!

    init(frame: NSRect, image: NSImage, filePath: String) {
        self.image = image
        self.filePath = filePath
        super.init(frame: frame)

        editButton = NSButton(title: "✏️ Sửa", target: self, action: #selector(actionAnnotate))
        editButton.bezelStyle = .inline
        editButton.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        editButton.frame = NSRect(x: bounds.width - 128, y: 8, width: 56, height: 22)
        addSubview(editButton)

        pinButton = NSButton(title: "📌 Ghim", target: self, action: #selector(actionPin))
        pinButton.bezelStyle = .inline
        pinButton.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        pinButton.frame = NSRect(x: bounds.width - 66, y: 8, width: 56, height: 22)
        addSubview(pinButton)
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
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.75, alpha: 1.0)
        ]
        let info = "✓ Đã copy"
        (info as NSString).draw(at: NSPoint(x: 14, y: 12), withAttributes: titleAttrs)
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

    static var defaultSettings: ShortcutSettings {
        let cmdShift = UInt32(cmdKey | shiftKey)
        return ShortcutSettings(
            area: ShortcutItem(keyCode: UInt16(kVK_ANSI_4), modifiers: cmdShift),
            fullscreen: ShortcutItem(keyCode: UInt16(kVK_ANSI_3), modifiers: cmdShift),
            ocr: ShortcutItem(keyCode: UInt16(kVK_ANSI_6), modifiers: cmdShift),
            pin: ShortcutItem(keyCode: UInt16(kVK_ANSI_5), modifiers: cmdShift),
            record: ShortcutItem(keyCode: UInt16(kVK_ANSI_7), modifiers: cmdShift)
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

    private var buttons: [KeyRecorderButton] {
        return [areaButton, fullButton, ocrButton, pinButton, recordButton].compactMap { $0 }
    }

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 490, height: 440),
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

        stack.addArrangedSubview(makeRow(title: "Chụp vùng (Area)", subtitle: "Kéo chuột chọn vùng cần chụp", button: areaButton))
        stack.addArrangedSubview(makeRow(title: "Chụp toàn màn hình (Fullscreen)", subtitle: "Chụp tức thì toàn bộ màn hình", button: fullButton))
        stack.addArrangedSubview(makeRow(title: "Nhận diện chữ & QR (OCR)", subtitle: "Trích xuất văn bản vào clipboard", button: ocrButton))
        stack.addArrangedSubview(makeRow(title: "Ghim ảnh nổi (Pin Image)", subtitle: "Ghim ảnh chụp nổi trên màn hình", button: pinButton))
        stack.addArrangedSubview(makeRow(title: "Quay màn hình (Record)", subtitle: "Bật / Dừng quay video màn hình", button: recordButton))

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
            ("Quay màn hình", settings.record)
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
            codesign --force --deep --sign - "/Applications/xChup.app" 2>/dev/null || true
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
        • \(settings.pin.displayString): Ghim ảnh nổi lên màn hình (Pin Image)
        • \(settings.record.displayString): Bật / Dừng quay màn hình (Screen Record)

        Bộ công cụ chú thích ảnh tức thì (Instant Annotation):
        • Quick Card sau khi chụp: Bấm '✏️ Sửa' hoặc nhấp đúp ảnh thumbnail để mở Editor.
        • Công cụ vẽ: Mũi tên chỉ dẫn (Arrow), Khung chữ nhật (Box), Làm mờ che thông tin nhạy cảm (Blur Pixelate), Đánh số thứ tự tự tăng ① ② ③ (Step Counter), Bút vẽ tự do (Pen) & Chữ (Text).
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
        }
    }
}

// Start Cocoa Event Loop
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

