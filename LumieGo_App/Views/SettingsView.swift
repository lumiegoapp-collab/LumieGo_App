import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var camera: CameraManager
    @ObservedObject var auth: AuthManager
    @ObservedObject var trial: TrialManager
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var showFolderPicker = false
    @State private var showPaywall = false
    @State private var novamintTapCount = 0
    @State private var showDevPanel = false

    private let privacyURL = URL(string: "https://lumiegoapp-collab.github.io/LumieGo/privacy.html")!
    private let termsURL   = URL(string: "https://lumiegoapp-collab.github.io/LumieGo/terms.html")!
    private let supportURL = URL(string: "mailto:lumiego.app@gmail.com")!

    var body: some View {
        NavigationStack {
            List {
                // MARK: Subscription
                Section {
                    Button {
                        showPaywall = true
                    } label: {
                        HStack {
                            Label(trial.isPro ? "LumieGo Pro" : "Upgrade to LumieGo Pro",
                                  systemImage: "crown.fill")
                                .foregroundColor(.primary)
                            Spacer()
                            if trial.isPro {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.green)
                            } else {
                                Text(trial.trialLabel)
                                    .font(.subheadline)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                } header: { SectionHeader("Subscription") } footer: {
                    Text(trial.isPro
                         ? "You have full access to all LumieGo Pro features. Manage your subscription in your Apple ID settings."
                         : "Unlock dual camera, teleprompter, 4K recording, and unlimited length.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }

                // MARK: Account
                Section {
                    if !auth.displayName.isEmpty {
                        InfoRow(label: "Name", value: auth.displayName)
                    }
                    InfoRow(label: "Email", value: auth.email.isEmpty ? "Hidden by Apple" : auth.email)

                    Button {
                        auth.signOut()
                        dismiss()
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        if isDeleting {
                            HStack { ProgressView(); Text("Deleting…") }
                        } else {
                            Label("Delete Account", systemImage: "trash")
                        }
                    }
                    .disabled(isDeleting)
                } header: { SectionHeader("Account") } footer: {
                    Text("Signed in with Apple. Deleting your account permanently removes your data from our servers.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }

                // MARK: Video
                Section {
                    PickerRow(label: "Format", systemImage: "film", selection: $camera.videoFormat)
                    PickerRow(label: "Quality", systemImage: "4k.tv", selection: $camera.videoQuality)
                    frameRateRow()
                    PickerRow(label: "Anti-Flicker", systemImage: "bolt.horizontal", selection: $camera.antiFlicker)
                    ToggleRow(label: "Stabilization", systemImage: "wand.and.stars", isOn: $camera.isStabilizationEnabled)
                    ToggleRow(label: "Mirror Front Camera", systemImage: "arrow.left.arrow.right", isOn: $camera.frontMirrored)
                    ToggleRow(label: "Save Both Formats", systemImage: "rectangle.portrait.on.rectangle.portrait", isOn: $camera.saveBothFormats)
                    clipLimitRow()
                } header: { SectionHeader("Video") } footer: {
                    Text("Anti-Flicker constrains the shutter to align with your local mains frequency (50 Hz in Europe/Asia, 60 Hz in North America), reducing banding under artificial light. Mirror Front Camera flips the selfie feed horizontally. Save Both Formats records an extra file at the alternate orientation in every take.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }

                // MARK: Controls
                Section {
                    ToggleRow(label: "Volume Button Shutter", systemImage: "speaker.wave.2",
                              isOn: $camera.volumeShutterEnabled)
                    audioInputRow()
                } header: { SectionHeader("Controls") } footer: {
                    Text("Use the physical volume up or down button to start and stop recording. Microphone selects which input captures audio — useful with AirPods or a wired lav mic.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }

                // MARK: Saving
                Section {
                    PickerRow(label: "Save Recordings To", systemImage: "square.and.arrow.down",
                              selection: $camera.saveDestination)

                    if camera.saveDestination == .folder {
                        Button { showFolderPicker = true } label: {
                            HStack {
                                Label("Destination Folder", systemImage: "folder")
                                Spacer()
                                Text(camera.externalFolderName.isEmpty ? "Choose…" : camera.externalFolderName)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: { SectionHeader("Saving") } footer: {
                    Text(camera.saveDestination == .folder
                         ? "New recordings are copied to this folder (Files, iCloud Drive, or a connected external drive). A copy is always kept in the app too."
                         : "New recordings are saved to your Photos gallery, and a copy is kept in the app.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }

                // MARK: Guides
                Section {
                    NavigationLink {
                        SocialLayoutPicker(selection: $camera.socialGuide)
                    } label: {
                        HStack {
                            Label("Social Media Layout", systemImage: "square.grid.2x2")
                            Spacer()
                            Text(camera.socialGuide.rawValue).foregroundColor(.secondary)
                        }
                    }
                } header: { SectionHeader("Guides") } footer: {
                    Text("Overlays a platform's frame and caption-safe zones on screen. Guide only - it doesn't change the recorded video.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }

                // MARK: Info
                Section {
                    InfoRow(label: "Recordings", value: "\(camera.savedRecordings.count) saved")
                } header: { SectionHeader("Device") }

                // MARK: Legal
                Section {
                    Link(destination: privacyURL) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                    Link(destination: termsURL) {
                        Label("Terms of Service", systemImage: "doc.text")
                    }
                    Link(destination: supportURL) {
                        Label("Contact Support", systemImage: "envelope")
                    }
                } header: { SectionHeader("Legal") }

                // MARK: About
                Section {
                    InfoRow(label: "App",     value: "LumieGo")
                    InfoRow(label: "Version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))")
                    Button {
                        novamintTapCount += 1
                        if novamintTapCount >= 7 {
                            novamintTapCount = 0
                            showDevPanel = true
                        }
                    } label: {
                        InfoRow(label: "Powered by", value: "Novamint Labs")
                    }
                    .buttonStyle(.plain)
                } header: { SectionHeader("About") }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Delete Account?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    isDeleting = true
                    Task {
                        let ok = await auth.deleteAccount()
                        isDeleting = false
                        if ok { dismiss() }   // on failure, stay and show the error
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes your account and removes your data from our servers. This can't be undone.")
            }
            .alert("Couldn't Delete Account",
                   isPresented: Binding(get: { auth.errorMessage != nil },
                                        set: { if !$0 { auth.errorMessage = nil } })) {
                Button("OK") {}
            } message: { Text(auth.errorMessage ?? "") }
            .sheet(isPresented: $showFolderPicker) {
                FolderPicker { url in camera.setExternalFolder(url) }
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showPaywall) {
                PaywallSheet(trial: trial, isPresented: $showPaywall)
            }
            .sheet(isPresented: $showDevPanel) {
                DevPanelView(camera: camera, trial: trial)
            }
        }
    }
}

/// Lets the user pick a destination folder (Files, iCloud Drive, or an external drive).
struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}

// MARK: - Row components

struct PickerRow<T: RawRepresentable & CaseIterable & Hashable>: View
    where T.RawValue == String, T.AllCases: RandomAccessCollection {
    let label: String
    let systemImage: String
    @Binding var selection: T

    var body: some View {
        Picker(selection: $selection) {
            ForEach(T.allCases, id: \.self) { item in
                Text(item.rawValue).tag(item)
            }
        } label: {
            Label(label, systemImage: systemImage)
        }
    }
}

// FrameRate, clip limit, and audio input need custom rows:
extension SettingsView {
    func frameRateRow() -> some View {
        Picker(selection: $camera.frameRate) {
            ForEach(FrameRate.allCases, id: \.self) { fps in
                Text(fps.label).tag(fps)
            }
        } label: {
            Label("Frame Rate", systemImage: "speedometer")
        }
    }

    func clipLimitRow() -> some View {
        let options: [(label: String, secs: TimeInterval)] = [
            ("Off", 0), ("30 sec", 30), ("1 min", 60), ("3 min", 180),
            ("5 min", 300), ("10 min", 600), ("15 min", 900), ("30 min", 1800)
        ]
        return Picker(selection: $camera.clipDurationLimit) {
            ForEach(options, id: \.secs) { opt in
                Text(opt.label).tag(opt.secs)
            }
        } label: {
            Label("Clip Limit", systemImage: "timer")
        }
    }

    func audioInputRow() -> some View {
        Picker(selection: $camera.selectedAudioUID) {
            if camera.audioInputOptions.isEmpty {
                Text("Built-in Mic").tag("")
            }
            ForEach(camera.audioInputOptions) { opt in
                Text(opt.name).tag(opt.id)
            }
        } label: {
            Label("Microphone", systemImage: "mic")
        }
        .onChange(of: camera.selectedAudioUID) { _, uid in
            camera.selectAudioInput(uid: uid)
        }
    }
}

struct ToggleRow: View {
    let label: String
    let systemImage: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            Label(label, systemImage: systemImage)
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
    }
}

// MARK: - Social Media Layout grid

/// A grid of social platforms. Selecting one shows its on-screen safe-zone overlay;
/// only one can be active at a time.
struct SocialLayoutPicker: View {
    @Binding var selection: SocialPlatform
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(SocialPlatform.allCases) { platform in
                    Button {
                        selection = platform
                        dismiss()
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: platform.icon)
                                .font(.system(size: 26))
                            Text(platform.rawValue)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 92)
                        .foregroundColor(selection == platform ? .white : .primary)
                        .background(selection == platform ? Color.orange : Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .navigationTitle("Social Media Layout")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Developer Panel

/// Hidden panel unlocked by tapping "Novamint Labs" 7 times.
/// Shows live device/session state and, in debug builds, trial reset controls.
struct DevPanelView: View {
    @ObservedObject var camera: CameraManager
    @ObservedObject var trial: TrialManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    InfoRow(label: "Version",
                            value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))")
                    InfoRow(label: "Trial",       value: trial.isPro ? "Pro ✓" : trial.trialLabel)
                    InfoRow(label: "Thermal",     value: thermalLabel)
                    InfoRow(label: "Multi-Cam",   value: camera.isMultiCamSupported ? "Supported" : "Not available")
                    InfoRow(label: "Min Zoom",    value: String(format: "%.2f×", camera.minZoom))
                    InfoRow(label: "Format",      value: camera.videoFormat.rawValue)
                    InfoRow(label: "Quality",     value: camera.videoQuality.rawValue)
                    InfoRow(label: "Frame Rate",  value: camera.frameRate.label)
                    InfoRow(label: "Recordings",  value: "\(camera.savedRecordings.count) saved")
                } header: { SectionHeader("Session State") }

                #if DEBUG
                Section {
                    Button("Reset Trial (fresh 3-day start)") {
                        trial.debugResetTrial()
                    }
                    .foregroundColor(.orange)

                    Button("Expire Trial (simulate locked)") {
                        trial.debugExpireTrial()
                    }
                    .foregroundColor(.red)
                } header: { SectionHeader("Trial") }

                Section {
                    Button("Clear Recording Library") {
                        camera.savedRecordings.removeAll()
                    }
                    .foregroundColor(.red)
                } header: { SectionHeader("Data") } footer: {
                    Text("Removes items from the in-app list only. Files remain on disk.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                #endif
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Developer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var thermalLabel: String {
        switch camera.thermalState {
        case .nominal:  return "Nominal"
        case .fair:     return "Fair"
        case .serious:  return "Serious ⚠️"
        case .critical: return "Critical 🔴"
        @unknown default: return "Unknown"
        }
    }
}
