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
            row(day: "2026-08-05", model: "gpt-observed", metric: .inputCacheWrite, quantity: 17),
            row(day: "2026-08-05", model: "gpt-observed", metric: .inputCacheWrite5m, quantity: 19),
            row(day: "2026-08-05", model: "gpt-observed", metric: .inputCacheWrite1h, quantity: 23)
        ]

        let result = try PriceResolver().resolve(rows: rows, pricing: snapshot)

        XCTAssertEqual(result.tokenTotal, 83)
        XCTAssertEqual(result.knownUSD, .zero)
        XCTAssertEqual(result.unpricedTokens, 83)
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

    func testDecimalOverflowThrowsInsteadOfReturningAnInexactCost() throws {
        let overflowingRate = StoredPriceRate(
            provider: .codex,
            canonicalModelID: "gpt-canonical",
            metric: .output,
            usdPerMillion: .greatestFiniteMagnitude,
            effectiveFrom: "2026-01-01",
            effectiveTo: nil,
            provenanceURL: URL(string: "https://openai.com/api/pricing/")!,
            verifiedAt: "2026-08-05"
        )

        do {
            _ = try PriceResolver().resolve(
                rows: [row(day: "2026-08-05", model: "gpt-observed", metric: .output, quantity: 2)],
                pricing: pricing(aliases: [alias(model: "gpt-observed")], rates: [overflowingRate])
            )
            XCTFail("expected decimal overflow to throw")
        } catch let error as PriceResolverError {
            XCTAssertEqual(error, .decimalArithmeticFailure)
        }
    }

    func testLaterExpiringAliasDoesNotFallBackToOlderOpenEndedAlias() throws {
        let snapshot = pricing(
            aliases: [
                alias(model: "gpt-observed", canonical: "gpt-old", from: "2026-01-01"),
                alias(
                    model: "gpt-observed",
                    canonical: "gpt-new",
                    from: "2026-09-01",
                    to: "2026-10-01"
                )
            ],
            rates: [
                rate(canonical: "gpt-old", metric: .output, usd: "2", from: "2026-01-01"),
                rate(canonical: "gpt-new", metric: .output, usd: "3", from: "2026-01-01")
            ]
        )
        let rows = [
            row(day: "2026-08-31", model: "gpt-observed", metric: .output, quantity: 1_000_000),
            row(day: "2026-09-01", model: "gpt-observed", metric: .output, quantity: 1_000_000),
            row(day: "2026-10-01", model: "gpt-observed", metric: .output, quantity: 1_000_000)
        ]

        let result = try PriceResolver().resolve(rows: rows, pricing: snapshot)

        XCTAssertEqual(result.tokenTotal, 3_000_000)
        XCTAssertEqual(result.knownUSD, Decimal(string: "5"))
        XCTAssertEqual(result.unpricedTokens, 1_000_000)
    }

    func testLaterExpiringRateDoesNotFallBackToOlderOpenEndedRate() throws {
        let snapshot = pricing(
            aliases: [alias(model: "gpt-observed")],
            rates: [
                rate(metric: .output, usd: "2", from: "2026-01-01"),
                rate(metric: .output, usd: "3", from: "2026-09-01", to: "2026-10-01")
            ]
        )
        let rows = [
            row(day: "2026-08-31", model: "gpt-observed", metric: .output, quantity: 1_000_000),
            row(day: "2026-09-01", model: "gpt-observed", metric: .output, quantity: 1_000_000),
            row(day: "2026-10-01", model: "gpt-observed", metric: .output, quantity: 1_000_000)
        ]

        let result = try PriceResolver().resolve(rows: rows, pricing: snapshot)

        XCTAssertEqual(result.tokenTotal, 3_000_000)
        XCTAssertEqual(result.knownUSD, Decimal(string: "5"))
        XCTAssertEqual(result.unpricedTokens, 1_000_000)
    }

    func testProviderIsolatesBothAliasAndRateLookupKeys() throws {
        let snapshot = pricing(
            aliases: [
                alias(provider: .codex, model: "shared-model", canonical: "shared-canonical"),
                alias(provider: .claudeCode, model: "shared-model", canonical: "shared-canonical")
            ],
            rates: [
                rate(
                    provider: .codex,
                    canonical: "shared-canonical",
                    metric: .output,
                    usd: "2",
                    from: "2026-01-01"
                ),
                rate(
                    provider: .claudeCode,
                    canonical: "shared-canonical",
                    metric: .output,
                    usd: "7",
                    from: "2026-01-01"
                )
            ]
        )
        let rows = [
            row(
                day: "2026-08-05",
                provider: .codex,
                model: "shared-model",
                metric: .output,
                quantity: 1_000_000
            ),
            row(
                day: "2026-08-05",
                provider: .claudeCode,
                model: "shared-model",
                metric: .output,
                quantity: 1_000_000
            )
        ]

        let result = try PriceResolver().resolve(rows: rows, pricing: snapshot)

        XCTAssertEqual(result.tokenTotal, 2_000_000)
        XCTAssertEqual(result.knownUSD, Decimal(string: "9"))
        XCTAssertEqual(result.unpricedTokens, 0)
    }

    func testRejectsMalformedAndImpossibleEffectiveDates() throws {
        assertResolverError(.invalidEffectiveDate("2026-8-01")) {
            _ = try PriceResolver().resolve(
                rows: [],
                pricing: pricing(
                    aliases: [alias(model: "gpt-observed", from: "2026-8-01")],
                    rates: []
                )
            )
        }
        assertResolverError(.invalidEffectiveDate("2026-02-30")) {
            _ = try PriceResolver().resolve(
                rows: [],
                pricing: pricing(
                    aliases: [],
                    rates: [rate(metric: .output, usd: "2", from: "2026-02-30")]
                )
            )
        }
    }

    func testRejectsEqualAndReversedEffectiveIntervals() throws {
        assertResolverError(.invalidEffectiveInterval(from: "2026-02-01", to: "2026-02-01")) {
            _ = try PriceResolver().resolve(
                rows: [],
                pricing: pricing(
                    aliases: [
                        alias(model: "gpt-observed", from: "2026-02-01", to: "2026-02-01")
                    ],
                    rates: []
                )
            )
        }
        assertResolverError(.invalidEffectiveInterval(from: "2026-03-01", to: "2026-02-01")) {
            _ = try PriceResolver().resolve(
                rows: [],
                pricing: pricing(
                    aliases: [],
                    rates: [
                        rate(metric: .output, usd: "2", from: "2026-03-01", to: "2026-02-01")
                    ]
                )
            )
        }
    }

    func testRejectsExplicitAliasAndRateIntervalsOverlappingLaterStarts() throws {
        assertResolverError(
            .overlappingAliasIntervals(
                provider: .codex,
                observedModelID: "gpt-observed",
                earlierEffectiveFrom: "2026-01-01",
                laterEffectiveFrom: "2026-02-01"
            )
        ) {
            _ = try PriceResolver().resolve(
                rows: [],
                pricing: pricing(
                    aliases: [
                        alias(model: "gpt-observed", from: "2026-01-01", to: "2026-03-01"),
                        alias(model: "gpt-observed", from: "2026-02-01")
                    ],
                    rates: []
                )
            )
        }
        assertResolverError(
            .overlappingRateIntervals(
                provider: .codex,
                canonicalModelID: "gpt-canonical",
                metric: .output,
                earlierEffectiveFrom: "2026-01-01",
                laterEffectiveFrom: "2026-02-01"
            )
        ) {
            _ = try PriceResolver().resolve(
                rows: [],
                pricing: pricing(
                    aliases: [],
                    rates: [
                        rate(metric: .output, usd: "2", from: "2026-01-01", to: "2026-03-01"),
                        rate(metric: .output, usd: "3", from: "2026-02-01")
                    ]
                )
            )
        }
    }

    private func assertResolverError(
        _ expected: PriceResolverError,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            XCTFail("expected resolver error \(expected)")
        } catch let error as PriceResolverError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    private func row(
        day value: String,
        provider: Provider = .codex,
        model: String,
        metric: UsageMetric,
        aggregation: MetricAggregation = .additive,
        quantity: Int64
    ) -> DailyUsageRow {
        DailyUsageRow(
            localDay: localDay(value),
            provider: provider,
            observedModelID: model,
            metric: metric,
            aggregation: aggregation,
            quantity: quantity
        )
    }

    private func alias(
        provider: Provider = .codex,
        model: String,
        canonical: String = "gpt-canonical",
        from: String = "2026-01-01",
        to: String? = nil
    ) -> StoredModelAlias {
        StoredModelAlias(
            provider: provider,
            observedModelID: model,
            canonicalModelID: canonical,
            effectiveFrom: from,
            effectiveTo: to
        )
    }

    private func rate(
        provider: Provider = .codex,
        canonical: String = "gpt-canonical",
        metric: UsageMetric,
        usd: String,
        from: String,
        to: String? = nil
    ) -> StoredPriceRate {
        StoredPriceRate(
            provider: provider,
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
