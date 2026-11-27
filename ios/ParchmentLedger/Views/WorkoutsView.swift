// MARK: - Workouts Pillar View
//
// Daily training ledger showing the weekly date strip, collapsible monthly calendar, scheduled
// routine header, inline exercise/routine pickers, MoveKit looping video demos, per-set logging
// (`weighted`, `bodyweight`, `timed`), and linear progression trendline charts.

import AVFoundation
import SwiftUI

struct WorkoutsView: View {
    @EnvironmentObject var store: LedgerStore
    @State private var routineTitleDraft: String = ""
    @State private var routineEmblemDraft: String = ""
    @State private var removePromptInfo: RoutineRemovalInfo? = nil
    @State private var inlineAssignScope: InlineAssignScope = .weeks(.defaultSpan)
    @State private var monthSlideDirection: Int = 1
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
                        dayScheduleBar(wk)
                            .inkWritten(index: 1, epoch: store.inkWriteEpoch)

                        if store.showInlineRoutinePicker {
                            inlineRoutinePickerPanel(wk)
                        }

                        if !wk.hasRoutines {
                            Rectangle()
                                .fill(Color.white.opacity(0.58))
                                .frame(height: 1.2)
                                .inkWritten(index: 2, epoch: store.inkWriteEpoch)
                        }
                    }

                    if !wk.hasRoutines {
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
                    } else {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(Array(wk.routines.enumerated()), id: \.element.id) { sectionIdx, section in
                                VStack(alignment: .leading, spacing: 12) {
                                    routineSectionHeader(section, in: wk)
                                        .inkWritten(index: sectionIdx + 2, epoch: store.inkWriteEpoch)

                                    if store.pickerOpen && store.pickerTargetRoutineId == section.id {
                                        inlineExercisePicker(for: section)
                                    }

                                    Rectangle()
                                        .fill(Color.white.opacity(0.58))
                                        .frame(height: 1.2)

                                    if section.exercises.isEmpty {
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
                                        .padding(.vertical, 20)
                                    } else {
                                        VStack(alignment: .leading, spacing: 12) {
                                            ForEach(Array(section.exercises.enumerated()), id: \.element.id) { idx, ex in
                                                exerciseBlock(ex, routineId: section.id)
                                                    .inkWritten(index: idx + 3, epoch: store.inkWriteEpoch)
                                            }
                                        }
                                    }
                                }
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
            "Remove \(removePromptInfo?.title ?? "Routine")?",
            isPresented: Binding(
                get: { removePromptInfo != nil },
                set: { if !$0 { removePromptInfo = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let info = removePromptInfo {
                Button("Just This Day (\(info.displayDateShort))", role: .destructive) {
                    store.unassignRoutine(info.routineId, fromSelectedDateOnly: true)
                    removePromptInfo = nil
                }
                if info.hasRemainingBeyondToday {
                    let remLabel = info.hasRecurringWeekly
                        ? "This Day & All Remaining"
                        : "This Day & Remaining (\(info.remainingCount) Days)"
                    Button(remLabel, role: .destructive) {
                        store.unassignRoutineAndRemaining(info.routineId)
                        removePromptInfo = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                removePromptInfo = nil
            }
        } message: {
            if let info = removePromptInfo {
                if info.hasRemainingBeyondToday {
                    Text("Remove \"\(info.title)\" from \(info.displayDateShort) only, or from this day and all remaining scheduled entries? Logged workout sets stay saved.")
                } else {
                    Text("Remove \"\(info.title)\" from \(info.displayDateShort)? Logged workout sets stay saved.")
                }
            }
        }
    }

    private func monthlyCalendarPanel() -> some View {
        let headers = ["M", "T", "W", "T", "F", "S", "S"]
        let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        let monthKey = DatabaseManager.monthAnchorKey(store.displayedMonthAnchor)

        return VStack(alignment: .leading, spacing: 10) {
            CenteredCalendarHeaderView(
                title: DatabaseManager.monthTitle(store.displayedMonthAnchor),
                onPrevious: {
                    monthSlideDirection = -1
                    withAnimation(.easeInOut(duration: 0.24)) {
                        store.shiftDisplayedMonth(by: -1)
                    }
                },
                onNext: {
                    monthSlideDirection = 1
                    withAnimation(.easeInOut(duration: 0.24)) {
                        store.shiftDisplayedMonth(by: 1)
                    }
                }
            )

            HStack {
                Spacer()
                Button("Today") {
                    store.jumpToToday()
                }
                .buttonStyle(WarmActionButtonStyle(isActive: store.selectedDate == store.todayDate))
            }

            HStack(spacing: 4) {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, sym in
                    Text(sym)
                        .font(LedgerFont.sansSm())
                        .foregroundStyle(LedgerColor.inkSecondary)
                        .frame(maxWidth: .infinity)
                }
            }

            ZStack(alignment: .top) {
                LazyVGrid(columns: cols, spacing: 6) {
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

                                    CalendarEmblemStripView(
                                        markers: slot.routineMarkers,
                                        hasLoggedSets: slot.hasLoggedSets,
                                        compact: true
                                    )
                                    .frame(height: 16, alignment: .top)
                                }
                                .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42, alignment: .top)
                                .padding(.top, 5)
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
                                .frame(height: 42)
                        }
                    }
                }
                .id(monthKey)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: monthSlideDirection >= 0 ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: monthSlideDirection >= 0 ? .leading : .trailing).combined(with: .opacity)
                    )
                )
            }
            .frame(height: 282, alignment: .top)
            .clipped()

            let emblemRoutines = store.routines.filter { !$0.emblem.isEmpty }
            if !emblemRoutines.isEmpty {
                Rectangle()
                    .fill(Color.white.opacity(0.45))
                    .frame(height: 1)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 6)], alignment: .leading, spacing: 4) {
                    ForEach(emblemRoutines) { rt in
                        HStack(spacing: 5) {
                            RoutineEmblemBadgeView(emblem: rt.emblem, fontSize: 11)
                            Text(rt.title)
                                .font(LedgerFont.sansSm())
                                .foregroundStyle(LedgerColor.inkSecondary)
                                .lineLimit(1)
                        }
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

                        CalendarEmblemStripView(
                            markers: slot.routineMarkers,
                            hasLoggedSets: slot.hasLoggedSets,
                            compact: false
                        )
                        .frame(height: 16, alignment: .top)
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

    private func dayScheduleBar(_ wk: DayWorkout) -> some View {
        let countLabel = !wk.hasRoutines ? "REST" : "\(wk.completedExercises)/\(wk.totalExercises) DONE"
        let prefix = wk.routines.count > 1 ? "SCHEDULED ROUTINES (\(wk.routines.count))" : "SCHEDULED ROUTINE"
        let overline = wk.isToday
            ? "\(prefix) · \(countLabel)"
            : "\(prefix) · \(wk.dayName.uppercased()) \(wk.displayDateShort.uppercased()) · \(countLabel)"

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(overline)
                    .font(LedgerFont.sansSm())
                    .tracking(1.6)
                    .foregroundStyle(LedgerColor.inkSecondary)

                Spacer(minLength: 4)

                if wk.hasRoutines {
                    Button(store.showInlineRoutinePicker ? "Close List" : "+ Routine") {
                        LedgerHaptics.light()
                        store.closeExercisePicker()
                        pickerFocused = false
                        inlineAssignScope = wk.isToday ? .weeks(.defaultSpan) : .thisDateOnly
                        store.showInlineRoutinePicker.toggle()
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: store.showInlineRoutinePicker))
                }
            }

            if !wk.hasRoutines {
                HStack(alignment: .center, spacing: 8) {
                    Text("No Routine")
                        .font(LedgerFont.serifLg(bold: true))
                        .foregroundStyle(LedgerColor.inkSecondary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Button(store.showInlineRoutinePicker ? "Close" : "+ Assign") {
                        LedgerHaptics.light()
                        store.closeExercisePicker()
                        pickerFocused = false
                        inlineAssignScope = wk.isToday ? .weeks(.defaultSpan) : .thisDateOnly
                        store.showInlineRoutinePicker.toggle()
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: store.showInlineRoutinePicker))

                    Button("+ New") {
                        store.openRoutineManager(createNew: true)
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: false))
                }
            }
        }
    }

    private func routineSectionHeader(_ section: DayRoutineSection, in wk: DayWorkout) -> some View {
        let isEditingThis = store.editRoutineMode && store.editingRoutineId == section.id
        let isPickerForThis = store.pickerOpen && store.pickerTargetRoutineId == section.id

        return VStack(alignment: .leading, spacing: 8) {
            if isEditingThis {
                HStack(spacing: 8) {
                    TextField("Routine title", text: $routineTitleDraft)
                        .font(LedgerFont.serifMd())
                        .foregroundStyle(LedgerColor.inkPrimary)
                        .warmRecessedField()
                        .onSubmit {
                            store.saveRoutineDetails(routineId: section.id, title: routineTitleDraft, emblem: routineEmblemDraft)
                        }

                    Button("Save") {
                        store.saveRoutineDetails(routineId: section.id, title: routineTitleDraft, emblem: routineEmblemDraft)
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: true))

                    Button("Done") {
                        LedgerHaptics.light()
                        store.editRoutineMode = false
                        store.editingRoutineId = nil
                    }
                    .buttonStyle(WarmActionButtonStyle())
                }

                RoutineEmblemPickerView(selectedEmblem: $routineEmblemDraft)
            } else {
                HStack(alignment: .center, spacing: 8) {
                    if !section.emblem.isEmpty {
                        RoutineEmblemBadgeView(emblem: section.emblem, fontSize: 18)
                    }

                    Text(section.title)
                        .font(LedgerFont.serifLg(bold: true))
                        .foregroundStyle(LedgerColor.inkPrimary)
                        .lineLimit(2)

                    if wk.routines.count > 1 {
                        Text("\(section.completedExercises)/\(section.totalExercises)")
                            .font(LedgerFont.sansSm())
                            .tracking(0.8)
                            .foregroundStyle(LedgerColor.inkSecondary)
                    }

                    Spacer(minLength: 4)

                    Button(isPickerForThis ? "Close" : "+ Add") {
                        store.showInlineRoutinePicker = false
                        if isPickerForThis {
                            pickerFocused = false
                            store.closeExercisePicker()
                        } else {
                            store.openExercisePicker(for: section.id)
                            pickerFocused = true
                        }
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: isPickerForThis))

                    Button("Edit") {
                        LedgerHaptics.light()
                        routineTitleDraft = section.title
                        routineEmblemDraft = section.emblem
                        store.editingRoutineId = section.id
                        store.editRoutineMode = true
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: false))
                }

                HStack(spacing: 8) {
                    Button("Remove") {
                        LedgerHaptics.heavy()
                        removePromptInfo = store.removalInfo(forRoutineId: section.id, title: section.title)
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
                Menu {
                    Button {
                        LedgerHaptics.light()
                        inlineAssignScope = .thisDateOnly
                    } label: {
                        if inlineAssignScope == .thisDateOnly {
                            Label(InlineAssignScope.thisDateOnly.menuLabel(dateShort: wk.displayDateShort, weekdayFull: wk.dayFullName), systemImage: "checkmark")
                        } else {
                            Text(InlineAssignScope.thisDateOnly.menuLabel(dateShort: wk.displayDateShort, weekdayFull: wk.dayFullName))
                        }
                    }

                    Divider()

                    ForEach(RoutineScheduleSpan.allCases) { span in
                        let option = InlineAssignScope.weeks(span)
                        Button {
                            LedgerHaptics.light()
                            inlineAssignScope = option
                        } label: {
                            if inlineAssignScope == option {
                                Label(option.menuLabel(dateShort: wk.displayDateShort, weekdayFull: wk.dayFullName), systemImage: "checkmark")
                            } else {
                                Text(option.menuLabel(dateShort: wk.displayDateShort, weekdayFull: wk.dayFullName))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(inlineAssignScope.triggerLabel(dateShort: wk.displayDateShort, weekdayShort: wk.dayName))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .uniformSecondaryButtonChrome(fullWidth: false)
                }

                Spacer()

                Button("Done") {
                    LedgerHaptics.light()
                    store.showInlineRoutinePicker = false
                }
                .buttonStyle(WarmActionButtonStyle())
            }

            if store.routines.isEmpty {
                Text("No saved routines yet. Create one below.")
                    .font(LedgerFont.serifMd(italic: true))
                    .foregroundStyle(LedgerColor.inkSecondary)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(store.routines) { r in
                            let isAssigned = wk.routineIds.contains(r.id)
                            HStack(spacing: 8) {
                                if !r.emblem.isEmpty {
                                    RoutineEmblemBadgeView(emblem: r.emblem, fontSize: 15)
                                }
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
                                Button(isAssigned ? "Assigned ✓" : "+ Add") {
                                    if isAssigned {
                                        LedgerHaptics.heavy()
                                        removePromptInfo = store.removalInfo(forRoutineId: r.id, title: r.title)
                                    } else {
                                        store.assignRoutine(r.id, scope: inlineAssignScope)
                                    }
                                }
                                .buttonStyle(WarmActionButtonStyle(isActive: isAssigned))
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }

            Button("+ Create Custom Routine") {
                store.showInlineRoutinePicker = false
                store.openRoutineManager(createNew: true)
            }
            .buttonStyle(WarmActionButtonStyle(isActive: true))
        }
        .softPanel()
    }

    private func exerciseBlock(_ ex: RoutineExerciseItem, routineId: String) -> some View {
        let expandKey = "\(routineId)_\(ex.id)"
        let isExpanded = store.expandedExerciseIds.contains(expandKey)
        let videoOpen = store.openVideoIds.contains(expandKey)
        let trendOpen = store.openTrendIds.contains(expandKey)
        let doneCount = ex.sets.filter(\.completed).count
        let isComplete = !ex.sets.isEmpty && doneCount == ex.sets.count
        let statusLine = "\(ex.muscleHint.uppercased())\(ex.isCustom ? " · CUSTOM" : "") · \(ex.sets.isEmpty ? "0 SETS" : "\(doneCount)/\(ex.sets.count) SETS")\(compactVolumeSuffix(ex))"

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    store.toggleExerciseExpanded(expandKey)
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
                    if store.editRoutineMode && store.editingRoutineId == routineId {
                        Button {
                            pendingConfirm = PendingActionConfirmation(
                                title: "Remove Exercise?",
                                message: "Remove \"\(ex.name)\" from this workout routine? Any past logged sets stay saved.",
                                confirmLabel: "Remove",
                                isDestructive: true
                            ) {
                                store.removeExercise(ex.id, fromRoutine: routineId)
                            }
                        } label: {
                            Text("×")
                                .font(LedgerFont.sansMd())
                        }
                        .buttonStyle(WarmIconButtonStyle())
                    }

                    Button {
                        store.toggleExerciseExpanded(expandKey)
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
                        store.toggleTrend(expandKey)
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: ex.progression.status == .yes))

                    Spacer(minLength: 4)

                    if BundleVideoResolver.url(for: ex.videoFilename) != nil {
                        Button {
                            store.toggleVideo(expandKey)
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
                                store.toggleExerciseExpanded(expandKey)
                            }
                            .buttonStyle(WarmActionButtonStyle(isActive: false))
                        } else {
                            Button("Complete & Minimize") {
                                store.completeAndMinimizeExercise(ex, key: expandKey)
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
        if p.metricUnit == "sec" {
            return " · \(Int(p.latestVolume.rounded())) SEC"
        }
        if p.metricUnit == "reps" {
            return " · \(Int(p.latestVolume.rounded())) REPS"
        }
        return " · \(Int(p.latestVolume.rounded()).formatted()) \(unit.uppercased())"
    }

    private func inlineExercisePicker(for section: DayRoutineSection) -> some View {
        let assignedIds = Set(section.exercises.map(\.id))
        let qTrim = store.pickerQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let exactMatch = store.pickerResults.contains { $0.name.caseInsensitiveCompare(qTrim) == .orderedSame }
        let visibleResults = Array(store.pickerResults.prefix(
            (store.pickerMuscleRegion == .all && qTrim.isEmpty) ? 20 : 50
        ))

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

            MuscleGroupFilterBar(
                selectedRegion: Binding(
                    get: { store.pickerMuscleRegion },
                    set: { newRegion in
                        store.pickerMuscleRegion = newRegion
                        store.pickerMuscleSubGroup = nil
                        store.refreshPickerResults()
                    }
                ),
                selectedSubGroup: Binding(
                    get: { store.pickerMuscleSubGroup },
                    set: { newSub in
                        store.pickerMuscleSubGroup = newSub
                        if let sub = newSub {
                            store.customQuickMuscleGroup = sub
                        }
                        store.refreshPickerResults()
                    }
                )
            )

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
                                    message: "Create custom movement \"\(qTrim)\" (\(store.customQuickMuscleGroup.rawValue)) and add it to \"\(section.title)\"?",
                                    confirmLabel: "Create",
                                    isDestructive: false
                                ) {
                                    store.createCustomExercise(muscleHint: store.customQuickMuscleGroup.rawValue)
                                }
                            }
                            .buttonStyle(PrimaryActionButtonStyle())
                        }

                        Picker("Muscle Group", selection: $store.customQuickMuscleGroup) {
                            ForEach(MuscleSubGroup.allCases) { grp in
                                Text(grp.rawValue).tag(grp)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(LedgerColor.inkPrimary)
                        .font(LedgerFont.sansSm())

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

                if visibleResults.isEmpty {
                    Text("No matching movements in this group. Clear filters or use “+ Custom” above.")
                        .font(LedgerFont.sansSm())
                        .foregroundStyle(LedgerColor.inkSecondary)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(visibleResults) { res in
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
                                        store.addExerciseToCurrentDay(res.id, routineId: section.id)
                                    }
                                    .buttonStyle(WarmActionButtonStyle(isActive: already))
                                    .disabled(already)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
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
                let metricName = progression.metricUnit == "sec" ? "time" : (progression.metricUnit == "reps" ? "reps" : "total volume")
                let baselineValue = progression.metricUnit == "sec"
                    ? "\(Int(progression.latestVolume)) sec"
                    : (progression.metricUnit == "reps" ? "\(Int(progression.latestVolume)) reps" : "\(Int(progression.latestVolume))")
                Text("Log at least 2 sessions to plot \(metricName) trendline (\(baselineValue) logged so far).")
                    .font(LedgerFont.sansSm())
                    .foregroundStyle(LedgerColor.inkSecondary)
            } else {
                let sessions = progression.sessions
                let unitLabel = progression.metricUnit == "sec" ? "sec" : (progression.metricUnit == "reps" ? "reps" : "\(unit) vol")

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
