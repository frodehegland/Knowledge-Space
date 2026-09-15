import Foundation

/// A human-assigned document date: the optional `date` field of the format.
/// Meeting notes written the morning after carry the meeting's date; a
/// transcription of an ancient text can carry the text's own date.
///
/// Stored as an ISO-style string with four precisions — "2026-07-07T14:30",
/// "2026-07-07", "2026-07", "2026" — and BCE as a non-positive year per
/// ISO 8601 (year 0 is 1 BCE, so 329 BCE is stored as "-0328"). The UI
/// speaks plain "329 BCE"; only the wire format uses the astronomical
/// year. The time, when present, is wall-clock at the place the moment
/// happened — no zone; a session that started at 14:30 says 14:30
/// wherever the file is read.
nonisolated struct LiquidDate: Hashable, Sendable {
    /// ISO astronomical year: 2026 CE = 2026, 1 BCE = 0, 329 BCE = -328.
    var year: Int
    var month: Int?   // 1–12
    var day: Int?     // 1–31, only meaningful when month is present
    var hour: Int?    // 0–23, only meaningful when day is present
    var minute: Int?  // 0–59, only meaningful when hour is present

    var isBCE: Bool { year <= 0 }

    /// The year as people say it: "-328" displays as 329 (BCE).
    var displayYear: Int { isBCE ? 1 - year : year }

    init(year: Int, month: Int? = nil, day: Int? = nil,
         hour: Int? = nil, minute: Int? = nil) {
        self.year = year
        self.month = month.flatMap { (1...12).contains($0) ? $0 : nil }
        self.day = (self.month != nil) ? day.flatMap { (1...31).contains($0) ? $0 : nil } : nil
        self.hour = (self.day != nil) ? hour.flatMap { (0...23).contains($0) ? $0 : nil } : nil
        self.minute = (self.hour != nil) ? minute.flatMap { (0...59).contains($0) ? $0 : nil } : nil
    }

    /// From what people say: displayYear 329 + bce → ISO year -328.
    init(displayYear: Int, isBCE: Bool, month: Int? = nil, day: Int? = nil) {
        self.init(year: isBCE ? 1 - displayYear : displayYear, month: month, day: day)
    }

    /// A moment as the local clock read it — a session's editable
    /// date and time, taken apart into wall-clock components.
    init(moment: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute],
                                            from: moment)
        self.init(year: parts.year ?? 2026, month: parts.month, day: parts.day,
                  hour: parts.hour, minute: parts.minute)
    }

    /// The stored wall-clock moment resolved on the local calendar —
    /// what a date-and-time picker edits. Missing time reads as noon.
    var editableMoment: Date {
        var components = DateComponents()
        components.era = isBCE ? 0 : 1
        components.year = displayYear
        components.month = month ?? 1
        components.day = day ?? 1
        components.hour = hour ?? 12
        components.minute = minute ?? 0
        return Calendar.current.date(from: components) ?? .now
    }

    // MARK: - Wire format

    /// Parses "2026-07-07T14:30", "2026-07-07", "2026-07", "2026",
    /// "-0328", "-0328-05". Trailing seconds are accepted and dropped.
    init?(isoString: String) {
        let pattern = /^(-?\d{1,6})(?:-(\d{1,2}))?(?:-(\d{1,2}))?(?:T(\d{1,2}):(\d{2})(?::\d{2})?)?$/
        guard let match = isoString.trimmingCharacters(in: .whitespaces).wholeMatch(of: pattern),
              let year = Int(match.1) else { return nil }
        let month = match.2.flatMap { Int($0) }
        let day = match.3.flatMap { Int($0) }
        let hour = match.4.flatMap { Int($0) }
        let minute = match.5.flatMap { Int($0) }
        if let month, !(1...12).contains(month) { return nil }
        if let day, !(1...31).contains(day) { return nil }
        if let hour, !(0...23).contains(hour) { return nil }
        if let minute, !(0...59).contains(minute) { return nil }
        self.init(year: year, month: month, day: day, hour: hour, minute: minute)
    }

    var isoString: String {
        var text = year < 0
            ? "-" + String(format: "%04d", -year)
            : String(format: "%04d", year)
        if let month {
            text += String(format: "-%02d", month)
            if let day {
                text += String(format: "-%02d", day)
                if let hour {
                    text += String(format: "T%02d:%02d", hour, minute ?? 0)
                }
            }
        }
        return text
    }

    // MARK: - Sorting

    /// A concrete instant for sorting and filtering alongside `created`
    /// timestamps. Missing precision resolves to the start of the period.
    var sortDate: Date {
        var components = DateComponents()
        components.era = isBCE ? 0 : 1
        components.year = displayYear
        components.month = month ?? 1
        components.day = day ?? 1
        components.hour = hour ?? 12
        components.minute = minute ?? 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: components) ?? .distantPast
    }

    // MARK: - Display

    private static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    /// "2026" or "329 BCE" — also the year of a citation.
    var yearText: String { isBCE ? "\(displayYear) BCE" : "\(displayYear)" }

    /// "July 2026", or just the year when month is unknown — timeline labels.
    var monthYearText: String {
        guard let month else { return yearText }
        return "\(Self.monthNames[month - 1]) \(yearText)"
    }

    /// "7 July 2026", "July 2026", "2026", "15 March 44 BCE" — with the
    /// time when one is carried: "7 July 2026, 14:30".
    var displayText: String {
        guard let month, let day else { return monthYearText }
        let dayText = "\(day) \(Self.monthNames[month - 1]) \(yearText)"
        guard let hour else { return dayText }
        return dayText + String(format: ", %02d:%02d", hour, minute ?? 0)
    }
}
