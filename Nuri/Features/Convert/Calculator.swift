import Foundation

/// Calculations answered in the address bar as they are typed: « 12*4+3 », « (1,5 + 2) × 3 »,
/// « 2^10 », « √2 », « 20 % de 150 », « 200 + 10 % », « sin(30°) ». Computed here, nothing is sent.
enum Calculator {
    struct Result: Equatable {
        /// « 12*4+3 = 51 »
        let text: String
        /// The result alone, as copied (no thousands separator): « 51 ».
        let value: String
    }

    /// nil when `input` isn't a calculation: a number alone, a search, a division by zero…
    static func answer(for input: String) -> Result? {
        var expression = input.trimmingCharacters(in: .whitespaces)
        if expression.hasSuffix("=") { expression = String(expression.dropLast()).trimmingCharacters(in: .whitespaces) }
        guard !expression.isEmpty, expression.count <= 200, let tokens = tokenize(expression) else { return nil }
        // At least one operation: « 2024 », « -5 » or « 192.168.1.1 » stay searches.
        // Two values side by side multiply (« 2π », « 2(3+4) »).
        let values = tokens.drop { $0 == .op("+") || $0 == .op("-") }.filter { $0 != .open && $0 != .close }
        guard values.contains(where: \.isOperation) || values.count > 1 else { return nil }
        var parser = Parser(tokens: tokens)
        guard let value = parser.parse(), value.isFinite else { return nil }
        let shown = format(value, grouped: true)
        return Result(text: expression + " = " + shown, value: format(value, grouped: false))
    }

    // MARK: - Reading what was typed

    private enum Token: Equatable {
        case number(Double)
        case op(Character)
        case open, close
        case function(String)
        case constant(Double)
        case percent, factorial, degrees
        /// « 20 % de 150 », « 20% of 150 »
        case of

        var isOperation: Bool {
            switch self {
            case .number, .open, .close, .constant: false
            default: true
            }
        }
    }

    private static let functions: Set<String> = ["sqrt", "racine", "abs", "ln", "log", "exp", "sin", "cos", "tan", "asin", "acos", "atan"]
    private static let constants: [String: Double] = ["pi": .pi, "π": .pi, "e": M_E]

    private static func tokenize(_ text: String) -> [Token]? {
        let characters = Array(text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ").lowercased())
        var tokens: [Token] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case " ":
                index += 1
            case "0"..."9", ".", ",":
                var raw = ""
                while index < characters.count {
                    let next = characters[index]
                    if next.isASCII, next.isNumber || next == "." || next == "," {
                        raw.append(next)
                        index += 1
                    } else if next == " ", raw.last?.isNumber == true, isThousandsGroup(characters, after: index) {
                        // « 1 000 000 »: a space followed by exactly three digits.
                        index += 1
                    } else {
                        break
                    }
                }
                guard raw.contains(where: \.isNumber), let value = number(raw) else { return nil }
                tokens.append(.number(value))
            case "+", "-", "−", "–":
                tokens.append(.op(character == "+" ? "+" : "-"))
                index += 1
            case "*", "×", "·", "∙":
                // « 2**10 »: a power.
                if character == "*", index + 1 < characters.count, characters[index + 1] == "*" {
                    tokens.append(.op("^"))
                    index += 2
                } else {
                    tokens.append(.op("*"))
                    index += 1
                }
            case "/", "÷":
                tokens.append(.op("/"))
                index += 1
            case "^":
                tokens.append(.op("^"))
                index += 1
            case "(", "[":
                tokens.append(.open)
                index += 1
            case ")", "]":
                tokens.append(.close)
                index += 1
            case "%":
                tokens.append(.percent)
                index += 1
            case "!":
                tokens.append(.factorial)
                index += 1
            case "°":
                tokens.append(.degrees)
                index += 1
            case "√":
                tokens.append(.function("sqrt"))
                index += 1
            case "π":
                tokens.append(.constant(.pi))
                index += 1
            case "²", "³":
                tokens.append(.op("^"))
                tokens.append(.number(character == "²" ? 2 : 3))
                index += 1
            default:
                guard character.isLetter else { return nil }
                var word = ""
                while index < characters.count, characters[index].isLetter {
                    word.append(characters[index])
                    index += 1
                }
                if functions.contains(word) {
                    tokens.append(.function(word == "racine" ? "sqrt" : word))
                } else if let value = constants[word] {
                    tokens.append(.constant(value))
                } else if word == "x" {
                    tokens.append(.op("*"))
                } else if (word == "de" || word == "of"), tokens.last == .percent {
                    tokens.append(.of)
                } else {
                    return nil
                }
            }
        }
        return tokens
    }

    private static func isThousandsGroup(_ characters: [Character], after space: Int) -> Bool {
        let digits = characters[(space + 1)...].prefix { $0.isASCII && $0.isNumber }
        guard digits.count == 3 else { return false }
        let end = space + 4
        return end == characters.count || !(characters[end].isASCII && characters[end].isNumber)
    }

    /// « 1,5 », « 1.5 », « 1 234,5 », « 1,234.5 »: the last separator is the decimal one, unless
    /// the same one appears several times (« 1.234.567 »: thousands).
    private static func number(_ raw: String) -> Double? {
        var text = raw
        let separators = text.filter { ".,".contains($0) }
        if let last = separators.last {
            let decimal = separators.count > 1 && Set(separators).count == 1 ? nil : text.lastIndex(of: last)
            let whole = text[..<(decimal ?? text.endIndex)].filter { !".,".contains($0) }
            text = whole + (decimal.map { "." + text[text.index(after: $0)...] } ?? "")
        }
        if text.hasPrefix(".") { text = "0" + text }
        return Double(text)
    }

    // MARK: - Computing

    /// expression = term (('+' | '-') term)*   — « a + b % » adds b percent of a
    /// term       = unary (('*' | '/' | implicit) unary)*
    /// unary      = ('+' | '-') unary | power
    /// power      = postfix ('^' unary)?        — right-associative, « -2^2 » = -4
    /// postfix    = primary ('%' | '!' | '°')*  — « 20 % de x » = 20 % × x
    /// primary    = number | constant | '(' expression ')' | function primary
    private struct Parser {
        let tokens: [Token]
        var position = 0

        init(tokens: [Token]) { self.tokens = tokens }

        mutating func parse() -> Double? {
            guard let value = expression(), position == tokens.count else { return nil }
            return value
        }

        private var current: Token? { position < tokens.count ? tokens[position] : nil }

        private mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while case .op(let op)? = current, op == "+" || op == "-" {
                position += 1
                let start = position
                guard let right = term() else { return nil }
                // « 200 + 10 % » = 220: a percentage of what comes before.
                if position == start + 2, tokens[position - 1] == .percent, case .number = tokens[start] {
                    value += (op == "+" ? 1 : -1) * value * right
                } else {
                    value += op == "+" ? right : -right
                }
            }
            return value
        }

        private mutating func term() -> Double? {
            guard var value = unary() else { return nil }
            while let token = current {
                switch token {
                case .op("*"), .of:
                    position += 1
                    guard let right = unary() else { return nil }
                    value *= right
                case .op("/"):
                    position += 1
                    guard let right = unary(), right != 0 else { return nil }
                    value /= right
                // « 2π », « 3(4+5) », « 2√9 »
                case .open, .constant, .function:
                    guard let right = power() else { return nil }
                    value *= right
                default:
                    return value
                }
            }
            return value
        }

        private mutating func unary() -> Double? {
            if case .op(let op)? = current, op == "+" || op == "-" {
                position += 1
                guard let value = unary() else { return nil }
                return op == "-" ? -value : value
            }
            return power()
        }

        private mutating func power() -> Double? {
            guard let base = postfix() else { return nil }
            guard case .op("^")? = current else { return base }
            position += 1
            guard let exponent = unary() else { return nil }
            return pow(base, exponent)
        }

        private mutating func postfix() -> Double? {
            guard var value = primary() else { return nil }
            while let token = current {
                switch token {
                case .percent: value /= 100
                case .degrees: value *= .pi / 180
                case .factorial:
                    guard value >= 0, value <= 170, value == value.rounded() else { return nil }
                    value = value == 0 ? 1 : (1...Int(value)).reduce(1.0) { $0 * Double($1) }
                default: return value
                }
                position += 1
            }
            return value
        }

        private mutating func primary() -> Double? {
            guard let token = current else { return nil }
            position += 1
            switch token {
            case .number(let value), .constant(let value):
                return value
            case .open:
                guard let value = expression() else { return nil }
                // A parenthesis left open at the end is closed: « (1+2)*(3+4 » while typing.
                if current == .close { position += 1 } else if current != nil { return nil }
                return value
            case .function(let name):
                // « sqrt(2)^2 » squares the root; « √2 », « sin 30° » take the number that follows.
                guard let argument = current == .open ? primary() : postfix() else { return nil }
                return apply(name, argument)
            default:
                return nil
            }
        }

        private func apply(_ name: String, _ x: Double) -> Double? {
            let value: Double
            switch name {
            case "sqrt": guard x >= 0 else { return nil }; value = x.squareRoot()
            case "abs": value = abs(x)
            case "ln": guard x > 0 else { return nil }; value = log(x)
            case "log": guard x > 0 else { return nil }; value = log10(x)
            case "exp": value = exp(x)
            // Trigonometry in radians; « sin(30°) » in degrees.
            case "sin": value = sin(x)
            case "cos": value = cos(x)
            case "tan": value = tan(x)
            case "asin": guard abs(x) <= 1 else { return nil }; value = asin(x)
            case "acos": guard abs(x) <= 1 else { return nil }; value = acos(x)
            case "atan": value = atan(x)
            default: return nil
            }
            return value.isFinite ? value : nil
        }
    }

    // MARK: - Writing the answer

    /// Twelve significant digits (« 0,1 + 0,2 » = 0,3; fifteen for a whole number), in the Mac's
    /// number format; scientific notation for very large or very small values.
    static func format(_ value: Double, grouped: Bool) -> String {
        // sin(π) is 1.2e-16, not 0.
        let value = abs(value) < 1e-12 ? 0 : value
        let formatter = NumberFormatter()
        if value != 0, abs(value) >= 1e15 || abs(value) < 1e-6 {
            formatter.numberStyle = .scientific
            formatter.usesSignificantDigits = true
            formatter.maximumSignificantDigits = 10
        } else {
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = grouped
            formatter.usesSignificantDigits = true
            formatter.maximumSignificantDigits = value == value.rounded() ? 15 : 12
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
