import Darwin
import CoreServices
import Foundation
import SQLite3

public struct SkillUsageRefreshOptions: Sendable, Equatable {
    public var sessionRoots: [String]
    public var databasePath: String?
    public var maxBytes: Int64
    public var maxFiles: Int
    /// Maximum size of one JSONL record. This is intentionally independent
    /// from `maxBytes`, which is the cooperative per-refresh slice budget.
    public var maxRecordBytes: Int64
    public var throttleEveryBytes: Int64
    public var throttleDelayMilliseconds: Int
    /// Zero means an explicit foreground refresh. A positive value makes this
    /// a cooperative background refresh: only one app process may claim the
    /// shared database during the interval.
    public var minimumMaintenanceIntervalSeconds: TimeInterval
    /// Background continuation slices can reuse an unchanged filesystem
    /// catalog instead of recursively rediscovering every retained session.
    /// Foreground refreshes leave this false so they always observe disk now.
    public var reusesSourceCatalog: Bool
    /// Even without a filesystem event, a continuation periodically rebuilds
    /// its catalog. This bounds risk from a lost event or an unavailable stream.
    public var sourceCatalogMaximumAgeSeconds: TimeInterval

    public init(
        sessionRoots: [String] = [],
        databasePath: String? = nil,
        maxBytes: Int64 = 8 * 1_024 * 1_024,
        maxFiles: Int = 12,
        maxRecordBytes: Int64 = 8 * 1_024 * 1_024,
        throttleEveryBytes: Int64 = 0,
        throttleDelayMilliseconds: Int = 0,
        minimumMaintenanceIntervalSeconds: TimeInterval = 0,
        reusesSourceCatalog: Bool = false,
        sourceCatalogMaximumAgeSeconds: TimeInterval = 15 * 60
    ) {
        self.sessionRoots = sessionRoots
        self.databasePath = databasePath
        self.maxBytes = max(1, maxBytes)
        self.maxFiles = max(1, maxFiles)
        self.maxRecordBytes = max(1, maxRecordBytes)
        self.throttleEveryBytes = max(0, throttleEveryBytes)
        self.throttleDelayMilliseconds = max(0, throttleDelayMilliseconds)
        self.minimumMaintenanceIntervalSeconds = max(0, minimumMaintenanceIntervalSeconds)
        self.reusesSourceCatalog = reusesSourceCatalog
        self.sourceCatalogMaximumAgeSeconds = max(0, sourceCatalogMaximumAgeSeconds)
    }
}

public struct SkillUsageSummary: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let skillName: String
    public let canonicalPath: String?
    public let scope: String
    public let totalInvocations: Int
    public let invocations7d: Int
    public let invocations30d: Int
    public let activeTurns: Int
    public let distinctThreads: Int
    public let repeatInvocations: Int
    public let directInvocations: Int
    public let inferredInvocations: Int
    public let firstUsedAt: String
    public let lastUsedAt: String
}

public struct SkillUsageSnapshot: Codable, Sendable, Equatable {
    public let summaries: [SkillUsageSummary]
    public let totalInvocations: Int
    public let totalFiles: Int
    public let completedFiles: Int
    public let totalBytes: Int64
    public let processedBytes: Int64
    public let isBackfillComplete: Bool
    public let isParserUpgradeBackfill: Bool
    public let displayParserVersion: Int?
    public let targetParserVersion: Int
    public let coverageStartedAt: String?
    public let lastUpdatedAt: String?

    public static let empty = SkillUsageSnapshot(
        summaries: [],
        totalInvocations: 0,
        totalFiles: 0,
        completedFiles: 0,
        totalBytes: 0,
        processedBytes: 0,
        isBackfillComplete: false,
        isParserUpgradeBackfill: false,
        displayParserVersion: nil,
        targetParserVersion: 0,
        coverageStartedAt: nil,
        lastUpdatedAt: nil
    )
}

/// One skill's observed reads on one calendar day.
public struct SkillUsageDayCount: Codable, Sendable, Equatable {
    public let canonicalPath: String?
    public let skillID: String
    public let day: String
    public let count: Int

    public init(canonicalPath: String?, skillID: String, day: String, count: Int) {
        self.canonicalPath = canonicalPath
        self.skillID = skillID
        self.day = day
        self.count = count
    }
}

public struct SkillUsageRefreshReport: Codable, Sendable, Equatable {
    public let snapshot: SkillUsageSnapshot
    public let filesRead: Int
    public let bytesRead: Int64
    public let processedBytesAdvanced: Int64
    public let invocationsAdded: Int
    public let hasMore: Bool
    public let wasDeferred: Bool
    public let warnings: [String]
}

public struct AgentRunDurationStats: Codable, Sendable, Equatable {
    public let windowDays: Int
    public let runCount: Int
    public let medianMilliseconds: Int64
    public let averageMilliseconds: Int64
    public let p90Milliseconds: Int64
    public let totalMilliseconds: Int64
    public let isBackfillComplete: Bool

    public static let empty = AgentRunDurationStats(
        windowDays: 30,
        runCount: 0,
        medianMilliseconds: 0,
        averageMilliseconds: 0,
        p90Milliseconds: 0,
        totalMilliseconds: 0,
        isBackfillComplete: false
    )
}

public extension MetagentCore {
    static func loadSkillUsageSnapshot(databasePath: String? = nil) -> SkillUsageSnapshot? {
        try? SkillUsageStore(path: databasePath).snapshot()
    }

    /// A small, privacy-protected materialization used only to paint warm
    /// launches. The SQLite event store remains authoritative; callers that
    /// need current data must use `loadSkillUsageSnapshot` or run a refresh.
    static func loadCachedSkillUsageSnapshot(databasePath: String? = nil) -> SkillUsageSnapshot? {
        try? SkillUsageStore(path: databasePath).loadLaunchSnapshot()
    }

    static func refreshSkillUsage(
        options: SkillUsageRefreshOptions = SkillUsageRefreshOptions()
    ) throws -> SkillUsageRefreshReport {
        let store = try SkillUsageStore(path: options.databasePath)
        let result = try store.refresh(options: options)
        // Materialization is an acceleration detail. A permissions or disk
        // failure must not turn a successful canonical refresh into failure.
        if !options.reusesSourceCatalog
            || !store.launchCacheOverlapsSessionRoots(options.sessionRoots)
        {
            try? store.saveLaunchSnapshot(
                result.report.snapshot,
                databaseGeneration: result.snapshotGeneration
            )
        }
        return result.report
    }

    /// Per-day observed reads for every skill identity in the event log, used to
    /// reconstruct adoption history for dates that predate history capture.
    static func skillUsageDailyCounts(
        databasePath: String? = nil,
        calendar: Calendar = .current
    ) throws -> [SkillUsageDayCount] {
        try SkillUsageStore(path: databasePath).dailyCounts(calendar: calendar)
    }

    static func agentRunDurationStats(
        databasePath: String? = nil,
        windowDays: Int = 30,
        projectRoot: String? = nil,
        now: Date = Date()
    ) throws -> AgentRunDurationStats {
        try SkillUsageStore(path: databasePath).agentRunDurationStats(
            windowDays: windowDays,
            projectRoot: projectRoot,
            now: now
        )
    }

    static func parseSkillUsageTimestamp(_ value: String) -> Date? {
        if let date = iso8601FractionalFormatter.date(from: value) {
            return date
        }
        return iso8601Formatter.date(from: value)
    }

    static func normalizedPluginMarketplace(_ marketplace: String) -> String {
        ["openai-curated", "openai-curated-remote"].contains(marketplace)
            ? "openai-curated"
            : marketplace
    }
}

private let skillUsageParserVersion = 17
private let skillUsageLaunchCacheFormatVersion = 2
private let skillUsageEventsTable = "skill_usage_events"
private let skillUsageSourcesTable = "skill_usage_sources"
private let agentRunsTable = "agent_runs"

private struct SkillUsageDayKey: Hashable {
    let canonicalPath: String
    let skillID: String
    let day: String
}

private let skillUsageMetadataTable = "skill_usage_metadata"
private let skillUsageStoreStateTable = "skill_usage_store_state"
private let previousSkillUsageEventsTable = "skill_usage_events_previous"
private let previousSkillUsageSourcesTable = "skill_usage_sources_previous"
private let previousSkillUsageMetadataTable = "skill_usage_metadata_previous"
private let previousAgentRunsTable = "agent_runs_previous"

private func skillUsageCodexHomeURL() -> URL {
    if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], !configured.isEmpty {
        return URL(fileURLWithPath: configured).standardizedFileURL
    }
    return homeURL().standardizedFileURL.appendingPathComponent(".codex").standardizedFileURL
}

private struct UsageSource: Sendable {
    let path: String
    let size: Int64
    let modifiedAt: Double
    let fileIdentity: String
    let prefixFingerprint: String
    var checkpoint: UsageSourceCheckpoint?
}

private struct UsageSourceMetadata {
    let size: Int64
    let modifiedAt: Double
    let fileIdentity: String
}

private struct UsageSourceState: Sendable {
    var offset: Int64 = 0
    var fileSize: Int64 = 0
    var modifiedAt: Double = 0
    var fileIdentity = ""
    var prefixFingerprint = ""
    var sessionID = ""
    var cwd = ""
    var turnID = ""
    var coverageStartedAt = ""
    var pendingEvents: [String: [ParsedUsageEvent]] = [:]
    var runSessionID = ""
    var runSessionStartedAt = ""
    var runKind = "unknown"
}

private struct UsageSourceCheckpoint: Sendable {
    var offset: Int64
    var fileSize: Int64
    var modifiedAt: Double
    var fileIdentity: String
    var prefixFingerprint: String

    init(
        offset: Int64,
        fileSize: Int64,
        modifiedAt: Double,
        fileIdentity: String,
        prefixFingerprint: String
    ) {
        self.offset = offset
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.fileIdentity = fileIdentity
        self.prefixFingerprint = prefixFingerprint
    }

    init(state: UsageSourceState) {
        self.init(
            offset: state.offset,
            fileSize: state.fileSize,
            modifiedAt: state.modifiedAt,
            fileIdentity: state.fileIdentity,
            prefixFingerprint: state.prefixFingerprint
        )
    }
}

private struct UsageSourceCheckpointRecord: Sendable {
    let path: String
    let checkpoint: UsageSourceCheckpoint
}

private struct UsageSourceCatalogKey: Hashable, Sendable {
    let databasePath: String
    let roots: [String]
}

private struct UsageSourceCatalogItem: Sendable {
    let path: String
    let size: Int64
    let modifiedAt: Double
    let fileIdentity: String

    init(source: UsageSource) {
        path = source.path
        size = source.size
        modifiedAt = source.modifiedAt
        fileIdentity = source.fileIdentity
    }
}

/// One passive invalidation stream per live catalog. It does no polling and
/// marks the catalog dirty for any recursive change under a session root.
/// Foreground refreshes still force discovery, and the cache also has a maximum
/// age, so stream setup failure or a dropped event cannot make reuse permanent.
private let usageSourceCatalogInvalidatingEventFlags = FSEventStreamEventFlags(
    kFSEventStreamEventFlagMustScanSubDirs |
        kFSEventStreamEventFlagUserDropped |
        kFSEventStreamEventFlagKernelDropped |
        kFSEventStreamEventFlagEventIdsWrapped |
        kFSEventStreamEventFlagRootChanged |
        kFSEventStreamEventFlagMount |
        kFSEventStreamEventFlagUnmount |
        kFSEventStreamEventFlagItemCreated |
        kFSEventStreamEventFlagItemRemoved |
        kFSEventStreamEventFlagItemInodeMetaMod |
        kFSEventStreamEventFlagItemRenamed |
        kFSEventStreamEventFlagItemModified |
        kFSEventStreamEventFlagItemFinderInfoMod |
        kFSEventStreamEventFlagItemChangeOwner |
        kFSEventStreamEventFlagItemXattrMod |
        kFSEventStreamEventFlagItemCloned
)

private func shouldInvalidateUsageSourceCatalog(
    _ flags: FSEventStreamEventFlags
) -> Bool {
    flags & usageSourceCatalogInvalidatingEventFlags != 0
}

private func canonicalUsageWatchPaths(_ paths: [String]) -> [String] {
    Array(Set(paths.map { path in
        let root = URL(fileURLWithPath: path).standardizedFileURL
        guard root.path != "/" else { return root.path }
        // Resolve aliases in the parent chain (notably macOS's /var ->
        // /private/var) without resolving the watched directory itself. A
        // user-configured root may intentionally be a mutable symlink, which
        // the cache must detect and decline rather than silently pinning to its
        // current target.
        return root.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(root.lastPathComponent)
            .standardizedFileURL
            .path
    })).sorted()
}

private func skillUsageLaunchCacheURL(for databaseURL: URL) -> URL {
    databaseURL.deletingLastPathComponent().appendingPathComponent(
        "\(databaseURL.lastPathComponent)-launch-snapshot.json"
    )
}

private struct UsageSourceCatalogOwnedPaths: Sendable {
    private let exactPaths: Set<String>
    private let stateDirectoryPath: String
    private let temporaryCachePrefix: String

    init(databasePath: String) {
        let databaseURL = URL(fileURLWithPath: databasePath).standardizedFileURL
        let cacheURL = skillUsageLaunchCacheURL(for: databaseURL)
        exactPaths = Set(canonicalUsageWatchPaths([
            databaseURL.path,
            databaseURL.path + "-journal",
            databaseURL.path + "-shm",
            databaseURL.path + "-wal",
            cacheURL.path,
            cacheURL.appendingPathExtension("lock").path,
        ]))
        stateDirectoryPath = canonicalUsageWatchPaths([
            databaseURL.deletingLastPathComponent().path,
        ]).first ?? databaseURL.deletingLastPathComponent().path
        temporaryCachePrefix = canonicalUsageWatchPaths([
            cacheURL.deletingLastPathComponent().appendingPathComponent(
                ".\(cacheURL.lastPathComponent)."
            ).path,
        ]).first ?? ""
    }

    func contains(_ path: String, flags: FSEventStreamEventFlags) -> Bool {
        let canonical = canonicalUsageWatchPaths([path]).first ?? path
        if exactPaths.contains(canonical)
            || (!temporaryCachePrefix.isEmpty && canonical.hasPrefix(temporaryCachePrefix))
        {
            return true
        }
        guard canonical == stateDirectoryPath else { return false }
        let structuralFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated |
                kFSEventStreamEventFlagItemRemoved |
                kFSEventStreamEventFlagItemRenamed |
                kFSEventStreamEventFlagItemCloned
        )
        // File-events mode emits the changed child separately. Ignore only the
        // directory bookkeeping that accompanies our own atomic SQLite/cache
        // writes; structural changes and dropped streams remain authoritative.
        return flags & structuralFlags == 0
    }
}

private let stableSystemSymlinkPaths: Set<String> = ["/etc", "/tmp", "/var"]

private func usagePathContainsMutableSymlink(_ path: String) -> Bool {
    let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    var candidate = URL(fileURLWithPath: "/", isDirectory: true)
    for component in components.dropFirst() {
        candidate.appendPathComponent(component)
        var metadata = stat()
        guard lstat(candidate.path, &metadata) == 0 else { continue }
        let isSymlink = metadata.st_mode & S_IFMT == S_IFLNK
        if isSymlink, !stableSystemSymlinkPaths.contains(candidate.path) {
            return true
        }
    }
    return false
}

private func usageRootIsMissing(_ path: String) -> Bool {
    var metadata = stat()
    return lstat(path, &metadata) != 0 && errno == ENOENT
}

private func usageIdentityWatchPaths(_ roots: [String]) -> [String] {
    var paths: Set<String> = []
    for root in roots {
        var current = URL(fileURLWithPath: root).standardizedFileURL
        while current.path != "/" {
            paths.insert(current.path)
            let parent = current.deletingLastPathComponent().standardizedFileURL
            guard parent.path != current.path else { break }
            current = parent
        }
    }
    return paths.sorted()
}

private func usageStreamWatchPaths(_ roots: [String]) -> [String] {
    Array(Set(roots.map { root in
        URL(fileURLWithPath: root)
            .deletingLastPathComponent().standardizedFileURL.path
    })).sorted()
}

private func usageEventInvalidatesRoots(
    _ eventPath: String,
    roots: [String]
) -> Bool {
    let normalizedEventPath = canonicalUsageWatchPaths([eventPath]).first ?? eventPath
    return roots.contains { root in
        normalizedEventPath == root || normalizedEventPath.hasPrefix(root + "/")
    }
}

private final class UsageSourceCatalogWatcherState: @unchecked Sendable {
    private let roots: [String]
    private let ownedPaths: UsageSourceCatalogOwnedPaths?
    private let lock = NSLock()
    private var baselineEventID: FSEventStreamEventId?
    private var dirty = false

    init(roots: [String] = [], databasePath: String? = nil) {
        self.roots = roots
        ownedPaths = databasePath.map(UsageSourceCatalogOwnedPaths.init(databasePath:))
    }

    var isDirty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return dirty
    }

    func arm(baselineEventID: FSEventStreamEventId) {
        lock.lock()
        dirty = false
        self.baselineEventID = baselineEventID
        lock.unlock()
    }

    func handle(
        _ flags: FSEventStreamEventFlags,
        eventID: FSEventStreamEventId,
        eventPath: String? = nil
    ) {
        guard shouldInvalidateUsageSourceCatalog(flags) else { return }
        let mustInvalidateWholeTree = flags & FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs |
                kFSEventStreamEventFlagUserDropped |
                kFSEventStreamEventFlagKernelDropped |
                kFSEventStreamEventFlagEventIdsWrapped |
                kFSEventStreamEventFlagRootChanged
        ) != 0
        if !mustInvalidateWholeTree,
           let eventPath,
           ownedPaths?.contains(eventPath, flags: flags) == true
        {
            return
        }
        if !mustInvalidateWholeTree,
           !roots.isEmpty,
           let eventPath,
           !usageEventInvalidatesRoots(eventPath, roots: roots)
        {
            return
        }

        lock.lock()
        if let baselineEventID,
           (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
            || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped) != 0
            || eventID == 0
            || eventID > baselineEventID)
        {
            dirty = true
        }
        lock.unlock()
    }

    func markDirty() {
        lock.lock()
        dirty = true
        lock.unlock()
    }
}

private final class UsageRootChangeWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject

    init?(path: String, queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
        let descriptor = Darwin.open(path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}

private func armUsageSourceCatalogWatcherState(
    _ state: UsageSourceCatalogWatcherState,
    on queue: DispatchQueue
) {
    // Capture the system event watermark on the callback queue. Events
    // generated before it are reflected by the full discovery that starts
    // after this block; later events invalidate even if callbacks arrive out
    // of order. Root-change events always invalidate once armed.
    queue.sync {
        state.arm(baselineEventID: FSEventsGetCurrentEventId())
    }
}

private final class UsageSourceCatalogWatcher: @unchecked Sendable {
    private let state: UsageSourceCatalogWatcherState
    private let queue = DispatchQueue(label: "com.ianwatts.metagent.usage-source-catalog")
    private var stream: FSEventStreamRef?
    private var identityChangeWatchers: [UsageRootChangeWatcher] = []
    private var missingIdentityPathsWithoutDescriptors: [String] = []
    private(set) var isStarted = false

    init(paths: [String], databasePath: String) {
        // A mutable symlink anywhere in a configured root can be retargeted
        // outside every stream created for its old hierarchy. In that rare
        // configuration, decline to cache rather than weaken freshness. The
        // fixed macOS /etc, /tmp, and /var aliases are normalized below.
        guard !paths.contains(where: usagePathContainsMutableSymlink) else {
            state = UsageSourceCatalogWatcherState()
            return
        }
        let roots = canonicalUsageWatchPaths(paths)
        state = UsageSourceCatalogWatcherState(roots: roots, databasePath: databasePath)
        // A filesystem-root stream would observe every machine-wide mutation.
        // Keep an explicit `/` scan correct but uncached rather than turning a
        // pathological configuration into a permanent energy hotspot.
        guard !roots.isEmpty, !roots.contains("/") else { return }
        var hasUnwatchedExistingIdentityPath = false
        identityChangeWatchers = usageIdentityWatchPaths(roots).compactMap { path in
            guard let watcher = UsageRootChangeWatcher(path: path, queue: queue, onChange: { [state] in
                state.markDirty()
            }) else {
                if usageRootIsMissing(path) {
                    missingIdentityPathsWithoutDescriptors.append(path)
                } else {
                    hasUnwatchedExistingIdentityPath = true
                }
                return nil
            }
            return watcher
        }
        // FSEvents can report only the destination of a rename. Watch every
        // existing ancestor inode so moving the root itself or any parent
        // invalidates its path identity. If any descriptor is unavailable,
        // decline reuse instead of risking a stale catalog.
        guard !hasUnwatchedExistingIdentityPath else { return }
        // A parent stream recursively sees the root and all descendants while
        // also catching creation of a root that was initially absent. Callback
        // filtering below discards unrelated siblings.
        let streamPaths = usageStreamWatchPaths(roots)
        // A top-level root such as `/Users` also derives a machine-wide `/`
        // parent stream. Decline reuse for that configuration just as we do
        // for an explicit filesystem-root scan.
        guard !streamPaths.contains("/") else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(state).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<UsageSourceCatalogWatcherState>
                    .fromOpaque(info)
                    .retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<UsageSourceCatalogWatcherState>
                    .fromOpaque(info)
                    .release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, eventIDs in
            guard let info, eventCount > 0 else { return }
            let state = Unmanaged<UsageSourceCatalogWatcherState>.fromOpaque(info)
                .takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            for index in 0 ..< Int(eventCount) {
                state.handle(
                    eventFlags[index],
                    eventID: eventIDs[index],
                    eventPath: index < paths.count ? paths[index] : nil
                )
            }
        }
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            streamPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes |
                    kFSEventStreamCreateFlagFileEvents
            )
        ) else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        isStarted = FSEventStreamStart(created)
        if isStarted {
            armUsageSourceCatalogWatcherState(state, on: queue)
        } else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
        }
    }

    deinit {
        identityChangeWatchers.removeAll()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    var isDirty: Bool {
        state.isDirty
    }

    func canRetainCatalogAfterDiscovery() -> Bool {
        guard isStarted, let stream else { return false }
        // Discovery may last long enough for stream delivery latency to hide a
        // change. Flush and drain before deciding whether this exact walk is
        // safe to retain for the next continuation.
        FSEventStreamFlushSync(stream)
        queue.sync {}
        guard !state.isDirty else { return false }
        // A root or ancestor missing during watcher setup has no inode
        // descriptor. If it appeared before the stream started, its creation
        // event is outside the stream horizon; refuse retention and let the
        // next discovery attach the descriptor.
        return missingIdentityPathsWithoutDescriptors.allSatisfy(usageRootIsMissing)
    }

    func markDirty() {
        state.markDirty()
    }
}

private final class UsageSourceCatalogCache: @unchecked Sendable {
    static let shared = UsageSourceCatalogCache()

    private struct Entry {
        let items: [UsageSourceCatalogItem]
        let createdAt: TimeInterval
        let watcher: UsageSourceCatalogWatcher
    }

    private let lock = NSLock()
    private var entries: [UsageSourceCatalogKey: Entry] = [:]
    private var discoveryCounts: [UsageSourceCatalogKey: Int] = [:]

    func sources(
        key: UsageSourceCatalogKey,
        roots: [String],
        allowsReuse: Bool,
        maximumAgeSeconds: TimeInterval,
        materialize: ([UsageSourceCatalogItem]) -> [UsageSource],
        discover: () -> [UsageSource]
    ) -> [UsageSource] {
        guard allowsReuse else {
            let sources = discover()
            lock.lock()
            discoveryCounts[key, default: 0] += 1
            entries.removeValue(forKey: key)
            lock.unlock()
            return sources
        }
        if let items = reusableItems(
            for: key,
            maximumAgeSeconds: maximumAgeSeconds
        ) {
            return materialize(items)
        }

        // Start listening before walking. If the tree changes during discovery,
        // the current refresh keeps its normal best-effort view but that view is
        // not retained for a later continuation.
        let watcher = UsageSourceCatalogWatcher(paths: roots, databasePath: key.databasePath)
        let sources = discover()
        let items = sources.map(UsageSourceCatalogItem.init(source:))
        let canRetainCatalog = watcher.canRetainCatalogAfterDiscovery()
        lock.lock()
        discoveryCounts[key, default: 0] += 1
        if canRetainCatalog {
            entries[key] = Entry(
                items: items,
                createdAt: ProcessInfo.processInfo.systemUptime,
                watcher: watcher
            )
        } else {
            entries.removeValue(forKey: key)
        }
        lock.unlock()
        return sources
    }

    func invalidate(databasePath: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard let databasePath else {
            entries.removeAll()
            return
        }
        for key in entries.keys where key.databasePath == databasePath {
            entries[key]?.watcher.markDirty()
        }
    }

    func resetForTesting() {
        lock.lock()
        entries.removeAll()
        discoveryCounts.removeAll()
        lock.unlock()
    }

    func discoveryCount(databasePath: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return discoveryCounts.reduce(into: 0) { count, record in
            if record.key.databasePath == databasePath {
                count += record.value
            }
        }
    }

    private func reusableItems(
        for key: UsageSourceCatalogKey,
        maximumAgeSeconds: TimeInterval
    ) -> [UsageSourceCatalogItem]? {
        lock.lock()
        defer { lock.unlock() }
        guard maximumAgeSeconds > 0,
              let entry = entries[key],
              !entry.watcher.isDirty,
              ProcessInfo.processInfo.systemUptime - entry.createdAt < maximumAgeSeconds
        else { return nil }
        return entry.items
    }
}

extension MetagentCore {
    static func resetSkillUsageSourceCatalogForTesting() {
        UsageSourceCatalogCache.shared.resetForTesting()
    }

    static func skillUsageLaunchCachePathForTesting(databasePath: String) throws -> String {
        try SkillUsageStore(path: databasePath).launchCachePath.path
    }

    static func saveSkillUsageLaunchSnapshotForTesting(
        _ snapshot: SkillUsageSnapshot,
        databasePath: String,
        snapshotGeneration: Int64
    ) throws {
        let store = try SkillUsageStore(path: databasePath)
        let current = try store.currentLaunchGeneration()
        try store.saveLaunchSnapshot(
            snapshot,
            databaseGeneration: SkillUsageStoreGeneration(
                storeID: current.storeID,
                sequence: snapshotGeneration
            )
        )
    }

    static func invalidateSkillUsageSourceCatalogForTesting(databasePath: String? = nil) {
        UsageSourceCatalogCache.shared.invalidate(
            databasePath: databasePath.map(standardizedUsageDatabasePath)
        )
    }

    static func skillUsageSourceDiscoveryCountForTesting(databasePath: String) -> Int {
        UsageSourceCatalogCache.shared.discoveryCount(
            databasePath: standardizedUsageDatabasePath(databasePath)
        )
    }

    static func shouldInvalidateSkillUsageSourceCatalogForTesting(
        eventFlags: FSEventStreamEventFlags
    ) -> Bool {
        shouldInvalidateUsageSourceCatalog(eventFlags)
    }

    static func skillUsageCatalogArmingDrainsQueuedCallbacksForTesting() -> Bool {
        let state = UsageSourceCatalogWatcherState()
        let queue = DispatchQueue(label: "com.ianwatts.metagent.usage-source-catalog-test")
        queue.async {
            state.handle(
                FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified),
                eventID: 1
            )
        }
        armUsageSourceCatalogWatcherState(state, on: queue)
        return !state.isDirty
    }

    static func skillUsageCatalogInvalidatesEventForTesting(
        baselineEventID: FSEventStreamEventId,
        eventID: FSEventStreamEventId,
        flags: FSEventStreamEventFlags
    ) -> Bool {
        let state = UsageSourceCatalogWatcherState()
        state.arm(baselineEventID: baselineEventID)
        state.handle(flags, eventID: eventID)
        return state.isDirty
    }

    static func skillUsageCatalogInvalidatesPathEventForTesting(
        roots: [String],
        databasePath: String,
        eventPath: String,
        flags: FSEventStreamEventFlags
    ) -> Bool {
        let state = UsageSourceCatalogWatcherState(
            roots: canonicalUsageWatchPaths(roots),
            databasePath: databasePath
        )
        state.arm(baselineEventID: 100)
        state.handle(flags, eventID: 101, eventPath: eventPath)
        return state.isDirty
    }

    static func canonicalSkillUsageWatchPathsForTesting(_ paths: [String]) -> [String] {
        canonicalUsageWatchPaths(paths)
    }

    static func skillUsageEventInvalidatesRootsForTesting(
        eventPath: String,
        roots: [String]
    ) -> Bool {
        usageEventInvalidatesRoots(
            eventPath,
            roots: canonicalUsageWatchPaths(roots)
        )
    }

    static func skillUsageWatchSupportsReuseForTesting(_ roots: [String]) -> Bool {
        let canonicalRoots = canonicalUsageWatchPaths(roots)
        return !canonicalRoots.contains("/")
            && !usageStreamWatchPaths(canonicalRoots).contains("/")
            && !roots.contains(where: usagePathContainsMutableSymlink)
    }

    static func skillUsageRootIsMissingForTesting(_ rootPath: String) -> Bool {
        usageRootIsMissing(rootPath)
    }

    static func skillUsageIdentityWatchPathsForTesting(_ roots: [String]) -> [String] {
        usageIdentityWatchPaths(canonicalUsageWatchPaths(roots))
    }

    static func skillUsageRootWatcherDetectsRenameForTesting(
        rootPath: String,
        renamedPath: String
    ) throws -> Bool {
        let queue = DispatchQueue(label: "com.ianwatts.metagent.usage-root-change-test")
        let changed = DispatchSemaphore(value: 0)
        let watchPaths = usageIdentityWatchPaths([rootPath])
        let watchers = watchPaths.compactMap { path in
            UsageRootChangeWatcher(path: path, queue: queue) { changed.signal() }
        }
        guard watchers.count == watchPaths.count else { return false }
        return try withExtendedLifetime(watchers) {
            try FileManager.default.moveItem(
                atPath: rootPath,
                toPath: renamedPath
            )
            return changed.wait(timeout: .now() + 2) == .success
        }
    }

    static func skillUsageRootWatcherDetectsDeleteForTesting(
        rootPath: String
    ) throws -> Bool {
        let queue = DispatchQueue(label: "com.ianwatts.metagent.usage-root-delete-test")
        let changed = DispatchSemaphore(value: 0)
        let watchPaths = usageIdentityWatchPaths([rootPath])
        let watchers = watchPaths.compactMap { path in
            UsageRootChangeWatcher(path: path, queue: queue) { changed.signal() }
        }
        guard watchers.count == watchPaths.count else { return false }
        return try withExtendedLifetime(watchers) {
            try FileManager.default.removeItem(atPath: rootPath)
            return changed.wait(timeout: .now() + 2) == .success
        }
    }

    static func skillUsageRootWatcherDetectsAncestorRenameForTesting(
        rootPath: String,
        ancestorPath: String,
        renamedAncestorPath: String
    ) throws -> Bool {
        let queue = DispatchQueue(label: "com.ianwatts.metagent.usage-ancestor-change-test")
        let changed = DispatchSemaphore(value: 0)
        let watchPaths = usageIdentityWatchPaths([rootPath])
        let watchers = watchPaths.compactMap { path in
            UsageRootChangeWatcher(path: path, queue: queue) { changed.signal() }
        }
        guard watchers.count == watchPaths.count else { return false }
        return try withExtendedLifetime(watchers) {
            try FileManager.default.moveItem(
                atPath: ancestorPath,
                toPath: renamedAncestorPath
            )
            return changed.wait(timeout: .now() + 2) == .success
        }
    }
}

private func standardizedUsageDatabasePath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
}

private struct ParsedSkillIdentity: Codable, Sendable {
    let id: String
    let name: String
    let confirmationName: String
    let canonicalPath: String
    let scope: String
}

private struct ParsedUsageEvent: Codable, Sendable {
    let id: String
    let skill: ParsedSkillIdentity
    let occurredAt: String
    let sessionID: String
    let turnID: String
    let cwd: String
    let sourcePath: String
    let callID: String
}

private struct ParsedAgentRun: Sendable {
    let id: String
    let sessionID: String
    let turnID: String
    let cwd: String
    let startedAt: String
    let completedAt: String
    let durationMilliseconds: Int64
    let kind: String
    let sourcePath: String
}

private struct FileParseResult: Sendable {
    let state: UsageSourceState
    let events: [ParsedUsageEvent]
    let runs: [ParsedAgentRun]
    let bytesRead: Int64
    let reachedEnd: Bool
    let warning: String?
}

private struct SkillUsageStoredRefreshResult {
    let report: SkillUsageRefreshReport
    /// Monotonic generation committed in the same SQLite transaction that
    /// captures `report.snapshot`. It orders concurrent sidecar writers without
    /// depending on wall-clock monotonicity.
    let snapshotGeneration: SkillUsageStoreGeneration
}

private struct SkillUsageStoreGeneration: Equatable, Sendable {
    let storeID: String
    let sequence: Int64
}

struct SkillUsageLaunchCacheEnvelope: Codable, Equatable {
    let formatVersion: Int
    let parserGeneration: Int
    let storeID: String
    let snapshotGeneration: Int64
    let generatedAt: Date
    let snapshot: SkillUsageSnapshot
}

private struct ExecutedCommand: Sendable {
    let text: String
    let workdir: String?
}

private final class SkillUsageStore {
    private let path: URL
    private let fileManager = FileManager.default

    init(path: String?) throws {
        if let path {
            self.path = URL(fileURLWithPath: path)
        } else {
            self.path = homeURL().standardizedFileURL
                .appendingPathComponent("Library/Application Support/Metagent/usage.sqlite")
        }
        try fileManager.createDirectory(
            at: self.path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func refresh(options: SkillUsageRefreshOptions) throws -> SkillUsageStoredRefreshResult {
        let parserGenerationChanged = try prepareParserVersion()
        if parserGenerationChanged {
            UsageSourceCatalogCache.shared.invalidate(databasePath: path.standardizedFileURL.path)
        }
        var maintenanceLeaseID: String?
        if options.minimumMaintenanceIntervalSeconds > 0 {
            guard let claimedLeaseID = try claimMaintenanceLease(
                minimumIntervalSeconds: options.minimumMaintenanceIntervalSeconds
            ) else {
                let (current, snapshotGeneration) = try snapshotWithCurrentLaunchGeneration()
                return SkillUsageStoredRefreshResult(
                    report: SkillUsageRefreshReport(
                        snapshot: current,
                        filesRead: 0,
                        bytesRead: 0,
                        processedBytesAdvanced: 0,
                        invocationsAdded: 0,
                        hasMore: !current.isBackfillComplete,
                        wasDeferred: true,
                        warnings: []
                    ),
                    snapshotGeneration: snapshotGeneration
                )
            }
            maintenanceLeaseID = claimedLeaseID
        }
        defer {
            if let maintenanceLeaseID {
                try? finishMaintenanceLease(id: maintenanceLeaseID)
            }
        }
        var checkpoints = try loadSourceCheckpoints()
        let checkpointsByIdentity = indexCheckpointsByIdentity(checkpoints)
        let catalogRoots = resolvedSessionRoots(options.sessionRoots).map(\.path)
        let catalogKey = UsageSourceCatalogKey(
            databasePath: path.standardizedFileURL.path,
            roots: catalogRoots
        )
        var sources = UsageSourceCatalogCache.shared.sources(
            key: catalogKey,
            roots: catalogRoots,
            allowsReuse: options.reusesSourceCatalog,
            maximumAgeSeconds: options.sourceCatalogMaximumAgeSeconds,
            materialize: { items in
                self.materializeCatalogItems(
                    items,
                    checkpoints: checkpoints,
                    checkpointsByIdentity: checkpointsByIdentity
                )
            },
            discover: {
                self.discoverSources(
                    roots: options.sessionRoots,
                    checkpoints: checkpoints,
                    checkpointsByIdentity: checkpointsByIdentity
                )
            }
        )
        let sourcePaths = Set(sources.map(\.path))
        var migrations: [(oldPath: String, newPath: String, sourceIndex: Int)] = []
        let orphanedByIdentity = Dictionary(grouping: checkpoints.filter {
            !sourcePaths.contains($0.key) && !$0.value.fileIdentity.isEmpty
        }, by: { $0.value.fileIdentity })
        if !orphanedByIdentity.isEmpty {
            for (sourceIndex, source) in sources.enumerated()
                where source.checkpoint == nil && !source.fileIdentity.isEmpty
            {
                guard let matches = orphanedByIdentity[source.fileIdentity], matches.count == 1 else { continue }
                migrations.append((matches[0].key, source.path, sourceIndex))
            }
        }
        if !migrations.isEmpty {
            for migration in migrations {
                guard var state = try loadSourceState(path: migration.oldPath) else { continue }
                state.pendingEvents = state.pendingEvents.mapValues { pending in
                    pending.map { event in
                        ParsedUsageEvent(
                            id: event.id,
                            skill: event.skill,
                            occurredAt: event.occurredAt,
                            sessionID: event.sessionID,
                            turnID: event.turnID,
                            cwd: event.cwd,
                            sourcePath: migration.newPath,
                            callID: event.callID
                        )
                    }
                }
                try migrateSource(from: migration.oldPath, to: migration.newPath, state: state)
                checkpoints.removeValue(forKey: migration.oldPath)
                let checkpoint = UsageSourceCheckpoint(state: state)
                checkpoints[migration.newPath] = checkpoint
                sources[migration.sourceIndex].checkpoint = checkpoint
            }
        }
        let resetIndices = sources.indices.filter { sourceIndex in
            let source = sources[sourceIndex]
            guard let checkpoint = source.checkpoint else { return false }
            let shrank = checkpoint.offset > source.size || checkpoint.fileSize > source.size
            let identityChanged = !checkpoint.fileIdentity.isEmpty
                && !source.fileIdentity.isEmpty
                && checkpoint.fileIdentity != source.fileIdentity
            let prefixChanged = !checkpoint.prefixFingerprint.isEmpty
                && !source.prefixFingerprint.isEmpty
                && checkpoint.prefixFingerprint != source.prefixFingerprint
            return shrank || identityChanged || prefixChanged
        }
        let resetPaths = resetIndices.map { sources[$0].path }
        if !resetPaths.isEmpty {
            try resetSources(resetPaths)
            for sourceIndex in resetIndices {
                let path = sources[sourceIndex].path
                checkpoints.removeValue(forKey: path)
                sources[sourceIndex].checkpoint = nil
            }
        }
        let startingProcessedBytes = processedBytes(for: sources)
        var candidateIndices = sources.indices.filter { index in
            (sources[index].checkpoint?.offset ?? 0) < sources[index].size
        }
        candidateIndices.sort { leftIndex, rightIndex in
            let left = sources[leftIndex]
            let right = sources[rightIndex]
            if left.modifiedAt != right.modifiedAt {
                return left.modifiedAt > right.modifiedAt
            }
            return left.path > right.path
        }

        var filesRead = 0
        var bytesRead: Int64 = 0
        var invocationsAdded = 0
        var warnings: [String] = []
        var identityCache: [String: ParsedSkillIdentity] = [:]

        for sourceIndex in candidateIndices {
            guard filesRead < options.maxFiles, bytesRead < options.maxBytes else { break }
            let source = sources[sourceIndex]
            let state = try loadSourceState(path: source.path) ?? UsageSourceState()
            let remainingBudget = max(1, options.maxBytes - bytesRead)
            let result = parse(
                source: source,
                state: state,
                maxBytes: remainingBudget,
                maxRecordBytes: options.maxRecordBytes,
                throttleEveryBytes: options.throttleEveryBytes,
                throttleDelayMilliseconds: options.throttleDelayMilliseconds,
                throttleOffset: bytesRead,
                identityCache: &identityCache
            )
            let added = try save(result: result, source: source)
            let checkpoint = UsageSourceCheckpoint(state: result.state)
            checkpoints[source.path] = checkpoint
            sources[sourceIndex].checkpoint = checkpoint
            filesRead += 1
            bytesRead += result.bytesRead
            invocationsAdded += added
            if let warning = result.warning {
                warnings.append(warning)
            }
        }

        let progress = progress(for: sources)
        try saveProgress(
            progress,
            force: filesRead > 0 || !migrations.isEmpty || !resetPaths.isEmpty
        )
        let (snapshot, snapshotGeneration) = try snapshotAdvancingLaunchGeneration()
        return SkillUsageStoredRefreshResult(
            report: SkillUsageRefreshReport(
                snapshot: snapshot,
                filesRead: filesRead,
                bytesRead: bytesRead,
                processedBytesAdvanced: max(0, progress.processedBytes - startingProcessedBytes),
                invocationsAdded: invocationsAdded,
                hasMore: !sources.isEmpty && !progress.isComplete,
                wasDeferred: false,
                warnings: warnings
            ),
            snapshotGeneration: snapshotGeneration
        )
    }

    func loadLaunchSnapshot() throws -> SkillUsageSnapshot? {
        try loadLaunchEnvelope()?.snapshot
    }

    func saveLaunchSnapshot(
        _ snapshot: SkillUsageSnapshot,
        databaseGeneration: SkillUsageStoreGeneration
    ) throws {
        let cachePath = launchCachePath
        let lockPath = cachePath.appendingPathExtension("lock")
        let lockDescriptor = Darwin.open(
            lockPath.path,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard lockDescriptor >= 0 else {
            throw launchCacheError("open cache lock")
        }
        defer { close(lockDescriptor) }
        var lockInfo = stat()
        guard fstat(lockDescriptor, &lockInfo) == 0,
              lockInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              lockInfo.st_nlink == 1
        else {
            throw launchCacheError("validate cache lock")
        }
        guard fchmod(lockDescriptor, mode_t(0o600)) == 0 else {
            throw launchCacheError("protect cache lock")
        }
        guard flock(lockDescriptor, LOCK_EX) == 0 else {
            throw launchCacheError("lock cache")
        }
        defer { flock(lockDescriptor, LOCK_UN) }

        // A database can be replaced while an older process is waiting for the
        // sidecar lock. Only the still-current store and generation may publish.
        let currentGeneration = try currentLaunchGeneration()
        guard currentGeneration == databaseGeneration else { return }

        // Never regress the launch view to an older canonical snapshot, even if
        // wall time moves backward. A new store ID intentionally supersedes any
        // sidecar left by a database that occupied the same path.
        if let existing = try? loadLaunchEnvelope(),
           existing.storeID == databaseGeneration.storeID,
           existing.snapshotGeneration == databaseGeneration.sequence
        {
            return
        }

        let envelope = SkillUsageLaunchCacheEnvelope(
            formatVersion: skillUsageLaunchCacheFormatVersion,
            parserGeneration: skillUsageParserVersion,
            storeID: databaseGeneration.storeID,
            snapshotGeneration: databaseGeneration.sequence,
            generatedAt: Date(),
            snapshot: snapshot
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        let temporaryPath = cachePath.deletingLastPathComponent().appendingPathComponent(
            ".\(cachePath.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporaryPath) }

        // Create the unpublished temp as 0600 before writing any path-bearing
        // bytes. `rename` then makes the complete private file visible
        // atomically, so readers see the old generation or the new one.
        try writePrivateLaunchCacheData(data, to: temporaryPath)
        guard Darwin.rename(temporaryPath.path, cachePath.path) == 0 else {
            throw launchCacheError("replace cache")
        }
    }

    var launchCachePath: URL {
        path.deletingLastPathComponent().appendingPathComponent(
            "\(path.lastPathComponent)-launch-snapshot.json"
        )
    }

    func launchCacheOverlapsSessionRoots(_ roots: [String]) -> Bool {
        let cachePath = launchCachePath.standardizedFileURL.path
        return resolvedSessionRoots(roots).contains { root in
            let rootPath = root.standardizedFileURL.path
            return cachePath == rootPath || cachePath.hasPrefix(rootPath + "/")
        }
    }

    private func loadLaunchEnvelope() throws -> SkillUsageLaunchCacheEnvelope? {
        let cachePath = launchCachePath
        let descriptor = Darwin.open(cachePath.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw launchCacheError("inspect cache")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw launchCacheError("inspect open cache")
        }
        let fileType = info.st_mode & mode_t(S_IFMT)
        let permissions = info.st_mode & mode_t(0o777)
        guard fileType == mode_t(S_IFREG),
              permissions == mode_t(0o600),
              info.st_nlink == 1,
              info.st_size >= 0,
              info.st_size <= 64 * 1_024 * 1_024
        else {
            return nil
        }

        let data = try handle.readToEnd() ?? Data()
        let envelope = try JSONDecoder().decode(SkillUsageLaunchCacheEnvelope.self, from: data)
        guard envelope.formatVersion == skillUsageLaunchCacheFormatVersion,
              envelope.parserGeneration == skillUsageParserVersion,
              !envelope.storeID.isEmpty,
              envelope.snapshotGeneration >= 0,
              envelope.snapshot.targetParserVersion == envelope.parserGeneration
        else { return nil }
        return envelope
    }

    private func writePrivateLaunchCacheData(_ data: Data, to path: URL) throws {
        let descriptor = Darwin.open(
            path.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw launchCacheError("create private cache")
        }
        defer { close(descriptor) }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw launchCacheError("write private cache")
                }
                guard written > 0 else {
                    throw launchCacheError("write private cache")
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else {
            throw launchCacheError("flush private cache")
        }
    }

    private func launchCacheError(_ operation: String) -> NSError {
        NSError(domain: "MetagentSkillUsageLaunchCache", code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"
        ])
    }

    private func claimMaintenanceLease(minimumIntervalSeconds: TimeInterval) throws -> String? {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        let now = Date()
        try exec(db, "BEGIN IMMEDIATE;")
        do {
            let lastFinished = try scalarText(
                db,
                "SELECT value FROM \(skillUsageMetadataTable) WHERE key = 'maintenance_finished_at';"
            ).flatMap(MetagentCore.parseSkillUsageTimestamp)
            let leaseExpires = try scalarText(
                db,
                "SELECT value FROM \(skillUsageMetadataTable) WHERE key = 'maintenance_lease_expires_at';"
            ).flatMap(MetagentCore.parseSkillUsageTimestamp)
            if lastFinished.map({ now.timeIntervalSince($0) < minimumIntervalSeconds }) == true
                || leaseExpires.map({ $0 > now }) == true
            {
                try exec(db, "COMMIT;")
                return nil
            }
            let leaseID = UUID().uuidString.lowercased()
            try upsertMetadata(
                db,
                key: "maintenance_lease_expires_at",
                value: iso8601Formatter.string(from: now.addingTimeInterval(5 * 60))
            )
            try upsertMetadata(db, key: "maintenance_lease_id", value: leaseID)
            try exec(db, "COMMIT;")
            return leaseID
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    private func finishMaintenanceLease(id: String) throws {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        try exec(db, "BEGIN IMMEDIATE;")
        do {
            let currentLeaseID = try scalarText(
                db,
                "SELECT value FROM \(skillUsageMetadataTable) WHERE key = 'maintenance_lease_id';"
            )
            guard currentLeaseID == id else {
                try exec(db, "COMMIT;")
                return
            }
            try upsertMetadata(
                db,
                key: "maintenance_finished_at",
                value: iso8601Formatter.string(from: Date())
            )
            try exec(
                db,
                "DELETE FROM \(skillUsageMetadataTable) "
                    + "WHERE key IN ('maintenance_lease_expires_at', 'maintenance_lease_id');"
            )
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    func snapshot() throws -> SkillUsageSnapshot {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        try exec(db, "BEGIN;")
        do {
            let snapshot = try snapshot(db)
            try exec(db, "COMMIT;")
            return snapshot
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    private func snapshotAdvancingLaunchGeneration() throws -> (
        SkillUsageSnapshot,
        SkillUsageStoreGeneration
    ) {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        try exec(db, "BEGIN IMMEDIATE;")
        do {
            let current = try launchGeneration(db)
            guard current.sequence < Int64.max else {
                throw databaseError(db, "advance launch cache generation")
            }
            let generation = SkillUsageStoreGeneration(
                storeID: current.storeID,
                sequence: current.sequence + 1
            )
            var statement: OpaquePointer?
            try prepare(db, """
            UPDATE \(skillUsageStoreStateTable)
            SET launch_snapshot_generation = ?
            WHERE id = 1 AND store_id = ?;
            """, &statement)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, generation.sequence)
            bind(statement, 2, generation.storeID)
            guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                throw databaseError(db, "advance launch cache generation")
            }
            let snapshot = try snapshot(db)
            try exec(db, "COMMIT;")
            return (snapshot, generation)
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    private func snapshotWithCurrentLaunchGeneration() throws -> (
        SkillUsageSnapshot,
        SkillUsageStoreGeneration
    ) {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        try exec(db, "BEGIN;")
        do {
            let generation = try launchGeneration(db)
            let snapshot = try snapshot(db)
            try exec(db, "COMMIT;")
            return (snapshot, generation)
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    fileprivate func currentLaunchGeneration() throws -> SkillUsageStoreGeneration {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        return try launchGeneration(db)
    }

    private func launchGeneration(_ db: OpaquePointer?) throws -> SkillUsageStoreGeneration {
        var statement: OpaquePointer?
        try prepare(db, """
        SELECT store_id, launch_snapshot_generation
        FROM \(skillUsageStoreStateTable)
        WHERE id = 1;
        """, &statement)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw databaseError(db, "load launch cache generation")
        }
        return SkillUsageStoreGeneration(
            storeID: text(statement, 0),
            sequence: sqlite3_column_int64(statement, 1)
        )
    }

    /// Per-day read counts for every observed skill identity, grouped with the
    /// same local calendar the history store uses for its snapshots.
    ///
    /// The event log is the only store that already carries a timestamp on every
    /// row, so it is the one source history can reconstruct backwards rather
    /// than only accumulate forwards.
    func dailyCounts(calendar: Calendar) throws -> [SkillUsageDayCount] {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        let table = try previousGenerationExists(db)
            ? previousSkillUsageEventsTable
            : skillUsageEventsTable
        let sql = """
        SELECT
          CASE WHEN canonical_path != '' THEN canonical_path ELSE '' END,
          skill_id,
          occurred_at
        FROM \(table)
        WHERE trim(occurred_at) != ''
          AND julianday(occurred_at) IS NOT NULL
        ORDER BY occurred_at;
        """
        var statement: OpaquePointer?
        try prepare(db, sql, &statement)
        defer { sqlite3_finalize(statement) }
        var grouped: [SkillUsageDayKey: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let canonicalPath = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let skillID = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            guard let occurredAt = sqlite3_column_text(statement, 2).map({ String(cString: $0) }),
                  let date = MetagentCore.parseSkillUsageTimestamp(occurredAt)
            else { continue }
            let key = SkillUsageDayKey(
                canonicalPath: canonicalPath,
                skillID: skillID,
                day: historyDay(date, calendar: calendar)
            )
            grouped[key, default: 0] += 1
        }
        return grouped
            .map { key, count in
                SkillUsageDayCount(
                    canonicalPath: key.canonicalPath.isEmpty ? nil : key.canonicalPath,
                    skillID: key.skillID,
                    day: key.day,
                    count: count
                )
            }
            .sorted {
                ($0.day, $0.canonicalPath ?? "", $0.skillID)
                    < ($1.day, $1.canonicalPath ?? "", $1.skillID)
            }
    }

    func agentRunDurationStats(
        windowDays: Int,
        projectRoot: String?,
        now: Date
    ) throws -> AgentRunDurationStats {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)

        let hasPrevious = try previousGenerationExists(db)
        let previousRunsAreUsable = try tableExists(db, previousAgentRunsTable)
            && columnExists(db, table: previousAgentRunsTable, column: "run_kind")
        let previousCount = previousRunsAreUsable
            ? try scalarInt(db, "SELECT COUNT(*) FROM \(previousAgentRunsTable);")
            : 0
        let table = previousCount > 0 ? previousAgentRunsTable : agentRunsTable
        let normalizedRoot = projectRoot.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        let cutoff = iso8601Formatter.string(
            from: now.addingTimeInterval(-Double(max(1, windowDays)) * 86_400)
        )

        var statement: OpaquePointer?
        try prepare(db, """
        SELECT duration_ms, cwd
        FROM \(table)
        WHERE completed_at >= ?
          AND duration_ms >= 0
          AND run_kind = 'user'
        ORDER BY duration_ms;
        """, &statement)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, cutoff)

        var durations: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let cwd = text(statement, 1)
            if let root = normalizedRoot {
                guard cwd == root || cwd.hasPrefix(root + "/") else { continue }
            }
            durations.append(sqlite3_column_int64(statement, 0))
        }

        let metadata = try loadMetadata(db, table: skillUsageMetadataTable)
        let isComplete = previousCount > 0
            || (
                metadata["parser_version"] == String(skillUsageParserVersion)
                    && metadata["is_complete"] == "1"
                    && !hasPrevious
            )
        guard !durations.isEmpty else {
            return AgentRunDurationStats(
                windowDays: max(1, windowDays),
                runCount: 0,
                medianMilliseconds: 0,
                averageMilliseconds: 0,
                p90Milliseconds: 0,
                totalMilliseconds: 0,
                isBackfillComplete: isComplete
            )
        }
        let total = durations.reduce(Int64(0), +)
        let middle = durations.count / 2
        let median = durations.count.isMultiple(of: 2)
            ? (durations[middle - 1] + durations[middle]) / 2
            : durations[middle]
        let p90Index = max(0, Int(ceil(Double(durations.count) * 0.9)) - 1)
        return AgentRunDurationStats(
            windowDays: max(1, windowDays),
            runCount: durations.count,
            medianMilliseconds: median,
            averageMilliseconds: total / Int64(durations.count),
            p90Milliseconds: durations[p90Index],
            totalMilliseconds: total,
            isBackfillComplete: isComplete
        )
    }

    private func snapshot(_ db: OpaquePointer?) throws -> SkillUsageSnapshot {
        let metadata = try loadMetadata(db, table: skillUsageMetadataTable)
        let hasPreviousGeneration = try previousGenerationExists(db)
        let storedParserVersion = Int(metadata["parser_version"] ?? "")
        let isParserUpgradeBackfill = hasPreviousGeneration
            || (storedParserVersion != nil && storedParserVersion != skillUsageParserVersion)
        let summariesTable = hasPreviousGeneration
            ? previousSkillUsageEventsTable
            : skillUsageEventsTable
        let coverageTable = hasPreviousGeneration
            ? previousSkillUsageSourcesTable
            : skillUsageSourcesTable
        let displayMetadata = hasPreviousGeneration
            ? try loadMetadata(db, table: previousSkillUsageMetadataTable)
            : metadata

        // The window/grouping steps only need summary fields. Keep source
        // provenance out of their transient rows rather than copying and
        // sorting it for every historical event.
        let sql = """
        WITH normalized AS (
          SELECT
            skill_id, skill_name, canonical_path, scope, occurred_at,
            session_id, turn_id, evidence,
            rowid AS event_rowid,
            CASE
              WHEN skill_id LIKE 'plugin:%' THEN 'id:' || skill_id
              WHEN canonical_path != '' THEN 'path:' || canonical_path
              ELSE 'id:' || skill_id
            END AS aggregate_id
          FROM \(summariesTable)
        ), ranked AS (
          SELECT
            *,
            ROW_NUMBER() OVER (
              PARTITION BY aggregate_id
              ORDER BY occurred_at DESC, event_rowid DESC
            ) AS identity_rank
          FROM normalized
        ), identity_counts AS (
          SELECT skill_id, COUNT(DISTINCT aggregate_id) AS aggregate_count
          FROM normalized
          GROUP BY skill_id
        )
        SELECT
          CASE
            WHEN MAX(identity_counts.aggregate_count) > 1 THEN ranked.aggregate_id
            ELSE MAX(CASE WHEN identity_rank = 1 THEN ranked.skill_id END)
          END,
          MAX(CASE WHEN identity_rank = 1 THEN skill_name END),
          MAX(CASE WHEN identity_rank = 1 THEN NULLIF(canonical_path, '') END),
          MAX(CASE WHEN identity_rank = 1 THEN scope END),
          COUNT(*),
          SUM(CASE WHEN julianday(occurred_at) >= julianday('now', '-7 days') THEN 1 ELSE 0 END),
          SUM(CASE WHEN julianday(occurred_at) >= julianday('now', '-30 days') THEN 1 ELSE 0 END),
          COUNT(DISTINCT session_id || char(0) || turn_id),
          COUNT(DISTINCT session_id),
          COUNT(*) - COUNT(DISTINCT session_id || char(0) || turn_id),
          SUM(CASE WHEN evidence = 'otel' THEN 1 ELSE 0 END),
          SUM(CASE WHEN evidence != 'otel' THEN 1 ELSE 0 END),
          MIN(occurred_at),
          MAX(occurred_at)
        FROM ranked
        JOIN identity_counts USING (skill_id)
        GROUP BY aggregate_id
        ORDER BY COUNT(*) DESC, lower(MAX(CASE WHEN identity_rank = 1 THEN skill_name END)), aggregate_id;
        """
        var statement: OpaquePointer?
        try prepare(db, sql, &statement)
        defer { sqlite3_finalize(statement) }

        var summaries: [SkillUsageSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            summaries.append(SkillUsageSummary(
                id: text(statement, 0),
                skillName: text(statement, 1),
                canonicalPath: optionalText(statement, 2),
                scope: text(statement, 3),
                totalInvocations: Int(sqlite3_column_int64(statement, 4)),
                invocations7d: Int(sqlite3_column_int64(statement, 5)),
                invocations30d: Int(sqlite3_column_int64(statement, 6)),
                activeTurns: Int(sqlite3_column_int64(statement, 7)),
                distinctThreads: Int(sqlite3_column_int64(statement, 8)),
                repeatInvocations: Int(sqlite3_column_int64(statement, 9)),
                directInvocations: Int(sqlite3_column_int64(statement, 10)),
                inferredInvocations: Int(sqlite3_column_int64(statement, 11)),
                firstUsedAt: text(statement, 12),
                lastUsedAt: text(statement, 13)
            ))
        }

        return SkillUsageSnapshot(
            summaries: summaries,
            totalInvocations: summaries.reduce(0) { $0 + $1.totalInvocations },
            totalFiles: Int(metadata["total_files"] ?? "0") ?? 0,
            completedFiles: Int(metadata["completed_files"] ?? "0") ?? 0,
            totalBytes: Int64(metadata["total_bytes"] ?? "0") ?? 0,
            processedBytes: Int64(metadata["processed_bytes"] ?? "0") ?? 0,
            isBackfillComplete: metadata["is_complete"] == "1" && !isParserUpgradeBackfill,
            isParserUpgradeBackfill: isParserUpgradeBackfill,
            displayParserVersion: Int(displayMetadata["parser_version"] ?? ""),
            targetParserVersion: skillUsageParserVersion,
            coverageStartedAt: try scalarText(
                db,
                "SELECT MIN(NULLIF(coverage_started_at, '')) FROM \(coverageTable);"
            ),
            lastUpdatedAt: metadata["last_updated_at"]
        )
    }

    /// Reads the regular-file check, size, modification time, and stable
    /// identity from one metadata snapshot. Source discovery used to ask
    /// Foundation for size/time and then call `lstat` again for identity,
    /// doubling metadata syscalls for every retained session on every slice.
    private func sourceMetadata(path: String) -> UsageSourceMetadata? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            // Preserve Foundation enumeration semantics for the unusual case
            // of a symlinked JSONL entry. It normally reports `isRegularFile`
            // as false and excludes the link; if a file system admits it,
            // identify the directory entry so replacing the link resets its
            // cursor. Normal session files stay on the bulk-attribute path.
            let url = URL(fileURLWithPath: path)
            let keys: Set<URLResourceKey> = [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ]
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true
            else { return nil }
            return UsageSourceMetadata(
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                fileIdentity: fileIdentity(info)
            )
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return UsageSourceMetadata(
            size: Int64(info.st_size),
            modifiedAt: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000,
            fileIdentity: fileIdentity(info)
        )
    }

    private func fileIdentity(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
    }

    private func fileIdentity(device: dev_t, fileID: UInt64, createdAt: timespec) -> String {
        "\(device):\(fileID):\(createdAt.tv_sec):\(createdAt.tv_nsec)"
    }

    private func prefixFingerprint(path: String, maxBytes: Int = 8_192) -> String {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return ""
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: max(0, maxBytes))) ?? Data()
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(data.count):\(String(hash, radix: 16))"
    }

    private func fingerprintByteCount(_ fingerprint: String) -> Int? {
        guard let separator = fingerprint.firstIndex(of: ":") else { return nil }
        return Int(fingerprint[..<separator])
    }

    private func discoverSources(
        roots: [String],
        checkpoints: [String: UsageSourceCheckpoint],
        checkpointsByIdentity: [String: UsageSourceCheckpointRecord]
    ) -> [UsageSource] {
        let resolvedRoots = resolvedSessionRoots(roots)

        // Scanning both a parent and its child produces the same canonical
        // paths twice. Collapse overlapping configured roots up front so the
        // hot loop does not need to hash all retained file paths.
        var scanRoots: [URL] = []
        for root in resolvedRoots.sorted(by: { $0.path.count < $1.path.count }) {
            let rootPath = root.path
            guard !scanRoots.contains(where: {
                rootPath == $0.path
                    || (rootPath.hasPrefix($0.path + "/")
                        && parentTraversalCanReach(root, from: $0))
            }) else { continue }
            scanRoots.append(root)
        }

        var sources: [UsageSource] = []
        for root in scanRoots where fileManager.fileExists(atPath: root.path) {
            var rootSources: [UsageSource] = []
            if discoverSourcesWithBulkAttributes(
                in: root,
                checkpoints: checkpoints,
                checkpointsByIdentity: checkpointsByIdentity,
                sources: &rootSources
            ) {
                sources.append(contentsOf: rootSources)
                continue
            }

            // getattrlistbulk is macOS-specific and can be rejected by some
            // mounted file systems. Retain the portable Foundation path for
            // those roots instead of dropping their session history.
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
                let path = fileURL.path
                appendSource(
                    path: path,
                    metadata: sourceMetadata(path: path),
                    checkpoints: checkpoints,
                    checkpointsByIdentity: checkpointsByIdentity,
                    sources: &sources
                )
            }
        }
        return sources
    }

    private func resolvedSessionRoots(_ roots: [String]) -> [URL] {
        if roots.isEmpty {
            let codex = skillUsageCodexHomeURL()
            return [
                codex.appendingPathComponent("sessions"),
                codex.appendingPathComponent("archived_sessions")
            ]
        }
        return roots.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    private func materializeCatalogItems(
        _ items: [UsageSourceCatalogItem],
        checkpoints: [String: UsageSourceCheckpoint],
        checkpointsByIdentity: [String: UsageSourceCheckpointRecord]
    ) -> [UsageSource] {
        var sources: [UsageSource] = []
        sources.reserveCapacity(items.count)
        for item in items {
            appendSource(
                path: item.path,
                metadata: UsageSourceMetadata(
                    size: item.size,
                    modifiedAt: item.modifiedAt,
                    fileIdentity: item.fileIdentity
                ),
                checkpoints: checkpoints,
                checkpointsByIdentity: checkpointsByIdentity,
                sources: &sources
            )
        }
        return sources
    }

    /// A nested explicit root is redundant only when the parent walk can
    /// actually descend into it. Hidden and package directories are skipped by
    /// both discovery implementations, so roots beneath either must remain
    /// independently scannable.
    private func parentTraversalCanReach(_ nestedRoot: URL, from parentRoot: URL) -> Bool {
        let parentComponents = parentRoot.standardizedFileURL.pathComponents
        let nestedComponents = nestedRoot.standardizedFileURL.pathComponents
        guard nestedComponents.starts(with: parentComponents) else { return false }

        var candidate = parentRoot.standardizedFileURL
        let keys: Set<URLResourceKey> = [.isHiddenKey, .isPackageKey]
        for component in nestedComponents.dropFirst(parentComponents.count) {
            candidate.appendPathComponent(component, isDirectory: true)
            guard let values = try? candidate.resourceValues(forKeys: keys),
                  values.isHidden != true,
                  values.isPackage != true
            else { return false }
        }
        return true
    }

    /// Darwin can return the name, type, size, timestamps, and stable file ID
    /// for a directory batch in one syscall. Walking retained session trees
    /// this way removes one `lstat` syscall and Foundation URL normalization
    /// pass per JSONL file while preserving a complete foreground scan.
    private func discoverSourcesWithBulkAttributes(
        in directory: URL,
        checkpoints: [String: UsageSourceCheckpoint],
        checkpointsByIdentity: [String: UsageSourceCheckpointRecord],
        sources: inout [UsageSource]
    ) -> Bool {
        let directoryPath = directory.path
        let descriptor = Darwin.open(directoryPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        var commonAttributes = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        commonAttributes |= attrgroup_t(ATTR_CMN_NAME)
        commonAttributes |= attrgroup_t(ATTR_CMN_DEVID)
        commonAttributes |= attrgroup_t(ATTR_CMN_OBJTYPE)
        commonAttributes |= attrgroup_t(ATTR_CMN_CRTIME)
        commonAttributes |= attrgroup_t(ATTR_CMN_MODTIME)
        commonAttributes |= attrgroup_t(ATTR_CMN_FILEID)
        commonAttributes |= attrgroup_t(ATTR_CMN_ERROR)
        attributes.commonattr = commonAttributes
        attributes.fileattr = attrgroup_t(ATTR_FILE_TOTALSIZE)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)

        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                getattrlistbulk(
                    descriptor,
                    &attributes,
                    bytes.baseAddress,
                    bytes.count,
                    0
                )
            }
            guard count >= 0 else { return false }
            if count == 0 { return true }

            var entryOffset = 0
            for _ in 0..<count {
                guard entryOffset + MemoryLayout<UInt32>.size <= buffer.count else { return false }
                let parsed = buffer.withUnsafeBytes { bytes -> BulkDirectoryEntry? in
                    guard let base = bytes.baseAddress else { return nil }
                    let entryStart = base.advanced(by: entryOffset)
                    let length = Int(entryStart.loadUnaligned(as: UInt32.self))
                    guard length > 0, entryOffset + length <= bytes.count else { return nil }
                    let entryEnd = entryStart.advanced(by: length)
                    let fixedAttributeBytes = MemoryLayout<UInt32>.size
                        + MemoryLayout<attribute_set_t>.size
                        + MemoryLayout<UInt32>.size
                        + MemoryLayout<attrreference_t>.size
                        + MemoryLayout<dev_t>.size
                        + MemoryLayout<fsobj_type_t>.size
                        + (2 * MemoryLayout<timespec>.size)
                        + MemoryLayout<UInt64>.size
                    guard length >= fixedAttributeBytes else { return nil }
                    var field = entryStart.advanced(by: MemoryLayout<UInt32>.size)

                    let returned = field.loadUnaligned(as: attribute_set_t.self)
                    field = field.advanced(by: MemoryLayout<attribute_set_t>.size)
                    let requiredCommon = attrgroup_t(
                        ATTR_CMN_ERROR
                            | ATTR_CMN_NAME
                            | ATTR_CMN_DEVID
                            | ATTR_CMN_OBJTYPE
                            | ATTR_CMN_CRTIME
                            | ATTR_CMN_MODTIME
                            | ATTR_CMN_FILEID
                    )
                    guard returned.commonattr & requiredCommon == requiredCommon else { return nil }

                    // ATTR_CMN_ERROR is the one exception to numeric attribute
                    // order: getattrlistbulk places it directly after the
                    // returned-attribute set.
                    let entryError = field.loadUnaligned(as: UInt32.self)
                    field = field.advanced(by: MemoryLayout<UInt32>.size)

                    let nameReferenceAddress = field
                    let nameReference = field.loadUnaligned(as: attrreference_t.self)
                    field = field.advanced(by: MemoryLayout<attrreference_t>.size)
                    let nameAddress = nameReferenceAddress.advanced(by: Int(nameReference.attr_dataoffset))
                    let nameLength = Int(nameReference.attr_length)
                    guard nameReference.attr_dataoffset >= 0,
                          nameLength > 0,
                          nameAddress >= entryStart,
                          nameAddress.advanced(by: nameLength) <= entryEnd
                    else { return nil }
                    let nameBytes = UnsafeRawBufferPointer(start: nameAddress, count: nameLength - 1)
                    guard let name = String(bytes: nameBytes, encoding: .utf8) else { return nil }

                    let device = field.loadUnaligned(as: dev_t.self)
                    field = field.advanced(by: MemoryLayout<dev_t>.size)
                    let objectType = field.loadUnaligned(as: fsobj_type_t.self)
                    field = field.advanced(by: MemoryLayout<fsobj_type_t>.size)
                    let createdAt = field.loadUnaligned(as: timespec.self)
                    field = field.advanced(by: MemoryLayout<timespec>.size)
                    let modifiedAt = field.loadUnaligned(as: timespec.self)
                    field = field.advanced(by: MemoryLayout<timespec>.size)
                    let fileID = field.loadUnaligned(as: UInt64.self)
                    field = field.advanced(by: MemoryLayout<UInt64>.size)
                    let hasFileSize = returned.fileattr & attrgroup_t(ATTR_FILE_TOTALSIZE) != 0
                    let fileSizeEnd = UInt(bitPattern: field) + UInt(MemoryLayout<off_t>.size)
                    if hasFileSize, fileSizeEnd > UInt(bitPattern: entryEnd) {
                        return nil
                    }
                    let size = hasFileSize ? field.loadUnaligned(as: off_t.self) : 0

                    let regularFile = objectType == fsobj_type_t(VREG.rawValue)
                    guard !regularFile || hasFileSize else { return nil }

                    return BulkDirectoryEntry(
                        length: length,
                        name: name,
                        objectType: objectType,
                        size: Int64(size),
                        modifiedAt: TimeInterval(modifiedAt.tv_sec)
                            + TimeInterval(modifiedAt.tv_nsec) / 1_000_000_000,
                        fileIdentity: fileIdentity(
                            device: device,
                            fileID: fileID,
                            createdAt: createdAt
                        ),
                        error: entryError
                    )
                }
                guard let parsed else { return false }
                entryOffset += parsed.length
                guard parsed.error == 0,
                      parsed.name != ".",
                      parsed.name != "..",
                      !parsed.name.hasPrefix(".")
                else { continue }

                let isDirectory = parsed.objectType == fsobj_type_t(VDIR.rawValue)
                let entryPath = directoryPath + "/" + parsed.name
                if isDirectory {
                    let entryURL = URL(fileURLWithPath: entryPath, isDirectory: true)
                    let traversalKeys: Set<URLResourceKey> = [.isHiddenKey, .isPackageKey]
                    let traversalValues = try? entryURL.resourceValues(forKeys: traversalKeys)
                    if traversalValues?.isHidden != true,
                       traversalValues?.isPackage != true,
                       !discoverSourcesWithBulkAttributes(
                           in: entryURL,
                           checkpoints: checkpoints,
                           checkpointsByIdentity: checkpointsByIdentity,
                           sources: &sources
                       )
                    {
                        return false
                    }
                    continue
                }
                guard parsed.name.hasSuffix(".jsonl") else { continue }
                let path = entryPath
                let metadata = parsed.objectType == fsobj_type_t(VLNK.rawValue)
                    ? sourceMetadata(path: path)
                    : parsed.objectType == fsobj_type_t(VREG.rawValue)
                        ? UsageSourceMetadata(
                            size: parsed.size,
                            modifiedAt: parsed.modifiedAt,
                            fileIdentity: parsed.fileIdentity
                        )
                        : nil
                appendSource(
                    path: path,
                    metadata: metadata,
                    checkpoints: checkpoints,
                    checkpointsByIdentity: checkpointsByIdentity,
                    sources: &sources
                )
            }
        }
    }

    private struct BulkDirectoryEntry {
        let length: Int
        let name: String
        let objectType: fsobj_type_t
        let size: Int64
        let modifiedAt: Double
        let fileIdentity: String
        let error: UInt32
    }

    private func appendSource(
        path: String,
        metadata: UsageSourceMetadata?,
        checkpoints: [String: UsageSourceCheckpoint],
        checkpointsByIdentity: [String: UsageSourceCheckpointRecord],
        sources: inout [UsageSource]
    ) {
        guard let metadata else { return }
        let identityMatch = checkpointsByIdentity[metadata.fileIdentity]
        let existing = identityMatch?.path == path
            ? identityMatch?.checkpoint
            : checkpoints[path]
        let shouldCheckPrefix = existing.map {
            $0.modifiedAt != metadata.modifiedAt
                || $0.fileSize != metadata.size
                || (!$0.fileIdentity.isEmpty && $0.fileIdentity != metadata.fileIdentity)
        } ?? false
        sources.append(UsageSource(
            path: path,
            size: metadata.size,
            modifiedAt: metadata.modifiedAt,
            fileIdentity: metadata.fileIdentity,
            prefixFingerprint: shouldCheckPrefix
                ? prefixFingerprint(
                    path: path,
                    maxBytes: fingerprintByteCount(existing?.prefixFingerprint ?? "") ?? 8_192
                )
                : (existing?.prefixFingerprint ?? ""),
            checkpoint: existing
        ))
    }

    private func parse(
        source: UsageSource,
        state initialState: UsageSourceState,
        maxBytes: Int64,
        maxRecordBytes: Int64,
        throttleEveryBytes: Int64,
        throttleDelayMilliseconds: Int,
        throttleOffset: Int64,
        identityCache: inout [String: ParsedSkillIdentity]
    ) -> FileParseResult {
        guard let file = fopen(source.path, "r") else {
            return FileParseResult(
                state: initialState,
                events: [],
                runs: [],
                bytesRead: 0,
                reachedEnd: false,
                warning: "Could not read \(source.path)"
            )
        }
        defer { fclose(file) }
        guard fseeko(file, off_t(initialState.offset), SEEK_SET) == 0 else {
            return FileParseResult(
                state: initialState,
                events: [],
                runs: [],
                bytesRead: 0,
                reachedEnd: false,
                warning: "Could not seek \(source.path)"
            )
        }

        var state = initialState
        state.fileSize = source.size
        state.modifiedAt = source.modifiedAt
        state.fileIdentity = source.fileIdentity
        // Discovery already fingerprints changed sources so reset detection
        // and the saved cursor can usually reuse the same view of the file.
        // A file that grew beyond its old fingerprint still needs one read to
        // extend coverage to the normal 8 KiB prefix.
        let desiredFingerprintBytes = Int(min(Int64(8_192), max(0, source.size)))
        state.prefixFingerprint = fingerprintByteCount(source.prefixFingerprint)
            == desiredFingerprintBytes
            ? source.prefixFingerprint
            : prefixFingerprint(path: source.path)
        var events: [ParsedUsageEvent] = []
        var runs: [ParsedAgentRun] = []
        var warning: String?
        var bytesRead: Int64 = 0
        var nextThrottleAt = throttleEveryBytes > 0
            ? ((throttleOffset / throttleEveryBytes) + 1) * throttleEveryBytes
            : 0
        while true {
            let lineStart = Int64(ftello(file))
            let remainingLineBudget = maxBytes - bytesRead
            guard remainingLineBudget > 0 else { break }
            // The refresh byte limit is a soft scheduling boundary, not a
            // record-size limit. If a record does not fit at the end of this
            // slice, rewind it so the next slice can parse it whole. A record
            // at the start of a slice may exceed the slice to ensure progress.
            let lineReadLimit = bytesRead == 0
                ? maxRecordBytes
                : min(remainingLineBudget, maxRecordBytes)
            let read = readBoundedLine(file, maxBytes: lineReadLimit)
            guard let read else { break }
            if read.exceededLimit {
                if bytesRead > 0, remainingLineBudget < maxRecordBytes {
                    fseeko(file, off_t(lineStart), SEEK_SET)
                    state.offset = lineStart
                    break
                }
                if !read.isTerminated {
                    discardRemainderOfLine(file)
                }
                state.offset = Int64(ftello(file))
                bytesRead += max(0, state.offset - lineStart)
                warning = "Skipped oversized JSONL record in \(source.path) at byte \(lineStart)"
                break
            }
            let lineBytes = Int64(read.data.count)
            bytesRead += lineBytes
            if !read.isTerminated {
                fseeko(file, off_t(lineStart), SEEK_SET)
                state.offset = lineStart
                break
            }
            state.offset = Int64(ftello(file))
            parseLine(
                read.data,
                lineOffset: lineStart,
                sourcePath: source.path,
                state: &state,
                identityCache: &identityCache,
                events: &events,
                runs: &runs
            )
            if throttleEveryBytes > 0,
               throttleDelayMilliseconds > 0,
               throttleOffset + bytesRead >= nextThrottleAt
            {
                let crossedIntervals = ((throttleOffset + bytesRead - nextThrottleAt) / throttleEveryBytes) + 1
                Thread.sleep(
                    forTimeInterval: Double(throttleDelayMilliseconds) * Double(crossedIntervals) / 1_000
                )
                nextThrottleAt += throttleEveryBytes * crossedIntervals
            }
            if bytesRead >= maxBytes { break }
        }

        return FileParseResult(
            state: state,
            events: events,
            runs: runs,
            bytesRead: bytesRead,
            reachedEnd: state.offset >= source.size,
            warning: warning
        )
    }

    private func discardRemainderOfLine(_ file: UnsafeMutablePointer<FILE>) {
        var buffer = [CChar](repeating: 0, count: 64 * 1_024)
        while fgets(&buffer, Int32(buffer.count), file) != nil {
            let count = Int(strlen(buffer))
            if count > 0, buffer[count - 1] == 10 { break }
        }
    }

    private func readBoundedLine(
        _ file: UnsafeMutablePointer<FILE>,
        maxBytes: Int64
    ) -> (data: Data, isTerminated: Bool, exceededLimit: Bool)? {
        let bufferSize = 64 * 1_024
        var buffer = [CChar](repeating: 0, count: bufferSize)
        var data = Data()
        while true {
            guard fgets(&buffer, Int32(buffer.count), file) != nil else {
                return data.isEmpty ? nil : (data, false, false)
            }
            let count = Int(strlen(buffer))
            guard Int64(data.count + count) <= maxBytes else {
                return (Data(), count > 0 && buffer[count - 1] == 10, true)
            }
            data.append(buffer.withUnsafeBytes { Data($0.prefix(count)) })
            if count > 0, buffer[count - 1] == 10 {
                return (data, true, false)
            }
        }
    }

    private func parseLine(
        _ data: Data,
        lineOffset: Int64,
        sourcePath: String,
        state: inout UsageSourceState,
        identityCache: inout [String: ParsedSkillIdentity],
        events: inout [ParsedUsageEvent],
        runs: inout [ParsedAgentRun]
    ) {
        guard Self.containsUsageMarker(in: data) else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any]
        else { return }

        if type == "session_meta" {
            let sessionID = string(payload["id"] ?? payload["session_id"])
            state.sessionID = sessionID
            state.cwd = string(payload["cwd"])
            let timestamp = string(object["timestamp"] ?? payload["timestamp"])
            if !timestamp.isEmpty,
               state.coverageStartedAt.isEmpty || timestamp < state.coverageStartedAt
            {
                state.coverageStartedAt = timestamp
            }
            let sourceSessionID = rolloutSessionID(sourcePath)
            if state.runSessionID.isEmpty,
               sourceSessionID == nil || sourceSessionID == sessionID
            {
                state.runSessionID = sessionID
                state.runSessionStartedAt = timestamp
                state.runKind = agentRunKind(payload)
            }
            return
        }
        if type == "turn_context" {
            state.turnID = string(payload["turn_id"])
            let cwd = string(payload["cwd"])
            if !cwd.isEmpty { state.cwd = cwd }
            return
        }
        if type == "event_msg" {
            let eventType = string(payload["type"])
            guard eventType == "task_complete" else { return }
            let turnID = string(payload["turn_id"])
            guard !turnID.isEmpty,
                  !state.runSessionID.isEmpty,
                  let startedDate = unixTimestampDate(payload["started_at"]),
                  let completedDate = unixTimestampDate(payload["completed_at"]),
                  completedDate >= startedDate
            else { return }

            // Forked and subagent rollouts contain copied parent history whose
            // JSONL wrapper timestamps are rewritten to the fork time. The
            // payload timestamps retain the real task time. Only events that
            // began in this source session belong to this file; the originals
            // are retained in their own rollout and deduplicate by turn there.
            if let sessionStarted = MetagentCore.parseSkillUsageTimestamp(state.runSessionStartedAt) {
                // Payload epochs are often whole seconds while the session
                // timestamp includes fractions. Keep starts from the same
                // second, but reject everything from an earlier second.
                let sessionStartSecond = Date(
                    timeIntervalSince1970: floor(sessionStarted.timeIntervalSince1970)
                )
                if startedDate < sessionStartSecond { return }
            }

            let recordedDuration = int64(payload["duration_ms"])
            let derivedDuration = Int64((completedDate.timeIntervalSince(startedDate) * 1_000).rounded())
            let duration = recordedDuration ?? derivedDuration
            guard duration >= 0 else { return }
            runs.append(ParsedAgentRun(
                id: "\(state.runSessionID)\u{1F}\(turnID)",
                sessionID: state.runSessionID,
                turnID: turnID,
                cwd: state.cwd,
                startedAt: iso8601Formatter.string(from: startedDate),
                completedAt: iso8601Formatter.string(from: completedDate),
                durationMilliseconds: duration,
                kind: state.runKind,
                sourcePath: sourcePath
            ))
            return
        }
        guard type == "response_item", let itemType = payload["type"] as? String else { return }
        if ["custom_tool_call_output", "function_call_output", "local_shell_call_output"].contains(itemType) {
            let callID = string(payload["call_id"] ?? payload["id"])
            guard !callID.isEmpty, let pending = state.pendingEvents.removeValue(forKey: callID) else {
                return
            }
            let output = collectStrings(payload["output"] ?? payload["result"]).joined(separator: "\n")
            events.append(contentsOf: pending.filter { outputConfirmsRead($0, output: output) })
            return
        }
        guard ["custom_tool_call", "function_call", "local_shell_call"].contains(itemType) else {
            return
        }

        let toolName = string(payload["name"])
        guard isSupportedReadTool(name: toolName, itemType: itemType) else { return }

        let callID = string(payload["call_id"] ?? payload["id"])
        guard !callID.isEmpty else { return }
        if let metadata = payload["internal_chat_message_metadata_passthrough"] as? [String: Any] {
            let turnID = string(metadata["turn_id"])
            if !turnID.isEmpty { state.turnID = turnID }
        }
        var pending: [ParsedUsageEvent] = []
        for (commandIndex, command) in executedCommands(payload: payload, itemType: itemType).enumerated() {
            let executionCWD = commandExecutionCWD(command, sessionCWD: state.cwd)
            for (readIndex, rawPath) in extractExecutedSkillPaths(command.text).enumerated() {
                let resolvedPath = resolve(path: rawPath, cwd: executionCWD)
                let skill = identityCache[resolvedPath] ?? identify(path: resolvedPath)
                identityCache[resolvedPath] = skill
                let sessionID = state.sessionID.isEmpty ? sourcePath : state.sessionID
                let turnID = state.turnID.isEmpty ? "unknown" : state.turnID
                pending.append(ParsedUsageEvent(
                    id: "\(sessionID)\u{1F}\(callID)\u{1F}\(commandIndex)\u{1F}\(readIndex)\u{1F}\(skill.id)",
                    skill: skill,
                    occurredAt: string(object["timestamp"]),
                    sessionID: sessionID,
                    turnID: turnID,
                    cwd: executionCWD,
                    sourcePath: sourcePath,
                    callID: callID
                ))
            }
        }
        if !pending.isEmpty {
            state.pendingEvents[callID] = pending
        }
    }

    /// Most session records cannot affect usage or run timing. Inspect their
    /// UTF-8 bytes before allocating a Swift String or decoding JSON. Large
    /// retained histories contain millions of token and message records, so
    /// this cheap gate is the difference between an incremental index and a
    /// sustained CPU workload.
    private static func containsUsageMarker(in data: Data) -> Bool {
        usageMarkers.contains { data.range(of: $0) != nil }
    }

    private static let usageMarkers = [
        Data("session_meta".utf8),
        Data("turn_context".utf8),
        Data("task_complete".utf8),
        Data("tool_call_output".utf8),
        Data("function_call_output".utf8),
        Data("shell_call_output".utf8),
        Data("SKILL.md".utf8),
    ]

    private func outputConfirmsRead(_ event: ParsedUsageEvent, output: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: event.skill.confirmationName)
        let pattern = #"(?im)^.*\bname:\s*[\"']?"# + escaped + #"[\"']?\s*$"#
        if output.range(of: pattern, options: .regularExpression) != nil { return true }
        if output.range(of: #"(?im)^.*\bname:\s*[\"']?[^\r\n]+$"#, options: .regularExpression) != nil {
            return false
        }
        let substantiveLines = output.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "Output:" { return false }
            if trimmed.localizedCaseInsensitiveContains("Script completed") { return false }
            if trimmed.localizedCaseInsensitiveContains("Wall time") { return false }
            return true
        }
        guard let first = substantiveLines.first?.trimmingCharacters(in: .whitespaces) else {
            return false
        }
        let leadingFailure = #"(?i)^(?:Script failed|Rejected\(|Process exited with code\s+(?:-[0-9]+|[1-9][0-9]*)\b|(?:cat|sed|head|tail|bat|zsh|bash|sh):.*(?:No such file or directory|Permission denied|Operation not permitted|command not found|cannot open|can't open))"#
        return first.range(of: leadingFailure, options: .regularExpression) == nil
    }

    private func collectStrings(_ value: Any?) -> [String] {
        if let value = value as? String {
            if let data = value.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                let content = ["text", "output", "result", "content", "message"].flatMap {
                    collectStrings(object[$0])
                }
                if let failure = structuredFailureLine(object) { return [failure] + content }
                if !content.isEmpty { return content }
            }
            return [value]
        }
        if let values = value as? [Any] { return values.flatMap(collectStrings) }
        if let values = value as? [String: Any] {
            let content = ["text", "output", "result", "content", "message"].flatMap {
                collectStrings(values[$0])
            }
            if let failure = structuredFailureLine(values) { return [failure] + content }
            return content.isEmpty ? values.values.flatMap(collectStrings) : content
        }
        return []
    }

    private func structuredFailureLine(_ object: [String: Any]) -> String? {
        if let exitCode = (object["exit_code"] as? Int) ?? (object["exitCode"] as? Int),
           exitCode != 0
        {
            return "Process exited with code \(exitCode)"
        }
        if object["success"] as? Bool == false { return "Script failed" }
        guard let status = object["status"] as? String else { return nil }
        switch status.lowercased() {
        case "failed", "failure", "error", "rejected": return "Script failed"
        default: return nil
        }
    }

    private func isSupportedReadTool(name: String, itemType: String) -> Bool {
        if itemType == "local_shell_call" { return true }
        let normalized = name.lowercased()
        return normalized == "exec"
            || normalized.hasSuffix(".exec")
            || normalized == "exec_command"
            || normalized.hasSuffix(".exec_command")
            || normalized == "shell"
            || normalized == "shell_command"
            || normalized.hasSuffix(".shell_command")
    }

    private func executedCommands(payload: [String: Any], itemType: String) -> [ExecutedCommand] {
        if itemType == "local_shell_call" {
            let workdir = string(payload["workdir"] ?? payload["cwd"])
            return commandStrings(payload["command"] ?? payload["cmd"]).map {
                ExecutedCommand(text: $0, workdir: workdir.isEmpty ? nil : workdir)
            }
        }

        if let arguments = payload["arguments"] as? String,
           let data = arguments.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            return executedCommands(from: object)
        }
        if let arguments = payload["arguments"] as? [String: Any] {
            return executedCommands(from: arguments)
        }

        guard let input = payload["input"] as? String else { return [] }
        return extractJavaScriptExecCommands(input)
    }

    private func executedCommands(from object: [String: Any]) -> [ExecutedCommand] {
        let workdir = string(object["workdir"] ?? object["cwd"])
        return commandStrings(object["cmd"] ?? object["command"]).map {
            ExecutedCommand(text: $0, workdir: workdir.isEmpty ? nil : workdir)
        }
    }

    private func commandStrings(_ value: Any?) -> [String] {
        if let value = value as? String { return [value] }
        if let values = value as? [String] { return values }
        if let values = value as? [Any] {
            return values.compactMap { $0 as? String }
        }
        return []
    }

    private func extractJavaScriptValues(_ source: String, property: String) -> [String] {
        let characters = Array(source)
        var commands: [String] = []
        var index = 0
        while index < characters.count {
            if let next = skipJavaScriptNonCode(characters, from: index) {
                index = next
                continue
            }
            guard isIdentifierStart(characters[index]) else {
                index += 1
                continue
            }
            let start = index
            index += 1
            while index < characters.count, isIdentifierPart(characters[index]) { index += 1 }
            guard String(characters[start..<index]) == property else { continue }
            var cursor = index
            while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
            guard cursor < characters.count, characters[cursor] == ":" else { continue }
            cursor += 1
            while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
            guard cursor < characters.count,
                  characters[cursor] == "\"" || characters[cursor] == "'" || characters[cursor] == "`",
                  let parsed = parseJavaScriptString(characters, from: cursor)
            else { continue }
            if !parsed.value.contains("${") {
                commands.append(parsed.value)
            }
            index = parsed.nextIndex
        }
        return commands
    }

    private func extractJavaScriptExecCommands(_ source: String) -> [ExecutedCommand] {
        let characters = Array(source)
        let marker = Array("tools.exec_command")
        var results: [ExecutedCommand] = []
        var index = 0
        while index < characters.count {
            if let next = skipJavaScriptNonCode(characters, from: index) {
                index = next
                continue
            }
            let markerEnd = index + marker.count
            guard markerEnd <= characters.count,
                  Array(characters[index..<markerEnd]) == marker,
                  index == 0 || !isIdentifierPart(characters[index - 1])
            else {
                index += 1
                continue
            }
            var cursor = markerEnd
            while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
            guard cursor < characters.count, characters[cursor] == "(" else {
                index = markerEnd
                continue
            }
            let bodyStart = cursor + 1
            cursor = bodyStart
            var depth = 1
            while cursor < characters.count, depth > 0 {
                if characters[cursor] == "\"" || characters[cursor] == "'" || characters[cursor] == "`" {
                    cursor = skipJavaScriptString(characters, from: cursor)
                    continue
                }
                if characters[cursor] == "(" { depth += 1 }
                if characters[cursor] == ")" { depth -= 1 }
                cursor += 1
            }
            guard depth == 0 else { break }
            let body = String(characters[bodyStart..<(cursor - 1)])
            let workdir = extractJavaScriptValues(body, property: "workdir").first
            for command in extractJavaScriptValues(body, property: "cmd") {
                results.append(ExecutedCommand(text: command, workdir: workdir))
            }
            index = cursor
        }
        return results
    }

    private func commandExecutionCWD(_ command: ExecutedCommand, sessionCWD: String) -> String {
        if let workdir = command.workdir, !workdir.isEmpty {
            return resolve(path: workdir, cwd: sessionCWD)
        }
        let pattern = #"^\s*cd\s+(?:--\s+)?(\"[^\"]+\"|'[^']+'|[^;&|\s]+)\s*&&"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: command.text,
                range: NSRange(command.text.startIndex..<command.text.endIndex, in: command.text)
              ),
              let directoryRange = Range(match.range(at: 1), in: command.text)
        else { return sessionCWD }
        let directory = String(command.text[directoryRange])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .replacingOccurrences(of: #"\ "#, with: " ")
        return resolve(path: directory, cwd: sessionCWD)
    }

    /// Returns the index just past a comment or string literal starting at
    /// `index`, or nil when that position is ordinary code. Both JavaScript
    /// scanners use this to stay out of quoted and commented text.
    private func skipJavaScriptNonCode(_ characters: [Character], from index: Int) -> Int? {
        if characters[index] == "/", index + 1 < characters.count {
            if characters[index + 1] == "/" {
                var cursor = index + 2
                while cursor < characters.count, characters[cursor] != "\n" { cursor += 1 }
                return cursor
            }
            if characters[index + 1] == "*" {
                var cursor = index + 2
                while cursor + 1 < characters.count,
                      !(characters[cursor] == "*" && characters[cursor + 1] == "/")
                { cursor += 1 }
                return min(characters.count, cursor + 2)
            }
        }
        if characters[index] == "\"" || characters[index] == "'" || characters[index] == "`" {
            return skipJavaScriptString(characters, from: index)
        }
        return nil
    }

    private func skipJavaScriptString(_ characters: [Character], from start: Int) -> Int {
        parseJavaScriptString(characters, from: start)?.nextIndex ?? characters.count
    }

    private func parseJavaScriptString(
        _ characters: [Character],
        from start: Int
    ) -> (value: String, nextIndex: Int)? {
        guard start < characters.count else { return nil }
        let quote = characters[start]
        var index = start + 1
        var value = ""
        while index < characters.count {
            let character = characters[index]
            if character == quote {
                return (value, index + 1)
            }
            if character == "\\" {
                index += 1
                guard index < characters.count else { return nil }
                let escaped = characters[index]
                switch escaped {
                case "n": value.append("\n")
                case "r": value.append("\r")
                case "t": value.append("\t")
                case "\n": break
                default: value.append(escaped)
                }
                index += 1
                continue
            }
            value.append(character)
            index += 1
        }
        return nil
    }

    private func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character == "$" || character.isLetter
    }

    private func isIdentifierPart(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber
    }

    private func extractExecutedSkillPaths(_ command: String) -> [String] {
        let withoutHeredocs = removingHeredocBodies(command)
        guard !containsAmbiguousControlFlow(withoutHeredocs) else { return [] }
        return shellSegments(withoutHeredocs).flatMap { segment in
            guard isSupportedReadSegment(segment) else { return [String]() }
            return extractSkillPaths(removingOutputRedirections(segment))
        }
    }

    private func removingOutputRedirections(_ segment: String) -> String {
        segment.replacingOccurrences(
            of: #"(?:\d+|&)?>>?\s*(?:'[^']*'|\"[^\"]*\"|[^\s;&|]+)"#,
            with: " ",
            options: .regularExpression
        )
    }

    private func containsAmbiguousControlFlow(_ command: String) -> Bool {
        var unquoted = ""
        var quote: Character?
        var escaped = false
        var index = command.startIndex
        while index < command.endIndex {
            let character = command[index]
            let nextIndex = command.index(after: index)
            let next = nextIndex < command.endIndex ? command[nextIndex] : nil
            if escaped {
                unquoted.append(" ")
                escaped = false
            } else if character == "\\", quote != "'" {
                unquoted.append(" ")
                escaped = true
            } else if let activeQuote = quote {
                unquoted.append(character == "\n" ? "\n" : " ")
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
                unquoted.append(" ")
            } else if character == "|", next == "|" {
                return true
            } else {
                unquoted.append(character)
            }
            index = nextIndex
        }
        let pattern = #"(?i)(?:^|[^A-Za-z0-9_])(?:if|then|elif|else|fi|case|esac|for|while|until|select)\b"#
        return unquoted.range(of: pattern, options: .regularExpression) != nil
    }

    private func isSupportedReadSegment(_ segment: String) -> Bool {
        var value = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        let controlPrefix = #"^(?:(?:then|do|else)\s+)+"#
        value = value.replacingOccurrences(
            of: controlPrefix,
            with: "",
            options: .regularExpression
        )
        let pattern = #"^(?:(?:[A-Za-z_][A-Za-z0-9_]*=(?:'[^']*'|\"[^\"]*\"|[^\s]+))\s+)*(?:(?:command|builtin)\s+)?(?:/usr/bin/|/bin/)?(?:cat|sed|head|tail|bat)\b"#
        return value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func shellSegments(_ command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var index = command.startIndex

        func finishSegment() {
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { segments.append(value) }
            current = ""
        }

        while index < command.endIndex {
            let character = command[index]
            let nextIndex = command.index(after: index)
            let next = nextIndex < command.endIndex ? command[nextIndex] : nil
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", quote != "'" {
                current.append(character)
                escaped = true
            } else if let activeQuote = quote {
                current.append(character)
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "#", current.isEmpty || current.last?.isWhitespace == true {
                while index < command.endIndex, command[index] != "\n" {
                    index = command.index(after: index)
                }
                finishSegment()
                continue
            } else if character == "\n" || character == ";" || character == "|" || character == "&" {
                finishSegment()
                if (character == "|" || character == "&"), next == character {
                    index = nextIndex
                }
            } else {
                current.append(character)
            }
            index = command.index(after: index)
        }
        finishSegment()
        return segments
    }

    private func removingHeredocBodies(_ command: String) -> String {
        let lines = command.components(separatedBy: .newlines)
        var output: [String] = []
        var delimiters: [(value: String, stripsTabs: Bool)] = []
        for line in lines {
            if let delimiter = delimiters.first {
                let candidate = delimiter.stripsTabs
                    ? String(line.drop(while: { $0 == "\t" }))
                    : line
                if candidate == delimiter.value {
                    delimiters.removeFirst()
                }
                continue
            }
            output.append(line)
            delimiters.append(contentsOf: heredocDelimiters(in: line))
        }
        return output.joined(separator: "\n")
    }

    private func heredocDelimiters(in line: String) -> [(value: String, stripsTabs: Bool)] {
        let pattern = #"<<(-)?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return expression.matches(in: line, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 3), in: line) else { return nil }
            return (String(line[valueRange]), match.range(at: 1).location != NSNotFound)
        }
    }

    private func extractSkillPaths(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let patterns = [
            #"[\"']((?:file://)?(?:~|/|\.\.?/)[^\"'\r\n]*?/SKILL\.md)[\"']"#,
            #"((?:file://)?(?:~|/|\.\.?/)?(?:[A-Za-z0-9_@.+~:-]|\\ )+(?:/(?:[A-Za-z0-9_@.+~:-]|\\ )+)+/SKILL\.md)(?=$|[\s;&|<>()])"#
        ]
        var matches: [(location: Int, length: Int, path: String)] = []
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in expression.matches(in: text, range: range) {
                guard match.numberOfRanges > 1,
                      let matchRange = Range(match.range(at: 1), in: text)
                else { continue }
                matches.append((
                    location: match.range(at: 1).location,
                    length: match.range(at: 1).length,
                    path: String(text[matchRange])
                        .replacingOccurrences(of: "file://", with: "")
                        .replacingOccurrences(of: #"\ "#, with: " ")
                ))
            }
        }
        matches.sort {
            $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location
        }
        var seenRanges = Set<String>()
        return matches.compactMap { match in
            guard seenRanges.insert("\(match.location):\(match.length)").inserted else { return nil }
            return match.path
        }
    }

    private func resolve(path: String, cwd: String) -> String {
        let expanded: String
        if path.hasPrefix("~/") {
            expanded = homeURL().standardizedFileURL
                .appendingPathComponent(String(path.dropFirst(2))).path
        } else if path.hasPrefix("/") {
            expanded = path
        } else if !cwd.isEmpty {
            expanded = URL(fileURLWithPath: cwd).appendingPathComponent(path).path
        } else {
            expanded = path
        }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        if fileManager.fileExists(atPath: url.path) {
            return url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        return url.path
    }

    private func identify(path: String) -> ParsedSkillIdentity {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        let components = directory.pathComponents
        let folderName = directory.lastPathComponent
        let frontmatterName = readSkillName(url) ?? folderName

        if components.contains(".system") {
            return ParsedSkillIdentity(
                id: "system:\(frontmatterName)",
                name: frontmatterName,
                confirmationName: frontmatterName,
                canonicalPath: directory.path,
                scope: "system"
            )
        }

        if let skillsIndex = components.lastIndex(of: "skills"),
           components.prefix(skillsIndex).contains("plugins"),
           components.prefix(skillsIndex).contains("cache")
        {
            let marketplace = skillsIndex >= 3 ? components[skillsIndex - 3] : "unknown"
            let pluginName = skillsIndex >= 2 ? components[skillsIndex - 2] : "plugin"
            let pluginOwner = "\(MetagentCore.normalizedPluginMarketplace(marketplace))/\(pluginName)"
            return ParsedSkillIdentity(
                id: "plugin:\(pluginOwner):\(folderName)",
                name: "\(pluginName):\(frontmatterName)",
                confirmationName: frontmatterName,
                canonicalPath: directory.path,
                scope: "plugin"
            )
        }

        let codexSkills = skillUsageCodexHomeURL().appendingPathComponent("skills").standardizedFileURL
        if directory.deletingLastPathComponent().standardizedFileURL.path == codexSkills.path {
            return ParsedSkillIdentity(
                id: "global:codex:\(frontmatterName)",
                name: frontmatterName,
                confirmationName: frontmatterName,
                canonicalPath: directory.path,
                scope: "global"
            )
        }

        if let containerIndex = components.lastIndex(where: {
            agentDirectoryNames.contains($0)
        }),
           containerIndex + 1 < components.count,
           components[containerIndex + 1] == "skills"
        {
            let root = NSString.path(withComponents: Array(components[..<containerIndex]))
            let container = components[containerIndex]
            let identityName = container == ".agents"
                ? frontmatterName
                : "\(container.dropFirst()):\(frontmatterName)"
            if URL(fileURLWithPath: root).standardizedFileURL.path
                == homeURL().standardizedFileURL.path
            {
                return ParsedSkillIdentity(
                    id: "global:\(identityName)",
                    name: frontmatterName,
                    confirmationName: frontmatterName,
                    canonicalPath: directory.path,
                    scope: "global"
                )
            }
            return ParsedSkillIdentity(
                id: "project:\(root):\(identityName)",
                name: frontmatterName,
                confirmationName: frontmatterName,
                canonicalPath: directory.path,
                scope: "project"
            )
        }

        return ParsedSkillIdentity(
            id: "path:\(directory.path)",
            name: frontmatterName,
            confirmationName: frontmatterName,
            canonicalPath: directory.path,
            scope: "unknown"
        )
    }

    private func readSkillName(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 8_192)) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(40) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("name:") else { continue }
            return String(trimmed.dropFirst(5))
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
        }
        return nil
    }

    private func save(result: FileParseResult, source: UsageSource) throws -> Int {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        try exec(db, "BEGIN IMMEDIATE;")
        do {
            var added = 0
            for event in result.events {
                var statement: OpaquePointer?
                try prepare(db, """
                INSERT OR IGNORE INTO skill_usage_events (
                  event_id, skill_id, skill_name, canonical_path, scope,
                  occurred_at, session_id, turn_id, cwd, evidence,
                  invocation_kind, confidence, source_path, call_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'session_backfill', 'skill_file_read', 'observed', ?, ?);
                """, &statement)
                defer { sqlite3_finalize(statement) }
                bind(statement, 1, event.id)
                bind(statement, 2, event.skill.id)
                bind(statement, 3, event.skill.name)
                bind(statement, 4, event.skill.canonicalPath)
                bind(statement, 5, event.skill.scope)
                bind(statement, 6, event.occurredAt)
                bind(statement, 7, event.sessionID)
                bind(statement, 8, event.turnID)
                bind(statement, 9, event.cwd)
                bind(statement, 10, event.sourcePath)
                bind(statement, 11, event.callID)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw databaseError(db, "insert usage event")
                }
                if sqlite3_changes(db) > 0 { added += 1 }
            }

            for run in result.runs {
                var statement: OpaquePointer?
                try prepare(db, """
                INSERT OR IGNORE INTO agent_runs (
                  run_id, session_id, turn_id, cwd, started_at, completed_at,
                  duration_ms, run_kind, source_path
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """, &statement)
                defer { sqlite3_finalize(statement) }
                bind(statement, 1, run.id)
                bind(statement, 2, run.sessionID)
                bind(statement, 3, run.turnID)
                bind(statement, 4, run.cwd)
                bind(statement, 5, run.startedAt)
                bind(statement, 6, run.completedAt)
                sqlite3_bind_int64(statement, 7, run.durationMilliseconds)
                bind(statement, 8, run.kind)
                bind(statement, 9, run.sourcePath)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw databaseError(db, "insert agent run")
                }
            }

            var sourceStatement: OpaquePointer?
            try prepare(db, """
            INSERT INTO skill_usage_sources (
              path, byte_offset, file_size, modified_at, file_identity, prefix_fingerprint,
              session_id, cwd, turn_id, coverage_started_at, pending_events_json,
              run_session_id, run_session_started_at, run_kind, parser_version, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
            ON CONFLICT(path) DO UPDATE SET
              byte_offset = excluded.byte_offset,
              file_size = excluded.file_size,
              modified_at = excluded.modified_at,
              file_identity = excluded.file_identity,
              prefix_fingerprint = excluded.prefix_fingerprint,
              session_id = excluded.session_id,
              cwd = excluded.cwd,
              turn_id = excluded.turn_id,
              coverage_started_at = excluded.coverage_started_at,
              pending_events_json = excluded.pending_events_json,
              run_session_id = excluded.run_session_id,
              run_session_started_at = excluded.run_session_started_at,
              run_kind = excluded.run_kind,
              parser_version = excluded.parser_version,
              updated_at = excluded.updated_at;
            """, &sourceStatement)
            defer { sqlite3_finalize(sourceStatement) }
            bind(sourceStatement, 1, source.path)
            sqlite3_bind_int64(sourceStatement, 2, result.state.offset)
            sqlite3_bind_int64(sourceStatement, 3, source.size)
            sqlite3_bind_double(sourceStatement, 4, source.modifiedAt)
            bind(sourceStatement, 5, result.state.fileIdentity)
            bind(sourceStatement, 6, result.state.prefixFingerprint)
            bind(sourceStatement, 7, result.state.sessionID)
            bind(sourceStatement, 8, result.state.cwd)
            bind(sourceStatement, 9, result.state.turnID)
            bind(sourceStatement, 10, result.state.coverageStartedAt)
            let pendingData = try JSONEncoder().encode(result.state.pendingEvents)
            bind(sourceStatement, 11, String(decoding: pendingData, as: UTF8.self))
            bind(sourceStatement, 12, result.state.runSessionID)
            bind(sourceStatement, 13, result.state.runSessionStartedAt)
            bind(sourceStatement, 14, result.state.runKind)
            sqlite3_bind_int(sourceStatement, 15, Int32(skillUsageParserVersion))
            guard sqlite3_step(sourceStatement) == SQLITE_DONE else {
                throw databaseError(db, "save usage cursor")
            }
            try exec(db, "COMMIT;")
            return added
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    private func loadSourceCheckpoints() throws -> [String: UsageSourceCheckpoint] {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        var statement: OpaquePointer?
        try prepare(db, """
        SELECT path, byte_offset, file_size, modified_at, file_identity, prefix_fingerprint
        FROM skill_usage_sources
        WHERE parser_version = ?;
        """, &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(skillUsageParserVersion))
        var checkpoints: [String: UsageSourceCheckpoint] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            checkpoints[text(statement, 0)] = UsageSourceCheckpoint(
                offset: sqlite3_column_int64(statement, 1),
                fileSize: sqlite3_column_int64(statement, 2),
                modifiedAt: sqlite3_column_double(statement, 3),
                fileIdentity: text(statement, 4),
                prefixFingerprint: text(statement, 5)
            )
        }
        return checkpoints
    }

    private func indexCheckpointsByIdentity(
        _ checkpoints: [String: UsageSourceCheckpoint]
    ) -> [String: UsageSourceCheckpointRecord] {
        var unique: [String: UsageSourceCheckpointRecord] = [:]
        var ambiguous: Set<String> = []
        for (path, checkpoint) in checkpoints where !checkpoint.fileIdentity.isEmpty {
            let identity = checkpoint.fileIdentity
            guard !ambiguous.contains(identity) else { continue }
            if unique.removeValue(forKey: identity) != nil {
                ambiguous.insert(identity)
                continue
            }
            unique[identity] = UsageSourceCheckpointRecord(path: path, checkpoint: checkpoint)
        }
        return unique
    }

    private func loadSourceState(path: String) throws -> UsageSourceState? {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        var statement: OpaquePointer?
        try prepare(db, """
        SELECT byte_offset, file_size, modified_at, file_identity, prefix_fingerprint,
               session_id, cwd, turn_id, coverage_started_at, pending_events_json,
               run_session_id, run_session_started_at, run_kind
        FROM skill_usage_sources
        WHERE path = ? AND parser_version = ?;
        """, &statement)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, path)
        sqlite3_bind_int(statement, 2, Int32(skillUsageParserVersion))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let pendingJSON = text(statement, 9)
        let pendingEvents: [String: [ParsedUsageEvent]] = if pendingJSON == "{}" || pendingJSON.isEmpty {
            [:]
        } else {
            pendingJSON.data(using: .utf8).flatMap {
                try? JSONDecoder().decode([String: [ParsedUsageEvent]].self, from: $0)
            } ?? [:]
        }
        return UsageSourceState(
            offset: sqlite3_column_int64(statement, 0),
            fileSize: sqlite3_column_int64(statement, 1),
            modifiedAt: sqlite3_column_double(statement, 2),
            fileIdentity: text(statement, 3),
            prefixFingerprint: text(statement, 4),
            sessionID: text(statement, 5),
            cwd: text(statement, 6),
            turnID: text(statement, 7),
            coverageStartedAt: text(statement, 8),
            pendingEvents: pendingEvents,
            runSessionID: text(statement, 10),
            runSessionStartedAt: text(statement, 11),
            runKind: text(statement, 12)
        )
    }

    private func migrateSource(
        from oldPath: String,
        to newPath: String,
        state: UsageSourceState
    ) throws {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        try exec(db, "BEGIN IMMEDIATE;")
        do {
            var eventStatement: OpaquePointer?
            try prepare(db, "UPDATE skill_usage_events SET source_path = ? WHERE source_path = ?;", &eventStatement)
            defer { sqlite3_finalize(eventStatement) }
            bind(eventStatement, 1, newPath)
            bind(eventStatement, 2, oldPath)
            guard sqlite3_step(eventStatement) == SQLITE_DONE else {
                throw databaseError(db, "migrate usage events")
            }

            var runStatement: OpaquePointer?
            try prepare(db, "UPDATE agent_runs SET source_path = ? WHERE source_path = ?;", &runStatement)
            defer { sqlite3_finalize(runStatement) }
            bind(runStatement, 1, newPath)
            bind(runStatement, 2, oldPath)
            guard sqlite3_step(runStatement) == SQLITE_DONE else {
                throw databaseError(db, "migrate agent runs")
            }

            let pendingData = try JSONEncoder().encode(state.pendingEvents)
            var sourceStatement: OpaquePointer?
            try prepare(db, """
            UPDATE skill_usage_sources
            SET path = ?, pending_events_json = ?, updated_at = datetime('now')
            WHERE path = ?;
            """, &sourceStatement)
            defer { sqlite3_finalize(sourceStatement) }
            bind(sourceStatement, 1, newPath)
            bind(sourceStatement, 2, String(decoding: pendingData, as: UTF8.self))
            bind(sourceStatement, 3, oldPath)
            guard sqlite3_step(sourceStatement) == SQLITE_DONE else {
                throw databaseError(db, "migrate usage cursor")
            }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    private func resetSources(_ paths: [String]) throws {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        try exec(db, "BEGIN IMMEDIATE;")
        do {
            var eventStatement: OpaquePointer?
            try prepare(db, "DELETE FROM skill_usage_events WHERE source_path = ?;", &eventStatement)
            defer { sqlite3_finalize(eventStatement) }
            var sourceStatement: OpaquePointer?
            try prepare(db, "DELETE FROM skill_usage_sources WHERE path = ?;", &sourceStatement)
            defer { sqlite3_finalize(sourceStatement) }
            var runStatement: OpaquePointer?
            try prepare(db, "DELETE FROM agent_runs WHERE source_path = ?;", &runStatement)
            defer { sqlite3_finalize(runStatement) }

            for path in paths {
                sqlite3_reset(eventStatement)
                sqlite3_clear_bindings(eventStatement)
                bind(eventStatement, 1, path)
                guard sqlite3_step(eventStatement) == SQLITE_DONE else {
                    throw databaseError(db, "reset usage events")
                }

                sqlite3_reset(sourceStatement)
                sqlite3_clear_bindings(sourceStatement)
                bind(sourceStatement, 1, path)
                guard sqlite3_step(sourceStatement) == SQLITE_DONE else {
                    throw databaseError(db, "reset usage cursor")
                }

                sqlite3_reset(runStatement)
                sqlite3_clear_bindings(runStatement)
                bind(runStatement, 1, path)
                guard sqlite3_step(runStatement) == SQLITE_DONE else {
                    throw databaseError(db, "reset agent runs")
                }
            }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    private func progress(
        for sources: [UsageSource]
    ) -> (totalFiles: Int, completedFiles: Int, totalBytes: Int64, processedBytes: Int64, isComplete: Bool) {
        var totalBytes: Int64 = 0
        var processedBytes: Int64 = 0
        var completedFiles = 0
        for source in sources {
            totalBytes += source.size
            let offset = source.checkpoint?.offset ?? 0
            processedBytes += min(offset, source.size)
            if offset >= source.size { completedFiles += 1 }
        }
        return (
            totalFiles: sources.count,
            completedFiles: completedFiles,
            totalBytes: totalBytes,
            processedBytes: processedBytes,
            isComplete: !sources.isEmpty && completedFiles == sources.count
        )
    }

    private func processedBytes(
        for sources: [UsageSource]
    ) -> Int64 {
        sources.reduce(Int64(0)) { total, source in
            total + min(source.checkpoint?.offset ?? 0, source.size)
        }
    }

    private func saveProgress(
        _ progress: (totalFiles: Int, completedFiles: Int, totalBytes: Int64, processedBytes: Int64, isComplete: Bool),
        force: Bool
    ) throws {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        var values = [
            "total_files": String(progress.totalFiles),
            "completed_files": String(progress.completedFiles),
            "total_bytes": String(progress.totalBytes),
            "processed_bytes": String(progress.processedBytes),
            "is_complete": progress.isComplete ? "1" : "0"
        ]
        if !force {
            let metadata = try loadMetadata(db, table: skillUsageMetadataTable)
            if values.allSatisfy({ metadata[$0.key] == $0.value }) { return }
        }
        values["last_updated_at"] = iso8601Formatter.string(from: Date())
        try exec(db, "BEGIN IMMEDIATE;")
        do {
            for (key, value) in values {
                var statement: OpaquePointer?
                try prepare(db, """
                INSERT INTO skill_usage_metadata (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                """, &statement)
                defer { sqlite3_finalize(statement) }
                bind(statement, 1, key)
                bind(statement, 2, value)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw databaseError(db, "save usage metadata")
                }
            }
            if progress.isComplete {
                try dropPreviousGeneration(db)
            }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    @discardableResult
    private func prepareParserVersion() throws -> Bool {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        let current = try scalarText(
            db,
            "SELECT value FROM skill_usage_metadata WHERE key = 'parser_version';"
        )
        guard current != String(skillUsageParserVersion) else { return false }
        try exec(db, "BEGIN IMMEDIATE;")
        do {
            if try previousGenerationExists(db) {
                try dropCurrentGeneration(db)
            } else if try currentGenerationHasHistory(db) {
                try preserveCurrentGeneration(db)
            } else {
                try dropCurrentGeneration(db)
            }
            try createSchema(db)
            var statement: OpaquePointer?
            try prepare(db, """
            INSERT INTO skill_usage_metadata (key, value) VALUES ('parser_version', ?);
            """, &statement)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, String(skillUsageParserVersion))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw databaseError(db, "save parser version")
            }
            try exec(db, "COMMIT;")
            return true
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    private func currentGenerationHasHistory(_ db: OpaquePointer?) throws -> Bool {
        let events = try scalarInt(db, "SELECT COUNT(*) FROM \(skillUsageEventsTable);")
        let sources = try scalarInt(db, "SELECT COUNT(*) FROM \(skillUsageSourcesTable);")
        return events > 0 || sources > 0
    }

    private func previousGenerationExists(_ db: OpaquePointer?) throws -> Bool {
        try tableExists(db, previousSkillUsageEventsTable)
            && tableExists(db, previousSkillUsageSourcesTable)
            && tableExists(db, previousSkillUsageMetadataTable)
    }

    private func preserveCurrentGeneration(_ db: OpaquePointer?) throws {
        try exec(db, "DROP INDEX IF EXISTS skill_usage_by_skill_time;")
        try exec(db, "DROP INDEX IF EXISTS skill_usage_by_session_turn;")
        try exec(db, "DROP INDEX IF EXISTS agent_runs_by_completed_at;")
        // Agent runs were added after the three core usage tables. A failed
        // development migration can therefore leave an orphan with this name
        // even though no complete previous generation exists.
        try exec(db, "DROP TABLE IF EXISTS \(previousAgentRunsTable);")
        try exec(db, "ALTER TABLE \(skillUsageEventsTable) RENAME TO \(previousSkillUsageEventsTable);")
        try exec(db, "ALTER TABLE \(skillUsageSourcesTable) RENAME TO \(previousSkillUsageSourcesTable);")
        try exec(db, "ALTER TABLE \(skillUsageMetadataTable) RENAME TO \(previousSkillUsageMetadataTable);")
        try exec(db, "ALTER TABLE \(agentRunsTable) RENAME TO \(previousAgentRunsTable);")
        try exec(db, """
        CREATE INDEX IF NOT EXISTS skill_usage_previous_by_skill_time
          ON \(previousSkillUsageEventsTable)(skill_id, occurred_at);
        CREATE INDEX IF NOT EXISTS skill_usage_previous_by_session_turn
          ON \(previousSkillUsageEventsTable)(session_id, turn_id);
        CREATE INDEX IF NOT EXISTS agent_runs_previous_by_completed_at
          ON \(previousAgentRunsTable)(completed_at);
        """)
    }

    private func dropCurrentGeneration(_ db: OpaquePointer?) throws {
        try exec(db, "DROP TABLE IF EXISTS \(skillUsageEventsTable);")
        try exec(db, "DROP TABLE IF EXISTS \(skillUsageSourcesTable);")
        try exec(db, "DROP TABLE IF EXISTS \(skillUsageMetadataTable);")
        try exec(db, "DROP TABLE IF EXISTS \(agentRunsTable);")
    }

    private func dropPreviousGeneration(_ db: OpaquePointer?) throws {
        try exec(db, "DROP TABLE IF EXISTS \(previousSkillUsageEventsTable);")
        try exec(db, "DROP TABLE IF EXISTS \(previousSkillUsageSourcesTable);")
        try exec(db, "DROP TABLE IF EXISTS \(previousSkillUsageMetadataTable);")
        try exec(db, "DROP TABLE IF EXISTS \(previousAgentRunsTable);")
    }

    private func open(_ db: inout OpaquePointer?) throws {
        guard sqlite3_open(path.path, &db) == SQLITE_OK else {
            throw databaseError(db, "open \(path.path)")
        }
        try exec(db, "PRAGMA journal_mode=WAL;")
        try exec(db, "PRAGMA synchronous=NORMAL;")
        try exec(db, "PRAGMA busy_timeout=2500;")
        // Snapshot aggregation uses window functions and DISTINCT grouping.
        // Keep those transient sort tables in memory rather than spilling tens
        // of megabytes to disk on every read; persistent usage data remains in
        // the WAL-backed database above.
        try exec(db, "PRAGMA temp_store=MEMORY;")
    }

    private func createSchema(_ db: OpaquePointer?) throws {
        try exec(db, """
        CREATE TABLE IF NOT EXISTS skill_usage_events (
          event_id TEXT PRIMARY KEY,
          skill_id TEXT NOT NULL,
          skill_name TEXT NOT NULL,
          canonical_path TEXT NOT NULL,
          scope TEXT NOT NULL,
          occurred_at TEXT NOT NULL,
          session_id TEXT NOT NULL,
          turn_id TEXT NOT NULL,
          cwd TEXT NOT NULL,
          evidence TEXT NOT NULL,
          invocation_kind TEXT NOT NULL,
          confidence TEXT NOT NULL,
          source_path TEXT NOT NULL,
          call_id TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS skill_usage_by_skill_time
          ON skill_usage_events(skill_id, occurred_at);
        CREATE INDEX IF NOT EXISTS skill_usage_by_session_turn
          ON skill_usage_events(session_id, turn_id);
        CREATE TABLE IF NOT EXISTS agent_runs (
          run_id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL,
          turn_id TEXT NOT NULL,
          cwd TEXT NOT NULL,
          started_at TEXT NOT NULL,
          completed_at TEXT NOT NULL,
          duration_ms INTEGER NOT NULL,
          run_kind TEXT NOT NULL,
          source_path TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS agent_runs_by_completed_at
          ON agent_runs(completed_at);
        CREATE TABLE IF NOT EXISTS skill_usage_sources (
          path TEXT PRIMARY KEY,
          byte_offset INTEGER NOT NULL,
          file_size INTEGER NOT NULL,
          modified_at REAL NOT NULL,
          file_identity TEXT NOT NULL DEFAULT '',
          prefix_fingerprint TEXT NOT NULL DEFAULT '',
          session_id TEXT NOT NULL,
          cwd TEXT NOT NULL,
          turn_id TEXT NOT NULL,
          coverage_started_at TEXT NOT NULL DEFAULT '',
          pending_events_json TEXT NOT NULL DEFAULT '{}',
          run_session_id TEXT NOT NULL DEFAULT '',
          run_session_started_at TEXT NOT NULL DEFAULT '',
          run_kind TEXT NOT NULL DEFAULT 'unknown',
          parser_version INTEGER NOT NULL,
          updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS skill_usage_metadata (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS skill_usage_store_state (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          store_id TEXT NOT NULL,
          launch_snapshot_generation INTEGER NOT NULL
        );
        INSERT OR IGNORE INTO skill_usage_store_state (
          id, store_id, launch_snapshot_generation
        ) VALUES (
          1, lower(hex(randomblob(16))), 0
        );
        """)
        try? exec(db, "ALTER TABLE skill_usage_sources ADD COLUMN file_identity TEXT NOT NULL DEFAULT '';" )
        try? exec(db, "ALTER TABLE skill_usage_sources ADD COLUMN prefix_fingerprint TEXT NOT NULL DEFAULT '';" )
        try? exec(db, "ALTER TABLE skill_usage_sources ADD COLUMN pending_events_json TEXT NOT NULL DEFAULT '{}';" )
        try? exec(db, "ALTER TABLE skill_usage_sources ADD COLUMN run_session_id TEXT NOT NULL DEFAULT '';" )
        try? exec(db, "ALTER TABLE skill_usage_sources ADD COLUMN run_session_started_at TEXT NOT NULL DEFAULT '';" )
        try? exec(db, "ALTER TABLE skill_usage_sources ADD COLUMN run_kind TEXT NOT NULL DEFAULT 'unknown';" )
        try? exec(db, "ALTER TABLE skill_usage_sources ADD COLUMN coverage_started_at TEXT NOT NULL DEFAULT '';" )
    }

    private func loadMetadata(
        _ db: OpaquePointer?,
        table: String
    ) throws -> [String: String] {
        var statement: OpaquePointer?
        try prepare(db, "SELECT key, value FROM \(table);", &statement)
        defer { sqlite3_finalize(statement) }
        var values: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            values[text(statement, 0)] = text(statement, 1)
        }
        return values
    }

    private func upsertMetadata(
        _ db: OpaquePointer?,
        key: String,
        value: String
    ) throws {
        var statement: OpaquePointer?
        try prepare(db, """
        INSERT INTO \(skillUsageMetadataTable) (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """, &statement)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, key)
        bind(statement, 2, value)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(db, "save usage metadata")
        }
    }

    private func scalarText(_ db: OpaquePointer?, _ sql: String) throws -> String? {
        var statement: OpaquePointer?
        try prepare(db, sql, &statement)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return optionalText(statement, 0)
    }

    private func scalarInt(_ db: OpaquePointer?, _ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        try prepare(db, sql, &statement)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    private func tableExists(_ db: OpaquePointer?, _ table: String) throws -> Bool {
        var statement: OpaquePointer?
        try prepare(
            db,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;",
            &statement
        )
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, table)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func columnExists(
        _ db: OpaquePointer?,
        table: String,
        column: String
    ) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if text(statement, 1) == column { return true }
        }
        return false
    }

    private func prepare(_ db: OpaquePointer?, _ sql: String, _ statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError(db, "prepare statement")
        }
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw databaseError(db, "execute statement")
        }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func optionalText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let value = text(statement, index)
        return value.isEmpty ? nil : value
    }

    private func string(_ value: Any?) -> String {
        value as? String ?? ""
    }

    private func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let value = value as? String {
            return Int64(value)
        }
        return nil
    }

    private func unixTimestampDate(_ value: Any?) -> Date? {
        let seconds: Double?
        if let number = value as? NSNumber {
            seconds = number.doubleValue
        } else if let value = value as? String {
            seconds = Double(value)
        } else {
            seconds = nil
        }
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1_000 : seconds)
    }

    private func rolloutSessionID(_ sourcePath: String) -> String? {
        let filename = URL(fileURLWithPath: sourcePath)
            .deletingPathExtension()
            .lastPathComponent
        guard filename.count >= 36 else { return nil }
        let candidate = String(filename.suffix(36))
        return UUID(uuidString: candidate) == nil ? nil : candidate
    }

    private func agentRunKind(_ session: [String: Any]) -> String {
        func hasJSONValue(_ value: Any?) -> Bool {
            value != nil && !(value is NSNull)
        }

        switch string(session["thread_source"]) {
        case "user":
            return "user"
        case "automation":
            return "automation"
        case "guardian_review":
            return "guardian"
        case "subagent":
            return "subagent"
        default:
            if hasJSONValue(session["agent_path"])
                || hasJSONValue(session["parent_thread_id"])
                || hasJSONValue(session["forked_from_id"])
                || hasJSONValue((session["source"] as? [String: Any])?["subagent"])
            {
                return "subagent"
            }
            return "unknown"
        }
    }

    private func databaseError(_ db: OpaquePointer?, _ operation: String) -> Error {
        let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
        return NSError(domain: "MetagentSkillUsage", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "\(operation): \(detail)"
        ])
    }
}
