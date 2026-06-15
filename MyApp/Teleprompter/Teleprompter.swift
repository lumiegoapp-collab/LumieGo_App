import SwiftUI
import Combine

// MARK: - Teleprompter Manager

/// Drives the auto-scrolling teleprompter overlay. Pure UI/state - no capture dependencies,
/// so it works regardless of camera availability (e.g. in the simulator).
final class TeleprompterManager: ObservableObject {

    @Published var script: String = """
    Welcome to LumieGo.

    Tap the pencil to write your own script, then press play and read while you record - no extra gear, no second person.

    Adjust the speed to match how you talk. Make the text bigger or smaller. Dim the background so you can still see your shot.

    You've got this. Look into the lens, breathe, and just talk.
    """

    @Published var isEnabled    = false     // overlay shown
    @Published var isScrolling  = false      // auto-scroll running
    @Published var speed: Double = 45        // points per second
    @Published var fontSize: CGFloat = 30
    @Published var dim: Double   = 0.55      // background dim behind text (0 = clear, 1 = black)
    @Published var mirrored      = false     // horizontal flip for beam-splitter teleprompter rigs
    @Published var offset: CGFloat = 0       // current scroll offset in points

    /// Measured at render time so we know when to stop scrolling.
    var contentHeight: CGFloat  = 0
    var viewportHeight: CGFloat = 0

    private var timer: Timer?

    let speedRange: ClosedRange<Double>   = 15...120
    let fontRange:  ClosedRange<CGFloat>  = 18...56

    func toggleEnabled() {
        isEnabled.toggle()
        if !isEnabled { pause() }
    }

    func toggleScroll() { isScrolling ? pause() : play() }

    func play() {
        guard !isScrolling else { return }
        isScrolling = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.offset += CGFloat(self.speed) / 60.0
            let maxOffset = max(0, self.contentHeight - self.viewportHeight * 0.4)
            if self.offset >= maxOffset { self.pause() }
        }
    }

    func pause() {
        isScrolling = false
        timer?.invalidate()
        timer = nil
    }

    func reset() {
        pause()
        offset = 0
    }

    func adjustSpeed(_ delta: Double) {
        speed = (speed + delta).clamped(to: speedRange)
    }
    func adjustFont(_ delta: CGFloat) {
        fontSize = (fontSize + delta).clamped(to: fontRange)
    }
}

// MARK: - Teleprompter Overlay

/// The scrolling script band. Sits in the upper portion of the screen so the
/// camera preview and record button stay visible underneath.
struct TeleprompterOverlay: View {
    @ObservedObject var teleprompter: TeleprompterManager
    @Binding var showEditor: Bool

    var body: some View {
        GeometryReader { geo in
            let bandHeight = geo.size.height * 0.42

            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    // Dimmed reading background
                    Color.black.opacity(teleprompter.dim)

                    // Scrolling text, masked so it fades at top and bottom edges
                    scrollingText(viewport: CGSize(width: geo.size.width, height: bandHeight))
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: .black, location: 0.12),
                                    .init(color: .black, location: 0.85),
                                    .init(color: .clear, location: 1.0)
                                ],
                                startPoint: .top, endPoint: .bottom)
                        )
                        .clipped()

                    // Center reading guide line
                    VStack {
                        Spacer().frame(height: bandHeight * 0.42)
                        Rectangle()
                            .fill(Color.orange.opacity(0.5))
                            .frame(height: 1.5)
                    }
                    .frame(height: bandHeight)

                    controls
                }
                .frame(height: bandHeight)

                Spacer()
            }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .buttonStyle(.plain)   // keep teleprompter control icons compact on iOS 26
    }

    private func scrollingText(viewport: CGSize) -> some View {
        Text(teleprompter.script)
            .font(.system(size: teleprompter.fontSize, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .lineSpacing(8)
            .padding(.horizontal, 24)
            .frame(width: viewport.width)
            .background(
                GeometryReader { textGeo in
                    Color.clear
                        .onAppear {
                            teleprompter.contentHeight = textGeo.size.height
                            teleprompter.viewportHeight = viewport.height
                        }
                        .onChange(of: textGeo.size.height) { _, h in
                            teleprompter.contentHeight = h
                        }
                }
            )
            // Start text below the top edge, then scroll up by `offset`.
            // The scroll timer already advances offset smoothly, so no implicit
            // animation is needed here (it would double the layout work over the live preview).
            .offset(y: viewport.height * 0.45 - teleprompter.offset)
            .scaleEffect(x: teleprompter.mirrored ? -1 : 1, y: 1)
    }

    private var controls: some View {
        VStack {
            // Top row: edit + mirror + close
            HStack(spacing: 14) {
                MiniControl(icon: "pencil") { showEditor = true }
                MiniControl(icon: teleprompter.mirrored ? "arrow.left.arrow.right.circle.fill"
                                                        : "arrow.left.arrow.right.circle",
                            active: teleprompter.mirrored) {
                    teleprompter.mirrored.toggle()
                }
                Spacer()
                MiniControl(icon: "xmark") {
                    withAnimation(.spring(response: 0.3)) { teleprompter.toggleEnabled() }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 52)

            Spacer()

            // Bottom row: scroll transport + speed + font + dim
            HStack(spacing: 10) {
                MiniControl(icon: teleprompter.isScrolling ? "pause.fill" : "play.fill",
                            active: teleprompter.isScrolling) {
                    teleprompter.toggleScroll()
                }
                MiniControl(icon: "gobackward") { teleprompter.reset() }

                Divider().frame(height: 22).overlay(Color.white.opacity(0.2))

                MiniControl(icon: "tortoise.fill") { teleprompter.adjustSpeed(-10) }
                Text("\(Int(teleprompter.speed))")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white).frame(width: 26)
                MiniControl(icon: "hare.fill") { teleprompter.adjustSpeed(10) }

                Divider().frame(height: 22).overlay(Color.white.opacity(0.2))

                MiniControl(icon: "textformat.size.smaller") { teleprompter.adjustFont(-3) }
                MiniControl(icon: "textformat.size.larger")  { teleprompter.adjustFont(3) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 22)
        }
    }
}

private struct MiniControl: View {
    let icon: String
    var active: Bool = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(active ? .orange : .white)
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.10))
                .clipShape(Circle())
        }
        .accessibilityLabel(a11yName(for: icon))
    }
}

// MARK: - Script Editor

struct ScriptEditorView: View {
    @ObservedObject var teleprompter: TeleprompterManager
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $draft)
                    .font(.system(size: 18, design: .rounded))
                    .padding(12)
                    .scrollContentBackground(.hidden)
                    .background(Color(.secondarySystemBackground))

                HStack {
                    Label("\(draft.split(whereSeparator: \.isWhitespace).count) words",
                          systemImage: "text.word.spacing")
                        .font(.footnote).foregroundColor(.secondary)
                    Spacer()
                    Text("~\(estimatedSeconds(draft))s at speaking pace")
                        .font(.footnote).foregroundColor(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .navigationTitle("Teleprompter Script")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        teleprompter.script = draft.isEmpty ? teleprompter.script : draft
                        teleprompter.reset()
                        dismiss()
                    }
                }
            }
            .onAppear { draft = teleprompter.script }
        }
    }

    private func estimatedSeconds(_ text: String) -> Int {
        let words = text.split(whereSeparator: \.isWhitespace).count
        // ~140 words per minute average speaking pace
        return Int(Double(words) / 140.0 * 60.0)
    }
}
