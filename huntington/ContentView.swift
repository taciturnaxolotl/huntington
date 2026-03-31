import SwiftUI

struct ContentView: View {
    @StateObject private var session = HuntingtonSession()
    @State private var accounts: [Account] = []
    @State private var transactions: [Transaction] = []
    @State private var showLogin = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var client: HuntingtonClient { HuntingtonClient(session: session) }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading…")
                } else if let error = errorMessage {
                    ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                } else if !session.isAuthenticated {
                    ContentUnavailableView("Not Signed In", systemImage: "lock",
                        description: Text("Tap Sign In to connect your Huntington account."))
                } else {
                    List {
                        if !accounts.isEmpty {
                            Section("Accounts") {
                                ForEach(accounts) { acct in
                                    NavigationLink(destination: AccountDetailView(account: acct, allTransactions: transactions)) {
                                        AccountRow(account: acct)
                                    }
                                }
                            }
                        }
                        if !transactions.isEmpty {
                            Section("Last 30 Days") {
                                ForEach(transactions) { tx in
                                    NavigationLink(destination: TransactionDetailView(transaction: tx, accounts: accounts)) {
                                        TransactionRow(transaction: tx)
                                    }
                                }
                            }
                        }
                    }
                    .refreshable { await loadData() }
                }
            }
            .navigationTitle("Huntington")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if session.isAuthenticated {
                        Button("Sign Out", role: .destructive) { session.signOut() }
                    } else {
                        Button("Sign In") { showLogin = true }
                    }
                }
            }
        }
        // Hidden WKWebView kept in hierarchy for API calls
        .background(WebViewRepresentable(webView: session.webView).frame(width: 0, height: 0))
        .sheet(isPresented: $showLogin) {
            LoginView(session: session)
        }
        .task {
            await session.initialize()
            if session.isAuthenticated {
                await loadData()
            } else {
                showLogin = true
            }
        }
        .onChange(of: session.isAuthenticated) { _, authenticated in
            if authenticated { Task { await loadData() } }
        }
    }

    private func loadData() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response = try await client.getAccounts()
            accounts = response.result.entities
                .flatMap { $0.userConnection.accounts }
                .filter { $0.active && !$0.closed }
            transactions = try await client.getRecentTransactions(accounts: accounts)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Rows

struct AccountRow: View {
    let account: Account

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.alias).fontWeight(.medium)
                Text(account.number).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(account.availableBalance, format: .currency(code: "USD"))
                .fontWeight(.semibold)
        }
    }
}

struct TransactionRow: View {
    let transaction: Transaction

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.name).lineLimit(1)
                Text(transaction.date).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(transaction.amount, format: .currency(code: "USD"))
                .foregroundStyle(transaction.amount >= 0 ? .green : .primary)
        }
    }
}

struct AccountDetailView: View {
    let account: Account
    let allTransactions: [Transaction]

    private var transactions: [Transaction] {
        allTransactions.filter { $0.accId == account.id }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Text(account.availableBalance, format: .currency(code: "USD"))
                            .font(.system(size: 36, weight: .semibold))
                        Text("Available Balance")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if account.availableBalance != account.balance {
                            Text("\(account.balance, format: .currency(code: "USD")) current")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .padding(.vertical, 8)
            }

            Section("Account Info") {
                LabeledContent("Account", value: account.number)
                LabeledContent("Type", value: account.huntingtonType)
            }

            if transactions.isEmpty {
                Section("Transactions") {
                    Text("No transactions in the last 30 days")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Last 30 Days (\(transactions.count))") {
                    ForEach(transactions) { tx in
                        NavigationLink(destination: TransactionDetailView(transaction: tx, accounts: [account])) {
                            TransactionRow(transaction: tx)
                        }
                    }
                }
            }
        }
        .navigationTitle(account.alias)
        .navigationBarTitleDisplayMode(.large)
    }
}

struct TransactionDetailView: View {
    let transaction: Transaction
    let accounts: [Account]

    private var account: Account? {
        accounts.first { $0.id == transaction.accId }
    }

    private var isCredit: Bool { transaction.amount >= 0 }

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Text(transaction.amount, format: .currency(code: "USD"))
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(isCredit ? .green : .primary)
                        Text(transaction.transactionType.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .padding(.vertical, 8)
            }

            Section("Details") {
                LabeledContent("Date", value: transaction.date)
                LabeledContent("Name", value: transaction.name)
                if let account {
                    LabeledContent("Account", value: "\(account.alias) \(account.number)")
                }
                LabeledContent("Type", value: isCredit ? "Credit" : "Debit")
                LabeledContent("Transaction ID", value: String(transaction.id))
            }
        }
        .navigationTitle(transaction.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    ContentView()
}
