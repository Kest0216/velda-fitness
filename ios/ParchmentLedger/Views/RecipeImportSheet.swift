// MARK: - AI Recipe Import Sheet
//
// Accepts pasted recipe text, recipe webpage URLs, or `.json`/`.md`/`.txt` files and uses the
// user's configured BYO-AI provider (after explicit confirmation) to structure ingredients, steps,
// and estimated per-serving nutrition into a saved local recipe.

import SwiftUI
import UniformTypeIdentifiers

struct RecipeImportSheet: View {
    @EnvironmentObject var store: LedgerStore
    @Environment(\.dismiss) private var dismiss

    @State private var rawContent: String = ""
    @State private var importError: String? = nil
    @State private var showFileImporter: Bool = false
    @State private var pendingConfirm: PendingActionConfirmation? = nil

    var body: some View {
        ZStack {
            ParchmentBackgroundView()

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    SectionHeaderView(
                        title: "Import Recipe",
                        subtitle: "USES \(store.activeAIProvider.displayName.uppercased())"
                    )

                    Spacer()

                    Button("Close") {
                        LedgerHaptics.light()
                        dismiss()
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: false))
                    .disabled(store.isImportingRecipeAI)
                }

                Rectangle()
                    .fill(Color.white.opacity(0.55))
                    .frame(height: 1.2)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Paste recipe text, a recipe webpage link, or load a .json, .md, or .txt file. Your connected AI provider formats it into ingredients, steps, and estimated nutrition.")
                            .font(LedgerFont.serifMd(italic: true))
                            .foregroundStyle(LedgerColor.inkSecondary)

                        Button("Choose File (.json / .md / .txt)") {
                            LedgerHaptics.light()
                            showFileImporter = true
                        }
                        .buttonStyle(WarmActionButtonStyle(isActive: false, fullWidth: true))
                        .disabled(store.isImportingRecipeAI)

                        TextField("Paste recipe text, Markdown, JSON, or a webpage link...", text: $rawContent, axis: .vertical)
                            .lineLimit(6...14)
                            .font(LedgerFont.serifMd())
                            .foregroundStyle(LedgerColor.inkPrimary)
                            .warmRecessedField()
                            .disabled(store.isImportingRecipeAI)

                        if store.isImportingRecipeAI {
                            InkLoadingQuillView(label: "Formatting recipe with \(store.activeAIProvider.displayName)…")
                                .softPanel()
                        }

                        if let err = importError, !err.isEmpty {
                            Text(err)
                                .font(LedgerFont.sansSm())
                                .foregroundStyle(LedgerColor.errorRust)
                                .softPanel()
                        }

                        Button(store.isImportingRecipeAI ? "Importing…" : "Import with AI") {
                            let clean = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !clean.isEmpty else {
                                importError = "Paste recipe text, a link, or select a file first."
                                return
                            }
                            importError = nil
                            pendingConfirm = PendingActionConfirmation(
                                title: "Import Recipe with \(store.activeAIProvider.displayName)?",
                                message: "Sends this recipe text or link to \(store.activeAIProvider.displayName) to structure the ingredients, steps, and nutrition and save it to your Saved Recipes.",
                                confirmLabel: "Import Recipe",
                                isDestructive: false
                            ) {
                                Task {
                                    if let err = await store.importRecipeWithAI(rawText: clean) {
                                        importError = err
                                    } else {
                                        dismiss()
                                    }
                                }
                            }
                        }
                        .buttonStyle(PrimaryActionButtonStyle(fullWidth: true))
                        .disabled(store.isImportingRecipeAI)
                    }
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
        .ledgerToastOverlay(store.toastMessage)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.json, .plainText, .text, .utf8PlainText],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) {
                rawContent = text
                importError = nil
            } else {
                importError = "Could not read that file as text or JSON."
            }
        }
        .actionConfirmationAlert($pendingConfirm)
    }
}
