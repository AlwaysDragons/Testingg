import Foundation

/// JSON coding for PostgREST rows: snake_case keys and Postgres timestamps
/// ("2026-10-27T09:30:00.123456+00:00", "...Z", or a plain "2026-10-27" date).
enum LifeCoding {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognized date \(s)")
            }
            return date
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(string(date))
        }
        return e
    }()

    /// Parses Postgres timestamptz / date strings. Fractional seconds of any length are accepted.
    static func parse(_ s: String) -> Date? {
        let chars = Array(s.utf8)
        func num(_ start: Int, _ len: Int) -> Int? {
            guard start + len <= chars.count else { return nil }
            var v = 0
            for i in start..<(start + len) {
                let c = chars[i]
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2) else { return nil }
        var comps = DateComponents(calendar: utcCalendar, timeZone: TimeZone(identifier: "UTC"), year: y, month: mo, day: d)
        if chars.count == 10 {
            // A plain date: midnight in the device's timezone (what a person means by "that day").
            comps.timeZone = .current
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .current
            comps.calendar = cal
            return comps.date
        }
        guard chars.count >= 19, let h = num(11, 2), let mi = num(14, 2), let sec = num(17, 2) else { return nil }
        comps.hour = h; comps.minute = mi; comps.second = sec
        var i = 19
        var fraction = 0.0
        if i < chars.count, chars[i] == UInt8(ascii: ".") {
            i += 1
            var scale = 0.1
            while i < chars.count, chars[i] >= 48, chars[i] <= 57 {
                fraction += Double(chars[i] - 48) * scale
                scale /= 10
                i += 1
            }
        }
        var offset = 0
        if i < chars.count {
            let sign = chars[i]
            if sign == UInt8(ascii: "Z") {
                offset = 0
            } else if sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
                guard let oh = num(i + 1, 2) else { return nil }
                let rest = i + 3 < chars.count && chars[i + 3] == UInt8(ascii: ":") ? i + 4 : i + 3
                let om = num(rest, 2) ?? 0
                offset = (oh * 3600 + om * 60) * (sign == UInt8(ascii: "-") ? -1 : 1)
            } else {
                return nil
            }
        }
        guard let base = comps.date else { return nil }
        return base.addingTimeInterval(fraction - Double(offset))
    }

    /// ISO 8601 in UTC with milliseconds, accepted by Postgres.
    static func string(_ date: Date) -> String {
        let c = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let ms = (c.nanosecond ?? 0) / 1_000_000
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ms)
    }

    /// "yyyy-MM-dd" in the given calendar's timezone (for `date` columns).
    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
}
