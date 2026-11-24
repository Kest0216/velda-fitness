import Foundation
import SwiftUI

enum RecipeDropdownKind {
    case meal
    case dietary
}

@MainActor
final class LedgerStore: ObservableObject {
    @Published var activePillar: Pillar = .workouts
    @Published var inkWriteEpoch: Int = 0
    @Published var cycleTrackingEnabled: Bool = true

    // Workouts
    @Published var todayDow: Int = DatabaseManager.weekdayIndex()
    @Published var todayDate: String = DatabaseManager.isoDate()
    @Published var selectedDate: String = DatabaseManager.isoDate()
    @Published var displayedMonthAnchor: Date = Date()
    @Published var weekSlots: [WeekDaySlot] = []
    @Published var monthSlots: [MonthDaySlot] = []
    @Published var routines: [RoutineSummary] = []
    @Published var workout: DayWorkout?
    @Published var editRoutineMode: Bool = false
    @Published var showMonthlyCalendar: Bool = false
    @Published var showRoutineManager: Bool = false
    @Published var routineManagerStartInCreate: Bool = false
    @Published var showCustomExerciseStudio: Bool = false
    @Published var showInlineRoutinePicker: Bool = false
    @Published var openVideoIds: Set<String> = []
    @Published var openTrendIds: Set<String> = []
    @Published var expandedExerciseIds: Set<String> = []
    @Published var pickerQuery: String = ""
    @Published var pickerResults: [Exercise] = []
    @Published var pickerOpen: Bool = false
    @Published var customLinkedVideoFilename: String = ""
    @Published var customExercises: [Exercise] = []

    // AI Routine Builder ("Create for Me")
    @Published var isGeneratingRoutine: Bool = false
    @Published var routineAIError: String? = nil

    // Weight Log
    @Published var showWeightLog: Bool = false
    @Published var weightLogs: [WeightLogEntry] = []

    // Diet & Macros
    @Published var macroDate: String = DatabaseManager.isoDate()
    @Published var macroTargets: MacroTargets = .default
    @Published var dailyMacros: DailyMacroTotals = DailyMacroTotals(
        kcal: 0,
        proteinG: 0,
        carbsG: 0,
        fatG: 0,
        sodiumMg: 0,
        sugarG: 0,
        cholesterolMg: 0,
        entries: []
    )
    @Published var recentKcalPoints: [DailyKcalPoint] = []
    @Published var isEstimatingMacros: Bool = false
    @Published var macroAIError: String? = nil

    // Cycle Tracking
    @Published var cycleSelectedDate: String = DatabaseManager.isoDate()
    @Published var cycleMonthAnchor: Date = Date()
    @Published var cycleLogs: [CycleLogEntry] = []
    @Published var cycleSummary: CycleSummary = CycleSummary(
        currentCycleDay: nil,
        estimatedPhase: "No Cycle Logged",
        avgCycleLength: 28,
        avgPeriodLength: 5,
        nextPredictedStart: nil,
        daysUntilNextPeriod: nil,
        predictedPeriodDates: [],
        periods: []
    )

    // Recipes
    @Published var recipeTab: RecipeTab = .saved
    @Published var mealFilter: MealFilter = .all
    @Published var dietaryFilters: [String] = []
    @Published var openDropdown: RecipeDropdownKind? = nil
    @Published var expandedRecipeId: String? = nil
    @Published var savedRecipes: [Recipe] = []
    @Published var discoverRecipes: [Recipe] = []
    @Published var discoverQuery: String = ""
    @Published var isDiscovering: Bool = false
    @Published var discoverError: String? = nil
    @Published var generatingImageRecipeId: String? = nil
    @Published var isImportingRecipeAI: Bool = false

    // AI Providers & Verification
    @Published var activeAIProvider: AIProvider = .gemini
    @Published var providerStates: [AIProvider: AIProviderConfigState] = [:]
    @Published var isTestingAI: Bool = false
    @Published var isSigningInOpenAI: Bool = false
    @Published var lastPingResult: AIPingResult? = nil

    // Vault & Toast
    @Published var storage: StorageMetrics?
    @Published var toastMessage: String? = nil

    var selectedDow: Int {
        DatabaseManager.weekdayIndex(DatabaseManager.dateFromISO(selectedDate))
    }

    var visiblePillars: [Pillar] {
        cycleTrackingEnabled
            ? [.workouts, .macros, .recipes, .cycle, .vault]
            : [.workouts, .macros, .recipes, .vault]
    }

    var activeProviderState: AIProviderConfigState {
        providerStates[activeAIProvider] ?? KeychainStore.shared.configState(for: activeAIProvider)
    }

    var hasConfiguredAICredential: Bool {
        activeProviderState.hasCredential
    }

    var activeProviderSupportsImageGeneration: Bool {
        activeAIProvider == .gemini || activeAIProvider == .openai
    }

    static let dietaryOptions = [
        "High-Protein",
        "Gluten-Free",
        "Dairy-Free",
        "Nut-Free",
        "Egg-Free",
        "Soy-Free",
        "Vegetarian",
    ]

    private let db = DatabaseManager.shared
    private let keychain = KeychainStore.shared
    private let ai = AIProviderService.shared
    private let openAIOAuth = OpenAIOAuthService.shared
    private let cloudSync = CloudSyncService.shared
    private let exporter = ExportShareService.shared
    private var toastTask: Task<Void, Never>?

    init() {
        keychain.migrateLegacySQLiteKeyIfNeeded(db: db)
        bootstrap()
    }

    func triggerInkWrite() {
        inkWriteEpoch &+= 1
    }

    func bootstrap() {
        let now = Date()
        todayDow = DatabaseManager.weekdayIndex(now)
        todayDate = DatabaseManager.isoDate(now)
        selectedDate = todayDate
        macroDate = todayDate
        cycleSelectedDate = todayDate
        displayedMonthAnchor = now
        cycleMonthAnchor = now

        cycleTrackingEnabled = db.getSetting("cycle_tracking_enabled", default: "1") != "0"
        if !cycleTrackingEnabled && activePillar == .cycle {
            activePillar = .workouts
        }

        reloadWorkoutState()
        reloadMacroState()
        reloadCycleState()
        reloadAIState()

        let recs = db.listRecipes()
        savedRecipes = recs.saved
        discoverRecipes = recs.discover
        pickerResults = db.fuzzySearchExercises(query: "", limit: 25)
    }

    func refreshAll() {
        LedgerHaptics.medium()
        bootstrap()
        cloudSync.refreshStatus()
        triggerInkWrite()
        showToast("Ledger refreshed")
    }

    func selectPillar(_ pillar: Pillar) {
        let resolved = (pillar == .cycle && !cycleTrackingEnabled) ? .workouts : pillar
        guard activePillar != resolved else { return }
        openDropdown = nil
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            activePillar = resolved
        }
    }

    func setCycleTrackingEnabled(_ enabled: Bool) {
        LedgerHaptics.medium()
        cycleTrackingEnabled = enabled
        db.setSetting("cycle_tracking_enabled", value: enabled ? "1" : "0")
        if !enabled && activePillar == .cycle {
            activePillar = .vault
        }
        showToast(enabled ? "Cycle tracker enabled" : "Cycle tracker hidden")
    }

    // MARK: - Workouts Actions

    func selectDate(_ isoDate: String) {
        LedgerHaptics.light()
        selectedDate = isoDate
        macroDate = isoDate
        displayedMonthAnchor = DatabaseManager.dateFromISO(isoDate)
        openVideoIds.removeAll()
        expandedExerciseIds.removeAll()
        showInlineRoutinePicker = false
        pickerOpen = false
        editRoutineMode = false
        reloadWorkoutState()
        reloadMacroState()
        triggerInkWrite()
    }

    func jumpToToday() {
        selectDate(todayDate)
        withAnimation(.easeInOut(duration: 0.2)) {
            showMonthlyCalendar = false
        }
    }

    func shiftDisplayedMonth(by delta: Int) {
        LedgerHaptics.light()
        displayedMonthAnchor = DatabaseManager.shiftMonth(displayedMonthAnchor, by: delta)
        monthSlots = db.getMonthDaySlots(forMonthAnchor: displayedMonthAnchor, todayDate: todayDate)
    }

    func toggleMonthlyCalendar() {
        LedgerHaptics.medium()
        withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
            showMonthlyCalendar.toggle()
        }
        if showMonthlyCalendar {
            monthSlots = db.getMonthDaySlots(forMonthAnchor: displayedMonthAnchor, todayDate: todayDate)
        }
    }

    func openRoutineManager(createNew: Bool = false) {
        LedgerHaptics.medium()
        routineAIError = nil
        routineManagerStartInCreate = createNew
        showRoutineManager = true
    }

    func openCustomExerciseStudio() {
        LedgerHaptics.medium()
        customExercises = db.listCustomExercises()
        showCustomExerciseStudio = true
    }

    func openWeightLog() {
        LedgerHaptics.medium()
        let unit = storage?.weightUnit ?? "lbs"
        weightLogs = db.listWeightLogs(displayUnit: unit)
        showWeightLog = true
    }

    func logBodyWeight(date: String, weight: Double, note: String = "") {
        guard weight > 0 else {
            showToast("Enter a valid weight")
            return
        }
        let unit = storage?.weightUnit ?? "lbs"
        db.upsertWeightLog(logDate: date, weight: weight, unit: unit, note: note)
        weightLogs = db.listWeightLogs(displayUnit: unit)
        storage = db.getStorageMetrics()
        LedgerHaptics.heavy()
        let formatted = weight.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(weight))"
            : String(format: "%.1f", weight)
        showToast("Logged \(formatted) \(unit.uppercased())")
    }

    func deleteBodyWeight(_ id: Int64) {
        db.deleteWeightLog(id: id)
        let unit = storage?.weightUnit ?? "lbs"
        weightLogs = db.listWeightLogs(displayUnit: unit)
        storage = db.getStorageMetrics()
        LedgerHaptics.heavy()
        showToast("Weight entry removed")
    }

    func saveRoutineTitle(_ newTitle: String) {
        let clean = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if let rid = workout?.routineId {
            db.updateRoutineTitle(routineId: rid, title: clean)
            LedgerHaptics.medium()
        } else {
            _ = db.createRoutine(title: clean, exerciseIds: [], assignWeekdays: [], assignDate: selectedDate)
            LedgerHaptics.heavy()
        }
        reloadWorkoutState()
        editRoutineMode = false
        showToast("Routine title saved")
    }

    func toggleVideo(_ exerciseId: String) {
        LedgerHaptics.light()
        if openVideoIds.contains(exerciseId) {
            openVideoIds.remove(exerciseId)
        } else {
            openVideoIds.insert(exerciseId)
        }
    }

    func toggleTrend(_ exerciseId: String) {
        LedgerHaptics.light()
        if openTrendIds.contains(exerciseId) {
            openTrendIds.remove(exerciseId)
        } else {
            openTrendIds.insert(exerciseId)
        }
    }

    func toggleExerciseExpanded(_ exerciseId: String) {
        LedgerHaptics.light()
        withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
            if expandedExerciseIds.contains(exerciseId) {
                expandedExerciseIds.remove(exerciseId)
                openVideoIds.remove(exerciseId)
            } else {
                expandedExerciseIds.insert(exerciseId)
            }
        }
    }

    func completeAndMinimizeExercise(_ ex: RoutineExerciseItem) {
        if ex.sets.isEmpty {
            db.upsertWorkoutSet(
                id: nil,
                sessionDate: selectedDate,
                exerciseId: ex.id,
                reps: ex.suggestedReps,
                weight: ex.suggestedWeight,
                completed: true
            )
        } else {
            for s in ex.sets where !s.completed {
                db.upsertWorkoutSet(
                    id: s.id,
                    sessionDate: selectedDate,
                    exerciseId: ex.id,
                    reps: s.reps,
                    weight: s.weight,
                    completed: true
                )
            }
        }
        reloadWorkoutState()
        LedgerHaptics.heavy()
        withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
            expandedExerciseIds.remove(ex.id)
            openVideoIds.remove(ex.id)
        }
        showToast("Completed · \(ex.name)")
    }

    func addWorkingSet(for ex: RoutineExerciseItem) {
        let last = ex.sets.last
        let reps = last?.reps ?? ex.suggestedReps
        let weight = last?.weight ?? ex.suggestedWeight
        db.upsertWorkoutSet(
            id: nil,
            sessionDate: selectedDate,
            exerciseId: ex.id,
            reps: reps,
            weight: weight,
            completed: true
        )
        reloadWorkoutState()
        LedgerHaptics.heavy()
        showToast("Working set logged")
    }

    func updateSet(_ setItem: WorkoutSet, exerciseId: String, reps: Int, weight: Double, completed: Bool) {
        LedgerHaptics.medium()
        db.upsertWorkoutSet(
            id: setItem.id,
            sessionDate: selectedDate,
            exerciseId: exerciseId,
            reps: reps,
            weight: weight,
            completed: completed
        )
        reloadWorkoutState()
    }

    func deleteSet(_ setId: Int64) {
        db.deleteWorkoutSet(id: setId)
        reloadWorkoutState()
        LedgerHaptics.heavy()
    }

    func searchExercises(_ query: String) {
        pickerQuery = query
        pickerOpen = true
        pickerResults = db.fuzzySearchExercises(query: query, limit: 25)
    }

    func addExerciseToCurrentDay(_ exerciseId: String) {
        if let rid = workout?.routineId {
            db.addExerciseToRoutine(routineId: rid, exerciseId: exerciseId)
        } else {
            let dayFull = workout?.dayFullName ?? "Custom"
            _ = db.createRoutine(
                title: "\(dayFull) Routine",
                exerciseIds: [exerciseId],
                assignWeekdays: [],
                assignDate: selectedDate
            )
        }
        expandedExerciseIds.insert(exerciseId)
        pickerQuery = ""
        pickerOpen = false
        customLinkedVideoFilename = ""
        reloadWorkoutState()
        LedgerHaptics.heavy()
        showToast("Added to routine")
    }

    func removeExerciseFromCurrentDay(_ exerciseId: String) {
        guard let rid = workout?.routineId else { return }
        db.removeExerciseFromRoutine(routineId: rid, exerciseId: exerciseId)
        expandedExerciseIds.remove(exerciseId)
        openVideoIds.remove(exerciseId)
        reloadWorkoutState()
        LedgerHaptics.heavy()
        showToast("Removed from routine")
    }

    func createCustomExercise() {
        let clean = pickerQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let existingRid = workout?.routineId
        let created = db.createCustomExercise(
            name: clean,
            muscleHint: "Custom",
            trackingType: "weighted",
            equipment: "",
            notes: "",
            videoFilename: customLinkedVideoFilename.isEmpty ? nil : customLinkedVideoFilename,
            routineId: existingRid
        )
        if existingRid == nil {
            let dayFull = workout?.dayFullName ?? "Custom"
            _ = db.createRoutine(
                title: "\(dayFull) Routine",
                exerciseIds: [created.id],
                assignWeekdays: [],
                assignDate: selectedDate
            )
        }
        expandedExerciseIds.insert(created.id)
        pickerQuery = ""
        pickerOpen = false
        customLinkedVideoFilename = ""
        pickerResults = db.fuzzySearchExercises(query: "", limit: 25)
        reloadWorkoutState()
        LedgerHaptics.heavy()
        showToast("Added custom: \(clean)")
    }

    func createCustomExerciseOnly(name: String, videoFilename: String?) -> Exercise {
        let ex = db.createCustomExercise(
            name: name,
            muscleHint: "Custom",
            trackingType: "weighted",
            equipment: "",
            notes: "",
            videoFilename: videoFilename,
            routineId: nil
        )
        customExercises = db.listCustomExercises()
        pickerResults = db.fuzzySearchExercises(query: "", limit: 25)
        storage = db.getStorageMetrics()
        LedgerHaptics.heavy()
        return ex
    }

    @discardableResult
    func createCustomExerciseFull(
        name: String,
        muscleHint: String,
        trackingType: String,
        equipment: String,
        notes: String,
        videoFilename: String?,
        addToCurrentDay: Bool = false
    ) -> Exercise {
        let rid = addToCurrentDay ? workout?.routineId : nil
        let ex = db.createCustomExercise(
            name: name,
            muscleHint: muscleHint,
            trackingType: trackingType,
            equipment: equipment,
            notes: notes,
            videoFilename: videoFilename,
            routineId: rid
        )
        if addToCurrentDay && rid == nil {
            let dayFull = workout?.dayFullName ?? "Custom"
            _ = db.createRoutine(
                title: "\(dayFull) Routine",
                exerciseIds: [ex.id],
                assignWeekdays: [],
                assignDate: selectedDate
            )
        }
        pickerResults = db.fuzzySearchExercises(query: pickerQuery, limit: 25)
        reloadWorkoutState()
        LedgerHaptics.heavy()
        showToast("Saved custom: \(ex.name)")
        return ex
    }

    func updateCustomExercise(
        id: String,
        name: String,
        muscleHint: String,
        trackingType: String,
        equipment: String,
        notes: String,
        videoFilename: String?
    ) {
        db.updateCustomExercise(
            id: id,
            name: name,
            muscleHint: muscleHint,
            trackingType: trackingType,
            equipment: equipment,
            notes: notes,
            videoFilename: videoFilename
        )
        pickerResults = db.fuzzySearchExercises(query: pickerQuery, limit: 25)
        reloadWorkoutState()
        LedgerHaptics.medium()
        showToast("Updated \(name)")
    }

    func deleteCustomExercise(_ id: String) {
        db.deleteCustomExercise(id: id)
        pickerResults = db.fuzzySearchExercises(query: pickerQuery, limit: 25)
        reloadWorkoutState()
        LedgerHaptics.heavy()
        showToast("Custom exercise deleted")
    }

    func createRoutine(title: String, exerciseIds: [String], weekdays: [Int], assignSelectedDate: Bool) {
        _ = db.createRoutine(
            title: title,
            exerciseIds: exerciseIds,
            assignWeekdays: weekdays,
            assignDate: assignSelectedDate ? selectedDate : nil
        )
        reloadWorkoutState()
        LedgerHaptics.heavy()
        triggerInkWrite()
        showToast("Created routine: \(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom Routine" : title)")
    }

    func generateRoutineForMe(
        prompt: String,
        weekdays: [Int],
        assignSelectedDate: Bool,
        includeCustomExercises: Bool = true
    ) async -> GeneratedRoutinePlan? {
        let clean = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            showToast("Describe what you want to train")
            return nil
        }

        LedgerHaptics.medium()
        isGeneratingRoutine = true
        routineAIError = nil

        do {
            let plan = try await ai.buildRoutine(
                userInstruction: clean,
                includeCustomExercises: includeCustomExercises
            )
            _ = db.createRoutine(
                title: plan.title,
                exerciseIds: plan.exercises.map(\.id),
                assignWeekdays: weekdays,
                assignDate: assignSelectedDate ? selectedDate : nil
            )
            reloadWorkoutState()
            isGeneratingRoutine = false
            LedgerHaptics.heavy()
            triggerInkWrite()
            showToast("Built routine: \(plan.title)")
            return plan
        } catch {
            isGeneratingRoutine = false
            routineAIError = error.localizedDescription
            return nil
        }
    }

    func updateRoutine(id: String, title: String, exerciseIds: [String], weekdays: [Int]) {
        db.updateRoutine(id: id, title: title, exerciseIds: exerciseIds, assignWeekdays: weekdays)
        reloadWorkoutState()
        LedgerHaptics.medium()
        triggerInkWrite()
        showToast("Updated routine")
    }

    func deleteRoutine(_ id: String) {
        db.deleteRoutine(id: id)
        expandedExerciseIds.removeAll()
        openVideoIds.removeAll()
        openTrendIds.removeAll()
        editRoutineMode = false
        reloadWorkoutState()
        LedgerHaptics.heavy()
        triggerInkWrite()
        showToast("Deleted routine")
    }

    func deleteAllRoutines() {
        db.deleteAllRoutines()
        expandedExerciseIds.removeAll()
        openVideoIds.removeAll()
        openTrendIds.removeAll()
        editRoutineMode = false
        showInlineRoutinePicker = false
        reloadWorkoutState()
        LedgerHaptics.heavy()
        triggerInkWrite()
        showToast("All routines deleted")
    }

    func toggleRoutineWeekday(routineId: String, dayOfWeek: Int) {
        LedgerHaptics.medium()
        let clearDate = (dayOfWeek == selectedDow) ? selectedDate : nil
        db.toggleRoutineWeekday(routineId: routineId, dayOfWeek: dayOfWeek, clearOverrideForDate: clearDate)
        reloadWorkoutState()
    }

    func assignRoutine(_ routineId: String, toSelectedDateOnly: Bool) {
        LedgerHaptics.medium()
        if toSelectedDateOnly {
            db.assignRoutineToDate(routineId: routineId, sessionDate: selectedDate)
        } else {
            db.assignRoutineToWeekday(routineId: routineId, dayOfWeek: selectedDow, clearOverrideForDate: selectedDate)
        }
        showInlineRoutinePicker = false
        expandedExerciseIds.removeAll()
        reloadWorkoutState()
        triggerInkWrite()
        showToast(toSelectedDateOnly ? "Assigned to \(DatabaseManager.shortDateLabel(selectedDate))" : "Assigned to weekly schedule")
    }

    func removeRoutineFromSelectedDateOnly() {
        db.clearDateSchedule(sessionDate: selectedDate)
        expandedExerciseIds.removeAll()
        openVideoIds.removeAll()
        editRoutineMode = false
        reloadWorkoutState()
        LedgerHaptics.heavy()
        triggerInkWrite()
        showToast("Cleared for \(DatabaseManager.shortDateLabel(selectedDate))")
    }

    func removeRoutineFromWeeklyDay() {
        db.clearWeekdaySchedule(dayOfWeek: selectedDow, clearOverrideForDate: selectedDate)
        expandedExerciseIds.removeAll()
        openVideoIds.removeAll()
        editRoutineMode = false
        reloadWorkoutState()
        LedgerHaptics.heavy()
        triggerInkWrite()
        showToast("Cleared from weekly schedule")
    }

    private func reloadWorkoutState() {
        routines = db.listRoutines()
        customExercises = db.listCustomExercises()
        weekSlots = db.getWeekDaySlots(containing: selectedDate, todayDate: todayDate)
        monthSlots = db.getMonthDaySlots(forMonthAnchor: displayedMonthAnchor, todayDate: todayDate)
        workout = db.getDayWorkout(sessionDate: selectedDate)
        let metrics = db.getStorageMetrics()
        storage = metrics
        weightLogs = db.listWeightLogs(displayUnit: metrics.weightUnit)
    }

    // MARK: - Diet & Macros Actions

    func selectMacroDate(_ isoDate: String) {
        LedgerHaptics.light()
        macroDate = isoDate
        reloadMacroState()
        triggerInkWrite()
    }

    func shiftMacroDate(by delta: Int) {
        selectMacroDate(DatabaseManager.shiftISODate(macroDate, byDays: delta))
    }

    func updateMacroTargets(_ targets: MacroTargets) {
        db.saveMacroTargets(targets)
        reloadMacroState()
        LedgerHaptics.medium()
        showToast("Macro targets saved")
    }

    func addMacroEntry(
        mealSlot: String,
        name: String,
        servings: Double = 1.0,
        kcal: Int,
        proteinG: Int,
        carbsG: Int,
        fatG: Int,
        sodiumMg: Int = 0,
        sugarG: Int = 0,
        cholesterolMg: Int = 0,
        recipeId: String? = nil,
        notes: String = ""
    ) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            showToast("Enter a meal or food name")
            return
        }
        db.addMacroLog(
            logDate: macroDate,
            mealSlot: mealSlot,
            name: clean,
            servings: servings,
            kcal: kcal,
            proteinG: proteinG,
            carbsG: carbsG,
            fatG: fatG,
            sodiumMg: sodiumMg,
            sugarG: sugarG,
            cholesterolMg: cholesterolMg,
            recipeId: recipeId,
            notes: notes
        )
        reloadMacroState()
        storage = db.getStorageMetrics()
        LedgerHaptics.heavy()
        showToast("Logged \(clean)")
    }

    func logRecipeToMacros(_ recipe: Recipe, servings: Double = 1.0, targetDate: String? = nil) {
        let mult = max(0.25, servings)
        let logDate = targetDate ?? macroDate
        let slot = ["Breakfast", "Lunch", "Dinner", "Snacks"].contains(recipe.mealType) ? recipe.mealType : "Dinner"
        db.addMacroLog(
            logDate: logDate,
            mealSlot: slot,
            name: recipe.title,
            servings: mult,
            kcal: Int(round(Double(recipe.kcal) * mult)),
            proteinG: Int(round(Double(recipe.proteinG) * mult)),
            carbsG: Int(round(Double(recipe.carbsG) * mult)),
            fatG: Int(round(Double(recipe.fatG) * mult)),
            sodiumMg: Int(round(Double(recipe.sodiumMg) * mult)),
            sugarG: Int(round(Double(recipe.sugarG) * mult)),
            cholesterolMg: Int(round(Double(recipe.cholesterolMg) * mult)),
            recipeId: recipe.id,
            notes: mult == 1.0 ? "From saved recipe" : String(format: "%.2g servings", mult)
        )
        if logDate == macroDate {
            reloadMacroState()
        }
        storage = db.getStorageMetrics()
        LedgerHaptics.heavy()
        showToast("Logged to Macros")
    }

    func macroHistory(for metric: MacroMetric, days: Int) -> [MacroHistoryPoint] {
        db.macroHistoryPoints(metric: metric, endingAt: macroDate, days: days)
    }

    func deleteMacroEntry(_ id: Int64) {
        db.deleteMacroLog(id: id)
        reloadMacroState()
        storage = db.getStorageMetrics()
        LedgerHaptics.heavy()
        showToast("Macro entry removed")
    }

    func estimateMealWithAI(description: String) async -> EstimatedMealMacros? {
        let clean = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            showToast("Describe what you ate")
            return nil
        }
        LedgerHaptics.medium()
        isEstimatingMacros = true
        macroAIError = nil
        do {
            let est = try await ai.estimateMealMacros(description: clean)
            isEstimatingMacros = false
            return est
        } catch {
            isEstimatingMacros = false
            macroAIError = error.localizedDescription
            return nil
        }
    }

    private func reloadMacroState() {
        macroTargets = db.getMacroTargets()
        dailyMacros = db.listMacroLogs(forDate: macroDate)
        recentKcalPoints = db.recentDailyKcalPoints(endingAt: macroDate, days: 7)
    }

    // MARK: - Cycle Tracking Actions

    func selectCycleDate(_ isoDate: String) {
        LedgerHaptics.light()
        cycleSelectedDate = isoDate
        cycleMonthAnchor = DatabaseManager.dateFromISO(isoDate)
    }

    func shiftCycleMonth(by delta: Int) {
        LedgerHaptics.light()
        cycleMonthAnchor = DatabaseManager.shiftMonth(cycleMonthAnchor, by: delta)
    }

    func cycleLog(forDate isoDate: String) -> CycleLogEntry? {
        cycleLogs.first { $0.logDate == isoDate }
    }

    func saveCycleLog(
        date: String,
        flow: CycleFlowLevel,
        symptoms: [String],
        mood: String,
        energy: Int,
        bbt: Double?,
        notes: String
    ) {
        let entry = CycleLogEntry(
            logDate: date,
            flow: flow,
            symptoms: symptoms,
            mood: mood,
            energy: energy,
            bbt: bbt,
            notes: notes,
            updatedAt: DatabaseManager.nowISO()
        )
        db.upsertCycleLog(entry)
        reloadCycleState()
        storage = db.getStorageMetrics()
        LedgerHaptics.heavy()
        showToast("Saved cycle entry")
    }

    func deleteCycleLog(date: String) {
        db.deleteCycleLog(logDate: date)
        reloadCycleState()
        storage = db.getStorageMetrics()
        LedgerHaptics.heavy()
        showToast("Cycle entry cleared")
    }

    private func reloadCycleState() {
        cycleLogs = db.listAllCycleLogs()
        cycleSummary = db.computeCycleSummary(todayDate: todayDate)
    }

    // MARK: - Recipes Actions

    func filteredRecipes(in tab: RecipeTab) -> [Recipe] {
        let pool = tab == .saved ? savedRecipes : discoverRecipes
        return pool.filter { recipeMatchesFilters($0) }
    }

    private func recipeMatchesFilters(_ rec: Recipe) -> Bool {
        if mealFilter != .all {
            let rm = rec.mealType.lowercased()
            let t = rec.title.lowercased()
            if rm != mealFilter.rawValue.lowercased() && !t.contains(mealFilter.rawValue.lowercased()) {
                return false
            }
        }
        for df in dietaryFilters {
            let tags = rec.dietaryTags.map { $0.lowercased() }
            let allergens = rec.allergens.map { $0.lowercased() }
            let ingText = rec.ingredients.joined(separator: " ").lowercased()
            let titleText = rec.title.lowercased()

            switch df {
            case "High-Protein":
                if !tags.contains("high-protein") && rec.proteinG < 28 { return false }
            case "Gluten-Free":
                if !tags.contains("gluten-free") && allergens.contains(where: { $0.contains("wheat") || $0.contains("gluten") }) { return false }
            case "Dairy-Free":
                if !tags.contains("dairy-free") && allergens.contains(where: { $0.contains("dairy") || $0.contains("milk") }) { return false }
            case "Nut-Free":
                if !tags.contains("nut-free") && allergens.contains(where: { $0.contains("nut") || $0.contains("peanut") }) { return false }
            case "Egg-Free":
                if !tags.contains("egg-free") && allergens.contains(where: { $0.contains("egg") }) { return false }
            case "Soy-Free":
                if !tags.contains("soy-free") && allergens.contains(where: { $0.contains("soy") }) { return false }
            case "Vegetarian":
                let meats = ["chicken", "beef", "steak", "pork", "turkey", "salmon", "shrimp", "fish", "bacon", "sausage", "lamb", "tuna"]
                let combined = "\(titleText) \(ingText)"
                let hasMeat = meats.contains { combined.contains($0) }
                if !tags.contains("vegetarian") && (hasMeat || allergens.contains(where: { $0.contains("fish") || $0.contains("shellfish") })) {
                    return false
                }
            default:
                break
            }
        }
        return true
    }

    func toggleDietaryFilter(_ option: String) {
        LedgerHaptics.light()
        if let idx = dietaryFilters.firstIndex(of: option) {
            dietaryFilters.remove(at: idx)
        } else {
            dietaryFilters.append(option)
        }
    }

    func toggleRecipeSave(_ id: String) {
        guard let updated = db.toggleRecipeSaved(id: id) else { return }
        let recs = db.listRecipes()
        savedRecipes = recs.saved
        discoverRecipes = recs.discover
        storage = db.getStorageMetrics()
        LedgerHaptics.heavy()
        showToast(updated.isSaved ? "Saved to ledger" : "Moved to discover")
    }

    func saveCookedPhoto(recipeId: String, rawData: Data) {
        if db.saveCookedPhoto(recipeId: recipeId, rawImageData: rawData) {
            let recs = db.listRecipes()
            savedRecipes = recs.saved
            discoverRecipes = recs.discover
            storage = db.getStorageMetrics()
            LedgerHaptics.heavy()
            showToast("Cooked dish photo saved")
        } else {
            showToast("Could not save image")
        }
    }

    func createManualRecipe(_ recipe: Recipe, rawImageData: Data?) {
        let created = db.createManualRecipe(recipe, rawImageData: rawImageData)
        let recs = db.listRecipes()
        savedRecipes = recs.saved
        discoverRecipes = recs.discover
        recipeTab = .saved
        expandedRecipeId = created.id
        storage = db.getStorageMetrics()
        LedgerHaptics.heavy()
        triggerInkWrite()
        showToast("Created recipe: \(created.title)")
    }

    func deleteRecipe(_ id: String) {
        db.deleteRecipe(id: id)
        if expandedRecipeId == id {
            expandedRecipeId = nil
        }
        let recs = db.listRecipes()
        savedRecipes = recs.saved
        discoverRecipes = recs.discover
        storage = db.getStorageMetrics()
        LedgerHaptics.heavy()
        showToast("Recipe deleted")
    }

    func clearRecipePhoto(recipeId: String) {
        db.clearRecipePhoto(recipeId: recipeId)
        let recs = db.listRecipes()
        savedRecipes = recs.saved
        discoverRecipes = recs.discover
        storage = db.getStorageMetrics()
        LedgerHaptics.medium()
        showToast("Photo removed")
    }

    func generateAIImage(for recipe: Recipe) async -> String? {
        guard hasConfiguredAICredential else {
            return "Connect an OpenAI or Gemini API key in Vault first."
        }
        guard activeProviderSupportsImageGeneration else {
            return AIProviderError.imageGenerationUnsupported(activeAIProvider).localizedDescription
        }
        LedgerHaptics.medium()
        generatingImageRecipeId = recipe.id
        do {
            let imgData = try await ai.generateRecipeImage(title: recipe.title, ingredients: recipe.ingredients)
            if db.saveRecipeImage(recipeId: recipe.id, rawImageData: imgData, source: "ai_generated") {
                let recs = db.listRecipes()
                savedRecipes = recs.saved
                discoverRecipes = recs.discover
                storage = db.getStorageMetrics()
                generatingImageRecipeId = nil
                LedgerHaptics.heavy()
                showToast("AI dish image generated")
                return nil
            } else {
                generatingImageRecipeId = nil
                return "Generated image could not be saved."
            }
        } catch {
            generatingImageRecipeId = nil
            return error.localizedDescription
        }
    }

    func importRecipeWithAI(rawText: String) async -> String? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Paste recipe text, a webpage link, or choose a file first."
        }

        // Fast path if the user picked an already structured Velda recipe JSON
        if let jsonData = trimmed.data(using: .utf8) {
            if let wrapped = try? JSONDecoder().decode(VeldaRecipeSharePayload.self, from: jsonData) {
                db.importSingleRecipe(wrapped.recipe)
                let recs = db.listRecipes()
                savedRecipes = recs.saved
                discoverRecipes = recs.discover
                recipeTab = .saved
                storage = db.getStorageMetrics()
                LedgerHaptics.heavy()
                triggerInkWrite()
                showToast("Imported recipe: \(wrapped.recipe.title)")
                return nil
            }
            if let bare = try? JSONDecoder().decode(Recipe.self, from: jsonData) {
                db.importSingleRecipe(bare)
                let recs = db.listRecipes()
                savedRecipes = recs.saved
                discoverRecipes = recs.discover
                recipeTab = .saved
                storage = db.getStorageMetrics()
                LedgerHaptics.heavy()
                triggerInkWrite()
                showToast("Imported recipe: \(bare.title)")
                return nil
            }
        }

        guard hasConfiguredAICredential else {
            return "Connect an AI provider key or ChatGPT sign-in in Vault to import recipes with AI."
        }

        LedgerHaptics.medium()
        isImportingRecipeAI = true
        do {
            let parsed = try await ai.parseImportedRecipe(rawContent: trimmed)
            db.importSingleRecipe(parsed)
            let recs = db.listRecipes()
            savedRecipes = recs.saved
            discoverRecipes = recs.discover
            recipeTab = .saved
            storage = db.getStorageMetrics()
            isImportingRecipeAI = false
            LedgerHaptics.heavy()
            triggerInkWrite()
            showToast("Imported recipe: \(parsed.title)")
            return nil
        } catch {
            isImportingRecipeAI = false
            return error.localizedDescription
        }
    }

    func crawlRecipes() async {
        let q = discoverQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            showToast("Enter a dish or craving")
            return
        }
        LedgerHaptics.medium()
        isDiscovering = true
        discoverError = nil

        do {
            let found = try await ai.discoverRecipes(
                query: q,
                mealType: mealFilter,
                dietaryFilters: dietaryFilters,
                cacheMediaDir: db.cacheMediaDir
            )
            db.insertDiscoveredRecipes(found)
            let recs = db.listRecipes()
            savedRecipes = recs.saved
            discoverRecipes = recs.discover
            storage = db.getStorageMetrics()
            isDiscovering = false
            recipeTab = .discover
            LedgerHaptics.heavy()
            triggerInkWrite()
            showToast("Found \(found.count) verified recipes")
        } catch {
            isDiscovering = false
            discoverError = error.localizedDescription
        }
    }

    // MARK: - AI Provider & Vault Actions

    func reloadAIState() {
        let raw = db.getSetting("active_ai_provider", default: AIProvider.gemini.rawValue)
        activeAIProvider = AIProvider(rawValue: raw) ?? .gemini
        var map: [AIProvider: AIProviderConfigState] = [:]
        for p in AIProvider.allCases {
            map[p] = keychain.configState(for: p)
        }
        providerStates = map
        storage = db.getStorageMetrics()
    }

    func selectAIProvider(_ provider: AIProvider) {
        LedgerHaptics.light()
        activeAIProvider = provider
        db.setSetting("active_ai_provider", value: provider.rawValue)
        lastPingResult = nil
        discoverError = nil
        routineAIError = nil
        macroAIError = nil
        reloadAIState()
    }

    func setAuthMode(_ mode: AIAuthMode, for provider: AIProvider) {
        LedgerHaptics.light()
        keychain.setAuthMode(mode, for: provider)
        lastPingResult = nil
        reloadAIState()
    }

    func testAIProvider(_ provider: AIProvider, draftKey: String) async -> AIPingResult {
        LedgerHaptics.medium()
        isTestingAI = true
        let mode = keychain.authMode(for: provider)
        let cleanDraft = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await ai.testPing(
            provider: provider,
            authMode: mode,
            overrideKey: cleanDraft.isEmpty ? nil : cleanDraft
        )
        isTestingAI = false
        lastPingResult = result

        if result.success {
            if !cleanDraft.isEmpty && mode == .apiKey {
                keychain.set(cleanDraft, forKey: KeychainStore.apiKeyIdentifier(for: provider))
            }
            keychain.saveVerifiedPing(result)
            reloadAIState()
            LedgerHaptics.heavy()
            showToast("\(provider.displayName) verified · \(result.latencyMs) ms")
        } else {
            keychain.clearVerification(for: provider, mode: mode)
            reloadAIState()
            showToast("Ping failed")
        }
        return result
    }

    func saveOrOverrideAPIKey(_ key: String, for provider: AIProvider) {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            showToast("Paste a valid API key")
            return
        }
        keychain.setAuthMode(.apiKey, for: provider)
        keychain.set(clean, forKey: KeychainStore.apiKeyIdentifier(for: provider))
        keychain.clearVerification(for: provider, mode: .apiKey)
        lastPingResult = nil
        discoverError = nil
        routineAIError = nil
        macroAIError = nil
        reloadAIState()
        LedgerHaptics.heavy()
        showToast("\(provider.displayName) key saved in iCloud Keychain")
    }

    func signInWithOpenAI() async {
        LedgerHaptics.medium()
        isSigningInOpenAI = true
        lastPingResult = nil
        do {
            let email = try await openAIOAuth.signInWithChatGPT()
            keychain.setAuthMode(.signIn, for: .openai)
            isSigningInOpenAI = false
            reloadAIState()
            LedgerHaptics.heavy()
            showToast("Signed in: \(email)")
            _ = await testAIProvider(.openai, draftKey: "")
        } catch {
            isSigningInOpenAI = false
            showToast(error.localizedDescription)
        }
    }

    func signOutOpenAI() {
        openAIOAuth.signOut()
        lastPingResult = nil
        reloadAIState()
        LedgerHaptics.heavy()
        showToast("Signed out of ChatGPT")
    }

    func clearProviderCredential(for provider: AIProvider) {
        keychain.delete(forKey: KeychainStore.apiKeyIdentifier(for: provider))
        keychain.clearVerification(for: provider, mode: .apiKey)
        if provider == .openai {
            openAIOAuth.signOut()
        }
        lastPingResult = nil
        reloadAIState()
        LedgerHaptics.heavy()
        showToast("Cleared \(provider.displayName) credential")
    }

    // MARK: - iCloud, Export, Share & Data Wipe Actions

    func syncToICloud() async {
        LedgerHaptics.medium()
        let snap = db.exportAllDomainSnapshot()
        let ok = await cloudSync.pushSnapshotToCloudKit(snap)
        if ok {
            LedgerHaptics.heavy()
            showToast("Synced to private iCloud")
        } else if let err = cloudSync.lastError {
            showToast(err)
        }
    }

    func pullFromICloud() async {
        LedgerHaptics.medium()
        if let snap = await cloudSync.pullSnapshotFromCloudKit() {
            db.importSnapshot(snap, merge: true)
            bootstrap()
            LedgerHaptics.heavy()
            triggerInkWrite()
            showToast("Merged private iCloud data")
        } else if let err = cloudSync.lastError {
            showToast(err)
        }
    }

    func backupToICloudDrive() -> URL? {
        LedgerHaptics.medium()
        let snap = db.exportAllDomainSnapshot()
        if let url = cloudSync.writeICloudDriveBackup(snap) {
            LedgerHaptics.heavy()
            showToast("Saved iCloud Drive backup")
            return url
        } else if let err = cloudSync.lastError {
            showToast(err)
        }
        return nil
    }

    func prepareExportFile(domain: ExportDomain, format: ExportFormat) -> URL? {
        do {
            LedgerHaptics.medium()
            return try exporter.createDomainExportFile(domain: domain, format: format)
        } catch {
            showToast("Export failed: \(error.localizedDescription)")
            return nil
        }
    }

    func prepareRecipeShareFile(_ recipe: Recipe, format: ExportFormat) -> URL? {
        do {
            LedgerHaptics.medium()
            return try exporter.createRecipeShareFile(recipe, format: format)
        } catch {
            showToast("Share failed: \(error.localizedDescription)")
            return nil
        }
    }

    func prepareRoutineShareFile(_ routine: RoutineSummary, format: ExportFormat) -> URL? {
        do {
            LedgerHaptics.medium()
            return try exporter.createRoutineShareFile(routine, format: format)
        } catch {
            showToast("Share failed: \(error.localizedDescription)")
            return nil
        }
    }

    func importJSONFile(from url: URL) {
        do {
            let result = try exporter.parseImportedJSON(from: url)
            switch result {
            case .fullSnapshot(let snap):
                db.importSnapshot(snap, merge: true)
                bootstrap()
                showToast("Imported ledger backup")
            case .singleRoutine(let rt):
                _ = db.importSingleRoutine(rt)
                reloadWorkoutState()
                showToast("Imported routine: \(rt.title)")
            case .singleRecipe(let rec):
                db.importSingleRecipe(rec)
                let recs = db.listRecipes()
                savedRecipes = recs.saved
                discoverRecipes = recs.discover
                storage = db.getStorageMetrics()
                showToast("Imported recipe: \(rec.title)")
            }
            LedgerHaptics.heavy()
            triggerInkWrite()
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func wipeAllUserData() {
        LedgerHaptics.heavy()
        db.wipeAllUserData()
        keychain.wipeAllAICredentials()
        lastPingResult = nil
        bootstrap()
        triggerInkWrite()
        showToast("All personal ledger data erased")
    }

    func sweepClutter() {
        let res = db.runStorageJanitor(aggressive: true)
        let recs = db.listRecipes()
        savedRecipes = recs.saved
        discoverRecipes = recs.discover
        storage = db.getStorageMetrics()
        LedgerHaptics.heavy()
        triggerInkWrite()
        showToast("Swept \(res.deletedRecipes) unsaved · Freed \(formatByteCount(res.reclaimedBytes))")
    }

    func setWeightUnit(_ unit: String) {
        LedgerHaptics.medium()
        db.setSetting("weight_unit", value: unit)
        storage = db.getStorageMetrics()
        weightLogs = db.listWeightLogs(displayUnit: unit)
        showToast("Unit set to \(unit.uppercased())")
    }

    func mediaURL(for recipe: Recipe) -> URL? {
        db.resolveMediaURL(imagePath: recipe.imagePath)
    }

    func showToast(_ msg: String) {
        toastMessage = msg
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_300_000_000)
            if !Task.isCancelled {
                toastMessage = nil
            }
        }
    }
}
