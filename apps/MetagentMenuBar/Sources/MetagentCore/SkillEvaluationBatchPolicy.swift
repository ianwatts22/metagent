/// Controls how often a multi-skill evaluation republishes the complete table
/// model. Per-skill progress text still updates after every result.
public enum SkillEvaluationBatchPolicy {
    public static let defaultBatchSize = 20

    public static func shouldPublish(
        completed: Int,
        total: Int,
        batchSize: Int = defaultBatchSize
    ) -> Bool {
        guard completed > 0, total > 0, completed <= total else { return false }
        let resolvedBatchSize = max(1, batchSize)
        return completed == total || completed.isMultiple(of: resolvedBatchSize)
    }
}
