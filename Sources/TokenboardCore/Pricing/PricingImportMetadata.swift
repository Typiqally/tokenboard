public enum PricingImportMetadata {
    public static let bundledRepositoryOrigin = "bundled_repository"
    public static let agentCatalogOrigin = "agent_catalog"
    public static let schemaV1ValidSummary = "schema_v1_valid"
    public static let schemaV2ValidSummary = "schema_v2_valid"

    public static func validationSummary(for schemaVersion: Int) -> String? {
        switch schemaVersion {
        case 1: schemaV1ValidSummary
        case 2: schemaV2ValidSummary
        default: nil
        }
    }

    static let allowedOrigins: Set<String> = [
        bundledRepositoryOrigin,
        agentCatalogOrigin
    ]
    static let allowedValidationSummaries: Set<String> = [
        schemaV1ValidSummary,
        schemaV2ValidSummary
    ]
}
