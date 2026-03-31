# huntington::neo

A native iOS client for Huntington Bank, built by reverse-engineering the private mobile API used by the official Android/iOS apps.

The canonical repo for this is hosted on tangled over at [`dunkirk.sh/huntington`](https://tangled.org/dunkirk.sh/huntington)

<p align="center">
    <img src="https://raw.githubusercontent.com/taciturnaxolotl/carriage/main/.github/images/line-break.svg" />
</p>

## API

All traffic goes to `m.huntington.com` under two namespaces:

- `mobile-authentication/1.8` — login, OTP, device registration
- `mobile-customer-accounts/1.11` — accounts, balances, transactions

### Session model

Every authenticated request needs two things:

- **Cookies** — `PD-ID` and `PD-S-SESSION-ID`, set by IBM Security Verify after login
- **`x-auth-receipt`** — a rolling token that the server rotates on every response; using a stale one yields a 401

All requests also carry:

| Header | Value |
| --- | --- |
| `x-channel` | `MOBILE` |
| `x-context-id` | lowercase UUID, generated once per session |
| `x-auth-receipt` | current receipt token |
| `user-agent` | `HuntingtonMobileBankingIOS/6.74.115` |

### Login

#### Step 1 — establish session

```
POST /api/mobile-authentication/1.8/mobile-init
  body: {}
  → 201

POST /pkmslogin.form
  content-type: application/x-www-form-urlencoded
  body: login-form-type=pwd&userName=…&password=…
  → 302  (sets PD-ID, PD-S-SESSION-ID cookies)

GET /api/mobile-authentication/1.8/contexts/{ctx}/authentication-receipt
  ?olbLoginId={username}&loginType=USER_PASS
  → 200  x-auth-receipt: <token>
         body: { customerId }
```

#### Step 2 — device check

```
POST /api/mobile-authentication/1.8/contexts/{ctx}/second-factors
  body: {
    olbLoginId, policy: "ANDROID", profile: "MOBILE",
    deviceId, token,          ← persisted device identity; empty string on first run
    fraudSessionId,           ← random UUID, no dashes
    loginType: "USER_PASS", flowId: "",
    fingerprint: { attributes: { os, osname, numberOfProcessors, localeName, rooted, appVersion } }
  }
  → 201  body: { secondFactorId, passed, registrationData: { token } }
```

`passed: true` means the device is trusted — skip to [activate](#step-4--activate). `passed: false` means OTP is required.

> **Note:** `policy` must be `"ANDROID"`. The `"IOS"` value triggers a server bug that causes 500s on `otp/status`.

#### Step 3 — OTP (new device only)

```
GET  /api/mobile-authentication/1.8/contexts/{ctx}/second-factors/{sfId}/otp/delivery-options
  → 200  body: { phoneNumbers: [{id, value}], emailAddresses: [{id, value}] }

PUT  /api/mobile-authentication/1.8/contexts/{ctx}/second-factors/{sfId}/otp/delivery-options/{optionId}
  body: {}
  → 200  (triggers SMS or email with code)

PUT  /api/mobile-authentication/1.8/contexts/{ctx}/second-factors/{sfId}/otp/status
  body: { otpValue: "123456", flowId: "" }
  → 200  body: { passed: true }  x-auth-receipt: <rotated>

GET  /api/mobile-authentication/1.8/contexts/{ctx}/second-factors/{sfId}/v2/ia-challenge-question
  → 200  body: {}  x-auth-receipt: <rotated again>
```

The receipt rotates twice through OTP verification — `otp/status` rotates it once, `ia-challenge-question` rotates it again. Use the receipt from `ia-challenge-question` for the activate call.

#### Step 4 — activate

```
POST /api/mobile-customer-accounts/1.11/contexts/{ctx}/customers/{customerId}/customers
  body: { secondFactorId, fraudSessionId }
  → 201  body: { customer: { customerId, customerType, name, displayName } }
```

#### Step 5 — register device (background, OTP path only)

```
POST /api/mobile-authentication/1.8/contexts/{ctx}/second-factors/{sfId}/registrations
  body: { deviceName: "iPhone" }
  → 201  body: { registrationData: { deviceId, token } }
```

Save the `token` — pass it in `second-factors` on future logins to skip OTP.

### Accounts

```
GET /api/mobile-customer-accounts/1.11/contexts/{ctx}/customers/{customerId}/accounts?refresh=false
  → 200  body: {
    groups: [{
      accountCategory,   ← e.g. "CASH"
      accounts: [{
        accountId, accountType, nickName,
        availableBalance, currentBalance,
        maskedAccountNumber, routingNumber
      }]
    }]
  }
```

### Customer info

```
GET …/customers/{customerId}/last-login
  → 200  body: { lastLogin: "2026-03-31T20:12:45.043Z" }

GET …/customers/{customerId}/customer-contacts
  → 200  body: {
    baseContacts: { postalAddress, phoneNumbers: { cellPhone }, emailId },
    alertContacts: { alertEmails, alertPhones }
  }
```

### Transactions

Three endpoints per account, each a different slice:

```
# Recent posted + pending transactions (paginated)
GET …/deposits/{accountId}/transactions
GET …/deposits/{accountId}/transactions?textRecordControl={cursor}
  → 200  body: { items: [...] }
  # transactionCategory: "history" | "pending"

# Posted transactions only (savings/interest accounts)
GET …/deposits/{accountId}/transaction-history
  → 200  body: { items: [...] }

# Pending transactions only
GET …/deposits/{accountId}/v2/pending-transactions
  → 200  body: {
    items: [...],
    inProcessTransactionExists,
    overdraftIndicator,
    idaResponse: { totalIdaAmount, defaultIdaAmount, remainingAmount, … }
  }
```

The `textRecordControl` cursor is an opaque string returned by the server — it encodes account number, type, and date range for the next page. Pass it verbatim to page back through history.

#### Transaction fields

Posted (`transactionCategory: "history"`):

| Field | Notes |
| --- | --- |
| `transactionAmount` | Always positive (string) |
| `runningBalance` | Balance after this transaction (string) |
| `postedDate` | `YYYY-MM-DD` |
| `payeeName` | Merchant/payee name |
| `transactionTypeDescription` | e.g. `"Direct Deposit"`, `"Transfer"` |
| `imageId` | Stable transaction ID |
| `memos` | Array of memo strings |
| `merchantCity` / `merchantState` | Card transaction location |
| `oysa.isZelleTransaction` | Whether this is a Zelle transfer |

Pending (`transactionCategory: "pending"`):

| Field | Notes |
| --- | --- |
| `transactionType` / `transactionTypeDesc` | Type description |
| `totalTransactionDebitAmount` | Debit amount (string) |
| `postedTransactionCreditAmount` | Credit amount (string) |
| `memo` | Memo string |

### Gotchas

- `x-context-id` must be **lowercase** — uppercase UUIDs cause 500s on `otp/status`
- `pkmslogin.form` occasionally resets the HTTP/2 connection (NSURLError -1005); retry with a fresh context ID
- Session state (context ID, receipt, customer ID, cookies) survives app restarts — validate on launch by hitting the accounts endpoint

<p align="center">
    <img src="https://raw.githubusercontent.com/taciturnaxolotl/carriage/main/.github/images/line-break.svg" />
</p>

<p align="center">
    <i><code>&copy; 2026-present <a href="https://dunkirk.sh">Kieran Klukas</a></code></i>
</p>

<p align="center">
    <a href="https://tangled.org/dunkirk.sh/huntington/blob/main/LICENSE.md"><img src="https://img.shields.io/static/v1.svg?style=for-the-badge&label=License&message=O'Saasy&logoColor=d9e0ee&colorA=363a4f&colorB=b7bdf8"/></a>
</p>
