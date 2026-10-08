import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO
import QuickLookThumbnailing
import Vision
import AVFoundation

@main
struct SpeedRAWApp: App {
    var body: some Scene {
        WindowGroup("Speed RAW") {
            ContentView()
                .frame(minWidth: 1100, minHeight: 700)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Открыть папку…") { NotificationCenter.default.post(name: .openFolder, object: nil) }
                    .keyboardShortcut("o", modifiers: [.command])
            }
        }
    }
}

extension Notification.Name {
    static let openFolder = Notification.Name("SpeedRAW.openFolder")
}

struct PhotoItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var rating: Int = 0
    var label: String = ""
    var orientation: OrientationFilter = .landscape
    var captureDate: Date?
    var camera: String = ""
    var lens: String = ""
    var aperture: String = ""
    var shutter: String = ""
    var iso: String = ""
    var flash: String = "Без вспышки"
    var peopleCount: Int = 0
}

enum RatingFilter: String, CaseIterable, Identifiable {
    case all = "Все"
    case none = "Без оценки"
    case one = "1★"
    case two = "2★"
    case three = "3★"
    case four = "4★"
    case five = "5★"
    case threePlus = "3★+"
    case fourPlus = "4★+"
    case selected = "Только выбранные"
    var id: String { rawValue }
}

enum OrientationFilter: String, CaseIterable, Identifiable { case all="Все", landscape="Горизонтальные", portrait="Вертикальные"; var id:String{rawValue} }

enum ColorFilter: String, CaseIterable, Identifiable {
    case all = "Все"
    case none = "Без цвета"
    case red = "Красный"
    case yellow = "Жёлтый"
    case green = "Зелёный"
    case blue = "Синий"
    case purple = "Фиолетовый"
    var id: String { rawValue }
}

@MainActor
final class Library: ObservableObject {
    @Published var items: [PhotoItem] = []
    @Published var index = 0
    @Published var ratingFilter: RatingFilter = .all
    @Published var colorFilter: ColorFilter = .all
    @Published var orientationFilter: OrientationFilter = .all
    @Published var autoAdvance = true
    @Published var folderName = "Папка не открыта"
    @Published var status = "Откройте папку с фотографиями"
    @Published var selectedIDs: Set<UUID> = []
    @Published var compareMode = false
    @Published var zoom: CGFloat = 1
    @Published var currentFolder: URL?
    @Published var sidebarRoots: [FolderNode] = []
    @Published var eyeCrop: CGImage?
    @Published var eyeFound = false
    @Published var exportSettings = ExportSettings()
    @Published var exportStatus = ""

    var filtered: [PhotoItem] {
        items.filter { item in
            let rOK: Bool = {
                switch ratingFilter {
                case .all: return true
                case .none: return item.rating == 0
                case .one: return item.rating == 1
                case .two: return item.rating == 2
                case .three: return item.rating == 3
                case .four: return item.rating == 4
                case .five: return item.rating == 5
                case .threePlus: return item.rating >= 3
                case .fourPlus: return item.rating >= 4
                case .selected: return item.rating > 0
                }
            }()
            let cOK: Bool = {
                switch colorFilter {
                case .all: return true
                case .none: return item.label.isEmpty
                case .red: return item.label == "Red"
                case .yellow: return item.label == "Yellow"
                case .green: return item.label == "Green"
                case .blue: return item.label == "Blue"
                case .purple: return item.label == "Purple"
                }
            }()
            return rOK && cOK && (orientationFilter == .all || item.orientation == orientationFilter)
        }
    }

    var current: PhotoItem? {
        guard !filtered.isEmpty, index >= 0, index < filtered.count else { return nil }
        return filtered[index]
    }
    // In culling mode a photo becomes "selected" as soon as it receives a rating.
    // Explicit selection remains available for compare/Select actions.
    var selectedCount: Int { items.reduce(0) { $0 + ($1.rating > 0 ? 1 : 0) } }
    var selectedPercent: Double { items.isEmpty ? 0 : Double(selectedCount) / Double(items.count) * 100 }
    var compareItems: [PhotoItem] { Array(filtered.filter { selectedIDs.contains($0.id) }.prefix(2)) }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Открыть"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func load(_ folder: URL) {
        currentFolder = folder
        folderName = folder.lastPathComponent
        status = "Сканирование…"
        sidebarRoots = FileBrowser.roots()
        DispatchQueue.global(qos: .userInitiated).async {
            let exts = Set(["jpg","jpeg","png","heic","heif","cr2","cr3","nef","arw","raf","rw2","orf","dng"])
            let urls = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])?
                .compactMap { $0 as? URL }
                .filter { exts.contains($0.pathExtension.lowercased()) }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) ?? []
            let loaded = urls.map { Metadata.read($0) }
                .sorted { ($0.captureDate ?? .distantPast, $0.url.path) < ($1.captureDate ?? .distantPast, $1.url.path) }
            DispatchQueue.main.async {
                self.items = loaded
                self.index = 0
                self.selectedIDs.removeAll()
                self.compareMode = false
                self.status = "\(loaded.count) файлов • сортировка по времени съёмки"
                self.updateEyePreview()
            }
        }
    }

    func loadFromSidebar(_ url: URL) {
        guard url.hasDirectoryPath else { return }
        load(url)
    }

    func createFolder() {
        guard let base = currentFolder else { return }
        let alert = NSAlert()
        alert.messageText = "Новая папка"
        alert.informativeText = "Введите название:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = "Новая папка"
        alert.accessoryView = field
        alert.addButton(withTitle: "Создать")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        try? FileManager.default.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true)
        sidebarRoots = FileBrowser.roots()
    }

    func rotateCurrent(clockwise: Bool) {
        guard let item = current else { return }
        // Store a reversible rotation preference in XMP without touching the original pixels.
        XMP.setOrientation(for: item.url, clockwise: clockwise)
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i].orientation = ImageInfo.orientation(for: item.url)
        }
        status = clockwise ? "Поворот по часовой" : "Поворот против часовой"
    }

    func exportCurrentJPEG() {
        guard let item = current else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.url.deletingPathExtension().lastPathComponent + ".jpg"
        panel.allowedContentTypes = [.jpeg]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try Exporter.exportJPEG(item, settings: exportSettings, destination: url.deletingLastPathComponent())
            exportStatus = "JPEG готов"
            status = "Экспортировано: \(url.lastPathComponent)"
        } catch {
            status = "Ошибка экспорта: \(error.localizedDescription)"
        }
    }

    func rate(_ value: Int) {
        guard let current else { return }
        guard let i = items.firstIndex(where: { $0.id == current.id }) else { return }
        XMP.write(rating: value, label: items[i].label, for: items[i].url)
        items[i].rating = value
        status = "\\(value)★  •  \\(items[i].url.lastPathComponent)"
        if autoAdvance { move(1) }
    }

    func color(_ label: String) {
        guard let current else { return }
        guard let i = items.firstIndex(where: { $0.id == current.id }) else { return }
        XMP.write(rating: items[i].rating, label: label, for: items[i].url)
        items[i].label = label
        status = "\\(label)  •  \\(items[i].url.lastPathComponent)"
        if autoAdvance { move(1) }
    }

    func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        index = min(max(index + delta, 0), filtered.count - 1)
        zoom = 1
        updateEyePreview()
    }

    func toggleSelected() { guard let c=current else{return}; if selectedIDs.contains(c.id){selectedIDs.remove(c.id)}else{selectedIDs.insert(c.id)} }
    func selectAll() { selectedIDs.formUnion(filtered.map{$0.id}); status="Выбрано \(selectedCount) из \(items.count)" }
    func toggleCompare() { compareMode = compareItems.count == 2 }

    func updateEyePreview() {
        guard let current else { eyeCrop = nil; eyeFound = false; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = VisionAnalysis.eyeCrop(for: current.url)
            DispatchQueue.main.async {
                self.eyeCrop = result.crop
                self.eyeFound = result.found
            }
        }
    }

    func clearRating() {
        guard let current, let i = items.firstIndex(where: { $0.id == current.id }) else { return }
        XMP.write(rating: 0, label: items[i].label, for: items[i].url)
        items[i].rating = 0
    }
}

struct ContentView: View {
    @StateObject private var lib = Library()
    @State private var showFilterControls = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { lib.openFolder() } label: { Label("Открыть папку", systemImage: "folder") }
                Button { lib.rotateCurrent(clockwise: false) } label: { Image(systemName: "rotate.left") }
                Button { lib.rotateCurrent(clockwise: true) } label: { Image(systemName: "rotate.right") }
                Button { lib.exportCurrentJPEG() } label: { Label("JPEG", systemImage: "arrow.down.doc") }
                Text(lib.folderName).font(.headline).lineLimit(1)
                Spacer()
                Button(lib.compareItems.count == 2 ? "Сравнить" : "Выбрать 2 фото") { lib.toggleCompare() }
                    .disabled(lib.compareItems.count != 2)
                Button(lib.selectedIDs.contains(lib.current?.id ?? UUID()) ? "Снять выбор" : "Выбрать") { lib.toggleSelected() }
                    .disabled(lib.current == nil)
                Toggle("Автопереход", isOn: $lib.autoAdvance)
                Button(showFilterControls ? "Скрыть фильтры" : "Фильтры") { showFilterControls.toggle() }
            }
            .padding(10)

            Divider()

            HStack(spacing: 0) {
                // Левая колонка: сначала дерево папок, затем ближайшие кадры.
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("ПАПКИ И ДИСКИ").font(.caption.bold()).foregroundStyle(.secondary)
                            Spacer()
                            Button { lib.createFolder() } label: {
                                Image(systemName: "folder.badge.plus")
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(lib.sidebarRoots) { node in
                                    FolderRow(node: node, depth: 0) { lib.loadFromSidebar($0) }
                                }
                            }
                            .padding(.vertical, 5)
                        }
                    }
                    .frame(maxHeight: .infinity)

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("БЛИЖАЙШИЕ КАДРЫ").font(.caption.bold()).foregroundStyle(.secondary)
                            Spacer()
                            Text("±3").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.top, 8)

                        NearbyStrip(lib: lib)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                    }
                    .frame(height: 330)

                    if showFilterControls {
                        Divider()
                        VStack(alignment: .leading, spacing: 7) {
                            Text("ФИЛЬТРЫ").font(.caption.bold()).foregroundStyle(.secondary)
                            Picker("Оценка", selection: $lib.ratingFilter) {
                                ForEach(RatingFilter.allCases) { Text($0.rawValue).tag($0) }
                            }.pickerStyle(.menu)
                            Picker("Цвет", selection: $lib.colorFilter) {
                                ForEach(ColorFilter.allCases) { Text($0.rawValue).tag($0) }
                            }.pickerStyle(.menu)
                            Picker("Ориентация", selection: $lib.orientationFilter) {
                                ForEach(OrientationFilter.allCases) { Text($0.rawValue).tag($0) }
                            }.pickerStyle(.menu)
                            Text("\(lib.filtered.count) из \(lib.items.count)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(10)
                    }
                }
                .frame(width: 300)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipped()

                Divider()

                // Центр: максимально большое фото.
                VStack(spacing: 0) {
                    HStack {
                        Text(lib.current?.url.lastPathComponent ?? "Speed RAW")
                            .font(.headline).lineLimit(1)
                        Spacer()
                        if !lib.filtered.isEmpty {
                            Text("\(lib.index + 1) / \(lib.filtered.count)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)

                    ZStack {
                        Color.black
                        if let item = lib.current {
                            if lib.compareMode {
                                CompareView(lib: lib)
                            } else {
                                ZoomablePreview(url: item.url, zoom: $lib.zoom)
                            }
                        } else {
                            VStack(spacing: 8) {
                                Text("Speed RAW").font(.largeTitle.bold())
                                Text("Откройте папку с RAW/JPEG").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .overlay {
                        if let item = lib.current {
                            RoundedRectangle(cornerRadius: 0)
                                .stroke(lib.selectedIDs.contains(item.id) ? Color.yellow : Color.clear, lineWidth: 4)
                        }
                    }

                    // Рейтинг теперь непосредственно под главным фото.
                    if let item = lib.current {
                        RatingBar(lib: lib, item: item)
                    }

                    HStack(spacing: 12) {
                        Text("Выбрано \(lib.selectedCount) из \(lib.items.count) • \(String(format: "%.1f", lib.selectedPercent))%")
                            .font(.caption.bold())
                        if let c = lib.current {
                            Text(c.label.isEmpty ? "Без цвета" : c.label)
                            Text("Людей: \(c.peopleCount)")
                        }
                        Spacer()
                        Text(lib.status).font(.caption).lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                }

                Divider()

                // Справа: голова крупным планом + данные файла.
                VStack(alignment: .leading, spacing: 10) {
                    Text("ГОЛОВА").font(.caption.bold()).foregroundStyle(.secondary)

                    HeadPreview(crop: lib.eyeCrop, found: lib.eyeFound)
                        .frame(maxHeight: 260)

                    Divider()

                    if let item = lib.current {
                        MetadataPanel(item: item)
                    } else {
                        Text("Данные появятся после открытия папки")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(12)
                .frame(width: 300)
                .frame(maxHeight: .infinity)
                .background(.regularMaterial)
                .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
        .onReceive(NotificationCenter.default.publisher(for: .openFolder)) { _ in lib.openFolder() }
        .onAppear { setupKeyboard() }
    }

    private func setupKeyboard() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "a" {
                lib.selectAll(); return nil
            }
            if event.keyCode == 49 { NSApp.keyWindow?.toggleFullScreen(nil); return nil }
            guard NSApp.keyWindow?.firstResponder is NSTextView == false else { return event }

            switch event.keyCode {
            case 123: lib.move(-1); return nil
            case 124: lib.move(1); return nil
            default: break
            }

            if let s = event.charactersIgnoringModifiers {
                switch s {
                case "1": lib.rate(1); return nil
                case "2": lib.rate(2); return nil
                case "3": lib.rate(3); return nil
                case "4": lib.rate(4); return nil
                case "5": lib.rate(5); return nil
                case "6": lib.color("Red"); return nil
                case "7": lib.color("Yellow"); return nil
                case "8": lib.color("Green"); return nil
                case "9": lib.color("Blue"); return nil
                case "0": lib.color("Purple"); return nil
                case "r": lib.clearRating(); return nil
                case "s": lib.toggleSelected(); return nil
                default: break
                }
            }
            return event
        }
    }
}

struct NearbyStrip: View {
    @ObservedObject var lib: Library

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 5) {
                    ForEach(neighborItems, id: \.item.id) { entry in
                        Button {
                            lib.index = entry.index
                            lib.zoom = 1
                            lib.updateEyePreview()
                        } label: {
                            ZStack(alignment: .bottomTrailing) {
                                ImageView(url: entry.item.url)
                                    .frame(width: max(70, geo.size.width - 4), height: 42)
                                    .clipped()
                                    .background(.black)

                                if entry.index == lib.index {
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.accentColor, lineWidth: 3)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .topLeading) {
                            if entry.index == lib.index {
                                Text("ТЕКУЩИЙ")
                                    .font(.system(size: 8, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(.black.opacity(0.75))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                }
            }
        }
    }

    private var neighborItems: [(index: Int, item: PhotoItem)] {
        guard !lib.filtered.isEmpty else { return [] }
        let lo = max(0, lib.index - 3)
        let hi = min(lib.filtered.count - 1, lib.index + 3)
        return Array(lo...hi).map { ($0, lib.filtered[$0]) }
    }
}

struct RatingBar: View {
    @ObservedObject var lib: Library
    let item: PhotoItem

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(1...5, id: \.self) { value in
                    Button {
                        lib.rate(value)
                    } label: {
                        Image(systemName: value <= item.rating ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundStyle(value <= item.rating ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().frame(height: 20)

            Button("Без оценки") { lib.clearRating() }
                .buttonStyle(.borderless)

            Spacer()

            Text(item.label.isEmpty ? "Без цвета" : item.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial)
    }
}

struct HeadPreview: View {
    let crop: CGImage?
    let found: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.black)
            if let crop {
                Image(decorative: crop, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else {
                Text(found ? "Не удалось показать" : "Голова не найдена")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct CompareView: View {
    @ObservedObject var lib: Library
    var body: some View {
        HStack(spacing: 2) {
            ForEach(lib.compareItems) { item in
                VStack(spacing: 0) {
                    Text(item.url.lastPathComponent).font(.caption).foregroundStyle(.white).padding(4)
                    ImageView(url: item.url).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
                }
            }
        }.background(.black)
    }
}

struct ImageView: View {
    let url: URL
    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "photo").font(.system(size: 60)).foregroundStyle(.secondary)
        }
    }
}

struct ZoomablePreview: NSViewRepresentable {
    let url: URL
    @Binding var zoom: CGFloat

    func makeNSView(context: Context) -> ZoomNSView {
        let view = ZoomNSView()
        view.load(url: url)
        return view
    }

    func updateNSView(_ nsView: ZoomNSView, context: Context) {
        nsView.onZoom = { value in
            DispatchQueue.main.async { self.zoom = value }
        }
        nsView.zoom = zoom
        nsView.load(url: url)
    }
}

final class ZoomNSView: NSView {
    var image: NSImage?
    var zoom: CGFloat = 1
    var onZoom: ((CGFloat) -> Void)?
    private var anchor = CGPoint(x: 0.5, y: 0.5)
    private var loadedURL: URL?
    private var loadToken = UUID()

    func load(url: URL) {
        guard loadedURL != url else { return }
        loadedURL = url
        let token = UUID()
        loadToken = token
        image = nil
        needsDisplay = true

        // Use Quick Look's embedded RAW preview first. This is much faster for CR3
        // than asking NSImage to fully decode the RAW on every frame.
        PreviewLoader.load(url: url) { [weak self] image in
            DispatchQueue.main.async {
                guard let self, self.loadToken == token else { return }
                self.image = image
                self.needsDisplay = true
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        guard let image else {
            let text = "Загрузка превью…"
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white.withAlphaComponent(0.65),
                .font: NSFont.systemFont(ofSize: 13)
            ]
            (text as NSString).draw(at: NSPoint(x: bounds.midX - 45, y: bounds.midY), withAttributes: attrs)
            return
        }

        let base = AVMakeRect(aspectRatio: image.size, insideRect: bounds)
        let w = base.width * zoom
        let h = base.height * zoom
        let x = bounds.midX - w * anchor.x
        let y = bounds.midY - h * (1 - anchor.y)
        image.draw(in: NSRect(x: x, y: y, width: w, height: h),
                   from: .zero, operation: .sourceOver, fraction: 1)
    }

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        anchor = CGPoint(x: max(0, min(1, p.x / max(bounds.width, 1))),
                         y: max(0, min(1, p.y / max(bounds.height, 1))))
        let factor: CGFloat = event.scrollingDeltaY > 0 ? 1.12 : 0.89
        zoom = min(8, max(1, zoom * factor))
        onZoom?(zoom)
        needsDisplay = true
    }
}

enum PreviewLoader {
    private static let cache = NSCache<NSURL, NSImage>()

    static func load(url: URL, completion: @escaping (NSImage?) -> Void) {
        if let cached = cache.object(forKey: url as NSURL) {
            completion(cached)
            return
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 1800, height: 1800),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            if let representation {
                let image = NSImage(
                    cgImage: representation.cgImage,
                    size: representation.contentRect.size
                )
                cache.setObject(image, forKey: url as NSURL)
                completion(image)
                return
            }

            // Last-resort fallback for formats Quick Look cannot thumbnail.
            DispatchQueue.global(qos: .userInitiated).async {
                let image = NSImage(contentsOf: url)
                if let image { cache.setObject(image, forKey: url as NSURL) }
                completion(image)
            }
        }
    }
}

struct FolderNode: Identifiable {
    let id = UUID()
    let url: URL
    let children: [FolderNode]
}

struct FolderRow: View {
    let node: FolderNode
    let depth: Int
    let action: (URL) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                if !node.children.isEmpty {
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 12)
                    }.buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 12)
                }
                Image(systemName: node.url.path == "/" ? "internaldrive" : "folder")
                Text(node.url.lastPathComponent.isEmpty ? node.url.path : node.url.lastPathComponent)
                    .lineLimit(1)
            }
            .padding(.leading, CGFloat(depth * 14))
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture { action(node.url) }

            if expanded {
                ForEach(node.children) { child in
                    FolderRow(node: child, depth: depth + 1, action: action)
                }
            }
        }
    }
}

struct MetadataPanel: View {
    let item: PhotoItem
    static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return f
    }()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ДАННЫЕ КАДРА").font(.caption.bold()).foregroundStyle(.secondary)
            MetaLine(icon: "camera", title: "Камера", value: item.camera)
            MetaLine(icon: "camera.aperture", title: "Объектив", value: item.lens)
            MetaLine(icon: "circle.dashed", title: "Диафрагма", value: item.aperture)
            MetaLine(icon: "timer", title: "Выдержка", value: item.shutter)
            MetaLine(icon: "speedometer", title: "ISO", value: item.iso)
            MetaLine(icon: "bolt.fill", title: "Вспышка", value: item.flash)
            MetaLine(icon: "person.2", title: "Людей", value: "\(item.peopleCount)")
            if let date = item.captureDate {
                MetaLine(icon: "clock", title: "Время", value: Self.df.string(from: date))
            }
            Divider()
            Text(item.url.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

struct MetaLine: View {
    let icon: String
    let title: String
    let value: String
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: icon).frame(width: 18)
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }
}

struct EyePreview: View {
    let crop: CGImage?
    let found: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.black)
            if let crop {
                Image(decorative: crop, scale: 1).resizable().scaledToFit().padding(5)
            } else {
                Text(found ? "Не удалось показать" : "Лицо / глаза не найдены")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(height: 145)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct PeopleBadge: View {
    let count: Int
    var body: some View {
        Label("\(count)", systemImage: "person.2.fill")
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.black.opacity(0.65), in: Capsule())
            .foregroundStyle(.white)
    }
}

enum Metadata {
    static func read(_ url: URL) -> PhotoItem {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        let props = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

        let dateText = (exif[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (tiff[kCGImagePropertyTIFFDateTime] as? String)
        let date = dateText.flatMap { parseDate($0) }

        let make = (tiff[kCGImagePropertyTIFFMake] as? String) ?? ""
        let model = (tiff[kCGImagePropertyTIFFModel] as? String) ?? ""
        let camera = "\(make) \(model)".trimmingCharacters(in: .whitespaces)

        let lens = (exif[kCGImagePropertyExifLensModel] as? String) ?? ""
        let f = exif[kCGImagePropertyExifFNumber] as? NSNumber
        let exposure = exif[kCGImagePropertyExifExposureTime] as? NSNumber
        let isoArray = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber]
        let iso = isoArray?.first?.stringValue ?? ""
        let aperture = f.map { "f/\($0.doubleValue.clean)" } ?? ""
        let shutter = exposure.map { formatExposure($0.doubleValue) } ?? ""
        let flashValue = (exif[kCGImagePropertyExifFlash] as? NSNumber)?.intValue ?? 0
        let flash = (flashValue & 1) != 0 ? "Со вспышкой" : "Без вспышки"

        let people = VisionAnalysis.peopleCount(for: url)
        return PhotoItem(url: url, rating: XMP.rating(for: url), label: XMP.label(for: url),
                         orientation: h > w ? .portrait : .landscape, captureDate: date,
                         camera: camera, lens: lens, aperture: aperture, shutter: shutter,
                         iso: iso, flash: flash, peopleCount: people)
    }

    static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)
    }

    static func formatExposure(_ v: Double) -> String {
        guard v > 0 else { return "" }
        if v >= 0.5 { return String(format: "%.2fs", v) }
        return "1/\(max(1, Int(round(1 / v))))s"
    }
}

extension Double {
    var clean: String { String(format: "%.1f", self).replacingOccurrences(of: ".0", with: "") }
}

enum VisionAnalysis {
    struct EyeResult { let crop: CGImage?; let found: Bool }

    static func thumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1800,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary)
    }

    static func peopleCount(for url: URL) -> Int {
        guard let image = thumbnail(url) else { return 0 }
        let request = VNDetectHumanRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return request.results?.count ?? 0
    }

    static func eyeCrop(for url: URL) -> EyeResult {
        guard let image = thumbnail(url) else { return EyeResult(crop: nil, found: false) }
        let request = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let face = request.results?.first else { return EyeResult(crop: nil, found: false) }

        // "ГЛАЗА" is intentionally a head/face preview now: Vision can return
        // a landmark box slightly off the eyes, especially on profile faces.
        // Showing the whole head gives a reliable view of expression and eyes.
        let b = face.boundingBox
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let faceRect = CGRect(x: b.minX * w, y: b.minY * h, width: b.width * w, height: b.height * h)

        let paddingX = faceRect.width * 0.45
        let paddingY = faceRect.height * 0.55
        let headRect = CGRect(
            x: faceRect.minX - paddingX,
            y: faceRect.minY - paddingY * 0.35,
            width: faceRect.width + paddingX * 2,
            height: faceRect.height + paddingY * 1.35
        ).intersection(CGRect(x: 0, y: 0, width: w, height: h))

        return EyeResult(crop: image.cropping(to: headRect), found: true)
    }
}

enum FileBrowser {
    static func roots() -> [FolderNode] {
        var urls = [URL(fileURLWithPath: NSHomeDirectory()), URL(fileURLWithPath: "/")]
        if let volumes = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"),
                                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                                      options: [.skipsHiddenFiles]) {
            urls.append(contentsOf: volumes)
        }
        var seen = Set<String>()
        return urls.compactMap { build($0, depth: 0, seen: &seen) }
    }

    static func build(_ url: URL, depth: Int, seen: inout Set<String>) -> FolderNode? {
        guard depth < 2 else { return FolderNode(url: url, children: []) }
        let path = url.standardizedFileURL.path
        guard !seen.contains(path) else { return nil }
        seen.insert(path)
        let children = (try? FileManager.default.contentsOfDirectory(at: url,
                                                                       includingPropertiesForKeys: [.isDirectoryKey],
                                                                       options: [.skipsHiddenFiles]))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { build($0, depth: depth + 1, seen: &seen) } ?? []
        return FolderNode(url: url, children: children)
    }
}



enum ExportMode: String, CaseIterable, Identifiable {
    case longSide = "Длинная сторона"
    case maxSize = "Максимальный размер файла"
    var id: String { rawValue }
}

struct ExportSettings {
    var mode: ExportMode = .longSide
    var longSide: Int = 3000
    var maxMB: Double = 5
    var quality: CGFloat = 1.0
}

final class Exporter {
    static func exportJPEG(_ item: PhotoItem, settings: ExportSettings, destination: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "SpeedRAW", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось декодировать RAW"])
        }

        let originalW = image.width, originalH = image.height
        let scale: CGFloat
        switch settings.mode {
        case .longSide:
            scale = min(1, CGFloat(settings.longSide) / CGFloat(max(originalW, originalH)))
        case .maxSize:
            scale = 1
        }
        let w = max(1, Int(CGFloat(originalW) * scale))
        let h = max(1, Int(CGFloat(originalH) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw NSError(domain: "SpeedRAW", code: 2)
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { throw NSError(domain: "SpeedRAW", code: 3) }

        let base = destination.appendingPathComponent(item.url.deletingPathExtension().lastPathComponent + ".jpg")
        if settings.mode == .longSide {
            try writeJPEG(scaled, url: base, quality: 1.0)
            return base
        }

        var q: CGFloat = 1.0
        var data = try jpegData(scaled, quality: q)
        let target = Int(settings.maxMB * 1024 * 1024)
        while data.count > target && q > 0.35 {
            q -= 0.05
            data = try jpegData(scaled, quality: q)
        }
        try data.write(to: base, options: .atomic)
        return base
    }

    private static func jpegData(_ image: CGImage, quality: CGFloat) throws -> Data {
        let d = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(d, "public.jpeg" as CFString, 1, nil) else {
            throw NSError(domain: "SpeedRAW", code: 4)
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "SpeedRAW", code: 5) }
        return d as Data
    }

    private static func writeJPEG(_ image: CGImage, url: URL, quality: CGFloat) throws {
        try jpegData(image, quality: quality).write(to: url, options: .atomic)
    }
}

enum ImageInfo {
    static func orientation(for url: URL) -> OrientationFilter {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return .landscape
        }
        return width >= height ? .landscape : .portrait
    }
}

enum XMP {
    static func setOrientation(for url: URL, clockwise: Bool) {
        // The original pixels remain untouched; rotation is stored in XMP.
        let value = clockwise ? "6" : "8"
        let xmpURL = url.deletingPathExtension().appendingPathExtension("xmp")
        var text = (try? String(contentsOf: xmpURL, encoding: .utf8)) ?? ""
        if text.isEmpty || !text.contains("<rdf:Description") {
            text = """
            <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
            <x:xmpmeta xmlns:x="adobe:ns:meta/" xmlns:tiff="http://ns.adobe.com/tiff/1.0/">
              <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description rdf:about="" tiff:Orientation="\(value)"/>
              </rdf:RDF>
            </x:xmpmeta>
            <?xpacket end="w"?>
            """
        } else if text.contains("tiff:Orientation=") {
            text = text.replacingOccurrences(
                of: #"tiff:Orientation="\d+""#,
                with: "tiff:Orientation=\"\(value)\"",
                options: .regularExpression
            )
        } else {
            text = text.replacingOccurrences(
                of: "<rdf:Description",
                with: "<rdf:Description tiff:Orientation=\"\(value)\"",
                options: []
            )
            if !text.contains("xmlns:tiff=") {
                text = text.replacingOccurrences(
                    of: "<x:xmpmeta",
                    with: "<x:xmpmeta xmlns:tiff=\"http://ns.adobe.com/tiff/1.0/\"",
                    options: []
                )
            }
        }
        try? text.write(to: xmpURL, atomically: true, encoding: .utf8)
    }

    static func sidecar(_ url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("xmp")
    }

    static func readAttribute(_ name: String, from text: String) -> String? {
        let pattern = NSRegularExpression.escapedPattern(for: name) + #"="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func rating(for url: URL) -> Int {
        guard let text = try? String(contentsOf: sidecar(url), encoding: .utf8),
              let value = readAttribute("xmp:Rating", from: text),
              let rating = Int(value) else { return 0 }
        return max(0, min(5, rating))
    }

    static func label(for url: URL) -> String {
        guard let text = try? String(contentsOf: sidecar(url), encoding: .utf8) else { return "" }
        return readAttribute("xmp:Label", from: text) ?? ""
    }

    static func setAttribute(_ name: String, value: String, in text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = escaped + #"="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        if let match = regex.firstMatch(in: text, range: range),
           let fullRange = Range(match.range, in: text) {
            let replacement = "\(name)=\"\(value)\""
            return text.replacingCharacters(in: fullRange, with: replacement)
        }

        if let descRange = text.range(of: "<rdf:Description") {
            let insertion = " \(name)=\"\(value)\""
            return text.replacingCharacters(in: descRange.upperBound..<descRange.upperBound, with: insertion)
        }
        return text
    }

    static func write(rating: Int, label: String, for url: URL) {
        let x = sidecar(url)
        let safeRating = max(0, min(5, rating))
        let safeLabel = label.replacingOccurrences(of: "&", with: "&amp;")
        let existing = (try? String(contentsOf: x, encoding: .utf8)) ?? ""
        let output: String

        if existing.isEmpty {
            output = "<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n" +
                "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">\n" +
                "<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n" +
                "<rdf:Description xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" xmp:Rating=\"\\(safeRating)\" xmp:Label=\"\\(safeLabel)\"/>\n" +
                "</rdf:RDF>\n" +
                "</x:xmpmeta>\n" +
                "<?xpacket end=\"w\"?>"
        } else {
            var text = existing
            text = setAttribute("xmp:Rating", value: String(safeRating), in: text)
            text = setAttribute("xmp:Label", value: safeLabel, in: text)
            output = text
        }

        try? output.write(to: x, atomically: true, encoding: .utf8)
    }
}
