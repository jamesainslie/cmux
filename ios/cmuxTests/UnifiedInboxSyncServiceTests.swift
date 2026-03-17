import Combine
import XCTest
@testable import cmux_DEV

@MainActor
final class UnifiedInboxSyncServiceTests: XCTestCase {
    func testMergesConversationAndWorkspaceRows() throws {
        let items = UnifiedInboxSyncService.merge(
            conversations: [
                .fixture(
                    id: "conversation_123",
                    title: "Fix Tailscale attach",
                    preview: "agent replied",
                    unread: false,
                    updatedAt: 10_000
                )
            ],
            workspaces: [
                .fixture(
                    workspaceID: "workspace_123",
                    title: "orb / cmux",
                    preview: "feature/dogfood-inbox",
                    latestEventSeq: 4,
                    lastReadEventSeq: 2,
                    lastActivityAt: Date(timeIntervalSince1970: 20)
                )
            ]
        )

        XCTAssertEqual(items.map(\.kind), [.workspace, .conversation])
        XCTAssertEqual(items.first?.title, "orb / cmux")
        XCTAssertEqual(items.first?.unreadCount, 1)
    }

    func testWorkspaceUpdateRewritesCachedRow() async throws {
        let database = try AppDatabase.inMemory()
        let inboxCache = InboxCacheRepository(database: database)
        try inboxCache.save([
            UnifiedInboxItem(
                kind: .conversation,
                conversationID: "conversation_123",
                title: "Fix Tailscale attach",
                preview: "agent replied",
                unreadCount: 0,
                sortDate: Date(timeIntervalSince1970: 10)
            )
        ])

        let subject = PassthroughSubject<[MobileInboxWorkspaceRow], Never>()
        let service = UnifiedInboxSyncService(
            inboxCacheRepository: inboxCache,
            publisherFactory: { _ in subject.eraseToAnyPublisher() }
        )

        let receivedLiveUpdate = expectation(description: "received live workspace update")
        var cancellable: AnyCancellable?
        cancellable = service.workspaceItemsPublisher
            .dropFirst()
            .sink { items in
                if items.first?.preview == "preview 2" {
                    receivedLiveUpdate.fulfill()
                }
            }

        service.connect(teamID: "team_123")
        subject.send([
            .fixture(
                workspaceID: "workspace_123",
                title: "orb / cmux",
                preview: "preview 1",
                latestEventSeq: 4,
                lastReadEventSeq: 2,
                lastActivityAt: Date(timeIntervalSince1970: 20)
            )
        ])
        subject.send([
            .fixture(
                workspaceID: "workspace_123",
                title: "orb / cmux",
                preview: "preview 2",
                latestEventSeq: 5,
                lastReadEventSeq: 2,
                lastActivityAt: Date(timeIntervalSince1970: 30)
            )
        ])

        await fulfillment(of: [receivedLiveUpdate], timeout: 1.0)
        cancellable?.cancel()

        let cachedItems = try inboxCache.load()
        XCTAssertEqual(cachedItems.count, 2)
        XCTAssertEqual(cachedItems.first(where: { $0.kind == .workspace })?.preview, "preview 2")
        XCTAssertEqual(
            cachedItems.first(where: { $0.kind == .conversation })?.conversationID,
            "conversation_123"
        )
    }
}
