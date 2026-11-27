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

    @State private var tagEditingTarget: IshaCatalogTagEditTarget?
    @State private var tagInfoTarget: IshaCatalogTagInfoTarget?
    @State private var showMultiReplaceLibrary = false
    @State private var heroes: [IshaCatalogHero] = []
    @State private var tagLibraryCache: [IshaCatalogTag] = []
    @State private var tagByIDCache: [String: IshaCatalogTag] = [:]
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
    @State private var shareURL: URL?
    @State private var showShareSheet = false
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
        (assignmentsCache[skin.stableID] ?? []).compactMap { tagByIDCache[$0]?.name }
    }

    @MainActor
    private func rebuildCatalogCaches(for catalog: [IshaCatalogHero]) {
        let heroNames = Set(catalog.map { $0.name.lowercased() })
        let genericNames: Set<String> = ["assassin", "fighter", "mage", "marksman", "tank", "support", "basic", "backup"]
        var unique: [String: IshaCatalogTag] = [:]

        for hero in catalog {
            for skin in hero.skins {
                for tag in skin.tags ?? [] {
                    let name = tag.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let key = name.lowercased()
                    guard !name.isEmpty, !heroNames.contains(key), !genericNames.contains(key) else { continue }
                    if let existing = unique[tag.stableID] {
                        if (existing.icon ?? "").isEmpty && !(tag.icon ?? "").isEmpty {
                            unique[tag.stableID] = tag
                        }
                    } else {
                        unique[tag.stableID] = tag
                    }
                }
            }
        }

        let library = unique.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        tagLibraryCache = library
        tagByIDCache = Dictionary(uniqueKeysWithValues: library.map { ($0.stableID, $0) })

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
                    if let name = tagByIDCache[id]?.name { values.insert(name) }
                }
            }
        }
        for tag in tagLibraryCache { values.insert(tag.name) }
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
        let heroKey = heroName.lowercased()
        let categoryKey = (category ?? "").lowercased()
        var result: [IshaCatalogTag] = []

        for tag in skin.tags ?? [] {
            let name = tag.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.lowercased() != heroKey, name.lowercased() != categoryKey,
                  !result.contains(where: { $0.stableID == tag.stableID }) else { continue }
            result.append(tag)
        }

        for tagID in assignmentsCache[skin.stableID] ?? [] {
            guard let tag = tagByIDCache[tagID],
                  !result.contains(where: { $0.stableID == tag.stableID }) else { continue }
            result.insert(tag, at: 0)
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
        .sheet(isPresented: $showShareSheet) {
            if let shareURL {
                ActivityView(activityItems: [shareURL])
            }
        }
        .sheet(item: $tagEditingTarget) { target in
            IshaSkinTagPickerView(
                skinName: target.skin.skin_name ?? "Custom Skin",
                heroName: target.heroName,
                tags: tagLibrary,
                initialSelection: selectedTagIDs(for: target.skin),
                onCancel: { tagEditingTarget = nil },
                onSave: { ids in
                    saveTagAssignments(ids, for: target.skin)
                    tagEditingTarget = nil
                }
            )
        }
        .sheet(item: $tagInfoTarget) { target in
            IshaSkinTagInfoSheet(
                tag: target.tag,
                heroName: target.heroName,
                skinName: target.skinName,
                skinImage: target.skinImage
            )
        }
        .sheet(isPresented: $showMultiReplaceLibrary) {
            IshaMultiReplaceLibraryView()
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
                showMultiReplaceLibrary = true
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 11) {
                IshaCatalogRemoteImage(urlString: skin.image)
                    .frame(width: 64, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.10), lineWidth: 1))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top, spacing: 5) {
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
                        Spacer(minLength: 2)
                        IshaSkinTagBadgeStack(
                            tags: visibleSkinTags(for: skin, heroName: heroName, category: category),
                            onTap: { tag in
                                tagInfoTarget = IshaCatalogTagInfoTarget(
                                    tag: tag,
                                    heroName: heroName,
                                    skinName: skin.skin_name ?? "Custom Skin",
                                    skinImage: skin.image
                                )
                            }
                        )
                    }

                    Text(heroName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(ConverterPalette.muted)

                    Button {
                        tagEditingTarget = IshaCatalogTagEditTarget(
                            skin: skin,
                            heroName: heroName,
                            category: category
                        )
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "tag.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text("EDIT SKIN TAGS")
                                .font(.system(size: 8, weight: .heavy, design: .rounded))
                            Text("\(selectedTagIDs(for: skin).count)")
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

                shareURL = convertedURL
                showShareSheet = true
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

        let sourceTags = (tags ?? []).map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        for tag in sourceTags where !tag.isEmpty {
            if tag.caseInsensitiveCompare(heroName) != .orderedSame &&
               tag.caseInsensitiveCompare(category ?? "") != .orderedSame {
                appendUnique(tag.capitalized)
            }
        }

        if sourceTags.filter({ !$0.isEmpty }).isEmpty {
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

    var displayName: String {
        stableID.contains("anniversary") ? "10TH ANNIVERSARY" : name.uppercased()
    }

    var infoTitle: String {
        let normalized = (name + " " + (file ?? "")).lowercased()
        if stableID.contains("anniversary") || normalized.contains("10th anniversary") || normalized.contains("epic 10th") {
            return "10th Anniversary Skin"
        }
        if let supplied = description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !supplied.isEmpty {
            return name
        }
        return name.localizedCaseInsensitiveContains("skin") ? name : "\(name) Skin"
    }

    var infoDescription: String {
        if let supplied = description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !supplied.isEmpty {
            return supplied
        }
        let normalized = (name + " " + (file ?? "")).lowercased()
        if stableID.contains("anniversary") || normalized.contains("10th anniversary") || normalized.contains("epic 10th") {
            return "10th Anniversary-themed exclusive Epic skin."
        }
        switch stableID {
        case "epic":
            return "This badge identifies the skin as an Epic-tier skin."
        case "collector":
            return "This badge identifies the skin as part of the Collector series."
        case "starlight":
            return "This badge identifies the skin as part of the Starlight series."
        case "annual-starlight":
            return "This badge identifies the skin as part of the Annual Starlight series."
        default:
            return "This badge identifies the skin's \(name) category in the catalog."
        }
    }

    var stableID: String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let slug = value.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? (tagID ?? "tag") : slug
    }

    var id: String { stableID }
}

private struct IshaCatalogTagEditTarget: Identifiable {
    let skin: IshaCatalogSkin
    let heroName: String
    let category: String?
    var id: String { skin.stableID }
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

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The catalog or download server returned an invalid response."
        case .invalidArchiveSize: return "The downloaded archive is empty or exceeds the 2 GB safety limit."
        case .emptyCatalog: return "The catalog contains no heroes."
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
        HStack(spacing: 4) {
            ForEach(Array(tags.prefix(2))) { tag in
                Button {
                    onTap(tag)
                } label: {
                    HStack(spacing: 3) {
                        IshaCatalogTagArtwork(tag: tag)
                            .frame(width: 26, height: 17)
                        Text(tag.displayName)
                            .font(.system(size: 7, weight: .heavy, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.84))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(ConverterPalette.blue.opacity(0.28), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View \(tag.displayName) skin tag details")
            }

            if tags.count > 2 {
                Text("+\(tags.count - 2)")
                    .font(.system(size: 7, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.84))
                    .clipShape(Capsule())
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
        tag.stableID.contains("anniversary")
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
                            .frame(width: 138, height: 78)
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
                            Text(tag.name.uppercased())
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
        return tags.filter { $0.name.localizedCaseInsensitiveContains(query) }
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

                Text(tag.name)
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

    var body: some View {
        AsyncImage(url: URL(string: tag.icon ?? "")) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
            case .empty, .failure:
                fallback
            @unknown default:
                fallback
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fallback: some View {
        let isAnniversary = tag.stableID.contains("anniversary")
        return ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(ConverterPalette.panel)
            Image(systemName: isAnniversary ? "diamond.fill" : "tag.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(
                    isAnniversary
                        ? Color(red: 0.68, green: 0.43, blue: 1.0)
                        : ConverterPalette.blue.opacity(0.85)
                )
        }
    }
}
