import Foundation

/// Incremental highlighting is a correctness risk, not just a speed trick: get the carried-over
/// line state wrong and half the file turns into a comment. These checks apply random edits to
/// real-looking source and assert, after every single one, that the colouring the incremental
/// path produces is byte-for-byte what a full re-tokenize would have produced.
@MainActor
enum AuditHighlighter {

    /// The colour every UTF-16 position ends up with, which is what the text storage actually
    /// shows. Later tokens overwrite earlier ones, exactly as `addAttribute` does.
    static func map(_ tokens: [Token], length: Int) -> [TokenKind] {
        var kinds = [TokenKind](repeating: .plain, count: length)
        for token in tokens {
            let lower = max(0, token.range.location)
            let upper = min(length, token.range.location + token.range.length)
            guard lower < upper else { continue }
            for position in lower..<upper { kinds[position] = token.kind }
        }
        return kinds
    }

    static func fullMap(_ text: String, _ language: Language) -> [TokenKind] {
        map(Tokenizer.tokens(for: text, language: language), length: (text as NSString).length)
    }

    private struct Rand {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state
        }
        mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(max(1, bound))) }
    }

    private static let samples: [(Language, String)] = [
        (Languages.swift, """
        import Foundation
        /// Doc.
        @MainActor final class Store {
            let limit = 1_000
            var label = "n=\\(limit) ok"
            /* block
               comment */
            func run() throws -> Int? {
                #if DEBUG
                print("hi")
                #endif
                return nil
            }
        }
        """),
        (Languages.python, """
        import os

        @dataclass
        class Point:
            \"\"\"Doc
            string\"\"\"
            x: int = 0
            def go(self) -> str:
                return f"x={self.x}"  # note
        """),
        (Languages.json, """
        {
          "a": 1,
          "b": {"c": [true, null, -2.5e3], "d": "text"},
          "e": "last"
        }
        """),
        (Languages.javascript, """
        const f = async (x) => {
          // note
          const s = `a ${x.b()} c`;
          /* block */
          return s;
        };
        """),
        (Languages.markdown, """
        # Title
        Some **bold** text and `code`.

        ```swift
        let x = 1
        ```

        > quote
        - item
        """),
        (Languages.yaml, """
        # top
        name: build
        steps:
          - run: |
              echo one
              echo two
          - run: echo three
        """),
        (Languages.html, """
        <!DOCTYPE html>
        <div class="a"
             id="b">
          <!-- note
               more -->
          <script>
            const x = 1;
          </script>
        </div>
        """),
        (Languages.toml, """
        # header
        [table]
        a = "one"
        b = 2
        """),
        (Languages.shell, """
        #!/bin/bash
        set -e
        NAME="${1:-x}"
        if [ -n "$NAME" ]; then
          echo "hi $NAME"  # go
        fi
        """),
        (Languages.rust, """
        #[derive(Debug)]
        pub fn main() {
            /* outer /* inner */ still */
            let v: Vec<u8> = vec![1u8];
            let s = r#"raw
        string"#;
        }
        """),
        (Languages.ruby, """
        =begin
        block comment
        =end
        def greet(name)
          puts "hi #{name.upcase}"
        end
        """),
        (Languages.xml, """
        <?xml version="1.0"?>
        <root>
          <![CDATA[ raw
          data ]]>
          <item a="1"/>
        </root>
        """),
        (Languages.c, """
        #include <stdio.h>
        /* a
           b */
        int main(void) {
            printf("hi\\n");
            return 0;
        }
        """),
        (Languages.go, """
        package main
        func main() {
            s := `raw
        string`
            fmt.Println(s)
        }
        """),
        (Languages.sql, """
        -- note
        SELECT id FROM t
        /* block
           comment */
        WHERE x = 'a';
        """),
        (Languages.lua, """
        -- note
        local t = [[multi
        line]]
        print(t)
        """),
    ]

    /// Edits chosen to break a naive implementation: openers and closers of every multi-line
    /// construct the grammars know about.
    private static let insertions = ["x", "\n", "  ", "/*", "*/", "\"\"\"", "'''", "```", "\"",
                                     "'", "`", "#", "//", "-->", "<!--", "]]>", "<![CDATA[",
                                     "=begin", "=end", "[[", "]]", "{", "}", "\\(", ")", "${",
                                     "<script>", "</script>", "|", "- ", "r#\"", "\"#", "\n\n"]

    static func run(_ audit: Auditor) {
        audit.section("Highlighter — incremental equals full")

        var rand = Rand(state: 0xD1B5_4A32_D192_ED03)
        var totalEdits = 0
        var divergences: [String] = []

        for (language, sample) in samples {
            var text = sample
            let highlighter = IncrementalHighlighter(language: language, text: text)
            var current = map(highlighter.rebuild(text), length: (text as NSString).length)
            audit.check("\(language.name): initial pass matches full",
                        current == fullMap(text, language))

            for step in 0..<220 {
                let nsText = text as NSString
                let length = nsText.length
                let location = length == 0 ? 0 : rand.int(length + 1)
                let insert = rand.int(3) != 0
                var editedRange: NSRange
                var replacement: String

                if insert {
                    replacement = insertions[rand.int(insertions.count)]
                    editedRange = NSRange(location: location, length: 0)
                } else {
                    let deleteLength = min(rand.int(6) + 1, max(0, length - location))
                    guard deleteLength > 0 else { continue }
                    editedRange = NSRange(location: location, length: deleteLength)
                    replacement = ""
                }
                // Never split a surrogate pair; a real text view cannot produce that either.
                let safe = nsText.rangeOfComposedCharacterSequences(for: editedRange)
                editedRange = safe

                let newText = nsText.replacingCharacters(in: editedRange, with: replacement)
                let replacementLength = (replacement as NSString).length

                // Model what NSTextStorage does to the existing attributes: the edited span is
                // replaced, everything after it slides, and nothing else is touched.
                var shifted = [TokenKind]()
                shifted.reserveCapacity((newText as NSString).length)
                shifted.append(contentsOf: current[0..<editedRange.location])
                shifted.append(contentsOf: [TokenKind](repeating: .plain,
                                                       count: replacementLength))
                let tailStart = editedRange.location + editedRange.length
                if tailStart < current.count {
                    shifted.append(contentsOf: current[tailStart...])
                }

                let newRange = NSRange(location: editedRange.location, length: replacementLength)
                let (dirty, tokens) = highlighter.update(newText, editedRange: newRange)

                // Clear then re-apply, exactly as the text-storage delegate does.
                let clearLower = max(0, dirty.location)
                let clearUpper = min(shifted.count, dirty.location + dirty.length)
                if clearLower < clearUpper {
                    for position in clearLower..<clearUpper { shifted[position] = .plain }
                }
                for token in tokens {
                    let lower = max(0, token.range.location)
                    let upper = min(shifted.count, token.range.location + token.range.length)
                    guard lower < upper else { continue }
                    for position in lower..<upper { shifted[position] = token.kind }
                }

                current = shifted
                text = newText
                totalEdits += 1

                let expected = fullMap(text, language)
                if current != expected {
                    let firstBad = zip(current, expected).enumerated()
                        .first { $0.element.0 != $0.element.1 }?.offset ?? -1
                    let context = (text as NSString)
                        .substring(with: NSRange(location: max(0, firstBad - 20),
                                                 length: min(40, (text as NSString).length
                                                             - max(0, firstBad - 20))))
                    divergences.append("\(language.id) step \(step) at \(firstBad): "
                                       + context.debugDescription)
                    break
                }
            }
        }

        audit.check("\(totalEdits) random edits: incremental colouring equals a full pass",
                    divergences.isEmpty,
                    divergences.prefix(4).joined(separator: " | "))

        // The point of all this is speed, so measure it rather than assume it.
        audit.section("Highlighter — cost")
        var big = ""
        let unit = """
        /// Comment.
        struct Widget {
            let name = "value \\(index)"
            func run() -> Int { return 0x1f + 1_000 }
        }

        """
        while (big as NSString).length < 400_000 { big += unit }
        let highlighter = IncrementalHighlighter(language: Languages.swift, text: big)
        let fullStart = Date()
        _ = Tokenizer.tokens(for: big, language: Languages.swift)
        let fullMilliseconds = -fullStart.timeIntervalSinceNow * 1000

        let insertAt = (big as NSString).length / 2
        let edited = (big as NSString).replacingCharacters(
            in: NSRange(location: insertAt, length: 0), with: "z")
        let incrementalStart = Date()
        let (dirty, _) = highlighter.update(edited,
                                            editedRange: NSRange(location: insertAt, length: 1))
        let incrementalMilliseconds = -incrementalStart.timeIntervalSinceNow * 1000

        audit.check("one keystroke in a 400 KB file re-scans a small span",
                    dirty.length < 4_000, "re-scanned \(dirty.length) characters")
        audit.check(String(format: "one keystroke costs %.1f ms vs %.1f ms for a full pass",
                           incrementalMilliseconds, fullMilliseconds),
                    incrementalMilliseconds < fullMilliseconds / 4)
    }
}
