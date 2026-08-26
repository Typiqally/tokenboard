import Foundation

enum GregorianDay {
    static func isValid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 10,
              bytes[4] == 0x2D,
              bytes[7] == 0x2D,
              bytes.enumerated().allSatisfy({ index, byte in
                  index == 4 || index == 7 || (0x30...0x39).contains(byte)
              }) else { return false }
        let year = decimalValue(bytes[0...3])
        let month = decimalValue(bytes[5...6])
        let day = decimalValue(bytes[8...9])
        guard let date = calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )) else { return false }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == year && roundTrip.month == month && roundTrip.day == day
    }

    private static func decimalValue(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reduce(0) { $0 * 10 + Int($1 - 0x30) }
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}
