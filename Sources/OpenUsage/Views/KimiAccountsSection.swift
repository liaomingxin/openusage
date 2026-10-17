import SwiftUI

struct KimiAccountsSection: View {
    let store: KimiAccountsStore

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @State private var isAdding = false
    @State private var label = ""
    @State private var region = "cn"
    @State private var apiKey = ""
    @State private var revealKey = false
    @State private var accountToRemove: KimiAccountConfiguration?
    @State private var isConfirmingRemoval = false
    @State private var actionError: String?

    var body: some View {
        SectionCard("Kimi Accounts") {
            ControlRow("Default Kimi CLI") {
                Text("Automatic")
                    .font(captionFont)
                    .foregroundStyle(.secondary)
            }
            CardCaption(text: "Added or removed account cards take effect after you restart OpenUsage.")

            if let loadError = store.loadError {
                CardCaption(text: loadError, tint: AnyShapeStyle(Theme.notice))
            }

            ForEach(store.accounts) { account in
                Divider()
                accountRow(account)
            }

            Divider()
            ControlRow("Additional Account") {
                Button(isAdding ? "Cancel" : "Add Account…") {
                    isAdding.toggle()
                    resetDraft()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.loadError != nil)
            }

            if isAdding {
                Divider()
                addAccountForm
            }

            if let actionError {
                CardCaption(text: actionError, tint: AnyShapeStyle(Theme.notice))
            }
        }
        .alert("Remove Kimi Account?", isPresented: $isConfirmingRemoval, presenting: accountToRemove) { account in
            Button("Remove Account", role: .destructive) {
                remove(account)
            }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            Text("Remove \(account.label) from OpenUsage after restart? Its saved API key will be deleted.")
        }
        .onDisappear {
            apiKey = ""
            revealKey = false
        }
    }

    private var captionFont: Font { .system(size: density.captionPointSize) }

    private func accountRow(_ account: KimiAccountConfiguration) -> some View {
        ControlRow {
            VStack(alignment: .leading, spacing: 4) {
                ControlRowLabel(title: account.label)
                Text("API Key · \(regionTitle(account.region))")
                    .font(captionFont)
                    .foregroundStyle(.secondary)
            }
        } control: {
            Button("Remove…", role: .destructive) {
                accountToRemove = account
                isConfirmingRemoval = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Remove \(account.label)")
            .disabled(store.loadError != nil)
        }
    }

    private var addAccountForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            ControlRow("API Key") {
                keyInput
                    .frame(maxWidth: 240)
            }
            ControlRow("Name (Optional)") {
                TextField("Account Name", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .accessibilityLabel("Account Name")
            }
            ControlRow("Region") {
                Picker("Region", selection: $region) {
                    Text("China (api.kimi.com)").tag("cn")
                    Text("Global (api.kimi.ai)").tag("global")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }

            CardCaption(text: "Use a Kimi Coding Plan API key, not a Moonshot Open Platform key.")

            ControlRow("") {
                Button("Add Account") { addAccount() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!canAdd || store.loadError != nil)
            }
        }
    }

    private var keyInput: some View {
        HStack(spacing: 4) {
            Group {
                if revealKey {
                    TextField("Kimi Coding Plan API Key", text: $apiKey)
                } else {
                    SecureField("Kimi Coding Plan API Key", text: $apiKey)
                }
            }
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Kimi Coding Plan API Key")
            Button {
                revealKey.toggle()
            } label: {
                Image(systemName: revealKey ? "eye.slash" : "eye")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(revealKey ? "Hide API Key" : "Show API Key")
        }
    }

    private var canAdd: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }


    private func regionTitle(_ region: String) -> String {
        region == "global" ? "Global" : "China"
    }


    private func addAccount() {
        do {
            try store.addAPIKey(label: label, key: apiKey, region: region)
            isAdding = false
            resetDraft()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func remove(_ account: KimiAccountConfiguration) {
        do {
            try store.remove(id: account.id)
            isAdding = false
            resetDraft()
        } catch {
            actionError = error.localizedDescription
        }
        accountToRemove = nil
    }

    private func resetDraft() {
        label = ""
        apiKey = ""
        revealKey = false
        actionError = nil
    }
}
