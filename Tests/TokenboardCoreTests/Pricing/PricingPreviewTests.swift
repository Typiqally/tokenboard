import Foundation
import XCTest
@testable import TokenboardCore

final class PricingPreviewTests: XCTestCase {
    func testCandidatePricesPreviouslyUnpricedSelectedPeriodUsage() throws {
        let current = PricingSnapshot(catalogIDs: ["current"], rates: [], aliases: [])
        let candidate = try validatedCandidate()
        let rows = [usageRow(quantity: 100_000)]

        let preview = try PricingPreview.make(
            rows: rows,
            currentPricing: current,
            candidate: candidate
        )

        XCTAssertEqual(preview.currentKnownUSD, Decimal.zero)
        XCTAssertEqual(preview.candidateKnownUSD, Decimal(string: "0.20"))
        XCTAssertEqual(preview.newlyPricedTokens, 100_000)
        XCTAssertEqual(preview.remainingUnpricedTokens, 0)
        XCTAssertEqual(preview.diff.modelsAdded, ["codex/gpt-preview"])
        XCTAssertEqual(preview.diff.aliasesAdded, 1)
        XCTAssertEqual(preview.diff.ratesAdded, 2)
        XCTAssertEqual(
            preview.provenanceURLs,
            [URL(string: "https://openai.com/api/pricing/")!]
        )
    }

    func testPreviewDoesNotMutateCurrentSnapshotOrCandidate() throws {
        let current = PricingSnapshot(catalogIDs: ["current"], rates: [], aliases: [])
        let candidate = try validatedCandidate()
        let originalCurrent = current
        let originalCandidate = candidate

        _ = try PricingPreview.make(
            rows: [usageRow(quantity: 100_000)],
            currentPricing: current,
            candidate: candidate
        )

        XCTAssertEqual(current, originalCurrent)
        XCTAssertEqual(candidate, originalCandidate)
    }

    func testSameKeyConflictRemainsVisibleAndDoesNotOverrideCurrentRate() throws {
        let current = PricingSnapshot(
            catalogIDs: ["current"],
            rates: [storedRate(usd: "1", metric: .inputUncached)],
            aliases: [storedAlias()]
        )
        let candidate = try validatedCandidate(inputUSD: "2")

        let preview = try PricingPreview.make(
            rows: [usageRow(quantity: 100_000)],
            currentPricing: current,
            candidate: candidate
        )

        XCTAssertEqual(preview.currentKnownUSD, Decimal(string: "0.10"))
        XCTAssertEqual(preview.candidateKnownUSD, Decimal(string: "0.10"))
        XCTAssertEqual(preview.newlyPricedTokens, 0)
        XCTAssertEqual(preview.remainingUnpricedTokens, 0)
        XCTAssertEqual(
            preview.diff.conflicts,
            ["rate codex/gpt-preview/input_uncached/2026-01-01"]
        )
    }

    func testUnionIntervalConflictIsReportedBeforeApply() throws {
        let current = PricingSnapshot(
            catalogIDs: ["current"],
            rates: [storedRate(usd: "1", metric: .inputUncached, to: "2026-12-01")],
            aliases: [storedAlias()]
        )
        let candidate = try validatedCandidate(
            inputUSD: "2",
            effectiveFrom: "2026-06-01"
        )

        let preview = try PricingPreview.make(
            rows: [usageRow(quantity: 100_000)],
            currentPricing: current,
            candidate: candidate
        )

        XCTAssertFalse(preview.diff.conflicts.isEmpty)
        XCTAssertEqual(preview.currentKnownUSD, Decimal(string: "0.10"))
        XCTAssertEqual(preview.candidateKnownUSD, Decimal(string: "0.10"))
    }

    func testNewlyPricedCountsOnlyPerRowTransitionsAndReportsStructuredGaps() throws {
        let current = PricingSnapshot(
            catalogIDs: ["current"],
            rates: [StoredPriceRate(
                provider: .codex,
                canonicalModelID: "gpt-current",
                metric: .inputUncached,
                usdPerMillion: Decimal(string: "1")!,
                effectiveFrom: "2026-01-01",
                effectiveTo: nil,
                provenanceURL: URL(string: "https://openai.com/api/pricing/")!,
                verifiedAt: "2026-08-05"
            )],
            aliases: [StoredModelAlias(
                provider: .codex,
                observedModelID: "gpt-current",
                canonicalModelID: "gpt-current",
                effectiveFrom: "2026-01-01",
                effectiveTo: nil
            )]
        )
        let candidate = try validatedCandidate(effectiveFrom: "2026-08-05")
        let rows = [
            usageRow(quantity: 50, model: "gpt-current", day: "2026-08-05"),
            usageRow(quantity: 20, model: "gpt-preview", day: "2026-08-05"),
            usageRow(quantity: 30, model: "gpt-preview", day: "2026-08-04"),
            usageRow(
                quantity: 40,
                model: "gpt-preview",
                day: "2026-08-05",
                metric: .inputCacheRead
            )
        ]

        let preview = try PricingPreview.make(
            rows: rows,
            currentPricing: current,
            candidate: candidate
        )

        XCTAssertEqual(preview.newlyPricedTokens, 20)
        XCTAssertEqual(preview.remainingUnpricedTokens, 70)
        XCTAssertEqual(preview.unresolvedGaps, [
            PricingGap(
                provider: .codex,
                observedModelID: "gpt-preview",
                metric: .inputUncached,
                effectiveDate: "2026-08-04",
                unpricedTokens: 30
            ),
            PricingGap(
                provider: .codex,
                observedModelID: "gpt-preview",
                metric: .inputCacheRead,
                effectiveDate: "2026-08-05",
                unpricedTokens: 40
            )
        ])
    }

    private func usageRow(
        quantity: Int64,
        model: String = "gpt-preview",
        day: String = "2026-08-05",
        metric: UsageMetric = .inputUncached
    ) -> DailyUsageRow {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return DailyUsageRow(
            localDay: LocalDay(
                date: ISO8601DateFormatter().date(from: "\(day)T12:00:00Z")!,
                calendar: calendar
            ),
            provider: .codex,
            observedModelID: model,
            metric: metric,
            aggregation: .additive,
            quantity: quantity
        )
    }

    private func storedAlias() -> StoredModelAlias {
        StoredModelAlias(
            provider: .codex,
            observedModelID: "gpt-preview",
            canonicalModelID: "gpt-preview",
            effectiveFrom: "2026-01-01",
            effectiveTo: nil
        )
    }

    private func storedRate(
        usd: String,
        metric: UsageMetric,
        from: String = "2026-01-01",
        to: String? = nil
    ) -> StoredPriceRate {
        StoredPriceRate(
            provider: .codex,
            canonicalModelID: "gpt-preview",
            metric: metric,
            usdPerMillion: Decimal(string: usd)!,
            effectiveFrom: from,
            effectiveTo: to,
            provenanceURL: URL(string: "https://openai.com/api/pricing/")!,
            verifiedAt: "2026-08-05"
        )
    }

    private func validatedCandidate(
        inputUSD: String = "2",
        effectiveFrom: String = "2026-01-01"
    ) throws -> ValidatedPricingCatalog {
        let json = """
        {
          "schemaVersion": 1,
          "catalogID": "candidate-2026-08-05",
          "generatedAt": "2026-08-05T12:00:00Z",
          "origin": {
            "kind": "official_research",
            "url": "https://openai.com/api/pricing/"
          },
          "models": [{
            "provider": "codex",
            "canonicalModelID": "gpt-preview",
            "aliases": [{
              "observedModelID": "gpt-preview",
              "effectiveFrom": "2026-01-01",
              "effectiveTo": null
            }],
            "rates": [{
              "effectiveFrom": "\(effectiveFrom)",
              "effectiveTo": null,
              "prices": {
                "input_uncached": "\(inputUSD)",
                "output": "30"
              },
              "provenanceURL": "https://openai.com/api/pricing/",
              "verifiedAt": "2026-08-05"
            }]
          }]
        }
        """
        return try PricingCatalogValidator().validate(
            PricingCatalogLoader().load(Data(json.utf8))
        )
    }
}
