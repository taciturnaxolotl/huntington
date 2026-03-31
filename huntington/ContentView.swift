import SwiftUI
import LocalAuthentication

struct ContentView: View {
    @State private var session = HuntingtonSession()
    @State private var accounts: [Account] = []
    @State private var transactions: [Transaction] = []
    @State private var showLogin = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isInitializing = true
    @State private var biometricLocked = false
    @State private var backgroundedAt: Date?
    private let lockTimeout: TimeInterval = 15 * 60

    private var client: HuntingtonClient { HuntingtonClient(session: session) }

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                HomeTab(accounts: accounts, transactions: transactions,
                        isLoading: isLoading, errorMessage: errorMessage,
                        isAuthenticated: session.isAuthenticated,
                        onRefresh: loadData, onSignIn: { showLogin = true })
            }
            Tab("Zelle", systemImage: "arrow.left.arrow.right") {
                ZelleTab()
            }
            Tab("Profile", systemImage: "person.circle") {
                ProfileTab(accounts: accounts, displayName: session.displayName,
                           onSignOut: { session.signOut() })
            }
        }
        .overlay {
            if isInitializing || biometricLocked || scenePhase != .active {
                ZStack {
                    Color(.systemBackground).ignoresSafeArea()
                    NeoWordmark(font: .title.bold())
                }
                .onTapGesture {
                    if biometricLocked { Task { await unlockWithBiometrics() } }
                }
            }
        }
        .sheet(isPresented: $showLogin) {
            LoginView(session: session)
        }
        .task {
            await session.initialize()
            isInitializing = false
            if session.isAuthenticated {
                await unlockWithBiometrics()
            } else {
                showLogin = true
            }
        }
        .onChange(of: session.isAuthenticated) { _, authenticated in
            if authenticated { Task { await loadData() } }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                backgroundedAt = Date()
            case .active:
                if let t = backgroundedAt, Date().timeIntervalSince(t) >= lockTimeout {
                    biometricLocked = true
                    Task { await unlockWithBiometrics() }
                }
                backgroundedAt = nil
            default:
                break
            }
        }
    }

    @Environment(\.scenePhase) private var scenePhase

    private func unlockWithBiometrics() async {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            await loadData()
            return
        }
        biometricLocked = true
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Authenticate to access your accounts")
            if ok {
                biometricLocked = false
                await loadData()
            }
        } catch {
            // Biometrics failed or cancelled — let them try again by tapping
        }
    }

    private func loadData() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            accounts = try await client.getAccounts()
            transactions = try await client.getRecentTransactions(accounts: accounts)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Tabs

struct HomeTab: View {
    let accounts: [Account]
    let transactions: [Transaction]
    let isLoading: Bool
    let errorMessage: String?
    let isAuthenticated: Bool
    let onRefresh: () async -> Void
    let onSignIn: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading…")
                } else if let error = errorMessage {
                    ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                } else if !isAuthenticated {
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
                            Section("Recent") {
                                ForEach(transactions) { tx in
                                    NavigationLink(destination: TransactionDetailView(transaction: tx, accounts: accounts)) {
                                        TransactionRow(transaction: tx)
                                    }
                                }
                            }
                        }
                    }
                    .refreshable { await onRefresh() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { NeoWordmark() }
                if !isAuthenticated {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Sign In", action: onSignIn)
                    }
                }
            }
        }
    }
}

struct ZelleTab: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Zelle", systemImage: "arrow.left.arrow.right",
                description: Text("Zelle support coming soon."))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { NeoWordmark() }
            }
        }
    }
}

struct ProfileTab: View {
    let accounts: [Account]
    let displayName: String
    let onSignOut: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if !displayName.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            VStack(spacing: 4) {
                                Image(systemName: "person.circle.fill")
                                    .font(.system(size: 56))
                                    .foregroundStyle(.secondary)
                                Text(displayName.capitalized)
                                    .font(.title3.weight(.semibold))
                            }
                            .padding(.vertical, 8)
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    }
                }

                if !accounts.isEmpty {
                    Section("Accounts") {
                        ForEach(accounts) { acct in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(acct.alias).fontWeight(.medium)
                                    Text(acct.accountType).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(acct.number).font(.caption).foregroundStyle(.secondary)
                                    Text("Routing: \(acct.routingNumber)").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }

                Section("App") {
                    Button("Sign Out", role: .destructive, action: onSignOut)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { NeoWordmark() }
            }
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
                HStack(spacing: 4) {
                    Text(transaction.name).lineLimit(1)
                    if transaction.isPending {
                        Text("Pending")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
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
        allTransactions.filter { $0.accountId == account.id }
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
                        if account.availableBalance != account.currentBalance {
                            Text("\(account.currentBalance, format: .currency(code: "USD")) current")
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
                LabeledContent("Type", value: account.accountType)
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
        accounts.first { $0.id == transaction.accountId }
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
                if let city = transaction.merchantCity, let state = transaction.merchantState {
                    LabeledContent("Location", value: "\(city), \(state)")
                } else if let city = transaction.merchantCity {
                    LabeledContent("Location", value: city)
                }
                if let balance = transaction.runningBalance {
                    LabeledContent("Balance After", value: balance, format: .currency(code: "USD"))
                }
                LabeledContent("Transaction ID", value: String(transaction.id))
            }
        }
        .navigationTitle(transaction.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct NeoWordmark: View {
    var font: Font = .headline

    var body: some View {
        HStack(spacing: 0) {
            Text("huntington")
            Text("::").foregroundStyle(Color.accentColor)
            Text("neo")
        }
        .font(font)
        .fontDesign(.monospaced)
    }
}

#Preview {
    ContentView()
}
