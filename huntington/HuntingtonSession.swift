import Foundation
import Observation

enum HuntingtonError: LocalizedError {
    case invalidResponse
    case httpError(Int, String)
    case authFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from server"
        case .httpError(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .authFailed(let msg): return msg
        }
    }
}

@MainActor
@Observable
class HuntingtonSession {
    var isAuthenticated = false

    private(set) var contextId = ""
    private(set) var authReceipt = ""
    private(set) var customerId = ""

    private let base = "https://m.huntington.com"
    private let stateKey = "huntington_auth_state_v2"
    private let cookieStorage = HTTPCookieStorage.shared
    private let session: URLSession
    private let noRedirectSession: URLSession

    init() {
        let cookies = HTTPCookieStorage.shared
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = cookies
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        session = URLSession(configuration: cfg)

        let nrCfg = URLSessionConfiguration.default
        nrCfg.httpCookieStorage = cookies
        nrCfg.httpCookieAcceptPolicy = .always
        nrCfg.httpShouldSetCookies = true
        noRedirectSession = URLSession(configuration: nrCfg, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    // MARK: - Lifecycle

    func initialize() async {
        guard let saved = loadState() else { return }
        contextId = saved.contextId
        authReceipt = saved.authReceipt
        customerId = saved.customerId
        restoreCookies(saved.cookies)

        do {
            let url = base + "/api/mobile-customer-accounts/1.11/contexts/\(contextId)/customers/\(customerId)/accounts?refresh=false"
            let _: AccountsResponse = try await fetch(url)
            isAuthenticated = true
        } catch {
            clearState()
        }
    }

    enum LoginResult {
        case success
        case needsDeliverySelection([OTPDeliveryOption])
    }

    struct OTPDeliveryOption: Identifiable {
        let id: String
        let value: String
        var isEmail: Bool { value.contains("@") }
    }

    // Persisted across the OTP step
    private var pendingCtx = ""
    private var pendingReceipt = ""
    private var pendingCustId = ""
    private var pendingSecondFactorId = ""
    private var pendingFraudId = ""
    private var pendingUsername = ""

    func beginLogin(username: String, password: String) async throws -> LoginResult {
        var ctx = UUID().uuidString.lowercased()
        let fraudId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        try await seedCookies()
        var lastError: Error?
        for attempt in 1...3 {
            do {
                try await mobileInit(contextId: ctx)
                try await pkmsLogin(username: username, password: password, contextId: ctx)
                lastError = nil
                break
            } catch let err as NSError where err.code == NSURLErrorNetworkConnectionLost {
                lastError = err
                ctx = UUID().uuidString.lowercased()
            }
        }
        if let err = lastError { throw err }
        let (receipt, custId) = try await authReceipt(contextId: ctx, username: username)
        let (sfId, passed) = try await secondFactors(
            contextId: ctx, authReceipt: receipt, username: username, fraudId: fraudId)

        if passed {
            try await activateCustomer(
                contextId: ctx, authReceipt: receipt,
                customerId: custId, secondFactorId: sfId, fraudId: fraudId)
            contextId = ctx
            self.authReceipt = receipt
            self.customerId = custId
            saveState()
            isAuthenticated = true
            return .success
        } else {
            // New device — server requires OTP before trusting
            pendingCtx = ctx; pendingReceipt = receipt; pendingCustId = custId
            pendingSecondFactorId = sfId; pendingFraudId = fraudId; pendingUsername = username
            let options = try await fetchDeliveryOptions(contextId: ctx, authReceipt: receipt, secondFactorId: sfId)
            return .needsDeliverySelection(options)
        }
    }

    func selectDelivery(_ option: OTPDeliveryOption) async throws {
        try await sendOTP(contextId: pendingCtx, authReceipt: pendingReceipt,
                          secondFactorId: pendingSecondFactorId, optionId: option.id)
    }

    func submitOTP(_ code: String) async throws {
        let receipt1 = try await verifyOTP(
            contextId: pendingCtx, authReceipt: pendingReceipt,
            secondFactorId: pendingSecondFactorId, code: code)
        let receipt2 = try await iaChallengeQuestion(
            contextId: pendingCtx, authReceipt: receipt1,
            secondFactorId: pendingSecondFactorId)
        try await activateCustomer(
            contextId: pendingCtx, authReceipt: receipt2,
            customerId: pendingCustId, secondFactorId: pendingSecondFactorId, fraudId: pendingFraudId)
        let ctx = pendingCtx; let sfId = pendingSecondFactorId
        contextId = pendingCtx
        self.authReceipt = receipt2
        self.customerId = pendingCustId
        saveState()
        isAuthenticated = true
        Task { await registerDevice(contextId: ctx, authReceipt: receipt2, secondFactorId: sfId) }
    }

    func signOut() {
        clearState()
        isAuthenticated = false
    }

    // MARK: - Auth steps

    private func seedCookies() async throws {
        // Load the homepage so Akamai bot-management sets ak_bmsc and related cookies
        // before pkmslogin.form, which rejects requests without them.
        var req = URLRequest(url: URL(string: base + "/")!)
        req.setValue("HuntingtonMobileBankingIOS/6.74.115", forHTTPHeaderField: "user-agent")
        _ = try? await session.data(for: req)
    }

    private func mobileInit(contextId: String) async throws {
        var req = agwRequest("POST", "/api/mobile-authentication/1.8/mobile-init", ctx: contextId)
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "content-type")
        req.httpBody = Data("{}".utf8)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201 else {
            print("[auth] mobile-init failed (\(status)): \(String(data: data, encoding: .utf8) ?? "")")
            throw HuntingtonError.authFailed("Could not start session (mobile-init \(status))")
        }
    }

    private func pkmsLogin(username: String, password: String, contextId: String) async throws {
        var req = agwRequest("POST", "/pkmslogin.form", ctx: contextId)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        req.setValue("no-cache", forHTTPHeaderField: "cache-control")
        req.httpBody = Data("login-form-type=pwd&userName=\(username.urlEncoded)&password=\(password.urlEncoded)".utf8)
        let (data, resp) = try await noRedirectSession.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let cookieNames = cookieStorage.cookies?.map(\.name) ?? []
        guard cookieNames.contains("PD-ID") else {
            print("[auth] pkmslogin failed (\(status)), body: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "")")
            if status == 200 || status == 302 {
                throw HuntingtonError.authFailed("Incorrect username or password")
            }
            throw HuntingtonError.authFailed("Login blocked by server (\(status)) — try again")
        }
    }

    private func authReceipt(contextId: String, username: String) async throws -> (String, String) {
        let path = "/api/mobile-authentication/1.8/contexts/\(contextId)/authentication-receipt"
            + "?olbLoginId=\(username.urlEncoded)&loginType=USER_PASS"
        let req = agwRequest("GET", path, ctx: contextId)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let http = resp as? HTTPURLResponse, status == 200 else {
            print("[auth] authentication-receipt failed (\(status)): \(String(data: data, encoding: .utf8) ?? "")")
            throw HuntingtonError.authFailed("Could not obtain auth receipt (\(status))")
        }
        guard let receipt = http.value(forHTTPHeaderField: "x-auth-receipt") else {
            throw HuntingtonError.authFailed("Auth receipt missing from response")
        }
        let body = try JSONDecoder().decode(AuthReceiptBody.self, from: data)
        return (receipt, body.customerId)
    }

    private func secondFactors(contextId: String, authReceipt: String,
                                username: String, fraudId: String) async throws -> (String, Bool) {
        let path = "/api/mobile-authentication/1.8/contexts/\(contextId)/second-factors"
        var req = agwRequest("POST", path, ctx: contextId, receipt: authReceipt)
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "content-type")
        let body = SecondFactorsRequest(
            fingerprint: .init(attributes: .makeForDevice()),
            olbLoginId: username,
            policy: "ANDROID",
            profile: "MOBILE",
            deviceId: persistentDeviceId(),
            token: storedDeviceToken() ?? "",
            fraudSessionId: fraudId,
            loginType: "USER_PASS",
            flowId: ""
        )
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201 else {
            print("[auth] second-factors failed (\(status)): \(String(data: data, encoding: .utf8) ?? "")")
            throw HuntingtonError.authFailed("Device verification failed (\(status))")
        }
        let result = try JSONDecoder().decode(SecondFactorsResponse.self, from: data)
        if let token = result.registrationData?.token, !token.isEmpty {
            UserDefaults.standard.set(token, forKey: "huntington_device_token")
        }
        return (result.secondFactorId, result.passed)
    }

    private func fetchDeliveryOptions(contextId: String, authReceipt: String,
                                        secondFactorId: String) async throws -> [OTPDeliveryOption] {
        let path = "/api/mobile-authentication/1.8/contexts/\(contextId)/second-factors/\(secondFactorId)/otp/delivery-options"
        let req = agwRequest("GET", path, ctx: contextId, receipt: authReceipt)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 201 else {
            print("[auth] delivery-options failed (\(status)): \(String(data: data, encoding: .utf8) ?? "")")
            throw HuntingtonError.authFailed("Could not fetch delivery options (\(status))")
        }
        let raw = try JSONDecoder().decode(DeliveryOptionsResponse.self, from: data)
        let emails = (raw.emailAddresses ?? []).map { OTPDeliveryOption(id: $0.id, value: $0.value) }
        let phones = (raw.phoneNumbers ?? []).map { OTPDeliveryOption(id: $0.id, value: $0.value) }
        let all = emails + phones
        guard !all.isEmpty else {
            throw HuntingtonError.authFailed("No delivery options available for verification code")
        }
        return all
    }

    private func sendOTP(contextId: String, authReceipt: String,
                          secondFactorId: String, optionId: String) async throws {
        let path = "/api/mobile-authentication/1.8/contexts/\(contextId)/second-factors/\(secondFactorId)/otp/delivery-options/\(optionId)"
        var req = agwRequest("PUT", path, ctx: contextId, receipt: authReceipt)
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "content-type")
        req.httpBody = Data("{}".utf8)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 201 else {
            print("[auth] send-otp failed (\(status)): \(String(data: data, encoding: .utf8) ?? "")")
            throw HuntingtonError.authFailed("Could not send verification code (\(status))")
        }
    }

    private func verifyOTP(contextId: String, authReceipt: String,
                            secondFactorId: String, code: String) async throws -> String {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        let path = "/api/mobile-authentication/1.8/contexts/\(contextId)/second-factors/\(secondFactorId)/otp/status"
        var req = agwRequest("PUT", path, ctx: contextId, receipt: authReceipt)
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "content-type")
        let body = try! JSONSerialization.data(withJSONObject: ["otpValue": trimmed, "flowId": ""])
        req.httpBody = body
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        // 201 = correct code (empty body), 200 = correct code with passed field
        guard status == 200 || status == 201 else {
            print("[auth] verify-otp failed (\(status)): \(String(data: data, encoding: .utf8) ?? "")")
            throw HuntingtonError.authFailed("Incorrect or expired verification code (\(status))")
        }
        if let result = try? JSONDecoder().decode(OTPStatusResponse.self, from: data), !result.passed {
            throw HuntingtonError.authFailed("Incorrect verification code")
        }
        return http?.value(forHTTPHeaderField: "x-auth-receipt") ?? authReceipt
    }

    private func registerDevice(contextId: String, authReceipt: String, secondFactorId: String) async {
        let path = "/api/mobile-authentication/1.8/contexts/\(contextId)/second-factors/\(secondFactorId)/registrations"
        var req = agwRequest("POST", path, ctx: contextId, receipt: authReceipt)
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["deviceName": "iPhone"])
        guard let (data, resp) = try? await session.data(for: req) else { return }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if let reg = try? JSONDecoder().decode(RegistrationResponse.self, from: data),
           let token = reg.registrationData?.token, !token.isEmpty {
            UserDefaults.standard.set(token, forKey: "huntington_device_token")
        }
    }

    private func iaChallengeQuestion(contextId: String, authReceipt: String,
                                      secondFactorId: String) async throws -> String {
        let path = "/api/mobile-authentication/1.8/contexts/\(contextId)/second-factors/\(secondFactorId)/v2/ia-challenge-question"
        let req = agwRequest("GET", path, ctx: contextId, receipt: authReceipt)
        let (_, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        return http?.value(forHTTPHeaderField: "x-auth-receipt") ?? authReceipt
    }

    private func activateCustomer(contextId: String, authReceipt: String,
                                   customerId: String, secondFactorId: String, fraudId: String) async throws {
        let path = "/api/mobile-customer-accounts/1.11/contexts/\(contextId)/customers/\(customerId)/customers"
        var req = agwRequest("POST", path, ctx: contextId, receipt: authReceipt)
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "content-type")
        let bodyObj: [String: Any] = ["secondFactorId": secondFactorId, "fraudSessionId": fraudId]
        req.httpBody = try? JSONSerialization.data(withJSONObject: bodyObj)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 201 else {
            print("[auth] activate-customer failed (\(status)): \(String(data: data, encoding: .utf8) ?? "")")
            throw HuntingtonError.authFailed("Could not activate session (\(status))")
        }
    }

    // MARK: - Fetch (used by HuntingtonClient)

    func fetch<T: Decodable>(_ urlString: String) async throws -> T {
        var req = URLRequest(url: URL(string: urlString)!)
        req.setValue("MOBILE", forHTTPHeaderField: "x-channel")
        req.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "accept")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "x-requested-with")
        req.setValue("https://m.huntington.com/", forHTTPHeaderField: "referer")
        req.setValue("HuntingtonMobileBankingIOS/6.74.115", forHTTPHeaderField: "user-agent")
        if !contextId.isEmpty { req.setValue(contextId, forHTTPHeaderField: "x-context-id") }
        if !authReceipt.isEmpty { req.setValue(authReceipt, forHTTPHeaderField: "x-auth-receipt") }

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw HuntingtonError.invalidResponse }
        guard http.statusCode == 200 else {
            throw HuntingtonError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Request builder

    private func agwRequest(_ method: String, _ path: String,
                             ctx: String, receipt: String? = nil) -> URLRequest {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = method
        req.setValue("MOBILE", forHTTPHeaderField: "x-channel")
        req.setValue(ctx, forHTTPHeaderField: "x-context-id")
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.setValue("HuntingtonMobileBankingIOS/6.74.115", forHTTPHeaderField: "user-agent")
        if let r = receipt { req.setValue(r, forHTTPHeaderField: "x-auth-receipt") }
        return req
    }

    // MARK: - Persistence

    private struct AuthState: Codable {
        let contextId: String
        let authReceipt: String
        let customerId: String
        let cookies: [SavedCookie]
    }

    private struct SavedCookie: Codable {
        let name: String; let value: String; let domain: String; let path: String
    }

    private func saveState() {
        let saved = (cookieStorage.cookies ?? [])
            .filter { ["PD-ID", "PD-S-SESSION-ID"].contains($0.name) }
            .map { SavedCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path) }
        let state = AuthState(contextId: contextId, authReceipt: authReceipt,
                              customerId: customerId, cookies: saved)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: stateKey)
        }
    }

    private func loadState() -> AuthState? {
        guard let data = UserDefaults.standard.data(forKey: stateKey) else { return nil }
        return try? JSONDecoder().decode(AuthState.self, from: data)
    }

    private func clearState() {
        UserDefaults.standard.removeObject(forKey: stateKey)
        contextId = ""; authReceipt = ""; customerId = ""
        cookieStorage.cookies?
            .filter { $0.domain.contains("huntington.com") }
            .forEach { cookieStorage.deleteCookie($0) }
    }

    private func restoreCookies(_ saved: [SavedCookie]) {
        for c in saved {
            if let cookie = HTTPCookie(properties: [
                .name: c.name, .value: c.value, .domain: c.domain, .path: c.path,
            ]) { cookieStorage.setCookie(cookie) }
        }
    }

    private func persistentDeviceId() -> String {
        let key = "huntington_device_id"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    private func storedDeviceToken() -> String? {
        UserDefaults.standard.string(forKey: "huntington_device_token")
    }

    private func ts() -> Int { Int(Date().timeIntervalSince1970 * 1000) }
}

// MARK: - Redirect delegate

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest,
                                completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Private auth models

private struct AuthReceiptBody: Decodable {
    let customerId: String
}

private struct SecondFactorsRequest: Encodable {
    struct Fingerprint: Encodable {
        struct Attributes: Encodable {
            let os: String
            let osname: String
            let numberOfProcessors: Int
            let localeName: String
            let rooted: Bool
            let appVersion: String

            static func makeForDevice() -> Attributes {
                Attributes(
                    os: "ios", osname: "ios",
                    numberOfProcessors: ProcessInfo.processInfo.processorCount,
                    localeName: Locale.current.identifier,
                    rooted: false,
                    appVersion: "6.74.115"
                )
            }
        }
        let attributes: Attributes
    }
    let fingerprint: Fingerprint
    let olbLoginId: String
    let policy: String
    let profile: String
    let deviceId: String
    let token: String
    let fraudSessionId: String
    let loginType: String
    let flowId: String
}

private struct SecondFactorsResponse: Decodable {
    struct RegistrationData: Decodable { let token: String }
    let secondFactorId: String
    let passed: Bool
    let registrationData: RegistrationData?
}

private struct DeliveryOptionsResponse: Decodable {
    struct Option: Decodable { let id: String; let value: String }
    let phoneNumbers: [Option]?
    let emailAddresses: [Option]?
}

private struct OTPStatusResponse: Decodable {
    let passed: Bool
}

private struct RegistrationResponse: Decodable {
    struct RegistrationData: Decodable { let token: String? }
    let registrationData: RegistrationData?
}

// MARK: - Helpers

private extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
