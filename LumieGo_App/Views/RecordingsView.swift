import SwiftUI
import AVKit

struct RecordingsView: View {
    @ObservedObject var camera: CameraManager
    @Environment(\.dismiss) private var dismiss
    @State private var playerItem: RecordingItem?
    @State private var deleteItem: RecordingItem?
    @State private var shareURL: URL?
    @State private var exportURL: URL?

    let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            Group {
                if camera.savedRecordings.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(camera.savedRecordings) { item in
                                RecordingCell(item: item)
                                    .overlay(alignment: .topTrailing) {
                                        Button { shareURL = item.url } label: {
                                            Image(systemName: "square.and.arrow.up")
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundColor(.white)
                                                .frame(width: 30, height: 30)
                                                .background(Color.black.opacity(0.5))
                                                .clipShape(Circle())
                                        }
                                        .padding(5)
                                    }
                                    .onTapGesture { playerItem = item }
                                    .contextMenu {
                                        Button { shareURL = item.url } label: {
                                            Label("Share", systemImage: "square.and.arrow.up")
                                        }
                                        Button { exportURL = item.url } label: {
                                            Label("Export to Files", systemImage: "folder")
                                        }
                                        Button(role: .destructive) { deleteItem = item } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(item: $playerItem) { item in
            VideoPlayerView(url: item.url)
        }
        .sheet(item: Binding(
            get: { shareURL.map { ShareWrapper(url: $0) } },
            set: { shareURL = $0?.url }
        )) { wrapper in
            ShareSheet(url: wrapper.url)
        }
        .sheet(item: Binding(
            get: { exportURL.map { ShareWrapper(url: $0) } },
            set: { exportURL = $0?.url }
        )) { wrapper in
            DocumentExporter(url: wrapper.url)
        }
        .alert("Delete recording?", isPresented: Binding(
            get: { deleteItem != nil },
            set: { if !$0 { deleteItem = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let item = deleteItem { camera.deleteRecording(item) }
                deleteItem = nil
            }
            Button("Cancel", role: .cancel) { deleteItem = nil }
        }
    }

    var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 52))
                .foregroundColor(.secondary)
            Text("No recordings yet")
                .font(.title3)
            Text("Start recording to see your clips here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }
}

struct RecordingCell: View {
    let item: RecordingItem

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let thumb = item.thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.3))
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(9/16, contentMode: .fit)
            .clipped()

            // Duration badge
            Text(durationText)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    var durationText: String {
        let m = Int(item.duration) / 60, s = Int(item.duration) % 60
        return String(format: "%d:%02d", m, s)
    }
}

struct VideoPlayerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VideoPlayer(player: AVPlayer(url: url))
                .ignoresSafeArea()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Saves a copy of the recording to a Files location the user picks,
/// including iCloud Drive and connected external drives.
struct DocumentExporter: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.shouldShowFileExtensions = true
        return picker
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
}

struct ShareWrapper: Identifiable {
    let id = UUID()
    let url: URL
}
