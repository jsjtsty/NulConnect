import Foundation

@MainActor
final class NulConnectAuthEngine {
    private var session: ATRAuthSession?
    private var configuration: ATRAuthConfiguration?
    private var callbackDeviceID: String?

    func loadMethods(configuration: ATRAuthConfiguration) throws -> [ATRAuthMethod] {
        let session = try ATRAuthSession(configuration: configuration)
        self.session = session
        self.configuration = configuration
        return try session.availableMethods()
    }

    func resolveWebLoginSession(for method: ATRAuthMethod) throws -> NulConnectWebLoginSession {
        guard let session, let configuration else {
            throw NulConnectLoginError.noSession
        }
        guard let capturePolicy = capturePolicy(for: method, baseHost: configuration.serverHost) else {
            throw NulConnectLoginError.unsupportedAuthType(method.authType)
        }

        let deviceID = UUID().uuidString.lowercased()
        try session.prepareCallbackLogin(deviceID: deviceID)
        callbackDeviceID = deviceID
        let startURL = try session.resolveLoginURL(method.loginURL)
        return NulConnectWebLoginSession(
            id: UUID(),
            method: method,
            deviceID: deviceID,
            title: method.authName.isEmpty ? method.authType : method.authName,
            subtitle: "\(method.loginDomain) · \(method.authType)",
            startURL: startURL,
            captureHint: capturePolicy.hint,
            capturePolicy: capturePolicy
        )
    }

    func completeWebLogin(callbackURL: URL, method: ATRAuthMethod) throws -> ATRAuthChallenge {
        guard let session, let configuration else {
            throw NulConnectLoginError.noSession
        }
        guard let callbackDeviceID else {
            throw NulConnectLoginError.noSession
        }
        let validatedURL = try validateCallbackURL(callbackURL, method: method, baseHost: configuration.serverHost)
        return try session.completeCallback(validatedURL, deviceID: callbackDeviceID)
    }

    func fetchClientResource() throws -> Data {
        guard let session else {
            throw NulConnectLoginError.noSession
        }
        return try session.fetchClientResource()
    }

    func reset() {
        session = nil
        configuration = nil
        callbackDeviceID = nil
    }

    private func capturePolicy(for method: ATRAuthMethod, baseHost: String) -> NulConnectWebLoginCapturePolicy? {
        switch method.authType {
        case "auth/cas":
            return .cas(baseHost: baseHost)
        case "auth/httpsOauth2":
            return .httpsOauth2(baseHost: baseHost)
        default:
            return nil
        }
    }

    private func validateCallbackURL(_ callbackURL: URL, method: ATRAuthMethod, baseHost: String) throws -> URL {
        guard let policy = capturePolicy(for: method, baseHost: baseHost) else {
            throw NulConnectLoginError.unsupportedAuthType(method.authType)
        }
        return try policy.validate(callbackURL)
    }

}
