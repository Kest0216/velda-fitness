// MARK: - Diet & Macros Pillar View
//
// Daily nutrition tracker displaying calorie and macronutrient progress alongside U.S. FDA Daily Value
// upper limits (Sodium 2,300 mg, Sugar 50 g, Cholesterol 300 mg), customizable targets, saved-recipe
// quick-logging, optional BYO-AI meal estimation, and multi-day nutrient trend charts.

import SwiftUI

struct MacrosView: View {
    @EnvironmentObject var store: LedgerStore

    @State private var showTargetEditor: Bool = false
    @State private var targetKcalDraft: String = ""
    @State private var targetPDraft: String = ""
    @State private var targetCDraft: String = ""
    @State private var targetFDraft: String = ""
    @State private var targetSodiumDraft: String = ""
    @State private var targetSugarDraft: String = ""
    @State private var targetCholesterolDraft: String = ""

    @State private var showManualAdd: Bool = false
    @State private var showRecipePicker: Bool = false
    @State private var showAIEstimator: Bool = false
    @State private var showMacroTrends: Bool = false
    @State private var showMedicalSources: Bool = false
    @State private var pendingConfirm: PendingActionConfirmation? = nil
    @State private var missingAIFeatureName: String? = nil

    @State private var foodName: String = ""
    @State private var mealSlot: String = "Lunch"
    @State private var kcalText: String = ""
    @State private var proteinText: String = ""
    @State private var carbsText: String = ""
    @State private var fatText: String = ""
    @State private var sodiumText: String = ""
    @State private var sugarText: String = ""
    @State private var cholesterolText: String = ""
    @State private var notesText: String = ""
    @State private var aiDescription: String = ""

    private let mealSlots = ["Breakfast", "Lunch", "Dinner", "Snacks"]

    private var dateLabel: String {
        let isToday = store.macroDate == store.todayDate
        let short = DatabaseManager.mediumDateLabel(store.macroDate).uppercased()
        return isToday ? "TODAY · \(short)" : short
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                headerRow
                    .inkWritten(index: 0, epoch: store.inkWriteEpoch)

                summaryCard
                    .inkWritten(index: 1, epoch: store.inkWriteEpoch)

                if showTargetEditor {
                    targetEditorPanel
                }

                quickLogButtons
                    .inkWritten(index: 2, epoch: store.inkWriteEpoch)

                if showManualAdd {
                    manualLogPanel
                }

                if showRecipePicker {
                    recipeQuickPickPanel
                }

                if showAIEstimator {
                    aiEstimatorPanel
                }

                loggedMealsSection
                    .inkWritten(index: 3, epoch: store.inkWriteEpoch)

                sourcesFooterCard
                    .inkWritten(index: 4, epoch: store.inkWriteEpoch)
            }
            .padding(.top, 6)
            .padding(.bottom, 56)
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showMacroTrends) {
            MacroTrendsSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $showMedicalSources) {
            MedicalSourcesSheet()
        }
        .actionConfirmationAlert($pendingConfirm)
        .aiCredentialRequiredAlert(featureName: $missingAIFeatureName) {
            store.selectPillar(.vault)
        }
    }

    // MARK: - Header & Summary

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 8) {
            SectionHeaderView(
                title: "Diet & Macros",
                subtitle: dateLabel
            )

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Button {
                    store.shiftMacroDate(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(WarmIconButtonStyle())

                Button("Today") {
                    store.selectMacroDate(store.todayDate)
                }
                .buttonStyle(WarmActionButtonStyle(isActive: store.macroDate == store.todayDate))

                Button {
                    store.shiftMacroDate(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(WarmIconButtonStyle())
            }
        }
    }

    private var summaryCard: some View {
        let d = store.dailyMacros
        let t = store.macroTargets

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 6) {
                SectionHeaderView(
                    title: "Daily Totals",
                    subtitle: "\(d.kcal) / \(t.kcal) KCAL GOAL"
                )
                .lineLimit(1)
                .minimumScaleFactor(0.7)

                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    Button {
                        LedgerHaptics.light()
                        showMacroTrends = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chart.xyaxis.line")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Trends")
                        }
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: false))
                    .fixedSize(horizontal: true, vertical: false)

                    Button(showTargetEditor ? "Close" : "Targets") {
                        LedgerHaptics.light()
                        if !showTargetEditor {
                            loadTargetDrafts(from: t)
                        }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showTargetEditor.toggle()
                        }
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: showTargetEditor))
                    .fixedSize(horizontal: true, vertical: false)
                }
            }

            macroBar(
                label: "Calories",
                current: d.kcal,
                target: t.kcal,
                unit: "kcal",
                tint: LedgerColor.warmTerracotta,
                isLimit: false
            )

            macroBar(
                label: "Protein",
                current: d.proteinG,
                target: t.proteinG,
                unit: "g",
                tint: LedgerColor.verifiedSage,
                isLimit: false
            )

            macroBar(
                label: "Carbs",
                current: d.carbsG,
                target: t.carbsG,
                unit: "g",
                tint: LedgerColor.warmAmber,
                isLimit: false
            )

            macroBar(
                label: "Fat",
                current: d.fatG,
                target: t.fatG,
                unit: "g",
                tint: LedgerColor.inkPrimary,
                isLimit: false
            )

            Divider().opacity(0.26)

            macroBar(
                label: "Sodium",
                current: d.sodiumMg,
                target: t.sodiumMg,
                unit: "mg",
                tint: LedgerColor.phaseOvulatory,
                isLimit: true
            )

            macroBar(
                label: "Sugar",
                current: d.sugarG,
                target: t.sugarG,
                unit: "g",
                tint: LedgerColor.cycleRose,
                isLimit: true
            )

            macroBar(
                label: "Cholesterol",
                current: d.cholesterolMg,
                target: t.cholesterolMg,
                unit: "mg",
                tint: LedgerColor.phaseLuteal,
                isLimit: true
            )
        }
        .softPanel()
    }

    private func loadTargetDrafts(from t: MacroTargets) {
        targetKcalDraft = "\(t.kcal)"
        targetPDraft = "\(t.proteinG)"
        targetCDraft = "\(t.carbsG)"
        targetFDraft = "\(t.fatG)"
        targetSodiumDraft = "\(t.sodiumMg)"
        targetSugarDraft = "\(t.sugarG)"
        targetCholesterolDraft = "\(t.cholesterolMg)"
    }

    private var targetEditorPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeaderView(
                    title: "Daily Targets",
                    subtitle: "CUSTOMIZE GOALS & UPPER LIMITS"
                )
                Spacer()
                Button("FDA Defaults") {
                    LedgerHaptics.light()
                    loadTargetDrafts(from: .default)
                }
                .buttonStyle(WarmActionButtonStyle(isActive: false))
            }

            HStack(spacing: 8) {
                numericField(title: "KCAL", text: $targetKcalDraft)
                numericField(title: "PROTEIN (G)", text: $targetPDraft)
                numericField(title: "CARBS (G)", text: $targetCDraft)
                numericField(title: "FAT (G)", text: $targetFDraft)
            }

            HStack(spacing: 8) {
                numericField(title: "SODIUM (MG)", text: $targetSodiumDraft)
                numericField(title: "SUGAR (G)", text: $targetSugarDraft)
                numericField(title: "CHOLEST (MG)", text: $targetCholesterolDraft)
            }

            Button("Save Targets") {
                let fallback = MacroTargets.default
                let targets = MacroTargets(
                    kcal: max(600, Int(targetKcalDraft) ?? fallback.kcal),
                    proteinG: max(20, Int(targetPDraft) ?? fallback.proteinG),
                    carbsG: max(20, Int(targetCDraft) ?? fallback.carbsG),
                    fatG: max(15, Int(targetFDraft) ?? fallback.fatG),
                    sodiumMg: max(500, Int(targetSodiumDraft) ?? fallback.sodiumMg),
                    sugarG: max(5, Int(targetSugarDraft) ?? fallback.sugarG),
                    cholesterolMg: max(50, Int(targetCholesterolDraft) ?? fallback.cholesterolMg)
                )
                store.updateMacroTargets(targets)
                dismissLedgerKeyboard()
                withAnimation(.easeInOut(duration: 0.2)) {
                    showTargetEditor = false
                }
            }
            .buttonStyle(PrimaryActionButtonStyle(fullWidth: true))
        }
        .softPanel()
    }

    // MARK: - Quick Log Controls

    private var quickLogButtons: some View {
        HStack(spacing: 8) {
            Button("+ Log Meal") {
                LedgerHaptics.light()
                withAnimation(.easeInOut(duration: 0.2)) {
                    showManualAdd.toggle()
                    if showManualAdd {
                        showRecipePicker = false
                        showAIEstimator = false
                    }
                }
            }
            .buttonStyle(WarmActionButtonStyle(isActive: showManualAdd, fullWidth: true))

            Button("From Recipes") {
                LedgerHaptics.light()
                withAnimation(.easeInOut(duration: 0.2)) {
                    showRecipePicker.toggle()
                    if showRecipePicker {
                        showManualAdd = false
                        showAIEstimator = false
                    }
                }
            }
            .buttonStyle(WarmActionButtonStyle(isActive: showRecipePicker, fullWidth: true))

            Button("AI Estimate") {
                LedgerHaptics.light()
                guard store.hasConfiguredAICredential else {
                    missingAIFeatureName = "AI Meal Estimator"
                    return
                }
                withAnimation(.easeInOut(duration: 0.2)) {
                    showAIEstimator.toggle()
                    if showAIEstimator {
                        showManualAdd = false
                        showRecipePicker = false
                    }
                }
            }
            .buttonStyle(WarmActionButtonStyle(isActive: showAIEstimator, fullWidth: true))
        }
    }

    private var manualLogPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeaderView(
                title: "Log Food or Meal",
                subtitle: "ADD TO \(mealSlot.uppercased())"
            )

            // 2x2 grid keeps "BREAKFAST" untruncated on narrow viewports.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(mealSlots, id: \.self) { slot in
                    Button(slot) {
                        LedgerHaptics.light()
                        mealSlot = slot
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: mealSlot == slot, fullWidth: true))
                }
            }

            TextField("Meal or food name...", text: $foodName)
                .font(LedgerFont.serifMd())
                .foregroundStyle(LedgerColor.inkPrimary)
                .warmRecessedField()

            HStack(spacing: 8) {
                numericField(title: "KCAL", text: $kcalText)
                numericField(title: "PROTEIN (G)", text: $proteinText)
                numericField(title: "CARBS (G)", text: $carbsText)
                numericField(title: "FAT (G)", text: $fatText)
            }

            HStack(spacing: 8) {
                numericField(title: "SODIUM (MG)", text: $sodiumText)
                numericField(title: "SUGAR (G)", text: $sugarText)
                numericField(title: "CHOLEST (MG)", text: $cholesterolText)
            }

            TextField("Optional note (e.g. portion size)...", text: $notesText)
                .font(LedgerFont.serifMd())
                .foregroundStyle(LedgerColor.inkPrimary)
                .warmRecessedField()

            Button("Save Meal Entry") {
                dismissLedgerKeyboard()
                let clean = foodName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else {
                    store.showToast("Enter a meal or food name")
                    return
                }
                let kcalVal = Int(kcalText) ?? 0
                pendingConfirm = PendingActionConfirmation(
                    title: "Save Meal Entry?",
                    message: "Log \"\(clean)\" (\(kcalVal) kcal) to \(mealSlot) on \(DatabaseManager.mediumDateLabel(store.macroDate))?",
                    confirmLabel: "Save Entry",
                    isDestructive: false
                ) {
                    store.addMacroEntry(
                        mealSlot: mealSlot,
                        name: clean,
                        kcal: kcalVal,
                        proteinG: Int(proteinText) ?? 0,
                        carbsG: Int(carbsText) ?? 0,
                        fatG: Int(fatText) ?? 0,
                        sodiumMg: Int(sodiumText) ?? 0,
                        sugarG: Int(sugarText) ?? 0,
                        cholesterolMg: Int(cholesterolText) ?? 0,
                        notes: notesText
                    )
                    clearManualFields()
                    showManualAdd = false
                }
            }
            .buttonStyle(PrimaryActionButtonStyle(fullWidth: true))
        }
        .softPanel()
    }

    private func clearManualFields() {
        foodName = ""
        kcalText = ""
        proteinText = ""
        carbsText = ""
        fatText = ""
        sodiumText = ""
        sugarText = ""
        cholesterolText = ""
        notesText = ""
    }

    private var recipeQuickPickPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeaderView(
                title: "Saved Recipes",
                subtitle: "\(store.savedRecipes.count) AVAILABLE"
            )

            if store.savedRecipes.isEmpty {
                Text("Save a recipe from the Recipes tab first to log it in one tap.")
                    .font(LedgerFont.serifMd(italic: true))
                    .foregroundStyle(LedgerColor.inkSecondary)
            } else {
                ForEach(store.savedRecipes.prefix(12)) { rec in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rec.title)
                                .font(LedgerFont.serifMd(semibold: true))
                                .foregroundStyle(LedgerColor.inkPrimary)
                                .lineLimit(1)

                            Text("\(rec.kcal) kcal · \(rec.proteinG)g P · \(rec.carbsG)g C · \(rec.fatG)g F")
                                .font(LedgerFont.sansSm())
                                .foregroundStyle(LedgerColor.inkSecondary)
                                .lineLimit(1)

                            if rec.sodiumMg > 0 || rec.sugarG > 0 || rec.cholesterolMg > 0 {
                                Text("Na \(rec.sodiumMg)mg · Sugar \(rec.sugarG)g · Chol \(rec.cholesterolMg)mg")
                                    .font(LedgerFont.sansSm())
                                    .foregroundStyle(LedgerColor.inkSecondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        Button("+ Log 1×") {
                            pendingConfirm = PendingActionConfirmation(
                                title: "Log Saved Recipe?",
                                message: "Add 1 serving of \"\(rec.title)\" (\(rec.kcal) kcal) to \(DatabaseManager.mediumDateLabel(store.macroDate))?",
                                confirmLabel: "Log Meal",
                                isDestructive: false
                            ) {
                                store.logRecipeToMacros(rec, servings: 1.0)
                            }
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .softPanel()
    }

    private var aiEstimatorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeaderView(
                title: "AI Meal Estimator",
                subtitle: "POWERED BY YOUR \(store.activeAIProvider.shortLabel) KEY"
            )

            HStack(spacing: 8) {
                TextField("e.g. 2 eggs, sourdough toast with butter, black coffee", text: $aiDescription)
                    .font(LedgerFont.serifMd())
                    .foregroundStyle(LedgerColor.inkPrimary)
                    .warmRecessedField()

                Button(store.isEstimatingMacros ? "Working…" : "Estimate") {
                    guard store.hasConfiguredAICredential else {
                        missingAIFeatureName = "AI Meal Estimator"
                        return
                    }
                    let cleanDesc = aiDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleanDesc.isEmpty else {
                        store.showToast("Describe what you ate")
                        return
                    }
                    pendingConfirm = PendingActionConfirmation(
                        title: "Estimate Nutrition with \(store.activeAIProvider.displayName)?",
                        message: "Sends your meal description to \(store.activeAIProvider.displayName) to estimate calories, macros, sodium, sugar, and cholesterol.",
                        confirmLabel: "Run Estimate",
                        isDestructive: false
                    ) {
                        Task {
                            if let est = await store.estimateMealWithAI(description: cleanDesc) {
                                foodName = est.name
                                mealSlot = est.mealSlot
                                kcalText = "\(est.kcal)"
                                proteinText = "\(est.proteinG)"
                                carbsText = "\(est.carbsG)"
                                fatText = "\(est.fatG)"
                                sodiumText = "\(est.sodiumMg)"
                                sugarText = "\(est.sugarG)"
                                cholesterolText = "\(est.cholesterolMg)"
                                notesText = est.notes
                                showAIEstimator = false
                                showManualAdd = true
                                aiDescription = ""
                            }
                        }
                    }
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(store.isEstimatingMacros)
            }

            if store.isEstimatingMacros {
                InkLoadingQuillView(label: "Estimating nutrition with \(store.activeAIProvider.displayName)…")
            }

            if let err = store.macroAIError, !err.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(err)
                        .font(LedgerFont.sansSm())
                        .foregroundStyle(LedgerColor.errorRust)
                    if err.localizedCaseInsensitiveContains("key") || err.localizedCaseInsensitiveContains("vault") || err.localizedCaseInsensitiveContains("credential") {
                        Button("Open Vault →") {
                            store.selectPillar(.vault)
                        }
                        .buttonStyle(WarmActionButtonStyle(isActive: true))
                    }
                }
            }
        }
        .softPanel()
    }

    // MARK: - Logged Meals List & Sources

    private var loggedMealsSection: some View {
        let entryCount = store.dailyMacros.entries.count
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeaderView(
                title: "Logged Meals",
                subtitle: "\(entryCount) \(entryCount == 1 ? "ENTRY" : "ENTRIES") ON \(DatabaseManager.mediumDateLabel(store.macroDate).uppercased())"
            )

            if store.dailyMacros.entries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No meals recorded for this date.")
                        .font(LedgerFont.serifMd(italic: true))
                        .foregroundStyle(LedgerColor.inkSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .softPanel()
            } else {
                ForEach(store.dailyMacros.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.mealSlot.uppercased())
                                    .font(LedgerFont.sansSm())
                                    .tracking(1.0)
                                    .foregroundStyle(LedgerColor.inkSecondary)

                                Text(entry.name)
                                    .font(LedgerFont.serifMd(semibold: true))
                                    .foregroundStyle(LedgerColor.inkPrimary)

                                Text("\(entry.kcal) kcal · \(entry.proteinG)g P · \(entry.carbsG)g C · \(entry.fatG)g F")
                                    .font(LedgerFont.sansSm())
                                    .monospacedDigit()
                                    .foregroundStyle(LedgerColor.inkSecondary)

                                if entry.sodiumMg > 0 || entry.sugarG > 0 || entry.cholesterolMg > 0 {
                                    Text("Sodium \(entry.sodiumMg) mg · Sugar \(entry.sugarG) g · Cholesterol \(entry.cholesterolMg) mg")
                                        .font(LedgerFont.sansSm())
                                        .monospacedDigit()
                                        .foregroundStyle(LedgerColor.inkSecondary)
                                }

                                if !entry.notes.isEmpty {
                                    Text(entry.notes)
                                        .font(LedgerFont.serifMd(italic: true))
                                        .foregroundStyle(LedgerColor.inkSecondary)
                                }
                            }

                            Spacer()

                            Button {
                                pendingConfirm = PendingActionConfirmation(
                                    title: "Delete Meal Entry?",
                                    message: "Remove \"\(entry.name)\" (\(entry.kcal) kcal) from \(DatabaseManager.mediumDateLabel(store.macroDate))?",
                                    confirmLabel: "Delete",
                                    isDestructive: true
                                ) {
                                    store.deleteMacroEntry(entry.id)
                                }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                    .foregroundStyle(LedgerColor.inkSecondary)
                            }
                            .buttonStyle(WarmIconButtonStyle())
                        }
                    }
                    .softPanel()
                }
            }
        }
    }

    private var sourcesFooterCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Default limits for sodium (2,300 mg), added sugar (50 g), and cholesterol (300 mg) follow U.S. FDA Daily Value references. Nutrition estimates are informational and not medical advice.")
                .font(LedgerFont.serifMd(italic: true))
                .foregroundStyle(LedgerColor.inkSecondary)

            Button {
                LedgerHaptics.light()
                showMedicalSources = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Dietary Reference Sources & Disclaimer")
                }
            }
            .buttonStyle(WarmActionButtonStyle(isActive: false, fullWidth: true))
        }
        .softPanel()
    }

    // MARK: - Subviews

    private func macroBar(
        label: String,
        current: Int,
        target: Int,
        unit: String,
        tint: Color,
        isLimit: Bool
    ) -> some View {
        let safeTarget = max(1, target)
        let ratio = min(1.0, max(0.0, Double(current) / Double(safeTarget)))
        let overLimit = isLimit && current > target
        let barColor = overLimit ? LedgerColor.errorRust : tint

        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label.uppercased())
                    .font(LedgerFont.sansSm(semibold: overLimit))
                    .tracking(0.8)
                    .lineLimit(1)
                Spacer()
                Text("\(current) / \(target) \(unit)")
                    .font(LedgerFont.sansSm(semibold: true))
                    .monospacedDigit()
                    .foregroundStyle(overLimit ? LedgerColor.errorRust : LedgerColor.inkPrimary)
            }
            .foregroundStyle(overLimit ? LedgerColor.errorRust : LedgerColor.inkPrimary)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LedgerColor.inkPrimary.opacity(0.13))
                        .frame(height: 6)

                    Capsule()
                        .fill(barColor)
                        .frame(width: max(4, geo.size.width * ratio), height: 6)
                }
            }
            .frame(height: 6)
        }
    }

    private func numericField(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(LedgerFont.sansSm())
                .foregroundStyle(LedgerColor.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            TextField("0", text: text)
                .keyboardType(.numberPad)
                .font(LedgerFont.sansMd())
                .foregroundStyle(LedgerColor.inkPrimary)
                .warmRecessedField()
        }
        .frame(maxWidth: .infinity)
    }
}
