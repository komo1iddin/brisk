import Foundation
import Synchronization

/// Only derived source/content folders are removed. A view retains its
/// unpacked value while Lottie may still read pictures from the folder.
nonisolated enum WasCache {
    private static let pinned = Mutex<[String: Int]>([:])

    final class Lease: Sendable {
        private let folder: String
        init(_ folder: URL) {
            self.folder = folder.standardizedFileURL.path(percentEncoded: false)
            pinned.withLock { $0[self.folder, default: 0] += 1 }
        }
        deinit {
            pinned.withLock { counts in
                let count = counts[folder, default: 1] - 1
                counts[folder] = count > 0 ? count : nil
            }
        }
    }

    static func trim(_ cache: URL, bytes budget: Int = 256 * 1024 * 1024, count limit: Int = 64) {
        let files = FileManager.default
        func hashed(_ url: URL) -> Bool {
            let name = url.lastPathComponent
            return name.count == 64 && name.allSatisfy { "0123456789abcdef".contains($0) }
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        func folders(_ parent: URL) -> [URL] {
            ((try? files.contentsOfDirectory(at: parent, includingPropertiesForKeys: Array(keys))) ?? []).filter {
                guard hashed($0), let values = try? $0.resourceValues(forKeys: keys) else { return false }
                return values.isDirectory == true && values.isSymbolicLink != true
            }
        }
        var entries: [(url: URL, bytes: Int, date: Date)] = []
        for source in folders(cache) {
            for folder in folders(source) {
                var bytes = 0
                if let enumerator = files.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) {
                    for case let file as URL in enumerator {
                        bytes += (try? file.resourceValues(forKeys: keys).fileSize) ?? 0
                    }
                }
                entries.append((folder, bytes, (try? folder.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast))
            }
        }
        var total = entries.reduce(0) { $0 + $1.bytes }
        var count = entries.count
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard total > budget || count > limit else { break }
            // Hold the pin lock through removal: a new reader cannot lease
            // the folder between the check and deletion.
            let removed = pinned.withLock { pins in
                guard pins[entry.url.standardizedFileURL.path(percentEncoded: false)] == nil else { return false }
                return (try? files.removeItem(at: entry.url)) != nil
            }
            if removed { total -= entry.bytes; count -= 1 }
        }
        for source in folders(cache) {
            if (try? files.contentsOfDirectory(atPath: source.path(percentEncoded: false)).isEmpty) == true {
                try? files.removeItem(at: source)
            }
        }
    }
}

/// Extraction is serial, including cache reads and pruning. Cancellation
/// removes waiting readers and is checked between inflated entries.
actor WasExtractionGate {
    private var busy = false
    private var waiting: [(UUID, CheckedContinuation<Void, any Error>)] = []

    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if busy { waiting.append((id, continuation)) }
                else { busy = true; continuation.resume() }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }

    func release() {
        if waiting.isEmpty { busy = false }
        else { waiting.removeFirst().1.resume() }
    }
}
