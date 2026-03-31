import Foundation

@MainActor
class HuntingtonClient {
    private let session: HuntingtonSession
    private let base = "https://m.huntington.com"
    private let apiBase = "/api/mobile-customer-accounts/1.11"

    init(session: HuntingtonSession) {
        self.session = session
    }

    // MARK: - Accounts

    func getAccounts() async throws -> [Account] {
        let url = "\(base)\(apiBase)/contexts/\(session.contextId)/customers/\(session.customerId)/accounts?refresh=false"
        let response: AccountsResponse = try await session.fetch(url)
        return response.groups.flatMap { $0.accounts }.map { Account(raw: $0) }
    }

    // MARK: - Transactions

    func getTransactions(account: Account) async throws -> [Transaction] {
        let encodedId = account.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? account.id
        let url = "\(base)\(apiBase)/contexts/\(session.contextId)/customers/\(session.customerId)/deposits/\(encodedId)/transactions"
        let response: TransactionsResponse = try await session.fetch(url)
        return response.items.enumerated().map { Transaction(raw: $0.element, accountId: account.id, index: $0.offset) }
    }

    func getRecentTransactions(accounts: [Account]) async throws -> [Transaction] {
        var all: [Transaction] = []
        for account in accounts {
            let txs = (try? await getTransactions(account: account)) ?? []
            all.append(contentsOf: txs)
        }
        return all.sorted { $0.date > $1.date }
    }
}
