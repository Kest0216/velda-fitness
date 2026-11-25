// MARK: - Parchment Ledger Design System
//
// Defines the visual language for Velda Fitness:
// - Warm parchment surface palette (`LedgerColor`) with high-contrast ink tokens.
// - Strict 3-size typography scale (`LedgerFont`: 20pt lg, 15pt md, 11pt sm) across serif & sans.
// - Tactile button styles (`WarmActionButtonStyle`, `PrimaryActionButtonStyle`, `VerifiedActionButtonStyle`).
// - Ink-write reveal animation (`InkWriteModifier`), floating toast overlay (`LedgerToastOverlayModifier`),
//   reusable confirmation/AI-gating alerts, and 3-tier haptic feedback (`LedgerHaptics`).

import SwiftUI
import UIKit

/// Resigns the active first responder so transient software keyboards and macOS iOS-app
/// input accessory bars dismiss cleanly across tab switches, saves, and sheet dismissals.
@MainActor
func dismissLedgerKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

enum LedgerColor {
    static let parchmentBase = Color(red: 0.847, green: 0.784, blue: 0.682)      // #D8C8AE
    static let parchmentLight = Color(red: 0.886, green: 0.831, blue: 0.737)     // #E2D4BC
    static let parchmentPopover = Color(red: 0.898, green: 0.843, blue: 0.753)   // #E5D7C0
    static let inkPrimary = Color(red: 0.098, green: 0.090, blue: 0.082)         // #191715
    static let inkSecondary = Color(red: 0.290, green: 0.267, blue: 0.239)       // #4A443D
    static let warmAmber = Color(red: 0.749, green: 0.439, blue: 0.188)          // #BF7030
    static let warmTerracotta = Color(red: 0.698, green: 0.337, blue: 0.125)     // #B25620
    static let verifiedSage = Color(red: 0.21, green: 0.47, blue: 0.28)          // #367847
    static let errorRust = Color(red: 0.65, green: 0.20, blue: 0.16)             // #A63329
    static let cycleRose = Color(red: 0.68, green: 0.28, blue: 0.27)             // #AD4745
    static let phaseFollicular = Color(red: 0.34, green: 0.50, blue: 0.36)       // #57805C
    static let phaseOvulatory = Color(red: 0.78, green: 0.53, blue: 0.16)        // #C78729
    static let phaseLuteal = Color(red: 0.45, green: 0.42, blue: 0.56)           // #736B8F
    static let buttonTextLight = Color(red: 0.98, green: 0.96, blue: 0.92)       // #FAF5EB
}

enum LedgerFont {
    private static let hasCormorant: Bool = {
        UIFont.familyNames.contains { $0.localizedCaseInsensitiveContains("Cormorant") }
    }()

    private static let hasMontserrat: Bool = {
        UIFont.familyNames.contains { $0.localizedCaseInsensitiveContains("Montserrat") }
    }()

    // Strict 3-size hierarchy: 20pt (lg), 15pt (md), 11pt (sm) across 2 font families
    static func serifLg(italic: Bool = false, semibold: Bool = false, bold: Bool = false) -> Font {
        if hasCormorant {
            if bold && italic { return .custom("CormorantGaramond-BoldItalic", size: 20) }
            if bold { return .custom("CormorantGaramond-Bold", size: 20) }
            if italic { return .custom("CormorantGaramond-Italic", size: 20) }
            if semibold { return .custom("CormorantGaramond-SemiBold", size: 20) }
            return .custom("CormorantGaramond-Medium", size: 20)
        }
        if bold && italic { return .custom("Baskerville-BoldItalic", size: 20) }
        if bold { return .custom("Baskerville-Bold", size: 20) }
        if italic { return .custom("Baskerville-Italic", size: 20) }
        if semibold { return .custom("Baskerville-SemiBold", size: 20) }
        return .custom("Baskerville", size: 20)
    }

    static func serifMd(italic: Bool = false, semibold: Bool = false) -> Font {
        if hasCormorant {
            if semibold { return .custom("CormorantGaramond-SemiBold", size: 15) }
            return .custom(italic ? "CormorantGaramond-Italic" : "CormorantGaramond-Medium", size: 15)
        }
        if semibold { return .custom("Baskerville-SemiBold", size: 15) }
        return .custom(italic ? "Baskerville-Italic" : "Baskerville", size: 15)
    }

    static func serifSmItalic() -> Font {
        if hasCormorant {
            return .custom("CormorantGaramond-Italic", size: 11)
        }
        return .custom("Baskerville-Italic", size: 11)
    }

    static func sansMd(semibold: Bool = false) -> Font {
        if hasMontserrat {
            return .custom(semibold ? "Montserrat-SemiBold" : "Montserrat-Medium", size: 15)
        }
        return .custom(semibold ? "AvenirNext-DemiBold" : "AvenirNext-Medium", size: 15)
    }

    static func sansSm(semibold: Bool = false) -> Font {
        if hasMontserrat {
            return .custom(semibold ? "Montserrat-SemiBold" : "Montserrat-Medium", size: 11)
        }
        return .custom(semibold ? "AvenirNext-DemiBold" : "AvenirNext-Medium", size: 11)
    }
}

struct ParchmentBackgroundView: View {
    var body: some View {
        ZStack {
            LedgerColor.parchmentBase
                .ignoresSafeArea()

            RadialGradient(
                colors: [
                    Color(red: 0.922, green: 0.875, blue: 0.796).opacity(0.45),
                    Color(red: 0.769, green: 0.694, blue: 0.576).opacity(0.35),
                ],
                center: UnitPoint(x: 0.5, y: 0.35),
                startRadius: 20,
                endRadius: 520
            )
            .ignoresSafeArea()

            Canvas { ctx, size in
                let step: CGFloat = 22
                let cols = Int(size.width / step) + 1
                let rows = Int(size.height / step) + 1
                for r in 0..<rows {
                    for c in 0..<cols {
                        let hash = (r * 73856093) ^ (c * 19349663)
                        let dx = CGFloat(abs(hash % 17))
                        let dy = CGFloat(abs((hash >> 5) % 17))
                        let x = CGFloat(c) * step + dx
                        let y = CGFloat(r) * step + dy
                        let isLight = (hash & 3) == 0
                        let radius: CGFloat = (hash & 7) == 0 ? 0.9 : 0.55
                        let rect = CGRect(x: x, y: y, width: radius * 2, height: radius * 2)
                        let color = isLight
                            ? Color.white.opacity(0.22)
                            : Color(red: 0.24, green: 0.19, blue: 0.12).opacity(0.14)
                        ctx.fill(Path(ellipseIn: rect), with: .color(color))
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}

struct WarmActionButtonStyle: ButtonStyle {
    var isActive: Bool = false
    var fullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LedgerFont.sansSm(semibold: true))
            .tracking(0.7)
            .textCase(.uppercase)
            .lineLimit(1)
            .minimumScaleFactor(0.76)
            .foregroundStyle(isActive ? LedgerColor.buttonTextLight : LedgerColor.inkPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 34)
            .background(
                Group {
                    if isActive {
                        LedgerColor.inkPrimary.opacity(configuration.isPressed ? 0.86 : 1.0)
                    } else {
                        LedgerColor.parchmentLight.opacity(configuration.isPressed ? 0.68 : 0.86)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isActive ? LedgerColor.inkPrimary : LedgerColor.inkPrimary.opacity(0.24),
                        lineWidth: 1.0
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct PrimaryActionButtonStyle: ButtonStyle {
    var fullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LedgerFont.sansSm(semibold: true))
            .tracking(0.7)
            .textCase(.uppercase)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .foregroundStyle(LedgerColor.buttonTextLight)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 34)
            .background(LedgerColor.warmTerracotta.opacity(configuration.isPressed ? 0.82 : 1.0))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct WarmIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(LedgerColor.inkPrimary)
            .frame(minWidth: 30, minHeight: 30)
            .padding(.horizontal, 4)
            .background(
                LedgerColor.parchmentLight.opacity(configuration.isPressed ? 0.6 : 0.82)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(LedgerColor.inkPrimary.opacity(0.18), lineWidth: 0.9)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
    }
}

struct VerifiedActionButtonStyle: ButtonStyle {
    var fullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LedgerFont.sansSm(semibold: true))
            .tracking(0.7)
            .textCase(.uppercase)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .foregroundStyle(LedgerColor.buttonTextLight)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 34)
            .background(LedgerColor.verifiedSage.opacity(configuration.isPressed ? 0.82 : 1.0))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct SectionHeaderView: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(LedgerFont.serifLg(bold: true))
                .foregroundStyle(LedgerColor.inkPrimary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(LedgerFont.sansSm())
                    .foregroundStyle(LedgerColor.inkSecondary)
            }
        }
    }
}

struct CenteredCalendarHeaderView: View {
    let title: String
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(LedgerFont.sansSm(semibold: true))
                .tracking(1.6)
                .foregroundStyle(LedgerColor.inkPrimary)
                .lineLimit(1)

            HStack {
                Button(action: onPrevious) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(WarmIconButtonStyle())
                .accessibilityLabel("Previous month")

                Spacer()

                Button(action: onNext) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(WarmIconButtonStyle())
                .accessibilityLabel("Next month")
            }
        }
    }
}

struct WarmRecessedFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                LinearGradient(
                    colors: [
                        LedgerColor.warmAmber.opacity(0.03),
                        LedgerColor.warmAmber.opacity(0.14),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct SoftPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(LedgerColor.inkPrimary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

@MainActor
enum LedgerHaptics {
    private static let lightGenerator: UIImpactFeedbackGenerator = {
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.prepare()
        return gen
    }()

    private static let mediumGenerator: UIImpactFeedbackGenerator = {
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.prepare()
        return gen
    }()

    private static let heavyGenerator: UIImpactFeedbackGenerator = {
        let gen = UIImpactFeedbackGenerator(style: .heavy)
        gen.prepare()
        return gen
    }()

    /// Subtle navigation, tab switches, disclosures, and filter chips.
    static func light() {
        lightGenerator.impactOccurred()
        lightGenerator.prepare()
    }

    /// State commits, schedule assignments, unit toggles, and refreshes.
    static func medium() {
        mediumGenerator.impactOccurred()
        mediumGenerator.prepare()
    }

    /// All creative (create/add/log/save/generate) and destructive (delete/remove/clear/sweep) actions.
    static func heavy() {
        heavyGenerator.impactOccurred()
        heavyGenerator.prepare()
    }
}

struct InkWriteModifier: ViewModifier {
    let index: Int
    let epoch: Int

    @State private var revealProgress: CGFloat = 0.0
    @State private var lastAnimatedEpoch: Int = -1
    @State private var animTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .opacity(0.32 + 0.68 * Double(revealProgress))
            .mask {
                GeometryReader { geo in
                    if revealProgress >= 0.999 {
                        Rectangle()
                            .padding(-24)
                    } else {
                        HStack(spacing: 0) {
                            Rectangle()
                                .frame(width: max(0, (geo.size.width + 24) * revealProgress))
                            LinearGradient(
                                colors: [.black, .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: 18)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, -16)
                        .padding(.leading, -12)
                    }
                }
            }
            .overlay(alignment: .leading) {
                if revealProgress > 0.01 && revealProgress < 0.985 {
                    GeometryReader { geo in
                        let xPos = geo.size.width * revealProgress
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        LedgerColor.warmTerracotta.opacity(0.05),
                                        LedgerColor.inkPrimary.opacity(0.48),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 1.6, height: max(10, geo.size.height * 0.68))
                            .shadow(color: LedgerColor.warmAmber.opacity(0.38), radius: 3, x: -3, y: 0)
                            .position(x: xPos, y: geo.size.height * 0.5)
                    }
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                if lastAnimatedEpoch != epoch {
                    playInkReveal(for: epoch)
                }
            }
            .onChange(of: epoch) { _, newEpoch in
                playInkReveal(for: newEpoch)
            }
            .onDisappear {
                animTask?.cancel()
            }
    }

    private func playInkReveal(for targetEpoch: Int) {
        animTask?.cancel()
        lastAnimatedEpoch = targetEpoch

        var resetTx = Transaction()
        resetTx.disablesAnimations = true
        withTransaction(resetTx) {
            revealProgress = 0.0
        }

        let delaySeconds = Double(min(max(0, index), 12)) * 0.036
        let sleepNs = UInt64((0.012 + delaySeconds) * 1_000_000_000)

        animTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: sleepNs)
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.22, 0.85, 0.32, 1.0, duration: 0.42)) {
                revealProgress = 1.0
            }
        }
    }
}

struct InkLoadingQuillView: View {
    let label: String
    private let lineRatios: [CGFloat] = [0.92, 0.74, 0.58]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(LedgerFont.serifMd(italic: true))
                .foregroundStyle(LedgerColor.inkPrimary)

            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let cycle = 1.35

                VStack(alignment: .leading, spacing: 7) {
                    ForEach(0..<lineRatios.count, id: \.self) { idx in
                        GeometryReader { geo in
                            let rawPhase = ((t - Double(idx) * 0.16) / cycle).truncatingRemainder(dividingBy: 1.0)
                            let phase = rawPhase < 0 ? rawPhase + 1.0 : rawPhase
                            // Brisk write-across (0..0.65), brief hold/fade (0.65..1.0)
                            let writeFrac = min(1.0, phase / 0.65)
                            let eased = 1.0 - pow(1.0 - writeFrac, 3.0)
                            let fade = phase > 0.72 ? max(0.0, 1.0 - (phase - 0.72) / 0.28) : 1.0
                            let maxW = geo.size.width * lineRatios[idx]
                            let curW = max(4, maxW * CGFloat(eased))

                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(LedgerColor.inkPrimary.opacity(0.08))
                                    .frame(width: maxW, height: 1.2)

                                HStack(spacing: 0) {
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    LedgerColor.inkPrimary.opacity(0.22 * fade),
                                                    LedgerColor.inkPrimary.opacity(0.68 * fade),
                                                ],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(width: curW, height: 1.8)

                                    if writeFrac < 0.98 {
                                        Circle()
                                            .fill(LedgerColor.inkPrimary.opacity(0.85 * fade))
                                            .frame(width: 4, height: 4)
                                            .offset(x: -1)
                                    }
                                }
                            }
                        }
                        .frame(height: 5)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct PendingActionConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmLabel: String
    let isDestructive: Bool
    let action: () -> Void

    init(
        title: String,
        message: String,
        confirmLabel: String = "Confirm",
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.confirmLabel = confirmLabel
        self.isDestructive = isDestructive
        self.action = action
    }
}

extension View {
    func warmRecessedField() -> some View {
        modifier(WarmRecessedFieldModifier())
    }

    func softPanel() -> some View {
        modifier(SoftPanelModifier())
    }

    func inkWritten(index: Int = 0, epoch: Int) -> some View {
        modifier(InkWriteModifier(index: index, epoch: epoch))
    }

    /// Shared secondary pill chrome for SwiftUI containers (`PhotosPicker`, `Menu`) that cannot
    /// directly adopt a `ButtonStyle`. Enforces uppercase text to match `WarmActionButtonStyle`.
    func uniformSecondaryButtonChrome(disabled: Bool = false, fullWidth: Bool = true) -> some View {
        self
            .font(LedgerFont.sansSm(semibold: true))
            .tracking(0.8)
            .textCase(.uppercase)
            .lineLimit(1)
            .minimumScaleFactor(0.76)
            .foregroundStyle(LedgerColor.inkPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 34)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LedgerColor.parchmentLight)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(LedgerColor.inkPrimary.opacity(0.28), lineWidth: 1.0)
            )
            .opacity(disabled ? 0.42 : 1.0)
    }

    /// Renders `LedgerStore.toastMessage` inside the current view hierarchy (including modal `.sheet`
    /// presentations, where a root-level overlay would otherwise sit occluded behind the sheet).
    func ledgerToastOverlay(_ message: String?, bottomPadding: CGFloat = 24) -> some View {
        modifier(LedgerToastOverlayModifier(message: message, bottomPadding: bottomPadding))
    }

    func actionConfirmationAlert(_ pending: Binding<PendingActionConfirmation?>) -> some View {
        self.alert(
            pending.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { pending.wrappedValue != nil },
                set: { if !$0 { pending.wrappedValue = nil } }
            ),
            presenting: pending.wrappedValue
        ) { item in
            Button(item.confirmLabel, role: item.isDestructive ? .destructive : nil) {
                let run = item.action
                pending.wrappedValue = nil
                run()
            }
            Button("Cancel", role: .cancel) {
                pending.wrappedValue = nil
            }
        } message: { item in
            Text(item.message)
        }
    }

    func aiCredentialRequiredAlert(featureName: Binding<String?>, onOpenVault: @escaping () -> Void) -> some View {
        self.alert(
            "AI Provider Required",
            isPresented: Binding(
                get: { featureName.wrappedValue != nil },
                set: { if !$0 { featureName.wrappedValue = nil } }
            ),
            presenting: featureName.wrappedValue
        ) { _ in
            Button("Open Vault") {
                featureName.wrappedValue = nil
                onOpenVault()
            }
            Button("OK", role: .cancel) {
                featureName.wrappedValue = nil
            }
        } message: { name in
            Text("\(name) requires connecting your own AI provider (a ChatGPT subscription sign-in or an API key for OpenAI, Gemini, or Anthropic) in Vault. Core workout, nutrition, recipe, and cycle tracking work fully offline without AI.")
        }
    }
}

struct LedgerToastOverlayModifier: ViewModifier {
    let message: String?
    let bottomPadding: CGFloat

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = message {
                Text(toast.uppercased())
                    .font(LedgerFont.sansSm(semibold: true))
                    .tracking(1.3)
                    .foregroundStyle(LedgerColor.parchmentLight)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(LedgerColor.inkPrimary)
                    .clipShape(Capsule())
                    .shadow(color: LedgerColor.inkPrimary.opacity(0.24), radius: 10, x: 0, y: 4)
                    .padding(.horizontal, 20)
                    .padding(.bottom, bottomPadding)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
    }
}

struct HandDrawnCheckboxView: View {
    let isChecked: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [LedgerColor.warmAmber.opacity(0.16), Color.clear],
                        center: .center,
                        startRadius: 1,
                        endRadius: 16
                    )
                )

            Canvas { ctx, size in
                let w = size.width
                let h = size.height
                var box = Path()
                box.move(to: CGPoint(x: w * 0.16, y: h * 0.18))
                box.addLine(to: CGPoint(x: w * 0.84, y: h * 0.16))
                box.addLine(to: CGPoint(x: w * 0.85, y: h * 0.84))
                box.addLine(to: CGPoint(x: w * 0.17, y: h * 0.83))
                box.closeSubpath()
                ctx.stroke(box, with: .color(LedgerColor.inkPrimary), style: StrokeStyle(lineWidth: 1.25, lineJoin: .round))

                if isChecked {
                    var check = Path()
                    check.move(to: CGPoint(x: w * 0.27, y: h * 0.52))
                    check.addLine(to: CGPoint(x: w * 0.44, y: h * 0.69))
                    check.addLine(to: CGPoint(x: w * 0.77, y: h * 0.30))
                    ctx.stroke(check, with: .color(LedgerColor.inkPrimary), style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(width: 24, height: 24)
    }
}

func formatByteCount(_ bytes: Int64) -> String {
    let b = Double(max(0, bytes))
    if b < 1024 { return "\(Int(b)) B" }
    if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024.0) }
    if b < 1024 * 1024 * 1024 { return String(format: "%.2f MB", b / (1024.0 * 1024.0)) }
    return String(format: "%.2f GB", b / (1024.0 * 1024.0 * 1024.0))
}

// MARK: - Routine Emblem & Muscle Filter Components

struct RoutineEmblemBadgeView: View {
    let emblem: String
    var fontSize: CGFloat = 14

    var body: some View {
        let clean = RoutineEmblemCatalog.sanitize(emblem)
        if !clean.isEmpty {
            if RoutineEmblemCatalog.isShape(clean) {
                Text(clean)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(LedgerColor.warmTerracotta)
            } else {
                Text(clean)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(LedgerColor.inkPrimary)
            }
        }
    }
}

struct CalendarEmblemStripView: View {
    let markers: [CalendarRoutineMarker]
    let hasLoggedSets: Bool
    var compact: Bool = false

    var body: some View {
        if markers.isEmpty {
            Circle()
                .fill(LedgerColor.inkPrimary.opacity(hasLoggedSets ? (compact ? 0.95 : 1.0) : (compact ? 0.0 : 0.14)))
                .frame(width: compact ? 3.5 : 4.0, height: compact ? 3.5 : 4.0)
        } else {
            let overflow = markers.count > 3
            let visible = overflow ? Array(markers.prefix(2)) : Array(markers.prefix(3))
            let hasAnyEmblem = markers.contains { !$0.emblem.isEmpty }

            VStack(spacing: compact ? 1.5 : 2) {
                HStack(spacing: compact ? 1.5 : 2.5) {
                    ForEach(visible) { m in
                        if m.emblem.isEmpty {
                            Circle()
                                .fill(LedgerColor.inkPrimary.opacity(hasLoggedSets ? 0.95 : 0.45))
                                .frame(width: compact ? 3.5 : 4.5, height: compact ? 3.5 : 4.5)
                        } else {
                            RoutineEmblemBadgeView(emblem: m.emblem, fontSize: compact ? 8.5 : 10.5)
                                .lineLimit(1)
                        }
                    }

                    if overflow {
                        Text("+")
                            .font(.system(size: compact ? 7.5 : 8.5, weight: .bold))
                            .foregroundStyle(LedgerColor.inkSecondary)
                    }
                }
                .frame(minHeight: compact ? 10 : 12)

                if hasLoggedSets && hasAnyEmblem {
                    Capsule()
                        .fill(LedgerColor.verifiedSage)
                        .frame(width: compact ? 8 : 11, height: compact ? 1.5 : 2)
                }
            }
        }
    }
}

struct RoutineEmblemPickerView: View {
    @Binding var selectedEmblem: String
    @State private var customText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("SELECTED:")
                    .font(LedgerFont.sansSm())
                    .tracking(1.0)
                    .foregroundStyle(LedgerColor.inkSecondary)

                if selectedEmblem.isEmpty {
                    Text("None")
                        .font(LedgerFont.serifMd(italic: true))
                        .foregroundStyle(LedgerColor.inkSecondary)
                } else {
                    RoutineEmblemBadgeView(emblem: selectedEmblem, fontSize: 16)
                }

                Spacer()

                if !selectedEmblem.isEmpty {
                    Button("Clear") {
                        LedgerHaptics.light()
                        selectedEmblem = ""
                        customText = ""
                    }
                    .buttonStyle(WarmActionButtonStyle())
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("SHAPES")
                    .font(LedgerFont.sansSm())
                    .tracking(1.2)
                    .foregroundStyle(LedgerColor.inkSecondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(RoutineEmblemCatalog.shapes, id: \.self) { shape in
                            emblemCell(shape)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("EMOJIS")
                    .font(LedgerFont.sansSm())
                    .tracking(1.2)
                    .foregroundStyle(LedgerColor.inkSecondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(RoutineEmblemCatalog.emojis, id: \.self) { emoji in
                            emblemCell(emoji)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Or type any emoji / 1-2 char label...", text: $customText)
                    .font(LedgerFont.sansMd())
                    .foregroundStyle(LedgerColor.inkPrimary)
                    .warmRecessedField()
                    .onChange(of: customText) { _, newVal in
                        let sanitized = RoutineEmblemCatalog.sanitize(newVal)
                        if sanitized != newVal {
                            customText = sanitized
                        }
                        if !sanitized.isEmpty {
                            selectedEmblem = sanitized
                        }
                    }
            }
        }
        .softPanel()
        .onAppear {
            if !selectedEmblem.isEmpty &&
                !RoutineEmblemCatalog.shapes.contains(selectedEmblem) &&
                !RoutineEmblemCatalog.emojis.contains(selectedEmblem) {
                customText = selectedEmblem
            }
        }
    }

    private func emblemCell(_ symbol: String) -> some View {
        let active = selectedEmblem == symbol
        return Button {
            LedgerHaptics.light()
            if active {
                selectedEmblem = ""
                customText = ""
            } else {
                selectedEmblem = symbol
                customText = ""
            }
        } label: {
            RoutineEmblemBadgeView(emblem: symbol, fontSize: 15)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(active ? LedgerColor.warmTerracotta.opacity(0.24) : LedgerColor.parchmentLight.opacity(0.75))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            active ? LedgerColor.warmTerracotta : LedgerColor.inkPrimary.opacity(0.16),
                            lineWidth: active ? 1.4 : 0.8
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

struct MuscleGroupFilterBar: View {
    @Binding var selectedRegion: MuscleRegion
    @Binding var selectedSubGroup: MuscleSubGroup?
    var regions: [MuscleRegion] = MuscleRegion.filterRegions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(regions) { region in
                        let isSelected = selectedRegion == region
                        Button {
                            LedgerHaptics.light()
                            selectedRegion = region
                            selectedSubGroup = nil
                        } label: {
                            chipLabel(region.rawValue, isActive: isSelected)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if selectedRegion.subGroups.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Button {
                            LedgerHaptics.light()
                            selectedSubGroup = nil
                        } label: {
                            chipLabel("All \(selectedRegion.rawValue)", isActive: selectedSubGroup == nil, subtle: true)
                        }
                        .buttonStyle(.plain)

                        ForEach(selectedRegion.subGroups) { sub in
                            let isSubSelected = selectedSubGroup == sub
                            Button {
                                LedgerHaptics.light()
                                selectedSubGroup = isSubSelected ? nil : sub
                            } label: {
                                chipLabel(sub.rawValue, isActive: isSubSelected, subtle: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func chipLabel(_ title: String, isActive: Bool, subtle: Bool = false) -> some View {
        Text(title.uppercased())
            .font(LedgerFont.sansSm(semibold: isActive))
            .tracking(0.6)
            .foregroundStyle(isActive ? LedgerColor.buttonTextLight : LedgerColor.inkPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, subtle ? 5 : 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isActive
                            ? (subtle ? LedgerColor.warmTerracotta : LedgerColor.inkPrimary)
                            : LedgerColor.parchmentLight.opacity(subtle ? 0.65 : 0.85)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        LedgerColor.inkPrimary.opacity(isActive ? 0.0 : 0.2),
                        lineWidth: 0.8
                    )
            )
    }
}
