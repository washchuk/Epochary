import AppKit
import EpocharyKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            KeysSettingsView()
                .tabItem { Label("Keys", systemImage: "key") }
            ArchiveSettingsView()
                .tabItem { Label("Archive", systemImage: "archivebox") }
            ToolsSettingsView()
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 600, height: 440)
    }
}

// MARK: - Keys

struct KeysSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: KeySheet?
    @State private var selection: Recipient.ID?
    @State private var importError: String?

    enum KeySheet: String, Identifiable {
        case add, generate
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Archives are encrypted to the public keys you choose. Epochary never stores private keys. "
                 + "Encrypt to at least two keys kept in different places: an archive can't be opened without one of them.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(selection: $selection) {
                ForEach(model.keys.recipients) { recipient in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recipient.label.isEmpty ? "Unlabeled key" : recipient.label)
                        Text(recipient.publicKey)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .tag(recipient.id)
                    .contextMenu {
                        Button("Copy Public Key") { copy(recipient.publicKey) }
                        Button("Remove", role: .destructive) { remove(recipient.id) }
                    }
                }
            }
            .onDeleteCommand { selection.map(remove) }
            .overlay {
                if model.keys.recipients.isEmpty {
                    Text("No keys").foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Generate New Key…") { sheet = .generate }
                Button("Add Public Key…") { sheet = .add }
                Button("Import from Identity File…") { importIdentity() }
                Spacer()
                Button("Remove") { selection.map(remove) }
                    .disabled(selection == nil)
            }
            if let importError {
                Text(importError).foregroundStyle(.red)
            }
        }
        .padding()
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .add: AddKeySheet()
            case .generate: GenerateKeySheet()
            }
        }
    }

    private func remove(_ id: Recipient.ID) {
        model.keys.remove(id)
        model.selectedRecipientIDs.remove(id)
        if selection == id { selection = nil }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Reads only the public key out of an existing age identity file.
    private func importIdentity() {
        let panel = NSOpenPanel()
        panel.message = "Choose an age identity file. Only its public key is saved."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importError = nil
        Task {
            do {
                let key = try await KeyGenerator.publicKey(forIdentityAt: url, tools: model.preferences.toolLocator)
                guard !model.keys.contains(publicKey: key) else {
                    importError = "That key is already in the list."
                    return
                }
                let recipient = Recipient(label: url.deletingPathExtension().lastPathComponent, publicKey: key)
                model.keys.add(recipient)
                model.selectedRecipientIDs.insert(recipient.id)
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

struct AddKeySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var publicKey = ""
    @State private var error: String?
    @State private var isChecking = false

    var body: some View {
        Form {
            TextField("Label", text: $label, prompt: Text("e.g. Home YubiKey"))
            TextField("Public key", text: $publicKey, prompt: Text("age1… or ssh-ed25519 …"), axis: .vertical)
                .font(.body.monospaced())
                .lineLimit(2...4)
            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { add() }
                    .disabled(!Recipient.looksLikePublicKey(publicKey) || isChecking)
            }
        }
    }

    private func add() {
        let key = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.keys.contains(publicKey: key) else {
            error = "That key is already in the list."
            return
        }
        isChecking = true
        Task {
            defer { isChecking = false }
            do {
                try await RecipientValidator.validate(key, tools: model.preferences.toolLocator)
                let recipient = Recipient(label: label, publicKey: key)
                model.keys.add(recipient)
                model.selectedRecipientIDs.insert(recipient.id)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct GenerateKeySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var postQuantum = false
    @State private var created: (url: URL, publicKey: String)?
    @State private var error: String?

    var body: some View {
        Form {
            if let created {
                Section {
                    Label("Key created", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    LabeledContent("Private key file", value: created.url.path(percentEncoded: false))
                    LabeledContent("Public key") {
                        Text(created.publicKey).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                Section {
                    Text("Back up the private key file now and keep copies somewhere safe, such as a password "
                         + "manager or printed on paper. Without it, archives encrypted to this key can never be opened.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                TextField("Label", text: $label, prompt: Text("e.g. Archive key 2025"))
                Toggle(isOn: $postQuantum) {
                    Text("Post-quantum key")
                    Text("A hybrid ML-KEM-768 + X25519 key that resists future quantum computers. "
                         + "Decrypting needs age 1.3 or newer, and the public key is much longer.")
                }
                Text("You'll choose where to save the private key file next. Epochary keeps only the public key.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            if created != nil {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            } else {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Generate…") { generate() } }
            }
        }
    }

    private func generate() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(label.isEmpty ? "age-key" : label).txt"
        panel.message = "Save the private key file somewhere safe."
        panel.prompt = "Save Key"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                // The save panel already confirmed replacing; age-keygen still refuses to overwrite.
                let key = try await KeyGenerator.generateIdentity(at: url, postQuantum: postQuantum,
                                                                  tools: model.preferences.toolLocator)
                let recipient = Recipient(label: label.isEmpty ? url.deletingPathExtension().lastPathComponent : label,
                                          publicKey: key)
                model.keys.add(recipient)
                model.selectedRecipientIDs.insert(recipient.id)
                created = (url, key)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Archive defaults

struct ArchiveSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Section {
                Picker("Compression level", selection: $preferences.compressionLevel) {
                    ForEach(1...22, id: \.self) { level in
                        Text(levelLabel(level)).tag(level)
                    }
                }
                Toggle(isOn: $preferences.longWindow) {
                    Text("Long-distance matching (--long=31)")
                    Text("Finds repeats up to 2 GiB apart for better compression. Restoring needs “zstd -d --long=31” "
                         + "and about 2 GiB of memory; the README says so.")
                }
            } header: {
                Text("Zstandard")
            }
            Section {
                Toggle(isOn: $preferences.verify) {
                    Text("Verify while archiving")
                    Text("Decompresses the stream and reads every tar header as it's written, so a bad archive is never kept.")
                }
                Toggle(isOn: $preferences.excludeFinderMetadata) {
                    Text("Skip .DS_Store files")
                    Text("Finder view settings, not your data.")
                }
            } header: {
                Text("Archive")
            }
        }
        .formStyle(.grouped)
    }

    private func levelLabel(_ level: Int) -> String {
        switch level {
        case 3: "3 (zstd default)"
        case 19: "19 (recommended)"
        case 20...22: "\(level) (ultra, very slow)"
        default: "\(level)"
        }
    }
}

// MARK: - Tools

struct ToolsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var versions: [Tool: String] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(Tool.allCases, id: \.self) { tool in
                    ToolRow(tool: tool, version: versions[tool])
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Install everything with Homebrew:")
                    Text("brew install gnu-tar zstd age par2")
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: model.preferences.toolOverrides) { await loadVersions() }
    }

    private func loadVersions() async {
        let locator = model.preferences.toolLocator
        var found: [Tool: String] = [:]
        for tool in Tool.allCases {
            found[tool] = await locator.version(of: tool)
        }
        versions = found
    }
}

struct ToolRow: View {
    @Environment(AppModel.self) private var model
    let tool: Tool
    let version: String?

    var body: some View {
        let path = model.preferences.toolLocator.locate(tool)
        LabeledContent {
            HStack {
                if model.preferences.toolOverrides[tool] != nil {
                    Button("Reset") { model.preferences.toolOverrides[tool] = nil }
                }
                Button("Choose…") { choose() }
            }
        } label: {
            HStack {
                Image(systemName: path == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(path == nil ? (tool.isRequiredForArchiving ? .red : .orange) : .green)
                VStack(alignment: .leading) {
                    Text(tool.executableName).font(.body.monospaced())
                    Text(path.map { "\($0.path)\(version.map { " · \($0)" } ?? "")" }
                         ?? (tool.isRequiredForArchiving ? "Not found (required)" : "Not found (optional)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.message = "Choose the \(tool.executableName) executable."
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            model.preferences.toolOverrides[tool] = url.path
        }
    }
}
