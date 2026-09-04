import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let aagedalFTPSyncConfiguration = UTType(
        exportedAs: "no.aagedal.aftpsync.configuration",
        conformingTo: .data
    )
}

struct ConfigurationTransferFile: FileDocument {
    static var readableContentTypes: [UTType] { [.aagedalFTPSyncConfiguration] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct RedactedSupportBundleFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum ConfigurationTransferOperation {
    case export(ConfigurationTransferScope)
    case importPackage(Data, ConfigurationTransferProtection)
}

struct PendingConfigurationTransfer: Identifiable {
    let id = UUID()
    let operation: ConfigurationTransferOperation
}

struct ConfigurationTransferOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let operation: ConfigurationTransferOperation
    let onExport: (ConfigurationTransferScope, String?) -> Bool
    let onImport: (Data, String?) -> Bool

    @State private var encryptPackage = true
    @State private var password = ""
    @State private var confirmation = ""
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: titleSymbol)
                .font(.title2.weight(.semibold))

            Text(explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isExport {
                Toggle("Encrypt package with a password", isOn: $encryptPackage)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("encrypt-configuration")
            }

            if requiresPassword {
                SecureField("Package password", text: $password)
                    .textContentType(.password)
            }

            if isExport && encryptPackage {
                SecureField("Confirm password", text: $confirmation)
                    .textContentType(.newPassword)
            }

            if !requiresPassword {
                Label(
                    "This package is not encrypted. Anyone who can open it can read its server addresses, usernames, paths, and metadata programming.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .labelStyle(AccessibleStatusLabelStyle(symbolColor: .orange))
                .fixedSize(horizontal: false, vertical: true)
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .labelStyle(AccessibleStatusLabelStyle(symbolColor: .red))
            }

            Text(securityNote)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(actionTitle, action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(requiresPassword && password.isEmpty)
                    .accessibilityIdentifier("configuration-transfer-submit")
            }
        }
        .padding(24)
        .frame(width: dynamicTypeSize.isAccessibilitySize ? 640 : 480)
    }

    private var isExport: Bool {
        if case .export = operation { return true }
        return false
    }

    private var title: String {
        switch operation {
        case .export(let scope): "Export \(scope.title)"
        case .importPackage(_, .encrypted): "Import Encrypted Package"
        case .importPackage(_, .unencrypted): "Import Unencrypted Package"
        }
    }

    private var titleSymbol: String {
        switch operation {
        case .export: encryptPackage ? "lock.doc" : "doc"
        case .importPackage(_, .encrypted): "lock.open"
        case .importPackage(_, .unencrypted): "doc"
        }
    }

    private var requiresPassword: Bool {
        switch operation {
        case .export: encryptPackage
        case .importPackage(_, .encrypted): true
        case .importPackage(_, .unencrypted): false
        }
    }

    private var actionTitle: String { isExport ? "Continue to Save" : "Import" }

    private var explanation: String {
        switch operation {
        case .export where encryptPackage:
            "Encryption is recommended. Choose a password that will be required when this package is imported."
        case .export:
            "You can export without encryption because passwords and folder-access bookmarks are excluded."
        case .importPackage:
            "Imported jobs are added as disabled copies. A metadata-only package replaces programming on jobs matched by ID or a unique job name."
        }
    }

    private var securityNote: String {
        "Server passwords and folder-access bookmarks are never exported. Imported jobs require folder access and server passwords to be configured again."
    }

    private func submit() {
        validationMessage = nil
        switch operation {
        case .export(let scope):
            if encryptPackage {
                guard password.count >= ConfigurationTransferCodec.minimumPasswordLength else {
                    validationMessage = "Use at least \(ConfigurationTransferCodec.minimumPasswordLength) characters."
                    return
                }
                guard password == confirmation else {
                    validationMessage = "The passwords do not match."
                    return
                }
            }
            if onExport(scope, encryptPackage ? password : nil) { dismiss() }
        case .importPackage(let data, let protection):
            if onImport(data, protection == .encrypted ? password : nil) { dismiss() }
        }
    }
}
