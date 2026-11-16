import SwiftUI

struct FileReviewView: View {
    let model: FileReviewModel
    let workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.title).font(.headline)
                    Text(workspace.relativePath(of: model.url))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(model.url.path)
                }
                Spacer(minLength: 0)
                if !model.isFrozen { Button { workspace.reviewActiveFile() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh the comparison with the current editor contents")
                .accessibilityLabel("Refresh comparison")
                }
                Button("Open File") { workspace.openReviewedFile() }
                    .disabled(!FileManager.default.fileExists(atPath: model.url.path) && workspace.buffers[model.url] == nil)
            }
            .padding(12)
            Divider()
            HStack {
                Text("\(model.isFrozen ? "Start" : "Baseline") \(model.baseline.capturedAt.formatted(date: .omitted, time: .shortened)) → \(model.isFrozen ? "End" : "Editor") \(model.comparedAt.formatted(date: .omitted, time: .shortened))")
                Spacer(minLength: 0)
                if case .ready(let difference) = model.state {
                    Text("+\(difference.additions)").foregroundStyle(.green)
                    Text("−\(difference.deletions)").foregroundStyle(.red)
                }
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary).padding(10) }
            Divider()
            HStack {
                Text(model.isFrozen ? "Frozen turn snapshot · Open File shows the current version" : "Read-only snapshot · Refresh to include later changes")
                Spacer(minLength: 0)
                if !model.isFrozen { Button("Reset Baseline") { workspace.resetFileReviewBaseline() }
                    .buttonStyle(.borderless)
                    .help("Use the current editor version as the new comparison baseline")
                    .disabled(workspace.isAgentEditingLocked)
                }
            }
            .font(.caption).foregroundStyle(.secondary).padding(10)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("Comparing file versions…")
        case .failed(let message):
            ContentUnavailableView {
                Label("Can’t Compare File", systemImage: "exclamationmark.triangle")
            } description: { Text(message) } actions: {
                if !model.isFrozen { Button("Try Again") { workspace.reviewActiveFile() } }
            }
        case .ready(let difference) where difference.rows.isEmpty:
            ContentUnavailableView {
                Label("No Changes", systemImage: "checkmark.circle")
            } description: {
                Text(model.isFrozen ? "The decoded text in these two snapshots is unchanged. Check any encoding or capture notices below."
                     : "The editor contents match the baseline captured when this file was opened or last reset. Saving does not reset the baseline.")
            }
        case .ready(let difference):
            NativeDiffView(difference: difference,
                           font: EditorSettings.shared.editorFont(ofSize: EditorSettings.shared.fontSize))
        }
    }
}
