import Foundation

public enum CurrencyConverter {
    public static func convert(
        usd value: Decimal,
        to currency: DisplayCurrency,
        rates: [DisplayCurrency: Decimal]?
    ) -> Decimal? {
        if currency == .usd { return value }
        guard var rate = rates?[currency], rate > 0 else { return nil }
        var usd = value
        var converted = Decimal.zero
        let error = NSDecimalMultiply(&converted, &usd, &rate, .plain)
        guard error == .noError || error == .lossOfPrecision else { return nil }
        return converted
    }
}
