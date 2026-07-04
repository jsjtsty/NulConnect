import Foundation

actor NulConnectAuthEngine {
    private var session: ATRAuthSession?
    private var configuration: ATRAuthConfiguration?
    private var callbackDeviceID: String?

    func loadMethods(configuration: ATRAuthConfiguration) async throws -> [ATRAuthMethod] {
        let (session, methods) = try await NulConnectAuthWorker.run {
            let session = try ATRAuthSession(configuration: configuration)
            let methods = try session.availableMethods()
            return (session, methods)
        }
        self.session = session
        self.configuration = configuration
        return methods
    }

    func resolveWebLoginSession(for method: ATRAuthMethod, deviceID: String) async throws -> NulConnectWebLoginSession {
        guard let session, let configuration else {
            throw NulConnectLoginError.noSession
        }
        guard let capturePolicy = Self.capturePolicy(for: method, baseHost: configuration.serverHost) else {
            throw NulConnectLoginError.unsupportedAuthType(method.authType)
        }

        let startURL = try await NulConnectAuthWorker.run {
            try session.prepareCallbackLogin(deviceID: deviceID)
            return try session.resolveLoginURL(method.loginURL)
        }
        callbackDeviceID = deviceID
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

    func completeWebLogin(callbackURL: URL, method: ATRAuthMethod) async throws -> ATRAuthChallenge {
        guard let session, let configuration else {
            throw NulConnectLoginError.noSession
        }
        guard let callbackDeviceID else {
            throw NulConnectLoginError.noSession
        }
        let validatedURL = try Self.validateCallbackURL(callbackURL, method: method, baseHost: configuration.serverHost)
        return try await NulConnectAuthWorker.run {
            try session.completeCallback(validatedURL, deviceID: callbackDeviceID)
        }
    }

    func fetchClientResource() async throws -> Data {
        guard let session else {
            throw NulConnectLoginError.noSession
        }
        return try await NulConnectAuthWorker.run {
            try session.fetchClientResource()
        }
    }

    func resumeSession(_ material: ATRSessionMaterial, configuration: ATRAuthConfiguration) async throws -> ATRSessionMaterial {
        let (session, refreshed) = try await NulConnectAuthWorker.run {
            let session = try ATRAuthSession(configuration: configuration)
            let refreshed = try session.resumeSession(material)
            return (session, refreshed)
        }
        self.session = session
        self.configuration = configuration
        self.callbackDeviceID = nil
        return refreshed
    }

    func reset() {
        session = nil
        configuration = nil
        callbackDeviceID = nil
    }

    private nonisolated static func capturePolicy(for method: ATRAuthMethod, baseHost: String) -> NulConnectWebLoginCapturePolicy? {
        switch method.authType {
        case "auth/cas":
            return .cas(baseHost: baseHost)
        case "auth/httpsOauth2":
            return .httpsOauth2(baseHost: baseHost)
        default:
            return nil
        }
    }

    private nonisolated static func validateCallbackURL(_ callbackURL: URL, method: ATRAuthMethod, baseHost: String) throws -> URL {
        guard let policy = capturePolicy(for: method, baseHost: baseHost) else {
            throw NulConnectLoginError.unsupportedAuthType(method.authType)
        }
        return try policy.validate(callbackURL)
    }

}

private nonisolated enum NulConnectAuthWorker {
    private static let queue = DispatchQueue(label: "com.nulstudio.NulConnect.auth-worker", qos: .utility)

    static func run<T>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
