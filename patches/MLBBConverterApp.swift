import SwiftUI
import UniformTypeIdentifiers
import UIKit
import Combine
import Security

private enum IshaLicenseConfiguration {
    // Set these two values after deploying the Supabase functions.
    // The publishable key is intended for client use. NEVER put a secret/service-role key here.
    static let validationURL = "https://gbeljybcfdpgzstffrsw.supabase.co/functions/v1/validate-license"
    static let publishableKey = "sb_publishable_ENErOce9koor0imL34c4sg_3n2SjrIx"

    static var isConfigured: Bool {
        guard let url = URL(string: validationURL),
              url.scheme == "https",
              let host = url.host,
              !host.contains("YOUR_PROJECT_REF"),
              !publishableKey.contains("YOUR_SUPABASE_PUBLISHABLE_KEY"),
              publishableKey.hasPrefix("sb_publishable_") || publishableKey.count > 30 else {
            return false
        }
        return true
    }
}

private struct IshaLicenseValidationResponse: Decodable {
    let ok: Bool
    let message: String?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case message
        case expiresAt = "expires_at"
    }
}

private enum IshaLicenseServiceError: LocalizedError {
    case notConfigured
    case rejected(String)
    case connection

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "License verification is not configured yet. Add your Supabase project URL and publishable key."
        case .rejected(let message):
            return message
        case .connection:
            return "Couldn't reach the license server. Check your internet connection and try again."
        }
    }
}

private enum IshaLicenseSecureStorage {
    private static let service = Bundle.main.bundleIdentifier ?? "com.isha.converter.ios"
    private static let licenseAccount = "isha.saved-license-key"
    private static let deviceAccount = "isha.device-identifier"

    static var savedLicenseKey: String? {
        read(account: licenseAccount)
    }

    static var deviceIdentifier: String {
        if let existing = read(account: deviceAccount) {
            return existing
        }
        let generated = UUID().uuidString.lowercased()
        write(generated, account: deviceAccount)
        return generated
    }

    static func saveLicenseKey(_ key: String) {
        write(key, account: licenseAccount)
    }

    static func clearLicenseKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: licenseAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private static func write(_ value: String, account: String) {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(baseQuery as CFDictionary)
        guard let data = value.data(using: .utf8) else { return }
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }
}

private enum IshaLicenseService {
    static func validate(_ rawKey: String) async throws -> IshaLicenseValidationResponse {
        guard IshaLicenseConfiguration.isConfigured,
              let url = URL(string: IshaLicenseConfiguration.validationURL) else {
            throw IshaLicenseServiceError.notConfigured
        }

        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else {
            throw IshaLicenseServiceError.rejected("Enter your license key first.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(IshaLicenseConfiguration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "license_key": key,
            "device_id": IshaLicenseSecureStorage.deviceIdentifier,
            "device_name": "iOS device"
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw IshaLicenseServiceError.connection
        }

        guard let http = response as? HTTPURLResponse else {
            throw IshaLicenseServiceError.connection
        }
        guard let decoded = try? JSONDecoder().decode(IshaLicenseValidationResponse.self, from: data) else {
            throw IshaLicenseServiceError.rejected("The license server returned an unreadable response.")
        }
        guard (200..<300).contains(http.statusCode), decoded.ok else {
            throw IshaLicenseServiceError.rejected(decoded.message ?? "This license key is invalid, expired, or revoked.")
        }
        return decoded
    }
}

@main
struct MLBBConverterApp: App {
    var body: some Scene {
        WindowGroup { IshaAppRootView() }
    }
}

private struct IshaAppRootView: View {
    @State private var hasContinuedToConverter = false
    @State private var didCheckSavedLicense = false
    @State private var pendingOpenURL: URL?

    var body: some View {
        Group {
            if hasContinuedToConverter {
                ConverterView(initialURL: pendingOpenURL)
            } else if !didCheckSavedLicense {
                IshaLicenseLoadingView()
            } else {
                IshaLicenseActivationView {
                    hasContinuedToConverter = true
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await checkSavedLicense()
        }
        .onOpenURL { url in
            if !hasContinuedToConverter {
                pendingOpenURL = url
            }
        }
    }

    @MainActor
    private func checkSavedLicense() async {
        guard !didCheckSavedLicense else { return }
        if let savedKey = IshaLicenseSecureStorage.savedLicenseKey {
            do {
                let result = try await IshaLicenseService.validate(savedKey)
                if result.ok {
                    hasContinuedToConverter = true
                } else {
                    IshaLicenseSecureStorage.clearLicenseKey()
                }
            } catch {
                // Fail closed: if the server cannot confirm a saved license, do not unlock the app.
                IshaLicenseSecureStorage.clearLicenseKey()
            }
        }
        didCheckSavedLicense = true
    }
}

private struct IshaLicenseLoadingView: View {
    var body: some View {
        ZStack {
            ConverterPalette.background.ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().tint(ConverterPalette.blue)
                Text("Checking license…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(ConverterPalette.muted)
            }
        }
    }
}

private struct IshaLicenseActivationView: View {
    let onContinue: () -> Void

    @State private var licenseKey = ""
    @State private var activationMessage = IshaLicenseConfiguration.isConfigured
        ? "Enter your license key to activate this device."
        : "License server setup is required before keys can be verified."
    @State private var messageIsError = false
    @State private var isValidating = false
    @State private var isLicenseActive = false
    @FocusState private var keyFieldFocused: Bool

    private let background = ConverterPalette.background
    private let panel = ConverterPalette.panel
    private let muted = ConverterPalette.muted
    private let blue = ConverterPalette.blue
    private let green = ConverterPalette.green

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    heroCard
                    activationCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 28)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var heroCard: some View {
        VStack(spacing: 15) {
            ZStack {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(ConverterPalette.field)
                    .frame(width: 150, height: 150)
                    .overlay(
                        RoundedRectangle(cornerRadius: 34, style: .continuous)
                            .stroke(ConverterPalette.blue.opacity(0.55), lineWidth: 2)
                    )
                    .shadow(color: ConverterPalette.blue.opacity(0.20), radius: 18, y: 7)

                Image(systemName: "arrow.left.arrow.right.square")
                    .font(.system(size: 76, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [ConverterPalette.blue, ConverterPalette.green],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .frame(height: 164)
            .accessibilityHidden(true)

            Text("Isha Converter iOS")
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundColor(ConverterPalette.text)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            Text("Android → iOS Unity bundle converter")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(ConverterPalette.muted)
                .multilineTextAlignment(.center)

            Text("Exact ShaderVariants matching")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(ConverterPalette.green)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 25)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 315)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [ConverterPalette.panel, ConverterPalette.field],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(ConverterPalette.muted.opacity(0.16), lineWidth: 1)
        )
    }

    private var activationCard: some View {
        VStack(spacing: 17) {
            Text("Activate your license")
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.top, 4)

            Text("Enter the key you received")
                .font(.system(size: 16))
                .foregroundColor(muted)
                .multilineTextAlignment(.center)

            TextField("ISHA-LICENSE-XXXX-XXXX", text: $licenseKey)
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .focused($keyFieldFocused)
                .padding(.horizontal, 17)
                .frame(height: 60)
                .background(ConverterPalette.field)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(ConverterPalette.muted.opacity(0.20), lineWidth: 1)
                )
                .accessibilityLabel("License key")

            Button {
                keyFieldFocused = false
                Task { await activateLicense() }
            } label: {
                Text(isValidating ? "VERIFYING…" : "ACTIVATE")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .tracking(0.4)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 65)
                    .background(
                        LinearGradient(
                            colors: [ConverterPalette.blue, ConverterPalette.blue.opacity(0.78)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: blue.opacity(0.20), radius: 10, y: 5)
            }
            .buttonStyle(.plain)
            .disabled(isValidating || licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(isValidating || licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.72 : 1)

            Text(activationMessage)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(messageIsError ? ConverterPalette.red : muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            HStack(spacing: 8) {
                Circle().fill(isLicenseActive ? green : blue).frame(width: 7, height: 7)
                Text(isLicenseActive
                    ? "LICENSE ACTIVE ON THIS DEVICE"
                    : (IshaLicenseConfiguration.isConfigured ? "KEY VERIFICATION REQUIRED" : "LICENSE SERVER NOT CONFIGURED"))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .foregroundColor(isLicenseActive ? green : blue.opacity(0.95))
            }
            .padding(.top, -3)

            Button(action: onContinue) {
                Text("Continue to converter")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .frame(minHeight: 52)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [ConverterPalette.blue, ConverterPalette.blue.opacity(0.78)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )
            }
            .buttonStyle(.plain)
            .disabled(!isLicenseActive || isValidating)
            .opacity(!isLicenseActive || isValidating ? 0.48 : 1)
            .padding(.top, 1)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(ConverterPalette.muted.opacity(0.16), lineWidth: 1.2)
        )
    }

    @MainActor
    private func activateLicense() async {
        guard !isValidating else { return }
        let normalizedKey = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalizedKey.isEmpty else {
            activationMessage = "Enter your license key first."
            messageIsError = true
            isLicenseActive = false
            return
        }

        isValidating = true
        messageIsError = false
        activationMessage = "Contacting license server…"
        defer { isValidating = false }

        do {
            let result = try await IshaLicenseService.validate(normalizedKey)
            IshaLicenseSecureStorage.saveLicenseKey(normalizedKey)
            isLicenseActive = true
            messageIsError = false
            activationMessage = result.message ?? "License active on this device."
        } catch {
            IshaLicenseSecureStorage.clearLicenseKey()
            isLicenseActive = false
            messageIsError = true
            activationMessage = error.localizedDescription
        }
    }


}

private enum ConverterPalette {
    static let background = Color(red: 23.0 / 255.0, green: 26.0 / 255.0, blue: 33.0 / 255.0)
    static let panel = Color(red: 34.0 / 255.0, green: 38.0 / 255.0, blue: 49.0 / 255.0)
    static let field = Color(red: 17.0 / 255.0, green: 20.0 / 255.0, blue: 26.0 / 255.0)
    static let text = Color(red: 238.0 / 255.0, green: 241.0 / 255.0, blue: 247.0 / 255.0)
    static let muted = Color(red: 170.0 / 255.0, green: 178.0 / 255.0, blue: 192.0 / 255.0)
    static let blue = Color(red: 75.0 / 255.0, green: 140.0 / 255.0, blue: 255.0 / 255.0)
    static let green = Color(red: 61.0 / 255.0, green: 220.0 / 255.0, blue: 151.0 / 255.0)
    static let red = Color(red: 255.0 / 255.0, green: 107.0 / 255.0, blue: 107.0 / 255.0)
}

struct ConverterView: View {
    private let initialURL: URL?
    @State private var didImportInitialURL = false
    @State private var inputURL: URL?
    @State private var outputURL: URL?

    init(initialURL: URL? = nil) {
        self.initialURL = initialURL
    }
    @State private var showImporter = false
    @State private var showShareSheet = false
    @State private var isConverting = false
    @State private var diagnosticsAvailable = false
    @State private var showDiagnostics = false
    @State private var status = "Ready"
    @State private var diagnosticText = "Converter logs will appear here."
    @State private var errorMessage: String?

    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var body: some View {
        NavigationView {
            ZStack {
                ConverterPalette.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        scriptSkinCatalogEntry
                        pathsPanel
                        optionsPanel
                        convertButton
                        statusPanel
                        logPanel
                        outputActions
                        footer
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationBarHidden(true)
            .alert("Conversion failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .preferredColorScheme(.dark)
        .onOpenURL { url in
            importFile(url)
        }
        .onAppear {
            refreshDiagnostics()
            if let log = try? String(contentsOf: diagnosticsFile, encoding: .utf8),
               log.contains("=== CONVERSION STARTED ==="),
               !log.contains("=== RESULT: SUCCESS ==="),
               !log.contains("=== RESULT: ERROR ===") {
                let lastLine = log.split(separator: "\n").last.map(String.init) ?? "No last progress message."
                status = "Previous conversion stopped. Last detail: \(lastLine)"
            }
            if let initialURL, !didImportInitialURL {
                didImportInitialURL = true
                importFile(initialURL)
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if isConverting { refreshDiagnostics() }
        }
        .sheet(isPresented: $showImporter) {
            AssetDocumentPicker { selected in
                importFile(selected)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "arrow.left.arrow.right.square")
                .font(.system(size: 27, weight: .semibold))
                .foregroundColor(ConverterPalette.blue)
                .frame(width: 58, height: 58)
                .background(ConverterPalette.panel)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("Isha Converter iOS")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundColor(ConverterPalette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Android → iOS Unity bundle converter")
                    .font(.system(size: 13))
                    .foregroundColor(ConverterPalette.muted)
                Text("Exact ShaderVariants matching")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(ConverterPalette.green)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
    }

    private var scriptSkinCatalogEntry: some View {
        NavigationLink(destination: IshaScriptSkinCatalogView()) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(ConverterPalette.green)
                    .frame(width: 42, height: 42)
                    .background(ConverterPalette.field)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("SCRIPT SKIN DOWNLOADS")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(ConverterPalette.text)
                    Text("Browse and download hero skin archives")
                        .font(.system(size: 11))
                        .foregroundColor(ConverterPalette.muted)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(ConverterPalette.muted)
            }
            .padding(14)
            .background(ConverterPalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(ConverterPalette.green.opacity(0.28), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var pathsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeading("FILES & PATHS", icon: "folder")
            Divider().overlay(ConverterPalette.field).padding(.vertical, 12)

            HStack(spacing: 12) {
                pathIcon("doc.zipper", color: ConverterPalette.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Android input")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(ConverterPalette.text)
                    Text(inputURL?.lastPathComponent ?? "Select a .unity3d bundle or ZIP file")
                        .font(.system(size: 12))
                        .foregroundColor(inputURL == nil ? ConverterPalette.muted : ConverterPalette.text)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Button {
                    showImporter = true
                } label: {
                    Text(inputURL == nil ? "Browse" : "Change")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(ConverterPalette.text)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(ConverterPalette.field)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .disabled(isConverting)
            }
            .padding(.vertical, 6)

            Divider().overlay(ConverterPalette.field).padding(.vertical, 10)

            HStack(spacing: 12) {
                pathIcon("square.stack.3d.up", color: ConverterPalette.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("iOS shaders")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(ConverterPalette.text)
                    Text("Built-in ShaderVariants · ready")
                        .font(.system(size: 12))
                        .foregroundColor(ConverterPalette.muted)
                }
                Spacer()
                statePill("READY", color: ConverterPalette.green)
            }
            .padding(.vertical, 6)

            Divider().overlay(ConverterPalette.field).padding(.vertical, 10)

            HStack(spacing: 12) {
                pathIcon("externaldrive", color: ConverterPalette.muted)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Output folder")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(ConverterPalette.text)
                    Text(outputURL?.deletingLastPathComponent().lastPathComponent ?? "App storage / Isha Converter iOS")
                        .font(.system(size: 12))
                        .foregroundColor(ConverterPalette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                statePill("ON DEVICE", color: ConverterPalette.muted)
            }
            .padding(.vertical, 6)
        }
        .padding(16)
        .background(ConverterPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private var optionsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("CONVERSION OPTIONS", icon: "slider.horizontal.3")
            settingRow(
                title: "Create ZIP",
                subtitle: "Package the converted assets into a ZIP",
                enabled: true
            )
            settingRow(
                title: "Full texture validation",
                subtitle: "Reduced for iPhone memory safety",
                enabled: false,
                badge: "OPTIMIZED"
            )
            settingRow(
                title: "Preserve shadows",
                subtitle: "Keep shadow-related assets during conversion",
                enabled: true
            )
        }
        .padding(16)
        .background(ConverterPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private var convertButton: some View {
        Button(action: convert) {
            HStack(spacing: 10) {
                if isConverting {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 16, weight: .bold))
                }
                Text(isConverting ? "CONVERTING TO iOS…" : "CONVERT TO iOS")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                if !isConverting {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 13, weight: .bold))
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(inputURL == nil || isConverting ? ConverterPalette.blue.opacity(0.45) : ConverterPalette.blue)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(inputURL == nil || isConverting)
    }

    private var statusPanel: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isConverting ? ConverterPalette.blue : (outputURL != nil ? ConverterPalette.green : ConverterPalette.muted))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(isConverting ? "Working" : (outputURL != nil ? "Complete" : "Status"))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(ConverterPalette.text)
                Text(status)
                    .font(.system(size: 12))
                    .foregroundColor(ConverterPalette.muted)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if isConverting {
                ProgressView()
                    .tint(ConverterPalette.green)
                    .scaleEffect(0.9)
            }
        }
        .padding(.horizontal, 4)
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeading("CONVERSION LOG", icon: "terminal")
                Spacer()
                if diagnosticsAvailable {
                    Button {
                        showDiagnostics = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(ConverterPalette.muted)
                            .frame(width: 34, height: 32)
                            .background(ConverterPalette.field)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .sheet(isPresented: $showDiagnostics) {
                        ActivityView(activityItems: [diagnosticsFile])
                    }
                    .accessibilityLabel("Share diagnostic log")
                }
            }

            ScrollView {
                Text(diagnosticText)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(ConverterPalette.text.opacity(0.88))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(minHeight: 145, maxHeight: 220)
            .background(ConverterPalette.field)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(16)
        .background(ConverterPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    @ViewBuilder
    private var outputActions: some View {
        if let outputURL {
            Button {
                showShareSheet = true
            } label: {
                Label("Save / Share Output ZIP", systemImage: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(ConverterPalette.text)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(ConverterPalette.field)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showShareSheet) {
                ActivityView(activityItems: [outputURL])
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("ISHA CONVERTER IOS")
            Spacer()
            Text("iOS • Memory-optimized")
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundColor(ConverterPalette.muted.opacity(0.8))
        .padding(.top, 2)
    }

    private func sectionHeading(_ title: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(ConverterPalette.blue)
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundColor(ConverterPalette.muted)
        }
    }

    private func pathIcon(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(color)
            .frame(width: 38, height: 38)
            .background(ConverterPalette.field)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func statePill(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(0.4)
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private func settingRow(title: String, subtitle: String, enabled: Bool, badge: String? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: enabled ? "checkmark.square.fill" : "checkmark.square")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(enabled ? ConverterPalette.green : ConverterPalette.muted)
                .frame(width: 23)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ConverterPalette.text)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(ConverterPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let badge {
                statePill(badge, color: ConverterPalette.blue)
            } else if enabled {
                statePill("ON", color: ConverterPalette.green)
            }
        }
    }

    private func importFile(_ selected: URL) {
        let ext = selected.pathExtension.lowercased()
        guard ext == "unity3d" || ext == "zip" else {
            errorMessage = "Unsupported file. Select a .unity3d bundle or .zip file."
            return
        }

        status = "Importing \(selected.lastPathComponent)…"
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
                    status = "Could not import file."
                    errorMessage = "Unable to read file from Files. \(failure.localizedDescription)"
                    return
                }
                guard let importedURL else {
                    status = "Could not import file."
                    errorMessage = "No file was imported. Try Share → Isha Converter iOS from the Files app."
                    return
                }
                inputURL = importedURL
                outputURL = nil
                status = "Ready to convert: \(selected.lastPathComponent)"
            }
        }
    }

    private func convert() {
        // Ignore rapid repeat taps before SwiftUI refreshes the disabled button.
        guard !isConverting, let inputURL else { return }
        isConverting = true
        outputURL = nil
        status = "Preparing shaders and converting Unity bundles…"
        let outputDirectory = documents.appendingPathComponent("Isha Converter iOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let started = "=== CONVERSION STARTED ===\n\(Date().formatted())\nInput: \(inputURL.lastPathComponent)\n"
        try? started.write(to: diagnosticsFile, atomically: true, encoding: .utf8)
        diagnosticText = started
        diagnosticsAvailable = true

        PythonConverter.shared.convert(input: inputURL, outputDirectory: outputDirectory) { result in
            DispatchQueue.main.async {
                isConverting = false
                refreshDiagnostics()
                switch result {
                case .success(let url):
                    outputURL = url
                    status = "Complete. Save or share the converted ZIP."
                case .failure(let error):
                    status = "Conversion failed."
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func refreshDiagnostics() {
        diagnosticsAvailable = FileManager.default.fileExists(atPath: diagnosticsFile.path)
        if let log = try? String(contentsOf: diagnosticsFile, encoding: .utf8), !log.isEmpty {
            diagnosticText = log
        }
    }

    private var diagnosticsFile: URL {
        documents.appendingPathComponent("Isha Converter iOS", isDirectory: true)
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


// MARK: - ISHA Script Skin Catalog
// Script skin catalog; saved archives are passed through the existing iOS converter.
private struct IshaScriptSkinCatalogView: View {
    @Environment(\.presentationMode) private var presentationMode
    @AppStorage("isha.catalog.download.history") private var historyJSON = "[]"
    @AppStorage("isha.catalog.skin.tag.assignments.v1") private var skinTagAssignmentsJSON = "{}"
    @AppStorage("isha.gameLook.skinTags.enabled") private var gameLookSkinTagsEnabled = true
    @AppStorage("isha.gameLook.skinTags.rules.v1") private var gameLookSkinTagRulesJSON = "[]"

    @State private var activeCatalogSheet: IshaCatalogSheet?
    @State private var heroes: [IshaCatalogHero] = []
    @State private var tagLibraryCache: [IshaCatalogTag] = []
    @State private var tagByIDCache: [String: IshaCatalogTag] = [:]
    @State private var tagByCanonicalIDCache: [String: IshaCatalogTag] = [:]
    @State private var assignmentsCache: [String: [String]] = [:]
    @State private var availableTagsCache: [String] = ["All"]
    @State private var visibleGroupsCache: [IshaCatalogHeroGroup] = []
    @State private var appliedSearchText = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var selectedRole = "All"
    @State private var selectedTag = "All"
    @State private var featuredOnly = false
    @State private var downloadingIDs: Set<String> = []
    @State private var convertingIDs: Set<String> = []
    @State private var isProcessingDownload = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    private let catalogURL = URL(string: "https://raw.githubusercontent.com/missnapokita/masterkiter/refs/heads/main/skins.json")!
    private let roles = ["All", "Assassin", "Fighter", "Mage", "Marksman", "Tank", "Support"]

    private var recentDownloads: [String] {
        guard let data = historyJSON.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return values
    }

    private var downloadableCount: Int {
        heroes.reduce(0) { result, hero in
            guard hero.enabled != false else { return result }
            return result + hero.skins.filter { $0.enabled != false && validDownloadURL($0.script) }.count
        }
    }

    private var featuredCount: Int {
        heroes.reduce(0) { result, hero in
            result + hero.skins.filter { $0.enabled != false && $0.featured == true && validDownloadURL($0.script) }.count
        }
    }

    private var tagLibrary: [IshaCatalogTag] {
        tagLibraryCache
    }

    private var gameLookSkinTagRules: [IshaSkinTagReplacementRule] {
        guard let data = gameLookSkinTagRulesJSON.data(using: .utf8),
              let rules = try? JSONDecoder().decode([IshaSkinTagReplacementRule].self, from: data) else {
            return []
        }
        return rules
    }

    private var availableTags: [String] {
        availableTagsCache
    }

    private var visibleGroups: [IshaCatalogHeroGroup] {
        visibleGroupsCache
    }

    private var visibleCount: Int {
        visibleGroupsCache.reduce(0) { $0 + $1.skins.count }
    }

    private func selectedTagIDs(for skin: IshaCatalogSkin) -> Set<String> {
        Set(assignmentsCache[skin.stableID] ?? [])
    }

    private func assignedTagNames(for skin: IshaCatalogSkin) -> [String] {
        (assignmentsCache[skin.stableID] ?? []).compactMap { tagByIDCache[$0]?.canonicalName }
    }

    @MainActor
    private func rebuildCatalogCaches(for catalog: [IshaCatalogHero]) {
        let heroNames = Set(catalog.map { ishaSkinTagKey($0.name) })
        let genericNames: Set<String> = ["assassin", "fighter", "mage", "marksman", "tank", "support", "basic", "backup", "default", "uncategorized", "featured"]
        var unique: [String: IshaCatalogTag] = [:]
        var sourceRecords: [IshaCatalogTag] = []

        for hero in catalog {
            for skin in hero.skins {
                for tag in skin.tags ?? [] {
                    let name = tag.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let key = ishaSkinTagKey(name)
                    let canonicalID = tag.canonicalID
                    let skinNameKey = ishaSkinTagKey(skin.skin_name ?? "")
                    guard !name.isEmpty,
                          !heroNames.contains(key),
                          !genericNames.contains(key),
                          !genericNames.contains(canonicalID),
                          key != skinNameKey else { continue }

                    sourceRecords.append(tag)
                    if let existing = unique[canonicalID] {
                        let hasIcon = !(existing.icon ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        let currentHasIcon = !(tag.icon ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        let existingHasCanonicalName = existing.name.caseInsensitiveCompare(existing.canonicalName) == .orderedSame
                        let currentHasCanonicalName = tag.name.caseInsensitiveCompare(tag.canonicalName) == .orderedSame
                        if (currentHasCanonicalName && !existingHasCanonicalName) || (!hasIcon && currentHasIcon) {
                            unique[canonicalID] = tag
                        }
                    } else {
                        unique[canonicalID] = tag
                    }
                }
            }
        }

        let library = unique.values.sorted {
            $0.canonicalName.localizedCaseInsensitiveCompare($1.canonicalName) == .orderedAscending
        }
        tagLibraryCache = library

        let canonicalLookup = Dictionary(uniqueKeysWithValues: library.map { ($0.canonicalID, $0) })
        tagByCanonicalIDCache = canonicalLookup

        // Map old name-derived assignment IDs as well as new canonical IDs.
        var legacyLookup: [String: IshaCatalogTag] = [:]
        for sourceTag in sourceRecords {
            if let canonical = canonicalLookup[sourceTag.canonicalID] {
                legacyLookup[sourceTag.stableID] = canonical
            }
        }
        for tag in library {
            legacyLookup[tag.stableID] = tag
            legacyLookup[tag.canonicalID] = tag
        }
        tagByIDCache = legacyLookup

        if let data = skinTagAssignmentsJSON.data(using: .utf8),
           let saved = try? JSONDecoder().decode([String: [String]].self, from: data) {
            assignmentsCache = saved
        } else {
            assignmentsCache = [:]
        }

        rebuildAvailableTags(for: catalog)
    }

    @MainActor
    private func rebuildAvailableTags(for catalog: [IshaCatalogHero]? = nil) {
        let source = catalog ?? heroes
        var values = Set<String>()
        for hero in source where hero.enabled != false {
            for skin in hero.skins where skin.enabled != false {
                for value in skin.searchTags(heroName: hero.name, category: hero.category) {
                    values.insert(value)
                }
                for id in assignmentsCache[skin.stableID] ?? [] {
                    if let name = tagByIDCache[id]?.canonicalName { values.insert(name) }
                }
            }
        }
        for tag in tagLibraryCache { values.insert(tag.canonicalName) }
        availableTagsCache = ["All"] + values.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    @MainActor
    private func rebuildVisibleGroups() {
        let query = appliedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleGroupsCache = heroes.compactMap { hero in
            guard hero.enabled != false else { return nil }
            if selectedRole != "All",
               hero.category?.caseInsensitiveCompare(selectedRole) != .orderedSame {
                return nil
            }

            let matchingSkins = hero.skins.filter { skin in
                guard skin.enabled != false, validDownloadURL(skin.script) else { return false }
                if featuredOnly && skin.featured != true { return false }

                let tags = skin.searchTags(heroName: hero.name, category: hero.category)
                    + assignedTagNames(for: skin)
                    + visibleSkinTags(for: skin, heroName: hero.name, category: hero.category).map { $0.canonicalName }
                if selectedTag != "All" &&
                    !tags.contains(where: { $0.caseInsensitiveCompare(selectedTag) == .orderedSame }) {
                    return false
                }

                guard !query.isEmpty else { return true }
                let searchable = [
                    hero.name,
                    skin.skin_name ?? "",
                    hero.category ?? "",
                    tags.joined(separator: " ")
                ].joined(separator: " ")
                return searchable.localizedCaseInsensitiveContains(query)
            }

            guard !matchingSkins.isEmpty else { return nil }
            return IshaCatalogHeroGroup(hero: hero, skins: matchingSkins)
        }
    }

    @MainActor
    private func saveTagAssignments(_ ids: [String], for skin: IshaCatalogSkin) {
        var values = assignmentsCache
        let cleaned = Array(Set(ids)).sorted()
        if cleaned.isEmpty { values.removeValue(forKey: skin.stableID) }
        else { values[skin.stableID] = cleaned }
        assignmentsCache = values

        if let data = try? JSONEncoder().encode(values),
           let json = String(data: data, encoding: .utf8) {
            skinTagAssignmentsJSON = json
        }

        rebuildAvailableTags()
        rebuildVisibleGroups()
    }

    private func visibleSkinTags(for skin: IshaCatalogSkin, heroName: String, category: String?) -> [IshaCatalogTag] {
        let heroKey = ishaSkinTagKey(heroName)
        let categoryKey = ishaSkinTagKey(category ?? "")
        let skinNameKey = ishaSkinTagKey(skin.skin_name ?? "")
        let genericNames: Set<String> = ["assassin", "fighter", "mage", "marksman", "tank", "support", "basic", "backup", "default", "uncategorized", "featured"]
        var result: [IshaCatalogTag] = []

        func appendRealTag(_ rawTag: IshaCatalogTag) {
            // Some source rows put the skin title in name, but the id is the real series (e.g. Heart Afloat -> Valentine).
            let canonical = tagByCanonicalIDCache[rawTag.canonicalID] ?? tagByIDCache[rawTag.stableID] ?? rawTag
            let cleanedName = canonical.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = ishaSkinTagKey(cleanedName)
            let identity = canonical.canonicalID
            guard !key.isEmpty,
                  key != heroKey,
                  key != categoryKey,
                  key != skinNameKey,
                  !genericNames.contains(key),
                  !genericNames.contains(identity) else { return }

            let rawIcon = rawTag.icon?.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonicalIcon = canonical.icon?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawFile = rawTag.file?.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonicalFile = canonical.file?.trimmingCharacters(in: .whitespacesAndNewlines)
            let original = IshaCatalogTag(
                tagID: canonical.tagID ?? rawTag.tagID,
                name: canonical.canonicalName,
                icon: (rawIcon?.isEmpty == false) ? rawIcon : canonicalIcon,
                file: (rawFile?.isEmpty == false) ? rawFile : canonicalFile,
                description: rawTag.description ?? canonical.description
            )

            // Replace the source tag globally for every catalog skin carrying it.
            let displayed: IshaCatalogTag
            if gameLookSkinTagsEnabled,
               let rule = gameLookSkinTagRules.first(where: { $0.sourceTagID == identity }),
               !rule.displayTagID.isEmpty,
               let replacement = tagByCanonicalIDCache[rule.displayTagID] {
                displayed = IshaCatalogTag(
                    tagID: replacement.tagID ?? replacement.canonicalID,
                    name: replacement.canonicalName,
                    icon: replacement.icon,
                    file: replacement.file,
                    description: replacement.description
                )
            } else {
                displayed = original
            }

            guard !result.contains(where: { $0.canonicalID == displayed.canonicalID }) else { return }
            result.append(displayed)
        }

        for tag in skin.tags ?? [] {
            appendRealTag(tag)
        }
        for tagID in assignmentsCache[skin.stableID] ?? [] {
            if let tag = tagByIDCache[tagID] {
                appendRealTag(tag)
            }
        }
        return result
    }

    var body: some View {
        ZStack {
            ConverterPalette.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 17) {
                    topBar
                    heroBanner
                    searchPanel
                    roleFilters

                    if !searchText.isEmpty || selectedRole != "All" || selectedTag != "All" || featuredOnly {
                        HStack {
                            Text("FILTERED RESULTS")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundColor(ConverterPalette.muted)
                            Spacer()
                            Text("\(visibleCount) SKINS")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundColor(ConverterPalette.green)
                        }
                    } else {
                        HStack {
                            Text("BROWSE ALL HEROES")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundColor(ConverterPalette.muted)
                            Spacer()
                            Text("\(heroes.count) HEROES")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundColor(ConverterPalette.muted)
                        }
                    }

                    if isLoading && heroes.isEmpty {
                        loadingState
                    } else if let errorMessage, heroes.isEmpty {
                        errorState(errorMessage)
                    } else if visibleGroups.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(alignment: .leading, spacing: 13) {
                            ForEach(visibleGroups) { group in
                                heroSection(group)
                            }
                        }
                    }

                    footer
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 34)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await loadCatalog() }
        }
        .navigationBarHidden(true)
        .preferredColorScheme(.dark)
        .task {
            if heroes.isEmpty { await loadCatalog() }
        }
        .onChange(of: searchText) { newValue in
            searchDebounceTask?.cancel()
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 220_000_000)
                guard !Task.isCancelled else { return }
                appliedSearchText = newValue
                rebuildVisibleGroups()
            }
        }
        .onChange(of: selectedRole) { _ in rebuildVisibleGroups() }
        .onChange(of: selectedTag) { _ in rebuildVisibleGroups() }
        .onChange(of: featuredOnly) { _ in rebuildVisibleGroups() }
        .onChange(of: gameLookSkinTagRulesJSON) { _ in rebuildVisibleGroups() }
        .onChange(of: gameLookSkinTagsEnabled) { _ in rebuildVisibleGroups() }
        .onDisappear { searchDebounceTask?.cancel() }
        .alert("Download failed", isPresented: Binding(
            get: { errorMessage != nil && !heroes.isEmpty },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .alert("ISHA Converter", isPresented: Binding(
            get: { statusMessage != nil },
            set: { if !$0 { statusMessage = nil } }
        )) {
            Button("OK", role: .cancel) { statusMessage = nil }
        } message: {
            Text(statusMessage ?? "")
        }
        .sheet(item: $activeCatalogSheet) { route in
            switch route {
            case .tagEditor(let target):
                IshaSkinTagPickerView(
                    skinName: target.skin.skin_name ?? "Custom Skin",
                    heroName: target.heroName,
                    tags: tagLibrary,
                    initialSelection: selectedTagIDs(for: target.skin).union(
                        Set(visibleSkinTags(for: target.skin, heroName: target.heroName, category: target.category).map { $0.stableID })
                    ),
                    onCancel: { activeCatalogSheet = nil },
                    onSave: { ids in
                        saveTagAssignments(ids, for: target.skin)
                        activeCatalogSheet = nil
                    }
                )
            case .tagInfo(let target):
                IshaSkinTagInfoSheet(
                    tag: target.tag,
                    heroName: target.heroName,
                    skinName: target.skinName,
                    skinImage: target.skinImage
                )
            case .skinTagSettings:
                IshaGameLookSkinTagsView(tags: tagLibrary)
            case .multiReplace:
                IshaMultiReplaceLibraryView()
            case .share(let url):
                ActivityView(activityItems: [url])
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                presentationMode.wrappedValue.dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(ConverterPalette.text)
                    .frame(width: 42, height: 42)
                    .background(ConverterPalette.panel)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("ISHA CONVERTER")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundColor(ConverterPalette.text)
                Text("SCRIPT SKIN LIBRARY")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(ConverterPalette.muted)
            }

            Spacer()

            Button {
                activeCatalogSheet = .multiReplace
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("MULTI")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                }
                .foregroundColor(ConverterPalette.green)
                .padding(.horizontal, 9)
                .frame(height: 38)
                .background(ConverterPalette.green.opacity(0.10))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                activeCatalogSheet = .skinTagSettings
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "tag.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("LOOK")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                }
                .foregroundColor(Color(red: 0.91, green: 0.70, blue: 0.34))
                .padding(.horizontal, 9)
                .frame(height: 38)
                .background(Color(red: 0.91, green: 0.70, blue: 0.34).opacity(0.10))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                Task { await loadCatalog() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(ConverterPalette.blue)
                    .frame(width: 42, height: 42)
                    .background(ConverterPalette.panel)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
        }
    }

    private var heroBanner: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(ConverterPalette.green).frame(width: 6, height: 6)
                    Text("LIVE SKIN CATALOG")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(ConverterPalette.green)
                }
                Spacer()
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Find your next")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("favorite skin.")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundColor(ConverterPalette.green)
                Text("Browse, search, tag and save script-skin archives.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 0) {
                metric(value: "\(downloadableCount)", label: "DOWNLOADS")
                Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 30)
                metric(value: "\(heroes.count)", label: "HEROES")
                Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 30)
                metric(value: "\(recentDownloads.count)", label: "SAVED")
            }
            .padding(.top, 2)
        }
        .padding(19)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.24, blue: 0.38),
                    Color(red: 0.10, green: 0.18, blue: 0.28),
                    ConverterPalette.panel
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(ConverterPalette.blue.opacity(0.35), lineWidth: 1)
        )
    }

    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.60))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var searchPanel: some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(ConverterPalette.blue)

            TextField("Search hero, skin name or tag…", text: $searchText)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(ConverterPalette.text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(ConverterPalette.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 52)
        .background(ConverterPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(ConverterPalette.blue.opacity(0.28), lineWidth: 1)
        )
    }

    private var roleFilters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HERO ROLE")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(ConverterPalette.muted)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(roles, id: \.self) { role in
                        filterChip(role, selected: selectedRole == role) {
                            selectedRole = role
                            selectedTag = "All"
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    featuredOnly.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: featuredOnly ? "star.fill" : "star")
                        Text("Featured")
                        Text("\(featuredCount)")
                            .opacity(0.7)
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(featuredOnly ? ConverterPalette.background : ConverterPalette.text)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(featuredOnly ? ConverterPalette.green : ConverterPalette.panel)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                if selectedTag != "All" {
                    Button {
                        selectedTag = "All"
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "tag.fill")
                            Text(selectedTag)
                            Image(systemName: "xmark")
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(ConverterPalette.blue)
                        .padding(.horizontal, 11)
                        .frame(height: 34)
                        .background(ConverterPalette.blue.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            if availableTags.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(availableTags.prefix(45), id: \.self) { tag in
                            Button {
                                selectedTag = tag
                            } label: {
                                Text(tag == "All" ? "All tags" : "#\(tag)")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(selectedTag == tag ? .white : ConverterPalette.muted)
                                    .padding(.horizontal, 9)
                                    .frame(height: 27)
                                    .background(selectedTag == tag ? ConverterPalette.blue.opacity(0.35) : ConverterPalette.panel)
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(
                                        selectedTag == tag ? ConverterPalette.blue.opacity(0.65) : .clear,
                                        lineWidth: 1
                                    ))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func filterChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(selected ? ConverterPalette.background : ConverterPalette.muted)
                .padding(.horizontal, 14)
                .frame(height: 35)
                .background(selected ? ConverterPalette.green : ConverterPalette.panel)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var loadingState: some View {
        VStack(spacing: 11) {
            ProgressView().tint(ConverterPalette.blue).scaleEffect(1.15)
            Text("Loading skin library…")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(ConverterPalette.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
        .background(ConverterPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("Catalog unavailable", systemImage: "wifi.exclamationmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(ConverterPalette.text)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(ConverterPalette.muted)
            Button {
                Task { await loadCatalog() }
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 35)
                    .background(ConverterPalette.blue)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ConverterPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(ConverterPalette.muted)
            Text("No matching skins")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(ConverterPalette.text)
            Text("Try another hero, role or tag.")
                .font(.system(size: 11))
                .foregroundColor(ConverterPalette.muted)
            Button("Clear filters") {
                searchText = ""
                appliedSearchText = ""
                selectedRole = "All"
                selectedTag = "All"
                featuredOnly = false
                rebuildVisibleGroups()
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(ConverterPalette.blue)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(ConverterPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func heroSection(_ group: IshaCatalogHeroGroup) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                IshaCatalogRemoteImage(urlString: group.skins.first?.image)
                    .frame(width: 43, height: 43)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.10), lineWidth: 1))

                VStack(alignment: .leading, spacing: 3) {
                    Text(group.hero.name)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(ConverterPalette.text)
                    Text((group.hero.category ?? "Hero").capitalized + " · \(group.skins.count) available")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(ConverterPalette.muted)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(ConverterPalette.muted)
            }

            ForEach(group.skins) { skin in
                skinRow(skin, heroName: group.hero.name, category: group.hero.category)
            }
        }
        .padding(12)
        .background(ConverterPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(.white.opacity(0.055), lineWidth: 1)
        )
    }

    private func skinRow(_ skin: IshaCatalogSkin, heroName: String, category: String?) -> some View {
        let skinTags = visibleSkinTags(for: skin, heroName: heroName, category: category)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 11) {
                IshaCatalogRemoteImage(urlString: skin.image)
                    .frame(width: 64, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.10), lineWidth: 1))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top, spacing: 6) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(skin.skin_name ?? "Custom Skin")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(ConverterPalette.text)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            if skin.featured == true {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(ConverterPalette.green)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if !skinTags.isEmpty {
                            IshaSkinTagBadgeStack(tags: skinTags) { tag in
                                activeCatalogSheet = .tagInfo(
                                    IshaCatalogTagInfoTarget(
                                        tag: tag,
                                        heroName: heroName,
                                        skinName: skin.skin_name ?? "Custom Skin",
                                        skinImage: skin.image
                                    )
                                )
                            }
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    }

                    Text(heroName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(ConverterPalette.muted)

                    Button {
                        activeCatalogSheet = .tagEditor(
                            IshaCatalogTagEditTarget(skin: skin, heroName: heroName, category: category)
                        )
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "tag.fill").font(.system(size: 9, weight: .bold))
                            Text("EDIT SKIN TAGS").font(.system(size: 8, weight: .heavy, design: .rounded))
                            Text("\(skinTags.count)")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundColor(ConverterPalette.green)
                        }
                        .foregroundColor(ConverterPalette.blue)
                    }
                    .buttonStyle(.plain)

                    if convertingIDs.contains(skin.stableID) {
                        HStack(spacing: 6) {
                            ProgressView().tint(ConverterPalette.green).scaleEffect(0.8)
                            Text("Converting to iOS…")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(ConverterPalette.green)
                        }
                    } else if downloadingIDs.contains(skin.stableID) {
                        HStack(spacing: 6) {
                            ProgressView().tint(ConverterPalette.blue).scaleEffect(0.8)
                            Text("Downloading archive…")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(ConverterPalette.blue)
                        }
                    } else {
                        Text(validArchiveKind(skin.script)?.uppercased() ?? "ARCHIVE")
                            .font(.system(size: 8, weight: .heavy, design: .rounded))
                            .foregroundColor(ConverterPalette.green)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(ConverterPalette.green.opacity(0.10))
                            .clipShape(Capsule())
                    }
                }

                Spacer(minLength: 0)

                Button {
                    Task { await download(skin, heroName: heroName) }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: convertingIDs.contains(skin.stableID) ? "arrow.triangle.2.circlepath" : (downloadingIDs.contains(skin.stableID) ? "arrow.down" : "arrow.down.to.line"))
                            .font(.system(size: 13, weight: .bold))
                        Text(isProcessingDownload ? "WAIT" : "SAVE")
                            .font(.system(size: 8, weight: .heavy, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .frame(width: 49, height: 50)
                    .background(ConverterPalette.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isProcessingDownload)
            }
        }
        .padding(10)
        .background(ConverterPalette.field)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var footer: some View {
        VStack(spacing: 7) {
            HStack {
                Text("ISHA SCRIPT SKIN LIBRARY")
                Spacer()
                Text("DOWNLOAD + AUTO CONVERT")
            }
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundColor(ConverterPalette.muted)
            Text("Tap SAVE to download a skin and automatically convert it into an iOS-ready ZIP.")
                .font(.system(size: 9))
                .foregroundColor(ConverterPalette.muted.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 5)
    }

    @MainActor
    private func loadCatalog() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            var request = URLRequest(url: catalogURL)
            request.timeoutInterval = 35
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw IshaCatalogError.invalidResponse
            }
            let decoded = try JSONDecoder().decode(IshaCatalogResponse.self, from: data)
            guard !decoded.heroes.isEmpty else { throw IshaCatalogError.emptyCatalog }
            heroes = decoded.heroes
            rebuildCatalogCaches(for: decoded.heroes)
            rebuildVisibleGroups()
            errorMessage = nil
        } catch {
            errorMessage = "Hindi ma-load ang catalog. Check internet connection. (\(error.localizedDescription))"
        }
    }

    @MainActor
    private func download(_ skin: IshaCatalogSkin, heroName: String) async {
        guard !isProcessingDownload,
              let address = skin.script,
              let url = URL(string: address),
              url.scheme?.lowercased() == "https",
              let fileExtension = validArchiveKind(address) else {
            errorMessage = "Invalid or unsupported archive link, or another skin is already being processed."
            return
        }

        isProcessingDownload = true
        downloadingIDs.insert(skin.stableID)
        defer {
            downloadingIDs.remove(skin.stableID)
            convertingIDs.remove(skin.stableID)
            isProcessingDownload = false
        }

        do {
            let (temporaryURL, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw IshaCatalogError.invalidResponse
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
            let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard fileSize > 0, fileSize <= 2_000_000_000 else {
                throw IshaCatalogError.invalidArchiveSize
            }

            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let folder = documents.appendingPathComponent("Script Skin Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let destination = folder.appendingPathComponent(
                "\(safeFileName(heroName)) - \(safeFileName(skin.skin_name ?? "Skin")).\(fileExtension)"
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)

            downloadingIDs.remove(skin.stableID)
            convertingIDs.insert(skin.stableID)

            let outputDirectory = documents
                .appendingPathComponent("Isha Converter iOS", isDirectory: true)
                .appendingPathComponent("Auto Converted Skins", isDirectory: true)
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

            // Reuse the exact converter engine used by the main Convert screen.
            // Keep the original downloaded archive as a recovery copy.
            let conversionResult: Result<URL, Error> = await withCheckedContinuation { continuation in
                PythonConverter.shared.convert(input: destination, outputDirectory: outputDirectory) { result in
                    continuation.resume(returning: result)
                }
            }

            switch conversionResult {
            case .success(let convertedURL):
                var history = recentDownloads
                history.removeAll { $0 == convertedURL.lastPathComponent }
                history.insert(convertedURL.lastPathComponent, at: 0)
                history = Array(history.prefix(30))
                if let historyData = try? JSONEncoder().encode(history),
                   let historyText = String(data: historyData, encoding: .utf8) {
                    historyJSON = historyText
                }

                activeCatalogSheet = .share(convertedURL)
                statusMessage = "Tapos na: na-download at awtomatikong na-convert ang \(skin.skin_name ?? "skin") para sa iOS. Ang converted ZIP ang nakahandang i-save o i-share."
            case .failure(let conversionError):
                errorMessage = "Na-download ang \(skin.skin_name ?? "skin"), pero nabigo ang automatic iOS conversion. Nananatili ang original archive sa Script Skin Downloads. Error: \(conversionError.localizedDescription)"
            }
        } catch {
            errorMessage = "Hindi na-download ang \(skin.skin_name ?? "skin"). \(error.localizedDescription)"
        }
    }

    private func validDownloadURL(_ value: String?) -> Bool {
        guard let value, let url = URL(string: value) else { return false }
        return url.scheme?.lowercased() == "https"
    }

    private func validArchiveKind(_ value: String?) -> String? {
        guard let value, let url = URL(string: value), url.scheme?.lowercased() == "https" else { return nil }
        let ext = url.pathExtension.lowercased()
        return (ext == "zip" || ext == "rar") ? ext : nil
    }

    private func safeFileName(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(
            of: "[^A-Za-z0-9._ -]",
            with: "_",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Skin" : cleaned
    }
}

private struct IshaSkinUpgradeCatalogResponse: Decodable {
    let skin_upgrades: [IshaSkinUpgradeEntry]
}

private struct IshaSkinUpgradeEntry: Decodable, Identifiable {
    let id: String
    let hero: String
    let base_name: String
    let base_image: String?
    let enabled: Bool?
    let skin_tags: [String]?
    let targets: [IshaSkinUpgradeTarget]?
}

private struct IshaSkinUpgradeTarget: Decodable, Identifiable {
    let id: String
    let name: String
    let image: String?
    let script: String?
    let type: String?
    let enabled: Bool?
    let skin_tags: [String]?
}

private struct IshaSkinUpgradeSelection {
    let entry: IshaSkinUpgradeEntry
    let target: IshaSkinUpgradeTarget
}

private struct IshaCatalogResponse: Decodable {
    let heroes: [IshaCatalogHero]
}

private struct IshaCatalogHero: Decodable, Identifiable {
    let id: String
    let name: String
    let category: String?
    let enabled: Bool?
    let skins: [IshaCatalogSkin]
}

private struct IshaCatalogSkin: Decodable, Identifiable {
    let skinID: String?
    let skin_name: String?
    let image: String?
    let script: String?
    let featured: Bool?
    let enabled: Bool?
    let tags: [IshaCatalogTag]?

    enum CodingKeys: String, CodingKey {
        case skinID = "id"
        case skin_name, image, script, featured, enabled, tags
    }

    var stableID: String {
        skinID ?? "\(skin_name ?? "skin")|\(script ?? "")"
    }

    var id: String { stableID }

    func searchTags(heroName: String, category: String?) -> [String] {
        var result: [String] = []

        func appendUnique(_ value: String) {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty,
                  !result.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) else { return }
            result.append(cleaned)
        }

        // Every entry receives generated hero and role tags even when its source
        // record has no manually assigned skin tags.
        appendUnique(heroName)
        appendUnique(category?.capitalized ?? "Uncategorized")

        let genericTags: Set<String> = ["assassin", "fighter", "mage", "marksman", "tank", "support", "basic", "backup", "default", "uncategorized", "featured"]
        let sourceTags = (tags ?? []).map { $0.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter {
                let key = ishaSkinTagKey($0)
                return !key.isEmpty &&
                    key != ishaSkinTagKey(heroName) &&
                    key != ishaSkinTagKey(category ?? "") &&
                    !genericTags.contains(key)
            }
        for tag in sourceTags {
            appendUnique(tag)
        }
        if sourceTags.isEmpty {
            appendUnique("Uncategorized")
        }
        if featured == true {
            appendUnique("Featured")
        }
        return result
    }
}

private struct IshaCatalogTag: Decodable, Identifiable {
    let tagID: String?
    let name: String
    let icon: String?
    let file: String?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case tagID = "id"
        case name, icon, file, description
    }

    var canonicalID: String {
        let rawID = (tagID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let slug = rawID.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? stableID : slug
    }

    var canonicalName: String {
        switch canonicalID {
        case "valentine": return "Valentine"
        case "elite": return "Elite"
        case "starlight": return "Starlight"
        default: return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var displayName: String {
        canonicalID.contains("anniversary") ? "10TH ANNIVERSARY" : canonicalName.uppercased()
    }

    var infoTitle: String {
        let normalized = (canonicalName + " " + (file ?? "")).lowercased()
        if canonicalID.contains("anniversary") || normalized.contains("10th anniversary") || normalized.contains("epic 10th") {
            return "10th Anniversary Skin"
        }
        if let supplied = description?.trimmingCharacters(in: .whitespacesAndNewlines), !supplied.isEmpty {
            return canonicalName
        }
        return canonicalName.localizedCaseInsensitiveContains("skin") ? canonicalName : "\(canonicalName) Skin"
    }

    var infoDescription: String {
        if let supplied = description?.trimmingCharacters(in: .whitespacesAndNewlines), !supplied.isEmpty {
            return supplied
        }
        let normalized = (canonicalName + " " + (file ?? "")).lowercased()
        if canonicalID.contains("anniversary") || normalized.contains("10th anniversary") || normalized.contains("epic 10th") {
            return "10th Anniversary-themed exclusive Epic skin."
        }
        switch canonicalID {
        case "epic":
            return "This badge identifies the skin as an Epic-tier skin."
        case "collector":
            return "This badge identifies the skin as part of the Collector series."
        case "starlight":
            return "This badge identifies the skin as part of the Starlight series."
        case "annual-starlight":
            return "This badge identifies the skin as part of the Annual Starlight series."
        case "valentine":
            return "This badge identifies the skin as part of the Valentine series."
        case "elite":
            return "This badge identifies the skin as an Elite-tier skin."
        default:
            return "This badge identifies the skin's \(canonicalName) category in the catalog."
        }
    }

    var stableID: String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let slug = value.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? (tagID ?? "tag") : slug
    }

    var id: String { canonicalID }
}

private func ishaSkinTagKey(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

private struct IshaCatalogTagEditTarget: Identifiable {
    let skin: IshaCatalogSkin
    let heroName: String
    let category: String?
    var id: String { skin.stableID }
}

private enum IshaCatalogSheet: Identifiable {
    case tagEditor(IshaCatalogTagEditTarget)
    case tagInfo(IshaCatalogTagInfoTarget)
    case skinTagSettings
    case multiReplace
    case share(URL)

    var id: String {
        switch self {
        case .tagEditor(let target): return "tag-editor|\(target.id)"
        case .tagInfo(let target): return "tag-info|\(target.id)"
        case .skinTagSettings: return "skin-tag-settings"
        case .multiReplace: return "multi-replace"
        case .share(let url): return "share|\(url.lastPathComponent)"
        }
    }
}


private struct IshaSkinTagReplacementRule: Codable, Identifiable, Equatable {
    var id: String
    var sourceTagID: String
    var displayTagID: String
    var gemColorID: String

    init(sourceTagID: String = "", displayTagID: String = "", gemColorID: String = "auto") {
        self.id = UUID().uuidString
        self.sourceTagID = sourceTagID
        self.displayTagID = displayTagID
        self.gemColorID = gemColorID
    }
}

private struct IshaSkinTagPickerTarget: Identifiable {
    let ruleID: String
    let slot: String
    let title: String
    var id: String { ruleID + "|" + slot }
}

private struct IshaGemPickerTarget: Identifiable {
    let ruleID: String
    var id: String { ruleID }
}

private struct IshaGemOption: Identifiable {
    let id: String
    let title: String
    let color: Color
}

private struct IshaCatalogTagInfoTarget: Identifiable {
    let tag: IshaCatalogTag
    let heroName: String
    let skinName: String
    let skinImage: String?

    var id: String { tag.stableID + "|" + heroName + "|" + skinName }
}

private struct IshaCatalogHeroGroup: Identifiable {
    let hero: IshaCatalogHero
    let skins: [IshaCatalogSkin]
    var id: String { hero.id }
}

private enum IshaCatalogError: LocalizedError {
    case invalidResponse
    case invalidArchiveSize
    case emptyCatalog
    case multiReplaceBatchTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The catalog or download server returned an invalid response."
        case .invalidArchiveSize: return "The downloaded archive is empty or exceeds the 2 GB safety limit."
        case .emptyCatalog: return "The catalog contains no heroes."
        case .multiReplaceBatchTooLarge: return "The selected replacement ZIP files exceed the 2 GB total batch limit. Select fewer skins and try again."
        }
    }
}

private struct IshaCatalogRemoteImage: View {
    let urlString: String?

    var body: some View {
        AsyncImage(url: URL(string: urlString ?? "")) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .failure, .empty:
                ZStack {
                    ConverterPalette.field
                    Image(systemName: "person.crop.square")
                        .resizable()
                        .scaledToFit()
                        .padding(11)
                        .foregroundColor(ConverterPalette.muted)
                }
            @unknown default:
                ConverterPalette.field
            }
        }
        .background(ConverterPalette.field)
        .clipped()
    }
}


private struct IshaSkinTagBadgeStack: View {
    let tags: [IshaCatalogTag]
    let onTap: (IshaCatalogTag) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 7) {
            ForEach(tags) { tag in
                Button {
                    onTap(tag)
                } label: {
                    VStack(spacing: 2) {
                        // The official MLBB tag artwork itself is the button surface.
                        IshaCatalogTagArtwork(tag: tag)
                            .frame(width: 132, height: 38)
                            .contentShape(Rectangle())

                        Text("TAP FOR DETAILS")
                            .font(.system(size: 7, weight: .heavy, design: .rounded))
                            .tracking(0.55)
                            .foregroundColor(ConverterPalette.blue)
                    }
                    .frame(width: 132, height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Open \(tag.displayName) skin tag details")
                .accessibilityHint("Shows details for this Mobile Legends skin tag")
                .frame(width: 132, height: 48)
                .contentShape(Rectangle())
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct IshaSkinTagInfoSheet: View {
    @Environment(\.presentationMode) private var presentationMode
    let tag: IshaCatalogTag
    let heroName: String
    let skinName: String
    let skinImage: String?

    private var anniversarySkin: Bool {
        tag.canonicalID.contains("anniversary")
            || skinName.localizedCaseInsensitiveContains("anniversary")
            || skinName.localizedCaseInsensitiveContains("10th")
    }

    private var titleText: String {
        anniversarySkin ? "10th Anniversary Skin" : tag.infoTitle
    }

    private var descriptionText: String {
        anniversarySkin
            ? "10th Anniversary-themed exclusive Epic skin."
            : tag.infoDescription
    }

    var body: some View {
        NavigationView {
            ZStack {
                ConverterPalette.background.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        Text("SKIN TAG DETAILS")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundColor(ConverterPalette.muted)
                        Spacer()
                        Button {
                            presentationMode.wrappedValue.dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(ConverterPalette.text)
                                .frame(width: 34, height: 34)
                                .background(ConverterPalette.panel)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 12) {
                        IshaCatalogTagArtwork(tag: tag)
                            .frame(width: 210, height: 72)
                            .padding(7)
                            .background(ConverterPalette.field)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "diamond.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(Color(red: 0.65, green: 0.40, blue: 1.0))
                                Text(titleText)
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text(tag.canonicalName.uppercased())
                                .font(.system(size: 9, weight: .heavy, design: .rounded))
                                .foregroundColor(ConverterPalette.blue)
                            Text(heroName + " · " + skinName)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(ConverterPalette.muted)
                                .lineLimit(2)
                        }
                    }

                    Text(descriptionText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color(red: 0.72, green: 0.79, blue: 0.88))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ConverterPalette.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Spacer(minLength: 4)
                }
                .padding(16)
            }
            .navigationBarHidden(true)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}


private struct IshaGameLookSkinTagsView: View {
    @Environment(\.presentationMode) private var presentationMode
    @AppStorage("isha.gameLook.skinTags.enabled") private var isEnabled = true
    @AppStorage("isha.gameLook.skinTags.rules.v1") private var savedRulesJSON = "[]"

    let tags: [IshaCatalogTag]

    @State private var rules: [IshaSkinTagReplacementRule] = []
    @State private var pickerTarget: IshaSkinTagPickerTarget?
    @State private var gemPickerTarget: IshaGemPickerTarget?
    @State private var didLoadRules = false

    private let gold = Color(red: 0.91, green: 0.70, blue: 0.34)

    private var artworkTags: [IshaCatalogTag] {
        tags.filter { tag in
            guard let icon = tag.icon?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: icon) else { return false }
            return !icon.isEmpty && url.scheme?.lowercased() == "https"
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                ConverterPalette.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    header

                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 13) {
                            Text("5 · SKIN TAGS (LOADING SCREEN)")
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .tracking(0.35)
                                .foregroundColor(ConverterPalette.muted)
                                .padding(.horizontal, 3)
                                .padding(.top, 14)

                            VStack(alignment: .leading, spacing: 0) {
                                HStack {
                                    Text("Change skin tags")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(ConverterPalette.text)
                                    Spacer()
                                    Toggle("Change skin tags", isOn: $isEnabled)
                                        .labelsHidden()
                                        .tint(gold)
                                }
                                .padding(.horizontal, 15)
                                .padding(.vertical, 14)

                                Divider().overlay(.white.opacity(0.07))

                                if isEnabled {
                                    if rules.isEmpty {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("No skin-tag replacements yet")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundColor(ConverterPalette.text)
                                            Text("Choose an original tag, then choose the artwork and name you want to show for every skin carrying that tag.")
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundColor(ConverterPalette.muted)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(15)
                                    }

                                    ForEach(rules) { rule in
                                        ruleCard(rule)
                                    }

                                    Button {
                                        rules.append(IshaSkinTagReplacementRule())
                                        persistRules()
                                    } label: {
                                        HStack(spacing: 9) {
                                            Image(systemName: "plus.circle.fill")
                                                .font(.system(size: 19, weight: .semibold))
                                            Text("Add another tag")
                                                .font(.system(size: 13, weight: .semibold))
                                            Spacer()
                                        }
                                        .foregroundColor(gold)
                                        .padding(.horizontal, 15)
                                        .frame(minHeight: 48)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    Text("A tag's picture and title are replaced for every skin that carries that tag. The gem follows the tag by default; choose a gem colour to override it.")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(ConverterPalette.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 15)
                                        .padding(.bottom, 14)
                                } else {
                                    Text("Skin-tag replacements are turned off. Your saved rules will stay here.")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(ConverterPalette.muted)
                                        .padding(15)
                                }
                            }
                            .background(ConverterPalette.panel)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(.white.opacity(0.055), lineWidth: 1)
                            )

                            Text("Rules are saved on this iPhone and reflected in the ISHA skin catalog preview.")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(ConverterPalette.muted.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 3)
                                .padding(.bottom, 28)
                        }
                        .padding(.horizontal, 14)
                    }
                }
            }
            .navigationBarHidden(true)
            .preferredColorScheme(.dark)
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear(perform: loadRules)
        .sheet(item: $pickerTarget) { target in
            IshaGameLookTagPickerView(
                title: target.title,
                tags: artworkTags,
                onCancel: { pickerTarget = nil },
                onSelect: { tag in
                    updateRule(target.ruleID) { rule in
                        if target.slot == "source" {
                            rule.sourceTagID = tag.canonicalID
                        } else {
                            rule.displayTagID = tag.canonicalID
                        }
                    }
                    pickerTarget = nil
                }
            )
        }
        .sheet(item: $gemPickerTarget) { target in
            IshaGameLookGemPickerView(
                selectedID: rules.first(where: { $0.id == target.ruleID })?.gemColorID ?? "auto",
                onCancel: { gemPickerTarget = nil },
                onSelect: { colorID in
                    updateRule(target.ruleID) { $0.gemColorID = colorID }
                    gemPickerTarget = nil
                }
            )
        }
    }

    private var header: some View {
        HStack {
            Button("Done") {
                presentationMode.wrappedValue.dismiss()
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(ConverterPalette.blue)

            Spacer()

            Text("Game look")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(ConverterPalette.text)

            Spacer()

            Text("Done")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.clear)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(ConverterPalette.panel.opacity(0.96))
    }

    private func ruleCard(_ rule: IshaSkinTagReplacementRule) -> some View {
        let source = findTag(rule.sourceTagID)
        let display = findTag(rule.displayTagID)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TAG REPLACEMENT")
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .tracking(0.65)
                    .foregroundColor(gold)
                Spacer()
                Button {
                    rules.removeAll { $0.id == rule.id }
                    persistRules()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(ConverterPalette.muted)
                        .frame(width: 30, height: 30)
                        .background(ConverterPalette.field)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            pickerRow(caption: "Tag of my skin", selectedName: source.map(tagTitle) ?? "Choose",
                      ruleID: rule.id, slot: "source", title: "Choose the tag")

            pickerRow(caption: "Show it as", selectedName: display.map(tagTitle) ?? "Choose",
                      ruleID: rule.id, slot: "display", title: "Show it as")

            HStack(spacing: 8) {
                previewCard(label: "BEFORE", tag: source, gemColorID: "auto")
                    .frame(maxWidth: .infinity)
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(gold)
                    .frame(width: 18)
                previewCard(label: "AFTER", tag: display, gemColorID: rule.gemColorID)
                    .frame(maxWidth: .infinity)
            }

            Text(rule.gemColorID == "auto"
                 ? "Gem: same colour, nothing to change."
                 : "Gem: \(gemTitle(rule.gemColorID))")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(ConverterPalette.muted)

            Button {
                gemPickerTarget = IshaGemPickerTarget(ruleID: rule.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(gemColor(rule.gemColorID))
                    Text("Pick the gem myself")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(ConverterPalette.text)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(gold)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(13)
        .background(ConverterPalette.field.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(gold.opacity(0.20), lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    private func pickerRow(
        caption: String,
        selectedName: String,
        ruleID: String,
        slot: String,
        title: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(ConverterPalette.muted)

            Button {
                pickerTarget = IshaSkinTagPickerTarget(ruleID: ruleID, slot: slot, title: title)
            } label: {
                HStack(spacing: 5) {
                    Text("Choose the tag")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(ConverterPalette.text)
                    Spacer(minLength: 4)
                    Text(selectedName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(gold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(ConverterPalette.muted)
                }
                .frame(minHeight: 25)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func previewCard(label: String, tag: IshaCatalogTag?, gemColorID: String) -> some View {
        VStack(spacing: 5) {
            Text(label)
                .font(.system(size: 7, weight: .heavy, design: .rounded))
                .tracking(0.75)
                .foregroundColor(ConverterPalette.muted)

            if let tag {
                IshaCatalogTagArtwork(tag: tag)
                    .frame(height: 55)
                    .padding(.horizontal, 5)
            } else {
                Text("Choose")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(ConverterPalette.muted)
                    .frame(height: 55)
            }

            HStack(spacing: 4) {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(gemColor(gemColorID))
                Text(tag.map(tagTitle) ?? "Skin Tag")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(ConverterPalette.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 22)
        }
        .padding(7)
        .frame(minHeight: 112)
        .background(Color.black.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(gold.opacity(0.18), lineWidth: 1)
        )
    }

    private func findTag(_ id: String) -> IshaCatalogTag? {
        guard !id.isEmpty else { return nil }
        return tags.first(where: { $0.canonicalID == id })
    }

    private func tagTitle(_ tag: IshaCatalogTag) -> String {
        switch tag.canonicalID {
        case "elite", "special", "epic", "legend", "limited":
            return tag.canonicalName + " Skin"
        case "starlight":
            return "StarLight Skin"
        case "annual-starlight":
            return "Annual StarLight Skin"
        case "valentine":
            return "Valentine's Day Skin"
        case "aspirants", "the-aspirants":
            return "The Aspirants Series Skin"
        default:
            return tag.canonicalName
        }
    }

    private func updateRule(_ id: String, change: (inout IshaSkinTagReplacementRule) -> Void) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        change(&rules[index])
        persistRules()
    }

    private func loadRules() {
        guard !didLoadRules else { return }
        didLoadRules = true
        if let data = savedRulesJSON.data(using: .utf8),
           let stored = try? JSONDecoder().decode([IshaSkinTagReplacementRule].self, from: data) {
            rules = stored
        } else {
            rules = []
        }
    }

    private func persistRules() {
        guard let data = try? JSONEncoder().encode(rules),
              let json = String(data: data, encoding: .utf8) else { return }
        savedRulesJSON = json
    }

    private func gemTitle(_ id: String) -> String {
        switch id {
        case "gold": return "Gold"
        case "red": return "Red"
        case "blue": return "Blue"
        case "green": return "Green"
        case "purple": return "Purple"
        case "cyan": return "Cyan"
        case "white": return "White"
        case "orange": return "Orange"
        default: return "Same colour"
        }
    }

    private func gemColor(_ id: String) -> Color {
        switch id {
        case "gold": return Color(red: 1.0, green: 0.72, blue: 0.22)
        case "red": return Color(red: 0.96, green: 0.28, blue: 0.30)
        case "blue": return Color(red: 0.26, green: 0.62, blue: 1.0)
        case "green": return Color(red: 0.25, green: 0.86, blue: 0.55)
        case "purple": return Color(red: 0.72, green: 0.42, blue: 1.0)
        case "cyan": return Color(red: 0.25, green: 0.88, blue: 0.92)
        case "white": return Color(red: 0.90, green: 0.94, blue: 1.0)
        case "orange": return Color(red: 1.0, green: 0.48, blue: 0.16)
        default: return gold
        }
    }
}

private struct IshaGameLookTagPickerView: View {
    let title: String
    let tags: [IshaCatalogTag]
    let onCancel: () -> Void
    let onSelect: (IshaCatalogTag) -> Void

    @State private var searchText = ""

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    private var filteredTags: [IshaCatalogTag] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tags }
        return tags.filter { $0.canonicalName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationView {
            ZStack {
                ConverterPalette.background.ignoresSafeArea()

                VStack(spacing: 10) {
                    HStack {
                        Button("Cancel", action: onCancel)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(ConverterPalette.blue)
                        Spacer()
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(ConverterPalette.text)
                        Spacer()
                        Color.clear.frame(width: 48)
                    }
                    .padding(.horizontal, 13)
                    .frame(height: 42)

                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(ConverterPalette.muted)
                        TextField("Search", text: $searchText)
                            .font(.system(size: 13))
                            .foregroundColor(ConverterPalette.text)
                            .autocorrectionDisabled()
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(ConverterPalette.muted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 39)
                    .background(ConverterPalette.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 13)

                    ScrollView(showsIndicators: false) {
                        LazyVGrid(columns: columns, spacing: 9) {
                            ForEach(filteredTags) { tag in
                                Button {
                                    onSelect(tag)
                                } label: {
                                    VStack(spacing: 6) {
                                        IshaCatalogTagArtwork(tag: tag)
                                            .frame(height: 67)
                                            .padding(.horizontal, 5)
                                            .padding(.top, 7)
                                        Text(tag.canonicalName)
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundColor(ConverterPalette.text)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                            .frame(maxWidth: .infinity, minHeight: 24, alignment: .top)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 103)
                                    .background(Color.black.opacity(0.32))
                                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .stroke(.white.opacity(0.09), lineWidth: 1)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 13)
                        .padding(.bottom, 22)
                    }
                }
            }
            .navigationBarHidden(true)
            .preferredColorScheme(.dark)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

private struct IshaGameLookGemPickerView: View {
    let selectedID: String
    let onCancel: () -> Void
    let onSelect: (String) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 9),
        GridItem(.flexible(), spacing: 9),
        GridItem(.flexible(), spacing: 9)
    ]

    private let options: [IshaGemOption] = [
        IshaGemOption(id: "auto", title: "Same colour", color: Color(red: 0.91, green: 0.70, blue: 0.34)),
        IshaGemOption(id: "gold", title: "Gold", color: Color(red: 1.0, green: 0.72, blue: 0.22)),
        IshaGemOption(id: "red", title: "Red", color: Color(red: 0.96, green: 0.28, blue: 0.30)),
        IshaGemOption(id: "blue", title: "Blue", color: Color(red: 0.26, green: 0.62, blue: 1.0)),
        IshaGemOption(id: "green", title: "Green", color: Color(red: 0.25, green: 0.86, blue: 0.55)),
        IshaGemOption(id: "purple", title: "Purple", color: Color(red: 0.72, green: 0.42, blue: 1.0)),
        IshaGemOption(id: "cyan", title: "Cyan", color: Color(red: 0.25, green: 0.88, blue: 0.92)),
        IshaGemOption(id: "white", title: "White", color: Color(red: 0.90, green: 0.94, blue: 1.0)),
        IshaGemOption(id: "orange", title: "Orange", color: Color(red: 1.0, green: 0.48, blue: 0.16))
    ]

    var body: some View {
        NavigationView {
            ZStack {
                ConverterPalette.background.ignoresSafeArea()
                VStack(spacing: 12) {
                    HStack {
                        Button("Cancel", action: onCancel)
                            .foregroundColor(ConverterPalette.blue)
                        Spacer()
                        Text("Pick the gem")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(ConverterPalette.text)
                        Spacer()
                        Color.clear.frame(width: 48)
                    }
                    .font(.system(size: 15, weight: .medium))
                    .padding(.horizontal, 14)
                    .frame(height: 42)

                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(options) { option in
                            Button {
                                onSelect(option.id)
                            } label: {
                                VStack(spacing: 8) {
                                    Image(systemName: option.id == "auto" ? "arrow.triangle.2.circlepath" : "diamond.fill")
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundColor(option.color)
                                    Text(option.title)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(ConverterPalette.text)
                                }
                                .frame(maxWidth: .infinity, minHeight: 82)
                                .background(ConverterPalette.panel)
                                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .stroke(selectedID == option.id ? option.color : .white.opacity(0.08), lineWidth: selectedID == option.id ? 1.7 : 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    Spacer()
                }
            }
            .navigationBarHidden(true)
            .preferredColorScheme(.dark)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

private struct IshaSkinTagPickerView: View {
    let skinName: String
    let heroName: String
    let tags: [IshaCatalogTag]
    let onCancel: () -> Void
    let onSave: ([String]) -> Void

    @State private var searchText = ""
    @State private var selectedIDs: Set<String>

    private let columns = [
        GridItem(.flexible(), spacing: 9),
        GridItem(.flexible(), spacing: 9),
        GridItem(.flexible(), spacing: 9)
    ]

    init(
        skinName: String,
        heroName: String,
        tags: [IshaCatalogTag],
        initialSelection: Set<String>,
        onCancel: @escaping () -> Void,
        onSave: @escaping ([String]) -> Void
    ) {
        self.skinName = skinName
        self.heroName = heroName
        self.tags = tags
        self.onCancel = onCancel
        self.onSave = onSave
        _selectedIDs = State(initialValue: initialSelection)
    }

    private var filteredTags: [IshaCatalogTag] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tags }
        return tags.filter { $0.canonicalName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationView {
            ZStack {
                ConverterPalette.background.ignoresSafeArea()

                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("CHOOSE SKIN TAGS")
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                            .foregroundColor(ConverterPalette.text)
                        Text("\(heroName) · \(skinName)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(ConverterPalette.muted)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(ConverterPalette.green)
                            Text("\(selectedIDs.count) selected")
                                .foregroundColor(ConverterPalette.green)
                            Spacer()
                            Text("\(tags.count) available tags")
                                .foregroundColor(ConverterPalette.muted)
                        }
                        .font(.system(size: 9, weight: .bold))
                        .padding(.top, 3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(ConverterPalette.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(ConverterPalette.blue)
                        TextField("Search tag name…", text: $searchText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(ConverterPalette.text)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(ConverterPalette.muted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 13)
                    .frame(height: 46)
                    .background(ConverterPalette.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    ScrollView(showsIndicators: false) {
                        if filteredTags.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "tag")
                                    .font(.system(size: 25))
                                    .foregroundColor(ConverterPalette.muted)
                                Text("No tags found")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(ConverterPalette.text)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 35)
                        } else {
                            LazyVGrid(columns: columns, spacing: 9) {
                                ForEach(filteredTags) { tag in
                                    tagCell(tag)
                                }
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Button(action: onCancel) {
                            Text("CANCEL")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundColor(ConverterPalette.text)
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .background(ConverterPalette.panel)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            onSave(Array(selectedIDs).sorted())
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "checkmark")
                                Text("DONE")
                                Text("(\(selectedIDs.count))")
                                    .opacity(0.75)
                            }
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(ConverterPalette.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
            }
            .navigationBarHidden(true)
            .preferredColorScheme(.dark)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func tagCell(_ tag: IshaCatalogTag) -> some View {
        let isSelected = selectedIDs.contains(tag.stableID)
        return Button {
            if isSelected { selectedIDs.remove(tag.stableID) }
            else { selectedIDs.insert(tag.stableID) }
        } label: {
            VStack(spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(ConverterPalette.field)
                    IshaCatalogTagArtwork(tag: tag)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 8)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(ConverterPalette.green)
                            .padding(5)
                            .background(ConverterPalette.field.opacity(0.92))
                            .clipShape(Circle())
                    }
                }
                .frame(height: 63)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? ConverterPalette.green : ConverterPalette.muted.opacity(0.18), lineWidth: isSelected ? 1.7 : 1)
                )

                Text(tag.canonicalName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(isSelected ? ConverterPalette.green : ConverterPalette.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .top)
            }
            .padding(6)
            .background(isSelected ? ConverterPalette.green.opacity(0.07) : ConverterPalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? ConverterPalette.green.opacity(0.55) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct IshaCatalogTagArtwork: View {
    let tag: IshaCatalogTag

    // The catalog stores Fandom thumbnails at 75 px. Request a larger rendition
    // so the badge remains crisp when shown at its real in-app size.
    private var artworkURL: URL? {
        guard let raw = tag.icon?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let highResolution = raw
            .replacingOccurrences(of: "/scale-to-width-down/75", with: "/scale-to-width-down/300")
            .replacingOccurrences(of: "/scale-to-width-down/100", with: "/scale-to-width-down/300")
        return URL(string: highResolution)
    }

    var body: some View {
        Group {
            if let artworkURL {
                AsyncImage(url: artworkURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                    case .empty:
                        ProgressView().tint(ConverterPalette.blue)
                    case .failure:
                        fallback
                    @unknown default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    // A text-only placeholder is used only where the source catalog has no
    // official image; it is deliberately not presented as official artwork.
    private var fallback: some View {
        Text(tag.displayName)
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .tracking(0.25)
            .foregroundColor(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.13, green: 0.20, blue: 0.34),
                        Color(red: 0.06, green: 0.09, blue: 0.16)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(ConverterPalette.blue.opacity(0.65), lineWidth: 1)
            )
    }
}


private struct IshaMultiReplaceLibraryView: View {
    @Environment(\.presentationMode) private var presentationMode

    @State private var entries: [IshaSkinUpgradeEntry] = []
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var appliedSearchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedReplacements: [String: String] = [:]
    @State private var isApplying = false
    @State private var processingMessage: String?
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var shareURL: URL?
    @State private var showShareSheet = false

    private let catalogURL = URL(string: "https://raw.githubusercontent.com/missnapokita/masterkiter/main/skin_upgrades.json")!
    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    private var availableTargetCount: Int {
        var total = 0
        for entry in entries {
            for target in entry.targets ?? [] {
                if validTarget(target) {
                    total += 1
                }
            }
        }
        return total
    }

    private var enabledEntryCount: Int {
        var count = 0
        for entry in entries {
            guard entry.enabled != false else { continue }
            let targets = entry.targets ?? []
            if targets.contains(where: { target in validTarget(target) }) {
                count += 1
            }
        }
        return count
    }

    private var selectedJobs: [IshaSkinUpgradeSelection] {
        var result: [IshaSkinUpgradeSelection] = []
        for entry in entries {
            guard let targetID = selectedReplacements[entry.id] else { continue }
            for target in entry.targets ?? [] {
                if target.id == targetID && validTarget(target) {
                    result.append(IshaSkinUpgradeSelection(entry: entry, target: target))
                    break
                }
            }
        }
        return result
    }

    private var visibleEntries: [IshaSkinUpgradeEntry] {
        let query = appliedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [IshaSkinUpgradeEntry] = []

        for entry in entries {
            guard entry.enabled != false else { continue }

            var hasValidTarget = false
            for target in entry.targets ?? [] {
                if validTarget(target) {
                    hasValidTarget = true
                    break
                }
            }
            guard hasValidTarget else { continue }

            if query.isEmpty || matchesSearch(entry, query: query) {
                result.append(entry)
            }
        }
        return result
    }

    private func matchesSearch(_ entry: IshaSkinUpgradeEntry, query: String) -> Bool {
        var searchParts: [String] = [entry.hero, entry.base_name]
        searchParts.append(contentsOf: entry.skin_tags ?? [])

        for target in entry.targets ?? [] {
            guard validTarget(target) else { continue }
            searchParts.append(target.name)
            if let type = target.type { searchParts.append(type) }
            searchParts.append(contentsOf: target.skin_tags ?? [])
        }

        return searchParts.joined(separator: " ").localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        NavigationView {
            ZStack {
                ConverterPalette.background.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        topBar
                        heroPanel
                        searchField

                        if !selectedReplacements.isEmpty {
                            selectionPanel
                        }

                        HStack {
                            Text("ALL AVAILABLE BASE SKINS")
                                .font(.system(size: 9, weight: .heavy, design: .rounded))
                                .foregroundColor(ConverterPalette.muted)
                            Spacer()
                            Text("\(visibleEntries.count) SKINS")
                                .font(.system(size: 9, weight: .heavy, design: .rounded))
                                .foregroundColor(ConverterPalette.green)
                        }

                        if isLoading && entries.isEmpty {
                            loadingState
                        } else if let errorMessage, entries.isEmpty {
                            errorState(errorMessage)
                        } else if visibleEntries.isEmpty {
                            emptyState
                        } else {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(visibleEntries) { entry in
                                    upgradeCard(entry)
                                }
                            }
                        }

                        footer
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 34)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationBarHidden(true)
            .preferredColorScheme(.dark)
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .task {
            if entries.isEmpty { await loadCatalog() }
        }
        .onChange(of: searchText) { value in
            searchTask?.cancel()
            searchTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 220_000_000)
                guard !Task.isCancelled else { return }
                appliedSearchText = value
            }
        }
        .onDisappear {
            searchTask?.cancel()
        }
        .sheet(isPresented: $showShareSheet) {
            if let shareURL {
                ActivityView(activityItems: [shareURL])
            }
        }
        .alert("Multi Replace failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .alert("Multi Replace", isPresented: Binding(
            get: { statusMessage != nil },
            set: { if !$0 { statusMessage = nil } }
        )) {
            Button("OK", role: .cancel) { statusMessage = nil }
        } message: {
            Text(statusMessage ?? "")
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                presentationMode.wrappedValue.dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(ConverterPalette.text)
                    .frame(width: 40, height: 40)
                    .background(ConverterPalette.panel)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("ISHA CONVERTER")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundColor(ConverterPalette.text)
                Text("MULTI-SKIN REPLACE")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(ConverterPalette.green)
            }

            Spacer()

            Button {
                Task { await loadCatalog() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(ConverterPalette.blue)
                    .frame(width: 40, height: 40)
                    .background(ConverterPalette.panel)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isLoading || isApplying)
        }
    }

    private var heroPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("REPLACE MULTIPLE SKINS")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundColor(ConverterPalette.green)
                Spacer()
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.white.opacity(0.78))
            }

            Text("Not limited to Default")
                .font(.system(size: 23, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            Text("Choose a base skin, pick its replacement, then select more skins from other heroes. Convert the whole selection into one iOS-ready ZIP.")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 0) {
                metric(value: "\(enabledEntryCount)", label: "BASE SKINS")
                Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 28)
                metric(value: "\(availableTargetCount)", label: "REPLACEMENTS")
                Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 28)
                metric(value: "\(selectedReplacements.count)", label: "SELECTED")
            }
            .padding(.top, 2)
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.24, blue: 0.38),
                    Color(red: 0.10, green: 0.18, blue: 0.28),
                    ConverterPalette.panel
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(ConverterPalette.green.opacity(0.25), lineWidth: 1)
        )
    }

    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 7, weight: .heavy, design: .rounded))
                .foregroundColor(.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(ConverterPalette.blue)
            TextField("Search hero, base skin or replacement…", text: $searchText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(ConverterPalette.text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    appliedSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(ConverterPalette.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 46)
        .background(ConverterPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ConverterPalette.blue.opacity(0.25), lineWidth: 1)
        )
    }

    private var selectionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selectedReplacements.count) REPLACEMENT(S) SELECTED")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundColor(ConverterPalette.green)
                    Text("One target per base skin · multiple heroes supported")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(ConverterPalette.muted)
                }
                Spacer()
                Button("CLEAR") {
                    selectedReplacements.removeAll()
                }
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundColor(ConverterPalette.blue)
                .disabled(isApplying)
            }

            Button {
                Task { await downloadAndConvert() }
            } label: {
                HStack(spacing: 8) {
                    if isApplying {
                        ProgressView().tint(.white).scaleEffect(0.85)
                    } else {
                        Image(systemName: "arrow.down.to.line")
                    }
                    Text(isApplying ? "PROCESSING SELECTED SKINS…" : "DOWNLOAD + CONVERT SELECTED")
                    Spacer()
                    Text("\(selectedReplacements.count)")
                        .opacity(0.75)
                }
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 13)
                .frame(height: 45)
                .background(ConverterPalette.green.opacity(0.88))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isApplying || selectedReplacements.isEmpty)

            if let processingMessage {
                HStack(spacing: 7) {
                    ProgressView().tint(ConverterPalette.blue).scaleEffect(0.8)
                    Text(processingMessage)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(ConverterPalette.blue)
                }
            }
        }
        .padding(12)
        .background(ConverterPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ConverterPalette.green.opacity(0.28), lineWidth: 1)
        )
    }

    private func upgradeCard(_ entry: IshaSkinUpgradeEntry) -> some View {
        let targets = (entry.targets ?? []).filter { validTarget($0) }
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                IshaCatalogRemoteImage(urlString: entry.base_image)
                    .frame(width: 48, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.10), lineWidth: 1))

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.hero.uppercased())
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundColor(ConverterPalette.blue)
                    Text(entry.base_name)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(ConverterPalette.text)
                        .lineLimit(2)
                    Text("BASE SKIN")
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                        .foregroundColor(ConverterPalette.muted)
                }

                Spacer(minLength: 0)

                if selectedReplacements[entry.id] != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(ConverterPalette.green)
                }
            }

            HStack {
                Text("REPLACE WITH")
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .foregroundColor(ConverterPalette.muted)
                Spacer()
                Text("\(targets.count) OPTIONS")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundColor(ConverterPalette.muted)
            }

            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(targets) { target in
                    targetButton(target, for: entry)
                }
            }
        }
        .padding(10)
        .background(ConverterPalette.field)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func targetButton(_ target: IshaSkinUpgradeTarget, for entry: IshaSkinUpgradeEntry) -> some View {
        let selected = selectedReplacements[entry.id] == target.id
        return Button {
            guard !isApplying else { return }
            if selected {
                selectedReplacements.removeValue(forKey: entry.id)
            } else {
                selectedReplacements[entry.id] = target.id
            }
        } label: {
            HStack(spacing: 7) {
                IshaCatalogRemoteImage(urlString: target.image)
                    .frame(width: 34, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(target.name)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(selected ? ConverterPalette.green : ConverterPalette.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text((target.type ?? "UPGRADE").uppercased())
                        .font(.system(size: 7, weight: .heavy, design: .rounded))
                        .foregroundColor(ConverterPalette.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(selected ? ConverterPalette.green : ConverterPalette.muted)
            }
            .padding(7)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(selected ? ConverterPalette.green.opacity(0.10) : ConverterPalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? ConverterPalette.green.opacity(0.65) : .white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isApplying)
    }

    private var loadingState: some View {
        VStack(spacing: 9) {
            ProgressView().tint(ConverterPalette.blue)
            Text("Loading all skin replacement options…")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(ConverterPalette.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(ConverterPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Replacement catalog unavailable")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(ConverterPalette.text)
            Text(message)
                .font(.system(size: 10))
                .foregroundColor(ConverterPalette.muted)
            Button("RETRY") {
                Task { await loadCatalog() }
            }
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundColor(ConverterPalette.blue)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ConverterPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 25))
                .foregroundColor(ConverterPalette.muted)
            Text("No matching base skins")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(ConverterPalette.text)
            Text("Try another hero, base skin or target name.")
                .font(.system(size: 10))
                .foregroundColor(ConverterPalette.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(ConverterPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("BATCH CONVERSION NOTES")
                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                .foregroundColor(ConverterPalette.muted)
            Text("Choose one replacement per base skin. You can combine different base skins and heroes in one batch. Original downloaded ZIP files are kept in Script Skin Downloads / Multi Replace Originals.")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(ConverterPalette.muted.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    @MainActor
    private func loadCatalog() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            var request = URLRequest(url: catalogURL)
            request.timeoutInterval = 45
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw IshaCatalogError.invalidResponse
            }
            let decoded = try JSONDecoder().decode(IshaSkinUpgradeCatalogResponse.self, from: data)
            entries = decoded.skin_upgrades
            errorMessage = nil
        } catch {
            errorMessage = "Could not refresh the replacement catalog. Check internet connection. (\(error.localizedDescription))"
        }
    }

    private func validTarget(_ target: IshaSkinUpgradeTarget) -> Bool {
        guard target.enabled != false,
              let address = target.script,
              let url = URL(string: address),
              url.scheme?.lowercased() == "https" else { return false }
        return url.pathExtension.lowercased() == "zip"
    }

    @MainActor
    private func downloadAndConvert() async {
        guard !isApplying else { return }
        let jobs = selectedJobs
        guard !jobs.isEmpty else { return }

        isApplying = true
        errorMessage = nil
        statusMessage = nil
        processingMessage = "Preparing \(jobs.count) skin replacement(s)…"

        var stagingRoot: URL?
        defer {
            isApplying = false
            processingMessage = nil
            if let stagingRoot {
                try? FileManager.default.removeItem(at: stagingRoot)
            }
        }

        do {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let batchID = String(UUID().uuidString.prefix(10))
            let batchName = "Multi_Replace_\(batchID)"
            let staging = documents
                .appendingPathComponent("Multi Replace Staging", isDirectory: true)
                .appendingPathComponent(batchName, isDirectory: true)
            stagingRoot = staging

            let archiveFolder = staging.appendingPathComponent("archives", isDirectory: true)
            let backupFolder = documents
                .appendingPathComponent("Script Skin Downloads", isDirectory: true)
                .appendingPathComponent("Multi Replace Originals", isDirectory: true)
                .appendingPathComponent(batchName, isDirectory: true)
            try FileManager.default.createDirectory(at: archiveFolder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)

            let marker = staging.appendingPathComponent(".isha_multi_replace_manifest.json")
            try Data("isha-multi-replace-v1".utf8).write(to: marker, options: .atomic)

            var totalBytes: Int64 = 0
            for (index, job) in jobs.enumerated() {
                guard let address = job.target.script,
                      let url = URL(string: address),
                      url.scheme?.lowercased() == "https",
                      url.pathExtension.lowercased() == "zip" else {
                    throw IshaCatalogError.invalidResponse
                }

                processingMessage = "Downloading \(index + 1)/\(jobs.count): \(job.target.name)"
                let (temporaryURL, response) = try await URLSession.shared.download(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw IshaCatalogError.invalidResponse
                }

                let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
                let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                guard fileSize > 0, fileSize <= 2_000_000_000 else {
                    throw IshaCatalogError.invalidArchiveSize
                }
                totalBytes += fileSize
                guard totalBytes <= 2_000_000_000 else {
                    throw IshaCatalogError.multiReplaceBatchTooLarge
                }

                let archiveName = safeFileName(
                    job.entry.hero + " - " + job.entry.base_name + " to " + job.target.name
                ) + ".zip"
                let original = backupFolder.appendingPathComponent(archiveName)
                let staged = archiveFolder.appendingPathComponent(archiveName)

                if FileManager.default.fileExists(atPath: original.path) {
                    try FileManager.default.removeItem(at: original)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: original)
                try FileManager.default.copyItem(at: original, to: staged)
            }

            processingMessage = "Converting all \(jobs.count) selected skin replacements to iOS…"
            let outputDirectory = documents
                .appendingPathComponent("Isha Converter iOS", isDirectory: true)
                .appendingPathComponent("Auto Converted Multi Replace", isDirectory: true)
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

            let conversionResult: Result<URL, Error> = await withCheckedContinuation { continuation in
                PythonConverter.shared.convert(input: staging, outputDirectory: outputDirectory) { result in
                    continuation.resume(returning: result)
                }
            }

            switch conversionResult {
            case .success(let convertedURL):
                shareURL = convertedURL
                showShareSheet = true
                statusMessage = "Completed: \(jobs.count) replacement archive(s) were combined and converted into one iOS-ready ZIP. Original ZIP files are backed up."
                selectedReplacements.removeAll()
            case .failure(let conversionError):
                errorMessage = "The selected archives were downloaded, but the combined conversion failed. The original ZIP files are backed up. \(conversionError.localizedDescription)"
            }
        } catch {
            errorMessage = "Multi Replace stopped. \(error.localizedDescription)"
        }
    }

    private func safeFileName(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(
            of: "[^A-Za-z0-9._ -]",
            with: "_",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Skin" : cleaned
    }
}
