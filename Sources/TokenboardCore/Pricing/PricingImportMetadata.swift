public enum PricingImportMetadata {
    public static let bundledRepositoryOrigin = "bundled_repository"
    public static let agentCandidateOrigin = "agent_candidate"
    public static let schemaV1ValidSummary = "schema_v1_valid"

    static let allowedOrigins: Set<String> = [
        bundledRepositoryOrigin,
        agentCandidateOrigin
    ]
    static let allowedValidationSummaries: Set<String> = [
        schemaV1ValidSummary
    ]
}
