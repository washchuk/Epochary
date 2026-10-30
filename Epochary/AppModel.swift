import AppKit
import EpocharyKit
import Foundation
import Observation

@MainActor @Observable
final class AppModel {
    struct SourceItem: Identifiable, Hashable {
        let url: URL
        var stats: SourceStats?
        var id: URL { url }
    }

    enum Phase {
        case editing
        case running(ArchiveProgress)
        case finished(ArchiveResult)
        case failed(String)
    }

    enum EncryptionMethod: String {
        case keys, passphrase
    }

    let keys = KeyStore()
    let preferences = Preferences()

    var items: [SourceItem] = []
    var name = ArchiveLayout.defaultName()
    var destination: URL? {
        didSet { UserDefaults.standard.set(destination?.path, forKey: "destinationPath") }
    }
    var selectedRecipientIDs: Set<Recipient.ID> {
        didSet { UserDefaults.standard.set(selectedRecipientIDs.map(\.uuidString), forKey: "selectedRecipients") }
    }
    var encryptionMethod: EncryptionMethod {
        didSet { UserDefaults.standard.set(encryptionMethod.rawValue, forKey: "encryptionMethod") }
    }
    /// Only ever held in memory, and cleared once an archive is made with it.
    var passphrase = ""
    var passphraseConfirmation = ""
    /// The last passphrase Epochary generated, shown in full so it can be written down.
    private(set) var generatedPassphrase: String?
    var generatedPassphraseSaved = false
    /// Percent of PAR2 redundancy; 0 means none.
    var parityPercent: Int {
        didSet { UserDefaults.standard.set(parityPercent, forKey: "parityPercent") }
    }
    var splitIntoSegments: Bool {
        didSet {
            UserDefaults.standard.set(splitIntoSegments, forKey: "splitIntoSegments")
            // Segmented archives can take days, so a consistent copy matters more.
            if splitIntoSegments, !oldValue { stopOnSourceChange = true }
        }
    }
    var stopOnSourceChange: Bool {
        didSet { UserDefaults.standard.set(stopOnSourceChange, forKey: "stopOnSourceChange") }
    }
    var medium: Medium {
        didSet { UserDefaults.standard.set(medium.rawValue, forKey: "medium") }
    }
    var customCapacity: Double {
        didSet { UserDefaults.standard.set(customCapacity, forKey: "customCapacity") }
    }
    var customCapacityUnit: CapacityUnit {
        didSet { UserDefaults.standard.set(customCapacityUnit.rawValue, forKey: "customCapacityUnit") }
    }
    var pauseAfterEachSegment: Bool {
        didSet { UserDefaults.standard.set(pauseAfterEachSegment, forKey: "pauseAfterEachSegment") }
    }
    private(set) var phase: Phase = .editing
    private var task: Task<Void, Never>?
    private var segmentConfirmation: CheckedContinuation<Void, Error>?

    init() {
        let defaults = UserDefaults.standard
        destination = defaults.string(forKey: "destinationPath").map { URL(fileURLWithPath: $0, isDirectory: true) }
        parityPercent = defaults.integer(forKey: "parityPercent")
        splitIntoSegments = defaults.bool(forKey: "splitIntoSegments")
        stopOnSourceChange = defaults.bool(forKey: "stopOnSourceChange")
        medium = defaults.string(forKey: "medium").flatMap(Medium.init(rawValue:)) ?? .lto8
        customCapacity = defaults.object(forKey: "customCapacity") == nil ? 100 : defaults.double(forKey: "customCapacity")
        customCapacityUnit = defaults.string(forKey: "customCapacityUnit").flatMap(CapacityUnit.init(rawValue:)) ?? .gigabytes
        pauseAfterEachSegment = defaults.bool(forKey: "pauseAfterEachSegment")
        encryptionMethod = defaults.string(forKey: "encryptionMethod").flatMap(EncryptionMethod.init(rawValue:)) ?? .keys
        if let stored = defaults.stringArray(forKey: "selectedRecipients") {
            selectedRecipientIDs = Set(stored.compactMap(UUID.init(uuidString:)))
        } else {
            selectedRecipientIDs = Set(keys.recipients.map(\.id))
        }
    }

    var isRunning: Bool {
        if case .running = phase { true } else { false }
    }

    var selectedRecipients: [Recipient] {
        keys.recipients.filter { selectedRecipientIDs.contains($0.id) }
    }

    var totalStats: SourceStats? {
        guard items.allSatisfy({ $0.stats != nil }) else { return nil }
        return items.reduce(into: SourceStats()) {
            $0.files += $1.stats?.files ?? 0
            $0.bytes += $1.stats?.bytes ?? 0
        }
    }

    var mediumCapacity: Int64? {
        medium.capacity ?? (customCapacity > 0 ? Int64(customCapacity * customCapacityUnit.bytes) : nil)
    }

    /// Bytes of archive data per segment, leaving room on each medium for its recovery data.
    var segmentSize: Int64? {
        guard splitIntoSegments, let mediumCapacity else { return nil }
        return SegmentOptions.segmentSize(forCapacity: mediumCapacity,
                                          parityPercent: parityPercent > 0 ? parityPercent : nil)
    }

    var missingRequiredTools: [Tool] {
        let locator = preferences.toolLocator
        return Tool.allCases.filter { $0.isRequiredForArchiving && locator.locate($0) == nil }
    }

    /// Why the archive can't be created yet, or nil when it can.
    var blocker: String? {
        if !missingRequiredTools.isEmpty { return "Required tools are missing." }
        if items.isEmpty { return "Add files or folders to archive." }
        do { try ArchiveLayout.validateName(name) } catch { return error.localizedDescription }
        if destination == nil { return "Choose where to save the archive." }
        if let problem = encryptionProblem { return problem }
        if parityPercent > 0, preferences.toolLocator.locate(.par2) == nil {
            return "par2 isn't installed, so recovery data can't be created."
        }
        if splitIntoSegments, segmentSize == nil {
            return "The medium is too small to hold a segment."
        }
        if splitIntoSegments, destinationVolume?.isTape == true {
            return "Segments can't be staged on an LTFS tape. Save to a disk, external drive or network share."
        }
        if let space = spaceCheck, space.requirement.isExact, space.requirement.bytes > space.available {
            return "Not enough space: one segment needs \(space.requirement.bytes.formatted(.byteCount(style: .file))), "
                + "\(space.available.formatted(.byteCount(style: .file))) is free."
        }
        return nil
    }

    /// A caution that doesn't stop the archive: the space estimate assumes nothing compresses.
    var spaceWarning: String? {
        guard blocker == nil, let space = spaceCheck, !space.requirement.isExact,
              space.requirement.bytes > space.available else { return nil }
        return "Only \(space.available.formatted(.byteCount(style: .file))) is free. If the data doesn't compress, "
            + "the archive needs up to \(space.requirement.bytes.formatted(.byteCount(style: .file)))."
    }

    private var encryptionProblem: String? {
        switch encryptionMethod {
        case .keys:
            return selectedRecipients.isEmpty ? "Choose at least one key to encrypt to." : nil
        case .passphrase:
            if preferences.toolLocator.locate(.agePassphrasePlugin) == nil {
                return "age-plugin-batchpass isn't installed, so a passphrase can't be used."
            }
            if passphrase.isEmpty { return "Enter a passphrase." }
            do { try Passphrase.validate(passphrase) } catch { return error.localizedDescription }
            if passphrase != passphraseConfirmation { return "The passphrases don't match." }
            if shownGeneratedPassphrase != nil, !generatedPassphraseSaved {
                return "Confirm you've saved the generated passphrase."
            }
            return nil
        }
    }

    /// The generated passphrase, while it's still the one in use.
    var shownGeneratedPassphrase: String? {
        generatedPassphrase.flatMap { $0 == passphrase ? $0 : nil }
    }

    func generatePassphrase() {
        let generated = Passphrase.generate()
        generatedPassphrase = generated
        generatedPassphraseSaved = false
        passphrase = generated
        passphraseConfirmation = generated
    }

    private func forgetPassphrase() {
        passphrase = ""
        passphraseConfirmation = ""
        generatedPassphrase = nil
        generatedPassphraseSaved = false
    }

    var destinationVolume: DestinationVolume? {
        destination.flatMap(DestinationVolume.init(containing:))
    }

    private var spaceCheck: (requirement: SpaceRequirement, available: Int64)? {
        guard let stats = totalStats, let request = makeRequest(),
              let available = destinationVolume?.availableCapacity else { return nil }
        return (SpaceRequirement(for: request, stats: stats), available)
    }

    private func makeRequest() -> ArchiveRequest? {
        guard let destination else { return nil }
        return ArchiveRequest(
            sources: items.map(\.url), destinationDirectory: destination, name: name,
            recipients: encryptionMethod == .keys ? selectedRecipients : [],
            compressionLevel: preferences.compressionLevel,
            longWindow: preferences.longWindow, parityPercent: parityPercent > 0 ? parityPercent : nil,
            excludeFinderMetadata: preferences.excludeFinderMetadata, verify: preferences.verify,
            segmentation: segmentSize.map { SegmentOptions(size: $0, pauseAfterEach: pauseAfterEachSegment) },
            stopOnSourceChange: stopOnSourceChange,
            passphrase: encryptionMethod == .passphrase ? passphrase : nil)
    }

    // MARK: Items

    func add(_ urls: [URL]) {
        let existing = Set(items.map(\.url))
        let new = urls.map(\.standardizedFileURL).filter { !existing.contains($0) }
        items += new.map { SourceItem(url: $0) }
        for url in new {
            Task.detached(priority: .utility) {
                let stats = SourceStats.measure([url])
                await self.setStats(stats, for: url)
            }
        }
    }

    private func setStats(_ stats: SourceStats, for url: URL) {
        if let index = items.firstIndex(where: { $0.url == url }) { items[index].stats = stats }
    }

    func remove(_ ids: Set<SourceItem.ID>) {
        items.removeAll { ids.contains($0.id) }
    }

    func chooseItems() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Epochary creates a folder named after the archive here."
        panel.directoryURL = destination
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }

    // MARK: Running

    func start() {
        guard blocker == nil, let request = makeRequest() else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let pipeline = ArchivePipeline(tools: preferences.toolLocator, appVersion: version)
        phase = .running(ArchiveProgress(stage: .preparing))

        let (updates, continuation) = AsyncStream.makeStream(of: ArchiveProgress.self,
                                                             bufferingPolicy: .bufferingNewest(1))
        task = Task {
            async let result = pipeline.run(request) { continuation.yield($0) } confirmNextSegment: { segment in
                try await self.waitForConfirmation(after: segment)
            }
            let watcher = Task {
                for await progress in updates where self.isRunning { self.phase = .running(progress) }
            }
            do {
                let finished = try await result
                phase = .finished(finished)
                forgetPassphrase()
                NSSound(named: "Glass")?.play()
            } catch is CancellationError {
                phase = .editing
            } catch {
                phase = .failed(error.localizedDescription)
            }
            continuation.finish()
            watcher.cancel()
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Suspends the archive after a segment until the user continues or cancels.
    private func waitForConfirmation(after segment: CompletedSegment) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                segmentConfirmation = continuation
                NSApp.requestUserAttention(.criticalRequest)
                NSSound(named: "Glass")?.play()
            }
        } onCancel: {
            Task { @MainActor in
                self.segmentConfirmation?.resume(throwing: CancellationError())
                self.segmentConfirmation = nil
            }
        }
    }

    /// Writes the next segment, optionally deleting the finished one from disk first.
    func continueWithNextSegment(deleting segment: CompletedSegment? = nil) throws {
        guard let confirmation = segmentConfirmation else { return }
        if let segment { try FileManager.default.removeItem(at: segment.folder) }
        segmentConfirmation = nil
        confirmation.resume()
    }

    /// Cancels a running archive and waits until its partial output is removed.
    func cancelAndWait() async {
        guard let task else { return }
        task.cancel()
        await task.value
    }

    func startOver() {
        items = []
        name = ArchiveLayout.defaultName()
        forgetPassphrase()
        phase = .editing
    }

    func backToEditing() {
        phase = .editing
    }
}
