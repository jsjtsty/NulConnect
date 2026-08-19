import Foundation

actor NulConnectAuthEngine {
    private var session: ATRAuthSession?
    private var configuration: ATRAuthConfiguration?
    private var callbackDeviceID: String?
    private var callbackCapturePolicy: NulConnectWebLoginCapturePolicy?

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
        let startURL = try await NulConnectAuthWorker.run {
            try session.prepareCallbackLogin(deviceID: deviceID)
            return try session.resolveLoginURL(method.loginURL)
        }
        guard let capturePolicy = Self.capturePolicy(
            for: method,
            baseHost: configuration.serverHost,
            callbackHost: startURL.host
        ) else {
            throw NulConnectLoginError.unsupportedAuthType(method.authType)
        }
        callbackDeviceID = deviceID
        callbackCapturePolicy = capturePolicy
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
        guard let session, let _ = configuration else {
            throw NulConnectLoginError.noSession
        }
        guard let callbackDeviceID else {
            throw NulConnectLoginError.noSession
        }
        guard let callbackCapturePolicy else {
            throw NulConnectLoginError.noSession
        }
        let validatedURL = try callbackCapturePolicy.validate(callbackURL)
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
        self.callbackCapturePolicy = nil
        return refreshed
    }

    func reset() {
        session = nil
        configuration = nil
        callbackDeviceID = nil
        callbackCapturePolicy = nil
    }

    private nonisolated static func capturePolicy(
        for method: ATRAuthMethod,
        baseHost: String,
        callbackHost: String? = nil
    ) -> NulConnectWebLoginCapturePolicy? {
        NulConnectWebLoginCapturePolicy.make(
            authType: method.authType,
            baseHost: baseHost,
            loginURL: method.loginURL,
            additionalHost: callbackHost
        )
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
