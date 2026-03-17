import Combine
import Foundation

@MainActor
protocol UnifiedInboxWorkspaceSyncing: AnyObject {
    var workspaceItemsPublisher: AnyPublisher<[UnifiedInboxItem], Never> { get }
    func connect(teamID: String)
}

@MainActor
final class UnifiedInboxSyncService: UnifiedInboxWorkspaceSyncing {
    private let inboxCacheRepository: InboxCacheRepository?
    private let publisherFactory: @MainActor (String) -> AnyPublisher<[MobileInboxWorkspaceRow], Never>
    private let subject: CurrentValueSubject<[UnifiedInboxItem], Never>
    private var cancellables = Set<AnyCancellable>()
    private var activeTeamID: String?

    init(
        inboxCacheRepository: InboxCacheRepository?,
        publisherFactory: @MainActor @escaping (String) -> AnyPublisher<[MobileInboxWorkspaceRow], Never> = UnifiedInboxSyncService.defaultPublisher
    ) {
        self.inboxCacheRepository = inboxCacheRepository
        self.publisherFactory = publisherFactory
        let cachedWorkspaceItems = (try? inboxCacheRepository?.load().filter { $0.kind == .workspace }) ?? []
        self.subject = CurrentValueSubject(cachedWorkspaceItems)
    }

    var workspaceItemsPublisher: AnyPublisher<[UnifiedInboxItem], Never> {
        subject.eraseToAnyPublisher()
    }

    func connect(teamID: String) {
        guard activeTeamID != teamID else { return }
        activeTeamID = teamID
        cancellables.removeAll()

        publisherFactory(teamID)
            .map { rows in
                rows.map { UnifiedInboxItem(workspaceRow: $0, teamID: teamID) }
            }
            .sink { [weak self] items in
                self?.handleLiveWorkspaceItems(items)
            }
            .store(in: &cancellables)
    }

    private func handleLiveWorkspaceItems(_ items: [UnifiedInboxItem]) {
        subject.send(items)
        guard let inboxCacheRepository else { return }

        do {
            let cachedConversationItems = try inboxCacheRepository
                .load()
                .filter { $0.kind == .conversation }
            try inboxCacheRepository.save(Self.mergeItems(
                conversationItems: cachedConversationItems,
                workspaceItems: items
            ))
        } catch {
            #if DEBUG
            print("Failed to persist live workspace inbox items: \(error)")
            #endif
        }
    }

    nonisolated static func merge(
        conversations: [ConvexConversation],
        workspaces: [AppDatabase.WorkspaceInboxRow]
    ) -> [UnifiedInboxItem] {
        let workspaceItems = workspaces.map(UnifiedInboxItem.init(workspaceRow:))
        return merge(
            conversations: conversations,
            workspaceItems: workspaceItems
        )
    }

    nonisolated static func merge(
        conversations: [ConvexConversation],
        workspaceItems: [UnifiedInboxItem]
    ) -> [UnifiedInboxItem] {
        mergeItems(
            conversationItems: conversations.map(UnifiedInboxItem.init(conversation:)),
            workspaceItems: workspaceItems
        )
    }

    nonisolated static func mergeItems(
        conversationItems: [UnifiedInboxItem],
        workspaceItems: [UnifiedInboxItem]
    ) -> [UnifiedInboxItem] {
        sort(items: conversationItems + workspaceItems)
    }

    nonisolated static func sort(items: [UnifiedInboxItem]) -> [UnifiedInboxItem] {
        items.sorted { lhs, rhs in
            if lhs.sortDate != rhs.sortDate {
                return lhs.sortDate > rhs.sortDate
            }
            if lhs.kind != rhs.kind {
                return lhs.kind == .workspace && rhs.kind == .conversation
            }
            return lhs.id < rhs.id
        }
    }

    private static func defaultPublisher(teamID: String) -> AnyPublisher<[MobileInboxWorkspaceRow], Never> {
        ConvexClientManager.shared.client
            .subscribe(
                to: "mobileInbox:listForUser",
                with: ["teamSlugOrId": teamID],
                yielding: [MobileInboxWorkspaceRow].self
            )
            .catch { _ in
                Just([])
            }
            .eraseToAnyPublisher()
    }
}
