import Foundation
import XCTest
@testable import TokenboardCore

final class PriceResolverTests: XCTestCase {
    func testResolvesEachAdditiveRowUsingHistoricalAliasAndExactMetricRate() throws {
        let rows = [
            row(day: "2026-08-31", model: "gpt-observed", metric: .inputUncached, quantity: 1_000_000),
            row(day: "2026-09-01", model: "gpt-observed", metric: .inputUncached, quantity: 1_000_000),
            row(day: "2026-09-01", model: "unknown-hash", metric: .inputUncached, quantity: 300_000),
            row(
                day: "2026-09-01",
                model: "gpt-observed",
                metric: .detailReasoningOutput,
                aggregation: .informationalSubset,
                quantity: 900_000
            )
        ]
        let snapshot = pricing(
            aliases: [alias(model: "gpt-observed")],
            rates: [
                rate(metric: .inputUncached, usd: "2.00", from: "2026-01-01"),
                rate(metric: .inputUncached, usd: "3.00", from: "2026-09-01")
            ]
        )

        let result = try PriceResolver().resolve(rows: rows, pricing: snapshot)

        XCTAssertEqual(result.tokenTotal, 2_300_000)
        XCTAssertEqual(result.knownUSD, Decimal(string: "5.00"))
        XCTAssertEqual(result.unpricedTokens, 300_000)
    }

    func testAliasGapLeavesTokensUnpricedAtExclusiveEnd() throws {
        let snapshot = pricing(
            aliases: [alias(model: "gpt-observed", from: "2026-01-01", to: "2026-02-01")],
            rates: [rate(metric: .inputUncached, usd: "7", from: "2026-01-01")]
        )

        let result = try PriceResolver().resolve(
            rows: [row(day: "2026-02-01", model: "gpt-observed", metric: .inputUncached, quantity: 40)],
            pricing: snapshot
        )

        XCTAssertEqual(result.tokenTotal, 40)
        XCTAssertEqual(result.knownUSD, .zero)
        XCTAssertEqual(result.unpricedTokens, 40)
    }

    func testUnclassifiedAndMissingCacheMetricsNeverBorrowBaseInputRate() throws {
        let snapshot = pricing(
            aliases: [alias(model: "gpt-observed")],
            rates: [rate(metric: .inputUncached, usd: "2.50", from: "2026-01-01")]
        )
        let rows = [
            row(day: "2026-08-05", model: "gpt-observed", metric: .inputUnclassified, quantity: 11),
            row(day: "2026-08-05", model: "gpt-observed", metric: .inputCacheRead, quantity: 13),
            row(day: "2026-08-05", model: "gpt-observed", metric: .inputCacheWrite, quantity: 17)
        ]

        let result = try PriceResolver().resolve(rows: rows, pricing: snapshot)

        XCTAssertEqual(result.tokenTotal, 41)
        XCTAssertEqual(result.knownUSD, .zero)
        XCTAssertEqual(result.unpricedTokens, 41)
    }

    func testRateGapLeavesTokensUnpricedAtExclusiveEnd() throws {
        let snapshot = pricing(
            aliases: [alias(model: "gpt-observed")],
            rates: [rate(metric: .output, usd: "10", from: "2026-01-01", to: "2026-04-01")]
        )

        let result = try PriceResolver().resolve(
            rows: [row(day: "2026-04-01", model: "gpt-observed", metric: .output, quantity: 80)],
            pricing: snapshot
        )

        XCTAssertEqual(result, PriceResolution(tokenTotal: 80, knownUSD: .zero, unpricedTokens: 80))
    }

    func testDuplicateAliasEffectiveStartIsAnIntegrityError() throws {
        let snapshot = pricing(
            aliases: [
                alias(model: "gpt-observed", canonical: "gpt-a"),
                alias(model: "gpt-observed", canonical: "gpt-b")
            ],
            rates: []
        )

        do {
            _ = try PriceResolver().resolve(
                rows: [row(day: "2026-08-05", model: "gpt-observed", metric: .output, quantity: 1)],
                pricing: snapshot
            )
            XCTFail("expected duplicate alias start to throw")
        } catch let error as PriceResolverError {
            XCTAssertEqual(
                error,
                .duplicateAliasEffectiveStart(
                    provider: .codex,
                    observedModelID: "gpt-observed",
                    effectiveFrom: "2026-01-01"
                )
            )
        }
    }

    func testDuplicateRateEffectiveStartIsAnIntegrityError() throws {
        let snapshot = pricing(
            aliases: [alias(model: "gpt-observed")],
            rates: [
                rate(metric: .output, usd: "10", from: "2026-01-01"),
                rate(metric: .output, usd: "20", from: "2026-01-01")
            ]
        )

        do {
            _ = try PriceResolver().resolve(
                rows: [row(day: "2026-08-05", model: "gpt-observed", metric: .output, quantity: 1)],
                pricing: snapshot
            )
            XCTFail("expected duplicate rate start to throw")
        } catch let error as PriceResolverError {
            XCTAssertEqual(
                error,
                .duplicateRateEffectiveStart(
                    provider: .codex,
                    canonicalModelID: "gpt-canonical",
                    metric: .output,
                    effectiveFrom: "2026-01-01"
                )
            )
        }
    }

    func testTokenAccumulationOverflowThrowsInsteadOfTrappingOrSaturating() throws {
        let rows = [
            row(day: "2026-08-05", model: "unknown", metric: .output, quantity: .max),
            row(day: "2026-08-06", model: "unknown", metric: .output, quantity: 1)
        ]

        do {
            _ = try PriceResolver().resolve(rows: rows, pricing: pricing(aliases: [], rates: []))
            XCTFail("expected token overflow to throw")
        } catch let error as PriceResolverError {
            XCTAssertEqual(error, .tokenTotalOverflow)
        }
    }

    func testNegativeAdditiveQuantityIsAnIntegrityError() throws {
        do {
            _ = try PriceResolver().resolve(
                rows: [row(day: "2026-08-05", model: "unknown", metric: .output, quantity: -1)],
                pricing: pricing(aliases: [], rates: [])
            )
            XCTFail("expected negative quantity to throw")
        } catch let error as PriceResolverError {
            XCTAssertEqual(error, .negativeQuantity)
        }
    }

    private func row(
        day value: String,
        model: String,
        metric: UsageMetric,
        aggregation: MetricAggregation = .additive,
        quantity: Int64
    ) -> DailyUsageRow {
        DailyUsageRow(
            localDay: localDay(value),
            provider: .codex,
            observedModelID: model,
            metric: metric,
            aggregation: aggregation,
            quantity: quantity
        )
    }

    private func alias(
        model: String,
        canonical: String = "gpt-canonical",
        from: String = "2026-01-01",
        to: String? = nil
    ) -> StoredModelAlias {
        StoredModelAlias(
            provider: .codex,
            observedModelID: model,
            canonicalModelID: canonical,
            effectiveFrom: from,
            effectiveTo: to
        )
    }

    private func rate(
        canonical: String = "gpt-canonical",
        metric: UsageMetric,
        usd: String,
        from: String,
        to: String? = nil
    ) -> StoredPriceRate {
        StoredPriceRate(
            provider: .codex,
            canonicalModelID: canonical,
            metric: metric,
            usdPerMillion: Decimal(string: usd)!,
            effectiveFrom: from,
            effectiveTo: to,
            provenanceURL: URL(string: "https://openai.com/api/pricing/")!,
            verifiedAt: "2026-08-05"
        )
    }

    private func pricing(aliases: [StoredModelAlias], rates: [StoredPriceRate]) -> PricingSnapshot {
        PricingSnapshot(catalogIDs: ["test"], rates: rates, aliases: aliases)
    }

    private func localDay(_ value: String) -> LocalDay {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return LocalDay(date: formatter.date(from: value)!, calendar: calendar)
    }
}
