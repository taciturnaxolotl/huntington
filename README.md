# huntington::neo

A native iOS client for Huntington Bank, built by reverse-engineering the private mobile API used by the official Android/iOS apps.

The canonical repo for this is hosted on tangled over at [`dunkirk.sh/huntington`](https://tangled.org/dunkirk.sh/huntington)

## API

All API traffic goes through `m.huntington.com`. There are two namespaces:

- `/api/mobile-authentication/1.8/` — auth flow (login, OTP, device registration)
- `/api/mobile-customer-accounts/1.11/` — account data (balances, transactions)

### Authentication

Every authenticated request requires two things:

- Session cookies `PD-ID` and `PD-S-SESSION-ID` (set by IBM Security Verify / DataPower after login)
- An `x-auth-receipt` header — a short-lived rolling token issued by the auth layer

The receipt **rotates on every response**: each API call returns a new `x-auth-receipt` that must be used for the next call. Using a stale receipt yields a 401.

#### Headers (all requests)

| Header           | Value                                  |
| ---------------- | -------------------------------------- |
| `x-channel`      | `MOBILE`                               |
| `x-context-id`   | UUID generated per session (lowercase) |
| `x-auth-receipt` | Rolling receipt token                  |
| `user-agent`     | `HuntingtonMobileBankingIOS/6.74.115`  |

#### Login flow (new device / OTP required)

```
POST /api/mobile-authentication/1.8/mobile-init
  body: {}
  → 201

POST /pkmslogin.form
  body: login-form-type=pwd&userName=...&password=...
  → 302 (sets PD-ID, PD-S-SESSION-ID cookies)

GET /api/mobile-authentication/1.8/contexts/{ctx}/authentication-receipt
  ?olbLoginId={username}&loginType=USER_PASS
  → 200, x-auth-receipt header, body: { customerId }

POST /api/mobile-authentication/1.8/contexts/{ctx}/second-factors
  body: { fingerprint, olbLoginId, policy: "ANDROID", profile: "MOBILE",
          deviceId, token, fraudSessionId, loginType, flowId }
  → 201, body: { secondFactorId, passed, registrationData }
  # passed=true → skip to activate-customer (trusted device)
  # passed=false → OTP required

GET /api/mobile-authentication/1.8/contexts/{ctx}/second-factors/{sfId}/otp/delivery-options
  → 200, body: { phoneNumbers: [{id, value}], emailAddresses: [{id, value}] }

PUT /api/mobile-authentication/1.8/contexts/{ctx}/second-factors/{sfId}/otp/delivery-options/{optionId}
  body: {}
  → 200 (sends OTP to selected phone/email)

PUT /api/mobile-authentication/1.8/contexts/{ctx}/second-factors/{sfId}/otp/status
  body: { otpValue: "123456", flowId: "" }
  → 200, body: { passed: true }, rotates x-auth-receipt

GET /api/mobile-authentication/1.8/contexts/{ctx}/second-factors/{sfId}/v2/ia-challenge-question
  → 200, body: {} (no challenge), rotates x-auth-receipt again

POST /api/mobile-customer-accounts/1.11/contexts/{ctx}/customers/{customerId}/customers
  body: { secondFactorId, fraudSessionId }
  → 201, body: { customer: { customerId, name, ... } }

POST /api/mobile-authentication/1.8/contexts/{ctx}/second-factors/{sfId}/registrations
  body: { deviceName: "iPhone" }
  → 201, body: { registrationData: { token } }
  # Save token — used in future second-factors calls to skip OTP
```

#### Login flow (trusted device, `passed=true`)

Same as above through `second-factors`, then jump straight to `activate-customer`. No OTP, no `ia-challenge-question`.

### Account data

```
GET /api/mobile-customer-accounts/1.11/contexts/{ctx}/customers/{customerId}/accounts
  ?refresh=false
  → 200, body: { groups: [{ accountCategory, accounts: [{ accountId, accountType,
                              nickName, availableBalance, currentBalance,
                              maskedAccountNumber, routingNumber }] }] }

GET /api/mobile-customer-accounts/1.11/contexts/{ctx}/customers/{customerId}/last-login
  → 200, body: { lastLogin: "2026-03-31T20:12:45.043Z" }

GET /api/mobile-customer-accounts/1.11/contexts/{ctx}/customers/{customerId}/customer-contacts
  → 200, body: { baseContacts: { postalAddress, phoneNumbers, emailId },
                  alertContacts: { alertEmails, alertPhones } }

GET /api/mobile-customer-accounts/1.11/contexts/{ctx}/customers/{customerId}/customer-custom-attribute
  → 200, body: feature flag map (UI state, onboarding flags, badge counts)
```

### Transactions

There are three transaction endpoints per account, each returning a different slice:

```
# Combined posted + pending (most recent page, no date filter)
GET /api/mobile-customer-accounts/1.11/contexts/{ctx}/customers/{customerId}/deposits/{accountId}/transactions
  → 200, body: { items: [...] }
  # items have transactionCategory: "history" or "pending"
  # Returns a cursor in the last item for pagination (see below)

# Paginate further back using a cursor from the previous response
GET /api/mobile-customer-accounts/1.11/contexts/{ctx}/customers/{customerId}/deposits/{accountId}/transactions
  ?textRecordControl={cursor}
  → 200, body: { items: [...] }

# Posted transactions only (savings/interest accounts use this endpoint)
GET /api/mobile-customer-accounts/1.11/contexts/{ctx}/customers/{customerId}/deposits/{accountId}/transaction-history
  → 200, body: { items: [...] }

# Pending transactions only
GET /api/mobile-customer-accounts/1.11/contexts/{ctx}/customers/{customerId}/deposits/{accountId}/v2/pending-transactions
  → 200, body: { items: [...], inProcessTransactionExists, overdraftIndicator,
                  idaResponse: { totalIdaAmount, defaultIdaAmount, ... } }
```

The `textRecordControl` cursor is an opaque string embedded in the transaction data — it encodes account number, account type, and date boundaries for the next page. Pass it verbatim to fetch the next batch.

#### Posted transaction fields

| Field                            | Description                               |
| -------------------------------- | ----------------------------------------- |
| `transactionCategory`            | `"history"` or `"pending"`                |
| `transactionAmount`              | Amount as string (always positive)        |
| `runningBalance`                 | Balance after this transaction            |
| `postedDate`                     | `YYYY-MM-DD`                              |
| `payeeName`                      | Merchant/payee name (posted)              |
| `transactionTypeDescription`     | e.g. `"Direct Deposit"`, `"Transfer"`     |
| `imageId`                        | Opaque ID (used as stable transaction ID) |
| `referenceNumber`                | Bank reference number                     |
| `memos`                          | Array of memo strings                     |
| `merchantCity` / `merchantState` | Card transaction location                 |
| `oysa.isZelleTransaction`        | Whether this is a Zelle transfer          |

#### Pending transaction fields

| Field                                     | Description            |
| ----------------------------------------- | ---------------------- |
| `transactionType` / `transactionTypeDesc` | Type description       |
| `totalTransactionDebitAmount`             | Debit amount (string)  |
| `postedTransactionCreditAmount`           | Credit amount (string) |
| `memo`                                    | Memo string            |

### Notes

- The `x-context-id` UUID must be **lowercase** — uppercase UUIDs cause 500 errors on `otp/status`
- `second-factors` must use `policy: "ANDROID"` — the `"IOS"` policy path has a server-side bug that causes 500 on `otp/status`
- `pkmslogin.form` uses HTTP/2 and occasionally resets the connection (-1005); retry with a fresh context ID
- Session state (context ID, receipt, customer ID, cookies) can be persisted and reused across app launches — validate by hitting the accounts endpoint on startup
- The transactions endpoint returns a rolling window of recent items (not a fixed 30-day window); use `textRecordControl` pagination to go further back
- The `transactions` endpoint mixes posted and pending; `transaction-history` and `v2/pending-transactions` split them out separately

<p align="center">
    <img src="https://raw.githubusercontent.com/taciturnaxolotl/carriage/main/.github/images/line-break.svg" />
</p>

<p align="center">
    <i><code>&copy; 2026-present <a href="https://dunkirk.sh">Kieran Klukas</a></code></i>
</p>

<p align="center">
    <a href="https://tangled.org/dunkirk.sh/huntington/blob/main/LICENSE.md"><img src="https://img.shields.io/static/v1.svg?style=for-the-badge&label=License&message=O'Saasy&logoColor=d9e0ee&colorA=363a4f&colorB=b7bdf8"/></a>
</p>
