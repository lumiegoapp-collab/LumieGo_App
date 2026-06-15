import SwiftUI
import AVFoundation

@main
struct LumieGoApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .statusBarHidden()
        }
    }
}

// MARK: - Camera Preview (UIViewRepresentable)

struct CameraPreviewView: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer = layer
        return v
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // Reassign when the layer changes (e.g. front/back swap) so the new feed shows.
        if uiView.previewLayer !== layer { uiView.previewLayer = layer }
    }

    class PreviewUIView: UIView {
        var previewLayer: AVCaptureVideoPreviewLayer? {
            didSet {
                // Only detach the old layer if it still belongs to THIS view. During a
                // front/back swap the same layer can already be re-parented to the other
                // slot - removing it then would blank that view out.
                if let old = oldValue, old.superlayer === layer { old.removeFromSuperlayer() }
                if let l = previewLayer {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)   // no implicit move/resize animation
                    l.videoGravity = .resizeAspectFill
                    layer.addSublayer(l)
                    l.frame = bounds
                    CATransaction.commit()
                }
            }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer?.frame = bounds
            CATransaction.commit()
        }
    }
}

// MARK: - Main Camera View

struct MainCameraView: View {
    @StateObject private var camera       = CameraManager()
    @StateObject private var teleprompter = TeleprompterManager()
    @StateObject private var trial        = TrialManager()
    @StateObject private var store        = StoreManager()
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSettings     = false
    @State private var showRecordings   = false
    @State private var showScriptEditor = false
    @State private var showFocus        = false
    @State private var focusPoint       = CGPoint.zero
    @State private var exposureEV: Float = 0
    @State private var focusHideToken   = 0
    @State private var pinchZoom: CGFloat = 1.0
    @State private var countdownValue   = 0
    @State private var showShutterFlash = false
    @State private var lockedLandscape: Bool? = nil   // frozen orientation while recording
    @State private var pendingShareURL: URL?          // newest clip, offered for one-tap share
    @State private var shareURL: URL?                 // drives the share sheet
    @State private var expectingRecording = false     // a recording is in progress / finishing
    @State private var countdownCancelled = false     // user tapped to abort the countdown

    private let exposureRange: ClosedRange<Float> = -3...3

    /// Clamp the tap point so the focus reticle (square + right-side brightness slider)
    /// always stays in the central preview, never hovering over the control strips.
    private func clampFocus(_ pt: CGPoint, in size: CGSize, landscape: Bool) -> CGPoint {
        let leftPad:   CGFloat = landscape ? 130 : 60
        let rightPad:  CGFloat = landscape ? 130 : 100
        let topPad:    CGFloat = landscape ? 100 : 150
        let bottomPad: CGFloat = landscape ? 110 : 200
        return CGPoint(
            x: pt.x.clamped(to: leftPad ... max(leftPad, size.width  - rightPad)),
            y: pt.y.clamped(to: topPad  ... max(topPad,  size.height - bottomPad))
        )
    }

    /// Auto-hide the focus/exposure reticle after 3s of no interaction.
    private func scheduleFocusHide() {
        focusHideToken += 1
        let token = focusHideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if token == focusHideToken {
                withAnimation(.easeOut(duration: 0.25)) { showFocus = false }
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            // While recording the orientation is locked to whatever it was at record start.
            let isLandscape = lockedLandscape ?? (geo.size.width > geo.size.height)
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()
                    .onChange(of: camera.isRecording) { _, rec in
                        lockedLandscape = rec ? (geo.size.width > geo.size.height) : nil
                    }

                // Live preview - arranged to match the selected layout
                LayoutPreview(camera: camera, geo: geo)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                // Tap to focus. As a SwiftUI gesture it yields to any control tapped on top,
                // so tapping the toolbar icons no longer moves focus.
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            let pt = clampFocus(value.location, in: geo.size, landscape: isLandscape)
                            camera.focus(at: pt)
                            focusPoint = pt
                            exposureEV = 0
                            camera.setExposureBias(0)
                            withAnimation(.easeOut(duration: 0.15)) { showFocus = true }
                            scheduleFocusHide()
                        }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { val in camera.setZoom(pinchZoom * val) }
                        .onEnded   { val in pinchZoom = (pinchZoom * val).clamped(to: 1...10) }
                )

                // Tap-to-focus reticle with a vertical brightness (exposure) slider
                if showFocus {
                    FocusExposureView(
                        point: focusPoint,
                        ev: $exposureEV,
                        range: exposureRange,
                        onChange: { camera.setExposureBias($0) },
                        onInteract: { scheduleFocusHide() }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 1.15)))
                }

                // Rule-of-thirds grid
                if camera.showGrid {
                    GridOverlay().ignoresSafeArea().allowsHitTesting(false)
                }

                // Dual layout - show the portrait + landscape capture regions
                if camera.pipMode == .dual {
                    FramingGuideOverlay()
                        .ignoresSafeArea()
                        .transition(.opacity)
                }

                // Social media safe-zone overlay
                if camera.socialGuide != .none {
                    SocialSafeZoneOverlay(platform: camera.socialGuide)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }

                // Controls - hidden while recording for a clean shot (just stop + timer remain)
                if camera.isRecording {
                    RecordingHUD(camera: camera, isLandscape: isLandscape, onStop: primaryAction)
                } else if isLandscape {
                    // Top icons gathered into a single blurred strip at top-left
                    VStack(spacing: 0) {
                        if !teleprompter.isEnabled {
                            HStack {
                                LandscapeTopBar(camera: camera, teleprompter: teleprompter,
                                                trial: trial,
                                                showSettings: $showSettings,
                                                showRecordings: $showRecordings)
                                    .padding(.leading, 50)
                                    .padding(.top, 18)
                                Spacer()
                            }
                        }
                        Spacer()
                    }
                    // Side control columns (shutter right, categories left)
                    LandscapeControls(camera: camera, teleprompter: teleprompter,
                                      showScriptEditor: $showScriptEditor,
                                      onPrimaryAction: primaryAction)
                } else {
                    VStack(spacing: 0) {
                        // Hide the camera top bar while the teleprompter band occupies the top
                        if !teleprompter.isEnabled {
                            TopBar(camera: camera, teleprompter: teleprompter, trial: trial,
                                   showSettings: $showSettings, showRecordings: $showRecordings)
                        }
                        Spacer()
                        BottomBar(camera: camera, teleprompter: teleprompter,
                                  showScriptEditor: $showScriptEditor,
                                  onPrimaryAction: primaryAction)
                    }
                }

                // Teleprompter overlay (the headline feature) - above the controls so its
                // own buttons receive taps; its lower area is transparent so the shutter stays usable
                if teleprompter.isEnabled {
                    TeleprompterOverlay(teleprompter: teleprompter, showEditor: $showScriptEditor)
                }

                // Countdown
                if countdownValue > 0 {
                    CountdownOverlay(value: countdownValue)
                        .contentShape(Rectangle())
                        .onTapGesture { cancelCountdown() }
                        .accessibilityLabel("Cancel countdown")
                }

                // One-tap share banner after a recording finishes
                if let url = pendingShareURL, !camera.isRecording {
                    VStack {
                        Spacer()
                        ShareBanner(
                            onShare: { shareURL = url },
                            onDismiss: { withAnimation { pendingShareURL = nil } }
                        )
                        .padding(.bottom, isLandscape ? 24 : 150)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Shutter flash for photo capture
                if showShutterFlash {
                    Color.white.ignoresSafeArea().allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea()
        .sheet(isPresented: $showSettings)     { SettingsView(camera: camera, auth: auth) }
        .sheet(isPresented: $showRecordings)   { RecordingsView(camera: camera) }
        .sheet(isPresented: $showScriptEditor) { ScriptEditorView(teleprompter: teleprompter) }
        .sheet(item: Binding(
            get: { shareURL.map { ShareWrapper(url: $0) } },
            set: { shareURL = $0?.url }
        )) { wrapper in
            ShareSheet(url: wrapper.url)
        }
        // When a new clip is saved after recording, offer one-tap share
        .onChange(of: camera.savedRecordings.count) { _, _ in
            guard expectingRecording, let url = camera.savedRecordings.first?.url else { return }
            expectingRecording = false
            withAnimation(.spring(response: 0.4)) { pendingShareURL = url }
            // Auto-hide the banner if untouched
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                if shareURL == nil { withAnimation { pendingShareURL = nil } }
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { trial.isLocked },
            set: { _ in }
        )) {
            PaywallView(trial: trial)
        }
        .onAppear { camera.requestPermissions() }
        .task {
            // Sync the live subscription entitlement so subscribers stay unlocked
            // and lapsed subscriptions re-lock after the trial.
            await store.refreshEntitlements()
            trial.updateSubscription(store.isPro)
        }
        .onChange(of: store.isPro) { _, active in
            trial.updateSubscription(active)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                trial.refresh()
                Task { await store.refreshEntitlements() }
            }
        }
        .alert("Error", isPresented: Binding(
            get: { camera.error != nil },
            set: { if !$0 { camera.error = nil } }
        )) { Button("OK") {} } message: { Text(camera.error ?? "Something went wrong. Please try again.") }
    }

    // MARK: Record / shutter handling

    private func primaryAction() {
        if camera.captureMode == .photo {
            beginCountdown {
                camera.capturePhoto()
                flashShutter()
            }
        } else if camera.isRecording {
            camera.stopRecording()
            teleprompter.pause()
        } else {
            beginCountdown {
                camera.startRecording()
                expectingRecording = true
                if teleprompter.isEnabled { teleprompter.play() }
            }
        }
    }

    private func beginCountdown(_ action: @escaping () -> Void) {
        guard camera.countdownMode > 0 else { action(); return }
        countdownCancelled = false
        countdownValue = camera.countdownMode
        func tick() {
            if countdownCancelled { return }
            guard countdownValue > 0 else { action(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if countdownCancelled { return }
                countdownValue -= 1
                tick()
            }
        }
        tick()
    }

    private func cancelCountdown() {
        countdownCancelled = true
        countdownValue = 0
    }

    private func flashShutter() {
        showShutterFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeOut(duration: 0.2)) { showShutterFlash = false }
        }
    }
}

// MARK: - Top Bar

struct TopBar: View {
    @ObservedObject var camera: CameraManager
    @ObservedObject var teleprompter: TeleprompterManager
    @ObservedObject var trial: TrialManager
    @Binding var showSettings:   Bool
    @Binding var showRecordings: Bool

    var body: some View {
        HStack(spacing: 6) {
            // Left controls on a blurred strip - grid, countdown
            HStack(spacing: 4) {
                ControlButton(icon: "grid",
                              tint: camera.showGrid ? .yellow : .white) {
                    camera.showGrid.toggle()
                }
                // Countdown cycle: off → 3 → 5 → 10 → off
                Button {
                    camera.countdownMode = [0, 3, 5, 10].first(where: { $0 > camera.countdownMode }) ?? 0
                } label: {
                    ZStack {
                        Image(systemName: "timer")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(camera.countdownMode > 0 ? .yellow : .white)
                        if camera.countdownMode > 0 {
                            Text("\(camera.countdownMode)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.black)
                                .frame(width: 13, height: 13)
                                .background(Color.yellow)
                                .clipShape(Circle())
                                .offset(x: 10, y: 9)
                        }
                    }
                    .frame(width: 38, height: 38)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())

            Spacer()

            // Center: trial badge (the timer lives in the recording HUD)
            if !camera.isRecording, !trial.isPro {
                HStack(spacing: 4) {
                    Image(systemName: "clock").font(.system(size: 10, weight: .semibold))
                    Text(trial.trialLabel).font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.orange)
                .fixedSize()
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.orange.opacity(0.35), lineWidth: 1))
                .onLongPressGesture {
                    #if DEBUG
                    trial.debugExpireTrial()   // long-press to preview the paywall in debug builds
                    #endif
                }
            }

            Spacer()

            // Right controls on a blurred strip - recordings, teleprompter, settings
            HStack(spacing: 4) {
                ControlButton(icon: "rectangle.stack") { showRecordings = true }
                ControlButton(icon: "text.alignleft",
                              tint: teleprompter.isEnabled ? .orange : .white) {
                    withAnimation(.spring(response: 0.3)) { teleprompter.toggleEnabled() }
                }
                ControlButton(icon: "gearshape")       { showSettings   = true }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.top, 60)      // sit below the Dynamic Island / notch - strips never go under it
        .padding(.bottom, 8)
        .buttonStyle(.plain)    // opt out of iOS 26 auto Liquid Glass so icons stay compact
    }
}

// MARK: - Bottom Bar

enum BottomPanel { case none, layout, look }

struct BottomBar: View {
    @ObservedObject var camera: CameraManager
    @ObservedObject var teleprompter: TeleprompterManager
    @Binding var showScriptEditor: Bool
    let onPrimaryAction: () -> Void

    @State private var panel: BottomPanel = .none

    private func toggle(_ p: BottomPanel) {
        withAnimation(.spring(response: 0.3)) { panel = (panel == p) ? .none : p }
    }
    private func closePanel() {
        withAnimation(.spring(response: 0.3)) { panel = .none }
    }

    /// A consistent circular control matching the landscape side strip.
    private func roundButton(icon: String, active: Bool = false, tint: Color = .white,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(active ? tint : .white)
                .frame(width: 50, height: 50)
                .background(active ? tint.opacity(0.22) : Color.white.opacity(0.14))
                .clipShape(Circle())
        }
        .accessibilityLabel(a11yName(for: icon))
    }

    var body: some View {
        VStack(spacing: 12) {
            // Live audio meter while recording
            if camera.isRecording {
                AudioMeter(level: camera.audioLevel)
                    .transition(.opacity)
            }

            // Expanded sub-options - only one panel open at a time
            if panel == .layout {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(PiPMode.allCases, id: \.self) { mode in
                            PiPModeChip(mode: mode, selected: camera.pipMode == mode) {
                                camera.pipMode = mode
                                closePanel()
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Photo / Video mode toggle, with the camera-flip button on its right
            HStack(spacing: 12) {
                Picker("", selection: $camera.captureMode) {
                    ForEach(CaptureMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)

                Button { withAnimation(.spring(response: 0.3)) { camera.swapCameras() } } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Color.white.opacity(0.14))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())

            // Zoom pills (centered, above the shutter)
            HStack(spacing: 6) {
                ForEach([1.0, 2.0, 3.0], id: \.self) { z in
                    Button {
                        withAnimation(.spring(response: 0.25)) { camera.setZoom(z) }
                    } label: {
                        Text(camera.currentZoom == z ? "\(Int(z))×" : "\(Int(z))")
                            .font(.system(size: 13, weight: camera.currentZoom == z ? .bold : .regular))
                            .foregroundColor(camera.currentZoom == z ? .yellow : .white.opacity(0.85))
                            .frame(width: 34, height: 34)
                            .background(Color.black.opacity(0.35))
                            .clipShape(Circle())
                    }
                }
            }

            // Flash · Record · Layout - on a blurred strip
            // (teleprompter now lives in the top bar next to Settings)
            HStack(alignment: .center) {
                roundButton(icon: camera.isFlashOn ? "bolt.fill" : "bolt.slash",
                            active: camera.isFlashOn, tint: .yellow) { camera.toggleFlash() }

                Spacer()

                RecordButton(isRecording: camera.isRecording,
                             isPhoto: camera.captureMode == .photo,
                             action: onPrimaryAction)

                Spacer()

                roundButton(icon: "rectangle.3.group",
                            active: panel == .layout) { toggle(.layout) }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 44)
        }
        .background(LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                    startPoint: .top, endPoint: .bottom))
        .buttonStyle(.plain)   // opt out of iOS 26 auto Liquid Glass so controls keep their custom look
    }
}

// MARK: - Layout Preview

/// Arranges the back and front camera previews to match the selected layout,
/// so changing the layout visibly changes what you see (and what gets recorded).
struct LayoutPreview: View {
    @ObservedObject var camera: CameraManager
    let geo: GeometryProxy

    var body: some View {
        Group {
            if !camera.isMultiCamSupported || camera.pipMode == .dual || camera.pipMode == .back {
                // Single-camera device, Dual layout, or Back → back camera only, no PiP
                CameraPreviewView(layer: camera.backPreviewLayer)
            } else {
                switch camera.pipMode {
                case .front:
                    CameraPreviewView(layer: camera.frontPreviewLayer)
                case .pipCircle, .pipSquare:
                    ZStack {
                        CameraPreviewView(layer: camera.mainPreviewLayer)
                        DraggablePiP(camera: camera, geo: geo,
                                     circle: camera.pipMode.isCircleBubble)
                    }
                case .sideBySide:
                    HStack(spacing: 1) {
                        CameraPreviewView(layer: camera.mainPreviewLayer)
                        CameraPreviewView(layer: camera.pipPreviewLayer)
                    }
                case .topBottom:
                    VStack(spacing: 1) {
                        CameraPreviewView(layer: camera.mainPreviewLayer)
                        CameraPreviewView(layer: camera.pipPreviewLayer)
                    }
                case .back, .dual:
                    CameraPreviewView(layer: camera.backPreviewLayer)
                }
            }
        }
    }
}

// MARK: - Landscape Controls

/// Landscape control layout: shutter column on the right, category/mode column on the left,
/// zoom + expanded chips along the bottom-center, audio meter top-center while recording.
struct LandscapeControls: View {
    @ObservedObject var camera: CameraManager
    @ObservedObject var teleprompter: TeleprompterManager
    @Binding var showScriptEditor: Bool
    let onPrimaryAction: () -> Void

    @State private var panel: BottomPanel = .none

    private func toggle(_ p: BottomPanel) {
        withAnimation(.spring(response: 0.3)) { panel = (panel == p) ? .none : p }
    }
    private func closePanel() { withAnimation(.spring(response: 0.3)) { panel = .none } }

    var body: some View {
        ZStack {
            // Center column: expanded layout chips, audio meter, zoom - anchored to the bottom
            VStack(spacing: 8) {
                Spacer()
                if panel == .layout {
                    chipScroll {
                        ForEach(PiPMode.allCases, id: \.self) { m in
                            PiPModeChip(mode: m, selected: camera.pipMode == m) {
                                camera.pipMode = m; closePanel()
                            }
                        }
                    }
                }
                if camera.isRecording {
                    AudioMeter(level: camera.audioLevel).transition(.opacity)
                }
                zoomPills.padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity)

            // Bottom-left corner: Photo/Video on a blurred strip so it stays legible
            HStack {
                Picker("", selection: $camera.captureMode) {
                    ForEach(CaptureMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.leading, 40)    // clear the landscape notch / Dynamic Island
                .padding(.bottom, 24)
                Spacer()
            }
            .frame(maxHeight: .infinity, alignment: .bottom)

            // Right column: flash, layout, shutter, flip - evenly spaced on a blurred strip
            // (teleprompter now lives in the top strip next to Settings)
            HStack {
                Spacer()
                VStack(spacing: 22) {
                    sideButton(icon: camera.isFlashOn ? "bolt.fill" : "bolt.slash",
                               active: camera.isFlashOn, tint: .yellow) { camera.toggleFlash() }
                    sideButton(icon: "rectangle.3.group",
                               active: panel == .layout) { toggle(.layout) }
                    RecordButton(isRecording: camera.isRecording,
                                 isPhoto: camera.captureMode == .photo,
                                 action: onPrimaryAction)
                    sideButton(icon: "camera.rotate") {
                        withAnimation(.spring(response: 0.3)) { camera.swapCameras() }
                    }
                }
                .padding(.vertical, 18)
                .padding(.horizontal, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.trailing, 40)   // clear the landscape notch / Dynamic Island
            }
        }
        .buttonStyle(.plain)
    }

    /// A consistent circular control for the landscape side strip.
    private func sideButton(icon: String, active: Bool = false, tint: Color = .white,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .medium))
                .foregroundColor(active ? tint : .white)
                .frame(width: 48, height: 48)
                .background(active ? tint.opacity(0.22) : Color.white.opacity(0.14))
                .clipShape(Circle())
        }
        .accessibilityLabel(a11yName(for: icon))
    }

    private func chipScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content() }.padding(.horizontal, 16)
        }
        .frame(maxWidth: 520)
        .padding(.bottom, 8)
        .transition(.opacity)
    }

    private var zoomPills: some View {
        HStack(spacing: 6) {
            ForEach([1.0, 2.0, 3.0], id: \.self) { z in
                Button {
                    withAnimation(.spring(response: 0.25)) { camera.setZoom(z) }
                } label: {
                    Text(camera.currentZoom == z ? "\(Int(z))×" : "\(Int(z))")
                        .font(.system(size: 13, weight: camera.currentZoom == z ? .bold : .regular))
                        .foregroundColor(camera.currentZoom == z ? .yellow : .white.opacity(0.85))
                        .frame(width: 34, height: 34)
                        .background(Color.black.opacity(0.35))
                        .clipShape(Circle())
                }
            }
        }
    }
}

// MARK: - Draggable PiP

struct DraggablePiP: View {
    @ObservedObject var camera: CameraManager
    let geo: GeometryProxy
    var circle: Bool = false
    @State private var drag = CGSize.zero
    @State private var livePinch: CGFloat = 1   // live pinch factor, committed on end

    var body: some View {
        // Size off the SHORT edge so the bubble matches in portrait and landscape,
        // scaled by the user's pinch-to-resize factor. Square so a circle renders round.
        let shortEdge = min(geo.size.width, geo.size.height)
        let side = (shortEdge * 0.30 * camera.pipScale * livePinch)
            .clamped(to: shortEdge * 0.15 ... shortEdge * 0.6)
        let maxX = geo.size.width  - side
        let maxY = geo.size.height - side
        let baseX = camera.pipNorm.x * geo.size.width
        let baseY = camera.pipNorm.y * geo.size.height
        // Centre point (clamped on screen) for the current base + live drag.
        let cx = (baseX + drag.width  + side / 2).clamped(to: side/2 ... (geo.size.width  - side/2))
        let cy = (baseY + drag.height + side / 2).clamped(to: side/2 ... (geo.size.height - side/2))

        CameraPreviewView(layer: camera.pipPreviewLayer)
            .frame(width: side, height: side)
            .clipShape(shape)
            .overlay(shape.stroke(Color.white.opacity(0.3), lineWidth: 1.5))
            // Tap-to-swap hint badge (bottom-right of the bubble)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(5)
                    .background(Color.black.opacity(0.45), in: Circle())
                    .padding(6)
            }
            .shadow(color: .black.opacity(0.55), radius: 10, x: 0, y: 4)
            .position(x: cx, y: cy)
            // Tap the bubble to swap which camera is the main feed
            .onTapGesture {
                withAnimation(.spring(response: 0.3)) { camera.swapCameras() }
            }
            .gesture(DragGesture()
                .onChanged { drag = $0.translation }
                .onEnded { v in
                    let newX = (baseX + v.translation.width).clamped(to: 0...maxX)
                    let newY = (baseY + v.translation.height).clamped(to: 0...maxY)
                    // Store the bubble's top-left as a fraction of the frame; the recorder reads this.
                    camera.pipNorm = CGPoint(x: newX / geo.size.width, y: newY / geo.size.height)
                    drag = .zero
                }
            )
            .simultaneousGesture(MagnificationGesture()
                .onChanged { livePinch = $0 }
                .onEnded { v in
                    camera.pipScale = (camera.pipScale * v).clamped(to: 0.5...2.0)
                    livePinch = 1
                }
            )
    }

    private var shape: AnyShape {
        circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Reusable Components

/// Maps a control's SF Symbol to a VoiceOver label.
func a11yName(for icon: String) -> String {
    switch icon {
    case "bolt.fill", "bolt.slash":                                   return "Flash"
    case "text.alignleft":                                            return "Teleprompter"
    case "rectangle.3.group":                                         return "Layout"
    case "camera.rotate", "arrow.triangle.2.circlepath.camera":       return "Switch camera"
    case "gearshape":                                                 return "Settings"
    case "rectangle.stack":                                           return "Recordings"
    case "grid":                                                      return "Grid"
    case "timer":                                                     return "Countdown timer"
    case "square.and.arrow.up":                                       return "Share"
    case "folder":                                                    return "Export to Files"
    case "pencil":                                                    return "Edit script"
    case "xmark":                                                     return "Close"
    case "play.fill":                                                 return "Play"
    case "pause.fill":                                                return "Pause"
    case "gobackward":                                                return "Restart"
    default:                                                          return icon.replacingOccurrences(of: ".", with: " ")
    }
}

struct RecordButton: View {
    let isRecording: Bool
    var isPhoto: Bool = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 3).frame(width: 80, height: 80)
                if isPhoto {
                    // Shutter
                    Circle().fill(Color.white).frame(width: 65, height: 65)
                } else if isRecording {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.red)
                        .frame(width: 30, height: 30)
                } else {
                    Circle().fill(Color.red).frame(width: 65, height: 65)
                }
            }
        }
        .scaleEffect(isRecording ? 1.06 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.65), value: isRecording)
        .accessibilityLabel(isPhoto ? "Take photo" : (isRecording ? "Stop recording" : "Start recording"))
    }
}

struct RecTimerView: View {
    let duration: TimeInterval
    var fileCount: Int = 1
    @State private var blink = true

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.red).frame(width: 8, height: 8).opacity(blink ? 1 : 0.25)
            Text(formatted)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            Text("·")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
            Text("\(fileCount) \(fileCount == 1 ? "file" : "files")")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.orange)
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.black.opacity(0.45))
        .clipShape(Capsule())
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever()) { blink = false }
        }
    }

    var formatted: String {
        let h = Int(duration) / 3600, m = Int(duration) / 60 % 60, s = Int(duration) % 60
        return h > 0 ? String(format: "%02d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

struct FocusRing: View {
    @State private var appeared = false
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.yellow, lineWidth: 1.5)
            .frame(width: 72, height: 72)
            .scaleEffect(appeared ? 1 : 1.3)
            .opacity(appeared ? 1 : 0)
            .onAppear { withAnimation(.easeOut(duration: 0.2)) { appeared = true } }
    }
}

/// Tap-to-focus reticle with a vertical brightness (exposure) slider, à la the iOS camera.
/// Drag up to brighten, down to darken. Auto-hides 3s after the last interaction.
struct FocusExposureView: View {
    let point: CGPoint
    @Binding var ev: Float
    let range: ClosedRange<Float>
    let onChange: (Float) -> Void
    let onInteract: () -> Void

    @State private var startEV: Float? = nil
    @State private var appeared = false

    private let box: CGFloat = 78
    private let trackH: CGFloat = 120

    var body: some View {
        // 0 (bottom) … 1 (top) along the brightness track
        let span = range.upperBound - range.lowerBound
        let norm = CGFloat((ev - range.lowerBound) / span)

        ZStack {
            // Focus square, centered on the tap point. Non-interactive so a tap anywhere
            // (except the slider) falls through to the preview and re-triggers focus.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.yellow, lineWidth: 1.5)
                .frame(width: box, height: box)
                .scaleEffect(appeared ? 1 : 1.25)
                .allowsHitTesting(false)

            // Brightness slider to the right of the square - the only interactive part
            ZStack {
                Capsule().fill(Color.yellow.opacity(0.55)).frame(width: 2, height: trackH)
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.yellow)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .offset(y: (0.5 - norm) * trackH)
            }
            .frame(width: 40, height: trackH + 20)
            .contentShape(Rectangle())
            .offset(x: box / 2 + 24)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if startEV == nil { startEV = ev }
                        let delta = Float(-v.translation.height / 140) * span
                        ev = min(range.upperBound, max(range.lowerBound, (startEV ?? ev) + delta))
                        onChange(ev)
                        onInteract()
                    }
                    .onEnded { _ in startEV = nil; onInteract() }
            )
        }
        .frame(width: box + 90, height: max(box, trackH) + 24)
        .position(point)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(.easeOut(duration: 0.2)) { appeared = true } }
    }
}

/// Minimal overlay shown while recording: just the stop button and the timer.
/// Everything else is hidden for a clean shot.
struct RecordingHUD: View {
    @ObservedObject var camera: CameraManager
    let isLandscape: Bool
    let onStop: () -> Void

    var body: some View {
        ZStack {
            // Recording timer, top-center
            VStack {
                RecTimerView(duration: camera.recordingDuration, fileCount: camera.plannedFileCount)
                    .padding(.top, isLandscape ? 20 : 60)
                Spacer()
            }

            // Stop button - bottom-center (portrait) or right-center (landscape)
            if isLandscape {
                HStack {
                    Spacer()
                    RecordButton(isRecording: true, action: onStop)
                        .padding(.trailing, 50)
                }
            } else {
                VStack {
                    Spacer()
                    RecordButton(isRecording: true, action: onStop)
                        .padding(.bottom, 48)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// One-tap share prompt shown right after a recording is saved.
struct ShareBanner: View {
    let onShare: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Saved to your library")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text("Share to TikTok, Reels, YouTube and more")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
            }
            Spacer(minLength: 8)
            Button(action: onShare) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.white)
                    .clipShape(Capsule())
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 24, height: 24)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        .padding(.horizontal, 18)
        .buttonStyle(.plain)
    }
}

/// Landscape top controls gathered into a single blurred strip (grid, countdown,
/// recordings, settings) so they sit neatly at the top-left.
struct LandscapeTopBar: View {
    @ObservedObject var camera: CameraManager
    @ObservedObject var teleprompter: TeleprompterManager
    @ObservedObject var trial: TrialManager
    @Binding var showSettings:   Bool
    @Binding var showRecordings: Bool

    var body: some View {
        HStack(spacing: 8) {
            ControlButton(icon: "grid", tint: camera.showGrid ? .yellow : .white) {
                camera.showGrid.toggle()
            }
            Button {
                camera.countdownMode = [0, 3, 5, 10].first(where: { $0 > camera.countdownMode }) ?? 0
            } label: {
                ZStack {
                    Image(systemName: "timer")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(camera.countdownMode > 0 ? .yellow : .white)
                    if camera.countdownMode > 0 {
                        Text("\(camera.countdownMode)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.black)
                            .frame(width: 13, height: 13)
                            .background(Color.yellow)
                            .clipShape(Circle())
                            .offset(x: 10, y: 9)
                    }
                }
                .frame(width: 38, height: 38)
            }
            ControlButton(icon: "rectangle.stack") { showRecordings = true }
            ControlButton(icon: "text.alignleft",
                          tint: teleprompter.isEnabled ? .orange : .white) {
                withAnimation(.spring(response: 0.3)) { teleprompter.toggleEnabled() }
            }
            ControlButton(icon: "gearshape")       { showSettings   = true }

            if !trial.isPro {
                HStack(spacing: 4) {
                    Image(systemName: "clock").font(.system(size: 10, weight: .semibold))
                    Text(trial.trialLabel).font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.orange)
                .fixedSize()
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Color.orange.opacity(0.15))
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .buttonStyle(.plain)
    }
}

struct PiPModeChip: View {
    let mode: PiPMode
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: mode.icon).font(.system(size: 12))
                Text(mode.shortLabel).font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(selected ? .orange : .white.opacity(0.65))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(selected ? Color.orange.opacity(0.15) : Color.white.opacity(0.06))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(selected ? Color.orange.opacity(0.45) : Color.clear, lineWidth: 1))
        }
    }
}

/// Live microphone level meter shown while recording - confirms audio is being captured.
struct AudioMeter: View {
    let level: Float
    private let count = 16
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "mic.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
            HStack(spacing: 2) {
                ForEach(0..<count, id: \.self) { i in
                    let t = Float(i) / Float(count)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(level > t ? barColor(t) : Color.white.opacity(0.15))
                        .frame(width: 3, height: 11)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.black.opacity(0.4))
        .clipShape(Capsule())
        .animation(.linear(duration: 0.06), value: level)
    }
    private func barColor(_ t: Float) -> Color {
        if t > 0.85 { return .red } else if t > 0.6 { return .yellow } else { return .green }
    }
}

/// A collapsed category button in the bottom toolbar (Layout / Look / Framing).
/// Tapping opens its sub-options; tapping again closes them.
struct CategoryButton: View {
    let icon: String
    let label: String
    let active: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13))
                Text(label).font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(active ? .orange : .white)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(active ? Color.orange.opacity(0.18) : Color.white.opacity(0.10))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(active ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1))
        }
    }
}

/// Shows the landscape (16:9) and portrait (9:16) capture regions on the live preview,
/// so creators can frame a subject that works for both YouTube and Reels in one take.
/// Overlays a social platform's frame + safe zones (caption/UI areas) on the preview.
/// Visual guide only - does not change the recording aspect.
struct SocialSafeZoneOverlay: View {
    let platform: SocialPlatform
    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            // The platform frame, centered, fit within the screen
            let byWidth = W / platform.aspect
            let frameH = min(H, byWidth)
            let frameW = min(W, frameH * platform.aspect)
            let rect = CGRect(x: (W - frameW) / 2, y: (H - frameH) / 2, width: frameW, height: frameH)
            let topSafe = rect.minY + frameH * platform.topSafeFraction
            let botSafe = rect.maxY - frameH * platform.bottomSafeFraction

            ZStack(alignment: .topLeading) {
                // Frame outline
                Rectangle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)

                // Dimmed unsafe zones (top + bottom) where the platform overlays its UI
                if platform.topSafeFraction > 0 {
                    Color.red.opacity(0.18)
                        .frame(width: rect.width, height: topSafe - rect.minY)
                        .position(x: rect.midX, y: (rect.minY + topSafe) / 2)
                }
                if platform.bottomSafeFraction > 0 {
                    Color.red.opacity(0.18)
                        .frame(width: rect.width, height: rect.maxY - botSafe)
                        .position(x: rect.midX, y: (botSafe + rect.maxY) / 2)
                }

                Text("\(platform.rawValue) safe area")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())
                    .position(x: rect.midX, y: rect.minY + 12)
            }
        }
        .allowsHitTesting(false)
    }
}

struct FramingGuideOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height

            // Landscape 16:9 region - anchored to width, centered vertically
            let landH = min(H, W * 9.0 / 16.0)
            let landRect = CGRect(x: (W - W) / 2, y: (H - landH) / 2, width: W, height: landH)

            // Portrait 9:16 region - true 9:16, anchored to width unless it would exceed height
            let portByWidth = W * 16.0 / 9.0
            let portW: CGFloat = portByWidth <= H ? W : H * 9.0 / 16.0
            let portH: CGFloat = portByWidth <= H ? portByWidth : H
            let portRect = CGRect(x: (W - portW) / 2, y: (H - portH) / 2, width: portW, height: portH)

            ZStack {
                // Portrait guide (orange)
                Rectangle()
                    .stroke(Color.orange.opacity(0.95), style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    .frame(width: portRect.width, height: portRect.height)
                    .position(x: portRect.midX, y: portRect.midY)
                Text("PORTRAIT 9:16 · Social")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())
                    .position(x: portRect.midX, y: portRect.minY + 44)

                // Landscape guide (cyan)
                Rectangle()
                    .stroke(Color.cyan.opacity(0.95), style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    .frame(width: landRect.width, height: landRect.height)
                    .position(x: landRect.midX, y: landRect.midY)
                Text("LANDSCAPE 16:9 · YouTube")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.cyan)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())
                    .position(x: landRect.midX, y: landRect.midY)
            }
        }
        .allowsHitTesting(false)
    }
}

struct ControlButton: View {
    let icon: String
    var tint: Color = .white
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(tint)
                .frame(width: 38, height: 38)
        }
        .accessibilityLabel(a11yName(for: icon))
    }
}

struct PresetChip: View {
    let preset: CreatorPreset
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: preset.icon).font(.system(size: 12))
                Text(preset.rawValue).font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(selected ? .black : .white.opacity(0.7))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(selected ? Color.orange : Color.white.opacity(0.08))
            .clipShape(Capsule())
        }
    }
}

struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                let w = geo.size.width, h = geo.size.height
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                    let y = h * CGFloat(i) / 3
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
        }
    }
}

struct CountdownOverlay: View {
    let value: Int
    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 10) {
                Text("\(value)")
                    .font(.system(size: 120, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(radius: 12)
                    .transition(.scale.combined(with: .opacity))
                    .id(value)
                Text("Tap to cancel")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }
}
