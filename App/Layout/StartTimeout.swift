//
//  StartTimeout.swift
//  Greenroom
//
//  Every wait in a Start has a limit. A step that never answers must end as a
//  plain sentence ("what did not happen, and what to do"), not as a spinner
//  the person can only quit out of.
//
//  Foundation only, so the race can be checked on its own.
//
import Foundation

/// What a start step that ran out of time says. The message is the whole
/// text shown to the person, so it names the step, the wait and the way out.
struct StartTimeoutError: LocalizedError, Equatable {
    let step: String
    let seconds: Int
    let advice: String

    var errorDescription: String? {
        "\(step) didn\u{2019}t finish in \(seconds) seconds. \(advice)"
    }
}

/// Runs `operation` and gives up after `seconds`.
///
/// Why not a task group: a group cannot return until EVERY child has
/// finished, and the thing being raced here is usually a callback from the
/// Zoom SDK that ignores cancellation, so a group would wait as long as the
/// hang it was meant to cut short. This returns the moment the first of
/// {result, error, timeout, cancellation of the caller} happens; the
/// operation is cancelled and left to wind down on its own.
///
/// Cancelling the caller (End Session pressed mid-start) resumes at once with
/// `CancellationError`.
@MainActor
func withStartTimeout<T>(_ seconds: TimeInterval, step: String, advice: String,
                         _ operation: @escaping @MainActor () async throws -> T) async throws -> T {
    let race = StartRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            race.arm(continuation)
            let work = Task { @MainActor in
                do { race.finish(.success(try await operation())) }
                catch { race.finish(.failure(error)) }
            }
            let timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                race.finish(.failure(StartTimeoutError(step: step, seconds: Int(seconds.rounded()), advice: advice)))
            }
            race.onFinish = { work.cancel(); timer.cancel() }
        }
    } onCancel: {
        Task { @MainActor in race.finish(.failure(CancellationError())) }
    }
}

/// One-shot resume of the continuation, whoever gets there first. A result
/// that lands before the continuation exists (the caller was already
/// cancelled) is held and delivered on arm, so nothing is ever left waiting.
@MainActor
private final class StartRace<T> {
    private var continuation: CheckedContinuation<T, Error>?
    private var held: Result<T, Error>?
    private var finished = false
    var onFinish: (() -> Void)?

    func arm(_ c: CheckedContinuation<T, Error>) {
        if let held { c.resume(with: held); self.held = nil } else { continuation = c }
    }

    func finish(_ result: Result<T, Error>) {
        guard !finished else { return }
        finished = true
        onFinish?(); onFinish = nil
        if let continuation { continuation.resume(with: result); self.continuation = nil } else { held = result }
    }
}
