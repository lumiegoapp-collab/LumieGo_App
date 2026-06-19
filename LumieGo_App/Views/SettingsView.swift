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
                    ToggleRow(label: "Stabilization", systemImage: "wand.and.stars", isOn: $camera.isStabilizationEnabled)
                } header: { SectionHeader("Video") }

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
                    InfoRow(label: "Version", value: "1.0")
                    InfoRow(label: "Powered by", value: "Novamint Labs")
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

// FrameRate doesn't have String raw value, so a custom version:
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
