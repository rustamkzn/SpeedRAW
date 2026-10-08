import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers
import ImageIO
import QuickLookThumbnailing
import Vision
import AVFoundation

let APP_VERSION = "0.2.0"
let APP_BUILD = 22

@MainActor
final class Workspace: ObservableObject, Identifiable {
    let id = UUID()
    let lib = Library()
    @Published var title = "Новая вкладка"
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var workspaces: [Workspace] = []
    @Published var activeID: UUID?
    private var libraryObservers: [UUID: AnyCancellable] = [:]

    init() {
        let first = Workspace()
        workspaces = [first]
        activeID = first.id
        observe(first)
    }

    var active: Workspace {
        if let activeID, let found = workspaces.first(where: { $0.id == activeID }) {
            return found
        }
        return workspaces[0]
    }

    func addWorkspace() {
        let ws = Workspace()
        observe(ws)
        workspaces.append(ws)
        store.activeID = ws.id
    }

    func closeWorkspace(_ ws: Workspace) {
        guard workspaces.count > 1 else {
            ws.lib.items.removeAll()
            ws.lib.currentFolder = nil
            ws.lib.folderName = "Папка не открыта"
            ws.lib.sidebarRoots.removeAll()
            ws.lib.index = 0
            return
        }

        let idx = workspaces.firstIndex(where: { $0.id == ws.id }) ?? 0
        libraryObservers[ws.id] = nil
        workspaces.remove(at: idx)

        if store.activeID == ws.id {
            activeID = workspaces[min(idx, workspaces.count - 1)].id
        }
    }

    private func observe(_ ws: Workspace) {
        libraryObservers[ws.id] = ws.lib.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            self.objectWillChange.send()
        }
    }
}

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
    var rotation: Int = 0
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
    private var eyeToken = UUID()
    private var loadGeneration = UUID()

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
    var selectedCount: Int { items.filter { $0.rating > 0 }.count }
    var selectedPercent: Double { guard !items.isEmpty else { return 0 }; return (Double(selectedCount) / Double(items.count)) * 100.0 }
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
        status = "Сканирование папки…"
        items.removeAll(keepingCapacity: true)
        selectedIDs.removeAll()
        index = 0
        compareMode = false
        eyeCrop = nil
        eyeFound = false

        let generation = UUID()
        loadGeneration = generation
        let exts = Set(["jpg","jpeg","png","heic","heif","cr2","cr3","nef","arw","raf","rw2","orf","dng"])

        // Critical culling rule: opening a folder must NOT read XMP/EXIF/RAW data
        // for every file. We only enumerate paths first and publish them immediately.
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let urls = (fm.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )?.compactMap { $0 as? URL }
                .filter { url in
                    guard exts.contains(url.pathExtension.lowercased()) else { return false }
                    return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                }) ?? []

            let sortedURLs = urls.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }

            let lightweight = sortedURLs.map { PhotoItem(url: $0) }

            DispatchQueue.main.async {
                guard self.loadGeneration == generation else { return }
                self.items = lightweight
                self.status = "\(lightweight.count) файлов • загрузка рейтингов…"
                self.sidebarRoots = FileBrowser.roots(focus: folder)
                self.loadQuickMetadata(for: sortedURLs, generation: generation)
                self.hydrateMetadata(around: 0, generation: generation)
                self.updateEyePreview()
            }
        }
    }

    var loadGenerationForUI: UUID { loadGeneration }

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

    func delete(_ item: PhotoItem) {
        let alert = NSAlert()
        alert.messageText = "Удалить фото?"
        alert.informativeText = item.url.lastPathComponent
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            if let i = items.firstIndex(where: { $0.id == item.id }) {
                items.remove(at: i)
                index = min(index, max(0, filtered.count - 1))
            }
            status = "Фото перемещено в Корзину"
        } catch {
            status = "Ошибка удаления: \(error.localizedDescription)"
        }
    }

    func rename(_ item: PhotoItem) {
        let alert = NSAlert()
        alert.messageText = "Переименовать фото"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = item.url.deletingPathExtension().lastPathComponent
        alert.accessoryView = field
        alert.addButton(withTitle: "Переименовать")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let destination = item.url.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(item.url.pathExtension)
        do {
            try FileManager.default.moveItem(at: item.url, to: destination)
            if let i = items.firstIndex(where: { $0.id == item.id }) {
                items[i] = Metadata.read(destination)
            }
            status = "Переименовано: \(destination.lastPathComponent)"
        } catch {
            status = "Ошибка переименования: \(error.localizedDescription)"
        }
    }

    func showInfo(_ item: PhotoItem) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .typeIdentifierKey]
        let values = try? item.url.resourceValues(forKeys: keys)
        let size = ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
        let type = values?.typeIdentifier ?? item.url.pathExtension.uppercased()
        let alert = NSAlert()
        alert.messageText = item.url.lastPathComponent
        alert.informativeText = """
        Путь: (item.url.path)
        Размер: (size)
        Тип: (type)
        Рейтинг: (item.rating)★
        Камера: (item.camera.isEmpty ? "—" : item.camera)
        Объектив: (item.lens.isEmpty ? "—" : item.lens)
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func rotateCurrent(clockwise: Bool) {
        guard let current, let i = items.firstIndex(where: { $0.id == current.id }) else { return }
        let step = clockwise ? 90 : 270
        items[i].rotation = (items[i].rotation + step) % 360
        XMP.setRotationAsync(for: items[i].url, degrees: items[i].rotation)
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

    func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        index = min(max(index + delta, 0), filtered.count - 1)
        zoom = 1
        hydrateMetadata(around: index, generation: loadGeneration)
        updateEyePreview()
    }

    func rate(_ value: Int) {
        guard let current else { return }
        setRating(value, for: [current.id], advance: autoAdvance)
    }

    func setRating(_ value: Int, for ids: [UUID], advance: Bool = false) {
        let safe = max(0, min(5, value))
        let currentID = ids.count == 1 ? ids[0] : nil
        let oldFilteredIndex = currentID.flatMap { id in filtered.firstIndex(where: { $0.id == id }) }

        for id in ids {
            guard let i = items.firstIndex(where: { $0.id == id }) else { continue }
            let label = items[i].label
            let url = items[i].url
            items[i].rating = safe
            // Disk I/O is off the main thread so rating never blocks culling/navigation.
            XMP.writeAsync(rating: safe, label: label, for: url)
        }

        status = safe == 0 ? "Рейтинг сброшен" : "Рейтинг \(safe)★ установлен"

        guard advance, let oldFilteredIndex, ids.count == 1 else { return }

        // Respect filters. If the current image disappears from the filtered list
        // (for example "Без оценки"), stay at its old position instead of skipping one.
        let newCount = filtered.count
        if newCount == 0 {
            index = 0
        } else if filtered.contains(where: { $0.id == currentID }) {
            index = min(oldFilteredIndex + 1, newCount - 1)
        } else {
            index = min(oldFilteredIndex, newCount - 1)
        }

        zoom = 1
        hydrateMetadata(around: index, generation: loadGeneration)
        updateEyePreview()
    }

    func rateSelected(_ value: Int) {
        let ids = selectedIDs.isEmpty ? filtered.map(\.id) : Array(selectedIDs)
        guard !ids.isEmpty else { return }
        setRating(value, for: ids, advance: false)
        status = "Рейтинг \(value)★ присвоен \(ids.count) фото"
    }

    func loadQuickMetadata(for urls: [URL], generation: UUID) {
        DispatchQueue.global(qos: .utility).async {
            let batchSize = 80
            for start in stride(from: 0, to: urls.count, by: batchSize) {
                guard self.loadGeneration == generation else { return }
                let end = min(start + batchSize, urls.count)
                let result = urls[start..<end].map { url in
                    (url, XMP.quickMetadata(for: url))
                }

                DispatchQueue.main.async {
                    guard self.loadGeneration == generation else { return }
                    for (url, quick) in result {
                        guard let i = self.items.firstIndex(where: { $0.url == url }) else { continue }
                        self.items[i].rating = quick.rating
                        self.items[i].label = quick.label
                        self.items[i].rotation = quick.rotation
                    }
                    self.status = "\(self.items.count) файлов • готово"
                }
            }
        }
    }

    func hydrateMetadata(around center: Int, generation: UUID) {
        guard !filtered.isEmpty else { return }
        let start = max(0, center - 2)
        let end = min(filtered.count, center + 4)
        let urls = filtered[start..<end].map(\.url)

        DispatchQueue.global(qos: .utility).async {
            let result = urls.map { Metadata.read($0) }
            DispatchQueue.main.async {
                guard self.loadGeneration == generation else { return }
                for meta in result {
                    guard let i = self.items.firstIndex(where: { $0.url == meta.url }) else { continue }
                    self.items[i].orientation = meta.orientation
                    self.items[i].captureDate = meta.captureDate
                    self.items[i].camera = meta.camera
                    self.items[i].lens = meta.lens
                    self.items[i].aperture = meta.aperture
                    self.items[i].shutter = meta.shutter
                    self.items[i].iso = meta.iso
                    self.items[i].flash = meta.flash
                }
            }
        }
    }

    func updateEyePreview() {
        guard let current else { eyeCrop = nil; eyeFound = false; return }
        let token = UUID()
        eyeToken = token
        let url = current.url
        DispatchQueue.global(qos: .userInitiated).async {
            let result = VisionAnalysis.eyeCrop(for: url)
            DispatchQueue.main.async {
                guard self.eyeToken == token else { return }
                self.eyeCrop = result.crop
                self.eyeFound = result.found
                if let i = self.items.firstIndex(where: { $0.id == current.id }) {
                    self.items[i].peopleCount = result.peopleCount
                }
            }
        }
    }

    func toggleCompare() {
        compareMode = compareItems.count == 2
    }

    func clearRating() {
        rateSelected(0)
    }

    func toggleSelectAll() {
        let ids = Set(filtered.map(\.id))
        if ids.isSubset(of: selectedIDs) {
            selectedIDs.subtract(ids)
        } else {
            selectedIDs.formUnion(ids)
        }
        status = "Выбрано \(selectedIDs.count) фото"
    }
}

struct ContentView: View {
    @StateObject private var store = WorkspaceStore()

    private var workspaces: [Workspace] { store.workspaces }

    private var active: Workspace {
        store.active
    }

    var body: some View {
        let lib = active.lib
        VStack(spacing: 0) {
            topBar(lib: lib)
            Divider()
            tabBar
            Divider()
            workspace(lib: lib)
            Divider()
            bottomBar(lib: lib)
        }
        .onAppear { if store.activeID == nil { store.activeID = workspaces[0].id } }
        .onDrop(of: [.fileURL, .folder], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                if let url = object as? URL {
                    DispatchQueue.main.async { active.lib.load(url) }
                } else if let nsurl = object as? NSURL, let url = nsurl as URL? {
                    DispatchQueue.main.async { active.lib.load(url) }
                }
            }
            return true
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func topBar(lib: Library) -> some View {
        HStack(spacing: 10) {
            Button { lib.openFolder() } label: { Label("Открыть папку", systemImage: "folder") }
            Button { lib.rotateCurrent(clockwise: false) } label: { Image(systemName: "rotate.left") }
            Button { lib.rotateCurrent(clockwise: true) } label: { Image(systemName: "rotate.right") }
            Button { lib.exportCurrentJPEG() } label: { Label("JPEG", systemImage: "arrow.down.doc") }
            Text(lib.folderName).font(.headline).lineLimit(1)
            Spacer()
            Toggle("Автопереход", isOn: Binding(get: { lib.autoAdvance }, set: { lib.autoAdvance = $0 }))
            Button(lib.compareItems.count == 2 ? "Сравнить" : "Выбрать 2 фото") { lib.toggleCompare() }
                .disabled(lib.compareItems.count != 2)
            Text("v\(APP_VERSION) • build \(APP_BUILD)").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(workspaces) { ws in
                HStack(spacing: 7) {
                    Image(systemName: "photo.on.rectangle")
                    Text(ws.lib.folderName == "Папка не открыта" ? "Новая вкладка" : ws.lib.folderName).lineLimit(1)
                    if !ws.lib.items.isEmpty { Text("\(ws.lib.items.count)").font(.caption2).foregroundStyle(.secondary) }
                    Button { closeWorkspace(ws) } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain)
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(store.activeID == ws.id ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
                .onTapGesture { activeID = ws.id }
            }
            Button {
                store.addWorkspace()
            } label: { Image(systemName: "plus") }
            .buttonStyle(.plain).padding(.horizontal, 8)
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
    }

    private func closeWorkspace(_ ws: Workspace) {
        store.closeWorkspace(ws)
    }

    private func workspace(lib: Library) -> some View {
        // Do not use nested HSplitView here.
        // On macOS SwiftUI can collapse a nested split column to zero width
        // when the divider is dragged or when the window is relaid out after
        // opening a large RAW folder. That was making the folder tree and
        // thumbnail strip disappear. Keep the three side columns stable first;
        // column resizing will be reintroduced with explicit width state.
        HStack(spacing: 0) {
            folderColumn(lib: lib)
                .frame(width: 220)
            
            Divider()
            
            photoStripColumn(lib: lib)
                .frame(width: 180)
            
            Divider()
            
            centerColumn(lib: lib)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Divider()
            
            rightColumn(lib: lib)
                .frame(width: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func folderColumn(lib: Library) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ПАПКИ").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Button { lib.createFolder() } label: { Image(systemName: "folder.badge.plus") }.buttonStyle(.plain)
            }.padding(8)
            if let folder = lib.currentFolder {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(folder.pathComponents.indices, id: \.self) { i in
                            if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                            Text(folder.pathComponents[i]).font(.caption2).lineLimit(1).foregroundStyle(.primary)
                        }
                    }.padding(.horizontal, 8).padding(.bottom, 6)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lib.sidebarRoots) { node in
                        FolderRow(node: node, depth: 0, selectedURL: lib.currentFolder) { lib.loadFromSidebar($0) }
                    }
                }.padding(.vertical, 4)
            }
        }.frame(maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
    }

    private func photoStripColumn(lib: Library) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("КАДРЫ").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Text("\(lib.filtered.isEmpty ? 0 : lib.index + 1)/\(max(lib.filtered.count, 1))")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.horizontal, 8).padding(.vertical, 8)
            NearbyStrip(lib: lib).padding(.horizontal, 6).frame(maxHeight: .infinity)
        }.background(Color(nsColor: .controlBackgroundColor))
    }

    private func centerColumn(lib: Library) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(lib.current?.url.lastPathComponent ?? "Speed RAW").font(.headline).lineLimit(1)
                Spacer()
                if !lib.filtered.isEmpty { Text("\(lib.index + 1) / \(lib.filtered.count)").font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 12).padding(.vertical, 7)

            ZStack {
                Color.black
                if let item = lib.current {
                    if lib.compareMode {
                        CompareView(lib: lib)
                    } else {
                        ZoomablePreview(url: item.url, rotation: item.rotation,
                                         zoom: Binding(get: { lib.zoom }, set: { lib.zoom = $0 }))
                            .id("\(item.id.uuidString)-\(item.rotation)")
                    }
                } else {
                    VStack(spacing: 8) {
                        Text("Speed RAW").font(.largeTitle.bold())
                        Text("Откройте папку с фотографиями").foregroundStyle(.secondary)
                    }.foregroundStyle(.white)
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

            if let item = lib.current { RatingBar(lib: lib, item: item) }
        }
        .background(Color.black)
        .overlay(KeyHandler(lib: lib).frame(width: 1, height: 1).opacity(0.01))
    }

    private func rightColumn(lib: Library) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("ГОЛОВА").font(.caption.bold()).foregroundStyle(.secondary)
                HeadPreview(crop: lib.eyeCrop, found: lib.eyeFound).frame(height: 180)
                if let item = lib.current { MetadataPanel(item: item) }
            }.padding(10)
        }.frame(maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
    }

    private func bottomBar(lib: Library) -> some View {
        let percentText = String(format: "%.1f", lib.selectedPercent)
        return HStack(spacing: 12) {
            Text("Отобрано: \\(lib.selectedCount) из \\(lib.items.count) • \\(percentText)%")
                .font(.caption.bold())
            if let c = lib.current {
                Text(c.label.isEmpty ? "Без цвета" : c.label)
                Text("Людей: \(c.peopleCount)")
            }
            Spacer()
            Text(lib.status).font(.caption).lineLimit(1)
        }.padding(.horizontal, 10).padding(.vertical, 7)
    }
}

struct KeyHandler: NSViewRepresentable {
    let lib: Library
    func makeNSView(context: Context) -> KeyCatcher {
        let v = KeyCatcher(); v.lib = lib
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }
    func updateNSView(_ nsView: KeyCatcher, context: Context) {
        nsView.lib = lib
        DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
    }
}

final class KeyCatcher: NSView {
    weak var lib: Library?
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { window?.makeFirstResponder(self) }
    }
    override func keyDown(with event: NSEvent) {
        guard let lib else { super.keyDown(with: event); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "a" {
            lib.toggleSelectAll(); return
        }
        switch event.keyCode {
        case 49:
            lib.zoom = lib.zoom == 0 ? 1 : 0
        case 123:
            lib.move(-1)
        case 124:
            lib.move(1)
        default:
            let chars = event.charactersIgnoringModifiers ?? ""
            if let n = Int(chars), n >= 0 && n <= 5 {
                if flags.contains(.command) { lib.rateSelected(n) } else { lib.rate(n) }
            } else { super.keyDown(with: event) }
        }
    }
}

struct NearbyStrip: View {
    @ObservedObject var lib: Library

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 6) {
                    ForEach(Array(lib.filtered.indices), id: \.self) { idx in
                        let item = lib.filtered[idx]
                        Button {
                            lib.index = idx
                            lib.zoom = 1
                            lib.hydrateMetadata(around: idx, generation: lib.loadGenerationForUI)
                            lib.updateEyePreview()
                            DispatchQueue.main.async {
                                withAnimation(.easeOut(duration: 0.12)) {
                                    proxy.scrollTo(idx, anchor: .center)
                                }
                            }
                        } label: {
                            ZStack(alignment: .bottom) {
                                CachedThumb(url: item.url)
                                    .frame(maxWidth: .infinity, minHeight: 86, maxHeight: 112)
                                    .clipped()
                                    .background(.black)

                                HStack(spacing: 2) {
                                    ForEach(1...5, id: \.self) { value in
                                        Image(systemName: value <= item.rating ? "star.fill" : "star")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(value <= item.rating ? Color.yellow : Color.white.opacity(0.75))
                                    }
                                }
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.7))
                                .clipShape(Capsule())
                                .padding(.bottom, 4)

                                if idx == lib.index {
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(Color.accentColor, lineWidth: 3)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .id(idx)
                        .contextMenu {
                            PhotoContextMenu(item: item, lib: lib)
                        }
                        .overlay(alignment: .topLeading) {
                            Text("\(idx + 1)")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.75))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: lib.index) { _, newIndex in
                guard newIndex >= 0, newIndex < lib.filtered.count else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
    }
}

struct PhotoContextMenu: View {
    let item: PhotoItem
    @ObservedObject var lib: Library

    var body: some View {
        Group {
            Button("Найти исходную папку") {
                NSWorkspace.shared.selectFile(item.url.path, inFileViewerRootedAtPath: item.url.deletingLastPathComponent().path)
            }
            Divider()
            Button("Удалить фото", role: .destructive) {
                lib.delete(item)
            }
            Button("Переименовать фото…") {
                lib.rename(item)
            }
            Divider()
            Button("Информация") {
                lib.showInfo(item)
            }
        }
    }
}

struct RatingBar: View {
    @ObservedObject var lib: Library
    let item: PhotoItem
    var body: some View {
        HStack(spacing: 10) {
            ForEach(1...5, id: \.self) { value in
                Button { lib.rate(value) } label: {
                    Image(systemName: value <= item.rating ? "star.fill" : "star")
                        .font(.title3)
                        .foregroundStyle(value <= item.rating ? Color.yellow : Color.secondary)
                }.buttonStyle(.plain)
            }
            Divider().frame(height: 20)
            Button("0 — сбросить") { lib.clearRating() }.buttonStyle(.borderless)
            Spacer()
            Text(item.label.isEmpty ? "Без цвета" : item.label).font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 12).padding(.vertical, 7).background(.regularMaterial)
    }
}

struct ZoomablePreview: NSViewRepresentable {
    let url: URL
    let rotation: Int
    @Binding var zoom: CGFloat

    func makeNSView(context: Context) -> ZoomNSView {
        let view = ZoomNSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.rotation = rotation
        view.load(url: url)
        return view
    }

    func updateNSView(_ nsView: ZoomNSView, context: Context) {
        nsView.onZoom = { value in
            DispatchQueue.main.async { self.zoom = value }
        }
        nsView.rotation = rotation
        nsView.zoom = zoom
        nsView.load(url: url)
        nsView.needsDisplay = true
    }
}

final class ZoomNSView: NSView {
    var image: NSImage?
    var zoom: CGFloat = 1
    var rotation: Int = 0 {
        didSet { if oldValue != rotation { needsDisplay = true } }
    }
    var onZoom: ((CGFloat) -> Void)?
    private var anchor = CGPoint(x: 0.5, y: 0.5)
    private var loadedURL: URL?
    private var loadToken = UUID()
    private var dragStart = CGPoint.zero
    private var dragAnchor = CGPoint(x: 0.5, y: 0.5)
    override var isOpaque: Bool { true }

    func load(url: URL) {
        guard loadedURL != url else { return }
        loadedURL = url
        let token = UUID()
        loadToken = token
        image = nil
        anchor = CGPoint(x: 0.5, y: 0.5)
        zoom = 1
        needsDisplay = true

        PreviewLoader.load(url: url, size: CGSize(width: 2400, height: 2400)) { [weak self] image in
            DispatchQueue.main.async {
                guard let self, self.loadToken == token else { return }
                self.image = image
                self.zoom = max(1, self.zoom)
                self.needsDisplay = true
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Preview canvas is intentionally independent from app theme.
        layer?.backgroundColor = NSColor.black.cgColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()

        guard let image, image.size.width > 0, image.size.height > 0 else {
            let text = "Загрузка превью…"
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white.withAlphaComponent(0.65),
                .font: NSFont.systemFont(ofSize: 13)
            ]
            (text as NSString).draw(
                at: NSPoint(x: bounds.midX - 45, y: bounds.midY),
                withAttributes: attrs
            )
            return
        }

        let normalizedRotation = ((rotation % 360) + 360) % 360
        let angle = CGFloat(normalizedRotation) * .pi / 180
        let rotatedAspect = normalizedRotation % 180 == 0
            ? image.size
            : CGSize(width: image.size.height, height: image.size.width)

        let fitRect = AVMakeRect(aspectRatio: rotatedAspect, insideRect: bounds)
        let fitScale = max(fitRect.width / max(rotatedAspect.width, 1),
                           fitRect.height / max(rotatedAspect.height, 1))
        let effectiveZoom = zoom <= 0 ? fitScale : max(1, zoom)
        let drawW = rotatedAspect.width * effectiveZoom
        let drawH = rotatedAspect.height * effectiveZoom

        let centerX = bounds.midX - (anchor.x - 0.5) * drawW
        let centerY = bounds.midY + (anchor.y - 0.5) * drawH

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: centerX, y: centerY)
        ctx.rotate(by: -angle)

        let rect = CGRect(x: -drawW / 2, y: -drawH / 2, width: drawW, height: drawH)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0,
                   respectFlipped: isFlipped, hints: nil)

        ctx.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragAnchor = anchor
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let dx = (p.x - dragStart.x) / max(bounds.width, 1)
        let dy = (p.y - dragStart.y) / max(bounds.height, 1)
        anchor = CGPoint(
            x: max(0, min(1, dragAnchor.x - dx)),
            y: max(0, min(1, dragAnchor.y + dy))
        )
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        anchor = CGPoint(
            x: max(0, min(1, p.x / max(bounds.width, 1))),
            y: max(0, min(1, p.y / max(bounds.height, 1)))
        )
        let factor: CGFloat = event.scrollingDeltaY > 0 ? 1.12 : 0.89
        zoom = min(8, max(1, zoom * factor))
        onZoom?(zoom)
        needsDisplay = true
    }
}

struct HeadPreview: View {
    let crop: CGImage?
    let found: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.black)
            if let crop {
                Image(decorative: crop, scale: 1).resizable().scaledToFit().padding(6)
            } else {
                Text(found ? "Не удалось показать" : "Голова не найдена")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 8))
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

struct CachedThumb: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: url) {
            await withCheckedContinuation { continuation in
                PreviewLoader.load(url: url, size: CGSize(width: 420, height: 420)) { img in
                    DispatchQueue.main.async {
                        image = img
                        continuation.resume()
                    }
                }
            }
        }
    }
}

enum PreviewLoader {
    private static let cache = NSCache<NSURL, NSImage>()

    static func load(url: URL, size: CGSize, completion: @escaping @Sendable (NSImage?) -> Void) {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            if let representation, representation.cgImage.width > 0, representation.cgImage.height > 0 {
                let cg = representation.cgImage
                let image = NSImage(
                    cgImage: cg,
                    size: NSSize(width: cg.width, height: cg.height)
                )
                cache.setObject(image, forKey: key)
                completion(image)
                return
            }

            DispatchQueue.global(qos: .utility).async {
                let fallback = NSImage(contentsOf: url)
                if let fallback {
                    cache.setObject(fallback, forKey: key)
                }
                completion(fallback)
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
    let selectedURL: URL?
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
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.leading, CGFloat(depth * 14))
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(selectedURL?.standardizedFileURL.path == node.url.standardizedFileURL.path ? Color.accentColor.opacity(0.18) : Color.clear)
            .onAppear {
                if let selectedURL, selectedURL.path.hasPrefix(node.url.path + "/") { expanded = true }
            }
            .onTapGesture { action(node.url) }

            if expanded {
                ForEach(node.children) { child in
                    FolderRow(node: child, depth: depth + 1, selectedURL: selectedURL, action: action)
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

        let people = 0
        return PhotoItem(url: url, rating: XMP.rating(for: url), label: XMP.label(for: url), rotation: XMP.rotation(for: url),
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
    struct EyeResult { let crop: CGImage?; let found: Bool; let peopleCount: Int }

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
        guard let image = thumbnail(url) else { return EyeResult(crop: nil, found: false, peopleCount: 0) }
        let request = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let peopleRequest = VNDetectHumanRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([peopleRequest])
        let peopleCount = peopleRequest.results?.count ?? 0
        guard let face = request.results?.first else { return EyeResult(crop: nil, found: false, peopleCount: peopleCount) }

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

        return EyeResult(crop: image.cropping(to: headRect), found: true, peopleCount: peopleCount)
    }
}

enum FileBrowser {
    static func roots(focus: URL? = nil) -> [FolderNode] {
        var urls = [URL(fileURLWithPath: NSHomeDirectory()), URL(fileURLWithPath: "/")]
        if let volumes = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"),
                                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                                      options: [.skipsHiddenFiles]) {
            urls.append(contentsOf: volumes)
        }
        var seen = Set<String>()
        var result = urls.compactMap { build($0, depth: 0, seen: &seen) }
        if let focus, !result.contains(where: { contains($0, focus: focus) }) {
            if let focused = build(focus, depth: 0, seen: &seen) { result.append(focused) }
        }
        return result
    }

    static func contains(_ node: FolderNode, focus: URL) -> Bool {
        if node.url.standardizedFileURL.path == focus.standardizedFileURL.path { return true }
        return node.children.contains { contains($0, focus: focus) }
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
    private static let ioQueue = DispatchQueue(label: "SpeedRAW.XMP", qos: .utility)

    static func writeAsync(rating: Int, label: String, for url: URL) {
        ioQueue.async {
            write(rating: rating, label: label, for: url)
        }
    }

    static func setRotationAsync(for url: URL, degrees: Int) {
        ioQueue.async {
            setRotation(for: url, degrees: degrees)
        }
    }

    static func setRotation(for url: URL, degrees: Int) {
        let value = ((degrees % 360) + 360) % 360
        let xmpURL = sidecar(url)
        var text = (try? String(contentsOf: xmpURL, encoding: .utf8)) ?? ""
        if text.isEmpty || !text.contains("<rdf:Description") {
            text = """
            <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
              <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rotation="\(value)"/>
              </rdf:RDF>
            </x:xmpmeta>
            <?xpacket end="w"?>
            """
        } else if text.contains("xmp:Rotation=") {
            text = text.replacingOccurrences(of: #"xmp:Rotation="\d+""#, with: "xmp:Rotation=\"\(value)\"", options: .regularExpression)
        } else {
            text = setAttribute("xmp:Rotation", value: String(value), in: text)
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

    struct QuickMetadata {
        let rating: Int
        let label: String
        let rotation: Int
    }

    static func quickMetadata(for url: URL) -> QuickMetadata {
        guard let text = try? String(contentsOf: sidecar(url), encoding: .utf8) else {
            return QuickMetadata(rating: 0, label: "", rotation: 0)
        }
        let rating = Int(readAttribute("xmp:Rating", from: text) ?? "") ?? 0
        let rotation = Int(readAttribute("xmp:Rotation", from: text) ?? "") ?? 0
        let label = readAttribute("xmp:Label", from: text) ?? ""
        return QuickMetadata(
            rating: max(0, min(5, rating)),
            label: label,
            rotation: ((rotation % 360) + 360) % 360
        )
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
                "<rdf:Description xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" xmp:Rating=\"\(safeRating)\" xmp:Label=\"\(safeLabel)\"/>\n" +
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
    
    static func rotation(for url: URL) -> Int {
        guard let text = try? String(contentsOf: sidecar(url), encoding: .utf8),
              let value = readAttribute("xmp:Rotation", from: text),
              let rotation = Int(value) else { return 0 }
        return ((rotation % 360) + 360) % 360
    }

}
