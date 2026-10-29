import SwiftUI
import UniformTypeIdentifiers
import UIKit
import Combine
import Security

private enum IshaLicenseConfiguration {
    // Set these two values after deploying the Supabase functions.
    // The publishable key is intended for client use. NEVER put a secret/service-role key here.
    static let validationURL = "https://YOUR_PROJECT_REF.supabase.co/functions/v1/validate-license"
    static let publishableKey = "YOUR_SUPABASE_PUBLISHABLE_KEY"

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
                    Text("ISHA CONVERTER IOS")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.5)
                        .foregroundColor(muted.opacity(0.65))
                        .padding(.top, 2)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 28)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomDock
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 7)
                .background(
                    LinearGradient(
                        colors: [background.opacity(0), background.opacity(0.96), background],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea(edges: .bottom)
                )
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

    private var bottomDock: some View {
        HStack(spacing: 0) {
            dockIcon("house.fill", selected: true)
            dockIcon("tshirt.fill")
            dockIcon("arrow.down.circle.fill")
            dockIcon("list.bullet")
            dockIcon("folder.fill")
            dockIcon("info.circle.fill")
        }
        .padding(.horizontal, 8)
        .frame(height: 70)
        .background(
            Capsule()
                .fill(ConverterPalette.panel.opacity(0.98))
        )
        .overlay(
            Capsule().stroke(ConverterPalette.muted.opacity(0.22), lineWidth: 1.2)
        )
        .shadow(color: .black.opacity(0.24), radius: 18, y: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Isha Converter iOS navigation bar")
    }

    private func dockIcon(_ symbol: String, selected: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 27, weight: .semibold))
            .foregroundColor(selected ? ConverterPalette.blue : ConverterPalette.muted.opacity(0.95))
            .frame(maxWidth: .infinity, minHeight: 56)
            .accessibilityHidden(true)
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
