import Foundation
import Testing

@testable import CopyzCore

@Suite("Transform catalogue")
struct TransformCatalogTests {
  private func run(_ id: String, _ input: String) -> String? {
    TransformCatalog.named(id)?.run(input)
  }

  private func expect(_ id: String, _ input: String, _ expected: String) {
    #expect(run(id, input) == expected, "\(id) failed")
  }

  /// Asserts the transform declines to apply, so the UI can disable its row
  /// rather than handing back mangled text.
  private func expectNil(_ id: String, _ input: String) {
    #expect(run(id, input) == nil, "\(id) should not apply")
  }

  @Test("Catalogue is large and has no duplicate ids")
  func catalogueIsWellFormed() {
    #expect(TransformCatalog.all.count >= 60)
    let ids = TransformCatalog.all.map(\.id)
    #expect(Set(ids).count == ids.count, "duplicate transform ids")

    for transform in TransformCatalog.all {
      #expect(!transform.name.isEmpty, "\(transform.id) has no name")
      #expect(!transform.detail.isEmpty, "\(transform.id) has no detail")
    }
  }

  @Test("Every category has transforms")
  func allCategoriesPopulated() {
    for category in Transform.Category.allCases {
      #expect(
        !TransformCatalog.transforms(in: category).isEmpty,
        "\(category.rawValue) is empty"
      )
    }
  }

  @Test("Transforms return nil for empty input")
  func nilOnEmpty() {
    for transform in TransformCatalog.all {
      #expect(transform.run("") == nil, "\(transform.id) should not apply to empty input")
    }
  }

  @Test("No transform crashes on odd input")
  func noCrashesOnOddInput() {
    let nasty = [
      "\u{200D}\u{200D}\u{200D}",
      "🎉🇯🇵",
      "\n\n\n",
      "\t\t",
      "a\r\nb",
      "   ",
      "%@#$^&*()",
      "0",
      "-",
      "/",
      "{\"a\": [1, 2, {\"b\": null}]}",
      "Café",
      "very long \(String(repeating: "word ", count: 500))",
    ]
    for input in nasty {
      for transform in TransformCatalog.all {
        // The assertion is that this returns rather than traps.
        _ = transform.run(input)
      }
    }
  }

  // MARK: - Case

  @Test("Case conversions")
  func caseConversions() {
    expect("case.lowercase", "Hello World", "hello world")
    expect("case.UPPERCASE", "Hello World", "HELLO WORLD")
    expect("case.Capitalized", "hello world", "Hello World")
    expect("case.Title Case", "hello world", "Hello World")
    expect("case.Sentence case", "hELLO WORLD", "Hello world")
    // "INVERT CASE" is the catalogue display name, not the id.
    // INVERT CASE id is "case.invert"; the display name is "INVERT CASE".
    expect("case.invert", "Hello", "hELLO")
  }

  @Test("Identifier casing splits on words and case boundaries")
  func identifierCasing() {
    expect("case.snake", "createTable", "create_table")
    expect("case.snake", "createTable", "create_table")
    // Acronym runs stay whole rather than shattering into single letters.
    expect("case.snake", "HTTPServer", "httpserver")
    expect("case.kebab", "createTable", "create-table")
    expect("case.camel", "create-table", "createTable")
    expect("case.camel", "CreateTable", "createTable")
    expect("case.pascal", "create_table", "CreateTable")
    expect("case.constant", "createTable", "CREATE_TABLE")
    expect("case.dot", "createTable", "create.table")
    expect("case.path", "createTable", "create/table")
    expect("case.snake", "already_snake", "already_snake")
  }

  // MARK: - Text

  @Test("Trim and whitespace transforms")
  func whitespaceTransforms() {
    expect("text.trim", "  hello  ", "hello")
    expect("text.trim-leading", "    a\n    b", "a\nb")
    expect("text.squeeze-spaces", "a   b\n\nc", "a b c")
    expect("text.collapse-blank-lines", "a\n\n\n\nb", "a\n\nb")
    expect("text.remove-blanks", "a\n\nb", "a\nb")
    expect("text.tabs-to-spaces", "\tx", "    x")
    expect("text.spaces-to-tabs", "    x", "\tx")
  }

  @Test("Quote transforms")
  func quoteTransforms() {
    expect("text.escape-quotes", #"say "hi""#, #"say \"hi\""#)
    expect("text.no-quotes", #""quoted""#, "quoted")
    expect("text.no-quotes", "'single'", "single")
    // Unbalanced quotes are left alone rather than mangled.
    #expect(run("text.no-quotes", #""unbalanced"#) == #""unbalanced"#)
  }

  @Test("Transliteration to ASCII")
  func transliteration() {
    expect("text.Any-Latin; Latin-ASCII", "Café Über", "Cafe Uber")
    expect("text.Cyrillic-Latin", "Привет", "Privet")
  }

  @Test("Transliteration that cannot apply returns nil")
  func transliterationNotApplicable() {
    // Already pure ASCII, so ICU has nothing to do.
    #expect(run("text.Cyrillic-Latin", "plain ascii") == nil)
  }

  // MARK: - Encode

  @Test("Encoding transforms")
  func encodings() {
    expect("encode.base64", "hello", "aGVsbG8=")
    expect("encode.hex", "hi", "6869")
    expect(
      "encode.html-escape", "<a href=\"x\">&</a>", "&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;")
    expect("encode.base64url", "subject?>", "c3ViamVjdD8-")
    expect("encode.uri", "a b&c", "a%20b%26c")
  }

  @Test("Base64 URL encode strips padding")
  func base64URLNoPadding() {
    expect("encode.base64url", "a", "YQ")
    expect("encode.base64", "a", "YQ==")
    expect("encode.base64url-pad", "a", "YQ==")
  }

  // MARK: - Escape

  @Test("Escaping transforms")
  func escaping() {
    expect("escape.sql", "O'Brien", "O''Brien")
    expect("escape.shell", "it's", "'it'\\''s'")
    expect("escape.python", "it's\n", "'it\\'s\\n'")
    expect("escape.regex", "a.b*c", "a\\.b\\*c")
    expect("escape.json", "say \"hi\"", "say \\\"hi\\\"")
  }

  @Test("Shell quoting is safe against injection")
  func shellQuotingIsSafe() {
    // The classic breakout attempt must not escape the quotes.
    let quoted = run("escape.shell", "'; rm -rf /; echo '") ?? ""
    #expect(quoted.hasPrefix("'"))
    #expect(quoted.hasSuffix("'"))
  }

  // MARK: - Web

  @Test("JSON transforms")
  func jsonTransforms() {
    let json = #"{"b":2,"a":1}"#
    let pretty = run("web.json-pretty", json) ?? ""
    #expect(pretty.contains("\n"))
    #expect(pretty.contains("\"a\""))

    let minified = run("web.json-minify", pretty) ?? ""
    #expect(minified == #"{"a":1,"b":2}"#)
  }

  @Test("JSON pretty-print refuses invalid JSON")
  func jsonRejectsInvalid() {
    #expect(run("web.json-pretty", "not json") == nil)
  }

  @Test("Slug generation")
  func slug() {
    expect("web.slug", "Hello, World! This is 2024", "hello-world-this-is-2024")
    expect("web.slug", "Café Über", "cafe-uber")
    expectNil("web.slug", "!!!")
  }

  @Test("URL decode and query transforms")
  func urlTransforms() {
    expect("web.url-decode", "a%20b", "a b")
    let query = run("web.query", "https://x.com?a=1&bb=2") ?? ""
    #expect(query.contains("a  = 1"))
    #expect(query.contains("bb = 2"))
    #expect(run("web.query", "not a url") == nil)
  }

  @Test("HTML tag stripping")
  func stripTags() {
    expect("web.strip-tags", "<p>Hello <b>world</b></p>", "Hello world")
    expectNil("web.strip-tags", "<div></div>")
  }

  @Test("Markdown link generation")
  func markdownLink() {
    expect("web.markdown-link", "https://example.com", "[example.com](https://example.com)")
    #expect(run("web.markdown-link", "not a url") == nil)
  }

  // MARK: - Number

  @Test("Hashes match known vectors")
  func knownHashes() {
    expect(
      "number.sha256", "abc",
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    expect("number.md5", "abc", "900150983cd24fb0d6963f7d28e17f72")
  }

  @Test("CRC-32 matches the known vector")
  func crc32() {
    expect("number.crc32", "123456789", "3421780262")
  }

  @Test("Counts")
  func counts() {
    expect("number.chars", "héllo", "5")
    expect("number.bytes", "é", "2")
    expect("number.lines", "a\nb", "2")
    expect("number.words", "one two  three", "3")
    expect("number.sum", "1 + 2 + 3", "6")
    expectNil("number.sum", "no numbers here")
  }

  @Test("Roman numerals")
  func roman() {
    expect("number.roman", "4", "IV")
    expect("number.roman", "1987", "MCMLXXXVII")
    expectNil("number.roman", "0")
    expectNil("number.roman", "5000")
  }

  @Test("Epoch conversions round-trip")
  func epochRoundTrip() {
    let iso = run("number.epoch-to-date", "0") ?? ""
    #expect(iso.hasPrefix("1970-01-01"))
    expect("number.date-to-epoch", iso, "0")
    expectNil("number.date-to-epoch", "nonsense")
  }

  @Test("Base conversion")
  func baseConvert() {
    expect("number.base-convert", "255", "FF")
    expectNil("number.base-convert", "not a number")
  }

  // MARK: - Lines and sorting

  @Test("Line operations")
  func lineOperations() {
    expect("lines.reverse", "a\nb\nc", "c\nb\na")
    expect("lines.numbers-strip", "1. one\n2. two", "one\ntwo")
    expect("lines.prefix", "a\nb", "# a\n# b")
    expect("lines.unindent", "    a\n      b", "a\n  b")
  }

  @Test("Sorting")
  func sorting() {
    expect("sort.alpha", "banana\napple\ncherry", "apple\nbanana\ncherry")
    expect("sort.reverse-alpha", "banana\napple\ncherry", "cherry\nbanana\napple")
    expect("sort.length", "aaa\nb\ncc", "b\ncc\naaa")
    expect("sort.numeric", "10\n2\n1", "1\n2\n10")
    expect("sort.unique", "a\nb\na", "a\nb")
  }

  @Test("Sorting is case-insensitive and stable")
  func sortingStable() {
    expect("sort.alpha", "banana\nApple", "Apple\nbanana")
    // Equal keys keep their original relative order.
    expect("sort.length", "bb\naa", "aa\nbb")
  }

  // MARK: - Format

  @Test("CSV parsing handles quotes and embedded newlines")
  func csvParsing() {
    let rows = TransformCatalog.parseCSV("a,b\n\"has, comma\",\"has \"\"quotes\"\"\"\n")
    #expect(rows.count == 2)
    #expect(rows[0] == ["a", "b"])
    #expect(rows[1] == ["has, comma", "has \"quotes\""])
  }

  @Test("CSV to JSON and back")
  func csvJsonRoundTrip() {
    let json = run("format.csv-to-json", "name,age\nAda,36\n") ?? ""
    #expect(json.contains("\"name\""))
    #expect(json.contains("\"Ada\""))

    // Keys are sorted for determinism, so the header is age,name.
    let csv = run("format.json-to-csv", json) ?? ""
    #expect(csv.hasPrefix("age,name"))
    #expect(csv.contains("36,Ada"))
  }

  @Test("CSV to TSV")
  func delimitedConversions() {
    let tsv = run("format.csv-to-tsv", "a,b\n1,2") ?? ""
    #expect(tsv.contains("\t"))
    #expect(!tsv.contains(","))
  }

  @Test("Markdown table generation")
  func markdownTable() {
    let table = run("format.markdown-table", "name\tage\nAda\t36") ?? ""
    #expect(table.contains("| name | age |"))
    #expect(table.contains("| --- | --- |"))
    #expect(table.contains("Ada"))
  }

  @Test("Markdown table refuses single-column input")
  func markdownTableNeedsColumns() {
    #expect(run("format.markdown-table", "just one column") == nil)
  }

  @Test("Hard wrap respects word boundaries and the column limit")
  func hardWrap() {
    let wrapped = run("format.wrap", String(repeating: "word ", count: 60)) ?? ""
    for line in wrapped.split(separator: "\n") {
      #expect(line.count <= 80, "line too long: \(line.count)")
    }
  }

  @Test("Hard wrap breaks words longer than the limit")
  func hardWrapBreaksLongWords() {
    let url = "https://example.com/" + String(repeating: "a", count: 300)
    let wrapped = run("format.wrap", url) ?? ""
    for line in wrapped.split(separator: "\n") {
      #expect(line.count <= 80, "line too long: \(line.count)")
    }
    #expect(wrapped.replacingOccurrences(of: "\n", with: "").contains("example"))
  }

  // MARK: - Path

  @Test("Path transforms")
  func pathTransforms() {
    expect("path.basename", "/Users/me/notes/todo.md", "todo.md")
    expect("path.extension", "/Users/me/notes/todo.md", "md")
    expect("path.stem", "/Users/me/notes/todo.md", "todo")
    expect("path.dirname", "/Users/me/notes/todo.md", "/Users/me/notes")
    expect(
      "path.untilde", "~/notes", FileManager.default.homeDirectoryForCurrentUser.path + "/notes")
  }

  @Test("Tilde shortening round-trips")
  func tildeRoundTrip() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let expanded = run("path.untilde", "~/notes") ?? ""
    expect("path.tilde", expanded, "~/notes")
    #expect(expanded.hasPrefix(home))
  }
}
