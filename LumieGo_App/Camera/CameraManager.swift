import AVFoundation
import CoreImage
import UIKit
import Photos
import Combine

// MARK: - Models

enum LayoutGroup: String, CaseIterable {
    case standard = "Standard"
    case pip      = "PiP"
    case dual     = "Dual"
}

enum PiPMode: String, CaseIterable {
    // Standard - single camera, one file
    case back  = "Back"
    case front = "Front"
    // PiP - both cameras composited into one video
    case pipCircle  = "Circle"
    case pipSquare  = "Square"
    case sideBySide = "Side"
    case topBottom  = "Top/Down"
    // Dual - back camera recorded as portrait + landscape (two files)
    case dual = "Dual"

    var group: LayoutGroup {
        switch self {
        case .back, .front: return .standard
        case .pipCircle, .pipSquare, .sideBySide, .topBottom: return .pip
        case .dual: return .dual
        }
    }

    var icon: String {
        switch self {
        case .back:       return "camera.fill"
        case .front:      return "person.crop.square"
        case .pipCircle:  return "circle.circle"
        case .pipSquare:  return "square.on.square"
        case .sideBySide: return "rectangle.split.2x1"
        case .topBottom:  return "rectangle.split.1x2"
        case .dual:       return "rectangle.portrait.on.rectangle.portrait"
        }
    }
    var shortLabel: String { rawValue }

    /// True for the corner-bubble PiP layouts (back main + front bubble).
    var hasBubble: Bool { self == .pipCircle || self == .pipSquare }
    var isCircleBubble: Bool { self == .pipCircle }
    var isDual: Bool { self == .dual }
}

/// Social platforms whose on-screen safe zones can be overlaid (doesn't change recording aspect).
enum SocialPlatform: String, CaseIterable, Identifiable {
    case none      = "Off"
    case tiktok    = "TikTok"
    case reels     = "Reels"
    case shorts    = "Shorts"
    case instagram = "Instagram"
    case snapchat  = "Snapchat"
    case youtube   = "YouTube"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .none:      return "rectangle.slash"
        case .tiktok:    return "music.note"
        case .reels:     return "play.rectangle.on.rectangle"
        case .shorts:    return "play.square.stack"
        case .instagram: return "camera.circle"
        case .snapchat:  return "bolt.square"
        case .youtube:   return "play.rectangle.fill"
        }
    }

    /// Aspect ratio (width:height) of the platform's primary feed frame.
    var aspect: CGFloat {
        switch self {
        case .none:      return 9.0/16.0
        case .tiktok, .reels, .shorts, .snapchat: return 9.0/16.0
        case .instagram: return 4.0/5.0
        case .youtube:   return 16.0/9.0
        }
    }
    /// Fraction of height reserved at the BOTTOM for the platform's caption/UI (safe zone).
    var bottomSafeFraction: CGFloat {
        switch self {
        case .tiktok:    return 0.18
        case .reels:     return 0.20
        case .shorts:    return 0.15
        case .snapchat:  return 0.16
        case .instagram: return 0.10
        default:         return 0.0
        }
    }
    /// Fraction of height reserved at the TOP for the platform's UI.
    var topSafeFraction: CGFloat {
        switch self {
        case .tiktok, .reels, .shorts, .snapchat: return 0.08
        default: return 0.0
        }
    }
}

enum RecordingOrientation: String, CaseIterable {
    case portrait  = "Portrait"
    case landscape = "Landscape"
    var icon: String { self == .portrait ? "iphone" : "rotate.right.fill" }
    var outputSize: CGSize {
        self == .portrait ? CGSize(width: 1080, height: 1920) : CGSize(width: 1920, height: 1080)
    }
}

enum VideoFormat: String, CaseIterable {
    case hevc   = "HEVC"
    case h264   = "H.264"
    case proRes = "ProRes"
    var fileExtension: String { self == .proRes ? "mov" : "mp4" }
    var avFileType: AVFileType { self == .proRes ? .mov : .mp4 }
    var codec: AVVideoCodecType {
        switch self {
        case .hevc:   return .hevc
        case .h264:   return .h264
        case .proRes: return .proRes422HQ
        }
    }
}

enum VideoQuality: String, CaseIterable {
    case p720  = "720p"
    case p1080 = "1080p"
    case p4K   = "4K"
    var baseSize: CGSize {
        switch self {
        case .p720:  return CGSize(width: 1280, height: 720)
        case .p1080: return CGSize(width: 1920, height: 1080)
        case .p4K:   return CGSize(width: 3840, height: 2160)
        }
    }
    var bitrate: Int {
        switch self {
        case .p720:  return 4_000_000
        case .p1080: return 8_000_000
        case .p4K:   return 25_000_000
        }
    }
}

enum FrameRate: Int, CaseIterable {
    case fps24 = 24, fps30 = 30, fps60 = 60
    var label: String { "\(rawValue) fps" }
}

enum CaptureMode: String, CaseIterable {
    case video = "Video"
    case photo = "Photo"
}

/// Where finished recordings are saved.
enum SaveDestination: String, CaseIterable {
    case photos = "Photos"
    case folder = "Files / External Drive"
}

/// One-tap creator looks. Each sets a frame rate and a color grade applied to the
/// merged composite (raw separate clips stay ungraded for editing).
enum CreatorPreset: String, CaseIterable {
    case none      = "None"
    case cinematic = "Cinematic"
    case sports    = "Sports"
    case vlog      = "Vlog"

    var icon: String {
        switch self {
        case .none:      return "circle.slash"
        case .cinematic: return "film"
        case .sports:    return "figure.run"
        case .vlog:      return "person.wave.2"
        }
    }

    var frameRate: FrameRate {
        switch self {
        case .cinematic: return .fps24
        case .sports:    return .fps60
        case .vlog, .none: return .fps30
        }
    }
}

struct RecordingItem: Identifiable {
    let id = UUID()
    let url: URL
    let date: Date
    var duration: TimeInterval
    var thumbnail: UIImage?
}

// MARK: - CameraManager

final class CameraManager: NSObject, ObservableObject {

    // MARK: Published
    @Published var pipMode: PiPMode = .back
    @Published var recordingOrientation: RecordingOrientation = .portrait
    @Published var videoFormat: VideoFormat = .hevc
    @Published var videoQuality: VideoQuality = .p1080
    @Published var frameRate: FrameRate = .fps30
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var isMultiCamSupported = false
    @Published var isFlashOn = false
    @Published var currentZoom: CGFloat = 1.0
    @Published var isStabilizationEnabled = true
    @Published var captureMode: CaptureMode = .video
    @Published var countdownMode: Int = 0      // 0 = off, else 3/5/10 seconds
    @Published var showGrid = false
    @Published var socialGuide: SocialPlatform = .none   // on-screen safe-zone overlay for a platform
    @Published var pipNorm = CGPoint(x: 0.66, y: 0.06)   // PiP bubble top-left, as a fraction of the frame
    @Published var pipScale: CGFloat = 1.0               // user-adjustable PiP bubble size (pinch to resize)
    @Published var camerasSwapped = false                // flip: front becomes the main feed, back the bubble
    @Published var preset: CreatorPreset = .none {
        didSet { frameRate = preset.frameRate }
    }
    @Published var lastCapturedPhoto: UIImage?  // for the shutter flash / quick review
    @Published var audioLevel: Float = 0         // 0...1 live mic level while recording
    @Published var savedRecordings: [RecordingItem] = []
    @Published var error: String?

    /// Where new recordings are saved. The clip is always also kept in the app library.
    @Published var saveDestination: SaveDestination =
        (SaveDestination(rawValue: UserDefaults.standard.string(forKey: "lumiego.saveDest") ?? "") ?? .photos) {
        didSet { UserDefaults.standard.set(saveDestination.rawValue, forKey: "lumiego.saveDest") }
    }
    /// Display name of the chosen Files/external folder (empty if none picked yet).
    @Published var externalFolderName: String = UserDefaults.standard.string(forKey: "lumiego.folderName") ?? ""

    private var folderBookmark: Data? {
        get { UserDefaults.standard.data(forKey: "lumiego.folderBookmark") }
        set { UserDefaults.standard.set(newValue, forKey: "lumiego.folderBookmark") }
    }

    /// Remember a user-picked folder (Files / external drive) via a security-scoped bookmark.
    func setExternalFolder(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            folderBookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            externalFolderName = url.lastPathComponent
            UserDefaults.standard.set(url.lastPathComponent, forKey: "lumiego.folderName")
            saveDestination = .folder
        } catch {
            self.error = "Couldn't access that folder. Please pick another location."
        }
    }

    /// Copy a finished clip into the remembered folder. Returns false if no folder / it failed.
    private func copyToExternalFolder(_ fileURL: URL) -> Bool {
        guard let data = folderBookmark else { return false }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: data, options: [],
                                    relativeTo: nil, bookmarkDataIsStale: &stale) else { return false }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let dest = folder.appendingPathComponent(fileURL.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: fileURL, to: dest)
            return true
        } catch { return false }
    }

    // Photo capture (triple-shot) - set on the main thread, consumed on the sync queue
    private var stillRequested = false

    // MARK: Preview layers
    let backPreviewLayer  = AVCaptureVideoPreviewLayer()
    let frontPreviewLayer = AVCaptureVideoPreviewLayer()

    var mainPreviewLayer: AVCaptureVideoPreviewLayer {
        if pipMode == .front { return frontPreviewLayer }
        return camerasSwapped ? frontPreviewLayer : backPreviewLayer
    }
    var pipPreviewLayer: AVCaptureVideoPreviewLayer {
        camerasSwapped ? backPreviewLayer : frontPreviewLayer
    }

    // MARK: Session & I/O
    let session = AVCaptureMultiCamSession()
    private var backInput:  AVCaptureDeviceInput?
    private var frontInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let backVideoOut  = AVCaptureVideoDataOutput()
    private let frontVideoOut = AVCaptureVideoDataOutput()
    private let audioOut      = AVCaptureAudioDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?

    // MARK: Recording
    private var writer: AVAssetWriter?
    private var audioIn: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStartTime: CMTime?
    private var currentURL: URL?
    private var recordingTimer: Timer?
    private var isWriting = false   // accessed on syncQueue only
    private var lastFront: CVPixelBuffer?   // most recent front frame, reused if one is dropped

    // Optional raw single-camera writers (when saveSeparateFiles is on)
    private var backClip:  ClipWriter?
    private var frontClip: ClipWriter?

    // Dual-frame mode: back camera recorded to both aspect ratios at once
    private var portraitClip:  ClipWriter?   // 9:16 for social
    private var landscapeClip: ClipWriter?   // 16:9 for YouTube

    // Device-rotation handling - keeps the preview and recording level with the device
    private var backRotationCoordinator:  AVCaptureDevice.RotationCoordinator?
    private var frontRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservers: [NSKeyValueObservation] = []

    // MARK: Queues & Context
    private let sessionQueue = DispatchQueue(label: "cam.session", qos: .userInitiated)
    private let syncQueue    = DispatchQueue(label: "cam.sync",    qos: .userInteractive)
    private let ciContext    = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Permissions & Start

    func requestPermissions() {
        Task {
            let cam = await AVCaptureDevice.requestAccess(for: .video)
            let mic = await AVCaptureDevice.requestAccess(for: .audio)
            if cam && mic {
                sessionQueue.async { self.configureSession() }
            } else {
                await MainActor.run { self.error = "Camera and microphone access required." }
            }
        }
    }

    // MARK: - Session Configuration

    private func configureSession() {
        let supported = AVCaptureMultiCamSession.isMultiCamSupported
        DispatchQueue.main.async { self.isMultiCamSupported = supported }

        session.beginConfiguration()
        if supported {
            setupMultiCam()
        } else {
            setupSingleCam()
        }
        session.commitConfiguration()
        session.startRunning()

        // Recover from interruptions (phone calls, Control Center, other camera use).
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleSessionInterruption(_:)),
                       name: .AVCaptureSessionRuntimeError, object: session)
        nc.addObserver(self, selector: #selector(handleSessionInterruption(_:)),
                       name: .AVCaptureSessionInterruptionEnded, object: session)
    }

    @objc private func handleSessionInterruption(_ note: Notification) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        rotationObservers.forEach { $0.invalidate() }
        rotationObservers.removeAll()
        recordingTimer?.invalidate()
        if session.isRunning { session.stopRunning() }
    }

    private func setupMultiCam() {
        guard
            let backDev  = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let frontDev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
            let bIn = try? AVCaptureDeviceInput(device: backDev),
            let fIn = try? AVCaptureDeviceInput(device: frontDev),
            session.canAddInput(bIn), session.canAddInput(fIn)
        else { setupSingleCam(); return }

        session.addInputWithNoConnections(bIn)
        session.addInputWithNoConnections(fIn)
        backInput  = bIn
        frontInput = fIn

        // Pick multi-cam-optimized formats so BOTH cameras' connections fit the hardware budget.
        // Without this, the front data-output connection can be rejected (only the back records).
        selectMultiCamFormat(for: backDev)
        selectMultiCamFormat(for: frontDev)

        if let audioDev = AVCaptureDevice.default(for: .audio),
           let aIn = try? AVCaptureDeviceInput(device: audioDev),
           session.canAddInput(aIn) {
            session.addInputWithNoConnections(aIn)
            audioInput = aIn
        }

        let fmt: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        backVideoOut.videoSettings  = fmt
        frontVideoOut.videoSettings = fmt
        backVideoOut.alwaysDiscardsLateVideoFrames  = true
        frontVideoOut.alwaysDiscardsLateVideoFrames = true

        [backVideoOut, frontVideoOut, audioOut].forEach {
            if session.canAddOutput($0) { session.addOutputWithNoConnections($0) }
        }

        // Back camera connections
        if let port = bIn.ports(for: .video, sourceDeviceType: backDev.deviceType, sourceDevicePosition: .back).first {
            let previewConn = AVCaptureConnection(inputPort: port, videoPreviewLayer: backPreviewLayer)
            if session.canAddConnection(previewConn) { session.addConnection(previewConn) }

            let outConn = AVCaptureConnection(inputPorts: [port], output: backVideoOut)
            if session.canAddConnection(outConn) { session.addConnection(outConn) }
        }

        // Front camera connections
        if let port = fIn.ports(for: .video, sourceDeviceType: frontDev.deviceType, sourceDevicePosition: .front).first {
            let previewConn = AVCaptureConnection(inputPort: port, videoPreviewLayer: frontPreviewLayer)
            if session.canAddConnection(previewConn) { session.addConnection(previewConn) }

            let outConn = AVCaptureConnection(inputPorts: [port], output: frontVideoOut)
            if session.canAddConnection(outConn) { session.addConnection(outConn) }
        }

        // Audio connection
        if let audioDev = audioInput?.device,
           let port = audioInput?.ports(for: .audio, sourceDeviceType: audioDev.deviceType, sourceDevicePosition: .unspecified).first {
            let conn = AVCaptureConnection(inputPorts: [port], output: audioOut)
            if session.canAddConnection(conn) { session.addConnection(conn) }
        }

        // Each output gets its own delegate (Apple's multi-cam pattern, no synchronizer).
        // Front frames are cached and composited onto each back frame, so the front is never
        // dropped by a synchronizer when compositing is busy.
        backVideoOut.setSampleBufferDelegate(self, queue: syncQueue)
        frontVideoOut.setSampleBufferDelegate(self, queue: syncQueue)
        audioOut.setSampleBufferDelegate(self, queue: syncQueue)

        backPreviewLayer.session  = session
        frontPreviewLayer.session = session

        // Front camera: the connections handle ROTATION only (via RotationCoordinator).
        // Let the preview mirror itself automatically; the recorded front is mirrored in software
        // (orientedUpright). Combining manual mirroring + rotation on the connection rotated the
        // front 90° wrong, so we keep them separate.
        frontPreviewLayer.connection.map { if $0.isVideoMirroringSupported { $0.automaticallyAdjustsVideoMirroring = true } }

        setupRotation(backDevice: backDev, frontDevice: frontDev)

        // Diagnostic: if the front data-output connection couldn't be added, the recording
        // would only contain the back camera. Surface it instead of failing silently.
        if frontVideoOut.connection(with: .video) == nil {
            DispatchQueue.main.async { self.error = "Front camera output unavailable - recordings may show only the back camera." }
        }
    }

    /// Selects a multi-cam-supported format (≈1080p) so both cameras stay within the hardware
    /// cost budget and all connections (preview + data, ×2) can be added.
    private func selectMultiCamFormat(for device: AVCaptureDevice) {
        let target = 1920 * 1080
        let candidates = device.formats.filter { format in
            format.isMultiCamSupported &&
            format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
        }
        guard !candidates.isEmpty else { return }
        func pixels(_ f: AVCaptureDevice.Format) -> Int {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return Int(d.width) * Int(d.height)
        }
        // Prefer the largest format that does not exceed ~1080p; otherwise the smallest available.
        let best = candidates.filter { pixels($0) <= target }.max(by: { pixels($0) < pixels($1) })
            ?? candidates.min(by: { pixels($0) < pixels($1) })
        if let best {
            try? device.lockForConfiguration()
            device.activeFormat = best
            device.unlockForConfiguration()
        }
    }

    private func setupSingleCam() {
        guard
            let backDev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let bIn = try? AVCaptureDeviceInput(device: backDev),
            session.canAddInput(bIn)
        else { return }

        session.addInput(bIn)
        backInput = bIn

        if let audioDev = AVCaptureDevice.default(for: .audio),
           let aIn = try? AVCaptureDeviceInput(device: audioDev),
           session.canAddInput(aIn) {
            session.addInput(aIn)
            audioInput = aIn
        }

        let fmt: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        backVideoOut.videoSettings = fmt
        backVideoOut.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(backVideoOut) { session.addOutput(backVideoOut) }
        if session.canAddOutput(audioOut)     { session.addOutput(audioOut) }

        backVideoOut.setSampleBufferDelegate(self, queue: syncQueue)
        audioOut.setSampleBufferDelegate(self, queue: syncQueue)
        backPreviewLayer.session = session

        setupRotation(backDevice: backDev, frontDevice: nil)
    }

    // MARK: - Device Rotation

    /// Uses RotationCoordinator(s) to keep the preview and recorded video level with the device,
    /// and auto-switches the recording aspect (portrait 9:16 ↔ landscape 16:9) as the phone turns.
    private func setupRotation(backDevice: AVCaptureDevice, frontDevice: AVCaptureDevice?) {
        rotationObservers.removeAll()

        backRotationCoordinator = AVCaptureDevice.RotationCoordinator(device: backDevice, previewLayer: backPreviewLayer)
        if let frontDevice {
            frontRotationCoordinator = AVCaptureDevice.RotationCoordinator(device: frontDevice, previewLayer: frontPreviewLayer)
        }

        applyRotations()

        if let rc = backRotationCoordinator {
            rotationObservers.append(rc.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.applyRotations() }
            })
            rotationObservers.append(rc.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.applyRotations() }
            })
        }
        if let rc = frontRotationCoordinator {
            rotationObservers.append(rc.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.applyRotations() }
            })
            rotationObservers.append(rc.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.applyRotations() }
            })
        }

        // Re-apply shortly after the session starts, once the coordinators have settled on
        // the current physical orientation (initial values can lag at launch).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.applyRotations() }
    }

    private func applyRotations() {
        // Lock orientation while recording - rotating the phone must not flip the video.
        guard !isRecording else { return }
        if let rc = backRotationCoordinator {
            let cap = rc.videoRotationAngleForHorizonLevelCapture
            let prev = rc.videoRotationAngleForHorizonLevelPreview
            setAngle(prev, on: backPreviewLayer.connection)
            setAngle(cap,  on: backVideoOut.connection(with: .video))

            // Auto-follow the device orientation for the recording aspect ratio:
            // capture angle 90/270 → portrait, 0/180 → landscape.
            let isPortraitAngle = (Int(cap) % 180) != 0
            let target: RecordingOrientation = isPortraitAngle ? .portrait : .landscape
            if recordingOrientation != target { recordingOrientation = target }
        }
        if let rc = frontRotationCoordinator {
            let cap = rc.videoRotationAngleForHorizonLevelCapture
            let prev = rc.videoRotationAngleForHorizonLevelPreview
            setAngle(prev, on: frontPreviewLayer.connection)
            setAngle(cap,  on: frontVideoOut.connection(with: .video))
        }
    }

    private func setAngle(_ angle: CGFloat, on connection: AVCaptureConnection?) {
        guard let connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    // MARK: - Recording

    /// Dual layout records two separate files (portrait + landscape) from the back camera.
    var isDualLayout: Bool { pipMode == .dual }

    /// How many files the next/current recording will produce.
    /// Dual layout → 2 files (portrait + landscape). Everything else → 1 combined video.
    var plannedFileCount: Int { isDualLayout ? 2 : 1 }

    /// Portrait (9:16) and landscape (16:9) output sizes at the current quality.
    private var portraitSize: CGSize {
        let b = videoQuality.baseSize
        return CGSize(width: min(b.width, b.height), height: max(b.width, b.height))
    }
    private var landscapeSize: CGSize {
        let b = videoQuality.baseSize
        return CGSize(width: max(b.width, b.height), height: min(b.width, b.height))
    }

    func startRecording() {
      syncQueue.async { [self] in
        let stamp = Int(Date().timeIntervalSince1970)
        let size  = outputSize()

        // Reset state
        backClip = nil; frontClip = nil
        portraitClip = nil; landscapeClip = nil
        writer = nil; adaptor = nil; audioIn = nil
        currentURL = nil

        // Dual layout → back camera recorded to portrait + landscape (2 files), no composite.
        // Standard + PiP → exactly one combined video.
        let dualFrame = isDualLayout
        let wantComposite = !dualFrame

        let videoSettings: [String: Any] = {
            var s: [String: Any] = [
                AVVideoCodecKey:  videoFormat.codec,
                AVVideoWidthKey:  Int(size.width),
                AVVideoHeightKey: Int(size.height)
            ]
            if videoFormat != .proRes {
                s[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: videoQuality.bitrate]
            }
            return s
        }()

        do {
            if dualFrame {
                if let pc = ClipWriter(url: outputURL(stamp: stamp, suffix: "_portrait"),
                                       size: portraitSize, format: videoFormat, bitrate: videoQuality.bitrate) {
                    pc.start(); portraitClip = pc
                }
                if let lc = ClipWriter(url: outputURL(stamp: stamp, suffix: "_landscape"),
                                       size: landscapeSize, format: videoFormat, bitrate: videoQuality.bitrate) {
                    lc.start(); landscapeClip = lc
                }
            }

            if wantComposite {
                let url = outputURL(stamp: stamp)
                currentURL = url
                let w = try AVAssetWriter(url: url, fileType: videoFormat.avFileType)
                writer = w

                let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                videoWriterInput.expectsMediaDataInRealTime = true
                let pixelAttrs: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey  as String: Int(size.width),
                    kCVPixelBufferHeightKey as String: Int(size.height)
                ]
                adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoWriterInput,
                                                               sourcePixelBufferAttributes: pixelAttrs)
                if w.canAdd(videoWriterInput) { w.add(videoWriterInput) }

                let audioSettings: [String: Any] = [
                    AVFormatIDKey:         kAudioFormatMPEG4AAC,
                    AVSampleRateKey:       44100,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey:   192000
                ]
                let audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audioWriterInput.expectsMediaDataInRealTime = true
                if w.canAdd(audioWriterInput) { w.add(audioWriterInput) }
                audioIn = audioWriterInput

                w.startWriting()
            }

            guard writer != nil || portraitClip != nil else {
                DispatchQueue.main.async { self.error = "Couldn't start recording." }
                return
            }

            sessionStartTime = nil
            isWriting = true

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                isRecording = true
                recordingDuration = 0
                recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.recordingDuration += 0.05
                    self.audioLevel = self.currentAudioLevel()
                }
            }
        } catch {
            DispatchQueue.main.async { self.error = error.localizedDescription }
        }
      }
    }

    func stopRecording() {
        let dur = recordingDuration   // read main-thread state before hopping queues
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isRecording = false
            recordingTimer?.invalidate()
            recordingTimer = nil
            audioLevel = 0
        }

        // Finish the writers on the capture queue so writer state is never touched concurrently.
        syncQueue.async { [self] in
            isWriting = false

            // If no frames were ever written, the session was never started - cancel to avoid writer errors
            guard sessionStartTime != nil else {
                writer?.cancelWriting()
                if let url = currentURL { try? FileManager.default.removeItem(at: url) }
                backClip?.cancel(); frontClip?.cancel()
                portraitClip?.cancel(); landscapeClip?.cancel()
                writer = nil; adaptor = nil; audioIn = nil
                backClip = nil; frontClip = nil
                portraitClip = nil; landscapeClip = nil
                currentURL = nil
                return
            }

            // Finish the raw per-camera clips (if any) and save each
            let backRef = backClip, frontRef = frontClip
            let portRef = portraitClip, landRef = landscapeClip
            backClip = nil; frontClip = nil
            portraitClip = nil; landscapeClip = nil
            backRef?.finish  { [weak self, backRef]  url in _ = backRef;  self?.finalizeRecording(url: url, duration: dur) }
            frontRef?.finish { [weak self, frontRef] url in _ = frontRef; self?.finalizeRecording(url: url, duration: dur) }
            portRef?.finish  { [weak self, portRef]  url in _ = portRef;  self?.finalizeRecording(url: url, duration: dur) }
            landRef?.finish  { [weak self, landRef]  url in _ = landRef;  self?.finalizeRecording(url: url, duration: dur) }

            adaptor?.assetWriterInput.markAsFinished()
            audioIn?.markAsFinished()
            let w = writer
            w?.finishWriting { [weak self] in
                guard let self, let url = self.currentURL else { return }
                self.finalizeRecording(url: url, duration: dur)
            }
        }
    }

    private func finalizeRecording(url: URL, duration: TimeInterval) {
        // Skip saving empty/corrupt files (writer cancelled or no frames written)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard fileSize > 0 else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let dest = DispatchQueue.main

        // The clip is always kept in the app library; the chosen destination gets a copy.
        switch saveDestination {
        case .folder:
            let ok = copyToExternalFolder(url)
            dest.async {
                if !ok {
                    self.error = "Couldn't save to the selected folder. The clip is still in the app; pick a folder again in Settings."
                }
                self.addLocalRecording(url: url, duration: duration)
            }

        case .photos:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    dest.async { self.addLocalRecording(url: url, duration: duration) }
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }) { _, _ in
                    dest.async { self.addLocalRecording(url: url, duration: duration) }
                }
            }
        }
    }

    private func addLocalRecording(url: URL, duration: TimeInterval) {
        var item = RecordingItem(url: url, date: Date(), duration: duration)
        generateThumbnail(for: url) { thumb in
            item.thumbnail = thumb
            self.savedRecordings.insert(item, at: 0)
        }
    }

    private func generateThumbnail(for url: URL, completion: @escaping (UIImage?) -> Void) {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 400, height: 400)   // downsample: grid cells are small
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.generateCGImageAsynchronously(for: time) { image, _, _ in
            DispatchQueue.main.async {
                completion(image.map { UIImage(cgImage: $0) })
            }
        }
    }

    // MARK: - Compositing

    private func compositeFrames(back: CVPixelBuffer, front: CVPixelBuffer?) -> CVPixelBuffer? {
        let size = outputSize()

        // The phone is held upright (portrait-locked UI), so every sensor frame is rotated
        // to display upright. The output aspect (9:16 vs 16:9) is handled purely by the crop.
        let backCI  = orientedUpright(back, isFront: false)
        let frontCI = front.map { orientedUpright($0, isFront: true) }

        // Flip swaps the roles: when swapped the front feed is the main shot and back the secondary.
        let primaryCI:   CIImage  = camerasSwapped ? (frontCI ?? backCI) : backCI
        let secondaryCI: CIImage? = camerasSwapped ? backCI : frontCI

        let composed: CIImage
        switch pipMode {
        case .back, .dual:
            composed = scaleToFill(backCI, to: size)

        case .front:
            composed = scaleToFill(frontCI ?? backCI, to: size)

        case .pipCircle, .pipSquare:
            let main = scaleToFill(primaryCI, to: size)
            if let f = secondaryCI {
                composed = buildPiP(f, outputSize: size, circle: pipMode.isCircleBubble).composited(over: main)
            } else { composed = main }

        case .sideBySide:
            let halfSize = CGSize(width: size.width / 2, height: size.height)
            let left  = scaleToFill(primaryCI, to: halfSize)
            let right = scaleToFill(secondaryCI ?? primaryCI, to: halfSize)
                .transformed(by: CGAffineTransform(translationX: halfSize.width, y: 0))
            composed = right.composited(over: left)

        case .topBottom:
            // Main feed on TOP, secondary on BOTTOM. (CIImage origin is bottom-left,
            // so the top half sits at y = halfHeight and the bottom half at y = 0.)
            let halfSize = CGSize(width: size.width, height: size.height / 2)
            let bottom = scaleToFill(secondaryCI ?? primaryCI, to: halfSize)
            let top    = scaleToFill(primaryCI, to: halfSize)
                .transformed(by: CGAffineTransform(translationX: 0, y: halfSize.height))
            composed = top.composited(over: bottom)
        }

        return render(applyGrade(composed), size: size)
    }

    /// Applies the active creator preset's color grade. Operates on the merged
    /// composite only - raw separate clips remain ungraded for editing.
    private func applyGrade(_ image: CIImage) -> CIImage {
        switch preset {
        case .none:
            return image
        case .cinematic:
            let warm = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral":       CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 5400, y: 15)
            ])
            return warm.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.86,
                kCIInputContrastKey:   1.12,
                kCIInputBrightnessKey: -0.02
            ])
        case .sports:
            let vivid = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.28,
                kCIInputContrastKey:   1.16
            ])
            return vivid.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.35])
        case .vlog:
            let bright = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.12,
                kCIInputBrightnessKey: 0.05,
                kCIInputContrastKey:   1.04
            ])
            return bright.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.28])
        }
    }

    private func buildPiP(_ image: CIImage, outputSize: CGSize, circle: Bool) -> CIImage {
        // Square bubble so a circular mask renders as a true circle.
        // Size off the short edge so it stays consistent in portrait and landscape,
        // and honor the user's pinch-to-resize scale.
        let side = (min(outputSize.width, outputSize.height) * 0.30 * pipScale)
            .clamped(to: 0...min(outputSize.width, outputSize.height))
        var scaled = scaleToFill(image, to: CGSize(width: side, height: side))

        if circle {
            let mask = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter":  CIVector(x: side / 2, y: side / 2),
                "inputRadius0": side / 2 - 1,
                "inputRadius1": side / 2,
                "inputColor0":  CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                "inputColor1":  CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            ])?.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
            if let mask {
                let clear = CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
                scaled = scaled.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputMaskImageKey: mask,
                    kCIInputBackgroundImageKey: clear
                ])
            }
        }

        // Place the bubble where the user dragged it. pipNorm is the bubble's top-left as a
        // fraction of the frame (y measured from the TOP); CIImage is y-up, so flip vertically.
        let maxX = outputSize.width  - side
        let maxY = outputSize.height - side
        let tx = (pipNorm.x * outputSize.width).clamped(to: 0...maxX)
        let topY = pipNorm.y * outputSize.height
        let ty = (outputSize.height - topY - side).clamped(to: 0...maxY)
        return scaled.transformed(by: CGAffineTransform(translationX: tx, y: ty))
    }

    private func scaleToFill(_ image: CIImage, to size: CGSize) -> CIImage {
        let e = image.extent
        let sx = size.width  / e.width
        let sy = size.height / e.height
        let s  = max(sx, sy)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let cx = (scaled.extent.width  - size.width)  / 2
        let cy = (scaled.extent.height - size.height) / 2
        return scaled
            .cropped(to: CGRect(x: cx, y: cy, width: size.width, height: size.height))
            .transformed(by: CGAffineTransform(translationX: -cx, y: -cy))
    }

    /// The capture connections rotate frames level with the device (via the RotationCoordinator),
    /// so the buffers arrive upright. The front camera still needs a horizontal mirror for a
    /// natural selfie, applied here in software.
    private func orientedUpright(_ pixel: CVPixelBuffer, isFront: Bool) -> CIImage {
        let ci = CIImage(cvPixelBuffer: pixel)
        return isFront ? ci.oriented(.upMirrored) : ci
    }

    // Reused pixel-buffer pool so we don't allocate a fresh buffer every frame.
    private var bufferPool: CVPixelBufferPool?
    private var poolDims: (Int, Int) = (0, 0)

    private func pooledBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if bufferPool == nil || poolDims != (width, height) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
            bufferPool = pool
            poolDims = (width, height)
        }
        guard let pool = bufferPool else { return nil }
        var buf: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf)
        return buf
    }

    private func render(_ image: CIImage, size: CGSize) -> CVPixelBuffer? {
        guard let buf = pooledBuffer(width: Int(size.width), height: Int(size.height)) else { return nil }
        ciContext.render(image, to: buf)
        return buf
    }

    private func outputSize() -> CGSize {
        let base = videoQuality.baseSize
        return recordingOrientation == .portrait
            ? CGSize(width: min(base.width, base.height), height: max(base.width, base.height))
            : CGSize(width: max(base.width, base.height), height: min(base.width, base.height))
    }

    private func outputURL(stamp: Int, suffix: String = "") -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("LumieGo_\(stamp)\(suffix).\(videoFormat.fileExtension)")
    }

    /// Renders one camera full-frame to the output canvas - used for the raw
    /// separate-file exports in dual layouts.
    private func renderSingleCamera(_ buffer: CVPixelBuffer, isFront: Bool) -> CVPixelBuffer? {
        let size = outputSize()
        let ci = orientedUpright(buffer, isFront: isFront)
        return render(scaleToFill(ci, to: size), size: size)
    }

    /// Renders the back camera (graded) cropped to a specific aspect - used by
    /// dual-frame mode to produce the portrait (9:16) and landscape (16:9) files.
    private func renderBackToSize(_ buffer: CVPixelBuffer, size: CGSize) -> CVPixelBuffer? {
        let ci = orientedUpright(buffer, isFront: false)
        return render(applyGrade(scaleToFill(ci, to: size)), size: size)
    }

    /// Live microphone level (0...1) from the audio output's channels, for the on-screen meter.
    private func currentAudioLevel() -> Float {
        guard let channels = audioOut.connection(with: .audio)?.audioChannels, !channels.isEmpty else { return 0 }
        let maxDb = channels.map { $0.averagePowerLevel }.max() ?? -60
        let clamped = max(-60, min(0, maxDb))      // dBFS, -60 (quiet) … 0 (max)
        return (clamped + 60) / 60                  // → 0...1
    }

    // MARK: - Camera Controls

    func swapCameras() {
        switch pipMode {
        case .back:  pipMode = .front
        case .front: pipMode = .back
        case .pipCircle, .pipSquare, .sideBySide, .topBottom:
            // Swap roles: the front feed becomes the main shot and back becomes the bubble/half.
            camerasSwapped.toggle()
        case .dual:
            break   // Dual records both full frames; nothing to swap
        }
    }

    func setZoom(_ factor: CGFloat) {
        guard let device = backInput?.device, (try? device.lockForConfiguration()) != nil else { return }
        let clamped = factor.clamped(to: 1.0...device.maxAvailableVideoZoomFactor)
        device.videoZoomFactor = clamped
        device.unlockForConfiguration()
        DispatchQueue.main.async { self.currentZoom = factor }
    }

    func toggleFlash() {
        guard let device = backInput?.device, device.hasTorch,
              (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = device.torchMode == .on ? .off : .on
        device.unlockForConfiguration()
        DispatchQueue.main.async { self.isFlashOn.toggle() }
    }

    /// The device whose focus/exposure the on-screen reticle drives.
    private var focusDevice: AVCaptureDevice? {
        pipMode == .front ? frontInput?.device : backInput?.device
    }
    private var focusLayer: AVCaptureVideoPreviewLayer {
        pipMode == .front ? frontPreviewLayer : backPreviewLayer
    }

    func focus(at point: CGPoint) {
        guard let dev = focusDevice, (try? dev.lockForConfiguration()) != nil else { return }
        let dp = focusLayer.captureDevicePointConverted(fromLayerPoint: point)
        if dev.isFocusPointOfInterestSupported    { dev.focusPointOfInterest = dp; dev.focusMode = .autoFocus }
        if dev.isExposurePointOfInterestSupported  { dev.exposurePointOfInterest = dp; dev.exposureMode = .autoExpose }
        dev.unlockForConfiguration()
    }

    /// Manual exposure (brightness) bias in EV, driven by the focus reticle's vertical slider.
    func setExposureBias(_ ev: Float) {
        guard let dev = focusDevice, (try? dev.lockForConfiguration()) != nil else { return }
        let clamped = max(dev.minExposureTargetBias, min(dev.maxExposureTargetBias, ev))
        dev.setExposureTargetBias(clamped, completionHandler: nil)
        dev.unlockForConfiguration()
    }

    func deleteRecording(_ item: RecordingItem) {
        try? FileManager.default.removeItem(at: item.url)
        savedRecordings.removeAll { $0.id == item.id }
    }

    // MARK: - Photo (triple-shot)

    /// Requests a still capture on the next synchronized frame set.
    /// Set on the capture queue (where it's read) to avoid a cross-thread data race.
    func capturePhoto() {
        syncQueue.async { self.stillRequested = true }
    }

    /// Renders and saves the merged (graded), back, and front stills to Photos.
    private func captureTripleShot(back: CVPixelBuffer, front: CVPixelBuffer?) {
        var images: [UIImage] = []
        if let merged = compositeFrames(back: back, front: front), let img = uiImage(from: merged) {
            images.append(img)
        }
        if let b = renderSingleCamera(back, isFront: false), let img = uiImage(from: b) {
            images.append(img)
        }
        if let front, let f = renderSingleCamera(front, isFront: true), let img = uiImage(from: f) {
            images.append(img)
        }
        guard !images.isEmpty else { return }

        let first = images.first
        DispatchQueue.main.async { self.lastCapturedPhoto = first }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                for img in images { PHAssetChangeRequest.creationRequestForAsset(from: img) }
            }
        }
    }

    private func uiImage(from buffer: CVPixelBuffer) -> UIImage? {
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

extension CameraManager {

    /// Starts the writer sessions on the first sample, consistently across all active writers.
    /// Safe to call from both delegates (both run on the same serial queue).
    private func startSessionsIfNeeded(at pts: CMTime) {
        guard sessionStartTime == nil else { return }
        sessionStartTime = pts
        writer?.startSession(atSourceTime: pts)
        backClip?.startSession(at: pts)
        frontClip?.startSession(at: pts)
        portraitClip?.startSession(at: pts)
        landscapeClip?.startSession(at: pts)
    }

    /// Appends an audio sample to every active writer. Shared by multi-cam and single-cam paths.
    /// Audio never starts the session - it only writes once a video frame has started it.
    private func appendAudioToWriters(_ sample: CMSampleBuffer) {
        guard isWriting, sessionStartTime != nil else { return }
        _ = audioIn?.append(sample)
        backClip?.appendAudio(sample)
        frontClip?.appendAudio(sample)
        portraitClip?.appendAudio(sample)
        landscapeClip?.appendAudio(sample)
    }
}

// MARK: - Single-cam fallback delegates

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate,
                          AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        // Front camera: just cache the latest frame for compositing onto the back stream.
        if output === frontVideoOut {
            if let buf = CMSampleBufferGetImageBuffer(sampleBuffer) { lastFront = buf }
            return
        }

        // Audio: append to every active writer.
        if output is AVCaptureAudioDataOutput {
            appendAudioToWriters(sampleBuffer)
            return
        }

        // Back camera drives the recording. Composite with the most recent front frame.
        guard output === backVideoOut || output is AVCaptureVideoDataOutput,
              let backBuf = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let frontBuf = lastFront

        if stillRequested {
            stillRequested = false
            captureTripleShot(back: backBuf, front: frontBuf)
        }

        guard isWriting else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        startSessionsIfNeeded(at: pts)

        // Merged composite (both cameras → one video for Standard/PiP layouts)
        if let adpt = adaptor, adpt.assetWriterInput.isReadyForMoreMediaData,
           let composited = compositeFrames(back: backBuf, front: frontBuf) {
            adpt.append(composited, withPresentationTime: pts)
        }

        // Dual layout: back camera → portrait (9:16) + landscape (16:9)
        if let pc = portraitClip, pc.isWriting, let p = renderBackToSize(backBuf, size: portraitSize) {
            pc.appendVideo(p, at: pts)
        }
        if let lc = landscapeClip, lc.isWriting, let l = renderBackToSize(backBuf, size: landscapeSize) {
            lc.appendVideo(l, at: pts)
        }
    }
}

// MARK: - ClipWriter

/// A single-file video+audio writer used for the raw front/back and dual-frame exports.
/// Uses the classic AVAssetWriter pipeline so audio is reliably written (the iOS 27
/// receiver API can't append captured CMSampleBuffers, which silently dropped audio).
final class ClipWriter {
    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput
    private var sessionStarted = false

    init?(url: URL, size: CGSize, format: VideoFormat, bitrate: Int) {
        guard let w = try? AVAssetWriter(url: url, fileType: format.avFileType) else { return nil }
        self.writer = w
        self.url = url

        var vs: [String: Any] = [
            AVVideoCodecKey:  format.codec,
            AVVideoWidthKey:  Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        if format != .proRes {
            vs[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: bitrate]
        }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: vs)
        videoInput.expectsMediaDataInRealTime = true
        let pixelAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey  as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,
                                                       sourcePixelBufferAttributes: pixelAttrs)
        guard w.canAdd(videoInput) else { return nil }
        w.add(videoInput)

        let aSettings: [String: Any] = [
            AVFormatIDKey:         kAudioFormatMPEG4AAC,
            AVSampleRateKey:       44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey:   192000
        ]
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
        audioInput.expectsMediaDataInRealTime = true
        if w.canAdd(audioInput) { w.add(audioInput) }
    }

    var isWriting: Bool { writer.status == .writing }

    func start() { writer.startWriting() }

    func startSession(at pts: CMTime) {
        guard !sessionStarted else { return }
        writer.startSession(atSourceTime: pts)
        sessionStarted = true
    }

    func appendVideo(_ buffer: CVPixelBuffer, at pts: CMTime) {
        if videoInput.isReadyForMoreMediaData {
            adaptor.append(buffer, withPresentationTime: pts)
        }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        if audioInput.isReadyForMoreMediaData {
            audioInput.append(sample)
        }
    }

    func finish(_ completion: @escaping (URL) -> Void) {
        guard sessionStarted else { writer.cancelWriting(); return }
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        let u = url
        writer.finishWriting { completion(u) }
    }

    func cancel() {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Helpers

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
