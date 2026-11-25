// MARK: - Routine Manager Sheet
//
// Unified sheet for browsing saved workout routines, toggling weekly day assignments,
// manually building/editing routines from the 588 MoveKit + custom catalogs, importing/sharing
// routines as JSON/Markdown/Text, and optionally generating routines via the user's BYO-AI provider.

import SwiftUI

struct RoutineManagerSheet: View {
    @EnvironmentObject var store: LedgerStore
    @Environment(\.dismiss) private var dismiss

    @State private var editingRoutineId: String? = nil
    @State private var isCreatingNew: Bool = false
    @State private var isAICreating: Bool = false
    @State private var confirmDeleteAllPresented: Bool = false
    @State private var sheetEpoch: Int = 0

    // Manual Editor state
    @State private var draftTitle: String = ""
    @State private var draftEmblem: String = ""
    @State private var draftExercises: [Exercise] = []
    @State private var draftWeekdays: Set<Int> = []
    @State private var draftAssignSelectedDate: Bool = false
    @State private var searchQuery: String = ""
    @State private var filterRegion: MuscleRegion = .all
    @State private var filterSubGroup: MuscleSubGroup? = nil
    @State private var customMuscleGroup: MuscleSubGroup = .custom
    @State private var searchResults: [Exercise] = []
    @State private var customFilmFilename: String = ""

    // AI "Create for Me" state
    @State private var aiPrompt: String = ""
    @State private var aiEmblem: String = ""
    @State private var aiWeekdays: Set<Int> = []
    @State private var aiAssignSelectedDate: Bool = true
    @State private var aiIncludeCustom: Bool = true

    // Share / Import state
    @State private var shareItem: IdentifiedShareURL? = nil
    @State private var showRoutineImporter: Bool = false
    @State private var pendingConfirm: PendingActionConfirmation? = nil
    @State private var missingAIFeatureName: String? = nil

    private let weekdayShorts = ["M", "T", "W", "T", "F", "S", "S"]

    private var inEditor: Bool {
        isCreatingNew || editingRoutineId != nil
    }

    private var selectedDateShort: String {
        DatabaseManager.shortDateLabel(store.selectedDate)
    }

    var body: some View {
        ZStack {
            ParchmentBackgroundView()

            VStack(alignment: .leading, spacing: 14) {
                headerBar

                Rectangle()
                    .fill(Color.white.opacity(0.55))
                    .frame(height: 1.2)

                if isAICreating {
                    aiCreateBody
                } else if inEditor {
                    editorBody
                } else {
                    libraryBody
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
        .ledgerToastOverlay(store.toastMessage)
        .onAppear {
            refreshSearchResults()
            sheetEpoch &+= 1
            if store.routineManagerStartInCreate {
                store.routineManagerStartInCreate = false
                startCreateMode()
            }
        }
        .alert("Delete All Routines?", isPresented: $confirmDeleteAllPresented) {
            Button("Delete All Routines", role: .destructive) {
                store.deleteAllRoutines()
                sheetEpoch &+= 1
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes all \(store.routines.count) saved routine(s) and unassigns your weekly and calendar schedule so you can build fresh. Past logged sets stay safe.")
        }
        .sheet(item: $shareItem) { item in
            ActivityShareSheet(activityItems: [item.url])
        }
        .fileImporter(
            isPresented: $showRoutineImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let first = urls.first {
                store.importJSONFile(from: first)
                sheetEpoch &+= 1
            }
        }
        .actionConfirmationAlert($pendingConfirm)
        .aiCredentialRequiredAlert(featureName: $missingAIFeatureName) {
            dismiss()
            store.selectPillar(.vault)
        }
    }

    private var headerOverline: String {
        if isAICreating { return "AI COACH · \(store.activeAIProvider.shortLabel)" }
        if inEditor { return isCreatingNew ? "NEW ROUTINE" : "EDIT ROUTINE" }
        return "ROUTINE LIBRARY"
    }

    private var headerHeadline: String {
        if isAICreating { return "Create for Me" }
        if inEditor { return draftTitle.isEmpty ? "Untitled Routine" : draftTitle }
        return "Manage Routines"
    }

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(headerOverline)
                    .font(LedgerFont.sansSm())
                    .tracking(1.8)
                    .foregroundStyle(LedgerColor.inkSecondary)

                Text(headerHeadline)
                    .font(LedgerFont.serifLg(bold: true))
                    .foregroundStyle(LedgerColor.inkPrimary)
                    .lineLimit(1)
            }

            Spacer()

            if isAICreating {
                Button("Back") {
                    LedgerHaptics.light()
                    store.routineAIError = nil
                    isAICreating = false
                    sheetEpoch &+= 1
                }
                .buttonStyle(WarmActionButtonStyle())
                .disabled(store.isGeneratingRoutine)
            } else if inEditor {
                Button("Back") {
                    LedgerHaptics.light()
                    resetEditor()
                    sheetEpoch &+= 1
                }
                .buttonStyle(WarmActionButtonStyle())

                Button("Save") {
                    dismissLedgerKeyboard()
                    let cleanName = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    let displayTitle = cleanName.isEmpty ? "Untitled Routine" : cleanName
                    let verb = editingRoutineId != nil ? "Update" : "Create"
                    pendingConfirm = PendingActionConfirmation(
                        title: "\(verb) Routine?",
                        message: "\(verb) \"\(displayTitle)\" with \(draftExercises.count) exercise(s)?",
                        confirmLabel: verb,
                        isDestructive: false
                    ) {
                        saveDraftRoutine()
                    }
                }
                .buttonStyle(PrimaryActionButtonStyle())
            } else {
                Button("Done") {
                    dismissLedgerKeyboard()
                    LedgerHaptics.light()
                    dismiss()
                }
                .buttonStyle(PrimaryActionButtonStyle())
            }
        }
    }

    private var libraryBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button("+ Create Routine") {
                        LedgerHaptics.light()
                        startCreateMode()
                    }
                    .buttonStyle(PrimaryActionButtonStyle())

                    Button {
                        LedgerHaptics.light()
                        guard store.hasConfiguredAICredential else {
                            missingAIFeatureName = "AI Routine Builder"
                            return
                        }
                        startAICreateMode()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Create for Me")
                        }
                    }
                    .buttonStyle(WarmActionButtonStyle())

                    Spacer()
                }

                HStack(spacing: 8) {
                    Button("Custom Studio") {
                        LedgerHaptics.light()
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            store.openCustomExerciseStudio()
                        }
                    }
                    .buttonStyle(WarmActionButtonStyle())

                    Button("Import JSON") {
                        LedgerHaptics.light()
                        showRoutineImporter = true
                    }
                    .buttonStyle(WarmActionButtonStyle())

                    Spacer()

                    if !store.routines.isEmpty {
                        Button("Delete All") {
                            LedgerHaptics.heavy()
                            confirmDeleteAllPresented = true
                        }
                        .buttonStyle(WarmActionButtonStyle())
                    }
                }
            }
            .inkWritten(index: 0, epoch: sheetEpoch)

            if store.routines.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("No Custom Routines Yet")
                        .font(LedgerFont.serifLg(italic: true))
                        .foregroundStyle(LedgerColor.inkPrimary)
                    Text("TAP + CREATE ROUTINE OR CREATE FOR ME ABOVE")
                        .font(LedgerFont.sansSm())
                        .tracking(1.0)
                        .foregroundStyle(LedgerColor.inkSecondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .inkWritten(index: 1, epoch: sheetEpoch)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(store.routines.enumerated()), id: \.element.id) { idx, routine in
                            routineLibraryCard(routine)
                                .inkWritten(index: idx + 1, epoch: sheetEpoch)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private var aiCreateBody: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("DESCRIBE YOUR ROUTINE")
                        .font(LedgerFont.sansSm())
                        .tracking(1.6)
                        .foregroundStyle(LedgerColor.inkSecondary)

                    TextField(
                        "e.g. 45-min dumbbell upper push & shoulder stability, or kettlebell posterior chain...",
                        text: $aiPrompt,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                    .font(LedgerFont.serifMd())
                    .foregroundStyle(LedgerColor.inkPrimary)
                    .disabled(store.isGeneratingRoutine)
                    .warmRecessedField()

                    Text("Selections are bounded to your 588 MoveKit catalog\(aiIncludeCustom ? " and your custom exercises" : "") so every movement matches your ledger.")
                        .font(LedgerFont.serifSmItalic())
                        .foregroundStyle(LedgerColor.inkSecondary)

                    Button {
                        LedgerHaptics.light()
                        aiIncludeCustom.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            HandDrawnCheckboxView(isChecked: aiIncludeCustom)
                            Text("INCLUDE MY CUSTOM EXERCISES (\(store.customExercises.count))")
                                .font(LedgerFont.sansSm())
                                .tracking(1.0)
                                .foregroundStyle(LedgerColor.inkPrimary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isGeneratingRoutine)
                }
                .inkWritten(index: 0, epoch: sheetEpoch)

                VStack(alignment: .leading, spacing: 6) {
                    Text("CALENDAR EMBLEM (OPTIONAL)")
                        .font(LedgerFont.sansSm())
                        .tracking(1.6)
                        .foregroundStyle(LedgerColor.inkSecondary)

                    RoutineEmblemPickerView(selectedEmblem: $aiEmblem)
                }
                .inkWritten(index: 1, epoch: sheetEpoch)

                VStack(alignment: .leading, spacing: 6) {
                    Text("ASSIGN TO WEEKLY STRIP")
                        .font(LedgerFont.sansSm())
                        .tracking(1.6)
                        .foregroundStyle(LedgerColor.inkSecondary)

                    HStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { dow in
                            let active = aiWeekdays.contains(dow)
                            Button {
                                LedgerHaptics.light()
                                if active {
                                    aiWeekdays.remove(dow)
                                } else {
                                    aiWeekdays.insert(dow)
                                }
                            } label: {
                                Text(weekdayShorts[dow])
                                    .font(LedgerFont.sansSm(semibold: active))
                                    .foregroundStyle(LedgerColor.inkPrimary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .background(
                                        Group {
                                            if active {
                                                LinearGradient(
                                                    colors: [LedgerColor.warmTerracotta.opacity(0.36), LedgerColor.warmAmber.opacity(0.18)],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            } else {
                                                LedgerColor.inkPrimary.opacity(0.05)
                                            }
                                        }
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(LedgerColor.inkPrimary.opacity(active ? 0.35 : 0.0), lineWidth: 0.9)
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(store.isGeneratingRoutine)
                        }
                    }

                    Button {
                        LedgerHaptics.light()
                        aiAssignSelectedDate.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            HandDrawnCheckboxView(isChecked: aiAssignSelectedDate)
                            Text("ALSO ASSIGN TO \(selectedDateShort.uppercased())")
                                .font(LedgerFont.sansSm())
                                .tracking(1.0)
                                .foregroundStyle(LedgerColor.inkPrimary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isGeneratingRoutine)
                    .padding(.top, 4)
                }
                .inkWritten(index: 1, epoch: sheetEpoch)

                HStack {
                    Button {
                        guard store.hasConfiguredAICredential else {
                            missingAIFeatureName = "AI Routine Builder"
                            return
                        }
                        let cleanPrompt = aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cleanPrompt.isEmpty else {
                            store.showToast("Describe your routine goal first")
                            return
                        }
                        pendingConfirm = PendingActionConfirmation(
                            title: "Build Routine with \(store.activeAIProvider.displayName)?",
                            message: "Sends your goal and exercise catalog to \(store.activeAIProvider.displayName) to assemble and save a new workout routine.",
                            confirmLabel: "Build Routine",
                            isDestructive: false
                        ) {
                            Task {
                                if let _ = await store.generateRoutineForMe(
                                    prompt: cleanPrompt,
                                    emblem: aiEmblem,
                                    weekdays: Array(aiWeekdays).sorted(),
                                    assignSelectedDate: aiAssignSelectedDate,
                                    includeCustomExercises: aiIncludeCustom
                                ) {
                                    aiPrompt = ""
                                    aiEmblem = ""
                                    isAICreating = false
                                    sheetEpoch &+= 1
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10, weight: .semibold))
                            Text(store.isGeneratingRoutine ? "Building Routine…" : "Build Routine")
                        }
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(store.isGeneratingRoutine)

                    Spacer()
                }
                .inkWritten(index: 2, epoch: sheetEpoch)

                if store.isGeneratingRoutine {
                    InkLoadingQuillView(
                        label: "Selecting movements from catalog with \(store.activeAIProvider.displayName)…"
                    )
                    .softPanel()
                }

                if let err = store.routineAIError, !err.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(err)
                            .font(LedgerFont.sansSm())
                            .foregroundStyle(LedgerColor.inkPrimary)

                        if err.localizedCaseInsensitiveContains("key") || err.localizedCaseInsensitiveContains("credential") || err.localizedCaseInsensitiveContains("vault") {
                            Button("Open Vault →") {
                                LedgerHaptics.light()
                                dismiss()
                                store.selectPillar(.vault)
                            }
                            .buttonStyle(WarmActionButtonStyle(isActive: true))
                        }
                    }
                    .softPanel()
                }
            }
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func routineLibraryCard(_ routine: RoutineSummary) -> some View {
        let previewNames = routine.exercises.prefix(4).map(\.name).joined(separator: " · ")
        let overflow = routine.exercises.count > 4 ? " +\(routine.exercises.count - 4)" : ""
        let assignedToViewedDate = store.workout?.routineIds.contains(routine.id) == true

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                if !routine.emblem.isEmpty {
                    RoutineEmblemBadgeView(emblem: routine.emblem, fontSize: 17)
                        .padding(.top, 1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.title)
                        .font(LedgerFont.serifMd(semibold: true))
                        .foregroundStyle(LedgerColor.inkPrimary)

                    Text("\(routine.exercises.count) MOVEMENT\(routine.exercises.count == 1 ? "" : "S")\(routine.exercises.isEmpty ? "" : " · \(previewNames)\(overflow)")")
                        .font(LedgerFont.sansSm())
                        .foregroundStyle(LedgerColor.inkSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 4)
            }

            // 1-click weekly assignment strip
            VStack(alignment: .leading, spacing: 4) {
                Text("WEEKLY SCHEDULE (TAP DAYS · MULTIPLE PER DAY)")
                    .font(LedgerFont.sansSm())
                    .tracking(1.2)
                    .foregroundStyle(LedgerColor.inkSecondary)

                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { dow in
                        let active = routine.assignedWeekdays.contains(dow)
                        Button {
                            store.toggleRoutineWeekday(routineId: routine.id, dayOfWeek: dow)
                        } label: {
                            Text(weekdayShorts[dow])
                                .font(LedgerFont.sansSm(semibold: active))
                                .foregroundStyle(LedgerColor.inkPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(
                                    Group {
                                        if active {
                                            LinearGradient(
                                                colors: [LedgerColor.warmTerracotta.opacity(0.36), LedgerColor.warmAmber.opacity(0.18)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        } else {
                                            LedgerColor.inkPrimary.opacity(0.05)
                                        }
                                    }
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(LedgerColor.inkPrimary.opacity(active ? 0.35 : 0.0), lineWidth: 0.9)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 8) {
                Button(assignedToViewedDate ? "On \(selectedDateShort) ✓" : "+ \(selectedDateShort)") {
                    store.toggleRoutineOnSelectedDate(routine.id)
                }
                .buttonStyle(WarmActionButtonStyle(isActive: assignedToViewedDate))

                Spacer()

                Menu {
                    ForEach(ExportFormat.allCases) { fmt in
                        Button("Share as \(fmt.label)") {
                            if let url = store.prepareRoutineShareFile(routine, format: fmt) {
                                shareItem = IdentifiedShareURL(url: url)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(WarmIconButtonStyle())

                Button("Edit") {
                    LedgerHaptics.light()
                    startEditMode(routine)
                }
                .buttonStyle(WarmActionButtonStyle())

                Button("Delete") {
                    pendingConfirm = PendingActionConfirmation(
                        title: "Delete Routine?",
                        message: "Remove \"\(routine.title)\" and its schedule assignments? Logged workout sets stay intact.",
                        confirmLabel: "Delete",
                        isDestructive: true
                    ) {
                        store.deleteRoutine(routine.id)
                        sheetEpoch &+= 1
                    }
                }
                .buttonStyle(WarmActionButtonStyle())
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LedgerColor.parchmentLight.opacity(0.56))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.36), lineWidth: 0.8)
        )
    }

    private var editorBody: some View {
        let qTrim = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let exactMatch = searchResults.contains { $0.name.caseInsensitiveCompare(qTrim) == .orderedSame }
        let selectedIds = Set(draftExercises.map(\.id))

        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ROUTINE NAME")
                        .font(LedgerFont.sansSm())
                        .tracking(1.6)
                        .foregroundStyle(LedgerColor.inkSecondary)

                    TextField("e.g. Heavy Push, Mobility Reset...", text: $draftTitle)
                        .font(LedgerFont.serifMd())
                        .foregroundStyle(LedgerColor.inkPrimary)
                        .warmRecessedField()
                }
                .inkWritten(index: 0, epoch: sheetEpoch)

                VStack(alignment: .leading, spacing: 6) {
                    Text("CALENDAR EMBLEM (OPTIONAL)")
                        .font(LedgerFont.sansSm())
                        .tracking(1.6)
                        .foregroundStyle(LedgerColor.inkSecondary)

                    RoutineEmblemPickerView(selectedEmblem: $draftEmblem)
                }
                .inkWritten(index: 1, epoch: sheetEpoch)

                VStack(alignment: .leading, spacing: 6) {
                    Text("CALENDAR EMBLEM (OPTIONAL)")
                        .font(LedgerFont.sansSm())
                        .tracking(1.6)
                        .foregroundStyle(LedgerColor.inkSecondary)

                    RoutineEmblemPickerView(selectedEmblem: $aiEmblem)
                }
                .inkWritten(index: 1, epoch: sheetEpoch)

                VStack(alignment: .leading, spacing: 6) {
                    Text("ASSIGN TO WEEKLY STRIP")
                        .font(LedgerFont.sansSm())
                        .tracking(1.6)
                        .foregroundStyle(LedgerColor.inkSecondary)

                    HStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { dow in
                            let active = draftWeekdays.contains(dow)
                            Button {
                                LedgerHaptics.light()
                                if active {
                                    draftWeekdays.remove(dow)
                                } else {
                                    draftWeekdays.insert(dow)
                                }
                            } label: {
                                Text(weekdayShorts[dow])
                                    .font(LedgerFont.sansSm(semibold: active))
                                    .foregroundStyle(LedgerColor.inkPrimary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .background(
                                        Group {
                                            if active {
                                                LinearGradient(
                                                    colors: [LedgerColor.warmTerracotta.opacity(0.36), LedgerColor.warmAmber.opacity(0.18)],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            } else {
                                                LedgerColor.inkPrimary.opacity(0.05)
                                            }
                                        }
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(LedgerColor.inkPrimary.opacity(active ? 0.35 : 0.0), lineWidth: 0.9)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if isCreatingNew {
                        Button {
                            LedgerHaptics.light()
                            draftAssignSelectedDate.toggle()
                        } label: {
                            HStack(spacing: 8) {
                                HandDrawnCheckboxView(isChecked: draftAssignSelectedDate)
                                Text("ALSO ASSIGN TO \(selectedDateShort.uppercased())")
                                    .font(LedgerFont.sansSm())
                                    .tracking(1.0)
                                    .foregroundStyle(LedgerColor.inkPrimary)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                }
                .inkWritten(index: 1, epoch: sheetEpoch)

                VStack(alignment: .leading, spacing: 8) {
                    Text("INCLUDED MOVEMENTS (\(draftExercises.count))")
                        .font(LedgerFont.sansSm())
                        .tracking(1.6)
                        .foregroundStyle(LedgerColor.inkSecondary)

                    if draftExercises.isEmpty {
                        Text("Search below to add MoveKit or custom exercises.")
                            .font(LedgerFont.serifMd(italic: true))
                            .foregroundStyle(LedgerColor.inkSecondary)
                            .softPanel()
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(draftExercises) { ex in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ex.name)
                                            .font(LedgerFont.serifMd(semibold: true))
                                            .foregroundStyle(LedgerColor.inkPrimary)
                                        Text("\(ex.muscleHint.uppercased()) · \(ex.videoFilename != nil ? "FILM" : "CUSTOM")")
                                            .font(LedgerFont.sansSm())
                                            .foregroundStyle(LedgerColor.inkSecondary)
                                    }
                                    Spacer()
                                    Button {
                                        LedgerHaptics.heavy()
                                        draftExercises.removeAll { $0.id == ex.id }
                                    } label: {
                                        Text("×")
                                            .font(LedgerFont.sansMd())
                                    }
                                    .buttonStyle(WarmIconButtonStyle())
                                }
                            }
                        }
                        .softPanel()
                    }
                }
                .inkWritten(index: 2, epoch: sheetEpoch)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("ADD MOVEMENTS (588 MOVEKIT OR CUSTOM)")
                            .font(LedgerFont.sansSm())
                            .tracking(1.6)
                            .foregroundStyle(LedgerColor.inkSecondary)

                        Spacer()

                        if filterRegion != .all || !qTrim.isEmpty {
                            Text("\(searchResults.count) MATCHING")
                                .font(LedgerFont.sansSm())
                                .tracking(0.8)
                                .foregroundStyle(LedgerColor.inkSecondary)
                        }
                    }

                    TextField("Fuzzy search or type custom movement...", text: $searchQuery)
                        .font(LedgerFont.serifMd())
                        .foregroundStyle(LedgerColor.inkPrimary)
                        .warmRecessedField()
                        .onChange(of: searchQuery) { _, _ in
                            refreshSearchResults()
                        }

                    MuscleGroupFilterBar(
                        selectedRegion: $filterRegion,
                        selectedSubGroup: $filterSubGroup
                    )
                    .onChange(of: filterRegion) { _, _ in
                        refreshSearchResults()
                    }
                    .onChange(of: filterSubGroup) { _, newSub in
                        if let sub = newSub {
                            customMuscleGroup = sub
                        }
                        refreshSearchResults()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        if !qTrim.isEmpty && !exactMatch {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Create custom “\(qTrim)”")
                                        .font(LedgerFont.serifMd(italic: true))
                                        .foregroundStyle(LedgerColor.inkPrimary)
                                    Spacer()
                                    Button("+ Custom") {
                                        let created = store.createCustomExerciseOnly(
                                            name: qTrim,
                                            muscleHint: customMuscleGroup.rawValue,
                                            videoFilename: customFilmFilename.isEmpty ? nil : customFilmFilename
                                        )
                                        draftExercises.append(created)
                                        searchQuery = ""
                                        customFilmFilename = ""
                                        refreshSearchResults()
                                    }
                                    .buttonStyle(WarmActionButtonStyle(isActive: true))
                                }

                                Picker("Muscle Group", selection: $customMuscleGroup) {
                                    ForEach(MuscleSubGroup.allCases) { grp in
                                        Text(grp.rawValue).tag(grp)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(LedgerColor.inkPrimary)
                                .font(LedgerFont.sansSm())

                                let filmCandidates = searchResults.filter { $0.videoFilename != nil }.prefix(6)
                                if !filmCandidates.isEmpty {
                                    Picker("Link Film", selection: $customFilmFilename) {
                                        Text("No reference film (standalone)").tag("")
                                        ForEach(Array(filmCandidates)) { cand in
                                            Text("Link film: \(cand.name)").tag(cand.videoFilename ?? "")
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .tint(LedgerColor.inkPrimary)
                                    .font(LedgerFont.sansSm())
                                }
                            }
                        }

                        let visibleLimit = (filterRegion == .all && qTrim.isEmpty) ? 25 : 60
                        if searchResults.isEmpty {
                            Text("No matching movements in this filter.")
                                .font(LedgerFont.sansSm())
                                .foregroundStyle(LedgerColor.inkSecondary)
                        } else {
                            ForEach(searchResults.prefix(visibleLimit)) { res in
                                let already = selectedIds.contains(res.id)
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(res.name)
                                            .font(LedgerFont.serifMd())
                                            .foregroundStyle(LedgerColor.inkPrimary)
                                            .lineLimit(1)
                                        Text("\(res.muscleHint.uppercased()) · \(res.videoFilename != nil ? "FILM" : "CUSTOM")")
                                            .font(LedgerFont.sansSm())
                                            .foregroundStyle(LedgerColor.inkSecondary)
                                    }
                                    Spacer()
                                    Button(already ? "Added" : "+ Add") {
                                        if !already {
                                            LedgerHaptics.heavy()
                                            draftExercises.append(res)
                                        }
                                    }
                                    .buttonStyle(WarmActionButtonStyle(isActive: already))
                                    .disabled(already)
                                }
                            }
                        }
                    }
                    .softPanel()
                }
                .inkWritten(index: 3, epoch: sheetEpoch)
            }
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func refreshSearchResults() {
        let isFiltered = filterRegion != .all || filterSubGroup != nil || !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        searchResults = DatabaseManager.shared.fuzzySearchExercises(
            query: searchQuery,
            region: filterRegion,
            subGroup: filterSubGroup,
            limit: isFiltered ? 80 : 30
        )
    }

    private func startAICreateMode() {
        editingRoutineId = nil
        isCreatingNew = false
        isAICreating = true
        store.routineAIError = nil
        aiPrompt = ""
        aiEmblem = ""
        aiWeekdays = [store.selectedDow]
        aiAssignSelectedDate = true
        sheetEpoch &+= 1
    }

    private func startCreateMode() {
        isAICreating = false
        editingRoutineId = nil
        isCreatingNew = true
        draftTitle = ""
        draftEmblem = ""
        draftExercises = []
        draftWeekdays = [store.selectedDow]
        draftAssignSelectedDate = true
        searchQuery = ""
        filterRegion = .all
        filterSubGroup = nil
        customMuscleGroup = .custom
        customFilmFilename = ""
        refreshSearchResults()
        sheetEpoch &+= 1
    }

    private func startEditMode(_ routine: RoutineSummary) {
        isAICreating = false
        isCreatingNew = false
        editingRoutineId = routine.id
        draftTitle = routine.title
        draftEmblem = routine.emblem
        draftExercises = routine.exercises
        draftWeekdays = Set(routine.assignedWeekdays)
        draftAssignSelectedDate = false
        searchQuery = ""
        filterRegion = .all
        filterSubGroup = nil
        customMuscleGroup = .custom
        customFilmFilename = ""
        refreshSearchResults()
        sheetEpoch &+= 1
    }

    private func resetEditor() {
        isAICreating = false
        isCreatingNew = false
        editingRoutineId = nil
        draftTitle = ""
        draftEmblem = ""
        draftExercises = []
        draftWeekdays = []
        searchQuery = ""
        filterRegion = .all
        filterSubGroup = nil
        customFilmFilename = ""
    }

    private func saveDraftRoutine() {
        let exIds = draftExercises.map(\.id)
        if let rid = editingRoutineId {
            store.updateRoutine(
                id: rid,
                title: draftTitle,
                emblem: draftEmblem,
                exerciseIds: exIds,
                weekdays: Array(draftWeekdays).sorted()
            )
            resetEditor()
            sheetEpoch &+= 1
        } else {
            store.createRoutine(
                title: draftTitle,
                emblem: draftEmblem,
                exerciseIds: exIds,
                weekdays: Array(draftWeekdays).sorted(),
                assignSelectedDate: draftAssignSelectedDate
            )
            resetEditor()
            sheetEpoch &+= 1
        }
    }
}
