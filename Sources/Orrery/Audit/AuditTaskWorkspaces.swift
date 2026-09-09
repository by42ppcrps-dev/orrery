import Foundation
import Darwin

@MainActor
enum AuditTaskWorkspaces {
    static func run(_ audit: Auditor) async {
        audit.section("Task workspaces — isolated review, recovery and guarded restore")
        await Auditor.withTemporaryDirectory { base in
            do {
                let project = base.appendingPathComponent("project"), storage = base.appendingPathComponent("storage")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
                let store = TaskWorkspaceStore(directory: storage)
                func write(_ path: String, _ text: String, root: URL? = nil) throws {
                    let file = (root ?? project).appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(text.utf8).write(to: file)
                }
                func read(_ path: String, root: URL? = nil) throws -> String { try String(contentsOf: (root ?? project).appendingPathComponent(path), encoding: .utf8) }
                try write("main.swift", "preexisting unsaved-to-git work\n")
                try write("deleted.txt", "keep until task deletes\n")
                try write("script.sh", "#!/bin/sh\nexit 0\n")
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.appendingPathComponent("script.sh").path)
                try write("node_modules/pkg/cache.js", "generated\n")
                let pythonCaches = ["__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache"]
                for cache in pythonCaches { try write("package/\(cache)/old.cache", "generated\n") }
                try Data([0, 1, 2, 0xff]).write(to: project.appendingPathComponent("binary.bin"))
                let id = UUID()
                let workspace = try await store.create(taskID: id, project: project)
                audit.check("creates a separate working root", workspace.executionRoot != project && workspace.isolated)
                audit.equal("task starts with actual preexisting edits", try read("main.swift", root: workspace.executionRoot), "preexisting unsaved-to-git work\n")
                audit.check("untracked dependencies are excluded", !FileManager.default.fileExists(atPath: workspace.executionRoot.appendingPathComponent("node_modules").path))
                audit.check("copy exclusions are visible", workspace.notices.contains { $0.contains("node_modules") })
                audit.check("Python caches are excluded from new working copies", pythonCaches.allSatisfy {
                    !FileManager.default.fileExists(atPath: workspace.executionRoot.appendingPathComponent("package/\($0)").path)
                })
                let privateMode = try FileManager.default.attributesOfItem(atPath: storage.path)[.posixPermissions] as? NSNumber
                audit.equal("task storage is private", privateMode?.intValue, 0o700)
                let manifestMode = try FileManager.default.attributesOfItem(atPath: storage.appendingPathComponent(id.uuidString + "/manifest.json").path)[.posixPermissions] as? NSNumber
                audit.equal("task metadata is private", manifestMode?.intValue, 0o600)
                let executableMode = try FileManager.default.attributesOfItem(atPath: workspace.executionRoot.appendingPathComponent("script.sh").path)[.posixPermissions] as? NSNumber
                audit.equal("executable permission survives isolation", executableMode?.intValue, 0o755)
                try write("main.swift", "agent change\n", root: workspace.executionRoot)
                try write("new/deep.txt", "new from task\n", root: workspace.executionRoot)
                try FileManager.default.removeItem(at: workspace.executionRoot.appendingPathComponent("deleted.txt"))
                try Data([0, 9, 8, 0xff]).write(to: workspace.executionRoot.appendingPathComponent("binary.bin"))
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: workspace.executionRoot.appendingPathComponent("script.sh").path)
                var changes = try await store.capture(taskID: id)
                for cache in pythonCaches { try write("package/\(cache)/new.cache", "generated during tests\n", root: workspace.executionRoot) }
                changes = try await store.capture(taskID: id)
                audit.check("running Python tools does not add generated cache files to task Changes", !changes.contains { $0.path.contains(".cache") || $0.path.contains("__pycache__") })
                audit.equal("captures added, modified, removed, binary and mode edits", changes.count, 5)
                audit.equal("new file has added status", changes.first { $0.path == "new/deep.txt" }?.kind, .added)
                audit.equal("removed file has deleted status", changes.first { $0.path == "deleted.txt" }?.kind, .deleted)
                audit.check("binary change is identified", changes.first { $0.path == "binary.bin" }?.isBinary == true)
                audit.check("permission-only edit is captured", changes.first { $0.path == "script.sh" }?.beforeMode != changes.first { $0.path == "script.sh" }?.afterMode)
                audit.equal("agent edits cannot mutate source through shared hard links", try read("main.swift"), "preexisting unsaved-to-git work\n")
                let preview = try await store.diff(taskID: id, path: "main.swift")
                audit.equal("review shows original dirty starting contents", preview.before, "preexisting unsaved-to-git work\n")
                audit.equal("review shows captured task contents", preview.after, "agent change\n")
                let binaryPreview = try await store.diff(taskID: id, path: "binary.bin")
                audit.check("binary preview does not decode bytes as text", binaryPreview.isBinary && binaryPreview.before == nil && binaryPreview.after == nil)

                // Every path is checked before any write, including nested newly added files.
                try write("main.swift", "newer human edit\n")
                do { try await store.integrate(taskID: id); audit.check("source conflict refuses entire apply", false) }
                catch { audit.check("source conflict refuses entire apply", true) }
                audit.equal("conflict preserves newer human edits", try read("main.swift"), "newer human edit\n")
                audit.check("all-path preflight prevents partial additions", !FileManager.default.fileExists(atPath: project.appendingPathComponent("new/deep.txt").path))
                audit.check("all-path preflight prevents partial deletion", FileManager.default.fileExists(atPath: project.appendingPathComponent("deleted.txt").path))
                try write("main.swift", "preexisting unsaved-to-git work\n")
                try await store.integrate(taskID: id, paths: ["main.swift"])
                audit.equal("selective apply updates only requested file", try read("main.swift"), "agent change\n")
                audit.check("selective apply leaves additions pending", !FileManager.default.fileExists(atPath: project.appendingPathComponent("new/deep.txt").path))
                // Review/application use exactly captured bytes, not subsequent unreviewed agent edits.
                try write("main.swift", "unreviewed later agent edit\n", root: workspace.executionRoot)
                try await store.integrate(taskID: id, paths: ["main.swift"])
                audit.equal("apply uses captured version", try read("main.swift"), "agent change\n")
                try write("main.swift", "human after apply\n")
                do { try await store.restore(taskID: id, paths: ["main.swift"]); audit.check("undo refuses a newer user edit", false) }
                catch { audit.check("undo refuses a newer user edit", true) }
                audit.equal("refused undo preserves human edits", try read("main.swift"), "human after apply\n")
                try write("main.swift", "agent change\n")
                let reopened = TaskWorkspaceStore(directory: storage)
                audit.equal("checkpoint identity survives store recreation", try await reopened.workspace(taskID: id), workspace)
                try await reopened.restore(taskID: id, paths: ["main.swift"])
                audit.equal("undo restores preexisting dirty text after restart", try read("main.swift"), "preexisting unsaved-to-git work\n")
                try await reopened.integrate(taskID: id)
                audit.equal("apply adds nested file", try read("new/deep.txt"), "new from task\n")
                audit.check("apply removes deleted file", !FileManager.default.fileExists(atPath: project.appendingPathComponent("deleted.txt").path))
                audit.equal("apply preserves exact binary bytes", try Data(contentsOf: project.appendingPathComponent("binary.bin")), Data([0, 9, 8, 0xff]))
                try await reopened.restore(taskID: id)
                audit.check("undo removes task additions", !FileManager.default.fileExists(atPath: project.appendingPathComponent("new/deep.txt").path))
                audit.equal("undo recreates task deletions", try read("deleted.txt"), "keep until task deletes\n")
                audit.equal("undo restores binary bytes", try Data(contentsOf: project.appendingPathComponent("binary.bin")), Data([0, 1, 2, 0xff]))
                let restoredMode = try FileManager.default.attributesOfItem(atPath: project.appendingPathComponent("script.sh").path)[.posixPermissions] as? NSNumber
                audit.equal("undo restores executable permission", restoredMode?.intValue, 0o755)
                changes = try await reopened.changes(taskID: id)
                audit.check("review tracks that changes were unapplied", changes.allSatisfy { !$0.applied })
                do { _ = try await reopened.diff(taskID: id, path: "../outside"); audit.check("review rejects traversal", false) }
                catch { audit.check("review rejects traversal", true) }
                do { try await reopened.integrate(taskID: id, paths: ["main.swift", "main.swift"]); audit.check("apply rejects duplicate paths", false) }
                catch { audit.check("apply rejects duplicate paths", true) }
                try await reopened.remove(taskID: id)
                audit.check("discard removes private working copy", !FileManager.default.fileExists(atPath: workspace.executionRoot.path))
                audit.equal("discard leaves original project intact", try read("main.swift"), "preexisting unsaved-to-git work\n")

                audit.section("Task workspaces — direct checkpoint, symlinks and capacity")
                let directID = UUID()
                _ = try await store.create(taskID: directID, project: project, isolated: false)
                try write("main.swift", "direct task output\n")
                _ = try await store.capture(taskID: directID)
                try write("main.swift", "human after capture\n")
                do { try await store.restore(taskID: directID); audit.check("direct restore refuses changes after capture", false) }
                catch { audit.check("direct restore refuses changes after capture", true) }
                try write("main.swift", "direct task output\n")
                try await store.restore(taskID: directID)
                audit.equal("direct restore returns to original dirty contents", try read("main.swift"), "preexisting unsaved-to-git work\n")
                let directChanges = try await store.changes(taskID: directID)
                audit.equal("restored direct task has no remaining changes", directChanges.count, 0)
                let linkID = UUID()
                try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("escape"), withDestinationURL: base)
                do { _ = try await store.create(taskID: linkID, project: project); audit.check("copy refuses source symlinks", false) }
                catch { audit.check("copy refuses source symlinks", true) }
                audit.check("failed creation removes partial storage", !FileManager.default.fileExists(atPath: storage.appendingPathComponent(linkID.uuidString).path))
                try FileManager.default.removeItem(at: project.appendingPathComponent("escape"))
                let attackID = UUID()
                let attack = try await store.create(taskID: attackID, project: project)
                try write("folder/new.txt", "task", root: attack.executionRoot)
                _ = try await store.capture(taskID: attackID)
                let outside = base.appendingPathComponent("outside")
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("folder"), withDestinationURL: outside)
                do { try await store.integrate(taskID: attackID); audit.check("apply refuses symlinked destination parent", false) }
                catch { audit.check("apply refuses symlinked destination parent", true) }
                audit.check("symlink refusal prevents outside write", !FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.txt").path))
                try FileManager.default.removeItem(at: project.appendingPathComponent("folder"))
                let large = project.appendingPathComponent("oversized.bin")
                FileManager.default.createFile(atPath: large.path, contents: nil)
                let handle = try FileHandle(forWritingTo: large)
                try handle.truncate(atOffset: UInt64(TaskWorkspaceStore.maximumFileBytes + 1)); try handle.close()
                let largeID = UUID()
                do { _ = try await store.create(taskID: largeID, project: project); audit.check("oversize file blocks partial checkpoint", false) }
                catch { audit.check("oversize file blocks partial checkpoint", true) }
                audit.check("oversize failure cleans partial working copy", !FileManager.default.fileExists(atPath: storage.appendingPathComponent(largeID.uuidString).path))
            } catch { audit.check("task workspace workflow completes", false, error.localizedDescription) }
        }
        await gitWorkflow(audit)
        await interruptedJournal(audit)
        await quotaWorkflow(audit)
    }

    private static func interruptedJournal(_ audit: Auditor) async {
        audit.section("Task workspaces — interrupted operation recovery and bounded storage")
        await Auditor.withTemporaryDirectory { base in
            do {
                let project = base.appendingPathComponent("project"), storage = base.appendingPathComponent("storage")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
                let source = project.appendingPathComponent("file.txt")
                try "starting user edit".write(to: source, atomically: true, encoding: .utf8)
                let id = UUID(), store = TaskWorkspaceStore(directory: storage)
                let workspace = try await store.create(taskID: id, project: project)
                let workingFile = workspace.executionRoot.appendingPathComponent("file.txt")
                try "agent edit".write(to: workingFile, atomically: true, encoding: .utf8)
                _ = try await store.capture(taskID: id)
                let manifestURL = storage.appendingPathComponent(id.uuidString + "/manifest.json")
                func journal(apply: Bool) throws {
                    var json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
                    let baseline = (json["baseline"] as! [String: Any])["file.txt"]!
                    let captured = (json["captured"] as! [String: Any])["file.txt"]!
                    var pending: [String: Any] = ["path": "file.txt", "expected": apply ? baseline : captured,
                                                  "desired": apply ? captured : baseline, "restoringDirect": false]
                    if apply { pending["appliedAfter"] = ["before": baseline, "after": captured] }
                    json["pending"] = pending
                    try JSONSerialization.data(withJSONObject: json).write(to: manifestURL, options: .atomic)
                }
                try journal(apply: true)
                let recovered = TaskWorkspaceStore(directory: storage)
                _ = try await recovered.workspace(taskID: id)
                audit.check("interrupted apply before writing does not claim success", try await recovered.changes(taskID: id).first?.applied == false)
                audit.equal("interrupted pre-write recovery leaves source untouched", try String(contentsOf: source, encoding: .utf8), "starting user edit")
                try journal(apply: true)
                try "agent edit".write(to: source, atomically: true, encoding: .utf8)
                // Preserve copied source mode for the byte-and-mode journal comparison.
                let mode = try FileManager.default.attributesOfItem(atPath: workingFile.path)[.posixPermissions]!
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: source.path)
                _ = try await recovered.workspace(taskID: id)
                audit.check("interrupted apply after writing recovers applied state", try await recovered.changes(taskID: id).first?.applied == true)
                try journal(apply: false)
                try "starting user edit".write(to: source, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: source.path)
                _ = try await recovered.workspace(taskID: id)
                audit.check("interrupted restore recovers unapplied state", try await recovered.changes(taskID: id).first?.applied == false)
                try journal(apply: true)
                try "new user edit after interruption".write(to: source, atomically: true, encoding: .utf8)
                do { _ = try await recovered.workspace(taskID: id); audit.check("interrupted journal refuses newer user conflict", false) }
                catch { audit.check("interrupted journal refuses newer user conflict", true) }
                audit.equal("journal conflict preserves newer user bytes", try String(contentsOf: source, encoding: .utf8), "new user edit after interruption")
                try "starting user edit".write(to: source, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: source.path)
                _ = try await recovered.workspace(taskID: id)
                for number in 0..<10 {
                    try "agent revision \(number)".write(to: workingFile, atomically: true, encoding: .utf8)
                    _ = try await recovered.capture(taskID: id)
                }
                let objects = try FileManager.default.contentsOfDirectory(atPath: storage.appendingPathComponent(id.uuidString + "/objects").path)
                audit.equal("repeated captures prune obsolete object versions", objects.count, 2)
                try await recovered.integrate(taskID: id)
                try "starting user edit".write(to: workingFile, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: workingFile.path)
                let reverted = try await recovered.capture(taskID: id)
                audit.check("reverted task still exposes an earlier applied version for undo", reverted.first?.applied == true && reverted.first?.matchesAppliedVersion == false)
                try await recovered.restore(taskID: id)
                audit.equal("undo remains available after agent reverts its own edit", try String(contentsOf: source, encoding: .utf8), "starting user edit")
            } catch { audit.check("interrupted task journal workflow completes", false, error.localizedDescription) }
        }
    }

    private static func quotaWorkflow(_ audit: Auditor) async {
        audit.section("Task workspaces — global snapshot quota")
        await Auditor.withTemporaryDirectory { base in
            do {
                let project = base.appendingPathComponent("project"), storage = base.appendingPathComponent("storage")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
                let file = project.appendingPathComponent("file.txt")
                try "1234567890".write(to: file, atomically: true, encoding: .utf8)
                let store = TaskWorkspaceStore(directory: storage, snapshotQuota: 25)
                let first = try await store.create(taskID: UUID(), project: project)
                let secondID = UUID()
                _ = try await store.create(taskID: secondID, project: project)
                audit.equal("quota counts separate retained snapshots", try await store.usage(taskID: first.id).totalSnapshotBytes, 20)
                let refusedID = UUID()
                do { _ = try await store.create(taskID: refusedID, project: project); audit.check("shared quota refuses excess task without deleting old work", false) }
                catch { audit.check("shared quota refuses excess task without deleting old work", true) }
                audit.check("quota failure cleans partial task directory", !FileManager.default.fileExists(atPath: storage.appendingPathComponent(refusedID.uuidString).path))
                audit.equal("quota refusal preserves earlier checkpoint", try await store.workspace(taskID: first.id), first)
                try "new agent output beyond remaining quota".write(to: first.executionRoot.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
                do { _ = try await store.capture(taskID: first.id); audit.check("capture quota failure preserves prior snapshot", false) }
                catch { audit.check("capture quota failure preserves prior snapshot", true) }
                audit.equal("failed capture leaves baseline review valid", try await store.changes(taskID: first.id).count, 0)
                audit.equal("quota never deletes the agent working files", try String(contentsOf: first.executionRoot.appendingPathComponent("file.txt"), encoding: .utf8), "new agent output beyond remaining quota")
                try await store.remove(taskID: secondID)
                audit.equal("discard releases counted snapshot space", try await store.usage(taskID: first.id).totalSnapshotBytes, 10)
                _ = try await store.create(taskID: refusedID, project: project)
                audit.equal("new checkpoint can use explicitly freed space", try await store.usage(taskID: refusedID).totalSnapshotBytes, 20)
                let savedWork = first.executionRoot.deletingLastPathComponent().appendingPathComponent("saved-work")
                try FileManager.default.moveItem(at: first.executionRoot, to: savedWork)
                try FileManager.default.createSymbolicLink(at: first.executionRoot, withDestinationURL: project)
                do { _ = try await store.capture(taskID: first.id); audit.check("capture rejects swapped working-root symlink", false) }
                catch { audit.check("capture rejects swapped working-root symlink", true) }
                audit.equal("working-root symlink refusal preserves source", try String(contentsOf: file, encoding: .utf8), "1234567890")
            } catch { audit.check("snapshot quota workflow completes", false, error.localizedDescription) }
        }
    }

    private static func gitWorkflow(_ audit: Auditor) async {
        audit.section("Task workspaces — independent Git baseline")
        await Auditor.withTemporaryDirectory { base in
            do {
                let project = base.appendingPathComponent("git-project")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
                func git(_ arguments: [String], cwd: URL? = nil) async throws -> String {
                    let result = try await ProcessRunner.run("/usr/bin/env", ["-i", "PATH=/usr/bin:/bin", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1", "/usr/bin/git", "-c", "core.hooksPath=/dev/null"] + arguments, cwd: cwd ?? project)
                    guard result.status == 0 else { throw TaskWorkspaceStore.Failure(message: result.standardError) }
                    return result.standardOutput
                }
                _ = try await git(["init", "--quiet"])
                let file = project.appendingPathComponent("source.txt")
                try "committed\n".write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.createDirectory(at: project.appendingPathComponent("build"), withIntermediateDirectories: true)
                try "tracked generated source\n".write(to: project.appendingPathComponent("build/tracked.txt"), atomically: true, encoding: .utf8)
                _ = try await git(["add", "--all"])
                _ = try await git(["-c", "user.name=Audit", "-c", "user.email=audit@local.invalid", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture"])
                let head = try await git(["rev-parse", "HEAD"]), branch = try await git(["symbolic-ref", "HEAD"])
                try "staged user edit\n".write(to: file, atomically: true, encoding: .utf8)
                _ = try await git(["add", "source.txt"])
                try "unstaged user edit\n".write(to: file, atomically: true, encoding: .utf8)
                try "new untracked\n".write(to: project.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
                try "ignored cache\n".write(to: project.appendingPathComponent("build/cache.txt"), atomically: true, encoding: .utf8)
                let indexBefore = try Data(contentsOf: project.appendingPathComponent(".git/index"))
                let store = TaskWorkspaceStore(directory: base.appendingPathComponent("storage"))
                let workspace = try await store.create(taskID: UUID(), project: project)
                audit.equal("Git task copies unstaged starting edits", try String(contentsOf: workspace.executionRoot.appendingPathComponent("source.txt"), encoding: .utf8), "unstaged user edit\n")
                audit.equal("tracked files inside excluded folders are retained", try String(contentsOf: workspace.executionRoot.appendingPathComponent("build/tracked.txt"), encoding: .utf8), "tracked generated source\n")
                audit.check("untracked generated sibling stays excluded", !FileManager.default.fileExists(atPath: workspace.executionRoot.appendingPathComponent("build/cache.txt").path))
                audit.check("untracked user files are included", FileManager.default.fileExists(atPath: workspace.executionRoot.appendingPathComponent("untracked.txt").path))
                audit.equal("original Git head is unchanged", try await git(["rev-parse", "HEAD"]), head)
                audit.equal("original checked-out branch is unchanged", try await git(["symbolic-ref", "HEAD"]), branch)
                audit.equal("original Git index bytes are unchanged", try Data(contentsOf: project.appendingPathComponent(".git/index")), indexBefore)
                audit.equal("isolated Git starts clean at actual user files", try await git(["status", "--porcelain"], cwd: workspace.executionRoot), "")
                audit.check("isolated Git metadata is a private directory", (try workspace.executionRoot.appendingPathComponent(".git").resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true)
                audit.check("history limitation is visible", workspace.notices.contains { $0.contains("history starts") })
                try "agent version\n".write(to: workspace.executionRoot.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
                _ = try await store.capture(taskID: workspace.id)
                try await store.integrate(taskID: workspace.id)
                try await store.restore(taskID: workspace.id)
                audit.equal("Git undo preserves pre-task uncommitted edits", try String(contentsOf: file, encoding: .utf8), "unstaged user edit\n")
                audit.equal("Git apply and undo preserve original staging", try Data(contentsOf: project.appendingPathComponent(".git/index")), indexBefore)
            } catch { audit.check("Git task workspace workflow completes", false, error.localizedDescription) }
        }
    }
}
