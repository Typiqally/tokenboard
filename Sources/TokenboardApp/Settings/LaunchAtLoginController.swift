import Combine
import Foundation
import ServiceManagement

@MainActor
protocol MainAppLoginServicing: AnyObject {
    var isEnabled: Bool { get }
    func register() throws
    func unregister() throws
}

@MainActor
private final class ServiceManagementMainAppLoginService: MainAppLoginServicing {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var errorMessage: String?

    private let service: any MainAppLoginServicing

    init(service: (any MainAppLoginServicing)? = nil) {
        let service = service ?? ServiceManagementMainAppLoginService()
        self.service = service
        isEnabled = service.isEnabled
    }

    func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            isEnabled = service.isEnabled
            errorMessage = nil
        } catch {
            isEnabled = service.isEnabled
            errorMessage = AppModel.errorDescription(error)
            throw error
        }
    }
}
