// MARK: - Root Ledger Shell
//
// Top-level 5-pillar horizontal paged container (`Workouts`, `Macros`, `Recipes`, optional `Cycle`,
// and `Vault`) anchored by a shared greeting/date header, folio indicator footer, and global
// root-level sheets (`RoutineManagerSheet`, `WeightLogSheet`, `CustomExerciseSheet`).

import SwiftUI

struct RootLedgerView: View {
    @EnvironmentObject var store: LedgerStore
    @State private var refreshSpinAngle: Double = 0

    private var greetingText: String {
        let hr = Calendar.current.component(.hour, from: Date())
        if hr < 12 { return "GOOD MORNING" }
        if hr < 18 { return "GOOD AFTERNOON" }
        return "GOOD EVENING"
    }

    private var weekdayLine: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f.string(from: Date()).uppercased()
    }

    private var fullDateLine: String {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f.string(from: Date()).uppercased()
    }

    private var hasWeightForSelectedDate: Bool {
        store.weightLogs.contains { $0.logDate == store.selectedDate }
    }

    var body: some View {
        ZStack {
            ParchmentBackgroundView()

            VStack(spacing: 0) {
                headerView
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                TabView(selection: $store.activePillar) {
                    WorkoutsView()
                        .padding(.horizontal, 24)
                        .tag(Pillar.workouts)

                    MacrosView()
                        .padding(.horizontal, 24)
                        .tag(Pillar.macros)

                    RecipesView()
                        .padding(.horizontal, 24)
                        .tag(Pillar.recipes)

                    if store.cycleTrackingEnabled {
                        CycleView()
                            .padding(.horizontal, 24)
                            .tag(Pillar.cycle)
                    }

                    VaultView()
                        .padding(.horizontal, 24)
                        .tag(Pillar.vault)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                folioStatusFooter
            }
        }
        .ledgerToastOverlay(
            (store.showRoutineManager || store.showWeightLog || store.showCustomExerciseStudio) ? nil : store.toastMessage,
            bottomPadding: 42
        )
        .onChange(of: store.activePillar) { _, _ in
            store.openDropdown = nil
            dismissLedgerKeyboard()
            LedgerHaptics.light()
            store.triggerInkWrite()
        }
        .sheet(isPresented: $store.showRoutineManager) {
            RoutineManagerSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.showWeightLog) {
            WeightLogSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.showCustomExerciseStudio) {
            CustomExerciseSheet()
                .environmentObject(store)
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("\(greetingText) · VELDA")
                    .font(LedgerFont.sansSm())
                    .tracking(2.2)
                    .foregroundStyle(LedgerColor.inkPrimary)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.65)) {
                        refreshSpinAngle += 360
                    }
                    store.refreshAll()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(LedgerColor.inkPrimary)
                        .rotationEffect(.degrees(refreshSpinAngle))
                        .frame(width: 34, height: 34)
                        .background(
                            RadialGradient(
                                colors: [LedgerColor.warmAmber.opacity(0.22), LedgerColor.warmAmber.opacity(0.03), .clear],
                                center: .center,
                                startRadius: 2,
                                endRadius: 20
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .accessibilityLabel("Refresh Velda ledger")
            }

            HStack(alignment: .center, spacing: 8) {
                Button {
                    dismissLedgerKeyboard()
                    store.jumpToToday()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(weekdayLine)
                        Text(fullDateLine)
                    }
                    .font(LedgerFont.sansSm())
                    .tracking(2.0)
                    .foregroundStyle(LedgerColor.inkPrimary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Jump to today")

                Spacer()

                if store.activePillar == .workouts {
                    Button {
                        store.openWeightLog()
                    } label: {
                        Image(systemName: "scalemass")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(LedgerColor.inkPrimary)
                            .frame(width: 34, height: 34)
                            .background(
                                Group {
                                    if store.showWeightLog || hasWeightForSelectedDate {
                                        LinearGradient(
                                            colors: [LedgerColor.warmTerracotta.opacity(0.34), LedgerColor.warmAmber.opacity(0.16), .clear],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    } else {
                                        RadialGradient(
                                            colors: [LedgerColor.warmAmber.opacity(0.22), LedgerColor.warmAmber.opacity(0.03), .clear],
                                            center: .center,
                                            startRadius: 2,
                                            endRadius: 20
                                        )
                                    }
                                }
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .accessibilityLabel("Log body weight")

                    Button {
                        store.toggleMonthlyCalendar()
                    } label: {
                        Image(systemName: "calendar")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(LedgerColor.inkPrimary)
                            .frame(width: 34, height: 34)
                            .background(
                                Group {
                                    if store.showMonthlyCalendar {
                                        LinearGradient(
                                            colors: [LedgerColor.warmTerracotta.opacity(0.34), LedgerColor.warmAmber.opacity(0.16), .clear],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    } else {
                                        RadialGradient(
                                            colors: [LedgerColor.warmAmber.opacity(0.22), LedgerColor.warmAmber.opacity(0.03), .clear],
                                            center: .center,
                                            startRadius: 2,
                                            endRadius: 20
                                        )
                                    }
                                }
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .accessibilityLabel("Toggle monthly calendar")

                    Button {
                        store.openRoutineManager(createNew: false)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Routines")
                        }
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: store.showRoutineManager))
                    .accessibilityLabel("Create and manage routines")
                }
            }
            .padding(.top, 10)
        }
    }

    private var folioStatusFooter: some View {
        VStack(spacing: 4) {
            Text(store.activePillar.label.uppercased())
                .font(LedgerFont.sansSm())
                .tracking(2.4)
                .foregroundStyle(LedgerColor.inkSecondary.opacity(0.68))
                .contentTransition(.opacity)

            HStack(spacing: 6) {
                ForEach(store.visiblePillars) { pillar in
                    let isActive = store.activePillar == pillar
                    Button {
                        store.selectPillar(pillar)
                    } label: {
                        Capsule()
                            .fill(LedgerColor.inkPrimary.opacity(isActive ? 0.62 : 0.18))
                            .frame(width: isActive ? 14 : 4, height: 2.5)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(pillar.label)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 4)
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: store.activePillar)
    }
}
