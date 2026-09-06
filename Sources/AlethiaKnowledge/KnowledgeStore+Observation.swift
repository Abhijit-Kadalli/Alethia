import Foundation
import AlethiaCore
import CSQLite

extension KnowledgeStore {
    /// Which area of the store changed. Posted (coalesced) as `KnowledgeStore.didChangeNotification`
    /// on the main queue with the set of changed areas under `changesKey`.
    public enum Change: String, Sendable, Hashable, CaseIterable {
        case meetings
        case utterances
        case speakers
        case dictations
        case dictionary
        case snippets
        case templates

        init?(table: String) {
            switch table {
            case "meetings": self = .meetings
            case "utterances": self = .utterances
            case "speakers": self = .speakers
            case "dictations": self = .dictations
            case "dictionary": self = .dictionary
            case "snippets": self = .snippets
            case "templates": self = .templates
            default: return nil
            }
        }
    }

    public static let didChangeNotification = Notification.Name("KnowledgeStore.didChange")
    public static let changesKey = "changes"

    /// Start posting change notifications. Safe to call once per store.
    public func startObservingChanges() {
        let box = ChangeCoalescer(store: self)
        changeCoalescer = box
        let context = Unmanaged.passUnretained(box).toOpaque()
        sqlite3_update_hook(db.handle, { context, _, _, table, _ in
            guard let context, let table else { return }
            let coalescer = Unmanaged<ChangeCoalescer>.fromOpaque(context).takeUnretainedValue()
            coalescer.record(String(cString: table))
        }, context)
    }

    /// Changes as an async sequence (each element is the coalesced set from one notification).
    public var changes: AsyncStream<Set<Change>> {
        AsyncStream { continuation in
            let observer = ObserverBox()
            observer.token = NotificationCenter.default.addObserver(
                forName: Self.didChangeNotification, object: self, queue: nil
            ) { note in
                let set = note.userInfo?[Self.changesKey] as? Set<Change> ?? []
                continuation.yield(set)
            }
            continuation.onTermination = { _ in
                observer.remove()
            }
        }
    }
}

final class ObserverBox: @unchecked Sendable {
    var token: NSObjectProtocol?

    func remove() {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
        token = nil
    }
}

/// Batches row-level hook callbacks into one notification per run loop turn.
final class ChangeCoalescer: @unchecked Sendable {
    private weak var store: KnowledgeStore?
    private let lock = NSLock()
    private var pending: Set<KnowledgeStore.Change> = []
    private var scheduled = false

    init(store: KnowledgeStore) {
        self.store = store
    }

    func record(_ table: String) {
        guard let change = KnowledgeStore.Change(table: table) else { return }
        lock.lock()
        pending.insert(change)
        let needsFlush = !scheduled
        scheduled = true
        lock.unlock()
        guard needsFlush else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        lock.lock()
        let changes = pending
        pending.removeAll()
        scheduled = false
        lock.unlock()
        guard let store, !changes.isEmpty else { return }
        NotificationCenter.default.post(
            name: KnowledgeStore.didChangeNotification,
            object: store,
            userInfo: [KnowledgeStore.changesKey: changes]
        )
    }
}
