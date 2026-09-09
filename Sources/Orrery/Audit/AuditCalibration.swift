import Darwin
import Foundation

/// Calibration harness: isolated copy, `kind` separation, `--calibrate` dispatch,
/// and the real 7-record store still loading. Scripted backends, temp directories,
/// no quota. The live JSONValidator calibration run is not part of `--audit`.
@MainActor
enum AuditCalibration {

    static func run(_ audit: Auditor) async {
        isolation(audit)
        surrogateCriteriaHonesty(audit)
        surrogateReachability(audit)
        await isolationProven(audit)
        await timeoutStopsRun(audit)
        await failedCriteriaNotCleanAccept(audit)
        kindSeparation(audit)
        await flagParsing(audit)
        realStoreCopy(audit)
    }

    // MARK: - Copy / hash seams

    private static func isolation(_ audit: Auditor) {
        audit.section("Calibration — copy exclusions and flag-value trap")
        let root = Calibration.packageRoot
        let hasPackage = FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Package.swift").path)
        let hasSources = FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Sources/Orrery").path)
        audit.check("packageRoot is this working tree",
                    hasPackage && hasSources, root.path)
        audit.check("the copy skip set names .build, build, and scratchpad",
                    Calibration.copySkipNames.contains(".build")
                    && Calibration.copySkipNames.contains("build")
                    && Calibration.copySkipNames.contains("scratchpad"))

        let args = ["Orrery", "--calibrate",
                    "calibration-jsonvalidator author=grok", "/tmp/proj"]
        let flagVals = LaunchArguments.flagValues(in: args)
        let paths = LaunchArguments.positionalPaths(in: args)
        audit.check("--calibrate value is not treated as a project path",
                    flagVals.contains("calibration-jsonvalidator author=grok")
                    && paths == ["/tmp/proj"],
                    "paths=" + paths.joined(separator: ","))
        audit.check("--calibrate /tmp is not treated as a positional project path",
                    LaunchArguments.positionalPaths(
                        in: ["Orrery", "--calibrate", "/tmp"]).isEmpty)

        audit.equal("the defined task id is calibration-jsonvalidator",
                    Calibration.tasks.map(\.id), ["calibration-jsonvalidator"])
        let task = Calibration.task(id: "calibration-jsonvalidator")
        audit.check("the JSONValidator task requires the JSON audit section and the gate",
                    task?.requiresAcceptanceGate == true
                    && task?.requiredAuditSections.contains("Diagnostics — JSON (built in)") == true)
        audit.check("the unchanged tree does not reject unpaired surrogates",
                    !Calibration.jsonValidatorWorkPresent(in: root),
                    "the live task would pass without doing anything")
        audit.check("the unchanged AuditDiagnostics does not assert planted surrogate locations",
                    !Calibration.auditDiagnosticsMatchesSurrogates(in: root))
        audit.equal("fixed reviewer for grok is claude",
                    Calibration.fixedReviewer(for: .grok), Provider.claude)
        audit.equal("fixed reviewer for claude is grok",
                    Calibration.fixedReviewer(for: .claude), Provider.grok)
        audit.check("fixed reviewer is never the author",
                    Provider.allCases.allSatisfy {
                        Calibration.fixedReviewer(for: $0) != $0
                    })
    }

    // MARK: - Pass criteria are not a word search

    private static func surrogateCriteriaHonesty(_ audit: Auditor) {
        audit.section("Calibration — unpaired-surrogate criteria are behavioral")
        let comments = writeFakeTree(
            validator: "// unpaired surrogate 0xD800\n",
            diagnostics: "// DiagnosticsEngine.checkJSON ud800 first.column first.line\n")
        defer { try? FileManager.default.removeItem(at: comments) }
        audit.check("a comment mentioning surrogate does not satisfy the criteria",
                    !Calibration.jsonValidatorWorkPresent(in: comments))

        let alwaysPass = writeFakeTree(
            validator: "let word = \"unpaired surrogate\"\n",
            diagnostics: "audit.check(\"JSON: unpaired surrogate ud800 line column\", true)\n")
        defer { try? FileManager.default.removeItem(at: alwaysPass) }
        audit.check("an always-passing audit.check named surrogate does not satisfy the criteria",
                    !Calibration.jsonValidatorWorkPresent(in: alwaysPass))

        let realURL = Calibration.packageRoot
            .appendingPathComponent("Sources/Orrery/Diagnostics/JSONValidator.swift")
        let realSource = (try? String(contentsOf: realURL, encoding: .utf8)) ?? ""
        let dead = writeFakeTree(
            validator: realSource + "\nenum Dead { static func f() { if false { _ = 0xD800; _ = \"unpaired\" } } }\n",
            diagnostics: "DiagnosticsEngine.checkJSON(payload)\nud800\nfound.first?.line == 1\nfound.first?.column == 8\n")
        defer { try? FileManager.default.removeItem(at: dead) }
        audit.check("unreachable 0xD800/unpaired plus unrelated checker expressions do not satisfy",
                    !Calibration.jsonValidatorWorkPresent(in: dead))

        let live = writeFakeTree(validator: Calibration.exactSurrogateValidatorSource,
                                diagnostics: Calibration.exactSurrogateAuditDiagnosticsSource)
        defer { try? FileManager.default.removeItem(at: live) }
        audit.check("generated matching AuditDiagnostics covers every planted fixture",
                    Calibration.auditDiagnosticsMatchesSurrogates(in: live))
        audit.check("a validator that reports the exact planted line and column of each nested surrogate, with matching AuditDiagnostics calls, satisfies",
                    Calibration.jsonValidatorWorkPresent(in: live))

        let validatorOnly = writeFakeTree(
            validator: Calibration.exactSurrogateValidatorSource,
            diagnostics: "// no nearby checkJSON window required\n")
        defer { try? FileManager.default.removeItem(at: validatorOnly) }
        audit.check("a validator-only edit does not satisfy without matching AuditDiagnostics checks",
                    !Calibration.jsonValidatorWorkPresent(in: validatorOnly))

        let decoy = writeFakeTree(
            validator: Calibration.exactSurrogateValidatorSource,
            diagnostics: Calibration.surrogateAuditDiagnosticsSource(invokeJSONChecker: false))
        defer { try? FileManager.default.removeItem(at: decoy) }
        audit.check("an always-true audit.check with fixture literals and line/column assignments does not satisfy",
                    !Calibration.auditDiagnosticsMatchesSurrogates(in: decoy)
                    && !Calibration.jsonValidatorWorkPresent(in: decoy))

        let unusedFeed = writeFakeTree(
            validator: Calibration.exactSurrogateValidatorSource,
            diagnostics: Calibration.surrogateAuditDiagnosticsSource(
                jsonCheckerArgument: #"{"ok":true}"#))
        defer { try? FileManager.default.removeItem(at: unusedFeed) }
        audit.check("checkJSON of unrelated JSON plus unused fixture literals does not satisfy",
                    !Calibration.auditDiagnosticsMatchesSurrogates(in: unusedFeed)
                    && !Calibration.jsonValidatorWorkPresent(in: unusedFeed))

        let urlFeed = writeFakeTree(
            validator: Calibration.exactSurrogateValidatorSource,
            diagnostics: Calibration.surrogateAuditDiagnosticsSource(placeFixtureInURL: true))
        defer { try? FileManager.default.removeItem(at: urlFeed) }
        audit.check("checkJSON of clean JSON with the fixture in the url argument does not satisfy",
                    !Calibration.auditDiagnosticsMatchesSurrogates(in: urlFeed)
                    && !Calibration.jsonValidatorWorkPresent(in: urlFeed))

        let nestedFeed = writeFakeTree(
            validator: Calibration.exactSurrogateValidatorSource,
            diagnostics: Calibration.surrogateAuditDiagnosticsSource(
                placeFixtureInNestedClosure: true))
        defer { try? FileManager.default.removeItem(at: nestedFeed) }
        audit.check("checkJSON of clean JSON with the fixture in a nested closure does not satisfy",
                    !Calibration.auditDiagnosticsMatchesSurrogates(in: nestedFeed)
                    && !Calibration.jsonValidatorWorkPresent(in: nestedFeed))

        let unrelatedDiag = writeFakeTree(
            validator: Calibration.exactSurrogateValidatorSource,
            diagnostics: Calibration.surrogateAuditDiagnosticsSource(
                placeUnrelatedDiagnostic: true))
        defer { try? FileManager.default.removeItem(at: unrelatedDiag) }
        audit.check("an always-true audit.check that calls checkJSON on the fixture plus an unrelated Diagnostic(line:column:) does not satisfy",
                    !Calibration.auditDiagnosticsMatchesSurrogates(in: unrelatedDiag)
                    && !Calibration.jsonValidatorWorkPresent(in: unrelatedDiag))

        let unrelatedCmp = writeFakeTree(
            validator: Calibration.exactSurrogateValidatorSource,
            diagnostics: Calibration.surrogateAuditDiagnosticsSource(
                placeUnrelatedComparison: true))
        defer { try? FileManager.default.removeItem(at: unrelatedCmp) }
        audit.check("an enclosing audit.check that compares an unrelated diagnostic's line/column does not satisfy",
                    !Calibration.auditDiagnosticsMatchesSurrogates(in: unrelatedCmp)
                    && !Calibration.jsonValidatorWorkPresent(in: unrelatedCmp))

        let sharedEnclosing = writeFakeTree(
            validator: Calibration.exactSurrogateValidatorSource,
            diagnostics: Calibration.surrogateAuditDiagnosticsSource(
                shareEnclosingAssertions: true))
        defer { try? FileManager.default.removeItem(at: sharedEnclosing) }
        audit.check("one audit.check sharing unrelated line/column comparisons across nested checkJSON calls does not satisfy",
                    !Calibration.auditDiagnosticsMatchesSurrogates(in: sharedEnclosing)
                    && !Calibration.jsonValidatorWorkPresent(in: sharedEnclosing))

        let stored = writeFakeTree(
            validator: Calibration.exactSurrogateValidatorSource,
            diagnostics: Calibration.surrogateAuditDiagnosticsSource(
                storeCheckerResult: true))
        defer { try? FileManager.default.removeItem(at: stored) }
        audit.check("storing checkJSON results in a local variable and asserting that result's line/column satisfies",
                    Calibration.auditDiagnosticsMatchesSurrogates(in: stored)
                    && Calibration.jsonValidatorWorkPresent(in: stored))

        let named = writeFakeTree(
            validator: Calibration.exactSurrogateValidatorSource,
            diagnostics: Calibration.surrogateAuditDiagnosticsSource(
                namedClosureParameter: true))
        defer { try? FileManager.default.removeItem(at: named) }
        audit.check("a named closure parameter asserting line/column on the checker result satisfies",
                    Calibration.auditDiagnosticsMatchesSurrogates(in: named)
                    && Calibration.jsonValidatorWorkPresent(in: named))

        let namedUnrelated = writeFakeTree(
            validator: Calibration.exactSurrogateValidatorSource,
            diagnostics: Calibration.surrogateAuditDiagnosticsSource(
                placeUnrelatedNamedClosure: true))
        defer { try? FileManager.default.removeItem(at: namedUnrelated) }
        audit.check("a named closure parameter that compares an unrelated diagnostic's line/column does not satisfy",
                    !Calibration.auditDiagnosticsMatchesSurrogates(in: namedUnrelated)
                    && !Calibration.jsonValidatorWorkPresent(in: namedUnrelated))

        let highOnlyTree = writeFakeTree(
            validator: highOnlySurrogateValidatorSource,
            diagnostics: Calibration.exactSurrogateAuditDiagnosticsSource)
        defer { try? FileManager.default.removeItem(at: highOnlyTree) }
        audit.check("detecting only unpaired high surrogates does not satisfy unpaired low surrogates",
                    !Calibration.jsonValidatorWorkPresent(in: highOnlyTree))

        let topOnly = """
        import Foundation
        enum JSONValidator {
            static func allowsComments(_ url: URL) -> Bool { return false }
            static func validate(_ text: String, url: URL) -> [Diagnostic] {
                if text == "{\\"x\\":\\"\\\\ud800\\"}" {
                    return [Diagnostic(file: url, line: 1, column: 7, severity: .error,
                                       message: "unpaired UTF-16 surrogate", source: "JSON")]
                }
                return []
            }
        }
        """
        let topOnlyTree = writeFakeTree(
            validator: topOnly,
            diagnostics: Calibration.exactSurrogateAuditDiagnosticsSource)
        defer { try? FileManager.default.removeItem(at: topOnlyTree) }
        audit.check("detecting a lone high surrogate only at top level does not satisfy nested positions",
                    !Calibration.jsonValidatorWorkPresent(in: topOnlyTree))

        let offByOne = Calibration.exactSurrogateValidatorSource
            .replacingOccurrences(of: "column: column,", with: "column: column + 1,")
        let offTree = writeFakeTree(
            validator: offByOne,
            diagnostics: Calibration.exactSurrogateAuditDiagnosticsSource)
        defer { try? FileManager.default.removeItem(at: offTree) }
        audit.check("an off-by-one column on a nested surrogate does not satisfy",
                    !Calibration.jsonValidatorWorkPresent(in: offTree))

        let topDiag = writeFakeTree(
            validator: Calibration.exactSurrogateValidatorSource,
            diagnostics: Calibration.surrogateAuditDiagnosticsSource(
                covering: Array(Calibration.surrogateFixtures.prefix(1))))
        defer { try? FileManager.default.removeItem(at: topDiag) }
        audit.check("AuditDiagnostics covering only the top-level high fixture does not satisfy",
                    !Calibration.jsonValidatorWorkPresent(in: topDiag))

        let offDiag = writeFakeTree(
            validator: Calibration.exactSurrogateValidatorSource,
            diagnostics: Calibration.surrogateAuditDiagnosticsSource(columnOffset: 1))
        defer { try? FileManager.default.removeItem(at: offDiag) }
        audit.check("AuditDiagnostics with an off-by-one column does not satisfy",
                    !Calibration.jsonValidatorWorkPresent(in: offDiag))

        let rejectAllTree = writeFakeTree(
            validator: rejectAllSurrogateValidatorSource,
            diagnostics: Calibration.exactSurrogateAuditDiagnosticsSource)
        defer { try? FileManager.default.removeItem(at: rejectAllTree) }
        audit.check("rejecting a valid paired surrogate does not satisfy",
                    !Calibration.jsonValidatorWorkPresent(in: rejectAllTree))
    }

    /// Coverage is executing checkJSON on the planted fixtures, not a 1500-character
    /// proximity window around a checkJSON/expectJSON call.
    private static func surrogateReachability(_ audit: Auditor) {
        audit.section("Calibration — surrogate coverage is checkJSON reachability")
        let jsonURL = URL(fileURLWithPath: "/tmp/audit.json")
        for fixture in Calibration.surrogateFixtures {
            let (line, column) = firstBackslash(in: fixture.json)
            audit.equal("planted \(fixture.name) line is the backslash",
                        fixture.line, line)
            audit.equal("planted \(fixture.name) column is the backslash",
                        fixture.column, column)
            let found = DiagnosticsEngine.checkJSON(fixture.json, url: jsonURL)
            let surrogate = found.first {
                $0.severity == .error
                    && ($0.message.lowercased().contains("surrogate")
                        || $0.message.lowercased().contains("unpaired"))
            }
            audit.check("checkJSON executed on \(fixture.name) and did not invent a location",
                        surrogate == nil
                            || (surrogate?.line == fixture.line
                                && surrogate?.column == fixture.column),
                        "line \(surrogate?.line ?? -1) col \(surrogate?.column ?? -1): "
                            + (surrogate?.message ?? "no surrogate error"))
        }

        audit.check("planted fixtures include an unpaired low surrogate",
                    Calibration.surrogateFixtures.contains { $0.json.contains("udc00") })
        audit.check("clean controls include a valid paired surrogate, not only a surrogate-free object",
                    Calibration.validJSONControls.contains { $0 == #"{"ok":true}"# }
                    && Calibration.validJSONControls.contains { $0.contains("ud800")
                        && $0.contains("udc00") })
        for control in Calibration.validJSONControls {
            audit.check("exact checkJSON leaves the \(control) control clean",
                        exactCheckJSON(control, jsonURL)
                            .filter { $0.severity == .error }.isEmpty)
        }
        audit.check("reject-all marks a valid paired surrogate as an error",
                    rejectAllSurrogatesCheckJSON(#"{"ok":"\ud800\udc00"}"#, jsonURL)
                        .contains { $0.severity == .error })
        audit.check("executing checkJSON with exact nested hits satisfies reachability",
                    Calibration.unpairedSurrogateReachability(checkJSON: exactCheckJSON))
        audit.check("executing checkJSON with an off-by-one nested column fails reachability",
                    !Calibration.unpairedSurrogateReachability(checkJSON: offByOneCheckJSON))
        audit.check("executing checkJSON that only rejects the top-level fixture fails reachability",
                    !Calibration.unpairedSurrogateReachability(checkJSON: topLevelOnlyCheckJSON))
        audit.check("executing checkJSON that ignores unpaired low surrogates fails reachability",
                    !Calibration.unpairedSurrogateReachability(checkJSON: highOnlyCheckJSON))
        audit.check("executing checkJSON that rejects a valid paired surrogate fails reachability",
                    !Calibration.unpairedSurrogateReachability(
                        checkJSON: rejectAllSurrogatesCheckJSON))
        audit.check("live DiagnosticsEngine.checkJSON does not yet reject nested unpaired surrogates",
                    !Calibration.unpairedSurrogateReachability(
                        checkJSON: { text, url in DiagnosticsEngine.checkJSON(text, url: url) }))

        let calibrationURL = Calibration.packageRoot
            .appendingPathComponent("Sources/Orrery/Orchestrator/Calibration.swift")
        let source = (try? String(contentsOf: calibrationURL, encoding: .utf8)) ?? ""
        audit.check("surrogate coverage is not decided by a 1500-character text window",
                    !source.contains("offsetBy: 1500") && !source.contains("checkerWindows("),
                    "Calibration.swift still has the proximity heuristic")

        let emptyDiag = writeFakeTree(validator: Calibration.exactSurrogateValidatorSource,
                                      diagnostics: "let nearby = \"ud800 line column checkJSON\"\n")
        defer { try? FileManager.default.removeItem(at: emptyDiag) }
        audit.check("adjacent surrogate needles without a checkJSON/expectJSON call do not satisfy",
                    !Calibration.jsonValidatorWorkPresent(in: emptyDiag)
                    && !Calibration.auditDiagnosticsMatchesSurrogates(in: emptyDiag))
    }

    private static func firstBackslash(in text: String) -> (Int, Int) {
        var line = 1, column = 1
        for character in text {
            if character == "\\" { return (line, column) }
            if character.isNewline { line += 1; column = 1 } else { column += 1 }
        }
        return (0, 0)
    }

    private static func exactCheckJSON(_ text: String, _ url: URL) -> [Diagnostic] {
        scanUnpairedSurrogate(text, url: url, columnOffset: 0, topLevelOnly: false,
                              includeLow: true)
    }

    private static func offByOneCheckJSON(_ text: String, _ url: URL) -> [Diagnostic] {
        scanUnpairedSurrogate(text, url: url, columnOffset: 1, topLevelOnly: false,
                              includeLow: true)
    }

    private static func topLevelOnlyCheckJSON(_ text: String, _ url: URL) -> [Diagnostic] {
        scanUnpairedSurrogate(text, url: url, columnOffset: 0, topLevelOnly: true,
                              includeLow: true)
    }

    private static func highOnlyCheckJSON(_ text: String, _ url: URL) -> [Diagnostic] {
        scanUnpairedSurrogate(text, url: url, columnOffset: 0, topLevelOnly: false,
                              includeLow: false)
    }

    private static func rejectAllSurrogatesCheckJSON(_ text: String, _ url: URL) -> [Diagnostic] {
        var line = 1, column = 1
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" && i + 5 < chars.count && chars[i + 1] == "u" {
                let hex = String(chars[(i + 2)..<(i + 6)])
                if let value = Int(hex, radix: 16), (0xD800...0xDFFF).contains(value) {
                    return [Diagnostic(file: url, line: line, column: column,
                                       severity: .error,
                                       message: "unpaired UTF-16 surrogate",
                                       source: "JSON")]
                }
            }
            if chars[i].isNewline { line += 1; column = 1 } else { column += 1 }
            i += 1
        }
        return []
    }

    /// Rejects every `\u` surrogate escape, including a valid `\ud800\udc00` pair.
    /// Used to prove the paired-surrogate clean control is load-bearing.
    private static let rejectAllSurrogateValidatorSource = #"""
    import Foundation
    enum JSONValidator {
        static func allowsComments(_ url: URL) -> Bool { return false }
        static func validate(_ text: String, url: URL) -> [Diagnostic] {
            var line = 1
            var column = 1
            let chars = Array(text)
            var i = 0
            while i < chars.count {
                if chars[i] == "\\" && i + 5 < chars.count && chars[i + 1] == "u" {
                    let hex = String(chars[(i + 2)..<(i + 6)])
                    if let value = Int(hex, radix: 16), (0xD800...0xDFFF).contains(value) {
                        return [Diagnostic(file: url, line: line, column: column,
                                           severity: .error,
                                           message: "unpaired UTF-16 surrogate",
                                           source: "JSON")]
                    }
                }
                if chars[i].isNewline { line += 1; column = 1 } else { column += 1 }
                i += 1
            }
            return []
        }
    }
    """#

    /// High-only: rejects unpaired `\ud800`…`\udbff` and accepts unpaired `\udc00`.
    /// Used to prove the planted low-surrogate fixtures are load-bearing.
    private static let highOnlySurrogateValidatorSource = #"""
    import Foundation
    enum JSONValidator {
        static func allowsComments(_ url: URL) -> Bool { return false }
        static func validate(_ text: String, url: URL) -> [Diagnostic] {
            var line = 1
            var column = 1
            let chars = Array(text)
            var i = 0
            while i < chars.count {
                if chars[i] == "\\" && i + 5 < chars.count && chars[i + 1] == "u" {
                    let hex = String(chars[(i + 2)..<(i + 6)])
                    if let value = Int(hex, radix: 16), (0xD800...0xDBFF).contains(value) {
                        var paired = false
                        if i + 11 < chars.count, chars[i + 6] == "\\", chars[i + 7] == "u" {
                            let low = String(chars[(i + 8)..<(i + 12)])
                            if let lv = Int(low, radix: 16), (0xDC00...0xDFFF).contains(lv) {
                                paired = true
                            }
                        }
                        if !paired {
                            return [Diagnostic(file: url, line: line, column: column,
                                               severity: .error,
                                               message: "unpaired UTF-16 surrogate",
                                               source: "JSON")]
                        }
                    }
                }
                if chars[i].isNewline { line += 1; column = 1 } else { column += 1 }
                i += 1
            }
            return []
        }
    }
    """#

    private static func scanUnpairedSurrogate(
        _ text: String, url: URL, columnOffset: Int, topLevelOnly: Bool,
        includeLow: Bool
    ) -> [Diagnostic] {
        if text == #"{"ok":true}"# { return [] }
        if topLevelOnly, text != #"{"x":"\ud800"}"# { return [] }
        var line = 1, column = 1
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" && i + 5 < chars.count && chars[i + 1] == "u" {
                let hex = String(chars[(i + 2)..<(i + 6)])
                if let value = Int(hex, radix: 16) {
                    if (0xD800...0xDBFF).contains(value) {
                        var paired = false
                        if i + 11 < chars.count, chars[i + 6] == "\\", chars[i + 7] == "u" {
                            let low = String(chars[(i + 8)..<(i + 12)])
                            if let lv = Int(low, radix: 16), (0xDC00...0xDFFF).contains(lv) {
                                paired = true
                            }
                        }
                        if !paired {
                            return [Diagnostic(file: url, line: line,
                                               column: column + columnOffset,
                                               severity: .error,
                                               message: "unpaired UTF-16 surrogate",
                                               source: "JSON")]
                        }
                        for _ in 0..<12 {
                            if chars[i].isNewline { line += 1; column = 1 } else { column += 1 }
                            i += 1
                        }
                        continue
                    } else if includeLow, (0xDC00...0xDFFF).contains(value) {
                        return [Diagnostic(file: url, line: line,
                                           column: column + columnOffset,
                                           severity: .error,
                                           message: "unpaired UTF-16 surrogate",
                                           source: "JSON")]
                    }
                }
            }
            if chars[i].isNewline { line += 1; column = 1 } else { column += 1 }
            i += 1
        }
        return []
    }

    private static func writeFakeTree(validator: String, diagnostics: String) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orrery-calibrate-fake-" + String(UUID().uuidString.prefix(8)))
        let vdir = dir.appendingPathComponent("Sources/Orrery/Diagnostics")
        let ddir = dir.appendingPathComponent("Sources/Orrery/Audit")
        try? FileManager.default.createDirectory(at: vdir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: ddir, withIntermediateDirectories: true)
        try? validator.write(to: vdir.appendingPathComponent("JSONValidator.swift"),
                             atomically: true, encoding: .utf8)
        try? diagnostics.write(to: ddir.appendingPathComponent("AuditDiagnostics.swift"),
                               atomically: true, encoding: .utf8)
        return dir
    }

    // MARK: - Isolation proven

    /// Hash the real tree, run a scripted calibration whose agent writes a unique
    /// file, hash again. The real tree must be byte-identical, and the write must
    /// have landed in the temp copy — an isolation check that passes because
    /// nothing was written proves nothing.
    private static func isolationProven(_ audit: Auditor) async {
        audit.section("Calibration — isolation proven (scripted, no quota)")
        let source = Calibration.packageRoot
        let token = String(UUID().uuidString.prefix(8))
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orrery-calibrate-audit-" + token)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appendingPathComponent("team-stats.jsonl")
        let previous = TeamStats.storeURL
        TeamStats.storeURL = store
        defer { TeamStats.storeURL = previous }

        let markerName = "calibration-isolation-" + UUID().uuidString + ".txt"
        let markerBody = "isolation-write-" + UUID().uuidString + "\n"
        let realMarker = source.appendingPathComponent(markerName)
        audit.check("the isolation marker does not already exist in the real tree",
                    !FileManager.default.fileExists(atPath: realMarker.path),
                    realMarker.path)

        guard let spec = parseOrFail(audit, "calibration-jsonvalidator author=grok") else { return }

        let authorTurn: [BackendEvent] = [
            .toolStarted(id: "t1", title: "Edit", kind: "edit", input: markerName),
            .toolUpdated(id: "t1", status: "completed", output: nil,
                         diff: FileDiff(path: markerName, oldText: "", newText: markerBody)),
            .assistantDelta("Wrote the isolation marker.\n"),
            .turnFinished(stopReason: "end_turn", costUSD: 0.01),
        ]
        var grokScripts: [[[BackendEvent]]] = [[authorTurn]]
        var claudeScripts: [[[BackendEvent]]] = [[ScriptedBackend.reply("NO FINDINGS", cost: 0.001)]]
        func nextBackend(_ provider: Provider) -> any AgentBackend {
            switch provider {
            case .grok:
                let scripts = grokScripts.isEmpty ? [] : grokScripts.removeFirst()
                return ScriptedBackend(provider: provider, scripts: scripts)
            case .claude:
                let scripts = claudeScripts.isEmpty ? [] : claudeScripts.removeFirst()
                return ScriptedBackend(provider: provider, scripts: scripts)
            case .codex:
                return ScriptedBackend(provider: provider, scripts: [])
            }
        }
        let result = await Calibration.run(
            spec: spec,
            sourceRoot: source,
            storeURL: store,
            makeBackend: nextBackend,
            followGate: false,
            evaluatePassCriteria: false,
            turnTimeout: 5,
            leaveCopy: true,
            installedProviders: [.grok, .claude])
        defer { try? FileManager.default.removeItem(at: result.copyRoot) }

        audit.check("the isolated copy is not the real working tree",
                    result.copyRoot.standardizedFileURL != source.standardizedFileURL,
                    result.copyRoot.path)
        let copyPackage = result.copyRoot.appendingPathComponent("Package.swift")
        let copySources = result.copyRoot.appendingPathComponent("Sources/Orrery")
        audit.check("the isolated copy still has Package.swift and Sources",
                    FileManager.default.fileExists(atPath: copyPackage.path)
                    && FileManager.default.fileExists(atPath: copySources.path))
        audit.check("the isolated copy does not contain .build",
                    !FileManager.default.fileExists(
                        atPath: result.copyRoot.appendingPathComponent(".build").path))
        audit.check("the isolated copy does not contain the app-bundle build/ directory",
                    !FileManager.default.fileExists(
                        atPath: result.copyRoot.appendingPathComponent("build").path))

        let copyMarker = result.copyRoot.appendingPathComponent(markerName)
        let landed = (try? String(contentsOf: copyMarker, encoding: .utf8)) ?? ""
        audit.check("the scripted agent wrote the marker in the temp copy",
                    landed == markerBody,
                    "copy marker='" + landed + "' path=" + copyMarker.path)
        audit.check("the marker is absent from the real working tree",
                    !FileManager.default.fileExists(atPath: realMarker.path),
                    realMarker.path)
        let beforeHex = String(result.sourceDigestBefore.prefix(16))
        let afterHex = String(result.sourceDigestAfter.prefix(16))
        audit.check("the real working tree digest is unchanged after the scripted calibration",
                    !result.sourceDigestBefore.isEmpty
                    && result.sourceDigestBefore == result.sourceDigestAfter,
                    "before=" + beforeHex + " after=" + afterHex)
        audit.check("isolation is not vacuously true — a write landed AND the real tree is identical",
                    landed == markerBody
                    && result.sourceDigestBefore == result.sourceDigestAfter
                    && !FileManager.default.fileExists(atPath: realMarker.path))
        audit.check("the author session started inside the copy",
                    result.authorProjectURL?.standardizedFileURL
                        == result.copyRoot.standardizedFileURL,
                    result.authorProjectURL?.path ?? "nil")
        audit.equal("the isolation run recorded kind=calibration",
                    result.recordedKind, TeamStats.kindCalibration)
        let loaded = TeamStats.load(from: store)
        audit.equal("the isolation run appended exactly one store record",
                    loaded.records.count, 1)
        audit.check("real-world aggregate ignores the isolation calibration record",
                    TeamStats.aggregate(records: loaded.records).isEmpty)
        let calAgg = TeamStats.aggregateCalibration(records: loaded.records)
        let grokAuthor = calAgg.keys.contains { $0.provider == "grok" && $0.role == "author" }
        audit.check("the calibration aggregate sees the isolation author seat", grokAuthor)

        let refuse = Orchestrator()
        refuse.installedProviders = [.grok, .claude]
        refuse.startPreparedItem(title: "x", brief: "y", author: .grok, reviewer: .grok,
                                 roundBudget: 2, project: result.copyRoot)
        if case let .failed(reason) = refuse.phase {
            audit.check("a prepared item whose reviewer is the author is refused in words",
                        reason.contains("never allowed"), reason)
        } else {
            audit.check("a prepared item whose reviewer is the author is refused in words",
                        false, "phase")
        }
    }

    // MARK: - Timeout is honoured; criteria run before the store

    private static func timeoutStopsRun(_ audit: Auditor) async {
        audit.section("Calibration — a still-running run is stopped, not audited")
        let token = String(UUID().uuidString.prefix(8))
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orrery-calibrate-timeout-" + token)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try? "x\n".write(to: dir.appendingPathComponent("README.md"),
                         atomically: true, encoding: .utf8)
        let store = dir.appendingPathComponent("team-stats.jsonl")
        let previous = TeamStats.storeURL
        TeamStats.storeURL = store
        defer { TeamStats.storeURL = previous }
        guard let spec = parseOrFail(audit, "calibration-jsonvalidator author=grok") else { return }
        let result = await Calibration.run(
            spec: spec,
            sourceRoot: dir,
            storeURL: store,
            makeBackend: { ScriptedBackend(provider: $0, scripts: []) },
            followGate: false,
            evaluatePassCriteria: true,
            turnTimeout: 30,
            leaveCopy: true,
            installedProviders: [.grok, .claude],
            runTimeout: 0.4,
            includeCopyAudit: false)
        defer { try? FileManager.default.removeItem(at: result.copyRoot) }
        audit.check("an expired wait prints fail: still running, not a pass",
                    result.line.contains("fail: still running"),
                    result.line)
        audit.check("the copy is not deleted out from under a live agent",
                    !result.copyDeleted)
        let rec = TeamStats.load(from: store).records.last
        audit.equal("a stopped run is stored as cancelled, not accepted",
                    rec?.items.first?.state, "cancelled")
    }

    private static func failedCriteriaNotCleanAccept(_ audit: Auditor) async {
        audit.section("Calibration — failed pass criteria are not stored as a clean accept")
        let token = String(UUID().uuidString.prefix(8))
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orrery-calibrate-criteria-" + token)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try? "x\n".write(to: dir.appendingPathComponent("README.md"),
                         atomically: true, encoding: .utf8)
        let store = dir.appendingPathComponent("team-stats.jsonl")
        let previous = TeamStats.storeURL
        TeamStats.storeURL = store
        defer { TeamStats.storeURL = previous }
        guard let spec = parseOrFail(audit, "calibration-jsonvalidator author=grok") else { return }
        var grokScripts: [[[BackendEvent]]] = [[ScriptedBackend.reply("done", cost: 0.01)]]
        var claudeScripts: [[[BackendEvent]]] = [[ScriptedBackend.reply("NO FINDINGS", cost: 0.001)]]
        func nextBackend(_ provider: Provider) -> any AgentBackend {
            switch provider {
            case .grok:
                let scripts = grokScripts.isEmpty ? [] : grokScripts.removeFirst()
                return ScriptedBackend(provider: provider, scripts: scripts)
            case .claude:
                let scripts = claudeScripts.isEmpty ? [] : claudeScripts.removeFirst()
                return ScriptedBackend(provider: provider, scripts: scripts)
            case .codex:
                return ScriptedBackend(provider: provider, scripts: [])
            }
        }
        let result = await Calibration.run(
            spec: spec,
            sourceRoot: dir,
            storeURL: store,
            makeBackend: nextBackend,
            followGate: false,
            evaluatePassCriteria: true,
            turnTimeout: 5,
            leaveCopy: true,
            installedProviders: [.grok, .claude],
            includeCopyAudit: false)
        defer { try? FileManager.default.removeItem(at: result.copyRoot) }
        audit.check("the printed line is a fail when the copy lacks unpaired-surrogate work",
                    result.line.contains(" fail:"),
                    result.line)
        let loaded = TeamStats.load(from: store)
        audit.equal("the failed calibration still writes one kind=calibration record",
                    loaded.records.count, 1)
        audit.equal("the stored kind is calibration",
                    loaded.records.first?.kind, TeamStats.kindCalibration)
        audit.equal("the stored item is not accepted",
                    loaded.records.first?.items.first?.state, "failed")
        let calAgg = TeamStats.aggregateCalibration(records: loaded.records)
        let clean = calAgg.values.reduce(0) { $0 + $1.cleanAccepts }
        audit.equal("the calibration aggregate does not count a criteria failure as clean",
                    clean, 0)
    }

    // MARK: - Kind separation

    private static func kindSeparation(_ audit: Auditor) {
        audit.section("Calibration — record kind separation")
        let token = String(UUID().uuidString.prefix(8))
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orrery-calibrate-kind-" + token)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appendingPathComponent("team-stats.jsonl")
        let previous = TeamStats.storeURL
        TeamStats.storeURL = store
        defer { TeamStats.storeURL = previous }

        let v1 = """
        {"date":1700000000,"items":[{"authorEffort":"high","authorModel":"a-model","authorProvider":"claude","costUSD":1.5,"failed":false,"findings":[],"findingsLeftStanding":false,"gate":{"hasExecuted":false,"hasFailure":false,"passed":false,"status":"not run","tasks":[]},"reviewerEffort":"unrecorded","reviewerModel":"r-model","reviewerProvider":"grok","roundBudget":"2","rounds":1,"stalled":false,"state":"accepted","title":"Old","turns":2,"unreportedTurns":0}],"orchestratorEffort":"unrecorded","orchestratorModel":"unrecorded","orchestratorProvider":"grok"}
        """
        try? (v1 + "\n").write(to: store, atomically: true, encoding: .utf8)

        let realItems = (0..<3).map { i in
            item(title: "R" + String(i), author: "claude", authorModel: "writer",
                 reviewer: "grok", reviewerModel: "r-model",
                 state: "accepted", rounds: 1, costUSD: 0.10)
        }
        TeamStats.append(TeamStats.RunOutcome(
            date: Date(timeIntervalSince1970: 1_700_000_100),
            orchestratorProvider: "codex",
            orchestratorModel: "sol", orchestratorEffort: "high",
            items: realItems, importFingerprint: nil,
            kind: TeamStats.kindRun), to: store)

        let calItems = (0..<10).map { i in
            item(title: "C" + String(i), author: "grok", authorModel: "hot",
                 reviewer: "claude", reviewerModel: "c-model",
                 state: "accepted", rounds: 1, costUSD: 0.01)
        }
        TeamStats.append(TeamStats.RunOutcome(
            date: Date(timeIntervalSince1970: 1_700_000_200),
            orchestratorProvider: "codex",
            orchestratorModel: "sol", orchestratorEffort: "high",
            items: calItems, importFingerprint: nil,
            kind: TeamStats.kindCalibration), to: store)

        let loaded = TeamStats.load(from: store)
        audit.equal("a mixed v1 + real + calibration store loads three records",
                    loaded.records.count, 3)
        audit.equal("the mixed store has 0 corrupt lines", loaded.corruptLines, 0)
        audit.equal("a v1 line with no kind field decodes as a real run",
                    loaded.records.first?.kind, TeamStats.kindRun)
        audit.check("a v1 line is not classified as calibration",
                    loaded.records.first?.isCalibration == false)
        audit.equal("the explicit real record keeps kind=run",
                    loaded.records.dropFirst().first?.kind, TeamStats.kindRun)
        audit.equal("the calibration record keeps kind=calibration",
                    loaded.records.last?.kind, TeamStats.kindCalibration)

        let realAgg = TeamStats.aggregate(records: loaded.records)
        let claudeWriter = TeamStats.SeatKey(provider: "claude", role: "author",
                                             model: "writer")
        let grokHot = TeamStats.SeatKey(provider: "grok", role: "author", model: "hot")
        let claudeV1 = TeamStats.SeatKey(provider: "claude", role: "author",
                                         model: "a-model")
        audit.equal("real-world aggregate counts the v1 claude/a-model item",
                    realAgg[claudeV1]?.items ?? -1, 1)
        audit.equal("real-world aggregate counts the three claude/writer items",
                    realAgg[claudeWriter]?.items ?? -1, 3)
        let leaked = realAgg[grokHot]?.items ?? -1
        audit.check("real-world aggregate does not see the ten calibration grok/hot items",
                    realAgg[grokHot] == nil,
                    "items=" + String(leaked))

        let calAgg = TeamStats.aggregateCalibration(records: loaded.records)
        audit.equal("calibration aggregate counts the ten grok/hot items",
                    calAgg[grokHot]?.items ?? -1, 10)
        audit.check("calibration aggregate does not see the real claude/writer items",
                    calAgg[claudeWriter] == nil)

        let catalog: Set<TeamStats.CatalogSeat> = [
            .init(provider: "claude", model: "writer"),
            .init(provider: "grok", model: "hot"),
        ]
        let rec = TeamStats.recommendSeats(
            stats: realAgg, installed: catalog,
            enabledWorkers: ["grok", "claude", "codex"],
            orchestratorProvider: "codex")
        if case .recommended(let pick) = rec.author {
            audit.check("seat recommendations pick the real claude/writer seat, not calibration grok/hot",
                        pick.provider == "claude" && pick.model == "writer" && pick.sampleSize == 3,
                        pick.provider + "/" + pick.model + " n=" + String(pick.sampleSize))
        } else {
            audit.check("seat recommendations pick the real claude/writer seat, not calibration grok/hot",
                        false, describe(rec.author))
        }

        let display = TeamStats.loadForDisplay(from: store)
        audit.equal("loadForDisplay real-world recordCount ignores calibration",
                    display.recordCount, 2)
        audit.equal("loadForDisplay calibrationRecordCount is 1",
                    display.calibrationRecordCount, 1)
        audit.check("real-world seats never include the calibration grok/hot author",
                    !display.seats.contains { $0.0 == grokHot })
        audit.check("the calibration section includes only the calibration grok/hot author",
                    display.calibrationSeats.contains { $0.0 == grokHot }
                    && !display.calibrationSeats.contains { $0.0 == claudeWriter })
        audit.equal("the calibration header string is the labelled section title",
                    TeamStats.calibrationHeader,
                    "Calibration — isolated runs, not counted in real-world seats")
        audit.equal("the calibration footer names the exclusion",
                    TeamStats.calibrationFooter(1),
                    "1 calibration run(s) — excluded from seat recommendations and real-world totals")
        let calEntry = display.calibrationSeats.first { $0.0 == grokHot }
        let calText = calEntry.map { TeamStats.rowText(seat: $0.0, stats: $0.1) } ?? ""
        audit.check("calibration rows use rowText, not the real-world trend suffix",
                    calText.contains("Grok") && calText.contains("hot")
                    && !calText.contains("recent"),
                    calText)
    }

    // MARK: - Flag parsing via openLaunchArguments

    private static func flagParsing(_ audit: Auditor) async {
        audit.section("Calibration — --calibrate via openLaunchArguments")
        let token = String(UUID().uuidString.prefix(8))
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orrery-calibrate-flag-" + token)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appendingPathComponent("team-stats.jsonl")
        let previous = TeamStats.storeURL
        TeamStats.storeURL = store
        defer { TeamStats.storeURL = previous }

        let model = AppModel(trust: .forAudit)
        defer { model.shutdown() }

        func dispatch(_ spec: String) async -> String {
            model.openLaunchArguments(["Orrery", "--calibrate", spec])
            return await model.calibrateTask?.value ?? ""
        }

        let full = await dispatch("calibration-jsonvalidator author=grok:grok-4.6:xhigh")
        audit.check("openLaunchArguments dispatches --calibrate",
                    model.calibrateTask != nil)
        audit.equal("valid full spec prints the canonical parsed line",
                    full, "calibrate: calibration-jsonvalidator author=grok:grok-4.6:xhigh")

        let providerOnly = await dispatch("calibration-jsonvalidator author=grok")
        audit.equal("provider-only spec prints the canonical parsed line",
                    providerOnly, "calibrate: calibration-jsonvalidator author=grok")

        let withModel = await dispatch("calibration-jsonvalidator author=grok:grok-4.6")
        audit.equal("provider:model spec prints the canonical parsed line",
                    withModel, "calibrate: calibration-jsonvalidator author=grok:grok-4.6")

        let withEffort = await dispatch("calibration-jsonvalidator author=claude:claude-opus-5:high")
        audit.equal("provider:model:effort spec prints the canonical parsed line",
                    withEffort,
                    "calibrate: calibration-jsonvalidator author=claude:claude-opus-5:high")

        let unknownTask = await dispatch("no-such-task author=grok")
        audit.equal("unknown task id prints its honest line",
                    unknownTask, "calibrate: unknown task id 'no-such-task'")

        let malformed = await dispatch("calibration-jsonvalidator author=")
        audit.equal("malformed author spec prints its honest line",
                    malformed, "calibrate: malformed author spec")

        let unknownProvider = await dispatch("calibration-jsonvalidator author=nope")
        audit.equal("unknown provider prints its honest line",
                    unknownProvider, "calibrate: unknown provider 'nope'")

        let missing = captureStdout {
            model.openLaunchArguments(["Orrery", "--calibrate"])
        }
        audit.equal("missing --calibrate value prints the needs-spec line",
                    missing.trimmingCharacters(in: .whitespacesAndNewlines),
                    Calibration.missingValueLine)

        audit.equal("a parse-only --audit dispatch does not write the store",
                    TeamStats.load(from: store).records.count, 0)
    }

    // MARK: - Real 7-record store

    private static func realStoreCopy(_ audit: Auditor) {
        audit.section("Calibration — real 7-record store still loads (temp copy)")
        let real = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Orrery/team-stats.jsonl")
        guard FileManager.default.fileExists(atPath: real.path) else {
            audit.skip("the real team-stats store exists for the calibration copy", "no Team run on this machine yet"); return
        }

        let token = String(UUID().uuidString.prefix(8))
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orrery-calibrate-real-" + token)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("team-stats.jsonl")
        do {
            AuditTeamStats.writeLegacyOnlyCopy(from: real, to: copy)
            guard FileManager.default.fileExists(atPath: copy.path) else {
                throw NSError(domain: "audit", code: 1)
            }
        } catch {
            audit.check("copied the real store for calibration checks", false, "copy failed")
            return
        }
        let original = (try? Data(contentsOf: real)) ?? Data()
        let loaded = TeamStats.load(from: copy)
        let beforeAgg = TeamStats.aggregate(records: loaded.records)
        let v1Real = TeamStats.legacyV1RealCount(loaded.records)
        let calBefore = loaded.records.filter(\.isCalibration).count
        audit.equal("the calibration copy still loads 7 legacy v1 real records", v1Real, 7)
        audit.equal("the calibration copy has 0 corrupt lines", loaded.corruptLines, 0)
        audit.check("every v1 record is a real run, not calibration",
                    loaded.records.filter { $0.schemaVersion == 1 }
                        .allSatisfy { !$0.isCalibration })
        audit.check("v1 records decode missing kind as run",
                    loaded.records.filter { $0.schemaVersion == 1 }
                        .allSatisfy { $0.kind == TeamStats.kindRun })

        let cal = TeamStats.RunOutcome(
            date: Date(),
            orchestratorProvider: "grok",
            orchestratorModel: "grok-4.6", orchestratorEffort: "xhigh",
            items: [item(title: "cal", author: "claude", authorModel: "invented-hot",
                         reviewer: "grok", reviewerModel: "g",
                         state: "accepted", rounds: 1, costUSD: 9.99)],
            importFingerprint: nil,
            kind: TeamStats.kindCalibration)
        TeamStats.append(cal, to: copy)
        let after = TeamStats.load(from: copy)
        let afterAgg = TeamStats.aggregate(records: after.records)
        let afterBytes = (try? Data(contentsOf: real)) ?? Data()
        audit.check("appending a calibration record to the copy does not mutate the original store",
                    original == afterBytes)
        audit.equal("the copy gained exactly one record",
                    after.records.count, loaded.records.count + 1)
        audit.equal("the seven legacy v1 real records are still on the copy after a calibration append",
                    TeamStats.legacyV1RealCount(after.records), 7)
        audit.check("real-world aggregate is unchanged after the calibration append",
                    afterAgg == beforeAgg)
        let display = TeamStats.loadForDisplay(from: copy)
        audit.equal("loadForDisplay real-world count is the non-calibration records",
                    display.recordCount, after.records.filter { !$0.isCalibration }.count)
        audit.equal("loadForDisplay calibration count includes the appended record",
                    display.calibrationRecordCount, calBefore + 1)
        let invented = TeamStats.SeatKey(provider: "claude", role: "author",
                                         model: "invented-hot")
        audit.check("the invented calibration seat is not in the real-world rows",
                    !display.seats.contains { $0.0 == invented })
        audit.check("the invented calibration seat is in the calibration section",
                    display.calibrationSeats.contains { $0.0 == invented })
        let rec = TeamStats.recommendSeats(
            stats: afterAgg,
            installed: [TeamStats.CatalogSeat(provider: "claude", model: "invented-hot")],
            enabledWorkers: ["claude", "grok"],
            orchestratorProvider: "grok")
        audit.check("recommendations on the copy still do not pick the calibration seat",
                    !rec.hasAnyRecommendation,
                    TeamStats.suggestionLine(rec))
    }

    // MARK: - Helpers

    private static func parseOrFail(_ audit: Auditor, _ raw: String) -> Calibration.Spec? {
        switch Calibration.parse(raw) {
        case .success(let spec): return spec
        case .failure(let error):
            audit.check("parse " + raw, false, error.line)
            return nil
        }
    }

    private static func item(title: String, author: String, authorModel: String,
                             reviewer: String, reviewerModel: String,
                             state: String, rounds: Int, costUSD: Double)
        -> TeamStats.ItemOutcome {
        TeamStats.ItemOutcome(
            title: title,
            authorProvider: author, authorModel: authorModel, authorEffort: "high",
            reviewerProvider: reviewer, reviewerModel: reviewerModel,
            reviewerEffort: "high",
            state: state, rounds: rounds, roundBudget: "2",
            findings: [], findingsLeftStanding: false,
            gate: .notRun, costUSD: costUSD, turns: 2, unreportedTurns: 0,
            stalled: false, failed: false)
    }

    private static func describe(_ advice: TeamStats.RoleAdvice) -> String {
        switch advice {
        case .recommended(let pick):
            return "recommended " + pick.provider + "/" + pick.model
                + " n=" + String(pick.sampleSize)
        case .needsData(let untested):
            let list = untested.map { $0.provider + "/" + $0.model }.joined(separator: ",")
            return "needsData " + list
        }
    }

    /// Redirect fd 1 around `body` so a `print` + `fflush(stdout)` summary can be asserted.
    private static func captureStdout(_ body: () -> Void) -> String {
        fflush(stdout)
        let pipe = Pipe()
        let saved = dup(STDOUT_FILENO)
        guard saved >= 0 else { return "" }
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        body()
        fflush(stdout)
        try? pipe.fileHandleForWriting.close()
        dup2(saved, STDOUT_FILENO)
        close(saved)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
