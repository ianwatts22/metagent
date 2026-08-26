import Foundation

/// A Metagent-authored finding about a skill. Advisories are distinct from
/// evaluator deductions: they carry management context Metagent itself
/// observes, they never claim the skill content is defective, and each one
/// states how it clears. Advisories never change Quality or Utility scores.
public struct SkillAdvisory: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let category: String
    public let severity: String
    public let message: String
    public let remediation: [String]
    /// Human-readable statement of what clears the advisory.
    public let clearance: String

    public init(
        id: String,
        category: String,
        severity: String,
        message: String,
        remediation: [String],
        clearance: String
    ) {
        self.id = id
        self.category = category
        self.severity = severity
        self.message = message
        self.remediation = remediation
        self.clearance = clearance
    }
}

/// One significant model release from a tracked provider, as recorded by
/// models.dev. Only text-output models that are not size or modality variants
/// are kept; the point of the catalog is "the frontier moved", not "an API id
/// appeared".
public struct ModelRelease: Codable, Equatable, Sendable, Identifiable {
    public let provider: String
    public let providerName: String
    public let modelID: String
    public let modelName: String
    /// Calendar date string from models.dev, `yyyy-MM-dd`, midnight UTC.
    public let releaseDate: Date

    public var id: String { "\(provider)/\(modelID)" }

    public init(provider: String, providerName: String, modelID: String, modelName: String, releaseDate: Date) {
        self.provider = provider
        self.providerName = providerName
        self.modelID = modelID
        self.modelName = modelName
        self.releaseDate = releaseDate
    }
}

/// The newest significant release event for one tracked provider, compared
/// with the best review evidence available for a skill. Keeping this
/// structured lets the table render provider badges without parsing advisory
/// prose, and makes an unknown baseline distinct from a current skill.
public struct ModelReviewTarget: Codable, Equatable, Sendable, Identifiable {
    public let provider: String
    public let providerName: String
    public let modelIDs: [String]
    public let modelNames: [String]
    public let releaseDate: Date
    public let baselineDate: Date?

    public var id: String { provider }
    public var needsReview: Bool {
        baselineDate.map { $0 < releaseDate } ?? false
    }
    public var isUnknown: Bool { baselineDate == nil }
    public var modelLabel: String {
        let shown = modelNames.prefix(2).joined(separator: ", ")
        let suffix = modelNames.count > 2 ? " +\(modelNames.count - 2) more" : ""
        return shown + suffix
    }

    public init(
        provider: String,
        providerName: String,
        modelIDs: [String],
        modelNames: [String],
        releaseDate: Date,
        baselineDate: Date?
    ) {
        self.provider = provider
        self.providerName = providerName
        self.modelIDs = modelIDs
        self.modelNames = modelNames
        self.releaseDate = releaseDate
        self.baselineDate = baselineDate
    }
}

public struct ModelReleaseSnapshot: Codable, Equatable, Sendable {
    public static let version = 1

    public let version: Int
    public let fetchedAt: Date?
    public let releases: [ModelRelease]

    public init(fetchedAt: Date?, releases: [ModelRelease]) {
        self.version = Self.version
        self.fetchedAt = fetchedAt
        self.releases = releases
    }

    public static let empty = ModelReleaseSnapshot(fetchedAt: nil, releases: [])

    public func isStale(maxAge: TimeInterval, now: Date = Date()) -> Bool {
        guard let fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) > maxAge
    }
}

extension MetagentCore {
    public static let modelReleaseSourceURL = URL(string: "https://models.dev/api.json")!
    public static let defaultTrackedModelProviders = ["anthropic", "openai"]

    /// Providers offered in Settings, in display order. Keys are models.dev
    /// provider ids; gateways and resellers are deliberately absent because
    /// they re-list other providers' models.
    public static let selectableModelProviders: [(key: String, name: String)] = [
        ("anthropic", "Anthropic"),
        ("openai", "OpenAI"),
        ("google", "Google"),
        ("xai", "xAI (Grok)"),
        ("deepseek", "DeepSeek"),
        ("alibaba", "Alibaba (Qwen)"),
        ("meta", "Meta (Llama)"),
        ("mistral", "Mistral"),
        ("moonshotai", "Moonshot (Kimi)"),
        ("zhipuai", "Zhipu (GLM)"),
    ]

    public static func loadModelReleaseSnapshot(path: URL? = nil) -> ModelReleaseSnapshot {
        let url = path ?? modelReleaseCachePath()
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? modelReleaseDecoder().decode(ModelReleaseSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }

    /// Returns the cached snapshot when it is fresh enough, otherwise fetches
    /// models.dev and persists the result. A failed fetch returns the cache
    /// rather than erasing it: a missed poll is not evidence that releases
    /// disappeared.
    public static func refreshModelReleaseSnapshot(
        cachePath: URL? = nil,
        sourceURL: URL? = nil,
        maxAge: TimeInterval = 86_400,
        now: Date = Date()
    ) async -> ModelReleaseSnapshot {
        let cached = loadModelReleaseSnapshot(path: cachePath)
        guard cached.isStale(maxAge: maxAge, now: now) else { return cached }
        do {
            let (data, response) = try await URLSession.shared.data(from: sourceURL ?? modelReleaseSourceURL)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return cached
            }
            let releases = try significantModelReleases(from: data)
            let snapshot = ModelReleaseSnapshot(fetchedAt: now, releases: releases)
            let url = cachePath ?? modelReleaseCachePath()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try modelReleaseEncoder().encode(snapshot).write(to: url, options: .atomic)
            return snapshot
        } catch {
            return cached
        }
    }

    /// Parses the models.dev database down to significant releases. Kept
    /// models must output text, carry a release date, and not read as a size,
    /// speed, or modality variant of a flagship.
    public static func significantModelReleases(from data: Data) throws -> [ModelRelease] {
        let providers = try JSONDecoder().decode([String: ModelsDevProvider].self, from: data)
        var releases: [ModelRelease] = []
        for (providerKey, provider) in providers {
            for (modelKey, model) in provider.models ?? [:] {
                guard let releaseDate = model.releaseDate.flatMap(parseModelReleaseDate),
                      model.modalities?.output?.contains("text") ?? true,
                      isSignificantModelID(modelKey)
                else { continue }
                releases.append(ModelRelease(
                    provider: providerKey,
                    providerName: provider.name ?? providerKey,
                    modelID: modelKey,
                    modelName: model.name ?? modelKey,
                    releaseDate: releaseDate
                ))
            }
        }
        return releases.sorted {
            if $0.releaseDate != $1.releaseDate { return $0.releaseDate > $1.releaseDate }
            return $0.id < $1.id
        }
    }

    /// Emits the release-staleness advisory for one skill, or nil when the
    /// skill has been touched or explicitly affirmed since the newest tracked
    /// release. A skill with no update evidence gets no advisory: staleness is
    /// a claim about the world changing after the skill, and that ordering
    /// needs a date to stand on.
    public static func modelReleaseAdvisory(
        skillUpdatedAt: Date?,
        affirmedAt: Date?,
        releases: [ModelRelease],
        trackedProviders: [String],
        now: Date = Date()
    ) -> SkillAdvisory? {
        modelReleaseAdvisory(targets: modelReviewTargets(
            skillUpdatedAt: skillUpdatedAt,
            affirmedAt: affirmedAt,
            releases: releases,
            trackedProviders: trackedProviders,
            now: now
        ))
    }

    /// Resolves one rolling target per provider. Multiple variants released by
    /// the same provider on the same day are one event, so GPT-5.6, Sol, and
    /// Terra yield one OpenAI badge rather than three warnings.
    public static func modelReviewTargets(
        skillUpdatedAt: Date?,
        affirmedAt: Date?,
        releases: [ModelRelease],
        trackedProviders: [String],
        now: Date = Date()
    ) -> [ModelReviewTarget] {
        let baseline = [skillUpdatedAt, affirmedAt].compactMap { $0 }.max()
        let available = releases.filter { $0.releaseDate <= now }
        return trackedProviders.compactMap { provider in
            let providerReleases = available.filter { $0.provider == provider }
            guard let newestDate = providerReleases.map(\.releaseDate).max() else { return nil }
            let newest = providerReleases
                .filter { $0.releaseDate == newestDate }
                .sorted {
                    if $0.modelName != $1.modelName { return $0.modelName < $1.modelName }
                    return $0.modelID < $1.modelID
                }
            guard let first = newest.first else { return nil }
            return ModelReviewTarget(
                provider: provider,
                providerName: first.providerName,
                modelIDs: newest.map(\.modelID),
                modelNames: newest.map(\.modelName),
                releaseDate: newestDate,
                baselineDate: baseline
            )
        }
    }

    public static func modelReleaseAdvisory(targets: [ModelReviewTarget]) -> SkillAdvisory? {
        let gaps = targets.filter(\.needsReview)
        guard !gaps.isEmpty else { return nil }

        let eventText = gaps.map {
            "\($0.modelLabel) (\($0.providerName), \(dayFormatter.string(from: $0.releaseDate)))"
        }.joined(separator: "; ")
        return SkillAdvisory(
            id: "model-release-staleness",
            category: "model-release",
            severity: "warning",
            message: "Not reviewed since \(eventText).",
            remediation: [
                "Review this skill against the newer models. Newer frontier models need less prescription, so look first for guidance to delete, not add — over-describing and over-prescribing solutions can limit them.",
            ],
            clearance: "Clears when the skill changes after the newest tracked release, or when it is explicitly marked reviewed."
        )
    }

    /// A model id is significant unless any of its tokens names a size, speed,
    /// or modality variant. Token matching keeps "gpt-5.6-sol" while dropping
    /// "gpt-5.6-mini" and "text-embedding-3-large".
    static func isSignificantModelID(_ modelID: String) -> Bool {
        let variantTokens: Set<String> = [
            "mini", "nano", "lite", "small", "tiny", "micro", "flash", "fast",
            "turbo", "air", "haiku", "embed", "embedding", "embeddings", "tts",
            "whisper", "audio", "realtime", "image", "video", "moderation",
            "search", "transcribe", "guard", "distill", "codex",
        ]
        let tokens = modelID.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        return !tokens.contains { variantTokens.contains($0) }
    }

    // MARK: - Review affirmations

    /// Records that a skill was reviewed against current models without
    /// changes. Keyed by standardized canonical path.
    public static func affirmModelReleaseReview(
        canonicalPath: String,
        date: Date = Date(),
        path: URL? = nil
    ) throws {
        let url = path ?? modelReleaseAffirmationPath()
        var affirmations = loadModelReleaseAffirmations(path: url)
        affirmations[standardizedModelReleasePath(canonicalPath)] = date
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoded = affirmations.mapValues { modelReleaseDayText($0) }
        try modelReleaseEncoder().encode(encoded).write(to: url, options: .atomic)
    }

    public static func loadModelReleaseAffirmations(path: URL? = nil) -> [String: Date] {
        let url = path ?? modelReleaseAffirmationPath()
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        var affirmations: [String: Date] = [:]
        for (storedPath, dateText) in stored {
            guard let date = parseModelReleaseDate(dateText) ?? ISO8601DateFormatter().date(from: dateText) else { continue }
            affirmations[standardizedModelReleasePath(storedPath)] = date
        }
        return affirmations
    }

    /// Affirmation keys use the same standardization the app applies to
    /// canonical paths so lookups match row identities.
    public static func standardizedModelReleasePath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            return url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        return url.path
    }

    // MARK: - Private

    private static func modelReleaseCachePath() -> URL {
        homeURL().appendingPathComponent("Library/Application Support/Metagent/model-releases-v1.json")
    }

    private static func modelReleaseAffirmationPath() -> URL {
        homeURL().appendingPathComponent("Library/Application Support/Metagent/model-release-affirmations-v1.json")
    }

    private static func modelReleaseEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func modelReleaseDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func parseModelReleaseDate(_ value: String) -> Date? {
        dayFormatter.date(from: value)
    }

    private static func modelReleaseDayText(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}

/// Minimal decode of the models.dev database. Every field is optional so an
/// upstream schema addition cannot break the poll.
struct ModelsDevProvider: Decodable {
    let name: String?
    let models: [String: ModelsDevModel]?
}

struct ModelsDevModel: Decodable {
    let name: String?
    let releaseDate: String?
    let modalities: ModelsDevModalities?

    enum CodingKeys: String, CodingKey {
        case name
        case releaseDate = "release_date"
        case modalities
    }
}

struct ModelsDevModalities: Decodable {
    let output: [String]?
}
