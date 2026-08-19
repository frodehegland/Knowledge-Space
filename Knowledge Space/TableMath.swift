import SwiftUI

// Tables, dressed and alive: how a document's tables appear (Settings
// ▸ Tables), and the small spreadsheet underneath them — a cell whose
// record carries a formula (or whose text spells one, "=B2*C2")
// computes live, and the reader can try other numbers in the input
// cells to see the maths follow. The document is never touched: the
// what-ifs live and die with the reading.

/// How a table dresses on the page — chosen in Settings ▸ Tables.
nonisolated enum TableStyle: String, CaseIterable, Identifiable {
    /// The table on a quiet grey ground.
    case greyBackground
    /// The table open on the page, a light grey frame around it.
    case lightFrame

    var id: String { rawValue }

    var label: String {
        switch self {
        case .greyBackground: "Grey background"
        case .lightFrame: "Light grey frame"
        }
    }
}

// MARK: - The maths

/// A small spreadsheet: numbers, A1-style cell references, + − × ÷ ^,
/// parentheses, and SUM / AVERAGE / MIN / MAX / COUNT over ranges
/// (B2:B9). Enough for the tables documents actually carry; anything
/// it cannot read simply shows as written.
nonisolated enum TableMath {

    /// The cell's formula: the record's own field first, or a value
    /// that spells one ("=B2*C2").
    static func formula(of cell: LiquidDoc.Table.Cell) -> String? {
        if let formula = cell.formula,
           !formula.trimmingCharacters(in: .whitespaces).isEmpty {
            return formula
        }
        let trimmed = cell.value.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("=") && trimmed.count > 1 ? trimmed : nil
    }

    /// Whether any cell computes — the table reads live when one does.
    static func hasMath(_ table: LiquidDoc.Table) -> Bool {
        table.cells.contains { row in row.contains { formula(of: $0) != nil } }
    }

    /// A cell's text as a number, forgiving thousands separators and
    /// currency/percent dressing.
    static func numeric(_ text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t$€£%"))
        return Double(cleaned)
    }

    /// A computed value, written the way a person would: whole numbers
    /// whole, the rest to three decimals at most.
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e12 {
            return String(Int(value))
        }
        return value.formatted(.number.precision(.fractionLength(0...3)))
    }

    /// Every formula cell's display text, computed over the grid with
    /// the reader's what-ifs laid on top. Keys are "row,col"; a cell
    /// with no formula (or a formula the parser cannot read) is nil —
    /// its own text stands.
    static func computedGrid(_ table: LiquidDoc.Table,
                             overrides: [String: String]) -> [String: String] {
        var memo: [String: Double?] = [:]
        var visiting: Set<String> = []

        func key(_ row: Int, _ col: Int) -> String { "\(row),\(col)" }

        func cellValue(_ row: Int, _ col: Int) -> Double? {
            guard row >= 0, row < table.cells.count,
                  col >= 0, col < table.cells[row].count else { return nil }
            let k = key(row, col)
            if let done = memo[k] { return done }
            // A circular formula stops flat rather than spinning.
            guard !visiting.contains(k) else { return nil }
            visiting.insert(k)
            defer { visiting.remove(k) }
            let cell = table.cells[row][col]
            let result: Double?
            if let text = overrides[k] {
                result = numeric(text)
            } else if let formula = formula(of: cell) {
                result = evaluate(formula, cellValue: cellValue)
            } else {
                result = numeric(cell.value)
            }
            memo[k] = result
            return result
        }

        var out: [String: String] = [:]
        for (row, cells) in table.cells.enumerated() {
            for (col, cell) in cells.enumerated() where formula(of: cell) != nil {
                if let value = cellValue(row, col) {
                    out[key(row, col)] = format(value)
                }
            }
        }
        return out
    }

    /// A cell's spreadsheet name — "row 2, col 1" → "B3": letters
    /// count columns, digits the 1-based row, the same address the
    /// formulas speak.
    static func cellName(row: Int, col: Int) -> String {
        var letters = ""
        var c = col + 1
        while c > 0 {
            let unit = (c - 1) % 26
            letters = String(UnicodeScalar(UInt8(65 + unit))) + letters
            c = (c - 1) / 26
        }
        return letters + String(row + 1)
    }

    /// "B3 = 7.5" back into its cell and number — the readable form a
    /// table what-if travels as in the annotation sidecar.
    static func parseEdit(_ text: String) -> (row: Int, col: Int, value: String)? {
        let parts = text.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let ref = parts[0].trimmingCharacters(in: .whitespaces)
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        var letters = "", digits = ""
        for character in ref {
            if character.isLetter, digits.isEmpty {
                letters.append(character)
            } else if character.isNumber {
                digits.append(character)
            } else {
                return nil
            }
        }
        guard !letters.isEmpty, let rowNumber = Int(digits), rowNumber >= 1
        else { return nil }
        var col = 0
        for c in letters.uppercased() {
            guard let scalar = c.unicodeScalars.first,
                  scalar.value >= 65, scalar.value <= 90 else { return nil }
            col = col * 26 + Int(scalar.value - 64)
        }
        return (rowNumber - 1, col - 1, value)
    }

    /// One formula over the grid. `cellValue` answers a reference —
    /// and may recurse into other formulas.
    static func evaluate(_ formula: String,
                         cellValue: @escaping (Int, Int) -> Double?) -> Double? {
        var text = formula.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("=") { text = String(text.dropFirst()) }
        var parser = Parser(chars: Array(text), cellValue: cellValue)
        let value = parser.expression()
        parser.skipSpaces()
        // Trailing junk means the formula is not ours to compute.
        return parser.pos >= parser.chars.count ? value : nil
    }

    /// Recursive descent, spreadsheet-shaped.
    private struct Parser {
        let chars: [Character]
        var pos = 0
        let cellValue: (Int, Int) -> Double?

        mutating func skipSpaces() {
            while pos < chars.count, chars[pos] == " " { pos += 1 }
        }

        private func peek() -> Character? { pos < chars.count ? chars[pos] : nil }

        mutating func expression() -> Double? {
            var left = term()
            while true {
                skipSpaces()
                guard let op = peek(), op == "+" || op == "-" || op == "−"
                else { return left }
                pos += 1
                guard let l = left, let r = term() else { return nil }
                left = op == "+" ? l + r : l - r
            }
        }

        private mutating func term() -> Double? {
            var left = factor()
            while true {
                skipSpaces()
                guard let op = peek(), "*/×÷".contains(op) else { return left }
                pos += 1
                guard let l = left, let r = factor() else { return nil }
                if op == "*" || op == "×" {
                    left = l * r
                } else {
                    guard r != 0 else { return nil }
                    left = l / r
                }
            }
        }

        private mutating func factor() -> Double? {
            skipSpaces()
            if peek() == "-" || peek() == "−" {
                pos += 1
                return factor().map { -$0 }
            }
            let base = primary()
            skipSpaces()
            if peek() == "^" {
                pos += 1
                guard let b = base, let e = factor() else { return nil }
                return pow(b, e)
            }
            return base
        }

        private mutating func primary() -> Double? {
            skipSpaces()
            if peek() == "(" {
                pos += 1
                let value = expression()
                skipSpaces()
                guard peek() == ")" else { return nil }
                pos += 1
                return value
            }
            if let c = peek(), c.isLetter {
                let word = readLetters()
                skipSpaces()
                if peek() == "(" {
                    pos += 1
                    let values = arguments()
                    skipSpaces()
                    guard peek() == ")" else { return nil }
                    pos += 1
                    return apply(word.uppercased(), to: values)
                }
                guard let ref = reference(letters: word, digits: readDigits())
                else { return nil }
                return cellValue(ref.row, ref.col)
            }
            return readNumber()
        }

        /// A function's arguments: ranges (B2:B9) expand to their
        /// cells; anything else is an expression. Blank cells simply
        /// stay out, as a spreadsheet's do.
        private mutating func arguments() -> [Double] {
            var values: [Double] = []
            while true {
                skipSpaces()
                if peek() == ")" || peek() == nil { return values }
                // A range first — backtracking to an expression when
                // the colon never comes.
                let saved = pos
                if let c = peek(), c.isLetter {
                    let letters = readLetters()
                    let digits = readDigits()
                    skipSpaces()
                    if peek() == ":",
                       let from = reference(letters: letters, digits: digits) {
                        pos += 1
                        skipSpaces()
                        let toLetters = readLetters()
                        if let to = reference(letters: toLetters, digits: readDigits()) {
                            for row in min(from.row, to.row)...max(from.row, to.row) {
                                for col in min(from.col, to.col)...max(from.col, to.col) {
                                    if let value = cellValue(row, col) {
                                        values.append(value)
                                    }
                                }
                            }
                        }
                    } else {
                        pos = saved
                        if let value = expression() { values.append(value) }
                    }
                } else if let value = expression() {
                    values.append(value)
                }
                skipSpaces()
                if peek() == "," || peek() == ";" { pos += 1 } else { return values }
            }
        }

        private func apply(_ function: String, to values: [Double]) -> Double? {
            switch function {
            case "SUM": return values.reduce(0, +)
            case "AVERAGE", "AVG", "MEAN":
                return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
            case "MIN": return values.min()
            case "MAX": return values.max()
            case "COUNT": return Double(values.count)
            case "ABS": return values.first.map(abs)
            case "ROUND": return values.first.map { $0.rounded() }
            case "SQRT": return values.first.flatMap { $0 >= 0 ? $0.squareRoot() : nil }
            default: return nil
            }
        }

        private mutating func readLetters() -> String {
            var word = ""
            while let c = peek(), c.isLetter { word.append(c); pos += 1 }
            return word
        }

        private mutating func readDigits() -> String {
            var digits = ""
            while let c = peek(), c.isNumber { digits.append(c); pos += 1 }
            return digits
        }

        private mutating func readNumber() -> Double? {
            skipSpaces()
            var text = ""
            while let c = peek(), c.isNumber || c == "." { text.append(c); pos += 1 }
            return Double(text)
        }

        /// "B2" → row 1, column 1: letters count columns (A first),
        /// digits the 1-based row.
        private func reference(letters: String, digits: String) -> (row: Int, col: Int)? {
            guard !letters.isEmpty, let row = Int(digits), row >= 1 else { return nil }
            var col = 0
            for c in letters.uppercased() {
                guard let scalar = c.unicodeScalars.first,
                      scalar.value >= 65, scalar.value <= 90 else { return nil }
                col = col * 26 + Int(scalar.value - 64)
            }
            return (row - 1, col - 1)
        }
    }
}

// MARK: - The what-ifs, kept

/// The reader's table what-ifs persist as W3C annotations in the
/// document's sidecar — motivation "editing", anchored to the table's
/// paragraph, each body the readable line "B3 = 7.5". The document is
/// the author's; the numbers tried over it are the reader's, and they
/// travel (and delete) with the rest of the reader's annotations.
extension AppState {

    func tableEdits(for doc: LiquidDoc, paragraphID: String) -> [String: String] {
        var out: [String: String] = [:]
        for annotation in annotations(for: doc)
        where annotation.motivation == "editing" && targets(annotation, paragraphID) {
            guard let body = annotation.body?.value,
                  let edit = TableMath.parseEdit(body) else { continue }
            out["\(edit.row),\(edit.col)"] = edit.value
        }
        return out
    }

    func setTableEdits(_ edits: [String: String], for doc: LiquidDoc,
                       paragraphID: String) {
        let folder = doc.fileURL.deletingLastPathComponent()
        var annotations = AnnotationStore.load(for: doc.id, in: folder)
        annotations.removeAll {
            $0.motivation == "editing" && targets($0, paragraphID)
        }
        for (key, value) in edits.sorted(by: { $0.key < $1.key }) {
            let parts = key.split(separator: ",").compactMap { Int(String($0)) }
            guard parts.count == 2 else { continue }
            annotations.append(WebAnnotation(
                motivation: "editing",
                body: WebAnnotation.TextualBody(
                    value: "\(TableMath.cellName(row: parts[0], col: parts[1])) = \(value)",
                    purpose: "editing"),
                target: AnnotationAnchor.target(in: doc, paragraphID: paragraphID)))
        }
        AnnotationStore.save(annotations, for: doc.id, in: folder)
        annotationsStamp += 1
    }

    private func targets(_ annotation: WebAnnotation, _ paragraphID: String) -> Bool {
        annotation.target.selectors.contains { selector in
            if case .fragment(let value, _) = selector { return value == paragraphID }
            return false
        }
    }
}

// MARK: - Settings ▸ Tables

struct TablesSettingsView: View {
    @AppStorage("tableStyle") private var tableStyleRaw = TableStyle.greyBackground.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Table style", selection: $tableStyleRaw) {
                    ForEach(TableStyle.allCases) { style in
                        Text(style.label).tag(style.rawValue)
                    }
                }
                .pickerStyle(.inline)
                // The choice, seen: a small live table in the chosen
                // dress — its Total computes, and the numbers answer
                // to a click.
                OrigamiTableView(table: Self.sample)
                    .padding(.vertical, 4)
            } header: {
                Text("Tables")
            } footer: {
                Text("How a document's tables dress on the reading page. A table whose cells carry formulas reads live: click a number to try another and the maths follows — the document itself is never changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// The preview's table: a header, two inputs, a computed total.
    private static let sample = LiquidDoc.Table(
        identifier: "settings-sample",
        rowCount: 4,
        columnCount: 3,
        cells: [
            [.init(value: "Item"), .init(value: "Count"), .init(value: "Cost")],
            [.init(value: "Paper"), .init(value: "3"), .init(value: "12")],
            [.init(value: "Ink"), .init(value: "2"), .init(value: "9")],
            [.init(value: "Total"), .init(value: "5", formula: "=B2+B3"),
             .init(value: "54", formula: "=B2*C2+B3*C3")],
        ])
}
