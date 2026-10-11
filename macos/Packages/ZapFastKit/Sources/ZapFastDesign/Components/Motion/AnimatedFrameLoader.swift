import Foundation

/// Two decoders for the process, with one job per source/size. Queued jobs
/// hold URLs only. The last departing reader cancels the decode.
actor AnimatedFrameLoader {
    private struct Job {
        let url: URL
        let pixels: Int
        var readers: [UUID: CheckedContinuation<AnimatedFrames?, Never>] = [:]
        var task: Task<Void, Never>?
    }

    private let cache: NSCache<NSString, AnimatedFrames> = {
        let cache = NSCache<NSString, AnimatedFrames>()
        cache.countLimit = 12
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    private var jobs: [String: Job] = [:]
    private var queued: [String] = []
    private var running = 0
    var readerCount: Int { jobs.values.reduce(0) { $0 + $1.readers.count } }
    private let decode: @Sendable (URL, Int) async -> AnimatedFrames?

    init(decode: @escaping @Sendable (URL, Int) async -> AnimatedFrames? = AnimatedFrames.decode) {
        self.decode = decode
    }

    func load(_ url: URL, pixels: Int, key: String) async -> AnimatedFrames? {
        guard !Task.isCancelled else { return nil }
        if let known = cache.object(forKey: key as NSString) { return known }
        let reader = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                if jobs[key] == nil {
                    jobs[key] = Job(url: url, pixels: pixels)
                    queued.append(key)
                }
                jobs[key]?.readers[reader] = continuation
                pump()
            }
        } onCancel: {
            Task { await self.cancel(key, reader: reader) }
        }
    }

    private func cancel(_ key: String, reader: UUID) {
        guard let continuation = jobs[key]?.readers.removeValue(forKey: reader) else { return }
        continuation.resume(returning: nil)
        if jobs[key]?.readers.isEmpty == true {
            if let task = jobs[key]?.task { task.cancel() }
            else {
                jobs[key] = nil
                queued.removeAll { $0 == key }
            }
        }
    }

    private func pump() {
        while running < 2, !queued.isEmpty {
            let key = queued.removeFirst()
            guard let job = jobs[key] else { continue }
            running += 1
            jobs[key]?.task = Task {
                let frames = await decode(job.url, job.pixels)
                finish(key, frames: frames)
            }
        }
    }

    private func finish(_ key: String, frames: AnimatedFrames?) {
        let job = jobs.removeValue(forKey: key)
        running -= 1
        if let job, job.task?.isCancelled == true, !job.readers.isEmpty {
            // A pointer can return before the cancelled decoder finishes.
            // Those new readers need a fresh job rather than its nil answer.
            jobs[key] = Job(url: job.url, pixels: job.pixels, readers: job.readers)
            queued.append(key)
            pump()
            return
        }
        if let frames, job?.readers.isEmpty == false {
            cache.setObject(frames, forKey: key as NSString,
                            cost: frames.frames.reduce(0) { $0 + $1.bytesPerRow * $1.height })
        }
        for reader in job?.readers.values ?? [:].values { reader.resume(returning: frames) }
        pump()
    }
}
