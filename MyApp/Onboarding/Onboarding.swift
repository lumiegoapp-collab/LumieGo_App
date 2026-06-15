import SwiftUI

// MARK: - Onboarding

/// First-launch intro for creators: 3 swipeable screens with custom-drawn icons,
/// followed by the sign-up screen. Shown once (tracked via @AppStorage).
struct OnboardingView: View {
    let done: () -> Void

    @State private var page = 0
    private let count = 3

    private var isLast: Bool { page == count - 1 }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.06, green: 0.07, blue: 0.10), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Skip") { finish() }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                        .padding(.trailing, 20).padding(.top, 12)
                        .opacity(isLast ? 0 : 1)
                        .allowsHitTesting(!isLast)
                        .accessibilityHidden(isLast)
                }

                TabView(selection: $page) {
                    creatorPage(
                        icon: AnyView(DualCamIcon()),
                        title: "Shoot like a\ntwo-person crew",
                        subtitle: "Capture you and your scene at the same time - front and back cameras in one video, no extra gear or second phone."
                    ).tag(0)

                    creatorPage(
                        icon: AnyView(TeleprompterIcon()),
                        title: "Never lose\nyour lines",
                        subtitle: "Read your script on-screen while you record. Adjustable speed, size and mirror - made for talking straight to camera."
                    ).tag(1)

                    creatorPage(
                        icon: AnyView(PlatformIcon()),
                        title: "Ready to post\nanywhere",
                        subtitle: "Frame for Reels, TikTok and YouTube with safe-zone guides, then save straight to your library - post-ready every time."
                    ).tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: page)

                // Dots
                HStack(spacing: 8) {
                    ForEach(0..<count, id: \.self) { i in
                        Capsule()
                            .fill(i == page ? Color.orange : Color.white.opacity(0.25))
                            .frame(width: i == page ? 22 : 7, height: 7)
                            .animation(.spring(response: 0.3), value: page)
                    }
                }
                .padding(.bottom, 26)

                Button {
                    if isLast { finish() } else { withAnimation { page += 1 } }
                } label: {
                    Text(isLast ? "Get Started" : "Continue")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(LinearGradient(colors: [.orange, .pink],
                                                   startPoint: .leading, endPoint: .trailing))
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 28).padding(.bottom, 30)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func creatorPage(icon: AnyView, title: String, subtitle: String) -> some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.orange.opacity(0.95), .pink.opacity(0.95)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 150, height: 150)
                    .shadow(color: .orange.opacity(0.4), radius: 28, y: 12)
                icon
            }
            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.top, 42)
            Text(subtitle)
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.68))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 14).padding(.horizontal, 34)
            Spacer(); Spacer()
        }
    }

    private func finish() { withAnimation { done() } }
}

// MARK: - Custom creator icons (drawn, not SF Symbols)

/// Dual camera: a phone with the main subject + a picture-in-picture bubble.
private struct DualCamIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white, lineWidth: 4)
                .frame(width: 58, height: 84)
            Image(systemName: "person.fill")
                .font(.system(size: 38))
                .foregroundColor(.white.opacity(0.92))
            // PiP bubble, top-right
            Circle()
                .fill(Color.white)
                .frame(width: 26, height: 26)
                .overlay(Image(systemName: "person.fill").font(.system(size: 12, weight: .bold))
                    .foregroundColor(.orange))
                .overlay(Circle().stroke(Color.orange, lineWidth: 2))
                .offset(x: 16, y: -28)
        }
    }
}

/// Teleprompter: scrolling script lines with a highlighted reading line.
private struct TeleprompterIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white, lineWidth: 4)
                .frame(width: 84, height: 64)
            VStack(spacing: 8) {
                Capsule().fill(Color.white.opacity(0.55)).frame(width: 44, height: 6)
                Capsule().fill(Color.white).frame(width: 56, height: 7)            // current line
                Capsule().fill(Color.white.opacity(0.55)).frame(width: 38, height: 6)
            }
            // play badge
            Circle().fill(Color.white).frame(width: 24, height: 24)
                .overlay(Image(systemName: "play.fill").font(.system(size: 11)).foregroundColor(.pink))
                .offset(x: 32, y: 26)
        }
    }
}

/// Platforms: overlapping landscape (16:9) and portrait (9:16) frames with a play mark.
private struct PlatformIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 4)
                .frame(width: 92, height: 52)
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white, lineWidth: 4)
                .frame(width: 50, height: 88)
            Image(systemName: "play.fill")
                .font(.system(size: 22))
                .foregroundColor(.white)
        }
    }
}

#Preview("Onboarding") {
    OnboardingView(done: {})
}
