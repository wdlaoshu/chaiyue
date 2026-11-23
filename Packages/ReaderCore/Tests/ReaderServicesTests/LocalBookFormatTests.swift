import Foundation
import ReaderModels
@testable import ReaderServices
import Testing
import ZIPFoundation

// MARK: - 样本构造工具

private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data("figure".utf8)
private let coverPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data("cover".utf8)

private func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
private func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
private func le16(_ v: Int) -> [UInt8] { be16(v).reversed() }
private func le32(_ v: Int) -> [UInt8] { be32(v).reversed() }

private func set(_ bytes: inout [UInt8], _ offset: Int, _ value: [UInt8]) {
    bytes.replaceSubrange(offset..<offset + value.count, with: value)
}

private func writeFile(_ name: String, _ data: Data) throws -> URL {
    let url = tempDirectory().appendingPathComponent(name)
    try data.write(to: url)
    return url
}

private func writeZip(_ name: String, _ files: [(String, Data)]) throws -> URL {
    let url = tempDirectory().appendingPathComponent(name)
    let archive = try Archive(url: url, accessMode: .create)
    for (path, data) in files {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
    }
    return url
}

/// 16 个 UTF-16 单元，不含目录关键字
private let filler = "　　风吹过山岗，河水静静流淌。\n"
private func body(_ length: Int = 1200) -> String {
    String(repeating: filler, count: length / filler.utf16.count + 1)
}

// MARK: - PalmDB / MOBI

private func palmDB(type: String, records: [[UInt8]], name: String = "palm-test") -> Data {
    var header = Array(name.utf8.prefix(31)) + Array(repeating: 0, count: 32 - min(31, name.utf8.count))
    header += Array(repeating: 0, count: 28)
    header += Array(type.utf8) + be32(0) + be32(0) + be16(records.count)
    var offset = 78 + records.count * 8 + 2
    for (i, record) in records.enumerated() {
        header += be32(offset) + [0] + Array(be32(i).suffix(3))
        offset += record.count
    }
    header += [0, 0]
    return Data(header + records.flatMap { $0 })
}

/// 只用字面量的 PalmDOC 压缩（0x01–0x08 引导的原样字节段）
private func palmDocLiteral(_ bytes: [UInt8]) -> [UInt8] {
    let plain = { (b: UInt8) in b == 0 || (0x09...0x7F).contains(b) }
    var out: [UInt8] = []
    var i = 0
    while i < bytes.count {
        if plain(bytes[i]) {
            out.append(bytes[i])
            i += 1
        } else {
            let run = bytes[i..<min(i + 8, bytes.count)].prefix { !plain($0) }
            out.append(UInt8(run.count))
            out += run
            i += run.count
        }
    }
    return out
}

private struct MobiFields {
    var compression = 2
    var encryption = 0
    var version = 6
    var textLength = 0
    var textRecords = 1
    var firstImage = 0xFFFF_FFFF
    var extraFlags = 0
    var ncx = 0xFFFF_FFFF
    var fdst = 0xFFFF_FFFF
    var fragment = 0xFFFF_FFFF
    var skeleton = 0xFFFF_FFFF
    var exth: [(Int, [UInt8])] = []
    var fullName = "full-name"
}

private func mobiRecord0(_ f: MobiFields) -> [UInt8] {
    let headerLength = 0x108
    var r = [UInt8](repeating: 0, count: 16 + headerLength)
    set(&r, 0, be16(f.compression))
    set(&r, 4, be32(f.textLength))
    set(&r, 8, be16(f.textRecords))
    set(&r, 10, be16(4096))
    set(&r, 12, be16(f.encryption))
    set(&r, 16, Array("MOBI".utf8))
    set(&r, 20, be32(headerLength))
    set(&r, 24, be32(2))
    set(&r, 28, be32(65001))
    set(&r, 36, be32(f.version))
    for offset in [80, 192, 244, 248, 252] { set(&r, offset, be32(0xFFFF_FFFF)) }
    set(&r, 108, be32(f.firstImage))
    set(&r, 128, be32(0x40))
    set(&r, 192, be32(f.fdst))
    set(&r, 242, be16(f.extraFlags))
    set(&r, 244, be32(f.ncx))
    set(&r, 248, be32(f.fragment))
    set(&r, 252, be32(f.skeleton))
    var exth: [UInt8] = []
    for (type, data) in f.exth { exth += be32(type) + be32(data.count + 8) + data }
    var block = Array("EXTH".utf8) + be32(12 + exth.count) + be32(f.exth.count) + exth
    while block.count % 4 != 0 { block.append(0) }
    r += block
    let name = Array(f.fullName.utf8)
    set(&r, 84, be32(r.count))
    set(&r, 88, be32(name.count))
    return r + name + [0, 0]
}

private func varint(_ value: Int) -> [UInt8] {
    var bytes = [UInt8(value & 0x7F) | 0x80]
    var rest = value >> 7
    while rest > 0 {
        bytes.insert(UInt8(rest & 0x7F), at: 0)
        rest >>= 7
    }
    return bytes
}

/// INDX 索引：头记录（TAGX，每个标签一位掩码）、一个数据记录，`strings` 非空时再加一个 CNCX 记录。
/// 返回记录与各字符串在 CNCX 中的偏移
private func indexRecords(tags: [(tag: Int, values: Int)], entries: [(key: String, values: [Int: [Int]])],
                          strings: [String] = []) -> (records: [[UInt8]], offsets: [Int]) {
    var cncx: [UInt8] = []
    var offsets: [Int] = []
    for string in strings {
        offsets.append(cncx.count)
        cncx += varint(string.utf8.count) + Array(string.utf8)
    }
    var tagx = Array("TAGX".utf8) + be32(12 + (tags.count + 1) * 4) + be32(1)
    for (i, tag) in tags.enumerated() { tagx += [UInt8(tag.tag), UInt8(tag.values), UInt8(1 << i), 0] }
    tagx += [0, 0, 0, 1]
    var header = Array("INDX".utf8) + be32(56) + Array(repeating: 0, count: 48)
    set(&header, 24, be32(1))
    set(&header, 28, be32(65001))
    set(&header, 36, be32(entries.count))
    set(&header, 52, be32(strings.isEmpty ? 0 : 1))
    header += tagx

    var data = Array("INDX".utf8) + Array(repeating: 0, count: 28)
    var entryOffsets: [Int] = []
    for entry in entries {
        entryOffsets.append(data.count)
        var control = 0
        var values: [UInt8] = []
        for (i, tag) in tags.enumerated() {
            guard let tagValues = entry.values[tag.tag] else { continue }
            control |= 1 << i
            values += tagValues.flatMap(varint)
        }
        data += [UInt8(entry.key.utf8.count)] + Array(entry.key.utf8) + [UInt8(control)] + values
    }
    let idxt = data.count
    data += Array("IDXT".utf8) + entryOffsets.flatMap(be16)
    set(&data, 20, be32(idxt))
    set(&data, 24, be32(entries.count))
    return ([header, data] + (strings.isEmpty ? [] : [cncx]), offsets)
}

private func byteOffset(_ text: String, of needle: String) -> Int {
    text.utf8.count - text[text.range(of: needle)!.lowerBound...].utf8.count
}

/// KF6：NCX 分章、EXTH 元数据与封面、recindex 图片、PalmDOC 压缩与多字节/附加数据尾
private func kf6Mobi(withNCX: Bool = true) -> Data {
    let html = """
    <html><head><guide></guide></head><body><p>封面页文字</p><mbp:pagebreak/>\
    <h2>第一章 起</h2><p>甲乙丙。</p><p><img recindex="00001" /></p><mbp:pagebreak/>\
    <h2>第二章 承</h2><p>丁戊己&amp;庚。</p></body></html>
    """
    let text = Array(html.utf8)
    let half = text.count / 2
    // 附加数据：多字节补齐字节 0x00（去掉 1 字节）+ 一项 2 字节的附加数据
    let records = [Array(text[..<half]), Array(text[half...])].map { palmDocLiteral($0) + [0x00, 0xAA, 0x82] }
    var fields = MobiFields(textLength: text.count, textRecords: 2, firstImage: 3, extraFlags: 0b11)
    fields.exth = [(503, Array("测试 MOBI".utf8)), (100, Array("作者甲".utf8)), (103, Array("<p>简介<b>文字</b></p>".utf8)),
                   (201, be32(1))]
    var all = records + [Array(png), Array(coverPNG)]
    if withNCX {
        fields.ncx = all.count + 1
        let index = indexRecords(tags: [(1, 1), (3, 1), (4, 1)], entries: [], strings: ["第一章 起", "第二章 承"])
        let entries = [
            ("0", [1: [byteOffset(html, of: "<h2>第一章")], 3: [index.offsets[0]], 4: [0]]),
            ("1", [1: [byteOffset(html, of: "<h2>第二章")], 3: [index.offsets[1]], 4: [0]]),
        ]
        all += indexRecords(tags: [(1, 1), (3, 1), (4, 1)], entries: entries, strings: ["第一章 起", "第二章 承"]).records
    }
    return palmDB(type: "BOOKMOBI", records: [mobiRecord0(fields)] + all)
}

private func simpleMobi(_ html: String, _ configure: (inout MobiFields) -> Void = { _ in }) -> Data {
    let text = Array(html.utf8)
    var fields = MobiFields(textLength: text.count)
    configure(&fields)
    return palmDB(type: "BOOKMOBI", records: [mobiRecord0(fields), palmDocLiteral(text)])
}

/// KF8（AZW3）：FDST、skeleton/fragment 还原文件，NCX 用 fragment 位置定位，kindle:embed 图片
private func kf8Azw3() -> Data {
    let skeleton = #"<?xml version="1.0"?><html><head><title>文件</title></head><body aid="0"></body></html>"#
    let fragments = [
        #"<h1>第一章 风起</h1><p>正文一。</p><p><img src="kindle:embed:0001?mime=image/png"/></p>"#,
        #"<h1>第二章 云涌</h1><p>正文二。</p>"#,
    ]
    var flow = ""
    var skeletonEntries: [(key: String, values: [Int: [Int]])] = []
    var fragmentEntries: [(key: String, values: [Int: [Int]])] = []
    for (i, fragment) in fragments.enumerated() {
        let start = flow.utf8.count
        skeletonEntries.append((String(format: "SKEL%010d", i), [1: [1], 6: [start, skeleton.utf8.count]]))
        let insert = start + byteOffset(skeleton, of: "</body>")
        fragmentEntries.append((String(format: "%010d", insert), [6: [start + skeleton.utf8.count, fragment.utf8.count]]))
        flow += skeleton + fragment
    }
    let text = Array(flow.utf8)
    let fdst = Array("FDST".utf8) + be32(12) + be32(1) + be32(0) + be32(text.count)
    let skeletonIndex = indexRecords(tags: [(1, 1), (6, 2)], entries: skeletonEntries).records
    let fragmentIndex = indexRecords(tags: [(6, 2)], entries: fragmentEntries).records
    let labels = ["第一章 风起", "第二章 云涌"]
    let offsets = indexRecords(tags: [], entries: [], strings: labels).offsets
    let ncxIndex = indexRecords(tags: [(3, 1), (4, 1), (6, 2)], entries: [
        ("0", [3: [offsets[0]], 4: [0], 6: [0, 0]]),
        ("1", [3: [offsets[1]], 4: [0], 6: [1, 0]]),
    ], strings: labels).records

    var fields = MobiFields(compression: 1, version: 8, textLength: text.count, firstImage: 2)
    fields.fullName = "KF8 测试"
    fields.fdst = 3
    fields.skeleton = 4
    fields.fragment = 4 + skeletonIndex.count
    fields.ncx = fields.fragment + fragmentIndex.count
    return palmDB(type: "BOOKMOBI", records: [mobiRecord0(fields), text, Array(png), fdst] + skeletonIndex + fragmentIndex + ncxIndex)
}

// MARK: - UMD

private func umdFunction(_ type: Int, _ data: [UInt8]) -> [UInt8] { [0x23] + le16(type) + [0] + [UInt8(5 + data.count)] + data }
private func umdExtra(_ id: Int, _ data: [UInt8]) -> [UInt8] { [0x24] + le32(id) + le32(9 + data.count) + data }
private func utf16LE(_ text: String) -> [UInt8] { text.utf16.flatMap { le16(Int($0)) } }

private func zlib(_ bytes: [UInt8]) throws -> [UInt8] {
    let deflated = try (Data(bytes) as NSData).compressed(using: .zlib) as Data
    var a = 1, b = 0
    for byte in bytes {
        a = (a + Int(byte)) % 65521
        b = (b + a) % 65521
    }
    return [0x78, 0x9C] + deflated + be32(b << 16 | a)
}

private func umd(kind: UInt8 = 1) throws -> Data {
    let text = "第一章 开端\u{2029}　　春天来了。\u{2029}第二章 发展\u{2029}　　夏天到了。\u{2029}"
    let content = utf16LE(text)
    let second = utf16LE(String(text[..<text.range(of: "第二章")!.lowerBound])).count
    let split = content.count / 4 * 2
    var file = le32(0xDE9A_9B89)
    file += umdFunction(0x01, [kind, 0x01, 0x00])
    file += umdFunction(0x02, utf16LE("掌上之书"))
    file += umdFunction(0x03, utf16LE("掌柜"))
    file += umdFunction(0x0B, le32(content.count))
    file += umdFunction(0x83, le32(0x3001)) + umdExtra(0x3001, le32(0) + le32(second))
    let titles = ["第一章 开端", "第二章 发展"].flatMap { [UInt8(utf16LE($0).count)] + utf16LE($0) }
    file += umdFunction(0x84, le32(0x3002)) + umdExtra(0x3002, titles)
    // 正文块故意倒序存放，由 0x81 索引排序
    file += umdExtra(0x1002, try zlib(Array(content[split...])))
    file += umdExtra(0x1001, try zlib(Array(content[..<split])))
    file += umdFunction(0x81, le32(0x3003)) + umdExtra(0x3003, le32(0x1001) + le32(0x1002))
    file += umdFunction(0x82, [0x01] + le32(0x3004)) + umdExtra(0x3004, Array(coverPNG))
    file += umdFunction(0x0C, le32(file.count + 9))
    return Data(file)
}

// MARK: - 测试

@Suite("MOBI 解析")
struct MobiTests {
    let store = LocalBookStore(root: tempDirectory())

    @Test func PalmDOC解压与记录尾数据() {
        // "abc" + 回溯（距离 3、长度 6）+ 空格合并字节 + 2 字节原样段 + 0x00
        let input: [UInt8] = [0x61, 0x62, 0x63, 0x80, 0x1B, 0xF8, 0x02, 0xE4, 0xB8, 0x00]
        #expect(MobiParser.palmDocDecompress(input[...]) == Array("abcabcabc x".utf8) + [0xE4, 0xB8, 0x00])
        #expect(MobiParser.trailingSize([1, 2, 3, 0x00, 0xAA, 0x82], flags: 0b11) == 3)
        #expect(MobiParser.trailingSize([1, 2, 0x01, 0x05], flags: 0b01) == 2)
        #expect(MobiParser.trailingSize([1, 2, 3], flags: 0) == 0)
    }

    @Test func KF6按NCX分章并导出图片() throws {
        let result = try store.importBook(from: try writeFile("kf6.mobi", kf6Mobi()))
        let book = result.book
        let id = try #require(LocalBookStore.id(of: book))
        #expect(book.name == "测试 MOBI" && book.author == "作者甲" && book.intro == "简介文字")
        #expect(book.coverUrl == "localbook://\(id)/cover")
        #expect(try store.resourceData("localbook://\(id)/cover") == coverPNG)
        #expect(result.chapters.map(\.title) == ["前言", "第一章 起", "第二章 承"])

        let first = try store.content(for: book, chapter: result.chapters[1])
        #expect(first.contains("甲乙丙。") && !first.contains("丁戊己") && !first.contains("封面页"))
        let image = "localbook://\(id)/res/image00001.png"
        #expect(first.contains("<img src=\"\(image)\">"))
        #expect(try store.resourceData(image) == png)
        #expect(try store.content(for: book, chapter: result.chapters[2]).contains("丁戊己&庚。"))
        #expect(!store.isTextBook(book) && !store.isEpub(book))
        #expect(throws: LocalBookError.notTextBook) { try store.resplit(book, tocMode: .byLength) }

        // 目录文件丢失时从原文件重建
        try FileManager.default.removeItem(at: store.directory(id).appendingPathComponent("chapters.json"))
        #expect(try store.chapters(for: book).map(\.title) == result.chapters.map(\.title))
        #expect(try store.content(for: book, chapter: result.chapters[1]) == first)
        #expect(try store.resourceData(image) == png)
        #expect(throws: LocalBookError.fileMissing) { try store.resourceData("localbook://\(id)/res/../chapters.json") }
    }

    @Test func KF6没有NCX时按分页或标题分章() throws {
        let headings = try store.importBook(from: try writeFile("no-ncx.mobi", kf6Mobi(withNCX: false)))
        #expect(headings.chapters.map(\.title) == ["前言", "第一章 起", "第二章 承"])

        let paged = simpleMobi("<html><body><p>引子</p><mbp:pagebreak/><p>楔子</p><p>正文一。</p><mbp:pagebreak/><mbp:pagebreak/><p>尾声</p><p>正文二。</p></body></html>")
        let result = try store.importBook(from: try writeFile("paged.azw", paged))
        #expect(result.book.name == "full-name")
        #expect(result.chapters.map(\.title) == ["前言", "楔子", "尾声"])
        #expect(try store.content(for: result.book, chapter: result.chapters[1]) == "　　正文一。")
    }

    @Test func KF6按目录页filepos链接分章() throws {
        let template = """
        <html><body><p>目录</p><p><a filepos=AAAAAAAAAA>第一回</a></p><p><a filepos=BBBBBBBBBB>第二回</a></p>\
        <p><a filepos=CCCCCCCCCC>第三回</a></p><mbp:pagebreak/><p>一回正文</p><p>二回正文</p><p>三回正文</p></body></html>
        """
        var html = template
        for (placeholder, needle) in [("AAAAAAAAAA", "<p>一回"), ("BBBBBBBBBB", "<p>二回"), ("CCCCCCCCCC", "<p>三回")] {
            html = html.replacingOccurrences(of: placeholder, with: String(format: "%010d", byteOffset(template, of: needle)))
        }
        let result = try store.importBook(from: try writeFile("filepos.prc", simpleMobi(html)))
        #expect(result.chapters.map(\.title) == ["前言", "第一回", "第二回", "第三回"])
        #expect(try store.content(for: result.book, chapter: result.chapters[2]) == "　　二回正文")
    }

    @Test func KF8按skeleton与NCX分章() throws {
        let result = try store.importBook(from: try writeFile("kf8.azw3", kf8Azw3()))
        let id = try #require(LocalBookStore.id(of: result.book))
        #expect(result.book.name == "KF8 测试")
        #expect(result.chapters.map(\.title) == ["第一章 风起", "第二章 云涌"])
        let first = try store.content(for: result.book, chapter: result.chapters[0])
        #expect(first.contains("正文一。") && !first.contains("正文二") && !first.contains("文件"))
        #expect(first.contains("<img src=\"localbook://\(id)/res/image00001.png\">"))
        #expect(try store.content(for: result.book, chapter: result.chapters[1]).contains("正文二。"))
    }

    @Test func 加密或不支持的压缩给出明确提示() throws {
        let drm = simpleMobi("<p>x</p>") { $0.encryption = 2 }
        #expect(throws: LocalBookError.drmProtected) { try store.importBook(from: try writeFile("drm.azw", drm)) }
        let huff = simpleMobi("<p>x</p>") { $0.compression = 17480 }
        #expect(throws: LocalBookError.unsupportedVariant("暂不支持 HUFF/CDIC 压缩的 MOBI 文件，可先用 Calibre 转换为 EPUB 再导入")) {
            try store.importBook(from: try writeFile("huff.mobi", huff))
        }
        #expect(throws: LocalBookError.corruptFile("不是有效的 MOBI 文件")) {
            try store.importBook(from: try writeFile("bad.mobi", Data("not a mobi".utf8)))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).isEmpty)
    }

    @Test func 纯PalmDOC文本() throws {
        let text = "第一章 开端\n" + body() + "第二章 发展\n" + body()
        let raw = Array(text.utf8)
        let record0 = be16(2) + be16(0) + be32(raw.count) + be16(1) + be16(4096) + be32(0)
        let data = palmDB(type: "TEXtREAd", records: [record0, palmDocLiteral(raw)], name: "掌上文本")
        let result = try store.importBook(from: try writeFile("doc.prc", data))
        #expect(result.book.name == "掌上文本")
        #expect(result.chapters.map { $0.title } == ["第一章 开端", "第二章 发展"])
    }
}

@Suite("UMD 解析")
struct UmdTests {
    let store = LocalBookStore(root: tempDirectory())

    @Test func 文本型UMD() throws {
        let result = try store.importBook(from: try writeFile("掌上.umd", try umd()))
        let book = result.book
        let id = try #require(LocalBookStore.id(of: book))
        #expect(book.name == "掌上之书" && book.author == "掌柜")
        #expect(try store.resourceData("localbook://\(id)/cover") == coverPNG)
        #expect(result.chapters.map { $0.title } == ["第一章 开端", "第二章 发展"])
        #expect(try store.content(for: book, chapter: result.chapters[0]) == "　　春天来了。")
        #expect(try store.content(for: book, chapter: result.chapters[1]) == "　　夏天到了。")
    }

    @Test func 漫画型与损坏的UMD() throws {
        #expect(throws: LocalBookError.unsupportedVariant("暂不支持漫画型 UMD，只能导入文本型 UMD")) {
            try store.importBook(from: try writeFile("漫画.umd", try umd(kind: 2)))
        }
        #expect(throws: LocalBookError.corruptFile("不是有效的 UMD 文件")) {
            try store.importBook(from: try writeFile("坏.umd", Data("garbage!!!".utf8)))
        }
    }
}

@Suite("FB2 解析")
struct Fb2Tests {
    let store = LocalBookStore(root: tempDirectory())

    private var fb2: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
        <description><title-info><genre>prose</genre>
        <author><first-name>Lev</first-name><last-name>Tolstoy</last-name></author>
        <book-title>战争与和平</book-title><annotation><p>一部长篇小说。</p></annotation>
        <coverpage><image l:href="#cover.png"/></coverpage></title-info></description>
        <body><title><p>战争与和平</p></title>
        <section><title><p>第一卷</p></title>
        <section><title><p>第一章</p></title><p>彼得堡的晚会。</p><image l:href="#map.png"/></section>
        <section><title><p>第二章</p></title><p>安德烈 &amp; 公爵。</p></section>
        </section>
        <section><title><p>尾声</p></title><epigraph><p>题记</p></epigraph><p>结束。</p><empty-line/></section>
        </body>
        <body name="notes"><title><p>注释</p></title><section id="n1"><title><p>1</p></title><p>注一。</p></section></body>
        <binary id="cover.png" content-type="image/png">\(coverPNG.base64EncodedString())</binary>
        <binary id="map.png" content-type="image/png">\(png.base64EncodedString(options: .lineLength64Characters))</binary>
        </FictionBook>
        """
    }

    @Test func 按section分章并导出插图() throws {
        let result = try store.importBook(from: try writeFile("war.fb2", Data(fb2.utf8)))
        let book = result.book
        let id = try #require(LocalBookStore.id(of: book))
        #expect(book.name == "战争与和平" && book.author == "Lev Tolstoy" && book.intro == "一部长篇小说。")
        #expect(try store.resourceData("localbook://\(id)/cover") == coverPNG)
        #expect(result.chapters.map(\.title) == ["第一卷", "第一章", "第二章", "尾声", "注释"])
        #expect(result.chapters.map(\.isVolume) == [true, false, false, false, false])
        let first = try store.content(for: book, chapter: result.chapters[1])
        #expect(first.contains("彼得堡的晚会。") && first.contains("<img src=\"localbook://\(id)/res/map.png\">"))
        #expect(try store.resourceData("localbook://\(id)/res/map.png") == png)
        #expect(try store.content(for: book, chapter: result.chapters[2]) == "　　安德烈 & 公爵。")
        #expect(try store.content(for: book, chapter: result.chapters[3]) == "　　题记\n　　结束。")
        #expect(try store.content(for: book, chapter: result.chapters[4]) == "　　1\n　　注一。")
    }

    @Test func 压缩的FB2() throws {
        let url = try writeZip("war.fb2.zip", [("book/war.fb2", Data(fb2.utf8))])
        #expect(LocalBookStore.canImport(url))
        let result = try store.importBook(from: url)
        #expect(result.chapters.count == 5)
        #expect(try #require(store.fileURL(for: result.book)).lastPathComponent == "book.fbz")
    }
}

@Suite("DOCX 解析")
struct DocxTests {
    let store = LocalBookStore(root: tempDirectory())

    private let namespaces = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture""#

    private func paragraph(_ text: String, style: String? = nil) -> String {
        "<w:p>" + (style.map { #"<w:pPr><w:pStyle w:val="\#($0)"/></w:pPr>"# } ?? "") + "<w:r><w:t>\(text)</w:t></w:r></w:p>"
    }

    private func docx(_ name: String, body: String, extra: [(String, Data)] = []) throws -> URL {
        let document = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document \#(namespaces)><w:body>\#(body)</w:body></w:document>"#
        let styles = """
        <?xml version="1.0" encoding="UTF-8"?><w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:style w:type="paragraph" w:styleId="1"><w:name w:val="heading 1"/></w:style>
        <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/></w:style>
        <w:style w:type="paragraph" w:styleId="MyChapter"><w:name w:val="自定义章"/><w:basedOn w:val="Heading2"/></w:style>
        <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/></w:style>
        </w:styles>
        """
        return try writeZip(name, [
            ("[Content_Types].xml", Data("<Types/>".utf8)),
            ("word/document.xml", Data(document.utf8)),
            ("word/styles.xml", Data(styles.utf8)),
        ] + extra)
    }

    @Test func 按标题样式分章并导出图片() throws {
        let body = paragraph("书名页", style: "Title") + paragraph("第一卷", style: "1")
            + #"<w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t xml:space="preserve">第一章 </w:t></w:r><w:r><w:t>春</w:t></w:r></w:p>"#
            + #"<w:p><w:r><w:t xml:space="preserve">春天 来了。</w:t></w:r><w:r><w:br/><w:t>第二行</w:t></w:r></w:p>"#
            + #"<w:p><w:r><w:drawing><wp:inline><a:graphic><a:graphicData><pic:pic><pic:blipFill><a:blip r:embed="rId5"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"#
            + #"<w:p><w:pPr><w:outlineLvl w:val="1"/></w:pPr><w:r><w:t>第二章 夏</w:t></w:r></w:p>"#
            + #"<w:p><w:r><w:t>夏天到了。</w:t></w:r><w:del><w:r><w:delText>删掉的</w:delText></w:r></w:del></w:p>"#
            + paragraph("第三章 秋", style: "MyChapter") + paragraph("秋天。")
        let rels = #"<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/></Relationships>"#
        let core = #"<?xml version="1.0"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>文档之书</dc:title><dc:creator>某人</dc:creator></cp:coreProperties>"#
        let url = try docx("doc.docx", body: body, extra: [
            ("word/_rels/document.xml.rels", Data(rels.utf8)),
            ("word/media/image1.png", png),
            ("docProps/core.xml", Data(core.utf8)),
        ])
        let result = try store.importBook(from: url)
        let id = try #require(LocalBookStore.id(of: result.book))
        #expect(result.book.name == "文档之书" && result.book.author == "某人")
        #expect(result.chapters.map(\.title) == ["前言", "第一卷", "第一章 春", "第二章 夏", "第三章 秋"])
        #expect(result.chapters.map(\.isVolume) == [false, true, false, false, false])
        let first = try store.content(for: result.book, chapter: result.chapters[2])
        #expect(first == "　　春天 来了。\n　　第二行\n　　<img src=\"localbook://\(id)/res/image1.png\">")
        #expect(try store.resourceData("localbook://\(id)/res/image1.png") == png)
        #expect(try store.content(for: result.book, chapter: result.chapters[3]) == "　　夏天到了。")
    }

    @Test func 没有标题样式时按目录规则或长度分章() throws {
        let bodyLines = body().split(separator: "\n").map(String.init)
        let lines = ["第一章 开端"] + bodyLines + ["第二章 发展"] + bodyLines
        let result = try store.importBook(from: try docx("plain.docx", body: lines.map { paragraph($0) }.joined()))
        #expect(result.chapters.map { $0.title } == ["第一章 开端", "第二章 发展"])
        #expect(result.book.name == "plain")

        let long = String(repeating: paragraph(String(repeating: "字", count: 99)), count: 120)
        let byLength = try store.importBook(from: try docx("long.docx", body: long))
        #expect(byLength.chapters.map(\.title) == ["第1节", "第2节", "第3节"])

        #expect(throws: LocalBookError.corruptFile("DOCX 中缺少正文（word/document.xml）")) {
            try store.importBook(from: try writeZip("empty.docx", [("a.txt", Data("x".utf8))]))
        }
    }
}

@Suite("HTML、Markdown 与 RTF")
struct MarkupBookTests {
    let store = LocalBookStore(root: tempDirectory())

    @Test func HTML按h1到h3分章() throws {
        let html = """
        <html><head><meta charset="gbk"><title>网页书</title><meta name="author" content="网页作者"></head><body>
        <p>序言文字</p><h1>第一卷</h1><h2>第一章</h2><p>甲&amp;乙</p>
        <img src="data:image/png;base64,\(png.base64EncodedString())"><img src="images/a.png"><img src="https://example.com/b.jpg">
        <h3>第二章</h3><p>丙</p><script>脚本</script><h4>小节</h4><p>丁</p></body></html>
        """
        let data = try #require(html.data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))))
        let result = try store.importBook(from: try writeFile("page.html", data))
        let id = try #require(LocalBookStore.id(of: result.book))
        #expect(result.book.name == "网页书" && result.book.author == "网页作者")
        #expect(result.chapters.map(\.title) == ["前言", "第一卷", "第一章", "第二章"])
        #expect(result.chapters[1].isVolume)
        let first = try store.content(for: result.book, chapter: result.chapters[2])
        #expect(first == "　　甲&乙\n　　<img src=\"localbook://\(id)/res/image1.png\">\n　　<img src=\"https://example.com/b.jpg\">")
        #expect(try store.content(for: result.book, chapter: result.chapters[3]) == "　　丙\n　　小节\n　　丁")
    }

    @Test func Markdown按井号标题分章() throws {
        let markdown = """
        ---
        title: "标记之书"
        author: 码农
        ---
        # 第一章 开始
        这是**粗体**、*斜体*和[链接](http://x.test)。
        ![图](https://example.com/a.png)
        ![本地图](local.png)

        ## 第一节
        - 列表项 `代码`
        ```
        # 代码里的井号
        ```
        第二章 下划线
        ---
        正文二 \\*星号\\*
        #### 四级标题
        """
        let result = try store.importBook(from: try writeFile("notes.md", Data(markdown.utf8)))
        #expect(result.book.name == "标记之书" && result.book.author == "码农")
        #expect(result.chapters.map(\.title) == ["第一章 开始", "第一节", "第二章 下划线"])
        #expect(try store.content(for: result.book, chapter: result.chapters[0])
            == "　　这是粗体、斜体和链接。\n　　<img src=\"https://example.com/a.png\">")
        #expect(try store.content(for: result.book, chapter: result.chapters[1]) == "　　• 列表项 代码\n　　# 代码里的井号")
        #expect(try store.content(for: result.book, chapter: result.chapters[2]) == "　　正文二 *星号*\n　　四级标题")
    }

    @Test func RTF转纯文本后分章() throws {
        func rtf(_ text: String) -> String {
            var out = #"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}\f0 "#
            for scalar in text.unicodeScalars {
                switch scalar {
                case "\n": out += "\\par\n"
                case "\\", "{", "}": out += "\\" + String(scalar)
                case _ where scalar.isASCII: out += String(scalar)
                default:
                    for unit in String(scalar).utf16 { out += "\\u\(Int16(bitPattern: unit))?" }
                }
            }
            return out + "}"
        }
        let text = "第一章 开端\n" + body() + "第二章 发展\n" + body()
        let result = try store.importBook(from: try writeFile("rich.rtf", Data(rtf(text).utf8)))
        #expect(result.chapters.map { $0.title } == ["第一章 开端", "第二章 发展"])
        #expect(try store.content(for: result.book, chapter: result.chapters[1]).hasPrefix("　　风吹过山岗，河水静静流淌。\n"))
        #expect(throws: LocalBookError.corruptFile("无法解析 RTF 文件")) {
            try store.importBook(from: try writeFile("bad.rtf", Data("plain".utf8)))
        }
    }
}
