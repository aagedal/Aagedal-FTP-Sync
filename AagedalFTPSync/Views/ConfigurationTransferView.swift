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

enum ConfigurationTransferOperation {
    case export(ConfigurationTransferScope)
    case importPackage(Data)
}

struct PendingConfigurationTransfer: Identifiable {
    let id = UUID()
    let operation: ConfigurationTransferOperation
}

struct ConfigurationTransferPasswordView: View {
    @Environment(\.dismiss) private var dismiss

    let operation: ConfigurationTransferOperation
    let onExport: (ConfigurationTransferScope, String) -> Bool
    let onImport: (Data, String) -> Bool

    @State private var password = ""
    @State private var confirmation = ""
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: isExport ? "lock.doc" : "lock.open")
                .font(.title2.weight(.semibold))

            Text(explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Package password", text: $password)
                .textContentType(.password)

            if isExport {
                SecureField("Confirm password", text: $confirmation)
                    .textContentType(.newPassword)
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Text(securityNote)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(actionTitle, action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var isExport: Bool {
        if case .export = operation { return true }
        return false
    }

    private var title: String {
        switch operation {
        case .export(let scope): "Export \(scope.title)"
        case .importPackage: "Import Encrypted Package"
        }
    }

    private var actionTitle: String { isExport ? "Continue to Save" : "Import" }

    private var explanation: String {
        switch operation {
        case .export:
            "Choose a password for this encrypted package. The same password is required when it is imported."
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
            guard password.count >= EncryptedConfigurationTransferCodec.minimumPasswordLength else {
                validationMessage = "Use at least \(EncryptedConfigurationTransferCodec.minimumPasswordLength) characters."
                return
            }
            guard password == confirmation else {
                validationMessage = "The passwords do not match."
                return
            }
            if onExport(scope, password) { dismiss() }
        case .importPackage(let data):
            if onImport(data, password) { dismiss() }
        }
    }
}
