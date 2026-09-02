import Foundation

struct JobTransferTotals: Sendable {
    private var cumulativeFileCounts: [UUID: Int] = [:]
    private var latestSessionFileCounts: [UUID: Int] = [:]

    mutating func record(jobID: UUID, fileCount: Int) {
        latestSessionFileCounts[jobID] = fileCount
        guard fileCount > 0 else { return }
        cumulativeFileCounts[jobID, default: 0] += fileCount
    }

    func fileCount(jobID: UUID, latestSessionOnly: Bool) -> Int {
        let counts = latestSessionOnly ? latestSessionFileCounts : cumulativeFileCounts
        return counts[jobID, default: 0]
    }

    mutating func reset(jobID: UUID) {
        cumulativeFileCounts[jobID] = 0
        latestSessionFileCounts[jobID] = 0
    }

    mutating func remove(jobID: UUID) {
        cumulativeFileCounts[jobID] = nil
        latestSessionFileCounts[jobID] = nil
    }
}

struct SyncConcurrencyPolicy: Equatable, Sendable {
    static let appDefault = SyncConcurrencyPolicy(globalLimit: 2, perHostLimit: 1)

    let globalLimit: Int
    let perHostLimit: Int?

    init(globalLimit: Int, perHostLimit: Int?) {
        precondition(globalLimit > 0)
        precondition(perHostLimit == nil || perHostLimit! > 0)
        self.globalLimit = globalLimit
        self.perHostLimit = perHostLimit
    }
}

struct SyncRemoteHost: Hashable, Sendable {
    let host: String
    let port: Int

    init?(endpoint: Endpoint) {
        guard endpoint.kind.isRemote else { return nil }
        host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        port = endpoint.port
    }

    static func hosts(for job: SyncJob) -> Set<SyncRemoteHost> {
        Set([job.left, job.right, job.processedFolder].compactMap { endpoint in
            endpoint.flatMap(SyncRemoteHost.init(endpoint:))
        })
    }
}

struct SyncConcurrencySnapshot: Equatable, Sendable {
    let activeCount: Int
    let pendingCount: Int
}

actor SyncConcurrencyController {
    private struct PendingRequest {
        let id: UUID
        let hosts: Set<SyncRemoteHost>
        let continuation: CheckedContinuation<UUID, any Error>
    }

    private let policy: SyncConcurrencyPolicy
    private var activeLeases: [UUID: Set<SyncRemoteHost>] = [:]
    private var activeHostCounts: [SyncRemoteHost: Int] = [:]
    private var pendingRequests: [PendingRequest] = []

    init(policy: SyncConcurrencyPolicy = .appDefault) {
        self.policy = policy
    }

    func acquire(hosts: Set<SyncRemoteHost>) async throws -> UUID {
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingRequests.append(PendingRequest(
                    id: requestID,
                    hosts: hosts,
                    continuation: continuation
                ))
                admitAvailableRequests()
            }
        } onCancel: {
            Task { await self.cancelPendingRequest(requestID) }
        }
    }

    func release(_ leaseID: UUID) {
        guard let hosts = activeLeases.removeValue(forKey: leaseID) else { return }
        for host in hosts {
            let remaining = activeHostCounts[host, default: 1] - 1
            activeHostCounts[host] = remaining > 0 ? remaining : nil
        }
        admitAvailableRequests()
    }

    func snapshot() -> SyncConcurrencySnapshot {
        SyncConcurrencySnapshot(
            activeCount: activeLeases.count,
            pendingCount: pendingRequests.count
        )
    }

    private func cancelPendingRequest(_ requestID: UUID) {
        guard let index = pendingRequests.firstIndex(where: { $0.id == requestID }) else { return }
        let request = pendingRequests.remove(at: index)
        request.continuation.resume(throwing: CancellationError())
        admitAvailableRequests()
    }

    private func admitAvailableRequests() {
        while activeLeases.count < policy.globalLimit,
              let index = pendingRequests.firstIndex(where: { canAdmit($0.hosts) }) {
            let request = pendingRequests.remove(at: index)
            activeLeases[request.id] = request.hosts
            for host in request.hosts {
                activeHostCounts[host, default: 0] += 1
            }
            request.continuation.resume(returning: request.id)
        }
    }

    private func canAdmit(_ hosts: Set<SyncRemoteHost>) -> Bool {
        guard activeLeases.count < policy.globalLimit else { return false }
        guard let perHostLimit = policy.perHostLimit else { return true }
        return hosts.allSatisfy { activeHostCounts[$0, default: 0] < perHostLimit }
    }
}
