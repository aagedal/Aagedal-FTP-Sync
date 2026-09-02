import ServiceManagement

@MainActor
final class LaunchAtLoginCoordinator {
    var status: SMAppService.Status { SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status == .notRegistered || service.status == .notFound {
                try service.register()
            }
        } else if service.status != .notRegistered {
            try service.unregister()
        }
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
