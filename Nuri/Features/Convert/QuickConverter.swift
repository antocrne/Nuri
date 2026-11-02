import Foundation
import Observation

/// Conversions answered in the address bar as they are typed: « 10 km en miles », « 72 °F en °C »,
/// « 100 usd en eur », « 50 € ». Units are computed here; currencies use the European Central
/// Bank's reference rates (CurrencyRates).
@MainActor
enum QuickConverter {
    private static var fr: Bool { LanguageStore.shared.isFrench }

    struct Result: Equatable {
        /// « 10 km = 6,214 mi »
        let text: String
        /// The converted value alone, as copied: « 6,214 mi ».
        let value: String
        /// Where a rate comes from (currencies only).
        let note: String?
    }

    enum Answer: Equatable {
        case result(Result)
        /// A currency conversion whose rates are being fetched.
        case loading
    }

    /// nil when `input` isn't a conversion.
    static func answer(for input: String, rates: CurrencyRates? = nil) -> Answer? {
        guard let query = parse(input) else { return nil }
        let rates = rates ?? .shared
        if let from = units[query.from], let name = query.to, let to = units[name], from.kind == to.kind {
            let value = (query.amount * from.factor + from.offset - to.offset) / to.factor
            let converted = format(value, fractionDigits: from.kind == .temperature ? 2 : nil) + " " + to.display
            return .result(Result(text: format(query.amount) + " " + from.display + " = " + converted, value: converted, note: nil))
        }
        guard let from = currency(query.from) else { return nil }
        // « 100 usd »: into the Mac's currency.
        let to = query.to.map(currency) ?? rates.localCurrency
        guard let to, to != from else { return nil }
        guard let fromRate = rates.rate(from), let toRate = rates.rate(to) else {
            // An unknown code once the rates are there: not a conversion.
            if rates.isLoaded { return nil }
            rates.refreshIfNeeded()
            return .loading
        }
        rates.refreshIfNeeded()
        let converted = format(query.amount / fromRate * toRate, fractionDigits: 2) + " " + to
        return .result(Result(text: format(query.amount, fractionDigits: 2, trimmed: true) + " " + from + " = " + converted,
                              value: converted, note: rates.sourceNote))
    }

    // MARK: - Reading what was typed

    private struct Query {
        var amount: Double
        var from: String
        var to: String?
    }

    private static let symbols: [Character: String] = ["€": "eur", "$": "usd", "£": "gbp", "¥": "jpy"]
    private static let query = try? NSRegularExpression(
        pattern: #"^([-+]?\d[\d\s.,]*)\s*(.+?)(?:\s+(?:en|in|to|vers|a|à)\s+|\s*(?:->|→|=)\s*)(.+)$"#, options: [.caseInsensitive])
    private static let single = try? NSRegularExpression(pattern: #"^([-+]?\d[\d\s.,]*)\s*(.+)$"#)

    private static func parse(_ input: String) -> Query? {
        var text = input.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
        // « $100 » → « 100 $ »
        if let first = text.first, symbols[first] != nil, text.dropFirst().first(where: { $0 != " " })?.isNumber == true {
            let rest = text.dropFirst().drop { $0 == " " }
            let number = rest.prefix { $0.isNumber || " .,".contains($0) }
            text = number.trimmingCharacters(in: .whitespaces) + " " + String(first) + " " + rest.dropFirst(number.count)
        }
        guard text.count <= 80, text.first.map({ $0.isNumber || "+-".contains($0) }) == true else { return nil }
        func groups(_ regex: NSRegularExpression?) -> [String]? {
            guard let match = regex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
        if let parts = groups(query), let amount = number(parts[0]) {
            return Query(amount: amount, from: normalize(parts[1]), to: normalize(parts[2]))
        }
        guard let parts = groups(single), let amount = number(parts[0]) else { return nil }
        // « 100 usd eur », or a currency alone.
        let words = parts[1].split(separator: " ").map(String.init)
        if words.count == 2, isKnown(normalize(words[0])), isKnown(normalize(words[1])) {
            return Query(amount: amount, from: normalize(words[0]), to: normalize(words[1]))
        }
        return Query(amount: amount, from: normalize(parts[1]), to: nil)
    }

    private static func isKnown(_ name: String) -> Bool {
        units[name] != nil || currencyNames[name] != nil || (name.count == 3 && CurrencyRates.codes.contains(name.uppercased()))
    }

    /// « 1 234,5 », « 1,234.5 », « 1.5 », « 1,5 »: the last separator is the decimal one, unless the
    /// same one appears several times (« 1,234,567 »: thousands).
    private static func number(_ raw: String) -> Double? {
        var text = raw.filter { $0 != " " }
        let separators = text.filter { ".,".contains($0) }
        if let last = separators.last {
            let decimal = separators.count > 1 && Set(separators).count == 1 ? nil : text.lastIndex(of: last)
            let whole = text[..<(decimal ?? text.endIndex)].filter { !".,".contains($0) }
            text = whole + (decimal.map { "." + text[text.index(after: $0)...] } ?? "")
        }
        return Double(text)
    }

    nonisolated private static func normalize(_ unit: String) -> String {
        unit.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "²", with: "2").replacingOccurrences(of: "³", with: "3")
            .replacingOccurrences(of: "œ", with: "oe")
            .folding(options: .diacriticInsensitive, locale: nil)
            .split(separator: " ").joined(separator: " ")
    }

    private static func currency(_ name: String) -> String? {
        if let code = currencyNames[name] { return code }
        let code = name.uppercased()
        return name.count == 3 && CurrencyRates.codes.contains(code) ? code : nil
    }

    // MARK: - Writing the answer

    /// Six significant digits (two decimals for money and temperatures), in the Mac's number format.
    static func format(_ value: Double, fractionDigits: Int? = nil, trimmed: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        if let fractionDigits {
            let scale = pow(10, Double(fractionDigits))
            let rounded = (value * scale).rounded() / scale
            formatter.minimumFractionDigits = trimmed || rounded == rounded.rounded() ? 0 : fractionDigits
            formatter.maximumFractionDigits = fractionDigits
        } else {
            formatter.usesSignificantDigits = true
            formatter.maximumSignificantDigits = abs(value) >= 1_000_000 ? 12 : 6
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    // MARK: - Units

    private enum Kind { case length, mass, temperature, volume, speed, area, duration, data, energy, power, pressure }

    private struct Unit {
        let kind: Kind
        let symbol: String
        /// value × factor + offset = the value in the kind's base unit.
        let factor: Double
        var offset: Double = 0
        /// The symbol as shown, in Nuri's language (« Mo » / « MB »).
        var display: String
    }

    /// Every name a unit can be typed as (lowercase, no accents, ² and ³ as digits) → the unit.
    private static let units: [String: Unit] = {
        var table: [String: Unit] = [:]
        func add(_ kind: Kind, _ symbol: String, _ factor: Double, offset: Double = 0, display: String? = nil, _ names: String...) {
            let unit = Unit(kind: kind, symbol: symbol, factor: factor, offset: offset, display: display ?? symbol)
            for name in [symbol.lowercased(), (display ?? symbol).lowercased()] + names { table[normalize(name)] = unit }
        }
        // Base: metre
        add(.length, "mm", 0.001, "millimetre", "millimetres", "millimeter", "millimeters")
        add(.length, "cm", 0.01, "centimetre", "centimetres", "centimeter", "centimeters")
        add(.length, "m", 1, "metre", "metres", "meter", "meters")
        add(.length, "km", 1000, "kilometre", "kilometres", "kilometer", "kilometers")
        add(.length, "in", 0.0254, "inch", "inches", "pouce", "pouces", "\"")
        add(.length, "ft", 0.3048, "foot", "feet", "pied", "pieds", "'")
        add(.length, "yd", 0.9144, "yard", "yards")
        add(.length, "mi", 1609.344, "mile", "miles")
        add(.length, "nmi", 1852, "mille marin", "milles marins", "nautical mile", "nautical miles")
        // Base: kilogram
        add(.mass, "mg", 0.000001, "milligramme", "milligrammes", "milligram", "milligrams")
        add(.mass, "g", 0.001, "gramme", "grammes", "gram", "grams")
        add(.mass, "kg", 1, "kilo", "kilos", "kilogramme", "kilogrammes", "kilogram", "kilograms")
        add(.mass, "t", 1000, "tonne", "tonnes")
        add(.mass, "oz", 0.028349523125, "once", "onces", "ounce", "ounces")
        add(.mass, "lb", 0.45359237, "lbs", "livre", "livres", "pound", "pounds")
        add(.mass, "st", 6.35029318, "stone", "stones")
        // Base: kelvin
        add(.temperature, "°C", 1, offset: 273.15, "c", "celsius", "degre celsius", "degres celsius", "degres", "degre")
        add(.temperature, "°F", 5.0 / 9.0, offset: 459.67 * 5.0 / 9.0, "f", "fahrenheit", "degre fahrenheit", "degres fahrenheit")
        add(.temperature, "K", 1, "kelvin", "kelvins")
        // Base: litre (US gallon, pint, cup and spoons)
        add(.volume, "ml", 0.001, "millilitre", "millilitres", "milliliter", "milliliters")
        add(.volume, "cl", 0.01, "centilitre", "centilitres")
        add(.volume, "dl", 0.1, "decilitre", "decilitres")
        add(.volume, "l", 1, "litre", "litres", "liter", "liters")
        add(.volume, "m³", 1000, "m3", "metre cube", "metres cubes")
        add(.volume, "gal", 3.785411784, "gallon", "gallons")
        add(.volume, "pt", 0.473176473, "pint", "pints", "pinte", "pintes")
        add(.volume, "cup", 0.2365882365, "cups", "tasse", "tasses")
        add(.volume, "fl oz", 0.0295735295625, "floz", "once liquide", "onces liquides", "fluid ounce", "fluid ounces")
        add(.volume, "tbsp", 0.01478676478125, "cuillere a soupe", "cuilleres a soupe", "tablespoon", "tablespoons")
        add(.volume, "tsp", 0.00492892159375, "cuillere a cafe", "cuilleres a cafe", "teaspoon", "teaspoons")
        // Base: metre per second
        add(.speed, "m/s", 1, "mps")
        add(.speed, "km/h", 1 / 3.6, "kmh", "kph")
        add(.speed, "mph", 0.44704, "mi/h", "miles/h")
        add(.speed, "kn", 1852.0 / 3600, "noeud", "noeuds", "knot", "knots")
        // Base: square metre
        add(.area, "cm²", 0.0001, "cm2")
        add(.area, "m²", 1, "m2", "metre carre", "metres carres")
        add(.area, "km²", 1_000_000, "km2")
        add(.area, "ha", 10_000, "hectare", "hectares")
        add(.area, "ft²", 0.09290304, "ft2", "sqft", "pied carre", "pieds carres")
        add(.area, "acre", 4046.8564224, "acres")
        // Base: second
        add(.duration, "ms", 0.001, "milliseconde", "millisecondes", "millisecond", "milliseconds")
        add(.duration, "s", 1, "sec", "seconde", "secondes", "second", "seconds")
        add(.duration, "min", 60, "minute", "minutes")
        add(.duration, "h", 3600, "heure", "heures", "hour", "hours")
        add(.duration, "j", 86400, display: Self.fr ? "j" : "d", "jour", "jours", "day", "days")
        add(.duration, "sem.", 604_800, display: Self.fr ? "sem." : "wk", "semaine", "semaines", "week", "weeks")
        // Base: byte (ko = 1000 octets, Kio = 1024)
        add(.data, "o", 1, display: Self.fr ? "o" : "B", "octet", "octets", "byte", "bytes")
        add(.data, "ko", 1e3, display: Self.fr ? "ko" : "kB", "kb", "kilooctet", "kilooctets")
        add(.data, "Mo", 1e6, display: Self.fr ? "Mo" : "MB", "mb", "megaoctet", "megaoctets")
        add(.data, "Go", 1e9, display: Self.fr ? "Go" : "GB", "gb", "gigaoctet", "gigaoctets")
        add(.data, "To", 1e12, display: Self.fr ? "To" : "TB", "tb", "teraoctet", "teraoctets")
        add(.data, "Kio", 1024, display: Self.fr ? "Kio" : "KiB", "kib")
        add(.data, "Mio", 1_048_576, display: Self.fr ? "Mio" : "MiB", "mib")
        add(.data, "Gio", 1_073_741_824, display: Self.fr ? "Gio" : "GiB", "gib")
        // Base: joule
        add(.energy, "J", 1, "joule", "joules")
        add(.energy, "kJ", 1000)
        add(.energy, "cal", 4.184, "calorie", "calories")
        add(.energy, "kcal", 4184)
        add(.energy, "Wh", 3600)
        add(.energy, "kWh", 3_600_000)
        // Base: watt
        add(.power, "W", 1, "watt", "watts")
        add(.power, "kW", 1000)
        add(.power, "ch", 735.49875, display: Self.fr ? "ch" : "hp", "cv", "cheval", "chevaux")
        add(.power, "hp", 745.699872, "horsepower")
        // Base: pascal
        add(.pressure, "Pa", 1, "pascal", "pascals")
        add(.pressure, "hPa", 100)
        add(.pressure, "bar", 100_000, "bars")
        add(.pressure, "psi", 6894.757293168)
        add(.pressure, "atm", 101_325)
        // « j » is the day here; joules are written out.
        table["j"] = table["jour"]
        return table
    }()

    private static let currencyNames: [String: String] = [
        "€": "EUR", "euro": "EUR", "euros": "EUR",
        "$": "USD", "dollar": "USD", "dollars": "USD", "dollar americain": "USD", "dollars americains": "USD",
        "£": "GBP", "livre sterling": "GBP", "livres sterling": "GBP",
        "¥": "JPY", "yen": "JPY", "yens": "JPY",
        "franc suisse": "CHF", "francs suisses": "CHF",
        "dollar canadien": "CAD", "dollars canadiens": "CAD",
        "dollar australien": "AUD", "dollars australiens": "AUD",
        "yuan": "CNY", "yuans": "CNY", "roupie": "INR", "roupies": "INR", "won": "KRW", "wons": "KRW",
        "zloty": "PLN", "zlotys": "PLN", "real": "BRL", "reals": "BRL", "peso mexicain": "MXN", "pesos mexicains": "MXN",
        "couronne suedoise": "SEK", "couronnes suedoises": "SEK", "couronne norvegienne": "NOK", "couronnes norvegiennes": "NOK",
        "couronne danoise": "DKK", "couronnes danoises": "DKK", "livre turque": "TRY", "livres turques": "TRY",
    ]
}

/// The European Central Bank's daily reference rates (one euro in each currency): a public file,
/// fetched when a currency conversion is typed and no more than every six hours, kept for the
/// next launches. Nothing of what is typed is sent.
@MainActor @Observable
final class CurrencyRates {
    static let shared = CurrencyRates()

    /// The currencies the ECB publishes, known before the first fetch (to tell « 100 usd » from a search).
    static let codes: Set<String> = ["EUR", "USD", "JPY", "CZK", "DKK", "GBP", "HUF", "PLN", "RON", "SEK", "CHF", "ISK", "NOK", "TRY",
                                     "AUD", "BRL", "CAD", "CNY", "HKD", "IDR", "ILS", "INR", "KRW", "MXN", "MYR", "NZD", "PHP", "SGD",
                                     "THB", "ZAR"]
    private static let source = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!

    private struct Saved: Codable {
        var day: String
        var fetched: Date
        var rates: [String: Double]
    }

    /// Bumped when rates arrive: the address bar computes its answer again.
    private(set) var revision = 0
    @ObservationIgnored private var saved: Saved?
    @ObservationIgnored private var fetching = false
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private let fileURL: URL?

    /// `fileURL`: nil keeps nothing on disk (self-test).
    init(fileURL: URL? = StateStore.directory.appendingPathComponent("rates.json")) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL) { saved = try? JSONDecoder().decode(Saved.self, from: data) }
    }

    var isLoaded: Bool { saved != nil }

    func rate(_ code: String) -> Double? { code == "EUR" ? (saved == nil ? nil : 1) : saved?.rates[code] }

    /// The Mac's currency when the ECB publishes it, else the euro.
    var localCurrency: String {
        let code = Locale.current.currency?.identifier ?? "EUR"
        return Self.codes.contains(code) ? code : "EUR"
    }

    /// « Taux BCE du 1 oct. 2026 »
    var sourceNote: String? {
        guard let saved else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: saved.day) else { return LanguageStore.shared.isFrench ? "Taux BCE" : "ECB rates" }
        let text = date.formatted(.dateTime.day().month(.abbreviated).year())
        return LanguageStore.shared.isFrench ? "Taux BCE du \(text)" : "ECB rates of \(text)"
    }

    /// Fetches the rates when there are none or they are more than six hours old (one attempt a minute at most).
    func refreshIfNeeded(now: Date = Date()) {
        if let saved, now.timeIntervalSince(saved.fetched) < 6 * 3600 { return }
        if fetching || lastAttempt.map({ now.timeIntervalSince($0) < 60 }) == true { return }
        #if DEBUG
        if SelfTestRunner.isRequested { return }
        #endif
        fetching = true
        lastAttempt = now
        Task {
            await fetch()
            fetching = false
        }
    }

    /// Reads the ECB's file. False when it can't be had (offline…): the rates kept, if any, stay.
    @discardableResult
    func fetch() async -> Bool {
        var request = URLRequest(url: Self.source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpShouldHandleCookies = false
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let parsed = Self.parse(String(decoding: data, as: UTF8.self)) else { return false }
        set(rates: parsed.rates, day: parsed.day)
        return true
    }

    func set(rates: [String: Double], day: String, fetched: Date = Date()) {
        let value = Saved(day: day, fetched: fetched, rates: rates)
        saved = value
        revision &+= 1
        if let fileURL, let data = try? JSONEncoder().encode(value) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// `<Cube time='2026-10-01'><Cube currency='USD' rate='1.1298'/>…`
    nonisolated static func parse(_ xml: String) -> (day: String, rates: [String: Double])? {
        guard let dayPattern = try? NSRegularExpression(pattern: #"time=['"](\d{4}-\d{2}-\d{2})['"]"#),
              let ratePattern = try? NSRegularExpression(pattern: #"currency=['"]([A-Z]{3})['"]\s+rate=['"]([0-9.]+)['"]"#) else { return nil }
        let whole = NSRange(xml.startIndex..., in: xml)
        guard let dayMatch = dayPattern.firstMatch(in: xml, range: whole), let dayRange = Range(dayMatch.range(at: 1), in: xml) else { return nil }
        var rates: [String: Double] = [:]
        for match in ratePattern.matches(in: xml, range: whole) {
            guard let code = Range(match.range(at: 1), in: xml), let value = Range(match.range(at: 2), in: xml),
                  let rate = Double(xml[value]), rate > 0 else { continue }
            rates[String(xml[code])] = rate
        }
        return rates.count >= 5 ? (String(xml[dayRange]), rates) : nil
    }
}
