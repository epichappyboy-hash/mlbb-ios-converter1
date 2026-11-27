import SwiftUI
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

            NixHubView()
                .tabItem {
                    Label("NIX HUB", systemImage: "square.grid.2x2.fill")
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

// MARK: - NIX HUB integration

private enum NixHubPage: String, CaseIterable, Identifiable {
    case heroSkins = "Hero Skins"
    case effects = "Effects"
    case backgrounds = "Backgrounds"
    case dailyRewards = "Daily Rewards"
    case heroCatalog = "Hero & Skin Catalog"
    case loadingIntros = "Loading Intros"
    case removeAds = "Remove Ads"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .heroSkins: return "Browse featured custom skin packages."
        case .effects: return "Explore emotes, battle effects, trails and more."
        case .backgrounds: return "Background catalog."
        case .dailyRewards: return "Daily tasks and rewards."
        case .heroCatalog: return "Search the hero reference catalog."
        case .loadingIntros: return "Browse and export loading intro packages."
        case .removeAds: return "Ad-free experience information."
        }
    }

    var symbol: String {
        switch self {
        case .heroSkins: return "person.crop.square"
        case .effects: return "sparkles"
        case .backgrounds: return "photo"
        case .dailyRewards: return "gift"
        case .heroCatalog: return "books.vertical"
        case .loadingIntros: return "play.rectangle"
        case .removeAds: return "rectangle.slash"
        }
    }
}

private struct NixHubPackage: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let imageURL: String
    let downloadURL: String
    let fileName: String
}

private struct NixHubEffectCategory: Identifiable {
    let id: String
    let title: String
    let count: Int
    let samples: [String]
}

private struct NixHubHero: Identifiable {
    let id: Int
    let name: String
    let role: String
    let lane: String
}

struct NixHubView: View {
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                                Text("N")
                                    .font(.system(size: 30, weight: .black, design: .rounded))
                                    .foregroundColor(.white)
                            }
                            .frame(width: 54, height: 54)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("NIX HUB")
                                    .font(.title.bold())
                                Text("Inside Isha Converter iOS")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Text("Browse skins, effects, hero references and downloadable packages.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(NixHubPage.allCases) { page in
                            NavigationLink(destination: NixHubPageView(page: page)) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Image(systemName: page.symbol)
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundColor(.blue)
                                    Text(page.rawValue)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text(page.subtitle)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(3)
                                }
                                .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
                                .padding(14)
                                .background(Color(.secondarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("ABOUT THIS iOS PORT")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        Text("Downloaded packages are saved to the app's NIX HUB Downloads folder and can be exported through the iOS share sheet. iOS apps cannot directly write into Mobile Legends' private app data.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("NIX HUB")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct NixHubPageView: View {
    let page: NixHubPage

    var body: some View {
        Group {
            switch page {
            case .heroSkins:
                NixHubPackageLibraryView(
                    title: "Featured Hero Skins",
                    subtitle: "Featured download entries included in the supplied NIX HUB XAPK.",
                    packages: NixHubData.featuredSkins
                )
            case .loadingIntros:
                NixHubPackageLibraryView(
                    title: "Loading Intros",
                    subtitle: "Download a package to the app's NIX HUB Downloads folder, then export it through Files.",
                    packages: NixHubData.loadingIntros
                )
            case .effects:
                NixHubEffectsView()
            case .heroCatalog:
                NixHubHeroCatalogView()
            case .backgrounds:
                NixHubInfoView(
                    symbol: "photo",
                    title: "Backgrounds",
                    message: "The supplied XAPK includes a Backgrounds menu entry, but it does not include a background package index. This section is reserved until the catalog data is available."
                )
            case .dailyRewards:
                NixHubInfoView(
                    symbol: "gift",
                    title: "Daily Rewards",
                    message: "The supplied XAPK describes daily tasks and rewards, but does not include a reward service or claim endpoint. No fake claim action is shown in this iOS port."
                )
            case .removeAds:
                NixHubInfoView(
                    symbol: "rectangle.slash",
                    title: "Remove Ads",
                    message: "The supplied XAPK contains this menu entry. An iOS ad-removal purchase and restore flow has not been integrated."
                )
            }
        }
        .navigationTitle(page.rawValue)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NixHubPackageLibraryView: View {
    let title: String
    let subtitle: String
    let packages: [NixHubPackage]

    @State private var downloadingID: String?
    @State private var downloadedURL: URL?
    @State private var showShareSheet = false
    @State private var alertMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.title2.bold())
                    Text(subtitle).font(.footnote).foregroundColor(.secondary)
                }
                ForEach(packages) { item in
                    HStack(spacing: 12) {
                        AsyncImage(url: URL(string: item.imageURL)) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                ZStack {
                                    Color(.tertiarySystemGroupedBackground)
                                    Image(systemName: "photo").foregroundColor(.secondary)
                                }
                            }
                        }
                        .frame(width: 104, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.title).font(.headline).lineLimit(2)
                            Text(item.subtitle).font(.caption).foregroundColor(.secondary).lineLimit(2)
                            Button {
                                download(item)
                            } label: {
                                HStack(spacing: 6) {
                                    if downloadingID == item.id {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "arrow.down.to.line")
                                    }
                                    Text(downloadingID == item.id ? "Downloading…" : "Download ZIP")
                                }
                                .font(.caption.bold())
                            }
                            .disabled(downloadingID != nil)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 15))
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $showShareSheet) {
            if let downloadedURL {
                ActivityView(activityItems: [downloadedURL])
            }
        }
        .alert("NIX HUB", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private func download(_ item: NixHubPackage) {
        guard let sourceURL = URL(string: item.downloadURL) else {
            alertMessage = "Invalid download URL."
            return
        }

        downloadingID = item.id
        Task {
            do {
                let (temporaryURL, response) = try await URLSession.shared.download(from: sourceURL)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw NixHubDownloadError.httpStatus(http.statusCode)
                }

                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let folder = documents.appendingPathComponent("NIX HUB Downloads", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

                let destination = folder.appendingPathComponent(item.fileName)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: destination)

                await MainActor.run {
                    downloadedURL = destination
                    downloadingID = nil
                    showShareSheet = true
                }
            } catch {
                await MainActor.run {
                    downloadingID = nil
                    alertMessage = "Hindi na-download ang package. \(error.localizedDescription)"
                }
            }
        }
    }
}

private enum NixHubDownloadError: LocalizedError {
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "The server returned HTTP \(code)."
        }
    }
}

private struct NixHubEffectsView: View {
    var body: some View {
        List(NixHubData.effectCategories) { category in
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(category.title).font(.headline)
                    Spacer()
                    Text("\(category.count)")
                        .font(.caption.bold())
                        .foregroundColor(.blue)
                }
                Text(category.samples.joined(separator: " • "))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 5)
        }
        .listStyle(.insetGrouped)
        .overlay(alignment: .top) {
            Text("Reference catalog • 618 records")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 5)
        }
    }
}

private struct NixHubHeroCatalogView: View {
    @State private var searchText = ""

    private var filteredHeroes: [NixHubHero] {
        guard !searchText.isEmpty else { return NixHubData.heroes }
        return NixHubData.heroes.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.role.localizedCaseInsensitiveContains(searchText) ||
            $0.lane.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List(filteredHeroes) { hero in
            VStack(alignment: .leading, spacing: 3) {
                Text(hero.name).font(.headline)
                Text("\(hero.role) • \(hero.lane)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 2)
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Search heroes, roles or lanes")
        .overlay(alignment: .top) {
            if filteredHeroes.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }
}

private struct NixHubInfoView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 42))
                .foregroundColor(.blue)
            Text(title).font(.title2.bold())
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

private enum NixHubData {
    static let featuredSkins = [
        NixHubPackage(
            id: "ken-masters",
            title: "Ken Masters",
            subtitle: "Chou • Featured skin package",
            imageURL: "https://github.com/Sparkies01/Images/raw/refs/heads/main/img/Ken.png",
            downloadURL: "https://raw.githubusercontent.com/lanz132/FIGHTER/main/264.zip",
            fileName: "Chou - Ken Masters.zip"
        ),
        NixHubPackage(
            id: "ryu",
            title: "Ryu",
            subtitle: "Paquito • Featured skin package",
            imageURL: "https://raw.githubusercontent.com/Sparkies01/Images/main/cover/1000621529.png",
            downloadURL: "https://raw.githubusercontent.com/lanz132/FIGHTER/main/267.zip",
            fileName: "Paquito - Ryu.zip"
        ),
        NixHubPackage(
            id: "guile",
            title: "Guile",
            subtitle: "Dyrroth • Featured skin package",
            imageURL: "https://raw.githubusercontent.com/Sparkies01/Images/main/cover/1000621528.png",
            downloadURL: "https://raw.githubusercontent.com/lanz132/FIGHTER/main/265.zip",
            fileName: "Dyrroth - Guile.zip"
        ),
        NixHubPackage(
            id: "chun-li",
            title: "Chun-Li",
            subtitle: "Guinevere • Featured skin package",
            imageURL: "https://raw.githubusercontent.com/Sparkies01/Images/main/cover/1000621527.png",
            downloadURL: "https://raw.githubusercontent.com/lanz132/FIGHTER/main/266.zip",
            fileName: "Guinevere - Chun-Li.zip"
        )
    ]

    static let loadingIntros = (1...10).map { number in
        let padded = number == 10 ? "10" : String(format: "%02d", number)
        let imageName = number == 10 ? "010" : padded
        return NixHubPackage(
            id: "intro-\(padded)",
            title: "Loading Intro \(padded)",
            subtitle: "Loading screen package",
            imageURL: "https://github.com/lanz132/INTRO/raw/main/\(imageName).jpg",
            downloadURL: "https://github.com/lanz132/LOADINGINTRO/raw/main/E\(number).zip",
            fileName: "NIX HUB Loading Intro \(padded).zip"
        )
    }

    static let effectCategories = [
        NixHubEffectCategory(id: "emote", title: "Emotes", count: 441, samples: ["Ouch!", "Oh, My Midas Touch", "Come Get Some!"]),
        NixHubEffectCategory(id: "statue", title: "Sacred Statues", count: 52, samples: ["Classic", "Light & Dark", "Carp Windsocks Fluttering~"]),
        NixHubEffectCategory(id: "spawn", title: "Spawn Effects", count: 39, samples: ["Cool Summer", "Classic", "Emerald Road"]),
        NixHubEffectCategory(id: "battle", title: "Battle Effects", count: 32, samples: ["Get over here", "Time to celebrate!", "Anniversary Celebration"]),
        NixHubEffectCategory(id: "elimination", title: "Elimination Effects", count: 25, samples: ["Classic", "K.O", "Roaming Ghost"]),
        NixHubEffectCategory(id: "notification", title: "Notifications", count: 13, samples: ["Classic", "Shinto Shrine", "Crystal"]),
        NixHubEffectCategory(id: "graffiti", title: "Graffiti", count: 13, samples: ["Thumbs Up", "Graffiti: Kitty", "Graffiti: Cinnamon"]),
        NixHubEffectCategory(id: "trail", title: "Trails", count: 3, samples: ["Classic", "M3 Glorious Trail", "Fiend Haunter Exclusive Trail"])
    ]

    static let heroes: [NixHubHero] = [
        NixHubHero(id: 1, name: "Miya", role: "Marksman", lane: "Gold Lane"),
        NixHubHero(id: 2, name: "Balmond", role: "Fighter", lane: "Jungle"),
        NixHubHero(id: 3, name: "Saber", role: "Assassin", lane: "Jungle/Roaming"),
        NixHubHero(id: 4, name: "Alice", role: "Mage/Tank", lane: "EXP Lane/Jungle"),
        NixHubHero(id: 5, name: "Nana", role: "Mage", lane: "Mid Lane"),
        NixHubHero(id: 6, name: "Tigreal", role: "Tank", lane: "Roaming"),
        NixHubHero(id: 7, name: "Alucard", role: "Fighter/Assassin", lane: "Jungle"),
        NixHubHero(id: 8, name: "Karina", role: "Assassin", lane: "Jungle"),
        NixHubHero(id: 9, name: "Akai", role: "Tank", lane: "Roaming/Jungle"),
        NixHubHero(id: 10, name: "Franco", role: "Tank", lane: "Roaming"),
        NixHubHero(id: 11, name: "Bane", role: "Fighter/Mage", lane: "Jungle/EXP Lane"),
        NixHubHero(id: 12, name: "Bruno", role: "Marksman", lane: "Gold Lane"),
        NixHubHero(id: 13, name: "Clint", role: "Marksman", lane: "Gold Lane"),
        NixHubHero(id: 14, name: "Rafaela", role: "Support", lane: "Roaming"),
        NixHubHero(id: 15, name: "Eudora", role: "Mage", lane: "Mid Lane"),
        NixHubHero(id: 16, name: "Zilong", role: "Fighter/Assassin", lane: "EXP Lane"),
        NixHubHero(id: 17, name: "Fanny", role: "Assassin", lane: "Jungle"),
        NixHubHero(id: 18, name: "Layla", role: "Marksman", lane: "Gold Lane"),
        NixHubHero(id: 19, name: "Minotaur", role: "Tank/Support", lane: "Roaming"),
        NixHubHero(id: 20, name: "Lolita", role: "Support/Tank", lane: "Roaming"),
        NixHubHero(id: 21, name: "Hayabusa", role: "Assassin", lane: "Jungle"),
        NixHubHero(id: 22, name: "Freya", role: "Fighter", lane: "EXP Lane"),
        NixHubHero(id: 23, name: "Gord", role: "Mage", lane: "Mid Lane"),
        NixHubHero(id: 24, name: "Natalia", role: "Assassin", lane: "Roaming"),
        NixHubHero(id: 25, name: "Kagura", role: "Mage", lane: "Mid Lane"),
        NixHubHero(id: 26, name: "Chou", role: "Fighter", lane: "EXP Lane/Roaming"),
        NixHubHero(id: 27, name: "Sun", role: "Fighter", lane: "EXP Lane/Jungle"),
        NixHubHero(id: 28, name: "Alpha", role: "Fighter", lane: "Jungle/EXP Lane"),
        NixHubHero(id: 29, name: "Ruby", role: "Fighter", lane: "EXP Lane"),
        NixHubHero(id: 30, name: "Yi Sun-shin", role: "Assassin/Marksman", lane: "Jungle/Gold Lane"),
        NixHubHero(id: 31, name: "Moskov", role: "Marksman", lane: "Gold Lane"),
        NixHubHero(id: 32, name: "Johnson", role: "Tank/Support", lane: "Roaming"),
        NixHubHero(id: 33, name: "Cyclops", role: "Mage", lane: "Mid Lane"),
        NixHubHero(id: 34, name: "Estes", role: "Support", lane: "Roaming"),
        NixHubHero(id: 35, name: "Hilda", role: "Fighter/Tank", lane: "Roaming/EXP Lane"),
        NixHubHero(id: 36, name: "Aurora", role: "Mage", lane: "Mid Lane"),
        NixHubHero(id: 37, name: "Lapu-Lapu", role: "Fighter", lane: "EXP Lane"),
        NixHubHero(id: 38, name: "Vexana", role: "Mage", lane: "Mid Lane"),
        NixHubHero(id: 39, name: "Roger", role: "Fighter/Marksman", lane: "Jungle"),
        NixHubHero(id: 40, name: "Karrie", role: "Marksman", lane: "Gold Lane"),
        NixHubHero(id: 41, name: "Gatotkaca", role: "Tank/Fighter", lane: "Roaming/EXP Lane"),
        NixHubHero(id: 42, name: "Harley", role: "Assassin/Mage", lane: "Jungle"),
        NixHubHero(id: 43, name: "Irithel", role: "Marksman", lane: "Gold Lane"),
        NixHubHero(id: 44, name: "Grock", role: "Tank/Fighter", lane: "Roaming"),
        NixHubHero(id: 45, name: "Argus", role: "Fighter", lane: "EXP Lane"),
        NixHubHero(id: 46, name: "Odette", role: "Mage", lane: "Mid Lane"),
        NixHubHero(id: 47, name: "Lancelot", role: "Assassin", lane: "Jungle"),
        NixHubHero(id: 48, name: "Diggie", role: "Support", lane: "Roaming"),
        NixHubHero(id: 49, name: "Hylos", role: "Tank", lane: "Roaming"),
        NixHubHero(id: 50, name: "Zhask", role: "Mage", lane: "Mid Lane"),
        NixHubHero(id: 51, name: "Helcurt", role: "Assassin", lane: "Jungle"),
        NixHubHero(id: 52, name: "Pharsa", role: "Mage", lane: "Mid Lane"),
        NixHubHero(id: 53, name: "Lesley", role: "Marksman/Assassin", lane: "Gold Lane"),
        NixHubHero(id: 54, name: "Jawhead", role: "Fighter", lane: "EXP Lane/Jungle"),
        NixHubHero(id: 55, name: "Angela", role: "Support", lane: "Roaming"),
        NixHubHero(id: 56, name: "Gusion", role: "Assassin", lane: "Jungle"),
        NixHubHero(id: 57, name: "Valir", role: "Mage", lane: "Mid Lane"),
        NixHubHero(id: 58, name: "Martis", role: "Fighter", lane: "Jungle"),
        NixHubHero(id: 59, name: "Uranus", role: "Tank", lane: "EXP Lane"),
        NixHubHero(id: 60, name: "Hanabi", role: "Marksman", lane: "Gold Lane"),
        NixHubHero(id: 61, name: "Chang'e", role: "Mage", lane: "Mid Lane"),
        NixHubHero(id: 62, name: "Kaja", role: "Support/Fighter", lane: "Roaming"),
        NixHubHero(id: 63, name: "Selena", role: "Assassin/Mage", lane: "Roaming/Mid Lane"),
        NixHubHero(id: 64, name: "Aldous", role: "Fighter", lane: "EXP Lane"),
        NixHubHero(id: 65, name: "Claude", role: "Marksman", lane: "Gold Lane"),
        NixHubHero(id: 66, name: "Vale", role: "Mage", lane: "Mid Lane"),
        NixHubHero(id: 67, name: "Leomord", role: "Fighter", lane: "Jungle"),
        NixHubHero(id: 68, name: "Lunox", role: "Mage", lane: "Mid Lane"),
        NixHubHero(id: 69, name: "Hanzo", role: "Assassin", lane: "Jungle"),
        NixHubHero(id: 70, name: "Belerick", role: "Tank", lane: "Roaming"),
        NixHubHero(id: 71, name: "Kimmy", role: "Marksman/Mage", lane: "Gold Lane"),
        NixHubHero(id: 72, name: "Thamuz", role: "Fighter", lane: "EXP Lane"),
        NixHubHero(id: 73, name: "Harith", role: "Mage", lane: "Gold Lane/Jungle"),
        NixHubHero(id: 74, name: "Minsitthar", role: "Fighter", lane: "EXP Lane/Roaming"),
        NixHubHero(id: 75, name: "Kadita", role: "Mage/Assassin", lane: "Mid Lane"),
        NixHubHero(id: 76, name: "Faramis", role: "Support/Mage", lane: "Mid Lane"),
        NixHubHero(id: 77, name: "Badang", role: "Fighter", lane: "Roaming/EXP Lane"),
        NixHubHero(id: 78, name: "Khufra", role: "Tank", lane: "Roaming"),
        NixHubHero(id: 79, name: "Granger", role: "Marksman", lane: "Jungle/Gold Lane"),
        NixHubHero(id: 80, name: "Guinevere", role: "Fighter", lane: "EXP Lane"),
        NixHubHero(id: 81, name: "Esmeralda", role: "Tank/Mage", lane: "EXP Lane"),
        NixHubHero(id: 82, name: "Terizla", role: "Fighter/Tank", lane: "EXP Lane"),
        NixHubHero(id: 83, name: "X.Borg", role: "Fighter", lane: "EXP Lane"),
        NixHubHero(id: 84, name: "Ling", role: "Assassin", lane: "Jungle"),
        NixHubHero(id: 85, name: "Dyrroth", role: "Fighter", lane: "EXP Lane/Jungle"),
        NixHubHero(id: 86, name: "Lylia", role: "Mage", lane: "Mid Lane"),
        NixHubHero(id: 87, name: "Baxia", role: "Tank", lane: "Jungle"),
        NixHubHero(id: 88, name: "Masha", role: "Fighter/Tank", lane: "EXP Lane"),
        NixHubHero(id: 89, name: "Wanwan", role: "Marksman", lane: "Gold Lane"),
        NixHubHero(id: 90, name: "Silvanna", role: "Fighter", lane: "EXP Lane"),
        NixHubHero(id: 91, name: "Cecilion", role: "Mage", lane: "Mid Lane"),
        NixHubHero(id: 92, name: "Carmilla", role: "Support/Tank", lane: "Roaming"),
        NixHubHero(id: 93, name: "Atlas", role: "Tank", lane: "Roaming"),
        NixHubHero(id: 94, name: "Popol and Kupa", role: "Marksman", lane: "Jungle/Gold Lane"),
        NixHubHero(id: 95, name: "Yu Zhong", role: "Fighter", lane: "EXP Lane"),
        NixHubHero(id: 96, name: "Luo Yi", role: "Mage", lane: "Mid Lane"),
        NixHubHero(id: 97, name: "Benedetta", role: "Assassin/Fighter", lane: "EXP Lane"),
        NixHubHero(id: 98, name: "Khaleed", role: "Fighter", lane: "EXP Lane"),
        NixHubHero(id: 99, name: "Barats", role: "Tank/Fighter", lane: "Jungle"),
        NixHubHero(id: 100, name: "Brody", role: "Marksman", lane: "Gold Lane"),
        NixHubHero(id: 101, name: "Yve", role: "Mage", lane: "Mid Lane"),
        NixHubHero(id: 102, name: "Mathilda", role: "Support/Assassin", lane: "Roaming"),
        NixHubHero(id: 103, name: "Paquito", role: "Fighter/Assassin", lane: "EXP Lane"),
        NixHubHero(id: 104, name: "Gloo", role: "Tank", lane: "Roaming/EXP Lane"),
        NixHubHero(id: 105, name: "Beatrix", role: "Marksman", lane: "Gold Lane"),
        NixHubHero(id: 106, name: "Phoveus", role: "Fighter", lane: "EXP Lane"),
        NixHubHero(id: 107, name: "Natan", role: "Marksman", lane: "Gold Lane"),
        NixHubHero(id: 108, name: "Aulus", role: "Fighter", lane: "Jungle"),
        NixHubHero(id: 109, name: "Aamon", role: "Assassin", lane: "Jungle"),
        NixHubHero(id: 110, name: "Valentina", role: "Mage", lane: "Mid Lane"),
        NixHubHero(id: 111, name: "Edith", role: "Tank/Marksman", lane: "EXP Lane/Roaming"),
        NixHubHero(id: 112, name: "Floryn", role: "Support", lane: "Roaming"),
        NixHubHero(id: 113, name: "Yin", role: "Fighter/Assassin", lane: "Jungle/EXP Lane"),
        NixHubHero(id: 114, name: "Melissa", role: "Marksman", lane: "Gold Lane"),
        NixHubHero(id: 115, name: "Xavier", role: "Mage", lane: "Mid Lane"),
        NixHubHero(id: 116, name: "Julian", role: "Assassin/Fighter", lane: "Jungle"),
        NixHubHero(id: 117, name: "Fredrinn", role: "Fighter/Tank", lane: "Jungle"),
        NixHubHero(id: 118, name: "Joy", role: "Assassin", lane: "Jungle"),
        NixHubHero(id: 119, name: "Novaria", role: "Mage", lane: "Mid Lane"),
        NixHubHero(id: 120, name: "Arlott", role: "Fighter/Assassin", lane: "EXP Lane"),
        NixHubHero(id: 121, name: "Ixia", role: "Marksman", lane: "Gold Lane"),
        NixHubHero(id: 122, name: "Nolan", role: "Assassin", lane: "Jungle"),
        NixHubHero(id: 123, name: "Cici", role: "Fighter", lane: "EXP Lane"),
        NixHubHero(id: 124, name: "Chip", role: "Support/Tank", lane: "Roaming"),
        NixHubHero(id: 125, name: "Zhuxin", role: "Mage", lane: "Mid Lane"),
        NixHubHero(id: 126, name: "Suyou", role: "Assassin/Fighter", lane: "Jungle/EXP Lane"),
        NixHubHero(id: 127, name: "Lukas", role: "Fighter", lane: "EXP Lane"),
        NixHubHero(id: 128, name: "Kalea", role: "Support/Fighter", lane: "Roaming"),
        NixHubHero(id: 129, name: "Zetian", role: "Mage", lane: "Mid Lane"),
        NixHubHero(id: 130, name: "Obsidia", role: "Marksman", lane: "Gold Lane"),
        NixHubHero(id: 131, name: "Sora", role: "Fighter/Assassin", lane: "EXP Lane"),
        NixHubHero(id: 132, name: "Marcel", role: "Support", lane: "Roaming"),
        NixHubHero(id: 133, name: "Hiara", role: "Assassin", lane: "Jungle")
    ]
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
