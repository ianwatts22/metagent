import CoreServices
import Foundation
import MetagentCore

/// Watches the directories skills live in and reports settled change.
///
/// The app has no polling loop by design, so without this it only learns about
/// external changes — a CLI removal, another agent editing a skill, a plugin
/// update — at launch or manual refresh. FSEvents supplies the missing signal.
/// Events are debounced because interesting changes arrive in bursts: one
/// plugin update touches hundreds of files, and one rescan at the end is worth
/// more than a rescan per file.
final class SkillRootsWatcher {
    private let debounceSeconds: TimeInterval
    private let onSettledChange: () -> Void
    private var stream: FSEventStreamRef?
    private var watchedPaths: [String] = []
    private var pendingChange: DispatchWorkItem?

    init(debounceSeconds: TimeInterval = 2.0, onSettledChange: @escaping () -> Void) {
        self.debounceSeconds = debounceSeconds
        self.onSettledChange = onSettledChange
    }

    deinit {
        stop()
    }

    /// Starts or rebuilds the stream to cover exactly `paths`. Directories that
    /// do not exist yet are still registered: FSEvents accepts them and begins
    /// reporting once they are created.
    func watch(paths: [String]) {
        let normalized = Array(Set(paths)).sorted()
        guard normalized != watchedPaths else { return }
        stop()
        watchedPaths = normalized
        guard !normalized.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<SkillRootsWatcher>.fromOpaque(info)
                .takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let mustRescan = (0..<eventCount).contains { index in
                let flags = eventFlags[index]
                return flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
                    || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) != 0
                    || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0
            }
            guard mustRescan || SkillRootEventFilter.shouldRefresh(paths: paths) else { return }
            watcher.scheduleSettledChange()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            normalized as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            )
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        pendingChange?.cancel()
        pendingChange = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func scheduleSettledChange() {
        pendingChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onSettledChange()
        }
        pendingChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceSeconds, execute: work)
    }
}
