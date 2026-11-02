import Foundation

/// Queues whole reports: retries restart their fragment assembler, and cancellation
/// removes every remaining fragment. Only one ATT write may be outstanding.
@MainActor
final class ReportWriteQueue<Destination: Equatable> {
    enum Kind: Equatable {
        case wii(UInt8), management(UInt16), setup
        var slot: UInt8? { if case .wii(let slot) = self { return slot }; return nil }
    }
    struct Frame {
        let destination: Destination
        let value: Data
    }
    private final class Report {
        let id: UUID
        let destination: Destination
        let frames: [Data]
        let kind: Kind
        let submitting: () -> Void
        let completion: (Result<Void, Error>) -> Void
        var index = 0
        var retries = 0
        var cancelled = false
        init(id: UUID, destination: Destination, frames: [Data], kind: Kind,
             submitting: @escaping () -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
            self.id = id; self.destination = destination; self.frames = frames; self.kind = kind
            self.submitting = submitting; self.completion = completion
        }
    }
    private var queued: [Report] = []
    private var active: Report?
    private var inFlight = false
    private var lastSlot: UInt8 = 3
    private(set) var retryAt: TimeInterval = 0
    var count: Int { queued.reduce(0) { $0 + $1.frames.count } + (active?.frames.count ?? 0) }

    func enqueue(id: UUID = UUID(), destination: Destination, frames: [Data], kind: Kind,
                 submitting: @escaping () -> Void = {},
                 completion: @escaping (Result<Void, Error>) -> Void = { _ in }) throws {
        guard !frames.isEmpty else { throw NintendoBLEError.invalidReport }
        guard count + frames.count <= 128 else { throw NintendoBLEError.writeQueueFull }
        queued.append(Report(id: id, destination: destination, frames: frames, kind: kind,
                             submitting: submitting, completion: completion))
    }

    func next(now: TimeInterval, canSend: (Destination) -> Bool) -> Frame? {
        guard !inFlight, now >= retryAt else { return nil }
        if active == nil {
            // Management and setup are short; otherwise rotate slots, preserving
            // command order within each remote and keeping report fragments together.
            var selected = queued.firstIndex { $0.kind.slot == nil }
            if selected == nil {
                for offset: UInt8 in 1...4 {
                    if let index = queued.firstIndex(where: { $0.kind.slot == (lastSlot + offset) % 4 }) {
                        selected = index; break
                    }
                }
            }
            guard let selected else { return nil }
            active = queued.remove(at: selected)
            if let slot = active?.kind.slot { lastSlot = slot }
        }
        guard let report = active, canSend(report.destination) else { return nil }
        inFlight = true
        if report.index == report.frames.count - 1 { report.submitting() }
        return Frame(destination: report.destination, value: report.frames[report.index])
    }

    /// A positive ATT error guarantees rejection, so a resource error can safely
    /// retry the whole report. Ambiguous transport errors must never be replayed.
    func acknowledge(destination: Destination, error: Error?, retryable: Bool, now: TimeInterval) {
        guard inFlight, let report = active, report.destination == destination else { return }
        inFlight = false
        if report.cancelled { active = nil; retryAt = 0; return }
        if let error {
            if retryable, report.retries < 3 {
                report.retries += 1
                report.index = 0
                retryAt = now + 0.025 * Double(1 << (report.retries - 1))
                return
            }
            active = nil; retryAt = 0
            report.completion(.failure(error))
        } else {
            report.index += 1
            if report.index == report.frames.count {
                active = nil; retryAt = 0
                report.completion(.success(()))
            }
        }
    }

    func cancel(_ id: UUID) { remove(where: { $0.id == id }, error: nil) }
    func remove(kind: Kind, error: Error? = nil) { remove(where: { $0.kind == kind }, error: error) }
    func disconnect() { remove(where: { _ in true }, error: NintendoBLEError.notReady) }

    private func remove(where matches: (Report) -> Bool, error: Error?) {
        let removed = queued.filter(matches)
        queued.removeAll(where: matches)
        var current: Report?
        if let report = active, !report.cancelled, matches(report) {
            report.cancelled = true
            current = report
            if !inFlight { active = nil; retryAt = 0 }
        }
        // Mutate first: completions may reenter the queue.
        if let error {
            for report in removed { report.completion(.failure(error)) }
            current?.completion(.failure(error))
        }
    }
}
