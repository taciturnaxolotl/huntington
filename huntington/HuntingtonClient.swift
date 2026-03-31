import Foundation

@MainActor
class HuntingtonClient {
    private let session: HuntingtonSession
    private let bankingHost = "https://m.huntington.com"

    init(session: HuntingtonSession) {
        self.session = session
    }

    // MARK: - Accounts

    func getAccounts() async throws -> AccountsResponse {
        try await session.fetch("\(bankingHost)//dmm/fm-p/accounts/get/all.action?_=\(ts())")
    }

    // MARK: - Transactions

    func getTransactions(accountIds: [Int], startDate: String, endDate: String) async throws -> CalendarResponse {
        let ids = accountIds.map { "productIds=\($0)" }.joined(separator: "&")
        let url = "\(bankingHost)//dmm/fm-p/financialcalendar/get.action"
            + "?startStr=\(startDate)&endStr=\(endDate)&\(ids)"
            + "&includeBalances=false&includeSystemPatterns=false&_=\(ts())"
        return try await session.fetch(url)
    }

    func getRecentTransactions(accounts: [Account], days: Int = 30) async throws -> [Transaction] {
        let eligibleIds = accounts
            .filter { $0.eligibleWidgets.contains("financial-calendar") }
            .map { $0.id }
        guard !eligibleIds.isEmpty else { return [] }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: end)!

        let calendar = try await getTransactions(
            accountIds: eligibleIds,
            startDate: fmt.string(from: start),
            endDate: fmt.string(from: end)
        )
        return flatten(calendar)
    }

    // MARK: - Categories

    func getCategories() async throws -> CategoriesResponse {
        try await session.fetch("\(bankingHost)//dmm/fm-p/categories/get/all.action?_=\(ts())")
    }

    // MARK: - Helpers

    private func flatten(_ response: CalendarResponse) -> [Transaction] {
        guard let result = response.result else { return [] }
        return result.days
            .flatMap { date, day in
                day.transactions.map {
                    Transaction(
                        id: $0.id, accId: $0.accId, name: $0.name,
                        amount: $0.amount, catId: $0.catId,
                        transactionType: $0.transactionType,
                        date: String(date.prefix(10))
                    )
                }
            }
            .sorted { $0.date > $1.date }
    }

    private func ts() -> Int { Int(Date().timeIntervalSince1970 * 1000) }
}

// MARK: - Categories types (minimal)

struct CategoriesResponse: Decodable {
    let result: [Category]
}

struct Category: Decodable, Identifiable {
    let catId: Int
    let catName: String
    let catHexrgbcolor: String
    let catIsIncome: Bool
    let categories: [Category]

    var id: Int { catId }
}
