import SwiftUI

struct FileReviewView: View {
    let model: FileReviewModel
    let workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("File Review").font(.headline)
                    Text(workspace.relativePath(of: model.url))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(model.url.path)
                }
                Spacer(minLength: 0)
                Button { workspace.reviewActiveFile() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh the comparison with the current editor contents")
                .accessibilityLabel("Refresh comparison")
                Button("Open File") { workspace.dismissFileReview() }
            }
            .padding(12)
            Divider()
            HStack {
                Text("Baseline \(model.baseline.capturedAt.formatted(date: .omitted, time: .shortened)) → Editor \(model.comparedAt.formatted(date: .omitted, time: .shortened))")
                Spacer(minLength: 0)
                if case .ready(let difference) = model.state {
                    Text("+\(difference.additions)").foregroundStyle(.green)
                    Text("−\(difference.deletions)").foregroundStyle(.red)
                }
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text("Read-only snapshot · Refresh to include later changes")
                Spacer(minLength: 0)
                Button("Reset Baseline") { workspace.resetFileReviewBaseline() }
                    .buttonStyle(.borderless)
                    .help("Use the current editor version as the new comparison baseline")
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
                Button("Try Again") { workspace.reviewActiveFile() }
            }
        case .ready(let difference) where difference.rows.isEmpty:
            ContentUnavailableView {
                Label("No Changes", systemImage: "checkmark.circle")
            } description: {
                Text("The editor contents match the baseline captured when this file was opened or last reset. Saving does not reset the baseline.")
            }
        case .ready(let difference):
            NativeDiffView(difference: difference,
                           font: EditorSettings.shared.editorFont(ofSize: EditorSettings.shared.fontSize))
        }
    }
}
