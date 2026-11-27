import SwiftUI
import UniformTypeIdentifiers
import UIKit

@main
struct MLBBConverterApp: App {
    var body: some Scene {
        WindowGroup { ConverterView() }
    }
}

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
                Text("MLBB iOS Converter")
                    .font(.title2.bold())
                Text("Android Unity assets → iOS")
                    .foregroundColor(.secondary)

                NavigationLink {
                    GameLookView()
                } label: {
                    Label("Game Look Editor", systemImage: "paintpalette.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Color(red: 0.82, green: 0.64, blue: 0.30))

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

        // Files and other providers can give the app a security-scoped URL whose
        // contents must be coordinated before they are copied into our container.
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
                        // Some providers return a coordinated URL that remains readable
                        // only through the original security-scoped URL.
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
                    errorMessage = "Walang file na naipasa mula sa Files. Subukan ulit gamit ang Share → MLBB Converter."
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


// MARK: - Game Look profile editor
// This first iOS implementation stores a local editable profile. It does not
// claim to inject changes into Mobile Legends' private app container.
private struct GameLookSkinRename: Identifiable, Codable {
    var id = UUID()
    var heroName = ""
    var currentSkinName = ""
    var replacementName = ""
}

private struct GameLookTagChange: Identifiable, Codable {
    var id = UUID()
    var currentTag = ""
    var replacementTag = ""
    var gemColor = ""
}

private struct GameLookProfile: Codable {
    var renameSkinsEnabled = false
    var skinRenames = [GameLookSkinRename()]

    var lobbyBannerEnabled = false
    var equippedBanner = ""
    var replacementBanner = ""

    var rankFrameEnabled = false
    var currentRank = ""
    var replacementRankFrame = ""

    var skinTagsEnabled = false
    var tagChanges = [GameLookTagChange()]

    var killNotificationEnabled = false
    var equippedKillNotification = ""
    var replacementKillNotification = ""

    private static let storageKey = "IshaConverter.GameLookProfile.v1"

    static func load() -> GameLookProfile {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let profile = try? JSONDecoder().decode(GameLookProfile.self, from: data) else {
            return GameLookProfile()
        }
        return profile
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

private struct GameLookPreview: View {
    let before: String
    let after: String

    var body: some View {
        HStack(spacing: 9) {
            VStack(spacing: 5) {
                Text("BEFORE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                Text(before.isEmpty ? "Original" : before)
                    .font(.system(size: 12, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 38)
            }
            .padding(9)
            .background(Color.white.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Color(red: 0.91, green: 0.72, blue: 0.39))

            VStack(spacing: 5) {
                Text("AFTER")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                Text(after.isEmpty ? "No change selected" : after)
                    .font(.system(size: 12, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 38)
            }
            .padding(9)
            .background(Color.white.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(8)
        .background(Color.black.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct GameLookView: View {
    @State private var profile = GameLookProfile.load()
    @State private var showResetConfirmation = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    private let gold = Color(red: 0.91, green: 0.72, blue: 0.39)

    var body: some View {
        NavigationView {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("GAME LOOK")
                            .font(.caption.weight(.bold))
                            .tracking(1.5)
                            .foregroundColor(gold)
                        Text("Customize the names and appearance choices you want to use for your MLBB setup.")
                            .font(.subheadline)
                        Text("Your selections are saved locally in Isha Converter. This editor does not yet write changes into Mobile Legends' private game files.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("2 · SKIN NAMES") {
                    Toggle("Rename skins", isOn: $profile.renameSkinsEnabled)
                    if profile.renameSkinsEnabled {
                        ForEach($profile.skinRenames) { $entry in
                            VStack(alignment: .leading, spacing: 9) {
                                TextField("Hero name", text: $entry.heroName)
                                TextField("Current skin name", text: $entry.currentSkinName)
                                TextField("Show it as", text: $entry.replacementName)
                                GameLookPreview(before: entry.currentSkinName, after: entry.replacementName)
                                HStack {
                                    Spacer()
                                    Button(role: .destructive) {
                                        let id = entry.wrappedValue.id
                                        profile.skinRenames.removeAll { $0.id == id }
                                    } label: {
                                        Label("Remove skin", systemImage: "trash")
                                            .font(.caption)
                                    }
                                }
                            }
                            .padding(.vertical, 5)
                        }
                        Button {
                            profile.skinRenames.append(GameLookSkinRename())
                        } label: {
                            Label("Add another skin", systemImage: "plus.circle.fill")
                                .foregroundColor(gold)
                        }
                    }
                }

                Section("3 · TEAM LOBBY BANNER") {
                    Toggle("Change my lobby banner", isOn: $profile.lobbyBannerEnabled)
                    if profile.lobbyBannerEnabled {
                        TextField("Banner I have equipped", text: $profile.equippedBanner)
                        TextField("Show it as", text: $profile.replacementBanner)
                        GameLookPreview(before: profile.equippedBanner, after: profile.replacementBanner)
                    }
                }

                Section("4 · RANK FRAME (LOADING SCREEN)") {
                    Toggle("Change the rank frame", isOn: $profile.rankFrameEnabled)
                    if profile.rankFrameEnabled {
                        TextField("My rank", text: $profile.currentRank)
                        TextField("Show it as", text: $profile.replacementRankFrame)
                        GameLookPreview(before: profile.currentRank, after: profile.replacementRankFrame)
                    }
                }

                Section("5 · SKIN TAGS / GEMS") {
                    Toggle("Change skin tags", isOn: $profile.skinTagsEnabled)
                    if profile.skinTagsEnabled {
                        ForEach($profile.tagChanges) { $entry in
                            VStack(alignment: .leading, spacing: 9) {
                                TextField("Choose the tag", text: $entry.currentTag)
                                TextField("Show it as", text: $entry.replacementTag)
                                TextField("Gem colour (optional)", text: $entry.gemColor)
                                GameLookPreview(before: entry.currentTag, after: entry.replacementTag)
                                HStack {
                                    Spacer()
                                    Button(role: .destructive) {
                                        let id = entry.wrappedValue.id
                                        profile.tagChanges.removeAll { $0.id == id }
                                    } label: {
                                        Label("Remove tag", systemImage: "trash")
                                            .font(.caption)
                                    }
                                }
                            }
                            .padding(.vertical, 5)
                        }
                        Button {
                            profile.tagChanges.append(GameLookTagChange())
                        } label: {
                            Label("Add another tag", systemImage: "plus.circle.fill")
                                .foregroundColor(gold)
                        }
                    }
                }

                Section("6 · KILL NOTIFICATION") {
                    Toggle("Change the kill notification", isOn: $profile.killNotificationEnabled)
                    if profile.killNotificationEnabled {
                        TextField("Notification I have equipped", text: $profile.equippedKillNotification)
                        TextField("Show it as", text: $profile.replacementKillNotification)
                        GameLookPreview(before: profile.equippedKillNotification, after: profile.replacementKillNotification)
                    }
                }

                Section {
                    Button {
                        saveProfile()
                    } label: {
                        Label("Save Game Look profile", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                            .font(.body.weight(.semibold))
                    }
                    .tint(gold)

                    Button(role: .destructive) {
                        showResetConfirmation = true
                    } label: {
                        Label("Reset profile", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                } footer: {
                    Text("Saved profiles stay on this iPhone. No .3105 patch or game-file injection is included.")
                }
            }
            .navigationTitle("Game Look")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        // The navigation stack is dismissed by the system's back action.
                    }
                    .disabled(true)
                }
            }
            .confirmationDialog("Reset the saved Game Look profile?", isPresented: $showResetConfirmation, titleVisibility: .visible) {
                Button("Reset profile", role: .destructive) {
                    GameLookProfile.reset()
                    profile = GameLookProfile()
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert(alertTitle, isPresented: $showAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
        }
        .tint(gold)
        .preferredColorScheme(.dark)
    }

    private func saveProfile() {
        do {
            try profile.save()
            alertTitle = "Profile saved"
            alertMessage = "Your Game Look selections were saved on this iPhone. They have not been applied to Mobile Legends."
        } catch {
            alertTitle = "Could not save"
            alertMessage = error.localizedDescription
        }
        showAlert = true
    }
}
