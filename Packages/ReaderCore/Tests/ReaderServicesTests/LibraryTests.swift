import Foundation
import ReaderModels
@testable import ReaderServices
import RuleEngine
import Testing

@Suite("书架更新与服务容器")
@MainActor
struct LibraryTests {
    @Test func 合并书籍信息保留进度并统计新章节() {
        let shelf = BookshelfRepository(fileURL: tempDirectory().appendingPathComponent("shelf.json"))
        var book = Book(bookUrl: "https://a.com/1", origin: "https://a.com", name: "甲", author: "作者")
        book.totalChapterNum = 10
        book.durChapterIndex = 5
        book.customCoverUrl = "my.jpg"
        book.intro = "旧简介"
        shelf.add(book)

        var fresh = book
        fresh.totalChapterNum = 13
        fresh.latestChapterTitle = "第十三章"
        fresh.coverUrl = "new.jpg"
        fresh.durChapterIndex = 0
        fresh.intro = ""
        shelf.mergeMetadata(from: fresh)

        let merged = try! #require(shelf.book(book.bookUrl))
        #expect(merged.lastCheckCount == 3)
        #expect(merged.totalChapterNum == 13)
        #expect(merged.latestChapterTitle == "第十三章")
        #expect(merged.durChapterIndex == 5)
        #expect(merged.customCoverUrl == "my.jpg")
        #expect(merged.coverUrl == "new.jpg")
        #expect(merged.intro == "旧简介")
        #expect(merged.lastCheckTime > 0)

        // 第一次拿到目录（原来没有章节数）不算新章节
        var other = Book(bookUrl: "https://a.com/2", origin: "https://a.com", name: "乙", author: "")
        shelf.add(other)
        other.totalChapterNum = 50
        shelf.mergeMetadata(from: other)
        #expect(shelf.book(other.bookUrl)?.lastCheckCount == 0)
        #expect(shelf.book(other.bookUrl)?.totalChapterNum == 50)
    }

    @Test func 书架更新统计新章节与失败() async throws {
        let transport = StubTransport()
        let server = BookServer(transport: transport, titles: ["第一章", "第二章", "第三章"])
        let env = SourceEnvironment(http: transport, store: MemoryKeyValueStore(), deviceID: "test")
        let src = try jsonSource()
        let store = ChapterStore(root: tempDirectory())
        let shelf = BookshelfRepository(fileURL: tempDirectory().appendingPathComponent("shelf.json"))

        var updated = server.book(origin: src.bookSourceUrl)
        updated.totalChapterNum = 2
        var orphan = Book(bookUrl: "https://x.test/book/2", origin: "https://x.test", name: "二", author: "")
        orphan.tocUrl = "https://x.test/toc/2"
        let local = Book(bookUrl: "file:///a.txt", name: "本地")
        var frozen = Book(bookUrl: "https://j.test/book/3", origin: src.bookSourceUrl, name: "三", author: "")
        frozen.canUpdate = false
        for book in [updated, orphan, local, frozen] { shelf.add(book) }

        let updater = ShelfUpdater(shelf: shelf) { book in
            BookContentService(source: book.origin == src.bookSourceUrl ? src : nil, environment: env, store: store)
        }
        let report = await updater.refresh(shelf.books)

        #expect(report.checked == 2)
        #expect(report.updated == [updated.bookUrl])
        #expect(Array(report.failed.keys) == [orphan.bookUrl])
        let refreshed = try #require(shelf.book(updated.bookUrl))
        #expect(refreshed.totalChapterNum == 3)
        #expect(refreshed.lastCheckCount == 1)
        #expect(refreshed.latestChapterTitle == "第三章")
        #expect(store.loadChapters(bookUrl: updated.bookUrl)?.count == 3)
        #expect(!updater.isRefreshing)
    }

    @Test func 搜索历史去重限量与持久化() {
        let file = tempDirectory().appendingPathComponent("history.json")
        let history = SearchHistoryStore(fileURL: file)
        history.limit = 3
        for keyword in ["甲", "乙", "丙", "乙", " 丁 ", ""] { history.record(keyword) }
        #expect(history.keywords == ["丁", "乙", "丙"])
        history.remove("乙")
        history.flush()
        #expect(SearchHistoryStore(fileURL: file).keywords == ["丁", "丙"])
        history.clear()
        #expect(history.keywords.isEmpty)
    }

    @Test func 图片解密与磁盘缓存() async throws {
        let transport = StubTransport()
        let hits = HitCounter()
        transport.on("https://img.test/a.jpg") { request in
            hits.hit("a")
            return HTTPResponse(url: request.url, body: Data([1, 2, 3, 200]))
        }
        let env = SourceEnvironment(http: transport, store: MemoryKeyValueStore(), deviceID: "test")
        let directory = tempDirectory()
        let cache = ImageCache(directory: directory, environment: env)
        let src = try source("https://img.test", "图", extra: #","coverDecodeJs":"result.map(function(b){return b ^ 15})""#)

        let data = try await cache.data(for: "https://img.test/a.jpg", source: src)
        #expect(Array(data) == [14, 13, 12, UInt8(200 ^ 15)])
        #expect(try await cache.data(for: "https://img.test/a.jpg", source: src) == data)
        #expect(hits.count("a") == 1)

        let reopened = ImageCache(directory: directory, environment: env)
        #expect(try await reopened.data(for: "https://img.test/a.jpg", source: src) == data)
        #expect(hits.count("a") == 1)

        // 没有解密脚本时返回原始数据（与带脚本的结果分开缓存）
        #expect(Array(try await cache.data(for: "https://img.test/a.jpg", source: nil)) == [1, 2, 3, 200])
        #expect(Array(try await cache.data(for: "data:image/png;base64,AQID", source: nil)) == [1, 2, 3])
        #expect(await cache.totalSize() > 0)
        await cache.clear()
        #expect(await cache.totalSize() == 0)
    }

    @Test func 书源脚本刷新发现页() async throws {
        let services = LibraryServices(dataDirectory: tempDirectory(), cacheDirectory: tempDirectory(), http: StubTransport())
        let explore = "<js>var n = Number(source.get('n') || 0) + 1; source.put('n', String(n));"
            + "JSON.stringify([{title: '第' + n + '次'}, {title: '刷新', type: 'button', action: 'java.refreshExplore()'}])</js>"
        let src = try source("https://e.test", "E", extra: #","exploreUrl":"\#(explore)""#)
        services.apply(.bookSources([src]))
        var events: [String] = []
        services.onSourceEvent = { event in
            if case .refreshExplore(let key) = event { events.append(key) }
        }

        let session = services.exploreSession(for: src)
        #expect(services.exploreSession(for: src) === session)
        let list = services.exploreList(source: src, url: "/rank")
        #expect(services.exploreList(source: src, url: "/rank") === list)
        await session.load()
        #expect(session.kinds.first?.title == "第1次")

        await session.press(session.kinds[1])
        try await waitUntil { session.kinds.first?.title == "第2次" }
        #expect(session.kinds.first?.title == "第2次")
        #expect(events == ["https://e.test"])
        #expect(services.exploreList(source: src, url: "/rank") !== list)
    }

    @Test func 服务容器写入导入内容与搜索历史() async throws {
        let transport = StubTransport()
        transport.on("https://j.test/search", json: #"[{"n":"测试书","a":"作者","u":"/book/1"}]"#)
        let services = LibraryServices(dataDirectory: tempDirectory(), cacheDirectory: tempDirectory(), http: transport)
        let summary = services.apply(.bookSources([try jsonSource()]))
        #expect(summary == ImportSummary(added: 1))
        #expect(services.apply(.httpTTS([HttpTTS(id: 1, name: "朗读", url: "https://tts.test/{{speakText}}")])) == ImportSummary(added: 1))
        #expect(services.httpTTS.engine(id: 1)?.name == "朗读")

        services.startSearch(" 测试 ")
        #expect(services.searchHistory.keywords == ["测试"])
        try await waitUntil { !services.search.isSearching }
        #expect(services.search.results.map(\.name) == ["测试书"])

        let book = try #require(services.search.results.first).primary.toBook()
        let session = services.readerSession(for: book)
        #expect(session.book.bookUrl == "https://j.test/book/1")
        #expect(!session.isOnShelf)
    }
}
