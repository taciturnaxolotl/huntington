import SwiftUI

struct LoginView: View {
    var session: HuntingtonSession
    @Environment(\.dismiss) var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var otp = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var deliveryOptions: [HuntingtonSession.OTPDeliveryOption] = []
    @State private var phase: Phase = .credentials

    enum Phase { case credentials, deliverySelection, codeEntry }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "building.columns.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.accentColor)
                    NeoWordmark(font: .title2.bold())
                    Text(headerSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .animation(.default, value: phase)
                }
                .padding(.top, 48)
                .padding(.bottom, 40)

                switch phase {
                case .credentials:
                    credentialsBody
                case .deliverySelection:
                    deliveryBody
                case .codeEntry:
                    codeEntryBody
                }

                // Error
                if let error = errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                        Text(error).font(.footnote)
                    }
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                }

                if phase != .credentials {
                    Button("Back") {
                        phase = phase == .codeEntry ? .deliverySelection : .credentials
                        errorMessage = nil
                    }
                    .padding(.top, 12)
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

            }
            .contentShape(Rectangle())
            .onTapGesture { hideKeyboard() }
        }
    }

    private var headerSubtitle: String {
        switch phase {
        case .credentials: return "Sign in to your account"
        case .deliverySelection: return "How would you like to receive\nyour verification code?"
        case .codeEntry: return "Enter the code we sent you"
        }
    }

    @ViewBuilder
    private var credentialsBody: some View {
        VStack(spacing: 12) {
            inputField(icon: "person", placeholder: "Username") {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            inputField(icon: "lock", placeholder: "Password") {
                SecureField("Password", text: $password)
                    .textContentType(.password)
            }
        }
        .padding(.horizontal, 24)

        Button {
            Task { await signIn() }
        } label: {
            buttonLabel("Sign In")
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accentColor)
        .disabled(isLoading || username.isEmpty || password.isEmpty)
        .padding(.horizontal, 24)
        .padding(.top, 24)
    }

    @ViewBuilder
    private var deliveryBody: some View {
        VStack(spacing: 10) {
            ForEach(deliveryOptions) { option in
                Button {
                    Task { await selectDelivery(option) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: option.isEmail ? "envelope" : "phone")
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24)
                        Text(option.value)
                            .foregroundStyle(.primary)
                        Spacer()
                        if isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                                .font(.caption)
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isLoading)
            }
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var codeEntryBody: some View {
        VStack(spacing: 12) {
            inputField(icon: "key", placeholder: "One-time code") {
                TextField("Code", text: $otp)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
            }
        }
        .padding(.horizontal, 24)

        Button {
            Task { await submitOTP() }
        } label: {
            buttonLabel("Verify")
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accentColor)
        .disabled(isLoading || otp.isEmpty)
        .padding(.horizontal, 24)
        .padding(.top, 24)
    }

    @ViewBuilder
    private func buttonLabel(_ title: String) -> some View {
        Group {
            if isLoading {
                ProgressView().tint(.white)
            } else {
                Text(title).fontWeight(.semibold)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 50)
    }

    @ViewBuilder
    private func inputField<F: View>(icon: String, placeholder: String, @ViewBuilder field: () -> F) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            field()
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func signIn() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await session.beginLogin(username: username, password: password)
            switch result {
            case .success:
                dismiss()
            case .needsDeliverySelection(let options):
                deliveryOptions = options
                phase = .deliverySelection
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func selectDelivery(_ option: HuntingtonSession.OTPDeliveryOption) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await session.selectDelivery(option)
            phase = .codeEntry
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func submitOTP() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await session.submitOTP(otp)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }
}
