import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO

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
    @Published var autoAdvance = true
    @Published var folderName = "Папка не открыта"
    @Published var status = "Откройте папку с фотографиями"

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
            return rOK && cOK
        }
    }

    var current: PhotoItem? {
        guard !filtered.isEmpty, index >= 0, index < filtered.count else { return nil }
        return filtered[index]
    }

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
        folderName = folder.lastPathComponent
        status = "Сканирование…"
        DispatchQueue.global(qos: .userInitiated).async {
            let exts = Set(["jpg","jpeg","png","heic","heif","cr2","cr3","nef","arw","raf","rw2","orf","dng"])
            let urls = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])?
                .compactMap { $0 as? URL }
                .filter { exts.contains($0.pathExtension.lowercased()) }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) ?? []
            let loaded = urls.map { PhotoItem(url: $0, rating: XMP.rating(for: $0), label: XMP.label(for: $0)) }
            DispatchQueue.main.async {
                self.items = loaded
                self.index = 0
                self.status = "(loaded.count) файлов"
            }
        }
    }

    func rate(_ value: Int) {
        guard let current else { return }
        guard let i = items.firstIndex(where: { $0.id == current.id }) else { return }
        XMP.write(rating: value, label: items[i].label, for: items[i].url)
        items[i].rating = value
        status = "(value)★  •  (items[i].url.lastPathComponent)"
        if autoAdvance { move(1) }
    }

    func color(_ label: String) {
        guard let current else { return }
        guard let i = items.firstIndex(where: { $0.id == current.id }) else { return }
        XMP.write(rating: items[i].rating, label: label, for: items[i].url)
        items[i].label = label
        status = "(label)  •  (items[i].url.lastPathComponent)"
        if autoAdvance { move(1) }
    }

    func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        index = min(max(index + delta, 0), filtered.count - 1)
    }

    func clearRating() {
        guard let current, let i = items.firstIndex(where: { $0.id == current.id }) else { return }
        XMP.write(rating: 0, label: items[i].label, for: items[i].url)
        items[i].rating = 0
    }
}

struct ContentView: View {
    @StateObject private var lib = Library()
    @State private var showFilters = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Открыть папку") { lib.openFolder() }
                    .keyboardShortcut("o", modifiers: [.command])
                Text(lib.folderName).font(.headline)
                Spacer()
                Toggle("Автопереход", isOn: $lib.autoAdvance)
                Button(showFilters ? "Скрыть фильтры" : "Фильтры") { showFilters.toggle() }
            }
            .padding(12)

            Divider()

            HStack(spacing: 0) {
                if showFilters {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ОЦЕНКА").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $lib.ratingFilter) {
                            ForEach(RatingFilter.allCases) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().pickerStyle(.menu)

                        Text("ЦВЕТ").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $lib.colorFilter) {
                            ForEach(ColorFilter.allCases) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().pickerStyle(.menu)

                        Spacer()
                        Text("\(lib.filtered.count) из \(lib.items.count)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(width: 190)
                    Divider()
                }

                ZStack {
                    Color.black.opacity(0.96)
                    if let item = lib.current {
                        ImageView(url: item.url)
                            .id(item.url)
                            .padding(20)
                    } else {
                        VStack(spacing: 10) {
                            Text("Speed RAW").font(.largeTitle.bold()).foregroundStyle(.white)
                            Text("Откройте папку с RAW/JPEG")
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    HStack {
                        Text(lib.current?.url.lastPathComponent ?? "")
                            .lineLimit(1)
                        Spacer()
                        if let c = lib.current {
                            Text(c.rating > 0 ? String(repeating: "★", count: c.rating) : "—")
                            Text(c.label.isEmpty ? "Без цвета" : c.label)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(10)
                    .background(.black.opacity(0.65))
                }
                .onTapGesture {
                    lib.move(1)
                }
            }

            Divider()
            HStack {
                Text(lib.status)
                Spacer()
                Text("← → навигация   •   1–5 оценка   •   6–0 цвет")
            }
            .font(.caption)
            .padding(8)
        }
        .background(.background)
        .onReceive(NotificationCenter.default.publisher(for: .openFolder)) { _ in lib.openFolder() }
        .onAppear { setupKeyboard() }
    }

    private func setupKeyboard() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
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
                default: break
                }
            }
            return event
        }
    }
}

struct ImageView: View {
    let url: URL
    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            VStack {
                Image(systemName: "photo")
                    .font(.system(size: 60))
                Text("Не удалось открыть превью")
            }
            .foregroundStyle(.white.opacity(0.7))
        }
    }
}

enum XMP {
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

    static func write(rating: Int, label: String, for url: URL) {
        let x = sidecar(url)
        let safeRating = max(0, min(5, rating))
        let safeLabel = label.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: """, with: "&quot;")
        let existing = (try? String(contentsOf: x, encoding: .utf8)) ?? ""
        let output: String

        if existing.isEmpty {
            output = """
            <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="\(safeRating)" xmp:Label="\(safeLabel)"/>
            </rdf:RDF>
            </x:xmpmeta>
            <?xpacket end="w"?>
            """
        } else {
            var text = existing
            text = setAttribute("xmp:Rating", value: String(safeRating), in: text)
            text = setAttribute("xmp:Label", value: safeLabel, in: text)
            output = text
        }

        try? output.write(to: x, atomically: true, encoding: .utf8)
    }

    static func setAttribute(_ name: String, value: String, in text: String) -> String {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = escapedName + #"="[^"]*""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else {
            guard let desc = text.range(of: "<rdf:Description"),
                  let end = text[desc.lowerBound...].firstIndex(of: ">") else { return text }
            var copy = text
            copy.insert(contentsOf: " \(name)=\"\(value)\"", at: end)
            return copy
        }
        var copy = text
        copy.replaceSubrange(range, with: "\(name)=\"\(value)\"")
        return copy
    }
}
