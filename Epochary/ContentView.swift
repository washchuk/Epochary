import AppKit
import EpocharyKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .editing: ComposeView()
            case .running(let progress): RunningView(progress: progress)
            case .finished(let result): FinishedView(result: result)
            case .failed(let message): FailedView(message: message)
            }
        }
        .frame(minWidth: 560, minHeight: 640)
    }
}

// MARK: - Compose

struct ComposeView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<AppModel.SourceItem.ID>()
    @State private var isTargeted = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if !model.missingRequiredTools.isEmpty {
                MissingToolsBanner(tools: model.missingRequiredTools)
            }
            sources
                .frame(minHeight: 170)
                .dropDestination(for: URL.self) { urls, _ in
                    model.add(urls.filter(\.isFileURL))
                    return true
                } isTargeted: { isTargeted = $0 }
            Divider()
            Form {
                TextField("Archive name", text: $model.name)
                LabeledContent("Save to") {
                    HStack {
                        if let destination = model.destination {
                            Text(destination.path(percentEncoded: false))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(destination.path(percentEncoded: false))
                        } else {
                            Text("Not chosen").foregroundStyle(.secondary)
                        }
                        Button("Choose…") { model.chooseDestination() }
                    }
                }
                RecipientsSection()
                Picker("Recovery data", selection: $model.parityPercent) {
                    Text("None").tag(0)
                    ForEach(ArchiveRequest.parityOptions, id: \.self) { Text("\($0)% (PAR2)").tag($0) }
                }
                Toggle(isOn: $model.stopOnSourceChange) {
                    Text("Stop if files change")
                    Text("Stops and keeps nothing if a file changes or disappears while it's being archived. "
                         + "Otherwise the archive is finished and the changed files are listed.")
                }
                SegmentsSection()
            }
            .formStyle(.grouped)
            .frame(minHeight: 300)
            .layoutPriority(1)
            footer
        }
    }

    @ViewBuilder private var sources: some View {
        if model.items.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "archivebox")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Drop files and folders to archive")
                    .font(.title3)
                Button("Choose…") { model.chooseItems() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                                  style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(isTargeted ? Color.accentColor.opacity(0.08) : .clear,
                                in: RoundedRectangle(cornerRadius: 12))
            }
            .padding()
        } else {
            VStack(spacing: 0) {
                List(model.items, selection: $selection) { item in
                    SourceRow(item: item)
                }
                .onDeleteCommand { model.remove(selection) }
                .overlay {
                    if isTargeted {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
                HStack {
                    Button { model.chooseItems() } label: { Image(systemName: "plus") }
                    Button { model.remove(selection) } label: { Image(systemName: "minus") }
                        .disabled(selection.isEmpty)
                    Spacer()
                    if let total = model.totalStats {
                        Text("\(total.files) files, \(total.bytes.formatted(.byteCount(style: .file)))")
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let blocker = model.blocker {
                Text(blocker).foregroundStyle(.secondary)
            } else if let warning = model.spaceWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Create Archive") { model.start() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.blocker != nil)
        }
        .padding()
    }
}

struct SourceRow: View {
    let item: AppModel.SourceItem

    var body: some View {
        HStack {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading) {
                Text(item.url.lastPathComponent)
                Text(item.url.deletingLastPathComponent().path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let stats = item.stats {
                Text(stats.bytes.formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }
}

struct RecipientsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Encrypt to") {
            if model.keys.recipients.isEmpty {
                HStack {
                    Text("No keys yet.").foregroundStyle(.secondary)
                    Spacer()
                    SettingsLink { Text("Add a Key…") }
                }
            } else {
                ForEach(model.keys.recipients) { recipient in
                    Toggle(isOn: binding(for: recipient.id)) {
                        Text(recipient.label.isEmpty ? "Unlabeled key" : recipient.label)
                        Text(recipient.publicKey.abbreviatedKey)
                            .font(.caption.monospaced())
                    }
                }
            }
        }
    }

    private func binding(for id: Recipient.ID) -> Binding<Bool> {
        Binding {
            model.selectedRecipientIDs.contains(id)
        } set: { isOn in
            if isOn { model.selectedRecipientIDs.insert(id) } else { model.selectedRecipientIDs.remove(id) }
        }
    }
}

struct SegmentsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            Toggle("Split into segments", isOn: $model.splitIntoSegments)
            if model.splitIntoSegments {
                Picker("Medium", selection: $model.medium) {
                    ForEach(Medium.allCases) { Text($0.name).tag($0) }
                }
                if model.medium == .custom {
                    LabeledContent("Capacity") {
                        HStack {
                            TextField("Capacity", value: $model.customCapacity, format: .number)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                            Picker("Unit", selection: $model.customCapacityUnit) {
                                ForEach(CapacityUnit.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
                LabeledContent("Segment size") {
                    Text(model.segmentSize?.formatted(.byteCount(style: .file)) ?? "Medium too small")
                        .monospacedDigit()
                }
                Picker("Write segments", selection: $model.pauseAfterEachSegment) {
                    Text("All at once").tag(false)
                    Text("One at a time").tag(true)
                }
                .pickerStyle(.segmented)
            }
        } footer: {
            if model.splitIntoSegments {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: String {
        let room = model.parityPercent > 0
            ? "Each segment leaves room on its medium for its recovery data, README and 3% free space."
            : "Each segment leaves room on its medium for its README and 3% free space."
        let mode = model.pauseAfterEachSegment
            ? "Epochary pauses after each segment so you can copy its folder to the medium and delete it, "
                + "so only one segment needs disk space at a time."
            : "All segments are written before you copy them, so the destination needs room for the whole archive."
        return room + " " + mode
    }
}

struct MissingToolsBanner: View {
    let tools: [Tool]

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text("Missing \(tools.map(\.executableName).formatted(.list(type: .and))). Install with Homebrew:")
                Text("brew install \(Set(tools.map(\.homebrewFormula)).sorted().joined(separator: " "))")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            Spacer()
            SettingsLink { Text("Settings…") }
        }
        .padding()
        .background(.yellow.opacity(0.12))
    }
}

// MARK: - Running

struct RunningView: View {
    @Environment(AppModel.self) private var model
    let progress: ArchiveProgress

    var body: some View {
        if progress.stage == .waitingForNextSegment, let segment = progress.waitingSegment {
            SegmentReadyView(segment: segment, estimatedSegments: progress.estimatedSegments)
        } else {
            working
        }
    }

    private var working: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "lock.doc")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.title3)
            if let segment = progress.currentSegment {
                Text("Segment \(segment) of up to \(progress.estimatedSegments ?? segment)")
                    .foregroundStyle(.secondary)
            }
            Group {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            .frame(maxWidth: 360)
            Text(detail)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Cancel") { model.cancel() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    private var title: String {
        switch progress.stage {
        case .preparing: "Preparing…"
        case .archiving: "Archiving, compressing and encrypting…"
        case .finishingSegment: "Creating recovery data for the segment…"
        case .waitingForNextSegment: "Segment ready"
        case .finishing: "Writing checksums…"
        case .creatingParity: "Creating recovery data…"
        case .done: "Done"
        }
    }

    private var detail: String {
        switch progress.stage {
        case .archiving where progress.bytesRead >= progress.estimatedTotal:
            // zstd reads ahead by up to its window, so reading finishes well before writing does.
            "Compressing the last of the data, \(progress.bytesWritten.formatted(.byteCount(style: .file))) written"
        case .archiving:
            "\(progress.bytesRead.formatted(.byteCount(style: .file))) of about "
                + "\(progress.estimatedTotal.formatted(.byteCount(style: .file))) read, "
                + "\(progress.bytesWritten.formatted(.byteCount(style: .file))) written"
        case .creatingParity, .finishingSegment:
            progress.parityFraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? ""
        default: " "
        }
    }
}

struct SegmentReadyView: View {
    @Environment(AppModel.self) private var model
    let segment: CompletedSegment
    let estimatedSegments: Int?
    @State private var confirmingDelete = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Segment \(segment.number) is ready").font(.title2)
            Text("Copy the folder “\(segment.folder.lastPathComponent)” to its medium, then continue to write "
                 + "segment \(segment.number + 1). Check the copy on the medium with the .sha256 file inside it.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("Folder").foregroundStyle(.secondary)
                        Text(segment.folder.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    GridRow {
                        Text("Segment").foregroundStyle(.secondary)
                        Text(segment.bytes.formatted(.byteCount(style: .file))).monospacedDigit()
                    }
                    GridRow {
                        Text("Folder size").foregroundStyle(.secondary)
                        Text(directorySize(segment.folder).formatted(.byteCount(style: .file))).monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            .frame(maxWidth: 480)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([segment.folder]) }
            if let error {
                Text(error).foregroundStyle(.red)
            }
            Spacer()
            HStack {
                Button("Cancel Archive", role: .destructive) { model.cancel() }
                Spacer()
                Button("Delete from Disk and Continue…") { confirmingDelete = true }
                Button("Continue") { proceed(deleting: false) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .confirmationDialog("Delete segment \(segment.number) from disk?", isPresented: $confirmingDelete) {
            Button("Delete and Continue", role: .destructive) { proceed(deleting: true) }
        } message: {
            Text("Only do this once the folder is safely copied to its medium. "
                 + "The archive can't be restored without every segment.")
        }
    }

    private func proceed(deleting: Bool) {
        do {
            try model.continueWithNextSegment(deleting: deleting ? segment : nil)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Total size of a file, or of everything inside a folder.
func directorySize(_ url: URL) -> Int64 {
    let keys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]
    guard (try? url.resourceValues(forKeys: keys))?.isDirectory == true else {
        return Int64((try? url.resourceValues(forKeys: keys).fileSize) ?? 0)
    }
    var total: Int64 = 0
    let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
    while let item = enumerator?.nextObject() as? URL {
        total += Int64((try? item.resourceValues(forKeys: keys).fileSize) ?? 0)
    }
    return total
}

// MARK: - Finished

struct FinishedView: View {
    @Environment(AppModel.self) private var model
    let result: ArchiveResult

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)
                VStack(alignment: .leading) {
                    Text("Archive created").font(.title2)
                    Text(summary).foregroundStyle(.secondary)
                }
            }
            if !result.changes.isEmpty {
                ChangeReport(result: result)
            }
            if !result.warnings.isEmpty {
                GroupBox {
                    ScrollView {
                        Text(result.warnings.joined(separator: "\n\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                } label: {
                    Label("Finished with warnings", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
            }
            Table(result.files) {
                TableColumn("File") { Text($0.lastPathComponent) }
                TableColumn("Size") { url in
                    Text(directorySize(url).formatted(.byteCount(style: .file))).monospacedDigit()
                }
                .width(90)
            }
            LabeledContent("Archive SHA-256") {
                Text(result.encryptedSHA256)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            HStack {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [result.segments.isEmpty ? result.layout.encryptedArchive : result.layout.readme])
                }
                Button("Open README") { NSWorkspace.shared.open(result.layout.readme) }
                Spacer()
                Button("New Archive") { model.startOver() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    private var summary: String {
        let ratio = result.tarBytes > 0 ? Double(result.encryptedBytes) / Double(result.tarBytes) : 1
        return "\(result.sourceStats.files) files, "
            + "\(result.tarBytes.formatted(.byteCount(style: .file))) → "
            + "\(result.encryptedBytes.formatted(.byteCount(style: .file))) "
            + "(\(ratio.formatted(.percent.precision(.fractionLength(0))))) in "
            + Duration.seconds(result.duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
            + (result.segments.isEmpty ? "" : ", \(result.segments.count) segment\(result.segments.count == 1 ? "" : "s")")
    }
}

struct ChangeReport: View {
    let result: ArchiveResult

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("This archive isn't a consistent copy: a file that changed may mix old and new contents, "
                     + "and a file that was removed is missing. The list is also saved, encrypted, in "
                     + "“\(result.layout.changesFileName)”.")
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(result.changes.prefix(500), id: \.self) { change in
                            Text("\(change.path) — \(change.summary)")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        if result.changes.count > 500 {
                            Text("…and \(result.changes.count - 500) more").font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
        } label: {
            Label("\(result.changes.count) file\(result.changes.count == 1 ? "" : "s") changed while being archived",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        }
    }
}

// MARK: - Failed

struct FailedView: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.red)
                VStack(alignment: .leading) {
                    Text("The archive wasn't created").font(.title2)
                    Text("Nothing was left in the destination folder.").foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(message)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Back") { model.backToEditing() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }
}

extension URL: @retroactive Identifiable {
    public var id: URL { self }
}

extension String {
    /// "age1ql3z7h…mcac8p"
    var abbreviatedKey: String {
        count > 24 ? "\(prefix(12))…\(suffix(8))" : self
    }
}
