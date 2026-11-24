import SwiftUI

struct MacroTrendsSheet: View {
    @EnvironmentObject var store: LedgerStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedMetric: MacroMetric = .kcal
    @State private var selectedDays: Int = 14
    @State private var showSources: Bool = false

    private let dayRanges = [7, 14, 30, 90]

    var body: some View {
        let points = store.macroHistory(for: selectedMetric, days: selectedDays)
        let targetVal = selectedMetric.targetValue(from: store.macroTargets)
        let loggedPoints = points.filter { $0.value > 0 }
        let avgVal: Int = loggedPoints.isEmpty
            ? 0
            : Int(round(Double(loggedPoints.map(\.value).reduce(0, +)) / Double(loggedPoints.count)))
        let peakVal = points.map(\.value).max() ?? 0

        ZStack {
            ParchmentBackgroundView()

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    SectionHeaderView(
                        title: "Nutrition Over Time",
                        subtitle: "LOGGED DAILY TOTALS BY NUTRIENT"
                    )

                    Spacer()

                    Button("Done") {
                        LedgerHaptics.light()
                        dismiss()
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                }

                Rectangle()
                    .fill(Color.white.opacity(0.55))
                    .frame(height: 1.2)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        // Metric selector grid
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 102), spacing: 8)], spacing: 8) {
                            ForEach(MacroMetric.allCases) { metric in
                                Button(metric.label) {
                                    LedgerHaptics.light()
                                    selectedMetric = metric
                                }
                                .buttonStyle(WarmActionButtonStyle(isActive: selectedMetric == metric, fullWidth: true))
                            }
                        }

                        // Range selector
                        HStack(spacing: 8) {
                            ForEach(dayRanges, id: \.self) { days in
                                Button("\(days)D") {
                                    LedgerHaptics.light()
                                    selectedDays = days
                                }
                                .buttonStyle(WarmActionButtonStyle(isActive: selectedDays == days, fullWidth: true))
                            }
                        }

                        // Chart panel
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("\(selectedMetric.label.uppercased()) (\(selectedMetric.unit.uppercased()))")
                                Spacer()
                                Text("\(selectedMetric.isUpperLimit ? "LIMIT" : "TARGET") \(targetVal) \(selectedMetric.unit.uppercased())")
                            }
                            .font(LedgerFont.sansSm(semibold: true))
                            .tracking(0.9)
                            .foregroundStyle(LedgerColor.inkSecondary)

                            trendCanvas(points: points, target: targetVal)
                                .frame(height: 132)

                            HStack {
                                Text(points.first.map { DatabaseManager.shortDateLabel($0.date).uppercased() } ?? "")
                                Spacer()
                                Text(points.last.map { DatabaseManager.shortDateLabel($0.date).uppercased() } ?? "")
                            }
                            .font(LedgerFont.sansSm())
                            .foregroundStyle(LedgerColor.inkSecondary)
                        }
                        .softPanel()

                        // Equal 3-card summary
                        HStack(spacing: 10) {
                            statCard(label: "DAILY AVG", value: "\(avgVal) \(selectedMetric.unit)")
                            statCard(label: "PEAK DAY", value: "\(peakVal) \(selectedMetric.unit)")
                            statCard(label: "LOGGED DAYS", value: "\(loggedPoints.count)/\(selectedDays)")
                        }

                        // Recent non-zero days
                        VStack(alignment: .leading, spacing: 8) {
                            Text("RECENT LOGGED DAYS")
                                .font(LedgerFont.sansSm(semibold: true))
                                .tracking(1.4)
                                .foregroundStyle(LedgerColor.inkSecondary)

                            if loggedPoints.isEmpty {
                                Text("No meals logged in this window yet.")
                                    .font(LedgerFont.serifMd(italic: true))
                                    .foregroundStyle(LedgerColor.inkSecondary)
                                    .softPanel()
                            } else {
                                ForEach(loggedPoints.reversed().prefix(14)) { pt in
                                    let overLimit = selectedMetric.isUpperLimit && pt.value > targetVal
                                    HStack {
                                        Text(DatabaseManager.mediumDateLabel(pt.date))
                                            .font(LedgerFont.serifMd(semibold: true))
                                            .foregroundStyle(LedgerColor.inkPrimary)
                                        Spacer()
                                        Text("\(pt.value) \(selectedMetric.unit)")
                                            .font(LedgerFont.sansMd(semibold: true))
                                            .monospacedDigit()
                                            .foregroundStyle(overLimit ? LedgerColor.errorRust : LedgerColor.inkPrimary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(LedgerColor.parchmentLight.opacity(0.65))
                                    )
                                }
                            }
                        }

                        Button("Dietary Reference Sources") {
                            LedgerHaptics.light()
                            showSources = true
                        }
                        .buttonStyle(WarmActionButtonStyle(isActive: false, fullWidth: true))
                    }
                    .padding(.bottom, 28)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
        .sheet(isPresented: $showSources) {
            MedicalSourcesSheet()
        }
    }

    private func statCard(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(LedgerFont.sansSm())
                .tracking(0.6)
                .foregroundStyle(LedgerColor.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(value)
                .font(LedgerFont.sansMd(semibold: true))
                .monospacedDigit()
                .foregroundStyle(LedgerColor.inkPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(LedgerColor.parchmentLight.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(LedgerColor.inkPrimary.opacity(0.14), lineWidth: 0.9)
        )
    }

    private func trendCanvas(points: [MacroHistoryPoint], target: Int) -> some View {
        let maxVal = max(target, points.map(\.value).max() ?? 1, 1)

        return Canvas { ctx, size in
            let padX: CGFloat = 10
            let padY: CGFloat = 12
            let w = size.width - padX * 2
            let h = size.height - padY * 2

            func px(_ i: Int) -> CGFloat {
                padX + (CGFloat(i) / CGFloat(max(1, points.count - 1))) * w
            }
            func py(_ v: Int) -> CGFloat {
                padY + h - CGFloat(Double(v) / Double(maxVal)) * h
            }

            // Baseline
            var base = Path()
            base.move(to: CGPoint(x: padX, y: padY + h))
            base.addLine(to: CGPoint(x: size.width - padX, y: padY + h))
            ctx.stroke(base, with: .color(LedgerColor.inkPrimary.opacity(0.16)), lineWidth: 1)

            // Target / limit dashed line
            let ty = py(target)
            var tLine = Path()
            tLine.move(to: CGPoint(x: padX, y: ty))
            tLine.addLine(to: CGPoint(x: size.width - padX, y: ty))
            ctx.stroke(
                tLine,
                with: .color(selectedMetric.isUpperLimit ? LedgerColor.warmTerracotta.opacity(0.75) : LedgerColor.inkSecondary.opacity(0.65)),
                style: StrokeStyle(lineWidth: 1.2, dash: [4, 4])
            )

            guard !points.isEmpty else { return }

            var line = Path()
            for (i, p) in points.enumerated() {
                let pt = CGPoint(x: px(i), y: py(p.value))
                if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
            }
            ctx.stroke(line, with: .color(LedgerColor.inkPrimary), style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round))

            if points.count <= 31 {
                for (i, p) in points.enumerated() where p.value > 0 || i == points.count - 1 {
                    let pt = CGPoint(x: px(i), y: py(p.value))
                    let over = selectedMetric.isUpperLimit && p.value > target
                    let r: CGFloat = i == points.count - 1 ? 3.5 : 2.5
                    let circle = Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2))
                    ctx.fill(circle, with: .color(over ? LedgerColor.errorRust : (i == points.count - 1 ? LedgerColor.inkPrimary : LedgerColor.parchmentBase)))
                    ctx.stroke(circle, with: .color(over ? LedgerColor.errorRust : LedgerColor.inkPrimary), lineWidth: 1.4)
                }
            }
        }
    }
}
