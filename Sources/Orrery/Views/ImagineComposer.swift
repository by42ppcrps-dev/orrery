import SwiftUI

struct ImagineComposer: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    @State private var request = ImagineRequest()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Imagine with Grok").font(.headline)
            Picker("Kind", selection: $request.kind) {
                ForEach(ImagineRequest.Kind.allCases) { kind in Text(kind.title).tag(kind) }
            }.pickerStyle(.segmented).labelsHidden()
            TextField(request.kind == .edit ? "What should change in the image?" : "Describe what you want", text: $request.prompt, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder).accessibilityLabel("Imagine prompt")
            if request.kind == .image {
                Picker("Aspect ratio", selection: $request.aspectRatio) {
                    ForEach(ImagineRequest.aspectRatios, id: \.self) { Text($0).tag($0) }
                }
            }
            if request.kind == .video {
                HStack {
                    Picker("Length", selection: $request.duration) { ForEach(ImagineRequest.durations, id: \.self) { Text("\($0) s").tag($0) } }
                    Picker("Resolution", selection: $request.resolution) { ForEach(ImagineRequest.resolutions, id: \.self) { Text($0).tag($0) } }
                }
            }
            if request.kind != .image {
                HStack {
                    Button(request.referencePath == nil ? "Choose Image…" : "Change Image…") { chooseReference() }
                    Text(request.referencePath.map { ($0 as NSString).lastPathComponent } ?? "No image chosen").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Text(request.kind == .video
                 ? "Video uses Grok's image_to_video tool (grok-imagine-video-1.5) and needs a SuperGrok plan; the agent says so if it is not available."
                 : "Runs in your Grok session with its image tools; the result shows in the chat with Open, Reveal and Copy to Project.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Generate") {
                    let instruction = request.instruction
                    isPresented = false
                    Task { await model.send(instruction) }
                }.buttonStyle(.borderedProminent).disabled(!request.isReady || model.state.isBusy)
            }
        }
        .padding(16).frame(width: 420)
    }

    private func chooseReference() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose the image Grok should start from."
        if panel.runModal() == .OK, let url = panel.url { request.referencePath = url.path }
    }
}

/// Inline preview for files a tool produced or used: images as thumbnails, videos in a player.
struct MediaPreview: View {
    let path: String
    let project: URL?
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if MediaPaths.isVideo(path) {
                Label((path as NSString).lastPathComponent, systemImage: "film").font(.caption)
            } else if let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityLabel("Generated image \((path as NSString).lastPathComponent)")
            } else {
                Label((path as NSString).lastPathComponent, systemImage: "photo").font(.caption)
            }
            HStack(spacing: 8) {
                Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                if let project {
                    Button("Copy to Project") {
                        do { let copied = try MediaPaths.copyIntoProject(path, project: project); note = "Copied to \(copied.path.replacingOccurrences(of: project.path + "/", with: ""))" }
                        catch { note = error.localizedDescription }
                    }
                }
                if let note { Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }.controlSize(.small)
        }
    }
}
