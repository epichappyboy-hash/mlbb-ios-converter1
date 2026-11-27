import SwiftUI
import Compression
import UniformTypeIdentifiers
import UIKit

@main
struct MLBBConverterApp: App {
    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            ConverterView()
                .tabItem {
                    Label("Converter", systemImage: "arrow.left.arrow.right.square")
                }

            NutCrackerToolsView()
                .tabItem {
                    Label("MLBB Tools", systemImage: "square.grid.2x2.fill")
                }
        }
        .tint(.blue)
    }
}

// MARK: - Existing Isha Converter screen
// Keep this flow intact: texture profiles, Files import, diagnostics,
// and the single-flight conversion guard remain unchanged.

struct ConverterView: View {
    @State private var inputURL: URL?
    @State private var outputURL: URL?
    @State private var selectedTextureQuality = "high"
    @State private var showImporter = false
    @State private var showShareSheet = false
    @State private var isConverting = false
    @State private var diagnosticsAvailable = false
    @State private var showDiagnostics = false
    @State private var status = "Pumili ng Android Unity bundle (.unity3d) o ZIP file."
    @State private var errorMessage: String?

    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: "arrow.left.arrow.right.square")
                    .font(.system(size: 46, weight: .medium))
                    .foregroundColor(.blue)
                Text("Isha Converter iOS")
                    .font(.title2.bold())
                Text("Android Unity assets → iOS")
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("TEXTURE QUALITY")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        qualityOption("High", "ASTC 4×4", value: "high")
                        qualityOption("Balanced", "ASTC 6×6", value: "balanced")
                        qualityOption("Small", "ASTC 8×8", value: "small")
                    }
                }

                Button {
                    showImporter = true
                } label: {
                    Label(inputURL?.lastPathComponent ?? "Pumili ng asset file", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isConverting)

                Button(action: convert) {
                    HStack {
                        if isConverting { ProgressView().tint(.white) }
                        Text(isConverting ? "Nagko-convert…" : "I-CONVERT SA iOS")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(inputURL == nil || isConverting)

                Text(status)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if diagnosticsAvailable {
                    Button {
                        showDiagnostics = true
                    } label: {
                        Label("I-share ang diagnostic log", systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .sheet(isPresented: $showDiagnostics) {
                        ActivityView(activityItems: [diagnosticsFile])
                    }
                }

                if let outputURL {
                    Button {
                        showShareSheet = true
                    } label: {
                        Label("I-save / I-share ang converted ZIP", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .sheet(isPresented: $showShareSheet) {
                        ActivityView(activityItems: [outputURL])
                    }
                }
                Spacer()
            }
            .padding(24)
            .navigationTitle("Converter")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Hindi natuloy", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .onOpenURL { url in
            importFile(url)
        }
        .onAppear {
            diagnosticsAvailable = FileManager.default.fileExists(atPath: diagnosticsFile.path)
            if let log = try? String(contentsOf: diagnosticsFile, encoding: .utf8),
               log.contains("=== CONVERSION STARTED ==="),
               !log.contains("=== RESULT: SUCCESS ==="),
               !log.contains("=== RESULT: ERROR ===") {
                let lastLine = log.split(separator: "\n").last.map(String.init) ?? "Walang huling progress message."
                status = "Biglang natigil ang huling conversion. Huling detalye: \(lastLine)"
            }
        }
        .sheet(isPresented: $showImporter) {
            AssetDocumentPicker { selected in
                importFile(selected)
            }
        }
    }

    private func importFile(_ selected: URL) {
        let ext = selected.pathExtension.lowercased()
        guard ext == "unity3d" || ext == "zip" else {
            errorMessage = "Hindi suportado ang file na ito. Pumili ng .unity3d o .zip file."
            return
        }

        status = "Ini-import ang \(selected.lastPathComponent)…"
        errorMessage = nil
        let destinationDirectory = documents.appendingPathComponent("Imported", isDirectory: true)

        DispatchQueue.global(qos: .userInitiated).async {
            let scoped = selected.startAccessingSecurityScopedResource()
            defer { if scoped { selected.stopAccessingSecurityScopedResource() } }

            var coordinationError: NSError?
            var copyError: Error?
            var importedURL: URL?
            let coordinator = NSFileCoordinator()

            coordinator.coordinate(readingItemAt: selected, options: [], error: &coordinationError) { readableURL in
                do {
                    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                    let destination = destinationDirectory.appendingPathComponent(UUID().uuidString + "_" + selected.lastPathComponent)
                    do {
                        try FileManager.default.copyItem(at: readableURL, to: destination)
                    } catch {
                        try FileManager.default.copyItem(at: selected, to: destination)
                    }
                    importedURL = destination
                } catch {
                    copyError = error
                }
            }

            let failure = coordinationError ?? copyError
            DispatchQueue.main.async {
                if let failure {
                    status = "Hindi na-import ang file."
                    errorMessage = "Hindi mabasa ang file mula sa Files. \(failure.localizedDescription)"
                    return
                }
                guard let importedURL else {
                    status = "Hindi na-import ang file."
                    errorMessage = "Walang file na naipasa mula sa Files. Subukan ulit gamit ang Share → Isha Converter."
                    return
                }
                inputURL = importedURL
                outputURL = nil
                status = "Handa nang i-convert: \(selected.lastPathComponent)"
            }
        }
    }

    private func qualityOption(_ title: String, _ detail: String, value: String) -> some View {
        let selected = selectedTextureQuality == value
        return Button {
            selectedTextureQuality = value
        } label: {
            VStack(spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.vertical, 6)
            .background(selected ? Color.blue.opacity(0.16) : Color(.secondarySystemBackground))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Color.blue : Color.secondary.opacity(0.2), lineWidth: selected ? 1.5 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(isConverting)
    }

    private func convert() {
        guard let inputURL else { return }
        isConverting = true
        outputURL = nil
        status = "Binabasa ang shaders at kino-convert ang Unity bundles…"
        let outputDirectory = documents.appendingPathComponent("Converted", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let started = "=== CONVERSION STARTED ===\n\(Date().formatted())\nInput: \(inputURL.lastPathComponent)\n"
        try? started.write(to: diagnosticsFile, atomically: true, encoding: .utf8)
        PythonConverter.shared.convert(input: inputURL, outputDirectory: outputDirectory, textureQuality: selectedTextureQuality) { result in
            DispatchQueue.main.async {
                isConverting = false
                diagnosticsAvailable = FileManager.default.fileExists(atPath: diagnosticsFile.path)
                switch result {
                case .success(let url):
                    outputURL = url
                    status = "Tapos na. Puwede mo nang i-save ang ZIP sa Files."
                case .failure(let error):
                    status = "Hindi natuloy ang conversion."
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private var diagnosticsFile: URL {
        documents.appendingPathComponent("Converted", isDirectory: true)
            .appendingPathComponent("conversion_diagnostics.log")
    }
}



// MARK: - NutCracker-inspired MLBB tools (native iOS implementation)
// The Android XAPK's Android-only storage bridge is intentionally not ported.
// iOS sandboxing does not allow a normal app to write to another app's private files.

private struct ToolHero: Identifiable, Hashable {
    let id: Int
    let name: String
    let role: String
    let lane: String
}

private enum ToolCatalog {
    static let heroes: [ToolHero] = [

        ToolHero(id: 1, name: "Miya", role: "Marksman", lane: "Gold Lane"),
        ToolHero(id: 2, name: "Balmond", role: "Fighter", lane: "Jungle"),
        ToolHero(id: 3, name: "Saber", role: "Assassin", lane: "Jungle/Roaming"),
        ToolHero(id: 4, name: "Alice", role: "Mage/Tank", lane: "EXP Lane/Jungle"),
        ToolHero(id: 5, name: "Nana", role: "Mage", lane: "Mid Lane"),
        ToolHero(id: 6, name: "Tigreal", role: "Tank", lane: "Roaming"),
        ToolHero(id: 7, name: "Alucard", role: "Fighter/Assassin", lane: "Jungle"),
        ToolHero(id: 8, name: "Karina", role: "Assassin", lane: "Jungle"),
        ToolHero(id: 9, name: "Akai", role: "Tank", lane: "Roaming/Jungle"),
        ToolHero(id: 10, name: "Franco", role: "Tank", lane: "Roaming"),
        ToolHero(id: 11, name: "Bane", role: "Fighter/Mage", lane: "Jungle/EXP Lane"),
        ToolHero(id: 12, name: "Bruno", role: "Marksman", lane: "Gold Lane"),
        ToolHero(id: 13, name: "Clint", role: "Marksman", lane: "Gold Lane"),
        ToolHero(id: 14, name: "Rafaela", role: "Support", lane: "Roaming"),
        ToolHero(id: 15, name: "Eudora", role: "Mage", lane: "Mid Lane"),
        ToolHero(id: 16, name: "Zilong", role: "Fighter/Assassin", lane: "EXP Lane"),
        ToolHero(id: 17, name: "Fanny", role: "Assassin", lane: "Jungle"),
        ToolHero(id: 18, name: "Layla", role: "Marksman", lane: "Gold Lane"),
        ToolHero(id: 19, name: "Minotaur", role: "Tank/Support", lane: "Roaming"),
        ToolHero(id: 20, name: "Lolita", role: "Support/Tank", lane: "Roaming"),
        ToolHero(id: 21, name: "Hayabusa", role: "Assassin", lane: "Jungle"),
        ToolHero(id: 22, name: "Freya", role: "Fighter", lane: "EXP Lane"),
        ToolHero(id: 23, name: "Gord", role: "Mage", lane: "Mid Lane"),
        ToolHero(id: 24, name: "Natalia", role: "Assassin", lane: "Roaming"),
        ToolHero(id: 25, name: "Kagura", role: "Mage", lane: "Mid Lane"),
        ToolHero(id: 26, name: "Chou", role: "Fighter", lane: "EXP Lane/Roaming"),
        ToolHero(id: 27, name: "Sun", role: "Fighter", lane: "EXP Lane/Jungle"),
        ToolHero(id: 28, name: "Alpha", role: "Fighter", lane: "Jungle/EXP Lane"),
        ToolHero(id: 29, name: "Ruby", role: "Fighter", lane: "EXP Lane"),
        ToolHero(id: 30, name: "Yi Sun-shin", role: "Assassin/Marksman", lane: "Jungle/Gold Lane"),
        ToolHero(id: 31, name: "Moskov", role: "Marksman", lane: "Gold Lane"),
        ToolHero(id: 32, name: "Johnson", role: "Tank/Support", lane: "Roaming"),
        ToolHero(id: 33, name: "Cyclops", role: "Mage", lane: "Mid Lane"),
        ToolHero(id: 34, name: "Estes", role: "Support", lane: "Roaming"),
        ToolHero(id: 35, name: "Hilda", role: "Fighter/Tank", lane: "Roaming/EXP Lane"),
        ToolHero(id: 36, name: "Aurora", role: "Mage", lane: "Mid Lane"),
        ToolHero(id: 37, name: "Lapu-Lapu", role: "Fighter", lane: "EXP Lane"),
        ToolHero(id: 38, name: "Vexana", role: "Mage", lane: "Mid Lane"),
        ToolHero(id: 39, name: "Roger", role: "Fighter/Marksman", lane: "Jungle"),
        ToolHero(id: 40, name: "Karrie", role: "Marksman", lane: "Gold Lane"),
        ToolHero(id: 41, name: "Gatotkaca", role: "Tank/Fighter", lane: "Roaming/EXP Lane"),
        ToolHero(id: 42, name: "Harley", role: "Assassin/Mage", lane: "Jungle"),
        ToolHero(id: 43, name: "Irithel", role: "Marksman", lane: "Gold Lane"),
        ToolHero(id: 44, name: "Grock", role: "Tank/Fighter", lane: "Roaming"),
        ToolHero(id: 45, name: "Argus", role: "Fighter", lane: "EXP Lane"),
        ToolHero(id: 46, name: "Odette", role: "Mage", lane: "Mid Lane"),
        ToolHero(id: 47, name: "Lancelot", role: "Assassin", lane: "Jungle"),
        ToolHero(id: 48, name: "Diggie", role: "Support", lane: "Roaming"),
        ToolHero(id: 49, name: "Hylos", role: "Tank", lane: "Roaming"),
        ToolHero(id: 50, name: "Zhask", role: "Mage", lane: "Mid Lane"),
        ToolHero(id: 51, name: "Helcurt", role: "Assassin", lane: "Jungle"),
        ToolHero(id: 52, name: "Pharsa", role: "Mage", lane: "Mid Lane"),
        ToolHero(id: 53, name: "Lesley", role: "Marksman/Assassin", lane: "Gold Lane"),
        ToolHero(id: 54, name: "Jawhead", role: "Fighter", lane: "EXP Lane/Jungle"),
        ToolHero(id: 55, name: "Angela", role: "Support", lane: "Roaming"),
        ToolHero(id: 56, name: "Gusion", role: "Assassin", lane: "Jungle"),
        ToolHero(id: 57, name: "Valir", role: "Mage", lane: "Mid Lane"),
        ToolHero(id: 58, name: "Martis", role: "Fighter", lane: "Jungle"),
        ToolHero(id: 59, name: "Uranus", role: "Tank", lane: "EXP Lane"),
        ToolHero(id: 60, name: "Hanabi", role: "Marksman", lane: "Gold Lane"),
        ToolHero(id: 61, name: "Chang'e", role: "Mage", lane: "Mid Lane"),
        ToolHero(id: 62, name: "Kaja", role: "Support/Fighter", lane: "Roaming"),
        ToolHero(id: 63, name: "Selena", role: "Assassin/Mage", lane: "Roaming/Mid Lane"),
        ToolHero(id: 64, name: "Aldous", role: "Fighter", lane: "EXP Lane"),
        ToolHero(id: 65, name: "Claude", role: "Marksman", lane: "Gold Lane"),
        ToolHero(id: 66, name: "Vale", role: "Mage", lane: "Mid Lane"),
        ToolHero(id: 67, name: "Leomord", role: "Fighter", lane: "Jungle"),
        ToolHero(id: 68, name: "Lunox", role: "Mage", lane: "Mid Lane"),
        ToolHero(id: 69, name: "Hanzo", role: "Assassin", lane: "Jungle"),
        ToolHero(id: 70, name: "Belerick", role: "Tank", lane: "Roaming"),
        ToolHero(id: 71, name: "Kimmy", role: "Marksman/Mage", lane: "Gold Lane"),
        ToolHero(id: 72, name: "Thamuz", role: "Fighter", lane: "EXP Lane"),
        ToolHero(id: 73, name: "Harith", role: "Mage", lane: "Gold Lane/Jungle"),
        ToolHero(id: 74, name: "Minsitthar", role: "Fighter", lane: "EXP Lane/Roaming"),
        ToolHero(id: 75, name: "Kadita", role: "Mage/Assassin", lane: "Mid Lane"),
        ToolHero(id: 76, name: "Faramis", role: "Support/Mage", lane: "Mid Lane"),
        ToolHero(id: 77, name: "Badang", role: "Fighter", lane: "Roaming/EXP Lane"),
        ToolHero(id: 78, name: "Khufra", role: "Tank", lane: "Roaming"),
        ToolHero(id: 79, name: "Granger", role: "Marksman", lane: "Jungle/Gold Lane"),
        ToolHero(id: 80, name: "Guinevere", role: "Fighter", lane: "EXP Lane"),
        ToolHero(id: 81, name: "Esmeralda", role: "Tank/Mage", lane: "EXP Lane"),
        ToolHero(id: 82, name: "Terizla", role: "Fighter/Tank", lane: "EXP Lane"),
        ToolHero(id: 83, name: "X.Borg", role: "Fighter", lane: "EXP Lane"),
        ToolHero(id: 84, name: "Ling", role: "Assassin", lane: "Jungle"),
        ToolHero(id: 85, name: "Dyrroth", role: "Fighter", lane: "EXP Lane/Jungle"),
        ToolHero(id: 86, name: "Lylia", role: "Mage", lane: "Mid Lane"),
        ToolHero(id: 87, name: "Baxia", role: "Tank", lane: "Jungle"),
        ToolHero(id: 88, name: "Masha", role: "Fighter/Tank", lane: "EXP Lane"),
        ToolHero(id: 89, name: "Wanwan", role: "Marksman", lane: "Gold Lane"),
        ToolHero(id: 90, name: "Silvanna", role: "Fighter", lane: "EXP Lane"),
        ToolHero(id: 91, name: "Cecilion", role: "Mage", lane: "Mid Lane"),
        ToolHero(id: 92, name: "Carmilla", role: "Support/Tank", lane: "Roaming"),
        ToolHero(id: 93, name: "Atlas", role: "Tank", lane: "Roaming"),
        ToolHero(id: 94, name: "Popol and Kupa", role: "Marksman", lane: "Jungle/Gold Lane"),
        ToolHero(id: 95, name: "Yu Zhong", role: "Fighter", lane: "EXP Lane"),
        ToolHero(id: 96, name: "Luo Yi", role: "Mage", lane: "Mid Lane"),
        ToolHero(id: 97, name: "Benedetta", role: "Assassin/Fighter", lane: "EXP Lane"),
        ToolHero(id: 98, name: "Khaleed", role: "Fighter", lane: "EXP Lane"),
        ToolHero(id: 99, name: "Barats", role: "Tank/Fighter", lane: "Jungle"),
        ToolHero(id: 100, name: "Brody", role: "Marksman", lane: "Gold Lane"),
        ToolHero(id: 101, name: "Yve", role: "Mage", lane: "Mid Lane"),
        ToolHero(id: 102, name: "Mathilda", role: "Support/Assassin", lane: "Roaming"),
        ToolHero(id: 103, name: "Paquito", role: "Fighter/Assassin", lane: "EXP Lane"),
        ToolHero(id: 104, name: "Gloo", role: "Tank", lane: "Roaming/EXP Lane"),
        ToolHero(id: 105, name: "Beatrix", role: "Marksman", lane: "Gold Lane"),
        ToolHero(id: 106, name: "Phoveus", role: "Fighter", lane: "EXP Lane"),
        ToolHero(id: 107, name: "Natan", role: "Marksman", lane: "Gold Lane"),
        ToolHero(id: 108, name: "Aulus", role: "Fighter", lane: "Jungle"),
        ToolHero(id: 109, name: "Aamon", role: "Assassin", lane: "Jungle"),
        ToolHero(id: 110, name: "Valentina", role: "Mage", lane: "Mid Lane"),
        ToolHero(id: 111, name: "Edith", role: "Tank/Marksman", lane: "EXP Lane/Roaming"),
        ToolHero(id: 112, name: "Floryn", role: "Support", lane: "Roaming"),
        ToolHero(id: 113, name: "Yin", role: "Fighter/Assassin", lane: "Jungle/EXP Lane"),
        ToolHero(id: 114, name: "Melissa", role: "Marksman", lane: "Gold Lane"),
        ToolHero(id: 115, name: "Xavier", role: "Mage", lane: "Mid Lane"),
        ToolHero(id: 116, name: "Julian", role: "Assassin/Fighter", lane: "Jungle"),
        ToolHero(id: 117, name: "Fredrinn", role: "Fighter/Tank", lane: "Jungle"),
        ToolHero(id: 118, name: "Joy", role: "Assassin", lane: "Jungle"),
        ToolHero(id: 119, name: "Novaria", role: "Mage", lane: "Mid Lane"),
        ToolHero(id: 120, name: "Arlott", role: "Fighter/Assassin", lane: "EXP Lane"),
        ToolHero(id: 121, name: "Ixia", role: "Marksman", lane: "Gold Lane"),
        ToolHero(id: 122, name: "Nolan", role: "Assassin", lane: "Jungle"),
        ToolHero(id: 123, name: "Cici", role: "Fighter", lane: "EXP Lane"),
        ToolHero(id: 124, name: "Chip", role: "Support/Tank", lane: "Roaming"),
        ToolHero(id: 125, name: "Zhuxin", role: "Mage", lane: "Mid Lane"),
        ToolHero(id: 126, name: "Suyou", role: "Assassin/Fighter", lane: "Jungle/EXP Lane"),
        ToolHero(id: 127, name: "Lukas", role: "Fighter", lane: "EXP Lane"),
        ToolHero(id: 128, name: "Kalea", role: "Support/Fighter", lane: "Roaming"),
        ToolHero(id: 129, name: "Zetian", role: "Mage", lane: "Mid Lane"),
        ToolHero(id: 130, name: "Obsidia", role: "Marksman", lane: "Gold Lane"),
        ToolHero(id: 131, name: "Sora", role: "Fighter/Assassin", lane: "EXP Lane"),
        ToolHero(id: 132, name: "Marcel", role: "Support", lane: "Roaming"),
        ToolHero(id: 133, name: "Hiara", role: "Assassin", lane: "Jungle")
    ]
}

private struct ToolHistoryRecord: Identifiable, Codable {
    var id: UUID = UUID()
    var fileName: String
    var action: String
    var details: String
    var date: Date = Date()
    var localPath: String?
}

private final class ToolHistoryStore: ObservableObject {
    static let shared = ToolHistoryStore()
    @Published private(set) var records: [ToolHistoryRecord] = []

    private let key = "isha.mlbbtools.history.v1"

    private init() {
        load()
    }

    func add(fileName: String, action: String, details: String, localPath: String?) {
        records.insert(
            ToolHistoryRecord(fileName: fileName, action: action, details: details, localPath: localPath),
            at: 0
        )
        records = Array(records.prefix(100))
        save()
    }

    func remove(_ record: ToolHistoryRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    func clear() {
        records.removeAll()
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ToolHistoryRecord].self, from: data) else {
            records = []
            return
        }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

private enum ToolTab: String, CaseIterable {
    case dashboard = "Home"
    case heroes = "Heroes"
    case skins = "Skin Library"
    case installer = "Installer"
    case history = "History"

    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2.fill"
        case .heroes: return "person.3.fill"
        case .skins: return "person.crop.square"
        case .installer: return "folder.badge.plus"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

struct NutCrackerToolsView: View {
    @State private var selectedTab: ToolTab = .dashboard
    @StateObject private var history = ToolHistoryStore.shared

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Group {
                    switch selectedTab {
                    case .dashboard:
                        ToolDashboardView(history: history, selectTab: { selectedTab = $0 })
                    case .heroes:
                        ToolHeroesView()
                    case .skins:
                        ToolSkinLibraryView(history: history)
                    case .installer:
                        ToolInstallerView(history: history)
                    case .history:
                        ToolHistoryView(history: history)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack(spacing: 0) {
                    ForEach(ToolTab.allCases, id: \.self) { tab in
                        Button {
                            selectedTab = tab
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: tab.symbol)
                                    .font(.system(size: 18, weight: .semibold))
                                Text(tab.rawValue)
                                    .font(.system(size: 10, weight: .medium))
                                    .lineLimit(1)
                            }
                            .foregroundColor(selectedTab == tab ? .blue : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(selectedTab == .dashboard ? "MLBB Tools" : selectedTab.rawValue)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ToolDashboardView: View {
    @ObservedObject var history: ToolHistoryStore
    let selectTab: (ToolTab) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 15)
                                .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                            Image(systemName: "gamecontroller.fill")
                                .font(.system(size: 25, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .frame(width: 58, height: 58)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("MLBB TOOLS")
                                .font(.title2.bold())
                            Text("Hero guides • Skin library • Package tools")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Text("Browse your hero references, manage local packages and keep a record of exported files.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))

                HStack(spacing: 10) {
                    ToolMetricCard(title: "Heroes", value: "\(ToolCatalog.heroes.count)", symbol: "person.3.fill")
                    ToolMetricCard(title: "Local history", value: "\(history.records.count)", symbol: "clock")
                }

                Text("TOOLS")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ToolDashboardTile(title: "Hero Guides", subtitle: "Roster and hero profiles", symbol: "person.text.rectangle") {
                        selectTab(.heroes)
                    }
                    ToolDashboardTile(title: "Skin Library", subtitle: "Imported local packages", symbol: "square.grid.2x2") {
                        selectTab(.skins)
                    }
                    ToolDashboardTile(title: "Installer", subtitle: "Import and export files", symbol: "folder.badge.plus") {
                        selectTab(.installer)
                    }
                    ToolDashboardTile(title: "Install History", subtitle: "Recent file operations", symbol: "clock.arrow.circlepath") {
                        selectTab(.history)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("MORE FEATURES")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    NavigationLink(destination: ToolResplendentView()) {
                        ToolLinkRow(title: "Resplendent Colors", subtitle: "Choose a preview color", symbol: "paintpalette.fill")
                    }
                    NavigationLink(destination: ToolSettingsView()) {
                        ToolLinkRow(title: "Settings", subtitle: "Local backup and display preferences", symbol: "gearshape.fill")
                    }
                    NavigationLink(destination: ToolAccountSafetyView()) {
                        ToolLinkRow(title: "Account Safety", subtitle: "iOS compatibility and safety notes", symbol: "shield.lefthalf.filled")
                    }
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 6) {
                    Label("iOS file access note", systemImage: "info.circle")
                        .font(.subheadline.bold())
                    Text("Packages can be imported, reviewed and exported through Files. A normal iOS app cannot directly alter Mobile Legends' private app storage, so this build does not claim to inject skins into the running game.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }
}

private struct ToolMetricCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundColor(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.title3.bold())
                Text(title).font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct ToolDashboardTile: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundColor(.blue)
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
    }
}

private struct ToolLinkRow: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundColor(.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundColor(.primary)
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundColor(.secondary)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

private struct ToolHeroesView: View {
    @State private var searchText = ""
    @State private var selectedRole = "All"

    private let roles = ["All", "Tank", "Fighter", "Assassin", "Mage", "Marksman", "Support"]

    private var filteredHeroes: [ToolHero] {
        ToolCatalog.heroes.filter { hero in
            let matchesText = searchText.isEmpty ||
                hero.name.localizedCaseInsensitiveContains(searchText) ||
                hero.role.localizedCaseInsensitiveContains(searchText) ||
                hero.lane.localizedCaseInsensitiveContains(searchText)
            let matchesRole = selectedRole == "All" || hero.role.localizedCaseInsensitiveContains(selectedRole)
            return matchesText && matchesRole
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(roles, id: \.self) { role in
                        Button {
                            selectedRole = role
                        } label: {
                            Text(role)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(selectedRole == role ? Color.blue.opacity(0.16) : Color(.secondarySystemGroupedBackground))
                                .foregroundColor(selectedRole == role ? .blue : .secondary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            List(filteredHeroes) { hero in
                NavigationLink(destination: ToolHeroDetailView(hero: hero)) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.blue.opacity(0.12))
                            Text(String(hero.name.prefix(1)))
                                .font(.headline.bold())
                                .foregroundColor(.blue)
                        }
                        .frame(width: 42, height: 42)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(hero.name).font(.subheadline.weight(.semibold))
                            Text(hero.role + " • " + hero.lane)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.plain)
        }
        .searchable(text: $searchText, prompt: "Search heroes, roles or lanes")
    }
}

private struct ToolHeroDetailView: View {
    let hero: ToolHero

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(LinearGradient(colors: [.blue.opacity(0.8), .purple.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Text(String(hero.name.prefix(1)))
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .frame(width: 74, height: 74)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hero.name).font(.title2.bold())
                        Text(hero.role).font(.subheadline).foregroundColor(.secondary)
                        Text(hero.lane).font(.caption).foregroundColor(.secondary)
                    }
                }
                ToolInfoPanel(title: "Hero Profile", message: "Hero reference data is available in this build. Skill descriptions, matchup percentages and combo guides require a separate current game-data source.")
                ToolInfoPanel(title: "Skills and Combos", message: "The APK loads this information from its remote hero catalog. No complete skill/combos dataset was included in the supplied XAPK, so exact skill details are not fabricated here.")
                ToolInfoPanel(title: "Counters and Matchups", message: "Counter and cooperation relationships are not bundled in the XAPK resources. This section is reserved for a verified hero-data source.")
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(hero.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ToolInfoPanel: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            Text(message).font(.footnote).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct ToolSkinCatalogDocument: Decodable {
    let catalogVersion: String
    let heroCount: Int
    let skinCount: Int
    let heroes: [ToolSkinCatalogHero]
}

private struct ToolSkinCatalogHero: Decodable, Identifiable {
    let heroId: Int
    let skins: [ToolSkinCatalogEntry]
    var id: Int { heroId }
}

private struct ToolSkinCatalogEntry: Decodable, Hashable {
    let id: Int
    let name: String
    let category: Int
    let type: String
    let backupAvailable: Bool
    let upgradeCount: Int
    var stableID: String { "\(id)-\(category)" }
}

private final class ToolSkinCatalogStore: ObservableObject {
    static let shared = ToolSkinCatalogStore()

    @Published private(set) var document: ToolSkinCatalogDocument?
    @Published private(set) var loadError: String?

    private init() {
        load()
    }

    private func load() {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent("isha_skin_catalog.json.zlib")
        guard let compressed = try? Data(contentsOf: url) else {
            loadError = "Skin catalog file is missing from this build."
            return
        }

        let capacity = 2 * 1024 * 1024
        var expanded = Data(count: capacity)
        let decodedSize = compressed.withUnsafeBytes { sourceBuffer in
            expanded.withUnsafeMutableBytes { destinationBuffer in
                guard let source = sourceBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let destination = destinationBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destination,
                    capacity,
                    source,
                    compressed.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard decodedSize > 0 else {
            loadError = "The built-in skin catalog could not be decompressed."
            return
        }
        expanded.count = decodedSize

        do {
            document = try JSONDecoder().decode(ToolSkinCatalogDocument.self, from: expanded)
        } catch {
            loadError = "The built-in skin catalog is invalid: \(error.localizedDescription)"
        }
    }

    func hero(_ heroId: Int) -> ToolSkinCatalogHero? {
        document?.heroes.first(where: { $0.heroId == heroId })
    }

    func skinName(heroId: Int, skinId: Int, category: Int) -> String? {
        hero(heroId)?.skins.first(where: { $0.id == skinId && $0.category == category })?.name
    }
}

private struct ToolSkinSelection: Codable, Equatable {
    let heroId: Int
    let heroName: String
    let skinId: Int
    let skinName: String
    let category: Int
}

private final class ToolSkinSelectionStore: ObservableObject {
    static let shared = ToolSkinSelectionStore()

    @Published private(set) var original: ToolSkinSelection?
    @Published private(set) var replacement: ToolSkinSelection?

    private let originalKey = "isha.mlbbtools.skinSelection.original.v1"
    private let replacementKey = "isha.mlbbtools.skinSelection.replacement.v1"

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: originalKey) {
            original = try? JSONDecoder().decode(ToolSkinSelection.self, from: data)
        }
        if let data = defaults.data(forKey: replacementKey) {
            replacement = try? JSONDecoder().decode(ToolSkinSelection.self, from: data)
        }
    }

    func select(_ selection: ToolSkinSelection, asOriginal: Bool) {
        if asOriginal {
            original = selection
        } else {
            replacement = selection
        }
        persist()
    }

    func clear() {
        original = nil
        replacement = nil
        UserDefaults.standard.removeObject(forKey: originalKey)
        UserDefaults.standard.removeObject(forKey: replacementKey)
    }

    private func persist() {
        let defaults = UserDefaults.standard
        if let original, let data = try? JSONEncoder().encode(original) {
            defaults.set(data, forKey: originalKey)
        }
        if let replacement, let data = try? JSONEncoder().encode(replacement) {
            defaults.set(data, forKey: replacementKey)
        }
    }
}

private struct ToolSkinHeroSection: Identifiable {
    let hero: ToolHero
    let skins: [ToolSkinCatalogEntry]
    var id: Int { hero.id }
}

private struct ToolSkinLibraryView: View {
    @ObservedObject var history: ToolHistoryStore
    @ObservedObject private var catalog = ToolSkinCatalogStore.shared
    @ObservedObject private var selection = ToolSkinSelectionStore.shared
    @State private var searchText = ""
    @State private var selectedCategory = "All"

    private let categoryFilters = ["All", "Slot 0", "Slot 1", "Slot 2"]

    private var visibleSections: [ToolSkinHeroSection] {
        guard let document = catalog.document else { return [] }
        return document.heroes.compactMap { catalogHero in
            guard let hero = ToolCatalog.heroes.first(where: { $0.id == catalogHero.heroId }) else {
                return nil
            }
            let categoryFiltered = catalogHero.skins.filter { skin in
                selectedCategory == "All" || selectedCategory == "Slot \(skin.category)"
            }
            let matchingSkins: [ToolSkinCatalogEntry]
            if searchText.isEmpty || hero.name.localizedCaseInsensitiveContains(searchText) {
                matchingSkins = categoryFiltered
            } else {
                matchingSkins = categoryFiltered.filter {
                    $0.name.localizedCaseInsensitiveContains(searchText) ||
                    $0.type.localizedCaseInsensitiveContains(searchText) ||
                    String($0.id).contains(searchText)
                }
            }
            guard !matchingSkins.isEmpty else { return nil }
            return ToolSkinHeroSection(hero: hero, skins: matchingSkins)
        }
    }

    private var selectedPairDescription: String {
        let original = selection.original.map { "\($0.heroName) · \($0.skinName)" } ?? "Not selected"
        let replacement = selection.replacement.map { "\($0.heroName) · \($0.skinName)" } ?? "Not selected"
        return "Original: \(original)\nReplacement: \(replacement)"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                ToolInfoPanel(
                    title: "Skin Catalog",
                    message: catalog.document.map {
                        "\($0.skinCount.formatted()) skin entries across \($0.heroCount) heroes. Search by hero, skin name, type, or skin ID. The catalog contains metadata only; skin packages must be supplied separately."
                    } ?? (catalog.loadError ?? "Loading skin catalog…")
                )

                ToolInfoPanel(
                    title: "Selected Skin Pair",
                    message: selectedPairDescription
                )

                HStack {
                    Text("FILTER BY CATEGORY")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    Spacer()
                    if selection.original != nil || selection.replacement != nil {
                        Button("Clear selection", role: .destructive) {
                            selection.clear()
                        }
                        .font(.caption.weight(.semibold))
                    }
                }

                Picker("Category", selection: $selectedCategory) {
                    ForEach(categoryFilters, id: \.self) { filter in
                        Text(filter).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            if catalog.document == nil {
                VStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 38))
                        .foregroundColor(.secondary)
                    Text("Skin catalog unavailable").font(.headline)
                    Text(catalog.loadError ?? "The built-in catalog could not be loaded.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(visibleSections) { section in
                        Section {
                            ForEach(section.skins, id: \.stableID) { skin in
                                NavigationLink {
                                    ToolSkinDetailView(hero: section.hero, skin: skin, selection: selection)
                                } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(Color.blue.opacity(0.10))
                                            Image(systemName: "person.crop.square")
                                                .font(.title2)
                                                .foregroundColor(.blue)
                                        }
                                        .frame(width: 44, height: 48)

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(skin.name)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundColor(.primary)
                                            Text("ID \(skin.id) · Slot \(skin.category)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            if !skin.type.isEmpty {
                                                Text(skin.type.replacingOccurrences(of: "|", with: " · "))
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer(minLength: 4)
                                        if skin.backupAvailable || skin.upgradeCount > 0 {
                                            Image(systemName: "arrow.triangle.2.circlepath")
                                                .font(.caption.weight(.semibold))
                                                .foregroundColor(.blue)
                                        }
                                    }
                                    .padding(.vertical, 3)
                                }
                            }
                        } header: {
                            HStack {
                                Text(section.hero.name)
                                Spacer()
                                Text("\(section.skins.count) skins")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    let importedPackages = history.records.filter {
                        $0.action == "Imported" || $0.action == "Converted"
                    }
                    if !importedPackages.isEmpty {
                        Section("My imported packages") {
                            ForEach(importedPackages) { record in
                                NavigationLink(destination: ToolPackageDetailView(record: record)) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(record.fileName)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(2)
                                        Text(record.details)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .background(Color(.systemGroupedBackground))
        .searchable(text: $searchText, prompt: "Search heroes, skins, or IDs")
    }
}

private struct ToolSkinDetailView: View {
    let hero: ToolHero
    let skin: ToolSkinCatalogEntry
    @ObservedObject var selection: ToolSkinSelectionStore
    @State private var notice: String?

    private var selectionValue: ToolSkinSelection {
        ToolSkinSelection(
            heroId: hero.id,
            heroName: hero.name,
            skinId: skin.id,
            skinName: skin.name,
            category: skin.category
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.20), Color.purple.opacity(0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    VStack(spacing: 8) {
                        Image(systemName: "person.crop.square")
                            .font(.system(size: 54))
                            .foregroundColor(.blue)
                        Text(skin.name)
                            .font(.title3.bold())
                            .multilineTextAlignment(.center)
                        Text(hero.name)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(24)
                }
                .frame(height: 190)

                ToolInfoPanel(
                    title: "Skin metadata",
                    message: "Skin ID: \(skin.id)\nHero ID: \(hero.id)\nCategory slot: \(skin.category)\nType: \(skin.type.isEmpty ? "Unspecified" : skin.type.replacingOccurrences(of: "|", with: " · "))"
                )

                ToolInfoPanel(
                    title: "Package references",
                    message: "\(skin.backupAvailable ? "A backup reference is listed" : "No backup reference is listed") · \(skin.upgradeCount) related upgrade routes in the source catalog. These are catalog references, not bundled skin files."
                )

                VStack(spacing: 10) {
                    Button {
                        selection.select(selectionValue, asOriginal: true)
                        notice = "Saved \(skin.name) as the original skin selection."
                    } label: {
                        Label("Select as Original Skin", systemImage: "arrow.down.left.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        selection.select(selectionValue, asOriginal: false)
                        notice = "Saved \(skin.name) as the replacement skin selection."
                    } label: {
                        Label("Select as Replacement Skin", systemImage: "arrow.triangle.swap")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Text("The selection is saved locally in Isha. Converting an imported package does not automatically modify or install anything inside Mobile Legends.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Skin Details")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Skin selection", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )) {
            Button("OK", role: .cancel) { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }
}

private struct ToolPackageDetailView: View {
    let record: ToolHistoryRecord
    @State private var showShare = false
    @State private var alertMessage: String?

    private var fileURL: URL? {
        guard let path = record.localPath else { return nil }
        return URL(fileURLWithPath: path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "archivebox.fill")
                .font(.system(size: 42))
                .foregroundColor(.blue)
            Text(record.fileName).font(.title3.bold())
            Text(record.details).font(.footnote).foregroundColor(.secondary)
            Text("Imported \(record.date.formatted(date: .long, time: .shortened))")
                .font(.caption)
                .foregroundColor(.secondary)

            Button {
                guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
                    alertMessage = "The local copy is no longer available. Import the file again."
                    return
                }
                showShare = true
            } label: {
                Label("Export package", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Package details")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShare) {
            if let fileURL { ActivityView(activityItems: [fileURL]) }
        }
        .alert("Package", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }
}

private struct ToolInstallerView: View {
    @ObservedObject var history: ToolHistoryStore
    @ObservedObject private var skinSelection = ToolSkinSelectionStore.shared
    @State private var showPicker = false
    @State private var selectedURL: URL?
    @State private var backupURL: URL?
    @State private var restoredURL: URL?
    @State private var outputURL: URL?
    @State private var showShare = false
    @State private var showBackupShare = false
    @State private var showRestoredShare = false
    @State private var alertMessage: String?
    @State private var statusMessage = "Choose an Android Unity3D bundle or ZIP package to process."
    @State private var isImporting = false
    @State private var isConverting = false
    @State private var selectedTextureQuality = "high"

    // The existing Isha converter bridge accepts Unity3D and ZIP input.
    // RAR and 7z are intentionally not advertised as processable formats.
    private let supportedExtensions: Set<String> = ["zip", "unity3d"]

    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ToolInfoPanel(
                    title: "Unity Asset Processor",
                    message: "This uses the existing Isha Converter Python/UnityPy engine. Import a .unity3d bundle or ZIP, choose an ASTC quality profile, then convert and export the iOS-ready ZIP."
                )

                if skinSelection.original != nil || skinSelection.replacement != nil {
                    ToolInfoPanel(
                        title: "Selected Skin Pair",
                        message: "Original: \(skinSelection.original.map { "\($0.heroName) · \($0.skinName)" } ?? "Not selected")\nReplacement: \(skinSelection.replacement.map { "\($0.heroName) · \($0.skinName)" } ?? "Not selected")\n\nThese are saved catalog selections. The converter processes the package you import; it does not apply the pair to the installed game."
                    )
                }

                Button {
                    showPicker = true
                } label: {
                    Label(isImporting ? "Importing…" : "Choose Unity3D / ZIP file", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isImporting || isConverting)

                if let selectedURL {
                    VStack(alignment: .leading, spacing: 11) {
                        Label("Selected asset package", systemImage: "archivebox")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        Text(selectedURL.lastPathComponent)
                            .font(.headline)
                            .textSelection(.enabled)
                        Text("Format: \(selectedURL.pathExtension.uppercased())")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if let size = try? FileManager.default.attributesOfItem(atPath: selectedURL.path)[.size] as? NSNumber {
                            Text("Size: \(ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if let backupURL {
                            ToolInfoPanel(
                                title: "Offline Skin Package Engine",
                                message: "Isha stores an original backup, verifies the package during conversion, and keeps a repairable local working copy. Restore exports the untouched original package; Reapply runs the Isha conversion again."
                            )
                            Button { showBackupShare = true } label: {
                                Label("Export Original Backup", systemImage: "archivebox")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            Button(action: repairImportedCopy) {
                                Label("Repair Imported Package", systemImage: "wrench.and.screwdriver")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isConverting || isImporting || !FileManager.default.fileExists(atPath: backupURL.path))

                            Button(action: restoreOriginalBackup) {
                                Label("Restore Original Package", systemImage: "arrow.uturn.backward")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isConverting || isImporting || !FileManager.default.fileExists(atPath: backupURL.path))

                            if let restoredURL {
                                Button { showRestoredShare = true } label: {
                                    Label("Export Restored Original", systemImage: "square.and.arrow.up")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                Text(restoredURL.lastPathComponent)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Divider()

                        Text("TEXTURE QUALITY")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        Picker("Texture quality", selection: $selectedTextureQuality) {
                            Text("High · ASTC 4×4").tag("high")
                            Text("Balanced · ASTC 6×6").tag("balanced")
                            Text("Small · ASTC 8×8").tag("small")
                        }
                        .pickerStyle(.segmented)
                        .disabled(isConverting)

                        Button(action: processToIOS) {
                            HStack {
                                if isConverting {
                                    ProgressView().tint(.white)
                                }
                                Text(isConverting ? "Converting…" : "CONVERT TO iOS")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isConverting || isImporting)

                        if let outputURL {
                            Button(action: processToIOS) {
                                Label("Reapply Conversion", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isConverting || isImporting)

                            Button {
                                showShare = true
                            } label: {
                                Label("Export converted ZIP to Files", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isConverting)
                            Text(outputURL.lastPathComponent)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }

                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 15))
                } else {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                ToolInfoPanel(
                    title: "What this processor does",
                    message: "It reuses the existing converter, texture decoder, ASTC encoder, shader mapping, material-lighting fix and texture validation already in this repository. The result is saved as a converted ZIP inside Isha Converter and can be exported through Files."
                )

                ToolInfoPanel(
                    title: "Important",
                    message: "This processes a local copy of the files you select. It does not install or apply changes inside the Mobile Legends app."
                )
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $showPicker) {
            ToolsDocumentPicker { url in
                importFile(url)
            }
        }
        .sheet(isPresented: $showShare) {
            if let outputURL { ActivityView(activityItems: [outputURL]) }
        }
        .sheet(isPresented: $showBackupShare) {
            if let backupURL { ActivityView(activityItems: [backupURL]) }
        }
        .sheet(isPresented: $showRestoredShare) {
            if let restoredURL { ActivityView(activityItems: [restoredURL]) }
        }
        .alert("Asset Processor", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private func importFile(_ selected: URL) {
        let ext = selected.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            alertMessage = "The existing Isha conversion engine accepts .unity3d and .zip files. Extract RAR/7z archives to a supported format first."
            return
        }

        isImporting = true
        isConverting = false
        outputURL = nil
        statusMessage = "Importing \(selected.lastPathComponent)…"

        DispatchQueue.global(qos: .userInitiated).async {
            let scoped = selected.startAccessingSecurityScopedResource()
            defer { if scoped { selected.stopAccessingSecurityScopedResource() } }

            let folder = documents.appendingPathComponent("MLBB Tools/Imported", isDirectory: true)
            var coordinationError: NSError?
            var copyError: Error?
            var resultURL: URL?
            var backupResultURL: URL?
            let coordinator = NSFileCoordinator()

            coordinator.coordinate(readingItemAt: selected, options: [], error: &coordinationError) { readableURL in
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let destination = folder.appendingPathComponent(UUID().uuidString + "_" + selected.lastPathComponent)
                    do {
                        try FileManager.default.copyItem(at: readableURL, to: destination)
                    } catch {
                        try FileManager.default.copyItem(at: selected, to: destination)
                    }
                    let backupFolder = documents.appendingPathComponent("MLBB Tools/Backups", isDirectory: true)
                    try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
                    let backup = backupFolder.appendingPathComponent(UUID().uuidString + "_" + selected.lastPathComponent)
                    try FileManager.default.copyItem(at: destination, to: backup)
                    resultURL = destination
                    backupResultURL = backup
                } catch {
                    copyError = error
                }
            }

            let failure = coordinationError ?? copyError
            DispatchQueue.main.async {
                isImporting = false
                if let failure {
                    statusMessage = "Import failed."
                    alertMessage = "Could not copy the selected file from Files. \(failure.localizedDescription)"
                    return
                }
                guard let resultURL else {
                    statusMessage = "Import failed."
                    alertMessage = "Files did not provide a readable copy. Please select the file again."
                    return
                }

                selectedURL = resultURL
                backupURL = backupResultURL
                restoredURL = nil
                let size = (try? FileManager.default.attributesOfItem(atPath: resultURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                history.add(
                    fileName: resultURL.lastPathComponent,
                    action: "Imported",
                    details: "\(ext.uppercased()) • \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) • Original backup saved; ready for package inspection and conversion.",
                    localPath: resultURL.path
                )
                statusMessage = "Imported. Original backup saved. Convert to inspect, validate and process the Unity resources."
            }
        }
    }

    private func repairImportedCopy() {
        guard let selectedURL, let backupURL,
              FileManager.default.fileExists(atPath: backupURL.path) else {
            alertMessage = "The original package backup is unavailable. Import the original file again."
            return
        }
        do {
            let temporary = selectedURL.deletingLastPathComponent()
                .appendingPathComponent(UUID().uuidString + ".repairing")
            try FileManager.default.copyItem(at: backupURL, to: temporary)
            try FileManager.default.removeItem(at: selectedURL)
            try FileManager.default.moveItem(at: temporary, to: selectedURL)
            statusMessage = "Imported copy repaired from the preserved original backup."
            history.add(
                fileName: selectedURL.lastPathComponent,
                action: "Repaired",
                details: "Local imported package restored from its original backup.",
                localPath: selectedURL.path
            )
        } catch {
            alertMessage = "Could not repair the imported copy. \(error.localizedDescription)"
        }
    }

    private func restoreOriginalBackup() {
        guard let backupURL, FileManager.default.fileExists(atPath: backupURL.path) else {
            alertMessage = "The original backup is unavailable."
            return
        }
        do {
            let folder = documents.appendingPathComponent("MLBB Tools/Restored", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent("Restored_" + UUID().uuidString + "_" + backupURL.lastPathComponent)
            try FileManager.default.copyItem(at: backupURL, to: destination)
            restoredURL = destination
            showRestoredShare = true
            statusMessage = "Original package restored to Isha's local export folder."
            history.add(
                fileName: destination.lastPathComponent,
                action: "Restored",
                details: "Untouched original package copied from its preserved import backup.",
                localPath: destination.path
            )
        } catch {
            alertMessage = "Could not restore the original backup. \(error.localizedDescription)"
        }
    }

    private func processToIOS() {
        guard let selectedURL else { return }
        guard supportedExtensions.contains(selectedURL.pathExtension.lowercased()) else {
            alertMessage = "Choose a .unity3d or .zip file."
            return
        }

        isConverting = true
        outputURL = nil
        statusMessage = "Running the existing Isha conversion pipeline…"

        let outputDirectory = documents.appendingPathComponent("MLBB Tools/Converted", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            isConverting = false
            alertMessage = "Could not create the output folder. \(error.localizedDescription)"
            statusMessage = "Conversion could not start."
            return
        }

        PythonConverter.shared.convert(
            input: selectedURL,
            outputDirectory: outputDirectory,
            textureQuality: selectedTextureQuality
        ) { result in
            DispatchQueue.main.async {
                isConverting = false
                switch result {
                case .success(let convertedURL):
                    outputURL = convertedURL
                    let qualityLabel = [
                        "high": "High / ASTC 4×4",
                        "balanced": "Balanced / ASTC 6×6",
                        "small": "Small / ASTC 8×8"
                    ][selectedTextureQuality] ?? selectedTextureQuality
                    statusMessage = "Conversion completed. CRC and texture validation ran in the existing pipeline."
                    history.add(
                        fileName: convertedURL.lastPathComponent,
                        action: "Converted",
                        details: "Android to iOS • \(qualityLabel) • Converted ZIP ready to export.",
                        localPath: convertedURL.path
                    )
                case .failure(let error):
                    statusMessage = "Conversion failed. Check the diagnostic log in Documents/Converted."
                    alertMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct ToolsDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

private struct ToolHistoryView: View {
    @ObservedObject var history: ToolHistoryStore
    @State private var selectedRecord: ToolHistoryRecord?
    @State private var showShare = false
    @State private var showClearConfirmation = false

    var body: some View {
        Group {
            if history.records.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No history yet").font(.headline)
                    Text("Imported and exported package operations will appear here.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(history.records) { record in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(record.fileName)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)
                                Spacer()
                                Text(record.action.uppercased())
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(record.action == "Exported" ? .green : .blue)
                            }
                            Text(record.details).font(.caption).foregroundColor(.secondary)
                            Text(record.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                        .contextMenu {
                            Button(role: .destructive) {
                                history.remove(record)
                            } label: {
                                Label("Remove history entry", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Install History")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !history.records.isEmpty {
                    Button("Clear") { showClearConfirmation = true }
                }
            }
        }
        .confirmationDialog("Clear local history?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the history records only. Imported files in the app's Documents folder are not deleted.")
        }
    }
}

private struct ToolResplendentView: View {
    @State private var selectedColor = "Amber"
    @State private var selectedSkinName = ""

    private let colors: [(String, Color, String)] = [
        ("Amber", Color(red: 0.95, green: 0.64, blue: 0.18), "resplendent_shard_amber"),
        ("Aquamarine", Color(red: 0.24, green: 0.78, blue: 0.78), "resplendent_shard_aquamarine"),
        ("Verdelite", Color(red: 0.34, green: 0.72, blue: 0.48), "resplendent_shard_verdelite"),
        ("Vermilion", Color(red: 0.88, green: 0.27, blue: 0.22), "resplendent_shard_vermilion")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ToolInfoPanel(
                    title: "Resplendent Colors",
                    message: "The Android app's XAPK lists four shard colors. This iOS screen provides a local color preview only; applying a color to an MLBB skin requires game-file access that iOS does not expose."
                )

                Text("CHOOSE A COLOR")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(colors.indices, id: \.self) { index in
                        let item = colors[index]
                        Button {
                            selectedColor = item.0
                        } label: {
                            HStack(spacing: 9) {
                                Circle().fill(item.1).frame(width: 23, height: 23)
                                Text(item.0).font(.subheadline.weight(.semibold))
                                Spacer()
                                if selectedColor == item.0 {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(item.1)
                                }
                            }
                            .padding(12)
                            .background(Color(.secondarySystemGroupedBackground))
                            .overlay(RoundedRectangle(cornerRadius: 13).stroke(selectedColor == item.0 ? item.1 : Color.clear, lineWidth: 2))
                            .clipShape(RoundedRectangle(cornerRadius: 13))
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("PREVIEW").font(.caption.bold()).foregroundColor(.secondary)
                    HStack(spacing: 12) {
                        Circle().fill(colors.first(where: { $0.0 == selectedColor })?.1 ?? .blue).frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedColor).font(.headline)
                            Text("Selected preview color").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Text("Skin replacement and original-slot selection will need a verified Resplendent catalog source before they can be enabled.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Resplendent")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ToolSettingsView: View {
    @AppStorage("isha.mlbbtools.keepBackups") private var keepBackups = true
    @AppStorage("isha.mlbbtools.keepZzpEffects") private var keepZzpEffects = true
    @AppStorage("isha.mlbbtools.portraitMode") private var portraitMode = "Regular"
    @AppStorage("isha.mlbbtools.restoreQuality") private var restoreQuality = "Automatic"
    @AppStorage("isha.mlbbtools.showSkinDetails") private var showSkinDetails = true

    var body: some View {
        Form {
            Section(header: Text("LOCAL FILES")) {
                Toggle("Keep local package copies", isOn: $keepBackups)
                Toggle("Keep zzp effect files in exported copies", isOn: $keepZzpEffects)
            }

            Section(header: Text("SKIN PRESENTATION")) {
                Toggle("Show replacement skin details", isOn: $showSkinDetails)
                Picker("Portrait preview", selection: $portraitMode) {
                    Text("Regular").tag("Regular")
                    Text("Dynamic").tag("Dynamic")
                    Text("Full Dynamic").tag("Full Dynamic")
                }
            }

            Section(header: Text("RESTORE PREFERENCE")) {
                Picker("Restore quality", selection: $restoreQuality) {
                    Text("Automatic").tag("Automatic")
                    Text("Standard first").tag("Standard")
                    Text("High quality first").tag("High")
                }
                Text("These options are saved as preferences for the iOS package workflow. They do not change the installed game because direct game-folder restoration is unavailable on iOS.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("UNAVAILABLE ANDROID FEATURES")) {
                Label("Shizuku and Wireless ADB are not included.", systemImage: "info.circle")
                Label("Special Transformation / game-manifest editing is not enabled.", systemImage: "lock.fill")
                Label("Account Safety cannot scan other installed apps on iOS.", systemImage: "shield.lefthalf.filled")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ToolAccountSafetyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 42))
                    .foregroundColor(.blue)
                Text("Account Safety").font(.title2.bold())
                Text("The Android reference checks a list of installed apps associated with account-ban risk. iOS does not allow a normal app to enumerate other installed apps, so this scan cannot be reproduced on iPhone.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                ToolInfoPanel(
                    title: "Safe use reminder",
                    message: "Changing game files or using unsupported modifications may violate the game's rules and can affect account access. This iOS app does not bypass game protections or modify the running game."
                )
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Account Safety")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Existing iOS document handling

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct AssetDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let unityBundle = UTType(filenameExtension: "unity3d") ?? .data
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.zip, unityBundle], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
