import Foundation

/// What the assistant has cost, per person. A record only: nothing here limits anything.
///
/// Everyone uses their own OpenRouter key, so "person" is the key's account.
public struct UsageLedger: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var date: Date
        public var user: String
        public var model: String
        /// US dollars.
        public var cost: Double
        public var promptTokens: Int
        public var completionTokens: Int
        /// One instruction from the person, however many model requests it took.
        public var run: String
        public var photo: String

        public init(date: Date, user: String, model: String, cost: Double, promptTokens: Int, completionTokens: Int, run: String, photo: String) {
            self.date = date
            self.user = user
            self.model = model
            self.cost = cost
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.run = run
            self.photo = photo
        }
    }

    public private(set) var entries: [Entry] = []

    static let keptDays = 400.0

    public init() {}

    public mutating func add(_ entry: Entry) {
        entries.append(entry)
        let cutoff = entry.date.addingTimeInterval(-UsageLedger.keptDays * 86400)
        if let first = entries.first, first.date < cutoff { entries.removeAll { $0.date < cutoff } }
    }

    private func sum(_ user: String, _ include: (Entry) -> Bool) -> Double {
        entries.reduce(0) { $1.user == user && include($1) ? $0 + $1.cost : $0 }
    }

    public func spent(by user: String, since date: Date) -> Double { sum(user) { $0.date >= date } }
    public func spent(by user: String, onRun run: String) -> Double { sum(user) { $0.run == run } }
    public func spent(by user: String, onPhoto photo: String) -> Double { sum(user) { $0.photo == photo } }
    public func total(for user: String) -> Double { sum(user) { _ in true } }

    public func requests(by user: String, since date: Date) -> Int {
        Set(entries.filter { $0.user == user && $0.date >= date }.map(\.run)).count
    }

    public static func dollars(_ amount: Double) -> String {
        amount > 0 && amount < 0.01 ? String(format: "$%.4f", amount) : String(format: "$%.2f", amount)
    }
}
