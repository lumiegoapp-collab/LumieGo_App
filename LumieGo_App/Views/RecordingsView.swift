import SwiftUI
import AVKit

// MARK: - Category filter

enum RecordingCategory: String, CaseIterable {
    case all       = "All"
    case photo     = "Photos"
    case portrait  = "Portrait"
    case landscape = "Landscape"
    case pip       = "PiP"
    case front     = "Front"

    var icon: String {
        switch self {
        case .all:       return "square.grid.2x2"
        case .photo:     return "camera.fill"
        case .portrait:  return "iphone"
        case .landscape: return "rectangle.landscape"
        case .pip:       return "square.on.square"
        case .front:     return "person.crop.square"
        }
    }

    func matches(_ tag: RecordingTag) -> Bool {
        switch self {
        case .all:       return true
        case .photo:     return tag == .photo
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
    @State private var photoItem:   RecordingItem?
    @State private var deleteItem:  RecordingItem?
    @State private var shareURL:    URL?
    @State private var exportURL:   URL?
    @State private var selectedCategory: RecordingCategory = .all

    private let gap: CGFloat = 1.5
    private let columns = [
        GridItem(.flexible(), spacing: 1.5),
        GridItem(.flexible(), spacing: 1.5),
        GridItem(.flexible(), spacing: 1.5)
    ]

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
                    Text("\(filtered.count) \(filtered.count == 1 ? "item" : "items")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .sheet(item: $playerItem) { item in
            GalleryPlayerView(item: item)
        }
        .sheet(item: $photoItem) { item in
            GalleryPhotoView(item: item)
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
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: gap) {
                ForEach(filtered) { item in
                    GalleryCell(item: item)
                        .onTapGesture {
                            if item.tag == .photo { photoItem = item }
                            else { playerItem = item }
                        }
                        .contextMenu { contextMenu(for: item) }
                }
            }
            .padding(.top, gap)
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func contextMenu(for item: RecordingItem) -> some View {
        if item.tag == .photo {
            Button { photoItem = item } label: {
                Label("View Photo", systemImage: "photo")
            }
        } else {
            Button { playerItem = item } label: {
                Label("Play", systemImage: "play.fill")
            }
            Button { exportURL = item.url } label: {
                Label("Export to Files", systemImage: "folder")
            }
        }
        Button { shareURL = item.url } label: {
            Label("Share", systemImage: "square.and.arrow.up")
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
            Text("No \(selectedCategory.rawValue)")
                .font(.headline)
                .foregroundColor(.white)
            Text(selectedCategory == .photo
                 ? "Your photos will appear here after capturing in photo mode."
                 : "Record in \(selectedCategory.rawValue.lowercased()) mode to see clips here.")
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
            .foregroundColor(selected ? .primary : .white.opacity(0.75))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .glassEffect(selected ? .regular.tint(.white).interactive() : .regular.interactive())
    }
}

// MARK: - Gallery Cell

struct GalleryCell: View {
    let item: RecordingItem

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Thumbnail or placeholder
                if let thumb = item.thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.width)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.07))
                        .frame(width: geo.size.width, height: geo.size.width)
                        .overlay(
                            Image(systemName: item.tag.icon)
                                .font(.system(size: 20))
                                .foregroundColor(.white.opacity(0.25))
                        )
                }

                // Scrim + overlays
                VStack {
                    // Tag badge — top right
                    HStack {
                        Spacer()
                        TagBadge(tag: item.tag)
                            .padding(5)
                    }
                    Spacer()
                    // Duration — bottom left
                    HStack {
                        Text(durationText)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                            .padding(.horizontal, 5)
                            .padding(.bottom, 5)
                        Spacer()
                    }
                }
                .frame(width: geo.size.width, height: geo.size.width)
                // Subtle vignette so text is readable without a heavy scrim
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.18), .clear, .black.opacity(0.35)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
        }
        .aspectRatio(1, contentMode: .fit) // square cell
    }

    private var durationText: String {
        if item.tag == .photo { return "Photo" }
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
        case .photo:     return Color(red: 0.9, green: 0.9, blue: 0.9)
        }
    }

    var body: some View {
        Text(tag.shortLabel)
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.55), lineWidth: 0.5))
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

// MARK: - Full-screen photo viewer

struct GalleryPhotoView: View {
    let item: RecordingItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let img = item.thumbnail {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            }
            VStack {
                HStack {
                    Spacer()
                    Button {
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
    }
}
