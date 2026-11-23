import Foundation
@testable import ReaderPlatform
import RuleEngine
import Testing
import WebKit

@MainActor
/// 按轮询次数计算超时：WebKit 启动网页进程时会阻塞主线程，阻塞期间不消耗等待时间
private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let interval = Duration.milliseconds(20)
    var remaining = Int(timeout / interval)
    while !condition() {
        if remaining <= 0 { throw RuleError.message("等待超时") }
        try await Task.sleep(for: interval)
        remaining -= 1
    }
}

/// 在独立线程上执行，模拟规则引擎的工作线程
private func onWorkerThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result { try body() }) }.start()
    }
}

private func environment() -> SourceEnvironment {
    SourceEnvironment(store: MemoryKeyValueStore(), deviceID: "platform-test")
}

@Suite("WebKit 后台渲染", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct WebViewRendererTests {
    let env = environment()

    /// 机器负载高时首次启动 WebKit 网页进程可超过 20 秒
    private func render(_ request: WebViewRequest) async throws -> String {
        try await WebViewRenderer.render(request, environment: env, timeout: .seconds(45), dataStore: .nonPersistent())
    }

    @Test func 执行脚本取结果() async throws {
        let request = WebViewRequest(html: "<html><body><p id='x'>你好</p></body></html>", url: "https://render.test/",
                                     js: "document.getElementById('x').textContent", sourceKey: "https://render.test")
        #expect(try await render(request) == "你好")
    }

    @Test func 没有脚本时取整页源码() async throws {
        let request = WebViewRequest(html: "<html><body><p id=\"x\">源码</p></body></html>", url: "https://render.test/",
                                     js: nil, sourceKey: "https://render.test")
        let html = try await render(request)
        #expect(html.hasPrefix("<html>"))
        #expect(html.contains("<p id=\"x\">源码</p>"))
    }

    @Test func 结果为空时每秒重试_空字符串算成功() async throws {
        let retry = WebViewRequest(html: "<p>a</p>", url: "https://render.test/",
                                   js: "window.n = (window.n || 0) + 1; window.n >= 3 ? 'n=' + window.n : null",
                                   sourceKey: "k")
        let start = ContinuousClock.now
        #expect(try await render(retry) == "n=3")
        #expect(ContinuousClock.now - start >= .milliseconds(2900))

        let empty = WebViewRequest(html: "<p>a</p>", url: "https://render.test/", js: "''", sourceKey: "k")
        #expect(try await render(empty) == "")
    }

    @Test func 嗅探跳转地址() async throws {
        let html = "<script>setTimeout(function(){ location.href = 'https://render.test/play/1.m3u8?t=1' }, 50)</script>"
        let request = WebViewRequest(html: html, url: "https://render.test/", js: nil, sourceKey: "k",
                                     sourceRegex: ".*\\.m3u8.*")
        #expect(try await render(request) == "https://render.test/play/1.m3u8?t=1")
    }

    @Test func 没有地址也没有页面时报错() async {
        let request = WebViewRequest(html: nil, url: nil, js: nil, sourceKey: "k")
        await #expect(throws: RuleError.self) { try await render(request) }
    }
}

@Suite("Cookie 同步", .timeLimit(.minutes(1)))
@MainActor
struct CookieSyncTests {
    @Test func 双向同步() async throws {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        defer { withExtendedLifetime(dataStore) {} }
        let store = dataStore.httpCookieStore
        let cookies = CookieStore(store: MemoryKeyValueStore())
        cookies.setCookie(url: "https://c.test/a", cookie: "a=1; b=2")

        await CookieSync.push("https://c.test/a", from: cookies, to: store)
        #expect(await store.allCookies().map(\.name).sorted() == ["a", "b"])

        let local = try #require(HTTPCookie(properties: [.name: "c", .value: "3", .domain: ".c.test", .path: "/"]))
        let other = try #require(HTTPCookie(properties: [.name: "x", .value: "9", .domain: "other.test", .path: "/"]))
        let scoped = try #require(HTTPCookie(properties: [.name: "p", .value: "8", .domain: ".c.test", .path: "/admin"]))
        await store.setCookie(local)
        await store.setCookie(other)
        await store.setCookie(scoped)

        await CookieSync.pull("https://c.test/book", into: cookies, key: "https://c.test", from: store)
        let header = cookies.getCookie(url: "https://c.test")
        #expect(Set(header.components(separatedBy: "; ")) == ["a=1", "b=2", "c=3"])

        let session = try #require(HTTPCookie(properties: [.name: "sessionid", .value: "fq", .domain: ".fanqienovel.com", .path: "/"]))
        await store.setCookie(session)
        #expect(await CookieSync.pullAll(into: cookies, from: store))
        #expect(cookies.getCookie(url: "fanqienovel.com").contains("sessionid=fq"))
        #expect(cookies.getCookie(url: "https://fanqienovel.com/").contains("sessionid=fq"))
        #expect(!cookies.getCookie(url: "https://c.test").contains("sessionid"))
    }
}

@MainActor
private final class MockPresenter: SourceInteractionPresenter {
    var requests: [BrowserRequest] = []
    var code: String?
    var setCookieOnClose: HTTPCookie?
    var store: WKHTTPCookieStore?

    func presentBrowser(_ request: BrowserRequest, completion: @escaping @MainActor (BrowserResult?) -> Void) {
        requests.append(request)
        Task { @MainActor in
            if let setCookieOnClose, let store { await store.setCookie(setCookieOnClose) }
            completion(BrowserResult(url: request.url + "#done", body: "<html>ok</html>"))
        }
    }

    func presentVerificationCode(imageURL: String, sourceKey: String, completion: @escaping @MainActor (String?) -> Void) {
        completion(code)
    }
}

private final class Messages: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var all: [String] { lock.withLock { items } }
    func append(_ item: String) { lock.withLock { items.append(item) } }
}

@Suite("书源交互", .serialized, .timeLimit(.minutes(1)),
       .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil, "CI 上没有可交互的浏览器窗口"))
@MainActor
struct PlatformSourceUITests {
    let env = environment()
    let ui: PlatformSourceUI
    private let presenter = MockPresenter()
    let store = WKWebsiteDataStore.nonPersistent()

    init() {
        ui = PlatformSourceUI(environment: env)
        ui.dataStore = store
        ui.presenter = presenter
        presenter.store = store.httpCookieStore
    }

    @Test func 等待浏览器关闭并同步登录Cookie() async throws {
        presenter.setCookieOnClose = HTTPCookie(properties: [.name: "token", .value: "t1", .domain: "p.test", .path: "/"])
        let ui = ui
        let result = try await onWorkerThread {
            try ui.startBrowserAwait(url: "https://p.test/login", title: "登录", html: nil, sourceKey: "https://p.test")
        }
        #expect(result.url == "https://p.test/login#done")
        #expect(result.body == "<html>ok</html>")
        let request = try #require(presenter.requests.first)
        #expect(request.waitsForResult)
        #expect(request.style == .page)
        #expect(request.title == "登录")
        #expect(request.userAgent == env.webViewUserAgent)
        #expect(env.cookies.getCookie(url: "https://p.test") == "token=t1")
    }

    @Test func 不阻塞的浏览器请求() async throws {
        ui.startBrowser(url: "https://p.test/a", title: "A", html: nil, sourceKey: "k")
        ui.showBrowser(BrowserSheet(url: "https://p.test/b", title: nil, html: "<p>b</p>", js: "1", optionsJSON: "{\"h\":0.5}",
                                    sourceKey: "k"))
        try await waitUntil { presenter.requests.count == 2 }
        let urls = presenter.requests.map(\.url).sorted()
        #expect(urls == ["https://p.test/a", "https://p.test/b"])
        let sheet = try #require(presenter.requests.first { $0.url.hasSuffix("/b") })
        #expect(sheet.style == .sheet(optionsJSON: "{\"h\":0.5}"))
        #expect(sheet.html == "<p>b</p>")
        #expect(!sheet.waitsForResult)
    }

    @Test func 验证码输入与取消() async throws {
        let ui = ui
        presenter.code = "1234"
        #expect(try await onWorkerThread { try ui.verificationCode(imageURL: "https://p.test/c.png", sourceKey: "k") } == "1234")
        presenter.code = nil
        await #expect(throws: RuleError.self) {
            try await onWorkerThread { try ui.verificationCode(imageURL: "https://p.test/c.png", sourceKey: "k") }
        }
    }

    @Test func 没有界面或在主线程调用时报错() async throws {
        #expect(throws: RuleError.self) { try ui.verificationCode(imageURL: "x", sourceKey: "k") }
        ui.presenter = nil
        let headless = ui
        await #expect(throws: RuleError.self) {
            try await onWorkerThread { try headless.startBrowserAwait(url: "https://p.test", title: "", html: nil, sourceKey: "k") }
        }
        await #expect(throws: RuleError.self) {
            try await onWorkerThread { try headless.verificationCode(imageURL: "x", sourceKey: "k") }
        }
    }

    @Test func 后台渲染与超时() async throws {
        let ui = ui
        let request = WebViewRequest(html: "<p id='v'>渲染</p>", url: "https://p.test/", js: "document.getElementById('v').textContent",
                                     sourceKey: "k")
        #expect(try await onWorkerThread { try ui.renderWebView(request) } == "渲染")

        ui.renderTimeout = 1.5
        let never = WebViewRequest(html: "<p>x</p>", url: "https://p.test/", js: "null", sourceKey: "k")
        await #expect(throws: RuleError.self) { try await onWorkerThread { try ui.renderWebView(never) } }
    }

    @Test func 转发提示() {
        let messages = Messages()
        ui.onToast = { message, _ in messages.append(message) }
        ui.toast("已登录", long: false)
        #expect(messages.all == ["已登录"])
    }
}
