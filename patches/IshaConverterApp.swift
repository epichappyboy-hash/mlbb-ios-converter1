import SwiftUI
import UniformTypeIdentifiers
import UIKit

@main
struct IshaConverterApp: App {
    var body: some Scene {
        WindowGroup { IshaConverterView() }
    }
}

struct IshaConverterView: View {
    @State private var inputURL: URL?
    @State private var outputURL: URL?
    @State private var showImporter = false
    @State private var showOutputShare = false
    @State private var showLogShare = false
    @State private var isConverting = false
    @State private var createZIP = true
    @State private var fullValidation = false
    @State private var preserveShadows = true
    @State private var textureQuality = "balanced"
    @State private var status = "Pumili ng Android Unity bundle para magsimula."
    @State private var errorMessage: String?
    @State private var conversionLog = "Ready. Built-in ShaderVariants are included."

    private let background = Color(red: 0.055, green: 0.063, blue: 0.082)
    private let panel = Color(red: 0.125, green: 0.137, blue: 0.176)
    private let rowLine = Color(red: 0.19, green: 0.205, blue: 0.25)
    private let accent = Color(red: 0.22, green: 0.55, blue: 1.0)
    private let green = Color(red: 0.19, green: 0.82, blue: 0.59)

    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var shaderDirectory: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent("ios_shaders", isDirectory: true)
    }

    private var shadersReady: Bool {
        let required = [
            "ShaderVariants.unity3d",
            "ShaderVariantsInBattle.unity3d",
            "ShaderVariants_add.unity3d"
        ]
        return required.allSatisfy {
            FileManager.default.fileExists(
                atPath: shaderDirectory.appendingPathComponent($0).path
            )
        }
    }

    private var outputDirectory: URL {
        documents.appendingPathComponent("Converted", isDirectory: true)
    }

    private var supportedImportTypes: [UTType] {
        [.zip, UTType(filenameExtension: "unity3d") ?? .data]
    }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    filesCard
                    optionsCard
                    qualityCard
                    convertButton
                    statusView
                    logCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 30)
                .padding(.bottom, 34)
            }
        }
        .preferredColorScheme(.dark)
        .onOpenURL { url in
            importOpenedURL(url)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: supportedImportTypes,
            allowsMultipleSelection: false
        ) { result in
            importSelectedFile(result)
        }
        .sheet(isPresented: $showOutputShare) {
            if let outputURL {
                IshaActivityView(activityItems: [outputURL])
            }
        }
        .sheet(isPresented: $showLogShare) {
            IshaActivityView(activityItems: [diagnosticFileURL])
        }
        .alert("Hindi natuloy", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 23)
                    .fill(panel)
                    .frame(width: 78, height: 78)
                Image(systemName: "arrow.left.arrow.right.square")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundColor(accent)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Isha Converter iOS")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundColor(.white)
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
                Text("Android → iOS Unity bundle converter")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.64))
                Text("Exact ShaderVariants matching")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(green)
            }
            .padding(.top, 2)
            Spacer(minLength: 0)
        }
    }

    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeading("FILES & PATHS", icon: "folder")
            Divider().overlay(rowLine).padding(.top, 15)

            HStack(spacing: 14) {
                fileIcon("scroll", color: accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Android input")
                        .font(.system(size: 17, weight: .semibold))
                    Text(inputURL?.lastPathComponent ?? "Select a .unity3d or ZIP file")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.62))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Button("Browse") { showImporter = true }
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 17)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.38))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .disabled(isConverting)
            }
            .padding(.vertical, 18)

            Divider().overlay(rowLine)

            HStack(spacing: 14) {
                fileIcon("square.stack.3d.up", color: green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("iOS shaders")
                        .font(.system(size: 17, weight: .semibold))
                    Text(shadersReady ? "Built-in ShaderVariants · ready" : "ShaderVariants are missing")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.62))
                }
                Spacer()
                statePill(shadersReady ? "READY" : "MISSING", isGood: shadersReady)
            }
            .padding(.vertical, 18)

            Divider().overlay(rowLine)

            HStack(spacing: 14) {
                fileIcon("externaldrive", color: .white.opacity(0.65))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Output folder")
                        .font(.system(size: 17, weight: .semibold))
                    Text("App storage /…/Isha Converter iOS")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.62))
                }
                Spacer()
                statePill("ON DEVICE", isGood: false)
            }
            .padding(.vertical, 18)
        }
        .padding(20)
        .background(panel)
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 17) {
            sectionHeading("CONVERSION OPTIONS", icon: "slider.horizontal.3")
            optionRow(
                title: "Create ZIP",
                detail: "Package the converted assets into a ZIP",
                isOn: $createZIP,
                badge: createZIP ? "ON" : "OFF",
                active: createZIP
            )
            optionRow(
                title: "Full texture validation",
                detail: "Extra pixel checks; slower and uses more memory",
                isOn: $fullValidation,
                badge: fullValidation ? "FULL" : "OPTIMIZED",
                active: fullValidation
            )
            optionRow(
                title: "Preserve shadows",
                detail: "Keep shadow-related assets during conversion",
                isOn: $preserveShadows,
                badge: preserveShadows ? "ON" : "OFF",
                active: preserveShadows
            )
        }
        .padding(20)
        .background(panel)
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private var qualityCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionHeading("TEXTURE QUALITY", icon: "viewfinder")
            HStack(spacing: 9) {
                qualityButton("High", format: "ASTC 4×4", value: "high")
                qualityButton("Balanced", format: "ASTC 6×6", value: "balanced")
                qualityButton("Small", format: "ASTC 8×8", value: "small")
            }
        }
        .padding(20)
        .background(panel)
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private var convertButton: some View {
        Button(action: convert) {
            HStack(spacing: 13) {
                if isConverting {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 22, weight: .semibold))
                }
                Text(isConverting ? "CONVERTING…" : "CONVERT TO iOS")
                    .font(.system(size: 19, weight: .bold))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 20, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(inputURL == nil || !shadersReady || isConverting ? accent.opacity(0.42) : accent.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .disabled(inputURL == nil || !shadersReady || isConverting)
    }

    private var statusView: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Status")
                .font(.system(size: 16, weight: .bold))
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(isConverting ? accent : (outputURL != nil ? green : Color.white.opacity(0.65)))
                    .frame(width: 8, height: 8)
                    .padding(.top, 7)
                Text(status)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let outputURL {
                Button {
                    showOutputShare = true
                } label: {
                    Label("Save / Share converted output", systemImage: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(green.opacity(0.18))
                        .foregroundColor(green)
                        .clipShape(RoundedRectangle(cornerRadius: 13))
                }
                .padding(.top, 5)
            }
        }
        .padding(.horizontal, 5)
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeading("CONVERSION LOG", icon: "terminal")
                Spacer()
                Button {
                    refreshDiagnosticText()
                    showLogShare = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 46, height: 46)
                        .background(Color.black.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(isConverting)
            }
            Text(conversionLog)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white.opacity(0.72))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .background(Color.black.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .textSelection(.enabled)
                .lineLimit(12)
        }
        .padding(20)
        .background(panel)
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private var diagnosticFileURL: URL {
        outputDirectory.appendingPathComponent("conversion_diagnostics.log")
    }

    private func sectionHeading(_ title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(accent)
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .tracking(1.7)
                .foregroundColor(.white.opacity(0.75))
        }
    }

    private func fileIcon(_ name: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15)
                .fill(Color.black.opacity(0.43))
                .frame(width: 58, height: 58)
            Image(systemName: name)
                .font(.system(size: 23, weight: .semibold))
                .foregroundColor(color)
        }
    }

    private func statePill(_ title: String, isGood: Bool) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .tracking(1.1)
            .foregroundColor(isGood ? green : .white.opacity(0.65))
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(isGood ? green.opacity(0.15) : Color.white.opacity(0.09))
            .clipShape(Capsule())
    }

    private func optionRow(
        title: String,
        detail: String,
        isOn: Binding<Bool>,
        badge: String,
        active: Bool
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundColor(isOn.wrappedValue ? green : .white.opacity(0.55))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.62))
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 3)
                statePill(badge, isGood: active)
            }
        }
        .buttonStyle(.plain)
        .disabled(isConverting)
    }

    private func qualityButton(_ title: String, format: String, value: String) -> some View {
        let selected = textureQuality == value
        return Button {
            textureQuality = value
        } label: {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text(format)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.62))
            }
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(selected ? accent.opacity(0.18) : Color.black.opacity(0.2))
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .stroke(selected ? accent : rowLine, lineWidth: selected ? 1.7 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .disabled(isConverting)
    }

    private func importSelectedFile(_ result: Result<[URL], Error>) {
        do {
            guard let selected = try result.get().first else { return }
            importFile(from: selected)
        } catch {
            errorMessage = "Hindi mabasa ang napiling file: \(error.localizedDescription)"
        }
    }

    // Handles ZIP/Unity files sent from the iOS Files app through Open In / Share.
    private func importOpenedURL(_ url: URL) {
        guard url.isFileURL else {
            errorMessage = "Hindi valid na local file URL ang ipinasa ng Files app."
            return
        }
        importFile(from: url)
    }

    private func importFile(from selected: URL) {
        let ext = selected.pathExtension.lowercased()
        guard ext == "unity3d" || ext == "zip" else {
            errorMessage = "Hindi supported ang file na ito. Pumili ng .unity3d o .zip file."
            return
        }

        let hasScopedAccess = selected.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                selected.stopAccessingSecurityScopedResource()
            }
        }

        do {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: selected.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                throw IshaConverterError.conversionFailed("Hindi makita ang ZIP file o folder ang napili.")
            }

            let imports = documents.appendingPathComponent("Imported", isDirectory: true)
            try FileManager.default.createDirectory(
                at: imports,
                withIntermediateDirectories: true
            )
            let destination = imports.appendingPathComponent(
                UUID().uuidString + "_" + selected.lastPathComponent
            )

            // Coordinate reads from Files/iCloud providers before copying into app storage.
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var copyError: Error?
            coordinator.coordinate(
                readingItemAt: selected,
                options: .withoutChanges,
                error: &coordinationError
            ) { readableURL in
                do {
                    try FileManager.default.copyItem(at: readableURL, to: destination)
                } catch {
                    copyError = error
                }
            }

            if let coordinationError {
                throw coordinationError
            }
            if let copyError {
                throw copyError
            }
            guard FileManager.default.fileExists(atPath: destination.path) else {
                throw IshaConverterError.conversionFailed("Hindi nakopya ang file mula sa Files app.")
            }

            inputURL = destination
            outputURL = nil
            status = "Handa nang i-convert: \(selected.lastPathComponent)"
            conversionLog = "Input imported: \(selected.lastPathComponent)\nSource: Files / Document Picker\nTexture quality: \(textureQuality.uppercased())"
            errorMessage = nil
        } catch {
            status = "Hindi na-import ang file: \(error.localizedDescription)"
            errorMessage = "Hindi na-import ang file mula sa Files app. \(error.localizedDescription)"
        }
    }

    private func convert() {
        guard let inputURL else { return }
        isConverting = true
        outputURL = nil
        status = "Preparing shaders and converting Android textures to ASTC…"
        conversionLog = "Starting conversion…"
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        PythonConverter.shared.convert(
            input: inputURL,
            outputDirectory: outputDirectory,
            textureQuality: textureQuality,
            createZIP: createZIP,
            fullValidation: fullValidation,
            preserveShadows: preserveShadows
        ) { result in
            DispatchQueue.main.async {
                isConverting = false
                switch result {
                case .success(let value):
                    outputURL = value.outputURL
                    status = value.isDirectory
                        ? "Conversion complete. Output folder is saved on this device."
                        : "Conversion complete. Converted ZIP is ready to save."
                    conversionLog = value.logs.isEmpty ? "Conversion finished successfully." : value.logs.joined(separator: "\n")
                    refreshDiagnosticText()
                case .failure(let error):
                    status = "Conversion stopped. \(error.localizedDescription)"
                    conversionLog = error.localizedDescription
                    errorMessage = error.localizedDescription
                    refreshDiagnosticText()
                }
            }
        }
    }

    private func refreshDiagnosticText() {
        guard let content = try? String(contentsOf: diagnosticFileURL, encoding: .utf8) else { return }
        conversionLog = content
    }
}

struct IshaActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
