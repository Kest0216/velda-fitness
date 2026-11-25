// MARK: - Vault & Settings Pillar View
//
// Central privacy and configuration hub: on-device storage meters, 60-day unsaved recipe cache
// sweeping, weight unit & Cycle tab toggles, BYO-AI provider credentials (Keychain-backed),
// iCloud Drive/CloudKit backups, JSON/Markdown/Text export & import, legal links, and 2-step erase.

import SwiftUI

struct VaultView: View {
    @EnvironmentObject var store: LedgerStore
    @StateObject private var cloudSync = CloudSyncService.shared

    @State private var apiKeyDraft: String = ""
    @State private var confirmSweepPresented: Bool = false
    @State private var confirmOverridePresented: Bool = false
    @State private var pendingOverrideAction: (() -> Void)? = nil
    @State private var pendingConfirm: PendingActionConfirmation? = nil
    @State private var confirmWipeStep1: Bool = false
    @State private var confirmWipeStep2: Bool = false

    @State private var exportDomain: ExportDomain = .all
    @State private var exportFormat: ExportFormat = .json
    @State private var shareItem: IdentifiedShareURL? = nil
    @State private var showJSONImporter: Bool = false
    @State private var showMedicalSources: Bool = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            if let st = store.storage {
                VStack(alignment: .leading, spacing: 22) {
                    vaultHeader(st)
                        .inkWritten(index: 0, epoch: store.inkWriteEpoch)

                    storageMetersSection(st)
                        .inkWritten(index: 1, epoch: store.inkWriteEpoch)

                    preferencesSection(st)
                        .inkWritten(index: 2, epoch: store.inkWriteEpoch)

                    aiProvidersSection
                        .inkWritten(index: 3, epoch: store.inkWriteEpoch)

                    iCloudSection
                        .inkWritten(index: 4, epoch: store.inkWriteEpoch)

                    exportImportSection
                        .inkWritten(index: 5, epoch: store.inkWriteEpoch)

                    aboutLegalWipeSection
                        .inkWritten(index: 6, epoch: store.inkWriteEpoch)
                }
                .padding(.top, 6)
                .padding(.bottom, 56)
            } else {
                InkLoadingQuillView(label: "Checking on-device ledger…")
                    .padding(.top, 24)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .actionConfirmationAlert($pendingConfirm)
        .alert("Override Existing Credential?", isPresented: $confirmOverridePresented) {
            Button("Confirm Override", role: .destructive) {
                pendingOverrideAction?()
                pendingOverrideAction = nil
            }
            Button("Cancel", role: .cancel) {
                pendingOverrideAction = nil
            }
        } message: {
            Text("This replaces your saved \(store.activeAIProvider.displayName) credential in your Apple Keychain. You can test it right away.")
        }
        .alert("Erase All Personal Data?", isPresented: $confirmWipeStep1) {
            Button("Continue…", role: .destructive) {
                confirmWipeStep2 = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes your local workouts, routines, weight, macros, saved meals, recipes, cycle logs, and saved AI credentials.")
        }
        .alert("Final Confirmation: Erase Everything?", isPresented: $confirmWipeStep2) {
            Button("Erase All Data", role: .destructive) {
                store.wipeAllUserData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone unless you exported a JSON backup or synced to your private iCloud.")
        }
        .sheet(item: $shareItem) { item in
            ActivityShareSheet(activityItems: [item.url])
        }
        .sheet(isPresented: $showMedicalSources) {
            MedicalSourcesSheet()
        }
        .fileImporter(
            isPresented: $showJSONImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let first = urls.first {
                store.importJSONFile(from: first)
            }
        }
    }

    // MARK: - Header & On-Device Storage

    private func vaultHeader(_ st: StorageMetrics) -> some View {
        HStack(alignment: .top, spacing: 10) {
            SectionHeaderView(
                title: "Vault & Settings",
                subtitle: "\(formatByteCount(st.appDataBytes).uppercased()) STORED ON THIS DEVICE"
            )

            Spacer()

            Button("Sweep Cache") {
                LedgerHaptics.heavy()
                confirmSweepPresented = true
            }
            .buttonStyle(WarmActionButtonStyle(isActive: false))
            .alert("Sweep Unsaved Recipe Cache?", isPresented: $confirmSweepPresented) {
                Button("Sweep Cache", role: .destructive) {
                    store.sweepClutter()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Clears \(st.cachedRecipeCount) unsaved recipe search result(s). Your workouts, macros, cycle logs, and \(st.savedRecipeCount) saved recipe(s) stay untouched.")
            }
        }
    }

    private func storageMetersSection(_ st: StorageMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            storageBar(
                label: "Personal Journal (\(st.totalSetCount) sets · \(st.macroLogCount) meals · \(st.savedMealCount) saved · \(st.cycleLogCount) cycle days)",
                valueText: formatByteCount(st.dbBytes),
                ratio: Double(st.dbBytes) / Double(2 * 1024 * 1024),
                minRatio: 0.04
            )
            storageBar(
                label: "Saved Photos (\(st.savedMediaFiles))",
                valueText: formatByteCount(st.savedMediaBytes),
                ratio: Double(st.savedMediaBytes) / Double(10 * 1024 * 1024),
                minRatio: 0.04
            )
            storageBar(
                label: "Recipe Search Cache (\(st.cachedRecipeCount))",
                valueText: formatByteCount(st.cacheMediaBytes),
                ratio: Double(st.cacheMediaBytes) / Double(max(1, st.cacheMaxMB) * 1024 * 1024),
                minRatio: 0.02
            )

            HStack {
                Text("OFFLINE EXERCISE DEMOS (\(st.bundleVideoCount) CLIPS)")
                    .font(LedgerFont.sansSm())
                    .tracking(0.8)
                    .foregroundStyle(LedgerColor.inkSecondary)
                Spacer()
                Text(formatByteCount(st.bundleVideoBytes))
                    .font(LedgerFont.sansSm(semibold: true))
                    .monospacedDigit()
                    .foregroundStyle(LedgerColor.inkPrimary)
            }
        }
        .softPanel()
    }

    // MARK: - Preferences

    private func preferencesSection(_ st: StorageMetrics) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeaderView(
                title: "Preferences",
                subtitle: "UNITS, TABS & AUTO-CLEANUP"
            )

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("Weight Unit")
                        .font(LedgerFont.serifMd(semibold: true))
                        .foregroundStyle(LedgerColor.inkPrimary)
                    Spacer()
                    HStack(spacing: 8) {
                        Button("LBS") { store.setWeightUnit("lbs") }
                            .buttonStyle(WarmActionButtonStyle(isActive: st.weightUnit == "lbs"))
                        Button("KG") { store.setWeightUnit("kg") }
                            .buttonStyle(WarmActionButtonStyle(isActive: st.weightUnit == "kg"))
                    }
                }

                Divider().opacity(0.25)

                HStack(spacing: 12) {
                    Text("Cycle Tracker Tab")
                        .font(LedgerFont.serifMd(semibold: true))
                        .foregroundStyle(LedgerColor.inkPrimary)
                    Spacer()
                    HStack(spacing: 8) {
                        Button("On") { store.setCycleTrackingEnabled(true) }
                            .buttonStyle(WarmActionButtonStyle(isActive: store.cycleTrackingEnabled))
                        Button("Off") { store.setCycleTrackingEnabled(false) }
                            .buttonStyle(WarmActionButtonStyle(isActive: !store.cycleTrackingEnabled))
                    }
                }

                Divider().opacity(0.25)

                HStack(alignment: .firstTextBaseline) {
                    Text("Unsaved Recipe Cache")
                        .font(LedgerFont.serifMd(semibold: true))
                        .foregroundStyle(LedgerColor.inkPrimary)
                    Spacer()
                    Text("60 DAYS")
                        .font(LedgerFont.sansSm(semibold: true))
                        .foregroundStyle(LedgerColor.inkPrimary)
                }

                Text("Unsaved recipe searches clear automatically after 60 days. Your saved logs never expire.")
                    .font(LedgerFont.serifMd(italic: true))
                    .foregroundStyle(LedgerColor.inkSecondary)
            }
            .softPanel()
        }
    }

    // MARK: - Your AI Provider

    private var aiProvidersSection: some View {
        let provider = store.activeAIProvider
        let state = store.activeProviderState

        let statusText: String = {
            if state.isVerified { return "CONNECTED & VERIFIED" }
            if state.hasCredential { return "SAVED (\(state.maskedCredential))" }
            return "NOT CONNECTED"
        }()

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                SectionHeaderView(
                    title: "Your AI Provider",
                    subtitle: statusText
                )
                Spacer()
                Circle()
                    .fill(state.isVerified ? LedgerColor.verifiedSage : (state.hasCredential ? LedgerColor.warmAmber : LedgerColor.inkSecondary.opacity(0.4)))
                    .frame(width: 9, height: 9)
                    .padding(.top, 6)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(AIProvider.allCases) { p in
                        let isSelected = provider == p
                        Button {
                            apiKeyDraft = ""
                            store.selectAIProvider(p)
                        } label: {
                            Text(p.displayName)
                        }
                        .buttonStyle(WarmActionButtonStyle(isActive: isSelected, fullWidth: true))
                    }
                }

                HStack(spacing: 8) {
                    Button("API Key") {
                        store.setAuthMode(.apiKey, for: provider)
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: state.authMode == .apiKey, fullWidth: true))

                    if provider == .openai {
                        Button("ChatGPT Sign-In") {
                            store.setAuthMode(.signIn, for: .openai)
                        }
                        .buttonStyle(WarmActionButtonStyle(isActive: state.authMode == .signIn, fullWidth: true))
                    } else if provider == .gemini {
                        Button("Sign In · Soon") {
                            store.showToast("Gemini account sign-in is coming soon — use an API key for now.")
                        }
                        .buttonStyle(WarmActionButtonStyle(isActive: false, fullWidth: true))
                    } else {
                        Button("API Only") {
                            store.showToast("Anthropic currently uses API keys (text & recipe analysis only; no image generation).")
                        }
                        .buttonStyle(WarmActionButtonStyle(isActive: false, fullWidth: true))
                    }
                }

                if provider == .openai && state.authMode == .signIn {
                    if state.hasCredential {
                        Text("Signed in as \(state.accountLabel.isEmpty ? "ChatGPT Account" : state.accountLabel)")
                            .font(LedgerFont.serifMd(semibold: true))
                            .foregroundStyle(LedgerColor.inkPrimary)
                    } else {
                        Text("Sign in with your ChatGPT subscription so no separate API key is needed.")
                            .font(LedgerFont.serifMd(italic: true))
                            .foregroundStyle(LedgerColor.inkSecondary)
                    }

                    HStack(spacing: 8) {
                        if state.isVerified {
                            Button {
                                requestOverride {
                                    Task { await store.signInWithOpenAI() }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text("Switch")
                                }
                            }
                            .buttonStyle(VerifiedActionButtonStyle(fullWidth: true))
                        } else {
                            Button(store.isSigningInOpenAI ? "Signing In…" : "Sign In") {
                                if state.hasCredential {
                                    requestOverride {
                                        Task { await store.signInWithOpenAI() }
                                    }
                                } else {
                                    pendingConfirm = PendingActionConfirmation(
                                        title: "Sign in with ChatGPT?",
                                        message: "Opens Apple's secure web sign-in for your ChatGPT account and stores the session token inside your Apple Keychain.",
                                        confirmLabel: "Continue",
                                        isDestructive: false
                                    ) {
                                        Task { await store.signInWithOpenAI() }
                                    }
                                }
                            }
                            .buttonStyle(PrimaryActionButtonStyle(fullWidth: true))
                            .disabled(store.isSigningInOpenAI)
                        }

                        Button(store.isTestingAI ? "Testing…" : "Test Ping") {
                            pendingConfirm = PendingActionConfirmation(
                                title: "Test OpenAI Connection?",
                                message: "Sends a quick test message to verify your ChatGPT sign-in works.",
                                confirmLabel: "Run Test",
                                isDestructive: false
                            ) {
                                Task { _ = await store.testAIProvider(.openai, draftKey: "") }
                            }
                        }
                        .buttonStyle(WarmActionButtonStyle(isActive: false, fullWidth: true))
                        .disabled(store.isTestingAI || !state.hasCredential)

                        if state.hasCredential {
                            Button("Sign Out") {
                                requestOverride {
                                    store.signOutOpenAI()
                                }
                            }
                            .buttonStyle(WarmActionButtonStyle(isActive: false, fullWidth: true))
                        }
                    }
                } else {
                    SecureField(
                        state.hasCredential ? "Paste new key to replace saved key..." : provider.keyPlaceholder,
                        text: $apiKeyDraft
                    )
                    .font(LedgerFont.sansMd())
                    .foregroundStyle(LedgerColor.inkPrimary)
                    .warmRecessedField()
                    .onSubmit {
                        handleSaveOrOverrideTapped(state: state, provider: provider)
                    }

                    HStack(spacing: 8) {
                        Button(store.isTestingAI ? "Testing…" : "Test Ping") {
                            pendingConfirm = PendingActionConfirmation(
                                title: "Test \(provider.displayName) Connection?",
                                message: "Sends a short test request to verify your \(provider.displayName) key responds normally.",
                                confirmLabel: "Run Test",
                                isDestructive: false
                            ) {
                                Task { _ = await store.testAIProvider(provider, draftKey: apiKeyDraft) }
                            }
                        }
                        .buttonStyle(WarmActionButtonStyle(isActive: false, fullWidth: true))
                        .disabled(store.isTestingAI || (apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !state.hasCredential))

                        if state.isVerified {
                            Button {
                                handleSaveOrOverrideTapped(state: state, provider: provider)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text("Override Key")
                                }
                            }
                            .buttonStyle(VerifiedActionButtonStyle(fullWidth: true))
                        } else {
                            Button("Save Key") {
                                handleSaveOrOverrideTapped(state: state, provider: provider)
                            }
                            .buttonStyle(PrimaryActionButtonStyle(fullWidth: true))
                        }

                        if state.hasCredential {
                            Button("Clear") {
                                requestOverride {
                                    apiKeyDraft = ""
                                    store.clearProviderCredential(for: provider)
                                }
                            }
                            .buttonStyle(WarmActionButtonStyle(isActive: false))
                        }
                    }
                }

                if provider == .anthropic {
                    Text("Note: Anthropic (Claude) supports text, recipes, and macro estimation, but does not generate images.")
                        .font(LedgerFont.serifMd(italic: true))
                        .foregroundStyle(LedgerColor.inkSecondary)
                }

                if let ping = store.lastPingResult, ping.provider == provider {
                    HStack(spacing: 6) {
                        Image(systemName: ping.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(ping.success ? LedgerColor.verifiedSage : LedgerColor.errorRust)
                        Text(ping.message)
                            .font(LedgerFont.sansSm(semibold: ping.success))
                            .foregroundStyle(ping.success ? LedgerColor.verifiedSage : LedgerColor.errorRust)
                    }
                } else if state.isVerified, let ms = state.lastPingLatencyMs {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(LedgerColor.verifiedSage)
                        Text("Verified (\(ms) ms) · Stored in your Apple Keychain")
                            .font(LedgerFont.sansSm())
                            .foregroundStyle(LedgerColor.verifiedSage)
                    }
                } else {
                    Text("Keys stay encrypted in your Apple Keychain on device and sync privately with your Apple ID.")
                        .font(LedgerFont.serifMd(italic: true))
                        .foregroundStyle(LedgerColor.inkSecondary)
                }
            }
            .softPanel()
        }
    }

    private func handleSaveOrOverrideTapped(state: AIProviderConfigState, provider: AIProvider) {
        let clean = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            store.showToast(state.hasCredential ? "Paste a new key above first" : "Paste a valid API key")
            return
        }
        if state.hasCredential {
            requestOverride {
                store.saveOrOverrideAPIKey(clean, for: provider)
                apiKeyDraft = ""
            }
        } else {
            pendingConfirm = PendingActionConfirmation(
                title: "Save \(provider.displayName) Key?",
                message: "Stores this API key encrypted in your Apple Keychain on device.",
                confirmLabel: "Save Key",
                isDestructive: false
            ) {
                store.saveOrOverrideAPIKey(clean, for: provider)
                apiKeyDraft = ""
            }
        }
    }

    private func requestOverride(_ action: @escaping () -> Void) {
        LedgerHaptics.heavy()
        pendingOverrideAction = action
        confirmOverridePresented = true
    }

    // MARK: - Apple iCloud Backup

    private var iCloudSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeaderView(
                title: "Your Apple iCloud",
                subtitle: cloudSync.isCloudKitConfiguredInBuild ? "PRIVATE ICLOUD ENABLED" : "KEYCHAIN & FILES BACKUP"
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("Velda has no servers. Sync straight to your own iCloud Drive or private Apple Cloud storage.")
                    .font(LedgerFont.serifMd(italic: true))
                    .foregroundStyle(LedgerColor.inkSecondary)

                if let syncAt = cloudSync.lastSyncAt {
                    Text("LAST SYNCED: \(syncAt)")
                        .font(LedgerFont.sansSm())
                        .foregroundStyle(LedgerColor.inkPrimary)
                }

                HStack(spacing: 8) {
                    Button(cloudSync.isSyncing ? "Syncing…" : "Sync Now") {
                        Task { await store.syncToICloud() }
                    }
                    .buttonStyle(PrimaryActionButtonStyle(fullWidth: true))
                    .disabled(cloudSync.isSyncing)

                    Button("Pull Copy") {
                        Task { await store.pullFromICloud() }
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: false, fullWidth: true))
                    .disabled(cloudSync.isSyncing)

                    Button("Drive File") {
                        if let url = store.backupToICloudDrive() {
                            shareItem = IdentifiedShareURL(url: url)
                        } else if let fallback = store.prepareExportFile(domain: .all, format: .json) {
                            shareItem = IdentifiedShareURL(url: fallback)
                        }
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: false, fullWidth: true))
                }

                if let err = cloudSync.lastError, !err.isEmpty {
                    Text(err)
                        .font(LedgerFont.sansSm())
                        .foregroundStyle(LedgerColor.inkSecondary)
                }
            }
            .softPanel()
        }
    }

    // MARK: - Data Export & Import

    private var exportImportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeaderView(
                title: "Export & Portability",
                subtitle: "OWN YOUR DATA ANYWHERE"
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("Export any section—or everything at once—for your own records, spreadsheets, or AI tools.")
                    .font(LedgerFont.serifMd(italic: true))
                    .foregroundStyle(LedgerColor.inkSecondary)

                HStack {
                    Text("Section")
                        .font(LedgerFont.serifMd(semibold: true))
                        .foregroundStyle(LedgerColor.inkPrimary)
                    Spacer()
                    Picker("Export Section", selection: $exportDomain) {
                        ForEach(ExportDomain.allCases) { d in
                            Text(d.label).tag(d)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(LedgerColor.inkPrimary)
                }

                HStack(spacing: 8) {
                    ForEach(ExportFormat.allCases) { fmt in
                        Button(fmt.shortLabel) {
                            LedgerHaptics.light()
                            exportFormat = fmt
                        }
                        .buttonStyle(WarmActionButtonStyle(isActive: exportFormat == fmt, fullWidth: true))
                    }
                }

                HStack(spacing: 8) {
                    Button("Export File") {
                        if let url = store.prepareExportFile(domain: exportDomain, format: exportFormat) {
                            shareItem = IdentifiedShareURL(url: url)
                        }
                    }
                    .buttonStyle(PrimaryActionButtonStyle(fullWidth: true))

                    Button("Import .JSON") {
                        LedgerHaptics.light()
                        showJSONImporter = true
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: false, fullWidth: true))
                }
            }
            .softPanel()
        }
    }

    // MARK: - Legal, Open Source & Data Wipe

    private var aboutLegalWipeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeaderView(
                title: "Legal, Open Source & Support",
                subtitle: "VELDA FITNESS · VELDAAPP.COM"
            )

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    if let home = URL(string: "https://veldaapp.com") {
                        Link("Website ↗", destination: home)
                    }
                    if let priv = URL(string: "https://veldaapp.com/privacy.html") {
                        Link("Privacy ↗", destination: priv)
                    }
                    if let tos = URL(string: "https://veldaapp.com/terms.html") {
                        Link("Terms ↗", destination: tos)
                    }
                    if let gh = URL(string: "https://github.com/Kest0216/velda-fitness") {
                        Link("GitHub ↗", destination: gh)
                    }
                    Spacer()
                    if let mail = URL(string: "mailto:support@veldaapp.com") {
                        Link("Email", destination: mail)
                    }
                }
                .font(LedgerFont.sansSm(semibold: true))
                .foregroundStyle(LedgerColor.inkPrimary)

                Button {
                    LedgerHaptics.light()
                    showMedicalSources = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Health & Dietary Sources + Disclaimer")
                    }
                }
                .buttonStyle(WarmActionButtonStyle(isActive: false, fullWidth: true))

                Text("Velda Fitness is an informational personal journal—not medical advice—and is provided \"as is\" with no obligation for perpetual updates. Open source on GitHub.")
                    .font(LedgerFont.serifMd(italic: true))
                    .foregroundStyle(LedgerColor.inkSecondary)

                Divider().opacity(0.25)

                HStack {
                    Text("Start with a clean slate")
                        .font(LedgerFont.serifMd(italic: true))
                        .foregroundStyle(LedgerColor.inkSecondary)
                    Spacer()
                    Button("Erase All Data") {
                        LedgerHaptics.heavy()
                        confirmWipeStep1 = true
                    }
                    .buttonStyle(WarmActionButtonStyle())
                }
            }
            .softPanel()
        }
    }

    private func storageBar(label: String, valueText: String, ratio: Double, minRatio: Double) -> some View {
        let clamped = min(1.0, max(minRatio, ratio))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label.uppercased())
                    .tracking(0.8)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text(valueText)
                    .monospacedDigit()
                    .font(LedgerFont.sansSm(semibold: true))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(LedgerFont.sansSm())
            .foregroundStyle(LedgerColor.inkPrimary)

            GeometryReader { geo in
                let fillW = geo.size.width * clamped
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(LedgerColor.inkPrimary.opacity(0.18))
                        .frame(height: 1)

                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(LedgerColor.inkPrimary)
                            .frame(width: max(4, fillW), height: 2.5)
                        Circle()
                            .fill(LedgerColor.inkPrimary)
                            .frame(width: 5, height: 5)
                            .offset(x: -2.5)
                    }
                }
            }
            .frame(height: 8)
        }
    }
}
