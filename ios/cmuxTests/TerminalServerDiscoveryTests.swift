import Combine
import XCTest
@testable import cmux_DEV

final class TerminalServerDiscoveryTests: XCTestCase {
    func testDiscoveryPublishesHostsWithTeamMetadata() async throws {
        let memberships = [
            makeMembership(
                teamID: "team-0",
                serverMetadata: #"{"cmux":{"servers":[{"id":"cmux-sequoia","name":"Sequoia","hostname":"cmux-sequoia","username":"cmux","symbolName":"desktopcomputer","palette":"sky","transport":"raw-ssh"}]}}"#
            ),
            makeMembership(
                teamID: "team-1",
                serverMetadata: #"{"cmux":{"servers":[{"id":"cmux-macmini","name":"Mac mini","hostname":"cmux-macmini","username":"cmux","symbolName":"desktopcomputer","palette":"mint","transport":"cmuxd-remote"}]}}"#
            )
        ]

        let discovery = TerminalServerDiscovery(
            teamMemberships: Just(memberships).eraseToAnyPublisher()
        )

        let hosts = await firstValue(from: discovery.hostsPublisher)

        XCTAssertEqual(hosts.map(\.stableID), ["cmux-sequoia", "cmux-macmini"])
        XCTAssertEqual(hosts.first?.teamID, "team-0")
        XCTAssertEqual(hosts.last?.teamID, "team-1")
        XCTAssertEqual(hosts.last?.transportPreference, .remoteDaemon)
    }

    func testDiscoveryPublishesEmptyHostsWhenMetadataClears() async throws {
        let subject = PassthroughSubject<TeamsListTeamMembershipsReturn, Never>()
        let discovery = TerminalServerDiscovery(
            teamMemberships: subject.eraseToAnyPublisher()
        )

        let receivedUpdates = expectation(description: "received discovery updates")
        var updates: [[TerminalHost]] = []
        let cancellable = discovery.hostsPublisher.sink { hosts in
            updates.append(hosts)
            if updates.count == 2 {
                receivedUpdates.fulfill()
            }
        }
        defer { cancellable.cancel() }

        subject.send([
            makeMembership(
                teamID: "team-1",
                serverMetadata: #"{"cmux":{"servers":[{"id":"cmux-macmini","name":"Mac mini","hostname":"cmux-macmini","username":"cmux","symbolName":"desktopcomputer","palette":"mint","transport":"cmuxd-remote"}]}}"#
            )
        ])
        subject.send([
            makeMembership(teamID: "team-1", serverMetadata: nil)
        ])

        await fulfillment(of: [receivedUpdates], timeout: 1.0)

        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates.first?.map(\.stableID), ["cmux-macmini"])
        XCTAssertEqual(updates.last, [])
    }

    func testDiscoveryFallsBackToLegacyServerMetadataWhenMachineRowsMissing() async throws {
        let memberships = [
            makeMembership(
                teamID: "team-1",
                serverMetadata: #"{"cmux":{"servers":[{"id":"cmux-macmini","name":"Mac mini","hostname":"cmux-macmini","username":"cmux","symbolName":"desktopcomputer","palette":"mint","transport":"cmuxd-remote"}]}}"#
            )
        ]
        let discovery = TerminalServerDiscovery(
            machineHosts: Just([]).eraseToAnyPublisher(),
            teamMemberships: Just(memberships).eraseToAnyPublisher()
        )

        let hosts = await firstValue(from: discovery.hostsPublisher)

        XCTAssertEqual(hosts.map(\.stableID), ["cmux-macmini"])
        XCTAssertEqual(hosts.first?.hostname, "cmux-macmini")
        XCTAssertEqual(hosts.first?.transportPreference, .remoteDaemon)
    }

    private func makeMembership(teamID: String, serverMetadata: String?) -> TeamsListTeamMembershipsItem {
        TeamsListTeamMembershipsItem(
            team: TeamsListTeamMembershipsItemTeam(
                _id: ConvexId(rawValue: "team_doc_1"),
                _creationTime: 0,
                slug: "cmux",
                displayName: "cmux",
                name: "cmux",
                profileImageUrl: nil,
                clientMetadata: nil,
                clientReadOnlyMetadata: nil,
                serverMetadata: serverMetadata,
                createdAtMillis: nil,
                teamId: teamID,
                createdAt: 0,
                updatedAt: 0
            ),
            _id: ConvexId(rawValue: "membership_doc_1"),
            _creationTime: 0,
            role: nil,
            teamId: teamID,
            createdAt: 0,
            updatedAt: 0,
            userId: "user-1"
        )
    }

    private func firstValue<T>(from publisher: AnyPublisher<T, Never>) async -> T {
        await withCheckedContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = publisher
                .first()
                .sink { value in
                    continuation.resume(returning: value)
                    cancellable?.cancel()
                }
        }
    }
}
