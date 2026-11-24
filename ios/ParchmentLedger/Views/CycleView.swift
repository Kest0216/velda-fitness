import SwiftUI

struct CycleView: View {
    @EnvironmentObject var store: LedgerStore

    @State private var flowDraft: CycleFlowLevel = .none
    @State private var symptomsDraft: Set<String> = []
    @State private var moodDraft: String = ""
    @State private var energyDraft: Int = 3
    @State private var bbtDraft: String = ""
    @State private var notesDraft: String = ""
    @State private var showMedicalSources: Bool = false
    @State private var pendingConfirm: PendingActionConfirmation? = nil

    private let symptomOptions = [
        "Cramps", "Fatigue", "Headache", "Bloating",
        "Tender", "Cravings", "Backache", "Clear Skin",
    ]
    private let moodOptions = ["Calm", "Steady", "Sensitive", "Energized", "Low"]

    private var selectedDateLabel: String {
        let isToday = store.cycleSelectedDate == store.todayDate
        let med = DatabaseManager.mediumDateLabel(store.cycleSelectedDate).uppercased()
        return isToday ? "TODAY · \(med)" : med
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                summaryPanel
                    .inkWritten(index: 0, epoch: store.inkWriteEpoch)

                cycleMonthCalendar
                    .inkWritten(index: 1, epoch: store.inkWriteEpoch)

                if let insight = store.cycleSummary.regularityInsight {
                    regularityInsightPanel(insight)
                        .inkWritten(index: 2, epoch: store.inkWriteEpoch)
                }

                dayLoggerPanel
                    .inkWritten(index: 3, epoch: store.inkWriteEpoch)

                if !store.cycleSummary.periods.isEmpty {
                    periodHistorySection
                        .inkWritten(index: 4, epoch: store.inkWriteEpoch)
                }

                disclaimerCard
                    .inkWritten(index: 5, epoch: store.inkWriteEpoch)
            }
            .padding(.top, 6)
            .padding(.bottom, 56)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            syncDrafts(for: store.cycleSelectedDate)
        }
        .onChange(of: store.cycleSelectedDate) { _, newDate in
            syncDrafts(for: newDate)
        }
        .sheet(isPresented: $showMedicalSources) {
            MedicalSourcesSheet()
        }
        .actionConfirmationAlert($pendingConfirm)
    }

    // MARK: - Summary Card & Equal Stat Boxes

    private var summaryPanel: some View {
        let s = store.cycleSummary
        let headline: String = {
            if let cd = s.currentCycleDay {
                return "Cycle Day \(cd)"
            }
            return "Cycle Ledger"
        }()

        let subline: String = {
            if let d = s.daysUntilNextPeriod {
                if d > 0 { return "\(s.estimatedPhase.uppercased()) · NEXT WINDOW IN ~\(d)D" }
                if d == 0 { return "\(s.estimatedPhase.uppercased()) · PREDICTED WINDOW TODAY" }
                return "\(s.estimatedPhase.uppercased()) · WINDOW \(abs(d))D AGO"
            }
            return "LOG FLOW DAYS BELOW TO DETECT PHASES & WINDOWS"
        }()

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                SectionHeaderView(
                    title: headline,
                    subtitle: subline
                )

                Spacer(minLength: 8)

                Button("Today") {
                    store.selectCycleDate(store.todayDate)
                }
                .buttonStyle(WarmActionButtonStyle(isActive: store.cycleSelectedDate == store.todayDate))
            }

            HStack(spacing: 10) {
                statBox(label: "AVG CYCLE", value: "\(s.avgCycleLength)D")
                statBox(label: "AVG PERIOD", value: "\(s.avgPeriodLength)D")
                statBox(label: "CYCLES", value: "\(s.periods.count)")
            }
        }
        .softPanel()
    }

    private func statBox(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(LedgerFont.serifLg(bold: true))
                .monospacedDigit()
                .foregroundStyle(LedgerColor.inkPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(label)
                .font(LedgerFont.sansSm())
                .tracking(0.8)
                .foregroundStyle(LedgerColor.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 62, maxHeight: 62)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LedgerColor.parchmentLight.opacity(0.68))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(LedgerColor.inkPrimary.opacity(0.14), lineWidth: 0.9)
        )
    }

    // MARK: - Centered & Color-Coded Monthly Calendar

    private var cycleMonthCalendar: some View {
        let slots = DatabaseManager.cycleMonthSlots(anchor: store.cycleMonthAnchor, todayDate: store.todayDate)
        let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        let headers = ["M", "T", "W", "T", "F", "S", "S"]

        return VStack(alignment: .leading, spacing: 10) {
            CenteredCalendarHeaderView(
                title: DatabaseManager.monthTitle(store.cycleMonthAnchor),
                onPrevious: { store.shiftCycleMonth(by: -1) },
                onNext: { store.shiftCycleMonth(by: 1) }
            )

            LazyVGrid(columns: cols, spacing: 6) {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, h in
                    Text(h)
                        .font(LedgerFont.sansSm())
                        .foregroundStyle(LedgerColor.inkSecondary)
                        .frame(maxWidth: .infinity)
                }

                ForEach(slots) { slot in
                    if let iso = slot.isoDate, let day = slot.dayNumber {
                        let log = store.cycleLog(forDate: iso)
                        let hasFlow = log.map { $0.flow != CycleFlowLevel.none } ?? false
                        let phase = store.cycleSummary.dayPhases[iso] ?? .none
                        let isPredicted = phase == .predictedPeriod
                        let isSelected = iso == store.cycleSelectedDate

                        Button {
                            store.selectCycleDate(iso)
                        } label: {
                            VStack(spacing: 2) {
                                Text("\(day)")
                                    .font(LedgerFont.sansSm(semibold: isSelected || slot.isToday || hasFlow))
                                    .monospacedDigit()
                                    .foregroundStyle(LedgerColor.inkPrimary)

                                Circle()
                                    .fill(dotColor(log: log, isToday: slot.isToday, phase: phase))
                                    .frame(width: 4, height: 4)
                            }
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(phaseFillColor(phase: phase, isSelected: isSelected))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                Group {
                                    if isSelected {
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(LedgerColor.inkPrimary, lineWidth: 1.6)
                                    } else if isPredicted {
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(
                                                LedgerColor.cycleRose.opacity(0.75),
                                                style: StrokeStyle(lineWidth: 1.0, dash: [3, 2])
                                            )
                                    } else if slot.isToday {
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(LedgerColor.warmTerracotta, lineWidth: 1.1)
                                    }
                                }
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(height: 34)
                    }
                }
            }

            // Color-coded phase legend
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    legendChip(color: LedgerColor.cycleRose.opacity(0.45), label: "Period", dashed: false)
                    legendChip(color: LedgerColor.cycleRose.opacity(0.25), label: "Predicted", dashed: true)
                    legendChip(color: LedgerColor.phaseFollicular.opacity(0.45), label: "Follicular", dashed: false)
                    legendChip(color: LedgerColor.phaseOvulatory.opacity(0.45), label: "Ovulatory", dashed: false)
                    legendChip(color: LedgerColor.phaseLuteal.opacity(0.42), label: "Luteal", dashed: false)
                }
                .padding(.top, 4)
            }
        }
        .softPanel()
    }

    private func phaseFillColor(phase: CyclePhase, isSelected: Bool) -> Color {
        switch phase {
        case .menstrual:
            return LedgerColor.cycleRose.opacity(isSelected ? 0.36 : 0.24)
        case .predictedPeriod:
            return LedgerColor.cycleRose.opacity(isSelected ? 0.18 : 0.08)
        case .follicular:
            return LedgerColor.phaseFollicular.opacity(isSelected ? 0.36 : 0.22)
        case .ovulatory:
            return LedgerColor.phaseOvulatory.opacity(isSelected ? 0.36 : 0.24)
        case .luteal:
            return LedgerColor.phaseLuteal.opacity(isSelected ? 0.34 : 0.20)
        case .none:
            return isSelected ? LedgerColor.warmTerracotta.opacity(0.16) : .clear
        }
    }

    private func dotColor(log: CycleLogEntry?, isToday: Bool, phase: CyclePhase) -> Color {
        if let log, log.flow != .none {
            return LedgerColor.cycleRose
        }
        if log != nil {
            return LedgerColor.inkPrimary.opacity(0.65)
        }
        if isToday {
            return LedgerColor.warmTerracotta
        }
        if phase == .ovulatory {
            return LedgerColor.phaseOvulatory
        }
        return .clear
    }

    private func legendChip(color: Color, label: String, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(
                            dashed ? LedgerColor.cycleRose.opacity(0.8) : LedgerColor.inkPrimary.opacity(0.22),
                            style: dashed ? StrokeStyle(lineWidth: 1, dash: [2, 1.5]) : StrokeStyle(lineWidth: 0.7)
                        )
                )

            Text(label)
                .font(LedgerFont.sansSm())
                .foregroundStyle(LedgerColor.inkSecondary)
        }
    }

    // MARK: - Regularity & PCOS Pattern Awareness

    private func regularityInsightPanel(_ insight: CycleRegularityInsight) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: insight.isIrregular ? "exclamationmark.circle.fill" : "checkmark.seal.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(insight.isIrregular ? LedgerColor.warmTerracotta : LedgerColor.verifiedSage)
                    .padding(.top, 3)

                SectionHeaderView(
                    title: insight.headline,
                    subtitle: insight.isIrregular ? "CYCLE VARIATION & PCOS AWARENESS" : "CYCLE CONSISTENCY"
                )
            }

            ForEach(insight.observations, id: \.self) { line in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                        .font(LedgerFont.sansSm(semibold: true))
                        .foregroundStyle(LedgerColor.inkPrimary)
                    Text(line)
                        .font(LedgerFont.sansSm())
                        .foregroundStyle(LedgerColor.inkPrimary)
                }
            }

            Text(insight.guidance)
                .font(LedgerFont.serifMd(italic: true))
                .foregroundStyle(LedgerColor.inkSecondary)
                .padding(.top, 2)

            Button {
                LedgerHaptics.light()
                showMedicalSources = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 10, weight: .semibold))
                    Text("View Clinical Sources")
                }
            }
            .buttonStyle(WarmActionButtonStyle(isActive: false))
        }
        .softPanel()
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    insight.isIrregular ? LedgerColor.warmTerracotta.opacity(0.45) : LedgerColor.verifiedSage.opacity(0.35),
                    lineWidth: 1.1
                )
        )
    }

    // MARK: - Daily Flow & Symptom Logger

    private var dayLoggerPanel: some View {
        let existing = store.cycleLog(forDate: store.cycleSelectedDate)
        let activePhase = store.cycleSummary.dayPhases[store.cycleSelectedDate] ?? .none

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                SectionHeaderView(
                    title: "Daily Entry",
                    subtitle: activePhase == .none ? selectedDateLabel : "\(selectedDateLabel) · \(activePhase.label.uppercased())"
                )

                Spacer()

                if existing != nil {
                    Button("Clear Day") {
                        pendingConfirm = PendingActionConfirmation(
                            title: "Clear Cycle Entry?",
                            message: "Erase all logged flow, symptoms, mood, and notes for \(DatabaseManager.mediumDateLabel(store.cycleSelectedDate))?",
                            confirmLabel: "Clear Day",
                            isDestructive: true
                        ) {
                            store.deleteCycleLog(date: store.cycleSelectedDate)
                            syncDrafts(for: store.cycleSelectedDate)
                        }
                    }
                    .buttonStyle(WarmActionButtonStyle())
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("FLOW LEVEL")
                    .font(LedgerFont.sansSm())
                    .tracking(1.4)
                    .foregroundStyle(LedgerColor.inkSecondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(CycleFlowLevel.allCases) { lvl in
                            Button(lvl.label) {
                                LedgerHaptics.light()
                                flowDraft = lvl
                            }
                            .buttonStyle(WarmActionButtonStyle(isActive: flowDraft == lvl))
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("SYMPTOMS")
                    .font(LedgerFont.sansSm())
                    .tracking(1.4)
                    .foregroundStyle(LedgerColor.inkSecondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 94), spacing: 6)], spacing: 6) {
                    ForEach(symptomOptions, id: \.self) { sym in
                        let active = symptomsDraft.contains(sym)
                        Button(sym) {
                            LedgerHaptics.light()
                            if active { symptomsDraft.remove(sym) } else { symptomsDraft.insert(sym) }
                        }
                        .buttonStyle(WarmActionButtonStyle(isActive: active, fullWidth: true))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("MOOD & ENERGY")
                    .font(LedgerFont.sansSm())
                    .tracking(1.4)
                    .foregroundStyle(LedgerColor.inkSecondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(moodOptions, id: \.self) { m in
                            Button(m) {
                                LedgerHaptics.light()
                                moodDraft = (moodDraft == m) ? "" : m
                            }
                            .buttonStyle(WarmActionButtonStyle(isActive: moodDraft == m))
                        }
                    }
                }

                HStack(spacing: 6) {
                    Text("ENERGY")
                        .font(LedgerFont.sansSm())
                        .foregroundStyle(LedgerColor.inkSecondary)

                    ForEach(1...5, id: \.self) { level in
                        Button("\(level)") {
                            LedgerHaptics.light()
                            energyDraft = level
                        }
                        .buttonStyle(WarmActionButtonStyle(isActive: energyDraft == level, fullWidth: true))
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Temp (°F / °C)", text: $bbtDraft)
                    .keyboardType(.decimalPad)
                    .font(LedgerFont.sansMd())
                    .foregroundStyle(LedgerColor.inkPrimary)
                    .warmRecessedField()
                    .frame(width: 132)

                TextField("Cycle note...", text: $notesDraft)
                    .font(LedgerFont.serifMd())
                    .foregroundStyle(LedgerColor.inkPrimary)
                    .warmRecessedField()
            }

            Button(existing != nil ? "Update Cycle Day" : "Save Cycle Day") {
                let verb = existing != nil ? "Update" : "Save"
                let summaryDesc = flowDraft == .none ? "no flow" : "\(flowDraft.label.lowercased()) flow"
                pendingConfirm = PendingActionConfirmation(
                    title: "\(verb) Cycle Day?",
                    message: "\(verb) \(summaryDesc) and \(symptomsDraft.count) symptom(s) for \(DatabaseManager.mediumDateLabel(store.cycleSelectedDate))?",
                    confirmLabel: verb,
                    isDestructive: false
                ) {
                    let parsedBBT = Double(bbtDraft.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
                    store.saveCycleLog(
                        date: store.cycleSelectedDate,
                        flow: flowDraft,
                        symptoms: Array(symptomsDraft).sorted(),
                        mood: moodDraft,
                        energy: energyDraft,
                        bbt: parsedBBT,
                        notes: notesDraft
                    )
                }
            }
            .buttonStyle(PrimaryActionButtonStyle(fullWidth: true))
        }
        .softPanel()
    }

    // MARK: - Period History & Clinical Disclaimer

    private var periodHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeaderView(
                title: "Period History",
                subtitle: "\(store.cycleSummary.periods.count) LOGGED WINDOWS"
            )

            ForEach(store.cycleSummary.periods.reversed()) { p in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(DatabaseManager.mediumDateLabel(p.startDate)) – \(DatabaseManager.mediumDateLabel(p.endDate))")
                            .font(LedgerFont.serifMd(semibold: true))
                            .foregroundStyle(LedgerColor.inkPrimary)
                        if let cyc = p.cycleLengthDays {
                            Text("Cycle length: \(cyc) days · Bleed: \(p.durationDays) days")
                                .font(LedgerFont.sansSm())
                                .foregroundStyle(LedgerColor.inkSecondary)
                        } else {
                            Text("Bleed duration: \(p.durationDays) days")
                                .font(LedgerFont.sansSm())
                                .foregroundStyle(LedgerColor.inkSecondary)
                        }
                    }

                    Spacer()

                    Button("Jump") {
                        store.selectCycleDate(p.startDate)
                    }
                    .buttonStyle(WarmActionButtonStyle())
                }
                .softPanel()
            }
        }
    }

    private var disclaimerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeaderView(
                title: "Not Medical Advice",
                subtitle: "INFORMATIONAL TRACKING ONLY"
            )

            Text("Phase colors, predictions, and cycle variation alerts are estimates from your personal logs—never a medical diagnosis or contraception. Always consult a qualified physician for irregular bleeding, missed periods, or PCOS evaluation.")
                .font(LedgerFont.serifMd(italic: true))
                .foregroundStyle(LedgerColor.inkSecondary)

            Button {
                LedgerHaptics.light()
                showMedicalSources = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Clinical Sources & Disclaimer")
                }
            }
            .buttonStyle(WarmActionButtonStyle(isActive: false, fullWidth: true))
        }
        .softPanel()
    }

    private func syncDrafts(for isoDate: String) {
        if let entry = store.cycleLog(forDate: isoDate) {
            flowDraft = entry.flow
            symptomsDraft = Set(entry.symptoms)
            moodDraft = entry.mood
            energyDraft = entry.energy
            bbtDraft = entry.bbt.map { String(format: "%.2f", $0) } ?? ""
            notesDraft = entry.notes
        } else {
            flowDraft = .none
            symptomsDraft = []
            moodDraft = ""
            energyDraft = 3
            bbtDraft = ""
            notesDraft = ""
        }
    }
}
