import SwiftUI
import AVKit

// MARK: - Category filter

enum RecordingCategory: String, CaseIterable {
    case all       = "All"
    case portrait  = "Portrait"
    case landscape = "Landscape"
    case pip       = "PiP"
    case front     = "Front"

    var icon: String {
        switch self {
        case .all:       return "square.grid.2x2"
        case .portrait:  return "iphone"
        case .landscape: return "rectangle.landscape"
        case .pip:       return "square.on.square"
        case .front:     return "person.crop.square"
        }
    }

    func matches(_ tag: RecordingTag) -> Bool {
        switch self {
        case .all:       return true
        case .portrait:  return tag == .portrait
        case .landscape: return tag == .landscape
        case .pip:       return tag == .pip
        case .front:     return tag == .front
        }
    }
}

// MARK: - Gallery View

struct RecordingsView: View {
    @ObservedObject var camera: CameraManager
    @Environment(\.dismiss) private var dismiss

    @State private var playerItem:  RecordingItem?
    @State private var deleteItem:  RecordingItem?
    @State private var shareURL:    URL?
    @State private var exportURL:   URL?
    @State private var selectedCategory: RecordingCategory = .all

    private let columns = [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]

    private var filtered: [RecordingItem] {
        camera.savedRecordings.filter { selectedCategory.matches($0.tag) }
    }

    private var presentCategories: [RecordingCategory] {
        RecordingCategory.allCases.filter { cat in
            cat == .all || camera.savedRecordings.contains { cat.matches($0.tag) }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if camera.savedRecordings.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        categoryBar
                        if filtered.isEmpty {
                            filteredEmptyState
                        } else {
                            clipGrid
                        }
                    }
                }
            }
            .navigationTitle("Gallery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Text("\(filtered.count) \(filtered.count == 1 ? "clip" : "clips")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .sheet(item: $playerItem) { item in
            GalleryPlayerView(item: item)
        }
        .sheet(item: Binding(
            get: { shareURL.map  { ShareWrapper(url: $0) } },
            set: { shareURL  = $0?.url }
        )) { w in ShareSheet(url: w.url) }
        .sheet(item: Binding(
            get: { exportURL.map { ShareWrapper(url: $0) } },
            set: { exportURL = $0?.url }
        )) { w in DocumentExporter(url: w.url) }
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

    // MARK: Category bar

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(presentCategories, id: \.self) { cat in
                    CategoryChip(
                        label: cat.rawValue,
                        icon: cat.icon,
                        selected: selectedCategory == cat
                    ) {
                        withAnimation(.spring(response: 0.28)) { selectedCategory = cat }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: Grid

    private var clipGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(filtered) { item in
                    GalleryCell(item: item)
                        .onTapGesture   { playerItem = item }
                        .contextMenu    { contextMenu(for: item) }
                        .overlay(alignment: .topTrailing) {
                            shareButton(for: item)
                        }
                }
            }
        }
    }

    // MARK: Share overlay button

    @ViewBuilder
    private func shareButton(for item: RecordingItem) -> some View {
        Button { shareURL = item.url } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(.ultraThinMaterial, in: Circle())
        }
        .padding(6)
    }

    // MARK: Context menu

    @ViewBuilder
    private func contextMenu(for item: RecordingItem) -> some View {
        Button { playerItem = item } label: {
            Label("Play", systemImage: "play.fill")
        }
        Button { shareURL = item.url } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        Button { exportURL = item.url } label: {
            Label("Export to Files", systemImage: "folder")
        }
        Divider()
        Button(role: .destructive) { deleteItem = item } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: Empty states

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.on.rectangle")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No recordings yet")
                .font(.title3.weight(.semibold))
                .foregroundColor(.white)
            Text("Your clips will appear here after you record.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: selectedCategory.icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No \(selectedCategory.rawValue) clips")
                .font(.headline)
                .foregroundColor(.white)
            Text("Record in \(selectedCategory.rawValue.lowercased()) mode to see clips here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Category Chip

struct CategoryChip: View {
    let label: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(selected ? .black : .white.opacity(0.75))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selected ? Color.white : Color.white.opacity(0.10),
                        in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Gallery Cell

struct GalleryCell: View {
    let item: RecordingItem

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let thumb = item.thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.07))
                        .overlay(
                            Image(systemName: item.tag.icon)
                                .font(.system(size: 24))
                                .foregroundColor(.white.opacity(0.3))
                        )
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(9/16, contentMode: .fit)
            .clipped()

            // Bottom info bar
            HStack(spacing: 0) {
                Text(durationText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                TagBadge(tag: item.tag)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.65)],
                    startPoint: .top, endPoint: .bottom
                )
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var durationText: String {
        let m = Int(item.duration) / 60
        let s = Int(item.duration) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Tag Badge

struct TagBadge: View {
    let tag: RecordingTag

    private var color: Color {
        switch tag {
        case .portrait:  return .orange
        case .landscape: return Color(red: 0.3, green: 0.9, blue: 1.0)
        case .pip:       return Color(red: 0.75, green: 0.5, blue: 1.0)
        case .front:     return .green
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: tag.icon)
                .font(.system(size: 8, weight: .semibold))
            Text(tag.shortLabel)
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(color.opacity(0.18), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 0.5))
    }
}

// MARK: - Full-screen player

struct GalleryPlayerView: View {
    let item: RecordingItem
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer

    init(item: RecordingItem) {
        self.item = item
        _player = State(initialValue: AVPlayer(url: item.url))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    Button {
                        player.pause()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(.trailing, 16)
                }
                .padding(.top, 54)
                Spacer()
            }
        }
        .onAppear  { player.play() }
        .onDisappear { player.pause() }
    }
}

// MARK: - Reused helpers

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

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
    let id  = UUID()
    let url: URL
}
