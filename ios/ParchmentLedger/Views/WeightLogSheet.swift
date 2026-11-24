import SwiftUI

struct WeightLogSheet: View {
    @EnvironmentObject var store: LedgerStore
    @Environment(\.dismiss) private var dismiss

    @State private var entryDate: String = DatabaseManager.isoDate()
    @State private var weightText: String = ""
    @State private var noteText: String = ""
    @State private var sheetEpoch: Int = 0
    @State private var chartRangeDays: Int? = 90
    @State private var pendingConfirm: PendingActionConfirmation? = nil
    @FocusState private var weightFieldFocused: Bool

    private var unit: String {
        store.storage?.weightUnit ?? "lbs"
    }

    private var latestEntry: WeightLogEntry? {
        store.weightLogs.first
    }

    private var existingForDate: WeightLogEntry? {
        store.weightLogs.first { $0.logDate == entryDate }
    }

    private var entryDateDisplay: String {
        let isToday = entryDate == store.todayDate
        let label = DatabaseManager.mediumDateLabel(entryDate).uppercased()
        return isToday ? "TODAY · \(label)" : label
    }

    private var chartEntries: [WeightLogEntry] {
        let sortedAsc = store.weightLogs.sorted { $0.logDate < $1.logDate }
        guard let days = chartRangeDays else { return sortedAsc }
        let cutoff = DatabaseManager.shiftISODate(store.todayDate, byDays: -(days - 1))
        let filtered = sortedAsc.filter { $0.logDate >= cutoff }
        return filtered.isEmpty ? sortedAsc : filtered
    }

    var body: some View {
        ZStack {
            ParchmentBackgroundView()

            VStack(alignment: .leading, spacing: 14) {
                headerBar

                Rectangle()
                    .fill(Color.white.opacity(0.55))
                    .frame(height: 1.2)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        WeightLineGraphCard(
                            entries: chartEntries,
                            allCount: store.weightLogs.count,
                            unit: unit,
                            selectedRangeDays: $chartRangeDays
                        )
                        .inkWritten(index: 0, epoch: sheetEpoch)

                        entryCard
                            .inkWritten(index: 1, epoch: sheetEpoch)

                        historySection
                    }
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
        .onAppear {
            entryDate = store.selectedDate
            syncDraftFields(for: store.selectedDate)
            sheetEpoch &+= 1
        }
        .actionConfirmationAlert($pendingConfirm)
    }

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 10) {
            SectionHeaderView(
                title: latestEntry.map { "\(formatWeight($0.weight)) \(unit.uppercased())" } ?? "Weight Log",
                subtitle: "BODY WEIGHT LEDGER"
            )

            Spacer()

            Button("Done") {
                LedgerHaptics.light()
                dismiss()
            }
            .buttonStyle(PrimaryActionButtonStyle())
        }
    }

    private var entryCard: some View {
        let placeholderWeight = latestEntry.map { formatWeight($0.weight) } ?? (unit == "kg" ? "75.0" : "165.0")

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    LedgerHaptics.light()
                    let next = DatabaseManager.shiftISODate(entryDate, byDays: -1)
                    entryDate = next
                    syncDraftFields(for: next)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(WarmIconButtonStyle())
                .accessibilityLabel("Previous day")

                Text(entryDateDisplay)
                    .font(LedgerFont.sansSm(semibold: true))
                    .tracking(1.3)
                    .foregroundStyle(LedgerColor.inkPrimary)

                Button {
                    LedgerHaptics.light()
                    let next = DatabaseManager.shiftISODate(entryDate, byDays: 1)
                    entryDate = next
                    syncDraftFields(for: next)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(WarmIconButtonStyle())
                .accessibilityLabel("Next day")

                Spacer()

                if entryDate != store.todayDate {
                    Button("Today") {
                        LedgerHaptics.light()
                        entryDate = store.todayDate
                        syncDraftFields(for: store.todayDate)
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: false))
                }
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    TextField(placeholderWeight, text: $weightText)
                        .keyboardType(.decimalPad)
                        .font(LedgerFont.sansMd(semibold: true))
                        .monospacedDigit()
                        .foregroundStyle(LedgerColor.inkPrimary)
                        .focused($weightFieldFocused)

                    Text(unit.uppercased())
                        .font(LedgerFont.sansSm())
                        .tracking(1.0)
                        .foregroundStyle(LedgerColor.inkSecondary)
                }
                .warmRecessedField()

                Button(existingForDate != nil ? "Update" : "+ Log Weight") {
                    requestSubmitConfirmation()
                }
                .buttonStyle(PrimaryActionButtonStyle())
            }

            TextField("Optional note (e.g. morning fasted)...", text: $noteText)
                .font(LedgerFont.serifMd())
                .foregroundStyle(LedgerColor.inkPrimary)
                .warmRecessedField()
                .onSubmit {
                    requestSubmitConfirmation()
                }
        }
        .softPanel()
    }

    @ViewBuilder
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RECENT ENTRIES (\(store.weightLogs.count))")
                .font(LedgerFont.sansSm(semibold: true))
                .tracking(1.6)
                .foregroundStyle(LedgerColor.inkSecondary)
                .inkWritten(index: 2, epoch: sheetEpoch)

            if store.weightLogs.isEmpty {
                VStack(spacing: 6) {
                    Text("No Weigh-Ins Recorded Yet")
                        .font(LedgerFont.serifLg(italic: true))
                        .foregroundStyle(LedgerColor.inkPrimary)
                    Text("ENTER YOUR WEIGHT ABOVE TO START PLOTTING")
                        .font(LedgerFont.sansSm())
                        .tracking(1.0)
                        .foregroundStyle(LedgerColor.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .inkWritten(index: 3, epoch: sheetEpoch)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(store.weightLogs.enumerated()), id: \.element.id) { idx, entry in
                        let olderEntry: WeightLogEntry? = (idx + 1 < store.weightLogs.count) ? store.weightLogs[idx + 1] : nil
                        weightRow(entry: entry, olderEntry: olderEntry)
                            .inkWritten(index: idx + 3, epoch: sheetEpoch)
                    }
                }
            }
        }
    }

    private func weightRow(entry: WeightLogEntry, olderEntry: WeightLogEntry?) -> some View {
        let delta: Double? = olderEntry.map { ((entry.weight - $0.weight) * 10.0).rounded() / 10.0 }

        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.displayDate.uppercased())
                        .font(LedgerFont.sansSm(semibold: entry.logDate == entryDate))
                        .tracking(1.0)
                        .foregroundStyle(LedgerColor.inkPrimary)

                    if entry.logDate == store.todayDate {
                        Text("· TODAY")
                            .font(LedgerFont.sansSm())
                            .foregroundStyle(LedgerColor.inkSecondary)
                    }
                }

                if !entry.note.isEmpty {
                    Text(entry.note)
                        .font(LedgerFont.serifMd(italic: true))
                        .foregroundStyle(LedgerColor.inkSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let d = delta, abs(d) >= 0.05 {
                let sign = d > 0 ? "+" : ""
                Text("\(sign)\(String(format: "%.1f", d))")
                    .font(LedgerFont.sansSm())
                    .monospacedDigit()
                    .foregroundStyle(LedgerColor.inkSecondary)
            }

            Text("\(formatWeight(entry.weight)) \(unit.uppercased())")
                .font(LedgerFont.sansMd(semibold: true))
                .monospacedDigit()
                .foregroundStyle(LedgerColor.inkPrimary)

            Button {
                pendingConfirm = PendingActionConfirmation(
                    title: "Delete Weigh-In?",
                    message: "Permanently remove the \(formatWeight(entry.weight)) \(unit) entry for \(entry.displayDate)?",
                    confirmLabel: "Delete",
                    isDestructive: true
                ) {
                    store.deleteBodyWeight(entry.id)
                    if entry.logDate == entryDate {
                        weightText = ""
                        noteText = ""
                    }
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(LedgerColor.inkSecondary)
            }
            .buttonStyle(WarmIconButtonStyle())
            .accessibilityLabel("Delete weight entry for \(entry.displayDate)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LedgerColor.parchmentLight.opacity(entry.logDate == entryDate ? 0.68 : 0.46))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.32), lineWidth: 0.8)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            LedgerHaptics.light()
            entryDate = entry.logDate
            syncDraftFields(for: entry.logDate)
        }
    }

    private func syncDraftFields(for dateISO: String) {
        if let found = store.weightLogs.first(where: { $0.logDate == dateISO }) {
            weightText = formatWeight(found.weight)
            noteText = found.note
        } else {
            weightText = ""
            noteText = ""
        }
    }

    private func requestSubmitConfirmation() {
        let cleaned = weightText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let val = Double(cleaned), val > 0 else {
            store.showToast("Enter a valid weight")
            return
        }
        weightFieldFocused = false
        let actionWord = existingForDate != nil ? "Update" : "Save"
        pendingConfirm = PendingActionConfirmation(
            title: "\(actionWord) Weigh-In?",
            message: "\(actionWord) \(formatWeight(val)) \(unit) on \(DatabaseManager.mediumDateLabel(entryDate))?",
            confirmLabel: actionWord,
            isDestructive: false
        ) {
            store.logBodyWeight(date: entryDate, weight: val, note: noteText)
            sheetEpoch &+= 1
        }
    }

    private func formatWeight(_ w: Double) -> String {
        w.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(w))"
            : String(format: "%.1f", w)
    }
}

private struct WeightLineGraphCard: View {
    let entries: [WeightLogEntry]
    let allCount: Int
    let unit: String
    @Binding var selectedRangeDays: Int?

    private let ranges: [(label: String, days: Int?)] = [
        ("30D", 30),
        ("90D", 90),
        ("ALL", nil),
    ]

    var body: some View {
        let ys = entries.map(\.weight)
        let currentW = ys.last
        let firstW = ys.first
        let minW = ys.min()
        let maxW = ys.max()
        let netChange: Double? = (entries.count >= 2 && firstW != nil && currentW != nil)
            ? ((currentW! - firstW!) * 10.0).rounded() / 10.0
            : nil

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                SectionHeaderView(
                    title: "Weight Over Time",
                    subtitle: "\(entries.count) OF \(allCount) WEIGH-INS"
                )
                Spacer()
            }

            HStack(spacing: 8) {
                ForEach(ranges, id: \.label) { item in
                    Button(item.label) {
                        LedgerHaptics.light()
                        selectedRangeDays = item.days
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: selectedRangeDays == item.days, fullWidth: true))
                }
            }

            if entries.isEmpty {
                VStack(spacing: 4) {
                    Text("No weight entries plotted yet.")
                        .font(LedgerFont.serifMd(italic: true))
                        .foregroundStyle(LedgerColor.inkPrimary)
                    Text("Log your first weigh-in below to see your line graph.")
                        .font(LedgerFont.sansSm())
                        .foregroundStyle(LedgerColor.inkSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                HStack(spacing: 8) {
                    miniStat(
                        label: "CURRENT",
                        value: currentW.map { "\(formatW($0)) \(unit)" } ?? "—"
                    )
                    miniStat(
                        label: "CHANGE",
                        value: netChange.map { d in
                            let s = d > 0 ? "+" : ""
                            return "\(s)\(String(format: "%.1f", d)) \(unit)"
                        } ?? "—"
                    )
                    miniStat(
                        label: "MIN – MAX",
                        value: (minW != nil && maxW != nil) ? "\(formatW(minW!))–\(formatW(maxW!))" : "—"
                    )
                }

                graphCanvas(entries: entries)
                    .frame(height: 148)

                HStack {
                    Text(entries.first.map { DatabaseManager.shortDateLabel($0.logDate).uppercased() } ?? "")
                    Spacer()
                    if entries.count == 1 {
                        Text("LOG ANOTHER DAY TO DRAW TRENDLINE")
                    } else {
                        Text(entries.last.map { DatabaseManager.shortDateLabel($0.logDate).uppercased() } ?? "")
                    }
                }
                .font(LedgerFont.sansSm())
                .foregroundStyle(LedgerColor.inkSecondary)
            }
        }
        .softPanel()
    }

    private func miniStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(LedgerFont.sansSm())
                .tracking(0.6)
                .foregroundStyle(LedgerColor.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(value)
                .font(LedgerFont.sansSm(semibold: true))
                .monospacedDigit()
                .foregroundStyle(LedgerColor.inkPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(LedgerColor.parchmentLight.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(LedgerColor.inkPrimary.opacity(0.14), lineWidth: 0.8)
        )
    }

    private func graphCanvas(entries: [WeightLogEntry]) -> some View {
        let ys = entries.map(\.weight)
        let rawMin = ys.min() ?? 0
        let rawMax = ys.max() ?? 10
        let padSpan = max(2.0, (rawMax - rawMin) * 0.18)
        let minV = max(0, rawMin - padSpan)
        let maxV = rawMax + padSpan
        let midV = (minV + maxV) / 2.0

        return HStack(spacing: 6) {
            VStack(alignment: .trailing) {
                Text(formatW(maxV))
                Spacer()
                Text(formatW(midV))
                Spacer()
                Text(formatW(minV))
            }
            .font(LedgerFont.sansSm())
            .monospacedDigit()
            .foregroundStyle(LedgerColor.inkSecondary)
            .frame(width: 38, alignment: .trailing)
            .padding(.vertical, 8)

            Canvas { ctx, size in
                let padX: CGFloat = 10
                let padY: CGFloat = 12
                let usableW = max(1, size.width - padX * 2)
                let usableH = max(1, size.height - padY * 2)
                let span = max(0.5, maxV - minV)

                func pointX(_ i: Int) -> CGFloat {
                    if entries.count <= 1 { return size.width * 0.5 }
                    return padX + (CGFloat(i) / CGFloat(entries.count - 1)) * usableW
                }

                func pointY(_ v: Double) -> CGFloat {
                    padY + usableH - CGFloat((v - minV) / span) * usableH
                }

                // 3 reference horizontal gridlines
                for frac in [0.0, 0.5, 1.0] {
                    let y = padY + CGFloat(frac) * usableH
                    var grid = Path()
                    grid.move(to: CGPoint(x: padX, y: y))
                    grid.addLine(to: CGPoint(x: size.width - padX, y: y))
                    ctx.stroke(
                        grid,
                        with: .color(LedgerColor.inkPrimary.opacity(frac == 1.0 ? 0.22 : 0.10)),
                        style: StrokeStyle(lineWidth: 0.9, dash: frac == 1.0 ? [] : [3, 3])
                    )
                }

                if entries.count >= 2 {
                    // Warm fill under weight curve
                    var area = Path()
                    area.move(to: CGPoint(x: pointX(0), y: padY + usableH))
                    for (i, e) in entries.enumerated() {
                        area.addLine(to: CGPoint(x: pointX(i), y: pointY(e.weight)))
                    }
                    area.addLine(to: CGPoint(x: pointX(entries.count - 1), y: padY + usableH))
                    area.closeSubpath()
                    ctx.fill(
                        area,
                        with: .linearGradient(
                            Gradient(colors: [
                                LedgerColor.warmTerracotta.opacity(0.26),
                                LedgerColor.warmTerracotta.opacity(0.02),
                            ]),
                            startPoint: CGPoint(x: 0, y: padY),
                            endPoint: CGPoint(x: 0, y: padY + usableH)
                        )
                    )

                    // Dashed linear regression trendline
                    let n = ys.count
                    let xMean = Double(n - 1) / 2.0
                    let yMean = ys.reduce(0, +) / Double(n)
                    var denom = 0.0
                    var numer = 0.0
                    for i in 0..<n {
                        let dx = Double(i) - xMean
                        denom += dx * dx
                        numer += dx * (ys[i] - yMean)
                    }
                    let slope = denom != 0 ? (numer / denom) : 0.0
                    let intercept = yMean - slope * xMean
                    var trend = Path()
                    trend.move(to: CGPoint(x: pointX(0), y: pointY(intercept)))
                    trend.addLine(to: CGPoint(x: pointX(n - 1), y: pointY(intercept + slope * Double(n - 1))))
                    ctx.stroke(
                        trend,
                        with: .color(LedgerColor.inkSecondary.opacity(0.85)),
                        style: StrokeStyle(lineWidth: 1.2, dash: [4, 4])
                    )

                    // Bold weight line
                    var line = Path()
                    for (i, e) in entries.enumerated() {
                        let pt = CGPoint(x: pointX(i), y: pointY(e.weight))
                        if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
                    }
                    ctx.stroke(
                        line,
                        with: .color(LedgerColor.warmTerracotta),
                        style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                    )
                }

                // Data points
                let strideStep = max(1, entries.count / 24)
                for (i, e) in entries.enumerated() {
                    let isEndpoint = i == 0 || i == entries.count - 1
                    if !isEndpoint && i % strideStep != 0 { continue }
                    let pt = CGPoint(x: pointX(i), y: pointY(e.weight))
                    let isLast = i == entries.count - 1
                    let r: CGFloat = isLast ? 4.2 : 3.0
                    let dot = Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2))
                    ctx.fill(dot, with: .color(isLast ? LedgerColor.warmTerracotta : LedgerColor.parchmentLight))
                    ctx.stroke(dot, with: .color(LedgerColor.warmTerracotta), lineWidth: 1.6)
                }
            }
        }
    }

    private func formatW(_ w: Double) -> String {
        w.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(w))" : String(format: "%.1f", w)
    }
}
