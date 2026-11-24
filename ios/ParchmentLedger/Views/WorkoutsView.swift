import AVFoundation
import SwiftUI

struct WorkoutsView: View {
    @EnvironmentObject var store: LedgerStore
    @State private var routineTitleDraft: String = ""
    @State private var removeDialogPresented: Bool = false
    @State private var assignToDateOnly: Bool = false
    @State private var pendingConfirm: PendingActionConfirmation? = nil
    @FocusState private var pickerFocused: Bool

    private var unit: String {
        store.storage?.weightUnit ?? "lbs"
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                if store.showMonthlyCalendar {
                    monthlyCalendarPanel()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                dayStrip
                    .inkWritten(index: 0, epoch: store.inkWriteEpoch)

                if let wk = store.workout {
                    VStack(alignment: .leading, spacing: 12) {
                        routineHeader(wk)
                            .inkWritten(index: 1, epoch: store.inkWriteEpoch)

                        if store.showInlineRoutinePicker {
                            inlineRoutinePickerPanel(wk)
                        }

                        if store.pickerOpen {
                            inlineExercisePicker()
                        }

                        Rectangle()
                            .fill(Color.white.opacity(0.58))
                            .frame(height: 1.2)
                            .inkWritten(index: 2, epoch: store.inkWriteEpoch)
                    }

                    if wk.routineId == nil {
                        VStack(spacing: 6) {
                            Text("Rest & Unassigned Day")
                                .font(LedgerFont.serifLg(italic: true))
                                .foregroundStyle(LedgerColor.inkPrimary)
                            Text("TAP + ASSIGN ABOVE OR + ROUTINES TO SCHEDULE")
                                .font(LedgerFont.sansSm())
                                .tracking(1.0)
                                .foregroundStyle(LedgerColor.inkSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                        .inkWritten(index: 3, epoch: store.inkWriteEpoch)
                    } else if wk.exercises.isEmpty {
                        VStack(spacing: 6) {
                            Text("No Movements in Routine")
                                .font(LedgerFont.serifLg(italic: true))
                                .foregroundStyle(LedgerColor.inkPrimary)
                            Text("TAP + ADD ABOVE TO ADD EXERCISES")
                                .font(LedgerFont.sansSm())
                                .tracking(1.0)
                                .foregroundStyle(LedgerColor.inkSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                        .inkWritten(index: 3, epoch: store.inkWriteEpoch)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(wk.exercises.enumerated()), id: \.element.id) { idx, ex in
                                exerciseBlock(ex)
                                    .inkWritten(index: idx + 3, epoch: store.inkWriteEpoch)
                            }
                        }
                    }
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 56)
        }
        .scrollDismissesKeyboard(.interactively)
        .actionConfirmationAlert($pendingConfirm)
        .confirmationDialog(
            "Remove \(store.workout?.title ?? "Routine")?",
            isPresented: $removeDialogPresented,
            titleVisibility: .visible
        ) {
            if let wk = store.workout {
                Button("Remove from \(wk.displayDateShort) Only", role: .destructive) {
                    store.removeRoutineFromSelectedDateOnly()
                }
                Button("Remove from Every \(wk.dayFullName)", role: .destructive) {
                    store.removeRoutineFromWeeklyDay()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func monthlyCalendarPanel() -> some View {
        let headers = ["M", "T", "W", "T", "F", "S", "S"]
        let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

        return VStack(alignment: .leading, spacing: 10) {
            CenteredCalendarHeaderView(
                title: DatabaseManager.monthTitle(store.displayedMonthAnchor),
                onPrevious: { store.shiftDisplayedMonth(by: -1) },
                onNext: { store.shiftDisplayedMonth(by: 1) }
            )

            HStack {
                Spacer()
                Button("Today") {
                    store.jumpToToday()
                }
                .buttonStyle(WarmActionButtonStyle(isActive: store.selectedDate == store.todayDate))
            }

            LazyVGrid(columns: cols, spacing: 6) {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, sym in
                    Text(sym)
                        .font(LedgerFont.sansSm())
                        .foregroundStyle(LedgerColor.inkSecondary)
                        .frame(maxWidth: .infinity)
                }

                ForEach(store.monthSlots) { slot in
                    if let iso = slot.isoDate, let dayNum = slot.dayNumber {
                        let isSelected = iso == store.selectedDate
                        Button {
                            store.selectDate(iso)
                            withAnimation(.easeInOut(duration: 0.2)) {
                                store.showMonthlyCalendar = false
                            }
                        } label: {
                            VStack(spacing: 3) {
                                Text("\(dayNum)")
                                    .font(LedgerFont.sansSm(semibold: isSelected || slot.isToday))
                                    .monospacedDigit()
                                    .foregroundStyle(isSelected || slot.isToday ? LedgerColor.inkPrimary : LedgerColor.inkSecondary)

                                Circle()
                                    .fill(LedgerColor.inkPrimary.opacity(
                                        slot.hasLoggedSets ? 0.95 : (slot.hasRoutine ? 0.38 : 0.0)
                                    ))
                                    .frame(width: 3.5, height: 3.5)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(
                                RadialGradient(
                                    colors: isSelected
                                        ? [LedgerColor.warmTerracotta.opacity(0.32), LedgerColor.warmAmber.opacity(0.10), .clear]
                                        : [.clear, .clear],
                                    center: .center,
                                    startRadius: 2,
                                    endRadius: 20
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(LedgerColor.inkPrimary.opacity(slot.isToday ? 0.45 : 0.0), lineWidth: 1.1)
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear
                            .frame(height: 28)
                    }
                }
            }
        }
        .softPanel()
    }

    private var dayStrip: some View {
        HStack(spacing: 2) {
            ForEach(store.weekSlots) { slot in
                let isSelected = slot.isoDate == store.selectedDate
                Button {
                    store.selectDate(slot.isoDate)
                } label: {
                    VStack(spacing: 2) {
                        Text(slot.dayShort)
                            .font(LedgerFont.sansSm(semibold: isSelected || slot.isToday))
                            .tracking(0.5)
                            .foregroundStyle(isSelected || slot.isToday ? LedgerColor.inkPrimary : LedgerColor.inkSecondary)

                        Text("\(slot.dayNumber)")
                            .font(LedgerFont.sansSm(semibold: isSelected || slot.isToday))
                            .monospacedDigit()
                            .foregroundStyle(isSelected || slot.isToday ? LedgerColor.inkPrimary : LedgerColor.inkSecondary.opacity(0.85))

                        Circle()
                            .fill(LedgerColor.inkPrimary.opacity(slot.hasLoggedSets ? 1.0 : (slot.hasRoutine ? 0.42 : 0.14)))
                            .frame(width: 4, height: 4)
                            .padding(.top, 1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        RadialGradient(
                            colors: isSelected
                                ? [LedgerColor.warmTerracotta.opacity(0.28), LedgerColor.warmAmber.opacity(0.08), .clear]
                                : [.clear, .clear],
                            center: .center,
                            startRadius: 2,
                            endRadius: 28
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                LedgerColor.inkPrimary.opacity(slot.isToday ? 0.45 : 0.0),
                                lineWidth: 1.2
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func routineHeader(_ wk: DayWorkout) -> some View {
        let countLabel = wk.routineId == nil ? "REST" : "\(wk.completedExercises)/\(wk.totalExercises) DONE"
        let overline = wk.isToday
            ? "SCHEDULED ROUTINE · \(countLabel)"
            : "SCHEDULED ROUTINE · \(wk.dayName.uppercased()) \(wk.displayDateShort.uppercased()) · \(countLabel)"

        return VStack(alignment: .leading, spacing: 6) {
            Text(overline)
                .font(LedgerFont.sansSm())
                .tracking(1.6)
                .foregroundStyle(LedgerColor.inkSecondary)

            if wk.routineId == nil {
                HStack(alignment: .center, spacing: 8) {
                    Text("No Routine")
                        .font(LedgerFont.serifLg(bold: true))
                        .foregroundStyle(LedgerColor.inkSecondary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Button(store.showInlineRoutinePicker ? "Close" : "+ Assign") {
                        LedgerHaptics.light()
                        store.pickerOpen = false
                        pickerFocused = false
                        assignToDateOnly = !wk.isToday
                        store.showInlineRoutinePicker.toggle()
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: store.showInlineRoutinePicker))

                    Button("+ New") {
                        store.openRoutineManager(createNew: true)
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: false))
                }
            } else if store.editRoutineMode {
                HStack(spacing: 8) {
                    TextField("Routine title", text: $routineTitleDraft)
                        .font(LedgerFont.serifMd())
                        .foregroundStyle(LedgerColor.inkPrimary)
                        .warmRecessedField()
                        .onSubmit {
                            store.saveRoutineTitle(routineTitleDraft)
                        }

                    Button("Save") {
                        store.saveRoutineTitle(routineTitleDraft)
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: true))

                    Button("Done") {
                        LedgerHaptics.light()
                        store.editRoutineMode = false
                    }
                    .buttonStyle(WarmActionButtonStyle())
                }
            } else {
                HStack(alignment: .center, spacing: 8) {
                    Text(wk.title)
                        .font(LedgerFont.serifLg(bold: true))
                        .foregroundStyle(LedgerColor.inkPrimary)
                        .lineLimit(2)

                    Spacer(minLength: 4)

                    Button(store.pickerOpen ? "Close" : "+ Add") {
                        LedgerHaptics.light()
                        store.showInlineRoutinePicker = false
                        if store.pickerOpen {
                            pickerFocused = false
                            store.pickerOpen = false
                            store.pickerQuery = ""
                            store.customLinkedVideoFilename = ""
                        } else {
                            store.pickerOpen = true
                            if store.pickerResults.isEmpty {
                                store.searchExercises(store.pickerQuery)
                            }
                            pickerFocused = true
                        }
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: store.pickerOpen))

                    Button("Edit") {
                        LedgerHaptics.light()
                        routineTitleDraft = wk.title
                        store.editRoutineMode = true
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: false))
                }

                HStack(spacing: 8) {
                    Button(store.showInlineRoutinePicker ? "Close List" : "Switch Routine ⌄") {
                        LedgerHaptics.light()
                        store.pickerOpen = false
                        pickerFocused = false
                        assignToDateOnly = !wk.isToday
                        store.showInlineRoutinePicker.toggle()
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: store.showInlineRoutinePicker))

                    Button("Remove") {
                        if wk.scheduleSource == .dateOverride {
                            store.removeRoutineFromSelectedDateOnly()
                        } else {
                            LedgerHaptics.heavy()
                            removeDialogPresented = true
                        }
                    }
                    .buttonStyle(WarmActionButtonStyle())

                    Spacer()
                }
            }
        }
    }

    private func inlineRoutinePickerPanel(_ wk: DayWorkout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button("This Date (\(wk.displayDateShort))") {
                    LedgerHaptics.light()
                    assignToDateOnly = true
                }
                .buttonStyle(WarmActionButtonStyle(isActive: assignToDateOnly))

                Button("Every \(wk.dayFullName)") {
                    LedgerHaptics.light()
                    assignToDateOnly = false
                }
                .buttonStyle(WarmActionButtonStyle(isActive: !assignToDateOnly))
            }

            if store.routines.isEmpty {
                Text("No saved routines yet. Create one below.")
                    .font(LedgerFont.serifMd(italic: true))
                    .foregroundStyle(LedgerColor.inkSecondary)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(store.routines) { r in
                            let isActive = wk.routineId == r.id
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.title)
                                        .font(LedgerFont.serifMd(semibold: true))
                                        .foregroundStyle(LedgerColor.inkPrimary)
                                        .lineLimit(1)
                                    Text("\(r.exercises.count) MOVEMENT\(r.exercises.count == 1 ? "" : "S")")
                                        .font(LedgerFont.sansSm())
                                        .foregroundStyle(LedgerColor.inkSecondary)
                                }
                                Spacer()
                                Button(isActive ? "Active" : "Assign") {
                                    store.assignRoutine(r.id, toSelectedDateOnly: assignToDateOnly)
                                }
                                .buttonStyle(WarmActionButtonStyle(isActive: isActive))
                            }
                        }
                    }
                }
                .frame(maxHeight: 190)
            }

            Button("+ Create Custom Routine") {
                store.showInlineRoutinePicker = false
                store.openRoutineManager(createNew: true)
            }
            .buttonStyle(WarmActionButtonStyle(isActive: true))
        }
        .softPanel()
    }

    private func exerciseBlock(_ ex: RoutineExerciseItem) -> some View {
        let isExpanded = store.expandedExerciseIds.contains(ex.id)
        let videoOpen = store.openVideoIds.contains(ex.id)
        let trendOpen = store.openTrendIds.contains(ex.id)
        let doneCount = ex.sets.filter(\.completed).count
        let isComplete = !ex.sets.isEmpty && doneCount == ex.sets.count
        let statusLine = "\(ex.muscleHint.uppercased())\(ex.isCustom ? " · CUSTOM" : "") · \(ex.sets.isEmpty ? "0 SETS" : "\(doneCount)/\(ex.sets.count) SETS")\(compactVolumeSuffix(ex))"

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    store.toggleExerciseExpanded(ex.id)
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        HandDrawnCheckboxView(isChecked: isComplete)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(ex.name)
                                .font(LedgerFont.serifMd(semibold: true))
                                .foregroundStyle(LedgerColor.inkPrimary)
                                .multilineTextAlignment(.leading)

                            Text(statusLine)
                                .font(LedgerFont.sansSm())
                                .tracking(0.8)
                                .foregroundStyle(LedgerColor.inkSecondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                HStack(spacing: 4) {
                    if store.editRoutineMode {
                        Button {
                            pendingConfirm = PendingActionConfirmation(
                                title: "Remove Exercise?",
                                message: "Remove \"\(ex.name)\" from this workout routine? Any past logged sets stay saved.",
                                confirmLabel: "Remove",
                                isDestructive: true
                            ) {
                                store.removeExerciseFromCurrentDay(ex.id)
                            }
                        } label: {
                            Text("×")
                                .font(LedgerFont.sansMd())
                        }
                        .buttonStyle(WarmIconButtonStyle())
                    }

                    Button {
                        store.toggleExerciseExpanded(ex.id)
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(LedgerColor.inkPrimary)
                            .frame(width: 28, height: 28)
                    }
                    .accessibilityLabel(isExpanded ? "Minimize \(ex.name)" : "Expand \(ex.name)")
                }
            }

            if isExpanded {
                Rectangle()
                    .fill(Color.white.opacity(0.42))
                    .frame(height: 1)

                HStack(spacing: 8) {
                    Button(progressionButtonLabel(ex)) {
                        store.toggleTrend(ex.id)
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: ex.progression.status == .yes))

                    Spacer(minLength: 4)

                    if BundleVideoResolver.url(for: ex.videoFilename) != nil {
                        Button {
                            store.toggleVideo(ex.id)
                        } label: {
                            HStack(spacing: 4) {
                                if !videoOpen {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 8))
                                }
                                Text(videoOpen ? "Hide" : "Film")
                            }
                        }
                        .buttonStyle(WarmActionButtonStyle(isActive: videoOpen))
                    }
                }

                if videoOpen, let url = BundleVideoResolver.url(for: ex.videoFilename) {
                    LoopingMoveKitPlayerView(url: url)
                        .frame(height: 196)
                        .background(LedgerColor.inkPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: LedgerColor.inkPrimary.opacity(0.14), radius: 8, x: 0, y: 4)
                }

                if trendOpen {
                    VolumeTrendlineChartView(progression: ex.progression, unit: unit)
                }

                if !ex.equipment.isEmpty || !ex.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        if !ex.equipment.isEmpty {
                            Text("EQUIPMENT: \(ex.equipment.uppercased())")
                                .font(LedgerFont.sansSm())
                                .tracking(0.8)
                                .foregroundStyle(LedgerColor.inkSecondary)
                        }
                        if !ex.notes.isEmpty {
                            Text(ex.notes)
                                .font(LedgerFont.serifMd(italic: true))
                                .foregroundStyle(LedgerColor.inkSecondary)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    if ex.sets.isEmpty {
                        Text("No sets logged yet — tap + Add Set or Complete & Minimize.")
                            .font(LedgerFont.serifMd(italic: true))
                            .foregroundStyle(LedgerColor.inkSecondary)
                    } else {
                        ForEach(ex.sets) { setItem in
                            SetRowView(setItem: setItem, exerciseId: ex.id, trackingType: ex.trackingType, unit: unit)
                        }
                    }

                    HStack(spacing: 8) {
                        Button("+ Add Set") {
                            store.addWorkingSet(for: ex)
                        }
                        .buttonStyle(WarmActionButtonStyle())

                        Spacer()

                        if isComplete {
                            Button("Minimize ↑") {
                                store.toggleExerciseExpanded(ex.id)
                            }
                            .buttonStyle(WarmActionButtonStyle(isActive: false))
                        } else {
                            Button("Complete & Minimize") {
                                store.completeAndMinimizeExercise(ex)
                            }
                            .buttonStyle(PrimaryActionButtonStyle())
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LedgerColor.parchmentLight.opacity(isExpanded ? 0.65 : 0.42))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.32), lineWidth: 0.8)
        )
    }

    private func progressionButtonLabel(_ ex: RoutineExerciseItem) -> String {
        let p = ex.progression
        switch p.status {
        case .yes:
            let sign = p.deltaPct > 0 ? "+" : ""
            return "Moving More · Yes ↑ \(sign)\(String(format: "%.1f", p.deltaPct))%"
        case .no:
            return "Moving More · No ↓ \(String(format: "%.1f", p.deltaPct))%"
        case .flat:
            let sign = p.deltaPct >= 0 ? "+" : ""
            return "Moving More · No → \(sign)\(String(format: "%.1f", p.deltaPct))%"
        case .baseline:
            return p.sessions.count == 1 ? "Baseline · 1 Session" : "Baseline"
        }
    }

    private func compactVolumeSuffix(_ ex: RoutineExerciseItem) -> String {
        let p = ex.progression
        guard p.latestVolume > 0 else { return "" }
        if p.metricUnit == "reps" {
            return " · \(Int(p.latestVolume.rounded())) REPS"
        }
        return " · \(Int(p.latestVolume.rounded()).formatted()) \(unit.uppercased())"
    }

    private func inlineExercisePicker() -> some View {
        let assignedIds = Set(store.workout?.exercises.map(\.id) ?? [])
        let qTrim = store.pickerQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let exactMatch = store.pickerResults.contains { $0.name.caseInsensitiveCompare(qTrim) == .orderedSame }

        return VStack(alignment: .leading, spacing: 10) {
            TextField(
                "Fuzzy search 588 MoveKit or type custom...",
                text: Binding(
                    get: { store.pickerQuery },
                    set: { store.searchExercises($0) }
                )
            )
            .font(LedgerFont.serifMd())
            .foregroundStyle(LedgerColor.inkPrimary)
            .focused($pickerFocused)
            .warmRecessedField()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("CUSTOM EXERCISES (\(store.customExercises.count))")
                        .font(LedgerFont.sansSm())
                        .tracking(1.0)
                        .foregroundStyle(LedgerColor.inkSecondary)
                    Spacer()
                    Button("+ Custom Studio") {
                        pickerFocused = false
                        store.openCustomExerciseStudio()
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: false))
                }

                if !qTrim.isEmpty && !exactMatch {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Create custom “\(qTrim)”")
                                .font(LedgerFont.serifMd(italic: true))
                                .foregroundStyle(LedgerColor.inkPrimary)
                            Spacer()
                            Button("+ Custom") {
                                pickerFocused = false
                                pendingConfirm = PendingActionConfirmation(
                                    title: "Create Custom Exercise?",
                                    message: "Create custom movement \"\(qTrim)\" and add it to your workout day?",
                                    confirmLabel: "Create",
                                    isDestructive: false
                                ) {
                                    store.createCustomExercise()
                                }
                            }
                            .buttonStyle(PrimaryActionButtonStyle())
                        }

                        let filmCandidates = store.pickerResults.filter { $0.videoFilename != nil }.prefix(6)
                        if !filmCandidates.isEmpty {
                            Picker("Link Film", selection: $store.customLinkedVideoFilename) {
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

                if store.pickerResults.isEmpty {
                    Text("No matching MoveKit films. Use “+ Custom” above.")
                        .font(LedgerFont.sansSm())
                        .foregroundStyle(LedgerColor.inkSecondary)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(store.pickerResults.prefix(20)) { res in
                                let already = assignedIds.contains(res.id)
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
                                        store.addExerciseToCurrentDay(res.id)
                                    }
                                    .buttonStyle(WarmActionButtonStyle(isActive: already))
                                    .disabled(already)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 210)
                }
            }
            .softPanel()
        }
    }
}

private struct SetRowView: View {
    @EnvironmentObject var store: LedgerStore
    let setItem: WorkoutSet
    let exerciseId: String
    let trackingType: String
    let unit: String

    @State private var repsText: String
    @State private var weightText: String
    @FocusState private var focusedField: Field?

    enum Field {
        case reps, weight
    }

    init(setItem: WorkoutSet, exerciseId: String, trackingType: String = "weighted", unit: String) {
        self.setItem = setItem
        self.exerciseId = exerciseId
        self.trackingType = trackingType
        self.unit = unit
        _repsText = State(initialValue: "\(setItem.reps)")
        let formattedW = setItem.weight.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(setItem.weight))"
            : String(format: "%.1f", setItem.weight)
        _weightText = State(initialValue: formattedW)
    }

    var body: some View {
        let isTimed = trackingType == "timed"
        return HStack(spacing: 8) {
            Text(String(format: "%02d", setItem.setNumber))
                .font(LedgerFont.sansSm())
                .monospacedDigit()
                .foregroundStyle(LedgerColor.inkSecondary)
                .frame(width: 22, alignment: .leading)

            TextField("0", text: $repsText)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(LedgerFont.sansMd())
                .monospacedDigit()
                .foregroundStyle(LedgerColor.inkPrimary)
                .focused($focusedField, equals: .reps)
                .frame(width: 48)
                .padding(.vertical, 4)
                .background(
                    LinearGradient(
                        colors: [LedgerColor.warmAmber.opacity(0.03), LedgerColor.warmAmber.opacity(0.14)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            if isTimed {
                Text("SEC")
                    .font(LedgerFont.sansSm())
                    .foregroundStyle(LedgerColor.inkSecondary)
            } else {
                Text("×")
                    .font(LedgerFont.sansSm())
                    .foregroundStyle(LedgerColor.inkSecondary)

                TextField("0", text: $weightText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .font(LedgerFont.sansMd())
                    .monospacedDigit()
                    .foregroundStyle(LedgerColor.inkPrimary)
                    .focused($focusedField, equals: .weight)
                    .frame(width: 56)
                    .padding(.vertical, 4)
                    .background(
                        LinearGradient(
                            colors: [LedgerColor.warmAmber.opacity(0.03), LedgerColor.warmAmber.opacity(0.14)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text(unit.uppercased())
                    .font(LedgerFont.sansSm())
                    .foregroundStyle(LedgerColor.inkSecondary)
            }

            Spacer()

            Button {
                commitValues(completed: !setItem.completed)
            } label: {
                HandDrawnCheckboxView(isChecked: setItem.completed)
            }

            Button {
                store.deleteSet(setItem.id)
            } label: {
                Text("×")
                    .font(LedgerFont.sansMd())
            }
            .buttonStyle(WarmIconButtonStyle())
        }
        .onChange(of: focusedField) { oldVal, newVal in
            if oldVal != nil && newVal == nil {
                commitValues(completed: setItem.completed)
            }
        }
        .onChange(of: setItem) { _, updated in
            if focusedField == nil {
                repsText = "\(updated.reps)"
                weightText = updated.weight.truncatingRemainder(dividingBy: 1) == 0
                    ? "\(Int(updated.weight))"
                    : String(format: "%.1f", updated.weight)
            }
        }
    }

    private func commitValues(completed: Bool) {
        let r = max(0, Int(repsText.trimmingCharacters(in: .whitespaces)) ?? setItem.reps)
        let w = max(0.0, Double(weightText.trimmingCharacters(in: .whitespaces)) ?? setItem.weight)
        store.updateSet(setItem, exerciseId: exerciseId, reps: r, weight: w, completed: completed)
    }
}

struct VolumeTrendlineChartView: View {
    let progression: ProgressionSummary
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if progression.sessions.count < 2 {
                Text("Log at least 2 sessions to plot total volume trendline (\(Int(progression.latestVolume)) logged so far).")
                    .font(LedgerFont.sansSm())
                    .foregroundStyle(LedgerColor.inkSecondary)
            } else {
                let sessions = progression.sessions
                let unitLabel = progression.metricUnit == "reps" ? "reps" : "\(unit) vol"

                HStack {
                    Text(unitLabel.uppercased())
                    Spacer()
                    Text("\(sessions.count) SESSIONS")
                }
                .font(LedgerFont.sansSm())
                .tracking(1.0)
                .foregroundStyle(LedgerColor.inkSecondary)

                Canvas { ctx, size in
                    let padX: CGFloat = 16
                    let padY: CGFloat = 14
                    let chartH = size.height - 16
                    let ys = sessions.map(\.volume)
                    let ts = progression.trendPoints.isEmpty ? ys : progression.trendPoints
                    let allVals = ys + ts
                    var minV = allVals.min() ?? 0
                    var maxV = allVals.max() ?? 10
                    if maxV - minV < 1 {
                        minV = max(0, minV - 10)
                        maxV += 10
                    }
                    let span = maxV - minV

                    func pointX(_ i: Int) -> CGFloat {
                        padX + (CGFloat(i) / CGFloat(max(1, sessions.count - 1))) * (size.width - padX * 2)
                    }
                    func pointY(_ v: Double) -> CGFloat {
                        chartH - padY - CGFloat((v - minV) / span) * (chartH - padY * 2)
                    }

                    // Baseline
                    var base = Path()
                    base.move(to: CGPoint(x: padX, y: chartH - padY))
                    base.addLine(to: CGPoint(x: size.width - padX, y: chartH - padY))
                    ctx.stroke(base, with: .color(LedgerColor.inkPrimary.opacity(0.14)), lineWidth: 1)

                    // Regression dashed trendline
                    if let firstT = ts.first, let lastT = ts.last {
                        var trend = Path()
                        trend.move(to: CGPoint(x: pointX(0), y: pointY(firstT)))
                        trend.addLine(to: CGPoint(x: pointX(sessions.count - 1), y: pointY(lastT)))
                        ctx.stroke(
                            trend,
                            with: .color(LedgerColor.inkSecondary),
                            style: StrokeStyle(lineWidth: 1.2, dash: [4, 4])
                        )
                    }

                    // Actual volume line
                    var line = Path()
                    for (i, s) in sessions.enumerated() {
                        let pt = CGPoint(x: pointX(i), y: pointY(s.volume))
                        if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
                    }
                    ctx.stroke(
                        line,
                        with: .color(LedgerColor.inkPrimary),
                        style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                    )

                    // Nodes
                    for (i, s) in sessions.enumerated() {
                        let pt = CGPoint(x: pointX(i), y: pointY(s.volume))
                        let isLast = i == sessions.count - 1
                        let r: CGFloat = isLast ? 3.5 : 2.5
                        let circle = Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2))
                        ctx.fill(circle, with: .color(isLast ? LedgerColor.inkPrimary : LedgerColor.parchmentBase))
                        ctx.stroke(circle, with: .color(LedgerColor.inkPrimary), lineWidth: 1.4)
                    }
                }
                .frame(height: 82)

                let verdict: String = {
                    switch progression.status {
                    case .yes:
                        return "Moving more weight over time (+\(String(format: "%.1f", progression.deltaPct))%)"
                    case .flat:
                        let sign = progression.deltaPct >= 0 ? "+" : ""
                        return "Volume holding steady (\(sign)\(String(format: "%.1f", progression.deltaPct))%)"
                    default:
                        return "Volume dipped (\(String(format: "%.1f", progression.deltaPct))%) across last \(sessions.count) sessions"
                    }
                }()

                Text(verdict)
                    .font(LedgerFont.serifMd(italic: true))
                    .foregroundStyle(LedgerColor.inkPrimary)
            }
        }
        .softPanel()
    }
}

struct LoopingMoveKitPlayerView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> LoopingPlayerUIView {
        LoopingPlayerUIView(url: url)
    }

    func updateUIView(_ uiView: LoopingPlayerUIView, context: Context) {
        uiView.load(url: url)
    }
}

final class LoopingPlayerUIView: UIView {
    private let playerLayer = AVPlayerLayer()
    private var queuePlayer: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentURL: URL?

    init(url: URL) {
        super.init(frame: .zero)
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
        load(url: url)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func load(url: URL) {
        guard currentURL != url else { return }
        currentURL = url
        looper?.disableLooping()
        queuePlayer?.pause()

        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        let loop = AVPlayerLooper(player: player, templateItem: item)
        self.queuePlayer = player
        self.looper = loop
        playerLayer.player = player
        player.play()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }

    deinit {
        looper?.disableLooping()
        queuePlayer?.pause()
    }
}
