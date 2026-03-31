import Foundation

// MARK: - Accounts

struct AccountsResponse: Decodable {
    let groups: [AccountGroup]
}

struct AccountGroup: Decodable {
    let accounts: [RawAccount]
}

struct RawAccount: Decodable {
    let accountId: String
    let accountType: String
    let nickName: String
    let availableBalance: String
    let currentBalance: String
    let maskedAccountNumber: String
    let routingNumber: String
}

struct Account: Identifiable {
    let id: String
    let alias: String
    let number: String
    let availableBalance: Double
    let currentBalance: Double
    let accountType: String
    let routingNumber: String

    init(raw: RawAccount) {
        id = raw.accountId
        alias = raw.nickName
        number = raw.maskedAccountNumber
        availableBalance = Double(raw.availableBalance) ?? 0
        currentBalance = Double(raw.currentBalance) ?? 0
        accountType = raw.accountType.capitalized
        routingNumber = raw.routingNumber
    }
}

// MARK: - Transactions

struct TransactionsResponse: Decodable {
    let items: [RawTransaction]
}

struct RawTransaction: Decodable {
    let transactionCategory: String
    let postedDate: String
    let runningBalance: String?
    // history
    let transactionAmount: String?
    let payeeName: String?
    let transactionTypeDescription: String?
    let imageId: String?
    let referenceNumber: String?
    let merchantCity: String?
    let merchantState: String?
    // pending
    let totalTransactionDebitAmount: String?
    let postedTransactionCreditAmount: String?
    let transactionTypeDesc: String?
    let transactionType: String?
    let memo: String?
}

struct Transaction: Identifiable {
    let id: String
    let accountId: String
    let name: String
    let amount: Double
    let date: String
    let transactionType: String
    let isPending: Bool
    let merchantCity: String?
    let merchantState: String?
    let runningBalance: Double?

    init(raw: RawTransaction, accountId: String, index: Int) {
        self.accountId = accountId
        isPending = raw.transactionCategory == "pending"
        date = raw.postedDate
        runningBalance = raw.runningBalance.flatMap(Double.init)
        merchantCity = raw.merchantCity?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        merchantState = raw.merchantState?.trimmingCharacters(in: .whitespaces).nilIfEmpty

        if isPending {
            if let debit = raw.totalTransactionDebitAmount.flatMap(Double.init) {
                amount = -debit
            } else if let credit = raw.postedTransactionCreditAmount.flatMap(Double.init) {
                amount = credit
            } else {
                amount = 0
            }
            name = raw.transactionTypeDesc ?? raw.transactionType ?? raw.memo?.trimmingCharacters(in: .whitespaces) ?? "Pending"
            transactionType = raw.transactionType ?? ""
            id = "\(accountId)_p_\(date)_\(transactionType)_\(index)"
        } else {
            amount = Double(raw.transactionAmount ?? "0") ?? 0
            name = raw.payeeName?.trimmingCharacters(in: .whitespaces) ?? raw.transactionTypeDescription ?? "Transaction"
            transactionType = raw.transactionTypeDescription ?? ""
            id = raw.imageId ?? "\(accountId)_h_\(date)_\(raw.referenceNumber ?? "")_\(index)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
