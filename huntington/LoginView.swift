import SwiftUI
import WebKit

struct LoginView: View {
    @ObservedObject var session: HuntingtonSession
    @Environment(\.dismiss) var dismiss
    @State private var isCompleting = false

    var body: some View {
        NavigationStack {
            WebViewRepresentable(webView: session.webView)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Sign In")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            isCompleting = true
                            Task {
                                await session.completeLogin()
                                isCompleting = false
                                dismiss()
                            }
                        }
                        .disabled(isCompleting)
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .task { await session.startLogin() }
        .onChange(of: session.loginDidComplete) { _, completed in
            if completed { dismiss() }
        }
    }
}

struct WebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
