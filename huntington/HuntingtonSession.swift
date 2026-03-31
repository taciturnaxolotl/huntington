import WebKit
import Combine

enum HuntingtonError: LocalizedError {
    case invalidResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from server"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        }
    }
}

@MainActor
class HuntingtonSession: NSObject, ObservableObject {
    @Published var isAuthenticated = false
    @Published var loginDidComplete = false  // fires when auto-detect dismisses login sheet

    let webView: WKWebView
    private let cookiesKey = "huntington_cookies"
    private var pendingNavigation: CheckedContinuation<Void, Error>?
    private var isInLoginFlow = false

    override init() {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(HuntingtonSession.loginResponsiveScript)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    private static let loginResponsiveScript: WKUserScript = {
        let css = """
        html, body { min-width: 0 !important; width: 100% !important; overflow-x: hidden !important; }
        *, *::before, *::after { box-sizing: border-box !important; }
        #header, #footerNav, #footerBottom, hr, .Messages, .buttonsCentered img, #fab-area, #site-survey { display: none !important; }
        #container, .container_16 { width: 100% !important; max-width: 100% !important; margin: 0 !important; padding: 0 !important; }
        .grid_1,.grid_2,.grid_3,.grid_4,.grid_5,.grid_6,.grid_7,.grid_8,.grid_9,.grid_10,.grid_11,.grid_12,.grid_13,.grid_14,.grid_15,.grid_16 { width: 100% !important; max-width: 100% !important; float: none !important; margin: 0 !important; padding: 0 !important; display: block !important; }
        #content { padding: 32px 20px !important; }
        .login { width: 100% !important; max-width: 100% !important; }
        .login .widget { max-width: 360px !important; margin: 0 auto !important; border-radius: 12px !important; overflow: hidden !important; box-shadow: 0 2px 12px rgba(0,0,0,0.12) !important; }
        div.widget-title { padding: 20px 20px 16px !important; height: auto !important; line-height: normal !important; }
        div.widget-title h3 { height: auto !important; font-size: 20px !important; line-height: 1.3 !important; white-space: normal !important; }
        #removebottomborder { padding: 20px !important; background: #fff !important; border: none !important; }
        dl.loginForm { width: 100% !important; margin: 0 !important; }
        dl.loginForm dt { float: none !important; width: 100% !important; font-size: 14px !important; font-weight: 600 !important; margin-bottom: 6px !important; color: #444 !important; }
        dl.loginForm dd { margin: 0 0 16px 0 !important; }
        dl.loginForm dd input { width: 100% !important; font-size: 16px !important; padding: 12px !important; border: 1px solid #ccc !important; border-radius: 8px !important; background: #f9f9f9 !important; }
        dl.loginForm dd input:focus { outline: none !important; border-color: #5ba63c !important; background: #fff !important; box-shadow: 0 0 0 3px rgba(91,166,60,0.15) !important; }
        .widget-footer { padding: 0 20px 20px !important; background: #fff !important; }
        .buttonsCentered { padding: 0 !important; margin: 0 !important; }
        .buttonsCentered input[type=submit] { display: block !important; width: 100% !important; padding: 14px !important; font-size: 16px !important; font-weight: 600 !important; margin-top: 4px !important; border-radius: 8px !important; border: none !important; background: #5ba63c !important; color: #fff !important; cursor: pointer !important; }
        .signonLinks { width: 100% !important; text-align: center !important; margin-top: 20px !important; line-height: 2.2 !important; }
        """
        let js = """
        (function() {
            if (!window.location.href.includes('Auth') && !window.location.href.includes('login')) return;
            const s = document.createElement('style');
            s.textContent = `\(css)`;
            (document.head || document.documentElement).appendChild(s);
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }()

    // MARK: - Lifecycle

    func initialize() async {
        guard let cookies = loadSavedCookies(), !cookies.isEmpty else { return }
        await restoreCookies(cookies)
        try? await navigate(to: URL(string: "https://m.huntington.com/")!)
        isAuthenticated = await checkAuthenticated()
    }

    func startLogin() async {
        isInLoginFlow = true
        try? await navigate(to: URL(string: "https://onlinebanking.huntington.com/rol/Auth/login.aspx")!)
    }

    func completeLogin() async {
        isInLoginFlow = false
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        saveCookies(cookies)
        try? await navigate(to: URL(string: "https://m.huntington.com/")!)
        isAuthenticated = true
        loginDidComplete = true
    }

    func signOut() {
        UserDefaults.standard.removeObject(forKey: cookiesKey)
        isAuthenticated = false
        Task {
            await webView.configuration.websiteDataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            )
        }
    }

    // MARK: - Fetch

    func fetch<T: Decodable>(_ url: String) async throws -> T {
        let js = """
        const res = await fetch(url, {
            headers: {
                'accept': 'application/json, text/javascript, */*; q=0.01',
                'x-requested-with': 'XMLHttpRequest',
                'referer': 'https://m.huntington.com/'
            }
        });
        if (!res.ok) {
            const body = await res.text();
            throw new Error('HTTP_' + res.status + ':' + body.slice(0, 300));
        }
        return JSON.stringify(await res.json());
        """

        let result = try await callJS(js, arguments: ["url": url])

        guard let jsonString = result as? String else {
            throw HuntingtonError.invalidResponse
        }

        return try JSONDecoder().decode(T.self, from: Data(jsonString.utf8))
    }

    private func callJS(_ functionBody: String, arguments: [String: Any]) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(functionBody, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Navigation

    private func navigate(to url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            pendingNavigation = continuation
            webView.load(URLRequest(url: url))
        }
    }

    private func checkAuthenticated() async -> Bool {
        let url = "https://m.huntington.com//dmm/fm-p/accounts/get/all.action?_=\(timestamp())"
        let js = """
        try {
            const res = await fetch(url, {
                headers: { 'accept': 'application/json', 'x-requested-with': 'XMLHttpRequest' }
            });
            return res.ok;
        } catch { return false; }
        """
        let result = try? await callJS(js, arguments: ["url": url])
        return result as? Bool ?? false
    }

    // MARK: - Cookie persistence

    private func saveCookies(_ cookies: [HTTPCookie]) {
        let data = cookies.compactMap { cookie -> [String: Any]? in
            guard let props = cookie.properties else { return nil }
            return Dictionary(uniqueKeysWithValues: props.map { ($0.key.rawValue, $0.value) })
        }
        UserDefaults.standard.set(data, forKey: cookiesKey)
    }

    private func loadSavedCookies() -> [HTTPCookie]? {
        guard let data = UserDefaults.standard.array(forKey: cookiesKey) as? [[String: Any]] else {
            return nil
        }
        return data.compactMap { dict in
            let props = Dictionary(uniqueKeysWithValues: dict.map {
                (HTTPCookiePropertyKey($0.key), $0.value)
            })
            return HTTPCookie(properties: props)
        }
    }

    private func restoreCookies(_ cookies: [HTTPCookie]) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for cookie in cookies {
            await store.setCookie(cookie)
        }
    }

    private func timestamp() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }
}

// MARK: - WKNavigationDelegate

extension HuntingtonSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pendingNavigation?.resume()
        pendingNavigation = nil

        // Auto-detect login completion: once we leave the auth pages, we're in
        if isInLoginFlow, let url = webView.url?.absoluteString,
           url.contains("onlinebanking.huntington.com"),
           !url.contains("/Auth/"), !url.contains("/login") {
            Task { await completeLogin() }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pendingNavigation?.resume(throwing: error)
        pendingNavigation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pendingNavigation?.resume(throwing: error)
        pendingNavigation = nil
    }
}
