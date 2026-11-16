import Foundation
import Observation

nonisolated struct FileReviewBaseline: Sendable {
    let text: String
    let capturedAt: Date
}

/// A frozen comparison, so disk refreshes or subsequent edits cannot rewrite history.
@Observable
final class FileReviewModel {
    enum State {
        case loading, ready(UnifiedDiff), failed(String)
    }

    let url: URL
    let baseline: FileReviewBaseline
    let updated: String
    let comparedAt = Date()
    private(set) var state: State = .loading
    @ObservationIgnored private var task: Task<Void, Never>?

    init(url: URL, baseline: FileReviewBaseline, updated: String) {
        self.url = url
        self.baseline = baseline
        self.updated = updated
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try GitDiffEngine.compare(original: baseline.text, updated: updated)
            }
            do {
                let difference = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { return }
                self?.state = .ready(difference)
            } catch is CancellationError {
                // The comparison was closed or replaced; keep the newer view intact.
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() { task?.cancel() }
}
