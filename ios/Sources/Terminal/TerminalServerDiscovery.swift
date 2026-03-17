import Combine
import ConvexMobile
import Foundation

protocol TerminalServerDiscovering {
    var hostsPublisher: AnyPublisher<[TerminalHost], Never> { get }
}

final class TerminalServerDiscovery: TerminalServerDiscovering {
    let hostsPublisher: AnyPublisher<[TerminalHost], Never>

    @MainActor
    convenience init() {
        let convexClient = ConvexClientManager.shared.client
        let memberships = convexClient
            .subscribe(to: "teams:listTeamMemberships", yielding: TeamsListTeamMembershipsReturn.self)
            .catch { _ in
                Empty<TeamsListTeamMembershipsReturn, Never>()
            }
            .eraseToAnyPublisher()
        let machineHosts = Self.makeMachineHostsPublisher(
            teamMemberships: memberships,
            convexClient: convexClient
        )
        self.init(machineHosts: machineHosts, teamMemberships: memberships)
    }

    init(
        machineHosts: AnyPublisher<[TerminalHost], Never> = Just([]).eraseToAnyPublisher(),
        teamMemberships: AnyPublisher<TeamsListTeamMembershipsReturn, Never>
    ) {
        let legacyHosts = teamMemberships
            .map(Self.legacyHosts(from:))
            .eraseToAnyPublisher()

        self.hostsPublisher = Publishers.CombineLatest(machineHosts, legacyHosts)
            .map { machineHosts, legacyHosts in
                Self.merge(machineHosts: machineHosts, legacyHosts: legacyHosts)
            }
            .eraseToAnyPublisher()
    }

    private static func makeMachineHostsPublisher(
        teamMemberships: AnyPublisher<TeamsListTeamMembershipsReturn, Never>,
        convexClient: ConvexClientWithAuth<StackAuthResult>
    ) -> AnyPublisher<[TerminalHost], Never> {
        teamMemberships
            .map { memberships in
                memberships.first?.teamId.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .removeDuplicates()
            .map { teamID -> AnyPublisher<[TerminalHost], Never> in
                guard let teamID, !teamID.isEmpty else {
                    return Just([]).eraseToAnyPublisher()
                }

                return convexClient
                    .subscribe(
                        to: "mobileMachines:listForUser",
                        with: ["teamSlugOrId": teamID],
                        yielding: [MobileMachineRow].self
                    )
                    .map { rows in
                        rows.map { $0.asTerminalHost() }
                    }
                    .catch { _ in
                        Just([])
                    }
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .eraseToAnyPublisher()
    }

    private static func legacyHosts(from memberships: TeamsListTeamMembershipsReturn) -> [TerminalHost] {
        memberships.flatMap { membership -> [TerminalHost] in
            guard let metadata = membership.team.serverMetadata?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !metadata.isEmpty,
                let catalog = try? TerminalServerCatalog(
                    metadataJSON: metadata,
                    teamID: membership.team.teamId
                ) else {
                return []
            }

            return catalog.hosts
        }
    }

    private static func merge(
        machineHosts: [TerminalHost],
        legacyHosts: [TerminalHost]
    ) -> [TerminalHost] {
        guard !machineHosts.isEmpty else {
            return legacyHosts
        }

        let machineStableIDs = Set(machineHosts.map(\.stableID))
        let legacyFallbackHosts = legacyHosts.filter { !machineStableIDs.contains($0.stableID) }
        return TerminalServerCatalog.merge(
            discovered: machineHosts + legacyFallbackHosts,
            local: []
        )
    }
}
