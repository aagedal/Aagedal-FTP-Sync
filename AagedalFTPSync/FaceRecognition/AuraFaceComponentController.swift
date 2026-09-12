import Combine
import Foundation

private final class WeakAuraFaceComponentController: @unchecked Sendable {
    weak var value: AuraFaceComponentController?

    init(_ value: AuraFaceComponentController) {
        self.value = value
    }
}

@MainActor
final class AuraFaceComponentController: ObservableObject {
    enum State: Equatable {
        case checking
        case notInstalled
        case downloading(progress: Double?)
        case installing
        case installed(version: String)
        case offline
        case verificationFailed(String)
        case cancelled
    }

    @Published private(set) var state: State = .checking
    private let installer: AuraFaceComponentInstaller
    private var operation: Task<Void, Never>?
    private var requestID = UUID()

    init(installer: AuraFaceComponentInstaller) {
        self.installer = installer
    }

    deinit { operation?.cancel() }

    /// Local-only startup/status probe. The caller chooses when an admitted runtime may begin it.
    func refresh() {
        replaceOperation(initial: .checking) { [installer] in
            try await installer.resolveInstalled()
        }
    }

    func downloadAndInstall() {
        let id = begin(.downloading(progress: nil))
        let controllerReference = WeakAuraFaceComponentController(self)
        operation = Task { [weak self, installer, controllerReference] in
            do {
                _ = try await installer.downloadAndInstall { fraction in
                    guard let controller = controllerReference.value else { return }
                    Task { @MainActor [weak controller] in
                        guard let controller, controller.requestID == id, !Task.isCancelled else { return }
                        if fraction == 1 {
                            controller.state = .installing
                        } else {
                            controller.state = fraction.map { .downloading(progress: $0) } ?? .downloading(progress: nil)
                        }
                    }
                }
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.state = .installing
                let resolution = try await installer.resolveInstalled()
                guard self.requestID == id, !Task.isCancelled else { return }
                self.publish(resolution)
            } catch is CancellationError {
                guard let self, self.requestID == id else { return }
                self.state = .cancelled
            } catch let error as URLError {
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.state = Self.isOffline(error) ? .offline : .verificationFailed(error.localizedDescription)
            } catch {
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.state = .verificationFailed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        requestID = UUID()
        operation?.cancel()
        operation = nil
        state = .cancelled
    }

    func removeInstalled() {
        let id = begin(.checking)
        operation = Task { [weak self, installer] in
            do {
                try await installer.removeInstalled()
                let resolution = try await installer.resolveInstalled()
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.publish(resolution)
            } catch is CancellationError {
                guard let self, self.requestID == id else { return }
                self.state = .cancelled
            } catch {
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.state = .verificationFailed(error.localizedDescription)
            }
        }
    }

    private func replaceOperation(
        initial: State,
        action: @escaping @Sendable () async throws -> AuraFaceComponentResolution
    ) {
        let id = begin(initial)
        operation = Task { [weak self] in
            do {
                let resolution = try await action()
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.publish(resolution)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.state = .verificationFailed(error.localizedDescription)
            }
        }
    }

    private func begin(_ initial: State) -> UUID {
        operation?.cancel()
        let id = UUID()
        requestID = id
        state = initial
        return id
    }

    private func publish(_ resolution: AuraFaceComponentResolution) {
        switch resolution.availability {
        case .notInstalled: state = .notInstalled
        case .installed(let version): state = .installed(version: version)
        case .verificationFailed: state = .verificationFailed(
            AuraFaceComponentError.invalidInstalledComponent.localizedDescription)
        }
    }

    private static func isOffline(_ error: URLError) -> Bool {
        [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
         .cannotConnectToHost, .dnsLookupFailed, .timedOut].contains(error.code)
    }
}
