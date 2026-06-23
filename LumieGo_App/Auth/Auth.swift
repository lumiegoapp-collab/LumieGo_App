import SwiftUI
import Combine
import AuthenticationServices

// MARK: - Auth Manager

/// Handles Sign in with Apple, persists the signed-in user, verifies the Apple
/// credential on launch, and exposes sign-out / account-deletion (required by the
/// App Store when an app offers account creation).
@MainActor
final class AuthManager: ObservableObject {

    @Published var isSignedIn   = false
    @Published var userID       = ""
    @Published var displayName  = ""
    @Published var email        = ""
    @Published var errorMessage: String?

    private let kUserID = "auth.appleUserID"
    private let kName   = "auth.displayName"
    private let kEmail  = "auth.email"

    init() { restore() }

    /// Restore the last session and confirm the Apple credential is still valid.
    func restore() {
        let d = UserDefaults.standard
        guard let id = d.string(forKey: kUserID), !id.isEmpty else { return }
        userID = id
        displayName = d.string(forKey: kName) ?? ""
        email = d.string(forKey: kEmail) ?? ""

        ASAuthorizationAppleIDProvider().getCredentialState(forUserID: id) { [weak self] state, _ in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .authorized, .transferred:
                    self.isSignedIn = true
                    // Re-attempt the backend save on launch (idempotent upsert).
                    await SupabaseService.shared.upsertUser(
                        id: self.userID, name: self.displayName, email: self.email)
                case .revoked, .notFound:
                    self.signOut()
                default:
                    self.isSignedIn = true
                }
            }
        }
    }

    /// Configure the Apple ID request (called from SignInWithAppleButton).
    func configure(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
    }

    /// Handle the result from SignInWithAppleButton.
    func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let error):
            // A user cancel isn't a real error worth surfacing.
            if (error as? ASAuthorizationError)?.code == .canceled {
                errorMessage = nil
            } else {
                errorMessage = error.localizedDescription
            }

        case .success(let authorization):
            guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential else { return }
            let id = cred.user

            // Apple only returns name/email on the FIRST authorization - keep what we have otherwise.
            var name = displayName
            if let full = cred.fullName {
                let parts = [full.givenName, full.familyName].compactMap { $0 }.filter { !$0.isEmpty }
                if !parts.isEmpty { name = parts.joined(separator: " ") }
            }
            let mail = cred.email ?? email

            persist(id: id, name: name, email: mail)
            withAnimation(.easeInOut) { isSignedIn = true }

            // Save the signed-up user to the backend (best effort).
            Task {
                await SupabaseService.shared.upsertUser(id: id, name: name, email: mail)
            }
        }
    }

    func signOut() {
        let d = UserDefaults.standard
        [kUserID, kName, kEmail].forEach { d.removeObject(forKey: $0) }
        userID = ""; displayName = ""; email = ""
        withAnimation(.easeInOut) { isSignedIn = false }
    }

    /// App Store Guideline 5.1.1(v): account creation requires in-app account deletion.
    /// Returns false (and keeps the user signed in) if the server deletion failed.
    @discardableResult
    func deleteAccount() async -> Bool {
        if !userID.isEmpty {
            let ok = await SupabaseService.shared.deleteUser(id: userID)
            guard ok else {
                errorMessage = "We couldn't delete your account right now. Check your connection and try again."
                return false
            }
        }
        signOut()
        return true
    }

    private func persist(id: String, name: String, email: String) {
        userID = id; displayName = name; self.email = email
        let d = UserDefaults.standard
        d.set(id, forKey: kUserID)
        d.set(name, forKey: kName)
        d.set(email, forKey: kEmail)
    }
}

// MARK: - Supabase Service

/// Stores signed-up users in Supabase via its REST (PostgREST) API - no extra
/// SDK/package required. Fill in `baseURL` and `anonKey` from your Supabase
/// project (Project Settings → API). Until then, calls are safely skipped.
struct SupabaseService {
    static let shared = SupabaseService()

    // Supabase project values (publishable key is safe to ship in a client app).
    private let baseURL = "https://dvdnvgmfemfrhbubokem.supabase.co"
    private let anonKey = "sb_publishable_U7_vEhoKQGPRWgK_NvzELg_fLy5m7Ld"
    private let table   = "users"

    var isConfigured: Bool { !baseURL.isEmpty && !anonKey.isEmpty }

    /// Save the signed-up user. Uses a plain insert (the public key has no SELECT policy,
    /// so an `on_conflict` upsert - which must read existing rows - is rejected by RLS).
    /// A duplicate (409) just means the user is already saved, which we treat as success.
    ///
    /// `return=minimal` is intentional: the anon key has no SELECT policy, so asking
    /// PostgREST to read the row back (return=representation) would fail with a misleading
    /// 401 even when the insert itself succeeded. With return=minimal the insert commits
    /// and we get a clean 201, which is the real signal of success.
    @discardableResult
    func upsertUser(id: String, name: String, email: String) async -> String {
        guard isConfigured, let url = URL(string: "\(baseURL)/rest/v1/\(table)") else {
            return "Supabase not configured"
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // New-style sb_publishable_ keys are opaque, not JWTs - send only as apikey.
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        let row: [String: Any] = ["apple_user_id": id, "name": name, "email": email]
        req.httpBody = try? JSONSerialization.data(withJSONObject: row)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if (200..<300).contains(code) { return "Saved to Supabase ✓ (\(code))" }
            if code == 409 { return "Already saved ✓" }   // unique apple_user_id → already signed up
            let body = String(data: data, encoding: .utf8) ?? ""
            return "Supabase \(code): \(body)"
        } catch {
            return "Supabase request failed: \(error.localizedDescription)"
        }
    }

    /// Returns true if the user's row was removed (or there was nothing to remove).
    func deleteUser(id: String) async -> Bool {
        guard isConfigured,
              let url = URL(string: "\(baseURL)/rest/v1/\(table)?apple_user_id=eq.\(id)") else {
            return false
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            return (200..<300).contains(code)   // 204 = deleted
        } catch {
            return false
        }
    }
}

// MARK: - Root Gate

/// Shows the login screen until the user signs in, then the camera.
struct RootView: View {
    @StateObject private var auth = AuthManager()
    @AppStorage("hasSeenOnboarding_v2") private var hasSeenOnboarding = false

    var body: some View {
        Group {
            if !hasSeenOnboarding {
                OnboardingView(done: { hasSeenOnboarding = true })
                    .transition(.opacity)
            } else if auth.isSignedIn {
                MainCameraView()
                    .environmentObject(auth)
            } else {
                LoginView(auth: auth)
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Login View

struct LoginView: View {
    @ObservedObject var auth: AuthManager

    // Replace these with your live URLs before submitting to the App Store.
    private let termsURL   = URL(string: "https://lumiegoapp-collab.github.io/LumieGo/terms.html")!
    private let privacyURL = URL(string: "https://lumiegoapp-collab.github.io/LumieGo/privacy.html")!

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.06, green: 0.07, blue: 0.10),
                                    Color.black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Brand mark - the LumieGo logo
                Image("LogoMark")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 104, height: 104)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: .orange.opacity(0.4), radius: 20, y: 8)

                Text("LumieGo")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.top, 18)

                Text("Dual-camera recording, built for creators.")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                    .padding(.horizontal, 40)

                Spacer()

                // Feature bullets - what creators get
                VStack(alignment: .leading, spacing: 13) {
                    featureRow("person.2.fill", "Film front + back together - like a two-person crew")
                    featureRow("text.alignleft", "Built-in teleprompter - read while you record")
                    featureRow("square.grid.2x2", "Reels, TikTok & YouTube-ready with safe-zone guides")
                    featureRow("sparkles", "Start free — subscribe to keep creating")
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 34)

                // Sign in with Apple
                SignInWithAppleButton(.continue,
                    onRequest: auth.configure,
                    onCompletion: auth.handle)
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 52)
                    .clipShape(Capsule())
                    .padding(.horizontal, 32)

                // Legal
                VStack(spacing: 2) {
                    Text("By continuing you agree to our")
                        .foregroundColor(.white.opacity(0.5))
                    HStack(spacing: 4) {
                        Link("Terms of Service", destination: termsURL)
                            .foregroundColor(.orange)
                        Text("and").foregroundColor(.white.opacity(0.5))
                        Link("Privacy Policy", destination: privacyURL)
                            .foregroundColor(.orange)
                    }
                }
                .font(.system(size: 11))
                .padding(.top, 16)

                Text("Powered by Novamint Labs")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.top, 10)
                    .padding(.bottom, 24)
            }
        }
        .alert("Sign-in failed",
               isPresented: Binding(get: { auth.errorMessage != nil },
                                    set: { if !$0 { auth.errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(auth.errorMessage ?? "") }
    }

    private func featureRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.orange)
                .frame(width: 26)
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.85))
            Spacer(minLength: 0)
        }
    }
}

#Preview("Login") {
    LoginView(auth: AuthManager())
}
