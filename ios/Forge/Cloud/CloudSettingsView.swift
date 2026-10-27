import SwiftUI

/// Connect a Supabase project, sign in with an email code, and see sync status.
/// Uses system Form styling only (the design system arrives in Phase 3.5).
struct CloudSettingsView: View {
    @Environment(CloudSync.self) private var cloud
    @Environment(AppModel.self) private var model
    @State private var url = ""
    @State private var anonKey = ""
    @State private var email = ""
    @State private var code = ""
    @State private var busy = false
    @State private var confirmDisconnect = false

    private let providers = [("hevy", "Hevy"), ("healthkit", "Apple Health")]

    var body: some View {
        Form {
            switch cloud.auth {
            case .notConfigured: connectSection
            case .signedOut: emailSection
            case .codeSent(let address): codeSection(address)
            case .signedIn(let address): signedInSections(address)
            }
            if let error = cloud.lastError {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Cloud sync")
        .disabled(busy)
        .confirmationDialog("Disconnect this Supabase project?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { run { await cloud.resetConfiguration() } }
        } message: {
            Text("Your cloud data stays in Supabase. Data on this phone is not affected.")
        }
    }

    // MARK: Sections

    private var connectSection: some View {
        Section {
            TextField("https://abcd1234.supabase.co", text: $url)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Anon public key", text: $anonKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Connect") { cloud.configure(url: url, anonKey: anonKey) }
                .disabled(url.isEmpty || anonKey.isEmpty)
        } header: {
            Text("Supabase project")
        } footer: {
            Text("Supabase → Project Settings → API. Use the anon (publishable) key, never the service_role key.")
        }
    }

    private var emailSection: some View {
        Section {
            TextField("Email", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Send code") { run { await cloud.sendCode(email: email) } }
                .disabled(!email.contains("@"))
        } header: {
            Text("Sign in")
        } footer: {
            Text("We'll email you a 6-digit code.")
        }
    }

    private func codeSection(_ address: String) -> some View {
        Section {
            TextField("6-digit code", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
            Button("Sign in") { run { await cloud.verify(code: code); code = "" } }
                .disabled(code.count < 6)
            Button("Use a different email") { cloud.cancelCode() }
        } header: {
            Text("Code sent to \(address)")
        }
    }

    @ViewBuilder
    private func signedInSections(_ address: String) -> some View {
        Section("Account") {
            LabeledContent("Signed in", value: address)
        }
        Section {
            ForEach(providers, id: \.0) { provider, name in
                let status = cloud.statuses[provider]
                VStack(alignment: .leading, spacing: 2) {
                    LabeledContent(name, value: status?.state ?? "Waiting")
                    if let s = status, !s.detail.isEmpty {
                        Text(s.lastSynced.map { "\(s.detail) · \($0.formatted(.relative(presentation: .named)))" } ?? s.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Button {
                Task { await cloud.push(from: model) }
            } label: {
                HStack {
                    Text("Sync now")
                    Spacer()
                    if cloud.isSyncing { ProgressView() }
                }
            }
            .disabled(cloud.isSyncing || model.demoMode)
        } header: {
            Text("Integrations")
        } footer: {
            if model.demoMode {
                Text("Sample data is never uploaded. Add your Hevy key in Settings to sync real data.")
            } else {
                Text("Syncs on launch and after every refresh.")
            }
        }
        Section {
            Button("Sign out", role: .destructive) { run { await cloud.signOut() } }
            Button("Disconnect project", role: .destructive) { confirmDisconnect = true }
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        busy = true
        Task {
            await work()
            busy = false
        }
    }
}

#Preview("Light") {
    NavigationStack { CloudSettingsView() }
        .environment(CloudSync())
        .environment(AppModel())
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    NavigationStack { CloudSettingsView() }
        .environment(CloudSync())
        .environment(AppModel())
        .preferredColorScheme(.dark)
}
