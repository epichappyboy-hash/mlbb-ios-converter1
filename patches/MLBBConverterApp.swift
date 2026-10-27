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
    @State private var showImporter = false
    @State private var showShareSheet = false
    @State private var isConverting = false
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
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip, UTType(filenameExtension: "unity3d") ?? .data], allowsMultipleSelection: false) { result in
                do {
                    guard let selected = try result.get().first else { return }
                    importFile(selected)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .alert("Hindi natuloy", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .onOpenURL { url in
            importFile(url)
        }
    }

    private func importFile(_ selected: URL) {
        let ext = selected.pathExtension.lowercased()
        guard ext == "unity3d" || ext == "zip" else {
            errorMessage = "Hindi suportado ang file na ito. Pumili ng .unity3d o .zip file."
            return
        }

        status = "Ini-import ang (selected.lastPathComponent)…"
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
                    try FileManager.default.copyItem(at: readableURL, to: destination)
                    importedURL = destination
                } catch {
                    copyError = error
                }
            }

            let failure: Error? = coordinationError ?? copyError
            DispatchQueue.main.async {
                if let failure {
                    status = "Hindi na-import ang file."
                    errorMessage = "Hindi mabasa ang file mula sa Files. (failure.localizedDescription)"
                    return
                }
                guard let importedURL else {
                    status = "Hindi na-import ang file."
                    errorMessage = "Walang file na naipasa mula sa Files. Subukan ulit gamit ang Share → MLBB Converter."
                    return
                }
                inputURL = importedURL
                outputURL = nil
                status = "Handa nang i-convert: (selected.lastPathComponent)"
            }
        }
    }

    private func convert() {
        guard let inputURL else { return }
        isConverting = true
        outputURL = nil
        status = "Binabasa ang shaders at kino-convert ang Unity bundles…"
        let outputDirectory = documents.appendingPathComponent("Converted", isDirectory: true)
        PythonConverter.shared.convert(input: inputURL, outputDirectory: outputDirectory) { result in
            DispatchQueue.main.async {
                isConverting = false
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
}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
