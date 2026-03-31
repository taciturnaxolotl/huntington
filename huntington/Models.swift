import Foundation

// MARK: - Accounts

struct AccountsResponse: Decodable {
    let result: AccountsResult
}

struct AccountsResult: Decodable {
    let amount: Double
    let entities: [AccountEntity]
}

struct AccountEntity: Decodable {
    let id: Int
    let name: String
    let userConnection: UserConnection
}

struct UserConnection: Decodable {
    let accounts: [Account]
}

struct Account: Decodable, Identifiable {
    let id: Int
    let alias: String
    let number: String
    let availableBalance: Double
    let balance: Double
    let eligibleWidgets: [String]
    let active: Bool
    let closed: Bool
    let huntingtonType: String
}

// MARK: - Transactions

struct CalendarResponse: Decodable {
    let result: CalendarResult?
}

struct CalendarResult: Decodable {
    let days: [String: CalendarDay]
}

struct CalendarDay: Decodable {
    let transactions: [RawTransaction]
}

struct RawTransaction: Decodable {
    let id: Int
    let accId: Int
    let name: String
    let amount: Double
    let catId: Int
    let transactionType: String
}

struct Transaction: Identifiable {
    let id: Int
    let accId: Int
    let name: String
    let amount: Double
    let catId: Int
    let transactionType: String
    let date: String
}
