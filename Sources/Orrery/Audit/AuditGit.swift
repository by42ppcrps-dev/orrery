import Foundation

/// Source control: the porcelain parser as a pure function, then a real repository in a
/// temporary folder — init, untracked, stage, commit, modify, unstage, discard, a bare remote
/// with push, ahead counts and a clone — all through the same commands the pane runs.
@MainActor
enum AuditGit {
    static func run(_ audit: Auditor) async {
        audit.section("Git — the status parser reads porcelain v2")
        let sample = """
        # branch.oid 0123456789abcdef0123456789abcdef01234567
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +2 -1
        1 .M N... 100644 100644 100644 aaaa bbbb src/hello.py
        1 A. N... 000000 100644 100644 0000 cccc new file.txt
        1 MM N... 100644 100644 100644 dddd eeee both.txt
        2 R. N... 100644 100644 100644 ffff ffff R100 renamed.txt\told.txt
        u UU N... 100644 100644 100644 100644 1111 2222 3333 conflict.txt
        ? notes/todo.md
        """
        let status = GitRepository.parseStatus(sample)
        audit.check("branch, upstream, ahead/behind and head are read", status.isRepo && status.branch == "main" && status.upstream == "origin/main" && status.ahead == 2 && status.behind == 1 && status.head == "01234567",
                    "\(status.branch) \(status.upstream) +\(status.ahead) -\(status.behind) \(status.head)")
        audit.equal("six entries, sorted by path", status.entries.map(\.path), ["both.txt", "conflict.txt", "new file.txt", "notes/todo.md", "renamed.txt", "src/hello.py"])
        audit.check("a modified, unstaged file shows M and is not staged", status.entries.first { $0.path == "src/hello.py" }.map { $0.label == "M" && !$0.isStaged && $0.hasUnstaged } == true)
        audit.check("a newly added file is staged with A", status.entries.first { $0.path == "new file.txt" }.map { $0.isStaged && $0.staged == "A" && !$0.hasUnstaged } == true)
        audit.check("a file changed in the index and the tree is in both lists", status.staged.contains { $0.path == "both.txt" } && status.unstaged.contains { $0.path == "both.txt" })
        audit.check("a rename keeps the new path", status.entries.contains { $0.path == "renamed.txt" && $0.staged == "R" })
        audit.check("an untracked file shows ? and counts as a change", status.entries.first { $0.path == "notes/todo.md" }.map { $0.isUntracked && $0.label == "?" } == true && status.unstaged.contains { $0.path == "notes/todo.md" })
        audit.check("a conflict is marked U", status.entries.first { $0.path == "conflict.txt" }?.staged == "U")
        let initial = GitRepository.parseStatus("# branch.oid (initial)\n# branch.head main\n")
        audit.check("a repository with no commits has an empty head and is clean", initial.isRepo && initial.head.isEmpty && initial.isClean)
        audit.check("git never prompts: terminal prompts, askpass and the editor are switched off",
                    GitRepository.environment["GIT_TERMINAL_PROMPT"] == "0" && GitRepository.environment["GIT_SSH_COMMAND"]?.contains("BatchMode=yes") == true && GitRepository.environment["GIT_EDITOR"] == "true")
        audit.equal("clone folder names come from the URL", ["https://github.com/o/repo.git", "git@github.com:o/other.git", "https://x.dev/a/b/c"].map(GitRepository.cloneFolderName), ["repo", "other", "c"])

        guard FileManager.default.isExecutableFile(atPath: GitRepository.executable) else {
            audit.check("git is installed for the live repository checks", false, "no /usr/bin/git")
            return
        }
        audit.section("Git — a real repository: init, stage, commit, discard, remote, push, clone")
        await Auditor.withTemporaryDirectory { base in
            let project = base.appendingPathComponent("project", isDirectory: true)
            try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let git = GitRepository()
            git.attach(project: nil)
            git.attach(project: project)
            await git.refresh()
            audit.check("a plain folder is not a repository", !git.status.isRepo)
            await git.initialize()
            audit.check("Initialize makes a repository on main with no commits", git.status.isRepo && git.status.branch == "main" && git.status.head.isEmpty, "\(git.status.isRepo) \(git.status.branch) \(git.status.head)")
            try? "hello\n".write(to: project.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            await git.refresh()
            audit.check("a new file appears as untracked", git.status.entries.map(\.path) == ["a.txt"] && git.status.entries[0].isUntracked)
            audit.equal("the diff of an untracked file is its content, added", await git.diff("a.txt", staged: false), "+hello\n+")
            await git.stage(["a.txt"])
            audit.check("Stage moves it to the index as A", git.status.staged.map(\.path) == ["a.txt"] && git.status.staged[0].staged == "A")
            await git.unstage(["a.txt"])
            audit.check("Unstage makes it untracked again", git.status.entries[0].isUntracked)
            git.commitMessage = ""
            await git.commit(all: true)
            audit.check("a commit without a message is refused with a reason", git.lastFailed && git.lastMessage.contains("message") && git.status.head.isEmpty)
            _ = await git.runner(["config", "user.email", "audit@orrery.test"], project, 10)
            _ = await git.runner(["config", "user.name", "Orrery Audit"], project, 10)
            git.commitMessage = "first"
            await git.commit(all: true)
            audit.check("Commit All stages and commits; the tree is clean and HEAD exists", git.status.isClean && !git.status.head.isEmpty && git.commitMessage.isEmpty && !git.lastFailed, git.lastMessage)
            audit.check("the commit shows in the recent list", git.recentCommits.first?.hasSuffix(" first") == true, git.recentCommits.joined(separator: " | "))
            try? "hello\nworld\n".write(to: project.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            await git.refresh()
            audit.check("a modified file shows M, unstaged", git.status.unstaged.map(\.path) == ["a.txt"] && git.status.unstaged[0].label == "M")
            let diff = await git.diff("a.txt", staged: false)
            audit.check("its diff shows the added line", diff.contains("+world") && diff.contains("@@"))
            audit.equal("the file badge reads M", git.badge(for: project.appendingPathComponent("a.txt")), "M")
            audit.check("an unchanged path has no badge", git.badge(for: project.appendingPathComponent("missing.txt")) == nil)
            await git.discard("a.txt")
            audit.check("Discard restores the committed content", (try? String(contentsOf: project.appendingPathComponent("a.txt"))) == "hello\n" && git.status.isClean)
            try? "scratch".write(to: project.appendingPathComponent("junk.txt"), atomically: true, encoding: .utf8)
            await git.refresh()
            await git.discard("junk.txt")
            audit.check("Discard deletes an untracked file", !FileManager.default.fileExists(atPath: project.appendingPathComponent("junk.txt").path) && git.status.isClean)

            let bare = base.appendingPathComponent("remote.git", isDirectory: true)
            _ = await git.runner(["init", "--bare", "-b", "main", bare.path], base, 20)
            _ = await git.runner(["remote", "add", "origin", bare.path], project, 10)
            await git.refresh()
            audit.equal("the remote is shown", git.remote, bare.path)
            audit.check("before the first push there is no upstream", git.status.upstream.isEmpty)
            await git.push()
            audit.check("Push sets the upstream on the first push", !git.lastFailed && git.status.upstream == "origin/main" && git.status.ahead == 0, git.lastMessage)
            try? "two\n".write(to: project.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
            await git.refresh()
            git.commitMessage = "second"
            await git.commit(all: true)
            audit.equal("a new commit puts the branch one ahead", git.status.ahead, 1)
            await git.push()
            audit.check("Push clears the ahead count", !git.lastFailed && git.status.ahead == 0, git.lastMessage)
            await git.fetch()
            audit.check("Fetch runs without a prompt", !git.lastFailed, git.lastMessage)
            await git.pull()
            audit.check("Pull (fast-forward only) is a no-op on an up-to-date branch", !git.lastFailed, git.lastMessage)

            let cloneParent = base.appendingPathComponent("clones", isDirectory: true)
            try? FileManager.default.createDirectory(at: cloneParent, withIntermediateDirectories: true)
            let cloneTool = GitRepository()
            cloneTool.attach(project: cloneParent)
            let folder = await cloneTool.clone(bare.path, into: cloneParent)
            audit.check("Clone lands in a folder named after the repository", folder?.lastPathComponent == "remote", cloneTool.lastMessage)
            audit.check("…with the pushed files", folder.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("b.txt").path) } == true)
            audit.check("a second clone into the same folder is refused", await cloneTool.clone(bare.path, into: cloneParent) == nil && cloneTool.lastMessage.contains("already exists"))
            audit.check("a clone of an option-looking URL is refused", await cloneTool.clone("--upload-pack=evil", into: cloneParent) == nil)
            let timed = GitRepository()
            timed.attach(project: project)
            timed.runner = { _, _, _ in GitRepository.Outcome(status: 124, output: "", error: "git did not finish within 1 seconds.") }
            await timed.push()
            audit.check("a command that times out is reported as a failure, not a hang", timed.lastFailed && timed.lastMessage.contains("did not finish"))
        }
    }
}
