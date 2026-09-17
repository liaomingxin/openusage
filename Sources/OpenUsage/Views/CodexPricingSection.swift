import SwiftUI

/// A local estimation preference, separate from the model used by the coding client.
struct CodexPricingSection: View {
    @Environment(WidgetDataStore.self) private var dataStore
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @AppStorage(CodexFallbackModelSetting.key) private var selectedModel = CodexFallbackModelSetting.none
    @State private var options: [PricingFallbackOption] = []
    @State private var isLoading = true
    @State private var isApplying = false
    @State private var refreshState = CodexFallbackPricingRefreshState()
    @State private var needsRecalculation = false

    var body: some View {
        SectionCard("Cost Estimates") {
            ControlRow("Fallback Model") {
                Picker("Fallback Model", selection: $selectedModel) {
                    Text("None").tag(CodexFallbackModelSetting.none)
                    if selectionUnavailable {
                        Text("Unavailable Model").tag(selectedModel)
                    }
                    ForEach(options) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(activityLabel != nil)
            }
            if let activityLabel {
                HStack(spacing: 6) {
                    MotionAwareProgressView(controlSize: .mini)
                        .accessibilityHidden(true)
                    Text(activityLabel)
                }
                .font(.system(size: density.captionPointSize))
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .padding(.horizontal, Theme.cardRowInset)
                .padding(.bottom, 8)
            }
            CardCaption(text: "Estimate costs for models that don't have known pricing.")
            if selectionUnavailable && !isLoading {
                CardCaption(
                    text: "This model's pricing is unavailable. Choose another model or None.",
                    tint: Theme.notice
                )
            }
        }
        .task {
            options = await ModelPricingStore.shared.current().fallbackOptions(for: "codex")
            guard !Task.isCancelled else { return }
            isLoading = false
            recalculateIfNeeded()
            await ModelPricingStore.shared.refreshNow()
            guard !Task.isCancelled else { return }
            options = await ModelPricingStore.shared.current().fallbackOptions(for: "codex")
            recalculateIfNeeded()
        }
        .onChange(of: selectedModel) {
            guard !isLoading else { return }
            recalculateIfNeeded()
        }
    }

    private func recalculateIfNeeded() {
        guard refreshState.update(model: selectedModel, options: options) else { return }
        needsRecalculation = true
        guard !isApplying else { return }
        isApplying = true
        Task {
            defer { isApplying = false }
            while needsRecalculation {
                needsRecalculation = false
                // A refresh already in flight may have captured the previous preference.
                // Wait for it before requesting a new pass instead of having that pass skipped.
                while dataStore.refreshingProviderIDs.contains("codex") {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                }
                dataStore.clearFailureBackoff(for: "codex")
                await dataStore.refresh(providerID: "codex", force: true)
            }
        }
    }

    private var selectionUnavailable: Bool {
        !selectedModel.isEmpty && !options.contains { $0.id == selectedModel }
    }

    private var activityLabel: String? {
        if isLoading { return "Loading Models…" }
        if isApplying { return "Recalculating Estimates…" }
        return nil
    }
}
