import Foundation

public enum Format {
    public static func duration(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        if t < 60 { return "\(t) s" }
        if t < 3600 { return "\(t / 60) min" }
        if t < 86_400 {
            let h = t / 3600, m = (t % 3600) / 60
            return m == 0 ? "\(h) h" : "\(h) h \(m) min"
        }
        let d = t / 86_400, h = (t % 86_400) / 3600
        return h == 0 ? "\(d) j" : "\(d) j \(h) h"
    }

    public static func ago(_ date: Date, now: Date = Date()) -> String {
        "il y a \(duration(max(0, now.timeIntervalSince(date))))"
    }

    public static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}
