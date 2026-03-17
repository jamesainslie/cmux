import Foundation

/// Maps cmux panel UUIDs to tmux window/pane IDs and TTY paths.
///
/// Persisted to `~/Library/Application Support/cmux/tmux-pane-registry-<bundleId>.json`
/// so that on relaunch, cmux can reattach to live tmux panes.
@MainActor
final class TmuxPaneRegistry: ObservableObject {

    /// A single mapping between a cmux panel and a tmux pane.
    struct Entry: Codable, Equatable, Sendable {
        let panelId: UUID
        let windowId: String   // e.g. "@0"
        let paneId: String     // e.g. "%0"
        var ttyPath: String?   // e.g. "/dev/ttys042"
        var workingDirectory: String?
    }

    /// Current mappings, keyed by panel UUID.
    @Published private(set) var entries: [UUID: Entry] = [:]

    private let persistenceURL: URL

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("cmux")

        let bundleId = Bundle.main.bundleIdentifier ?? "com.cmux.app"
        let filename = "tmux-pane-registry-\(bundleId).json"
        self.persistenceURL = appSupport.appendingPathComponent(filename)
    }

    // MARK: - Registration

    /// Register a new panel ↔ tmux pane mapping.
    func register(
        panelId: UUID,
        windowId: String,
        paneId: String,
        ttyPath: String? = nil,
        workingDirectory: String? = nil
    ) {
        entries[panelId] = Entry(
            panelId: panelId,
            windowId: windowId,
            paneId: paneId,
            ttyPath: ttyPath,
            workingDirectory: workingDirectory
        )
    }

    /// Update the TTY path for an existing entry (e.g., after querying tmux).
    func updateTTYPath(_ ttyPath: String, forPanelId panelId: UUID) {
        guard var entry = entries[panelId] else { return }
        entry.ttyPath = ttyPath
        entries[panelId] = entry
    }

    /// Remove a panel mapping (on panel close).
    func unregister(panelId: UUID) {
        entries.removeValue(forKey: panelId)
    }

    // MARK: - Lookups

    /// Find the entry for a given tmux pane ID.
    func entry(forPaneId paneId: String) -> Entry? {
        entries.values.first { $0.paneId == paneId }
    }

    /// Find the entry for a given tmux window ID.
    func entry(forWindowId windowId: String) -> Entry? {
        entries.values.first { $0.windowId == windowId }
    }

    /// Find the entry for a given panel UUID.
    func entry(forPanelId panelId: UUID) -> Entry? {
        entries[panelId]
    }

    /// All tmux pane IDs currently registered.
    var allPaneIds: Set<String> {
        Set(entries.values.map(\.paneId))
    }

    // MARK: - Reattach Reconciliation

    /// Result of reconciling the persisted registry with live tmux state.
    struct ReconciliationResult: Sendable {
        /// Entries that matched a live tmux pane — ready to reattach.
        let reattachable: [Entry]
        /// Tmux panes that exist in tmux but have no matching registry entry — orphans.
        let orphanedPaneIds: [String]
        /// Registry entries whose tmux pane no longer exists — stale.
        let stalePanelIds: [UUID]
    }

    /// Cross-reference the persisted registry with live tmux pane IDs.
    ///
    /// - Parameter livePaneIds: Set of pane IDs currently reported by `tmux list-panes`.
    /// - Returns: Categorized entries for reattach, import, or cleanup.
    func reconcile(livePaneIds: Set<String>) -> ReconciliationResult {
        var reattachable: [Entry] = []
        var stalePanelIds: [UUID] = []

        let registeredPaneIds = allPaneIds

        for entry in entries.values {
            if livePaneIds.contains(entry.paneId) {
                reattachable.append(entry)
            } else {
                stalePanelIds.append(entry.panelId)
            }
        }

        let orphanedPaneIds = livePaneIds.subtracting(registeredPaneIds).sorted()

        return ReconciliationResult(
            reattachable: reattachable,
            orphanedPaneIds: orphanedPaneIds,
            stalePanelIds: stalePanelIds
        )
    }

    /// Remove all stale entries (tmux pane no longer exists).
    func removeStaleEntries(_ panelIds: [UUID]) {
        for id in panelIds {
            entries.removeValue(forKey: id)
        }
    }

    /// Remove all entries.
    func clear() {
        entries.removeAll()
    }

    // MARK: - Persistence

    /// Save the current registry to disk.
    func save() {
        let allEntries = Array(entries.values)

        do {
            let dir = persistenceURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let data = try JSONEncoder().encode(allEntries)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            // Log but don't crash — registry loss means fresh shells on restart.
            NSLog("[TmuxPaneRegistry] Failed to save: \(error)")
        }
    }

    /// Load the registry from disk. Returns true if entries were loaded.
    @discardableResult
    func load() -> Bool {
        guard FileManager.default.fileExists(atPath: persistenceURL.path) else {
            return false
        }

        do {
            let data = try Data(contentsOf: persistenceURL)
            let loadedEntries = try JSONDecoder().decode([Entry].self, from: data)

            entries = Dictionary(uniqueKeysWithValues: loadedEntries.map { ($0.panelId, $0) })
            return !entries.isEmpty
        } catch {
            NSLog("[TmuxPaneRegistry] Failed to load: \(error)")
            return false
        }
    }

    /// Delete the persisted registry file.
    func deletePersistence() {
        try? FileManager.default.removeItem(at: persistenceURL)
    }
}
