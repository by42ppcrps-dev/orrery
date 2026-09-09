import Foundation

/// Imagine: the composed instructions name the tool and every parameter, media paths are found
/// in tool output only when the files exist, copies into the project never overwrite, and the
/// agent may read Grok's bundled skills but nothing else outside the project.
@MainActor
enum AuditImagine {
    static func run(_ audit: Auditor) async {
        audit.section("Imagine — instructions, media previews and the bundled-skills read allowance")
        var request = ImagineRequest(kind: .image, prompt: "a red circle", aspectRatio: "16:9")
        audit.check("an image request names image_gen, the ratio and the prompt", request.instruction.contains("image_gen") && request.instruction.contains("\"16:9\"") && request.instruction.contains("a red circle") && request.instruction.contains("absolute path"))
        audit.check("an image request needs only a prompt", request.isReady)
        request = ImagineRequest(kind: .video, prompt: "slow zoom", duration: 10, resolution: "720p")
        audit.check("a video request without a reference is not ready", !request.isReady)
        request.referencePath = "/tmp/a.jpg"
        audit.check("a video request names image_to_video with image, duration, resolution and the plan caveat",
                    request.instruction.contains("image_to_video") && request.instruction.contains("image=\"/tmp/a.jpg\"") && request.instruction.contains("duration=10") && request.instruction.contains("\"720p\"") && request.instruction.contains("plan"))
        request = ImagineRequest(kind: .edit, prompt: "make it blue", referencePath: "/tmp/a.jpg")
        audit.check("an edit request names image_edit with the reference", request.instruction.contains("image_edit") && request.instruction.contains("/tmp/a.jpg") && request.instruction.contains("make it blue"))
        audit.check("every instruction forbids other file writes", [ImagineRequest.Kind.image, .video, .edit].allSatisfy { ImagineRequest(kind: $0, prompt: "x", referencePath: "/tmp/a.jpg").instruction.contains("Do not write any other files") })

        await Auditor.withTemporaryDirectory { dir in
            let image = dir.appendingPathComponent("sessions/1/images/1.jpg")
            try? FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data([0xFF, 0xD8, 0xFF]).write(to: image)
            let video = dir.appendingPathComponent("videos/1.mp4")
            try? FileManager.default.createDirectory(at: video.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data([0]).write(to: video)
            let output = "{\"path\":\"\(image.path.replacingOccurrences(of: "/", with: "\\/"))\",\"filename\":\"1.jpg\"}\nAlso wrote \(video.path) and \(dir.path)/missing.png and \(dir.path)/notes.txt"
            let found = MediaPaths.paths(in: output)
            audit.equal("paths are found in JSON-escaped and plain form, only for files that exist, only for media", found, [image.path, video.path])
            audit.check("a video is told apart from an image", MediaPaths.isVideo(video.path) && !MediaPaths.isVideo(image.path))
            let percent = "/tmp/%2FUsers%2Fme/1.jpg"
            audit.equal("a percent-encoded folder name is kept as it is on disk", MediaPaths.paths(in: percent, fileExists: { $0 == percent }), [percent])
            audit.equal("…and decoded only when the literal path does not exist", MediaPaths.paths(in: percent, fileExists: { $0 == "/tmp//Users/me/1.jpg" }), ["/tmp//Users/me/1.jpg"])
            audit.check("the list is bounded", MediaPaths.paths(in: (1...20).map { "/tmp/x\($0).png" }.joined(separator: " "), fileExists: { _ in true }).count == MediaPaths.limit)
            var detail = ToolDetail()
            detail.output = "saved: \(image.path)"
            audit.equal("a tool detail exposes its media", detail.mediaPaths, [image.path])

            let project = dir.appendingPathComponent("project")
            try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let first = try? MediaPaths.copyIntoProject(image.path, project: project)
            let second = try? MediaPaths.copyIntoProject(image.path, project: project)
            audit.check("copies land in images/ and never overwrite", first?.lastPathComponent == "1.jpg" && second?.lastPathComponent == "1-2.jpg" && first?.deletingLastPathComponent().lastPathComponent == "images")
            audit.check("videos land in videos/", (try? MediaPaths.copyIntoProject(video.path, project: project))?.deletingLastPathComponent().lastPathComponent == "videos")

            let bundled = dir.appendingPathComponent("bundled")
            try? FileManager.default.createDirectory(at: bundled.appendingPathComponent("skills/imagine"), withIntermediateDirectories: true)
            try? "# Imagine".write(to: bundled.appendingPathComponent("skills/imagine/SKILL.md"), atomically: true, encoding: .utf8)
            try? "secret".write(to: dir.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
            try? "print(1)".write(to: project.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
            let previousRoot = ACPClient.bundledSkillsRoot
            ACPClient.bundledSkillsRoot = bundled
            defer { ACPClient.bundledSkillsRoot = previousRoot }
            let workspace = WorkspaceFileAccess(root: project)
            audit.check("a project file reads as before", (try? ACPClient.readForAgent(project.appendingPathComponent("a.py").path, workspace: workspace)).map { String(decoding: $0, as: UTF8.self) } == "print(1)")
            audit.check("Grok's bundled skills are readable", (try? ACPClient.readForAgent(bundled.appendingPathComponent("skills/imagine/SKILL.md").path, workspace: workspace)).map { String(decoding: $0, as: UTF8.self) } == "# Imagine")
            audit.check("a file beside the bundled folder is still refused", (try? ACPClient.readForAgent(dir.appendingPathComponent("auth.json").path, workspace: workspace)) == nil)
            audit.check("a traversal out of the bundled folder is refused", (try? ACPClient.readForAgent(bundled.appendingPathComponent("../auth.json").path, workspace: workspace)) == nil)
        }
    }
}
