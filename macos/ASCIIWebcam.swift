import AppKit
import AVFoundation
import CoreText
import UniformTypeIdentifiers

// This native front end is self-contained. The original Python terminal app is
// still available; this renderer uses the same brightness-to-character idea.
struct PictureSettings {
    var columns = 150
    var color = true
    var mirror = true
    var invert = false
    var gamma = 0.85
    var edges = 0.35
    var rotation = 0
    var ramp = Array(" .:-=+*#%@".utf16)
}

struct ASCIIFrame {
    let columns: Int
    let rows: Int
    let characters: [UInt16]
    let colors: [SIMD3<Double>]
    var text: String {
        (0..<rows).map { String(utf16CodeUnits: Array(characters[($0 * columns)..<(($0 + 1) * columns)]), count: columns) }.joined(separator: "\n")
    }
}

enum Renderer {
    // The input is top-to-bottom BGRA, as supplied by AVCaptureVideoDataOutput.
    static func convert(_ bytes: UnsafePointer<UInt8>, width: Int, height: Int,
                        stride: Int, settings: PictureSettings) -> ASCIIFrame {
        let turned = settings.rotation % 2 != 0
        let aspect = Double(turned ? height : width) / Double(turned ? width : height)
        let cols = settings.columns
        let rows = max(1, Int((Double(cols) * 0.5 / aspect).rounded()))
        var colors = [SIMD3<Double>](repeating: .zero, count: cols * rows)
        var brightness = [Double](repeating: 0, count: cols * rows)
        for y in 0..<rows {
            for x in 0..<cols {
                var rgb = SIMD3<Double>.zero
                // Four samples per character reduce noise and aliasing.
                for dy in [0.25, 0.75] {
                    for dx in [0.25, 0.75] {
                        var u = (Double(x) + dx) / Double(cols)
                        let v = (Double(y) + dy) / Double(rows)
                        if settings.mirror { u = 1 - u }
                        let source: (Double, Double)
                        switch settings.rotation {
                        case 1: source = (v, 1 - u)
                        case 2: source = (1 - u, 1 - v)
                        case 3: source = (1 - v, u)
                        default: source = (u, v)
                        }
                        let sx = min(width - 1, max(0, Int(source.0 * Double(width))))
                        let sy = min(height - 1, max(0, Int(source.1 * Double(height))))
                        let offset = sy * stride + sx * 4
                        rgb += SIMD3(Double(bytes[offset + 2]), Double(bytes[offset + 1]), Double(bytes[offset])) / 1020
                    }
                }
                let i = y * cols + x
                colors[i] = settings.color ? rgb : SIMD3(repeating: 0.89)
                brightness[i] = pow(max(0, min(1, rgb.x * 0.299 + rgb.y * 0.587 + rgb.z * 0.114)), settings.gamma)
            }
        }
        var characters = [UInt16](repeating: 32, count: cols * rows)
        for y in 0..<rows {
            for x in 0..<cols {
                let i = y * cols + x
                let horizontal = abs(brightness[y * cols + max(0, x - 1)] - brightness[y * cols + min(cols - 1, x + 1)])
                let vertical = abs(brightness[max(0, y - 1) * cols + x] - brightness[min(rows - 1, y + 1) * cols + x])
                var value = min(1, brightness[i] + (horizontal + vertical) * settings.edges)
                if settings.invert { value = 1 - value }
                characters[i] = settings.ramp[Int((value * Double(settings.ramp.count - 1)).rounded())]
            }
        }
        return ASCIIFrame(columns: cols, rows: rows, characters: characters, colors: colors)
    }

    static func demo(time: Double, settings: PictureSettings) -> ASCIIFrame {
        let width = 640, height = 360
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) / Double(width), v = Double(y) / Double(height)
                let radius = hypot((u - 0.5) * 1.78, v - 0.5)
                let wave = 0.5 + 0.5 * sin(radius * 38 - time * 2.5)
                let mask = radius < 0.32 ? wave : (0.25 + 0.35 * u + 0.2 * sin(u * 15 + v * 10 + time))
                let i = (y * width + x) * 4
                pixels[i] = UInt8(max(0, min(255, (0.55 + 0.4 * (1 - u)) * mask * 255)))
                pixels[i + 1] = UInt8(max(0, min(255, (0.6 + 0.4 * v) * mask * 255)))
                pixels[i + 2] = UInt8(max(0, min(255, (0.3 + 0.7 * u) * mask * 255)))
            }
        }
        return pixels.withUnsafeBufferPointer { convert($0.baseAddress!, width: width, height: height, stride: width * 4, settings: settings) }
    }
}

final class PreviewView: NSView {
    var frameData: ASCIIFrame? { didSet { needsDisplay = true } }
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { super.mouseDown(with: event) }
    }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.025, green: 0.035, blue: 0.05, alpha: 1).setFill()
        bounds.fill()
        guard let frame = frameData, let context = NSGraphicsContext.current?.cgContext else { return }
        let cell = min((bounds.width - 32) / CGFloat(frame.columns), (bounds.height - 32) / CGFloat(frame.rows * 2))
        guard cell > 0 else { return }
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, cell / 0.602, nil)
        let x0 = (bounds.width - CGFloat(frame.columns) * cell) / 2
        let y0 = (bounds.height - CGFloat(frame.rows) * cell * 2) / 2
        var alphabet = Array(32...126).map { UInt16($0) }
        var glyphs = [CGGlyph](repeating: 0, count: alphabet.count)
        CTFontGetGlyphsForCharacters(font, &alphabet, &glyphs, alphabet.count)
        context.textMatrix = .identity
        for y in 0..<frame.rows {
            for x in 0..<frame.columns {
                let i = y * frame.columns + x, ch = Int(frame.characters[i])
                if ch == 32 { continue }
                let rgb = frame.colors[i]
                context.setFillColor(red: rgb.x, green: rgb.y, blue: rgb.z, alpha: 1)
                var glyph = glyphs[ch - 32]
                var point = CGPoint(x: x0 + CGFloat(x) * cell, y: y0 + CGFloat(frame.rows - 1 - y) * cell * 2 + cell * 0.32)
                CTFontDrawGlyphs(font, &glyph, &point, 1, context)
            }
        }
    }
}

final class VideoOutputWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        if styleMask.contains(.fullScreen) { toggleFullScreen(sender) }
        else { close() }
    }
}

final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "com.fiorillotech.ascii.camera", qos: .userInitiated)
    private let session = AVCaptureSession()
    private var settings = PictureSettings()
    private var generation = 0
    private var lastFrameTime = 0.0
    private let delivery = DispatchSemaphore(value: 1)
    var onFrame: ((ASCIIFrame, Int) -> Void)?
    var onStatus: ((String, Int, Bool) -> Void)?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(failed(_:)), name: .AVCaptureSessionRuntimeError, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)), name: .AVCaptureSessionWasInterrupted, object: session)
    }
    func update(_ value: PictureSettings) { queue.async { self.settings = value } }
    func stop() { queue.async { self.session.stopRunning() } }
    func shutdown() { queue.sync { session.stopRunning() } }
    private func report(_ text: String, _ token: Int, failed: Bool) {
        DispatchQueue.main.async { self.onStatus?(text, token, failed) }
    }
    @objc private func failed(_ notification: Notification) {
        queue.async { self.report("The camera stopped. Try Start camera again, or choose another camera.", self.generation, failed: true) }
    }
    @objc private func interrupted(_ notification: Notification) {
        queue.async { self.report("Camera interrupted. Close other camera apps, then try again.", self.generation, failed: true) }
    }
    func start(device: AVCaptureDevice, token: Int) {
        queue.async {
            self.session.stopRunning()
            self.generation = token
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            for output in self.session.outputs { self.session.removeOutput(output) }
            if self.session.canSetSessionPreset(.vga640x480) { self.session.sessionPreset = .vga640x480 }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else { throw NSError(domain: "Camera", code: 1) }
                self.session.addInput(input)
                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: self.queue)
                guard self.session.canAddOutput(output) else { throw NSError(domain: "Camera", code: 2) }
                self.session.addOutput(output)
                self.session.commitConfiguration()
                self.lastFrameTime = 0
                self.session.startRunning()
                if !self.session.isRunning { self.report("Could not start this camera. Choose another camera or check camera access.", token, failed: true) }
            } catch {
                self.session.commitConfiguration()
                self.report("Could not open this camera. Close other camera apps or choose another camera.", token, failed: true)
            }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFrameTime >= 1.0 / 24, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer), delivery.wait(timeout: .now()) == .success else { return }
        lastFrameTime = now
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            delivery.signal()
            return
        }
        let frame = Renderer.convert(base.assumingMemoryBound(to: UInt8.self), width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), stride: CVPixelBufferGetBytesPerRow(buffer), settings: settings)
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        let token = generation
        DispatchQueue.main.async {
            self.onFrame?(frame, token)
            self.delivery.signal()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let preview = PreviewView()
    let outputPreview = PreviewView()
    var outputWindow: VideoOutputWindow?
    var faceTimeWindow: NSWindow?
    var faceTimeStatus: NSTextField?
    let camera = CameraSource()
    let picker = NSPopUpButton()
    let startButton = NSButton(title: "Start camera", target: nil, action: nil)
    let demoButton = NSButton(title: "Try demo", target: nil, action: nil)
    let saveButton = NSButton(title: "Save image…", target: nil, action: nil)
    let copyButton = NSButton(title: "Copy text", target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString: "")
    let quality = NSSlider(value: 150, minValue: 70, maxValue: 220, target: nil, action: nil)
    let brightness = NSSlider(value: 1.15, minValue: 0.35, maxValue: 1.65, target: nil, action: nil)
    let edge = NSSlider(value: 0.35, minValue: 0, maxValue: 1, target: nil, action: nil)
    let color = NSButton(checkboxWithTitle: "Color", target: nil, action: nil)
    let mirror = NSButton(checkboxWithTitle: "Mirror", target: nil, action: nil)
    let invert = NSButton(checkboxWithTitle: "Invert", target: nil, action: nil)
    let style = NSPopUpButton()
    let rotation = NSPopUpButton()
    var devices: [AVCaptureDevice] = []
    var generation = 0
    var mode = "idle"
    var demoTimer: Timer?
    var watchdog: Timer?
    var lastReceived = 0.0
    var settings = PictureSettings()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        loadSettings()
        refreshCameras()
        camera.onFrame = { [weak self] frame, token in
            guard let self = self, self.mode == "camera", token == self.generation else { return }
            self.showFrame(frame)
            self.lastReceived = ProcessInfo.processInfo.systemUptime
            self.status.stringValue = "Live · \(frame.columns) × \(frame.rows) characters · Processed on your Mac"
            self.saveButton.isEnabled = true
            self.copyButton.isEnabled = true
        }
        camera.onStatus = { [weak self] text, token, failed in
            guard let self = self, self.mode == "camera", token == self.generation else { return }
            if failed { self.stop(clear: true) }
            self.status.stringValue = text
        }
        NotificationCenter.default.addObserver(self, selector: #selector(camerasChanged), name: .AVCaptureDeviceWasConnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(camerasChanged), name: .AVCaptureDeviceWasDisconnected, object: nil)
        status.stringValue = "Choose Start camera to begin, or Try demo without camera access."
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--demo") { toggleDemo() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === window { NSApp.terminate(nil) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        demoTimer?.invalidate()
        watchdog?.invalidate()
        camera.shutdown()
    }
    func buildMenu() {
        let menu = NSMenu()
        let item = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About ASCII Webcam", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit ASCII Webcam", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        menu.addItem(item)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        edit.submenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.submenu?.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        menu.addItem(edit)
        let view = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        view.submenu = NSMenu(title: "View")
        let fullScreen = NSMenuItem(title: "Full-screen Video", action: #selector(fullScreenVideo), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        fullScreen.target = self
        view.submenu?.addItem(fullScreen)
        let output = NSMenuItem(title: "Open Video Output", action: #selector(openVideoOutput), keyEquivalent: "o")
        output.target = self
        view.submenu?.addItem(output)
        let controls = NSMenuItem(title: "Show Controls", action: #selector(showControls), keyEquivalent: "1")
        controls.target = self
        view.submenu?.addItem(controls)
        let faceTime = NSMenuItem(title: "FaceTime Setup…", action: #selector(showFaceTimeSetup), keyEquivalent: "")
        faceTime.target = self
        view.submenu?.addItem(faceTime)
        menu.addItem(view)
        NSApp.mainMenu = menu
    }
    func text(_ string: String, size: CGFloat = 13, bold: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        return label
    }
    func row(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.alignment = .centerY
        return stack
    }
    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "ASCII Webcam"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 1000, height: 700)
        window.center()
        window.appearance = NSAppearance(named: .darkAqua)
        let root = NSView()
        window.contentView = root
        let heading = text("ASCII Webcam", size: 25, bold: true)
        let subtitle = text("Your camera, made of characters.", size: 13)
        subtitle.textColor = .secondaryLabelColor
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(camerasChanged))
        picker.target = self; picker.action = #selector(selectCamera)
        picker.widthAnchor.constraint(equalToConstant: 275).isActive = true
        startButton.target = self; startButton.action = #selector(toggleCamera)
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        demoButton.target = self; demoButton.action = #selector(toggleDemo)
        saveButton.target = self; saveButton.action = #selector(saveImage)
        copyButton.target = self; copyButton.action = #selector(copyText)
        saveButton.isEnabled = false; copyButton.isEnabled = false
        let toolbar = row([picker, refresh, startButton, demoButton, copyButton, saveButton])
        color.state = .on; mirror.state = .on
        for button in [color, mirror, invert] { button.target = self; button.action = #selector(changeSettings) }
        for slider in [quality, brightness, edge] {
            slider.target = self; slider.action = #selector(changeSettings)
            slider.widthAnchor.constraint(equalToConstant: 130).isActive = true
        }
        quality.toolTip = "More characters show finer detail; fewer characters run faster."
        brightness.toolTip = "Move right to brighten shadows."
        edge.toolTip = "Move right to emphasize outlines."
        style.addItems(withTitles: ["Clean", "Dense", "Bold", "Thin"])
        rotation.addItems(withTitles: ["0°", "90°", "180°", "270°"])
        for popup in [style, rotation] { popup.target = self; popup.action = #selector(changeSettings) }
        let controls = row([text("Detail"), quality, text("Brightness"), brightness, text("Edges"), edge, color, mirror, invert], spacing: 12)
        let reset = NSButton(title: "Reset picture", target: self, action: #selector(resetSettings))
        let privacy = NSButton(title: "Camera access…", target: self, action: #selector(cameraAccess))
        let options = row([text("Characters"), style, text("Rotate"), rotation, reset, privacy], spacing: 12)
        let fullScreen = NSButton(title: "Full screen", target: self, action: #selector(fullScreenVideo))
        fullScreen.toolTip = "Show only the video full screen. Press Escape to return."
        let videoOutput = NSButton(title: "Video output", target: self, action: #selector(openVideoOutput))
        videoOutput.toolTip = "Open a clean video-only window for capture in OBS."
        let faceTime = NSButton(title: "FaceTime setup…", target: self, action: #selector(showFaceTimeSetup))
        let outputHint = text("Double-click the preview for full screen · Esc to exit", size: 12)
        outputHint.textColor = .secondaryLabelColor
        let outputControls = row([fullScreen, videoOutput, faceTime, outputHint], spacing: 12)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 14
        preview.setAccessibilityLabel("ASCII camera preview")
        preview.onDoubleClick = { [weak self] in self?.fullScreenVideo() }
        let stack = NSStackView(views: [heading, subtitle, toolbar, preview, controls, options, outputControls, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 290),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.heightAnchor.constraint(equalToConstant: 34)
        ])
        preview.setContentHuggingPriority(.defaultLow, for: .vertical)
        for view in [heading, subtitle, toolbar, controls, options, outputControls, status] { view.setContentHuggingPriority(.required, for: .vertical) }
    }
    func showFrame(_ frame: ASCIIFrame?) {
        preview.frameData = frame
        outputPreview.frameData = frame
    }
    @objc func openVideoOutput() {
        if outputWindow == nil {
            let output = VideoOutputWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                           backing: .buffered, defer: false)
            output.title = "ASCII Webcam — Video Output"
            output.titleVisibility = .hidden
            output.titlebarAppearsTransparent = true
            output.isMovableByWindowBackground = true
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                output.standardWindowButton(button)?.isHidden = true
            }
            output.isReleasedWhenClosed = false
            output.collectionBehavior = [.fullScreenPrimary]
            output.minSize = NSSize(width: 320, height: 180)
            output.contentAspectRatio = NSSize(width: 16, height: 9)
            output.appearance = NSAppearance(named: .darkAqua)
            output.contentView = outputPreview
            outputPreview.setAccessibilityLabel("Clean ASCII video output. Press Escape to exit full screen.")
            outputPreview.onDoubleClick = { [weak self] in self?.fullScreenVideo() }
            output.center()
            outputWindow = output
        }
        outputPreview.frameData = preview.frameData
        outputWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func fullScreenVideo() {
        openVideoOutput()
        outputWindow?.toggleFullScreen(nil)
    }
    @objc func showControls() { window.makeKeyAndOrderFront(nil) }
    @objc func showFaceTimeSetup() {
        if faceTimeWindow == nil {
            let help = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 650),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            help.title = "Use ASCII Webcam in FaceTime"
            help.appearance = NSAppearance(named: .darkAqua)
            help.isReleasedWhenClosed = false
            let root = NSView()
            help.contentView = root
            let title = text("Your ASCII camera in FaceTime", size: 22, bold: true)
            let explanation = NSTextField(wrappingLabelWithString: "OBS Studio provides the virtual camera FaceTime can select. Set it up once, then keep ASCII Webcam and OBS open during your calls.")
            let steps = NSTextField(wrappingLabelWithString: """
            1. Start your real camera in ASCII Webcam, then click Open video output below. Leave that window open and unminimized.

            2. Install OBS Studio in Applications, then open it. If its setup wizard appears, choose the virtual-camera option.

            3. In OBS, add a macOS Screen Capture source. Set Method to Window Capture and choose “ASCII Webcam — Video Output”. Turn off Show cursor and audio capture. Allow screen recording when macOS asks. Fit the source to the canvas using Transform → Fit to screen.

            4. Click Start Virtual Camera in OBS. Approve OBS under System Settings → General → Login Items & Extensions → Camera Extensions if prompted, then restart OBS and start its virtual camera again.

            5. In FaceTime’s Video menu, choose OBS Virtual Camera. Keep your usual microphone selected. Choose your physical camera in ASCII Webcam, not OBS Virtual Camera.

            To end the feed, stop OBS’s virtual camera and stop the camera in ASCII Webcam. Nothing is broadcast to a service by OBS’s virtual-camera button.
            """)
            steps.font = .systemFont(ofSize: 13)
            let state = NSTextField(wrappingLabelWithString: "")
            state.font = .systemFont(ofSize: 12)
            state.textColor = .secondaryLabelColor
            faceTimeStatus = state
            let buttons = row([
                NSButton(title: "Open video output", target: self, action: #selector(openVideoOutput)),
                NSButton(title: "Open / get OBS", target: self, action: #selector(openOBS)),
                NSButton(title: "Open FaceTime", target: self, action: #selector(openFaceTime))
            ])
            let helpButtons = row([
                NSButton(title: "OBS setup help", target: self, action: #selector(openOBSHelp)),
                NSButton(title: "Check again", target: self, action: #selector(updateFaceTimeStatus))
            ])
            let stack = NSStackView(views: [title, explanation, steps, state, buttons, helpButtons])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 18
            stack.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
                stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),
                explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
                steps.widthAnchor.constraint(equalTo: stack.widthAnchor),
                state.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
            help.center()
            faceTimeWindow = help
        }
        updateFaceTimeStatus()
        faceTimeWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func updateFaceTimeStatus() {
        refreshCameras()
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.obsproject.obs-studio") != nil
        let available = devices.contains { $0.localizedName.localizedCaseInsensitiveContains("OBS Virtual Camera") }
        if available {
            faceTimeStatus?.stringValue = "OBS Virtual Camera is detected. Start it in OBS and select it in FaceTime."
        } else if installed {
            faceTimeStatus?.stringValue = "OBS is installed. Its virtual camera is not detected yet; complete its camera-extension approval."
        } else {
            faceTimeStatus?.stringValue = "OBS is not installed yet. Open / get OBS takes you to the official download."
        }
    }
    @objc func openOBS() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.obsproject.obs-studio") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(URL(string: "https://obsproject.com/download")!)
        }
    }
    @objc func openFaceTime() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FaceTime") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
    @objc func openOBSHelp() {
        NSWorkspace.shared.open(URL(string: "https://obsproject.com/kb/virtual-camera-troubleshooting")!)
    }
    @objc func camerasChanged() { refreshCameras() }
    func refreshCameras() {
        let previous = picker.selectedItem?.representedObject as? String ?? UserDefaults.standard.string(forKey: "cameraID")
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types += [.external, .continuityCamera]
        } else {
            types += [.externalUnknown]
        }
        devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        picker.removeAllItems()
        for device in devices {
            picker.addItem(withTitle: device.localizedName)
            picker.lastItem?.representedObject = device.uniqueID
        }
        if let index = devices.firstIndex(where: { $0.uniqueID == previous }) { picker.selectItem(at: index) }
        if devices.isEmpty { picker.addItem(withTitle: "No camera found") }
        picker.isEnabled = !devices.isEmpty
        startButton.isEnabled = !devices.isEmpty || mode == "camera"
        if mode == "camera", !devices.contains(where: { $0.uniqueID == previous }) {
            stop(clear: true)
            status.stringValue = "Camera disconnected. Connect a camera and click Refresh."
        }
    }
    @objc func selectCamera() {
        if let id = picker.selectedItem?.representedObject as? String { UserDefaults.standard.set(id, forKey: "cameraID") }
        if mode == "camera" { stop(clear: true); toggleCamera() }
    }
    func stop(clear: Bool = false) {
        generation += 1
        mode = "idle"
        demoTimer?.invalidate(); demoTimer = nil
        watchdog?.invalidate(); watchdog = nil
        camera.stop()
        startButton.title = "Start camera"
        demoButton.title = "Try demo"
        if clear { showFrame(nil); saveButton.isEnabled = false; copyButton.isEnabled = false }
        status.stringValue = "Stopped · Camera off"
    }
    @objc func toggleCamera() {
        if mode == "camera" || mode == "permission" { stop(); return }
        guard devices.indices.contains(picker.indexOfSelectedItem) else {
            status.stringValue = "No camera found. Connect a camera and click Refresh, or try the demo."
            return
        }
        stop(clear: true)
        let device = devices[picker.indexOfSelectedItem]
        UserDefaults.standard.set(device.uniqueID, forKey: "cameraID")
        mode = "permission"
        startButton.title = "Cancel"
        status.stringValue = "Waiting for camera access…"
        let token = generation
        let ready: (Bool) -> Void = { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self = self, token == self.generation, self.mode == "permission" else { return }
                guard allowed else {
                    self.stop(clear: true)
                    self.status.stringValue = "Camera access is off. Click Camera access… and allow ASCII Webcam, then try again."
                    return
                }
                self.mode = "camera"
                self.startButton.title = "Stop camera"
                self.status.stringValue = "Starting \(device.localizedName)…"
                self.lastReceived = ProcessInfo.processInfo.systemUptime
                self.camera.start(device: device, token: token)
                self.watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    guard let self = self, self.mode == "camera", ProcessInfo.processInfo.systemUptime - self.lastReceived > 12 else { return }
                    self.stop(clear: true)
                    self.status.stringValue = "No frames received. Check camera access, close other camera apps, or choose another camera."
                }
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: ready(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video, completionHandler: ready)
        default: ready(false)
        }
    }
    @objc func toggleDemo() {
        if mode == "demo" { stop(); return }
        stop(clear: true)
        mode = "demo"
        demoButton.title = "Stop demo"
        status.stringValue = "Demo · Camera off · Try the picture controls below"
        saveButton.isEnabled = true; copyButton.isEnabled = true
        drawDemo()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.drawDemo() }
    }
    func drawDemo() { showFrame(Renderer.demo(time: ProcessInfo.processInfo.systemUptime, settings: settings)) }
    @objc func changeSettings() {
        settings.columns = Int(quality.doubleValue)
        settings.gamma = 2 - brightness.doubleValue
        settings.edges = edge.doubleValue
        settings.color = color.state == .on
        settings.mirror = mirror.state == .on
        settings.invert = invert.state == .on
        settings.rotation = rotation.indexOfSelectedItem
        let ramps = [" .:-=+*#%@", " .'`^\",:;Il!i~+_-?][}{1)(|\\/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$", "  ..::--==++**##%%@@", " .,:;irsXA253hMHGS#9B&@"]
        settings.ramp = Array(ramps[max(0, style.indexOfSelectedItem)].utf16)
        camera.update(settings)
        let defaults = UserDefaults.standard
        defaults.set(["columns": quality.doubleValue, "brightness": brightness.doubleValue, "edges": edge.doubleValue, "style": Double(style.indexOfSelectedItem), "rotation": Double(rotation.indexOfSelectedItem)], forKey: "picture")
        defaults.set(settings.color, forKey: "color")
        defaults.set(settings.mirror, forKey: "mirror")
        defaults.set(settings.invert, forKey: "invert")
    }
    func loadSettings() {
        let defaults = UserDefaults.standard
        if let values = defaults.dictionary(forKey: "picture") as? [String: Double] {
            quality.doubleValue = max(70, min(220, values["columns"] ?? 150))
            brightness.doubleValue = max(0.35, min(1.65, values["brightness"] ?? 1.15))
            edge.doubleValue = max(0, min(1, values["edges"] ?? 0.35))
            style.selectItem(at: max(0, min(3, Int(values["style"] ?? 0))))
            rotation.selectItem(at: max(0, min(3, Int(values["rotation"] ?? 0))))
            color.state = defaults.bool(forKey: "color") ? .on : .off
            mirror.state = defaults.bool(forKey: "mirror") ? .on : .off
            invert.state = defaults.bool(forKey: "invert") ? .on : .off
        }
        changeSettings()
    }
    @objc func resetSettings() {
        quality.doubleValue = 150; brightness.doubleValue = 1.15; edge.doubleValue = 0.35
        color.state = .on; mirror.state = .on; invert.state = .off
        style.selectItem(at: 0); rotation.selectItem(at: 0)
        changeSettings()
    }
    @objc func cameraAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }
    @objc func copyText() {
        guard let frame = preview.frameData else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(frame.text, forType: .string)
    }
    @objc func saveImage() {
        guard preview.frameData != nil,
              let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) else { return }
        // Capture now so the saved image matches the moment the button was pressed.
        preview.cacheDisplay(in: preview.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.title = "Save ASCII image"
        panel.nameFieldStringValue = "ASCII Webcam.png"
        panel.allowedContentTypes = [.png]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try png.write(to: url, options: .atomic) }
            catch { let alert = NSAlert(error: error); alert.beginSheetModal(for: self.window) }
        }
    }
}

func makeIcon(at path: String) throws {
    let directory = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = size * scale
            // Draw at exact pixel sizes, independent of the display's Retina scale.
            let space = CGColorSpaceCreateDeviceRGB()
            let context = CGContext(data: nil, width: pixels, height: pixels,
                                    bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
            func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
                CGColor(red: r, green: g, blue: b, alpha: a)
            }
            func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
                CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            }
            func gradient(_ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
                context.saveGState()
                context.addPath(path); context.clip()
                let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
                context.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                context.restoreGState()
            }
            func stroke(_ path: CGPath, _ ink: CGColor, width: CGFloat) {
                context.addPath(path); context.setStrokeColor(ink); context.setLineWidth(width); context.strokePath()
            }
            func text(_ string: String, size: CGFloat, at point: CGPoint, ink: CGColor) {
                let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink
                ]))
                let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                context.textPosition = CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY)
                CTLineDraw(line, context)
            }
            let tile = rounded(CGRect(x: 60, y: 60, width: 904, height: 904), 204)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -14), blur: 24, color: color(0, 0, 0, 0.3))
            context.addPath(tile); context.setFillColor(color(0.035, 0.065, 0.12)); context.fillPath()
            context.restoreGState()
            gradient(tile, [color(0.13, 0.21, 0.31), color(0.035, 0.06, 0.115)],
                     from: CGPoint(x: 220, y: 980), to: CGPoint(x: 750, y: 90))
            stroke(tile, color(0.6, 0.8, 0.9, 0.16), width: 3)

            // A compact webcam silhouette stays recognizable even at Dock sizes.
            let stem = rounded(CGRect(x: 473, y: 244, width: 78, height: 153), 28)
            gradient(stem, [color(0.19, 0.55, 0.58), color(0.40, 0.87, 0.75)],
                     from: CGPoint(x: 460, y: 240), to: CGPoint(x: 550, y: 400))
            let foot = rounded(CGRect(x: 350, y: 216, width: 324, height: 60), 30)
            gradient(foot, [color(0.29, 0.64, 0.66), color(0.59, 0.94, 0.80)],
                     from: CGPoint(x: 360, y: 215), to: CGPoint(x: 650, y: 280))
            let body = rounded(CGRect(x: 179, y: 344, width: 666, height: 392), 100)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -16), blur: 30, color: color(0, 0, 0, 0.45))
            context.addPath(body); context.setFillColor(color(0.4, 0.9, 0.78)); context.fillPath()
            context.restoreGState()
            gradient(body, [color(0.66, 1.0, 0.84), color(0.22, 0.74, 0.72)],
                     from: CGPoint(x: 200, y: 750), to: CGPoint(x: 840, y: 330))
            stroke(body, color(0.82, 1, 0.94, 0.65), width: 4)
            let face = rounded(CGRect(x: 204, y: 369, width: 616, height: 342), 78)
            gradient(face, [color(0.10, 0.24, 0.29), color(0.055, 0.13, 0.19)],
                     from: CGPoint(x: 260, y: 720), to: CGPoint(x: 760, y: 360))

            if pixels >= 64 {
                // Character texture links the camera to its ASCII output.
                for (x, glyph) in [(CGFloat(271), ":"), (CGFloat(753), "+")] {
                    for y in [CGFloat(456), 540, 624] {
                        text(glyph, size: 42, at: CGPoint(x: x, y: y), ink: color(0.46, 0.9, 0.78, 0.50))
                    }
                }
            }
            let rim = CGPath(ellipseIn: CGRect(x: 362, y: 390, width: 300, height: 300), transform: nil)
            gradient(rim, [color(0.61, 1, 0.88), color(0.11, 0.51, 0.57)],
                     from: CGPoint(x: 410, y: 690), to: CGPoint(x: 610, y: 390))
            let lens = CGPath(ellipseIn: CGRect(x: 380, y: 408, width: 264, height: 264), transform: nil)
            gradient(lens, [color(0.08, 0.22, 0.29), color(0.015, 0.055, 0.11)],
                     from: CGPoint(x: 390, y: 680), to: CGPoint(x: 630, y: 400))
            stroke(CGPath(ellipseIn: CGRect(x: 399, y: 427, width: 226, height: 226), transform: nil),
                   color(0.4, 0.9, 0.86, 0.2), width: 3)
            text("@", size: 204, at: CGPoint(x: 512, y: 543), ink: color(0.69, 1, 0.87))
            if pixels >= 32 {
                context.setFillColor(color(0.75, 1, 0.75))
                context.fillEllipse(in: CGRect(x: 762, y: 655, width: 16, height: 16))
            }
            let suffix = scale == 2 ? "@2x" : ""
            let url = directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
            let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(output, context.makeImage()!, nil)
            guard CGImageDestinationFinalize(output) else { throw NSError(domain: "AppIcon", code: 1) }
        }
    }
}

func selfTest() {
    var settings = PictureSettings()
    settings.columns = 80; settings.mirror = false; settings.gamma = 1; settings.edges = 0
    var pixels = [UInt8](repeating: 0, count: 8 * 4 * 4)
    for y in 0..<4 { for x in 4..<8 { for channel in 0..<3 { pixels[(y * 8 + x) * 4 + channel] = 255 } } }
    func render() -> ASCIIFrame { pixels.withUnsafeBufferPointer { Renderer.convert($0.baseAddress!, width: 8, height: 4, stride: 32, settings: settings) } }
    let normal = render()
    precondition(normal.columns == 80 && normal.rows == 20)
    precondition(normal.characters.first == 32 && normal.characters[79] == 64)
    settings.mirror = true
    precondition(render().characters.first == 64)
    settings.invert = true
    precondition(render().characters.first == 32)
    settings.rotation = 1
    precondition(render().rows == 80)
    settings.color = false
    precondition(render().colors.first == SIMD3<Double>(repeating: 0.89))
    precondition(normal.text.split(separator: "\n", omittingEmptySubsequences: false).count == 20)
    let demo = Renderer.demo(time: 0, settings: PictureSettings())
    precondition(Set(demo.characters).count > 3)
    print("Native renderer checks passed: geometry, brightness, mirror, invert, rotation, monochrome, text, demo.")
}

if CommandLine.arguments.contains("--self-test") {
    selfTest()
} else if let index = CommandLine.arguments.firstIndex(of: "--make-icon"), CommandLine.arguments.count > index + 1 {
    try makeIcon(at: CommandLine.arguments[index + 1])
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    app.run()
}
