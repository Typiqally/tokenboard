/// A per-stage lookup locked to the journey's length: building one from the
/// wrong number of values traps at initialization (every table is exercised
/// by CompanionStageCoverageTests), and reads clamp out-of-range stages so a
/// caller can never crash a render with a stage index.
struct CompanionStageTable<Value> {
    private let values: [Value]

    init(_ values: [Value]) {
        precondition(
            values.count == CompanionJourney.stageCount,
            "Stage table holds \(values.count) values for \(CompanionJourney.stageCount) stages"
        )
        self.values = values
    }

    subscript(stage stage: Int) -> Value {
        values[CompanionJourney.clamped(stage: stage)]
    }
}

extension CompanionStageTable: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: Value...) {
        self.init(elements)
    }
}

extension CompanionStageTable: Sequence {
    func makeIterator() -> IndexingIterator<[Value]> {
        values.makeIterator()
    }
}

extension CompanionStageTable: Sendable where Value: Sendable {}
extension CompanionStageTable: Equatable where Value: Equatable {}
