// MARK: - Domain & Persistence Models
//
// Pure Swift value types shared across SQLite persistence, SwiftUI views, JSON exports, and BYO-AI
// payloads. Includes U.S. FDA Daily Value defaults (`MacroTargets.default`), backward-compatible
// `Codable` initializers for older snapshots, progression trend summaries, and cycle phase enums.

import Foundation

enum Pillar: String, CaseIterable, Identifiable {
    case workouts
    case macros
    case recipes
    case cycle
    case vault

    var id: String { rawValue }

    var label: String {
        switch self {
        case .workouts: return "Workouts"
        case .macros: return "Macros"
        case .recipes: return "Recipes"
        case .cycle: return "Cycle"
        case .vault: return "Vault"
        }
    }
}

enum RecipeTab: Int, Hashable {
    case saved = 0
    case discover = 1
}

enum MealFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case breakfast = "Breakfast"
    case lunch = "Lunch"
    case dinner = "Dinner"
    case snacks = "Snacks"

    var id: String { rawValue }

    var displayLabel: String {
        self == .all ? "All Meals" : rawValue
    }

    var triggerLabel: String {
        self == .all ? "Meal: All" : rawValue
    }
}

struct MoveKitManifestEntry: Codable {
    let id: String
    let name: String
    let videoFilename: String
    let muscleHint: String
}

enum MuscleRegion: String, CaseIterable, Identifiable {
    case all = "All"
    case chest = "Chest"
    case back = "Back"
    case shoulders = "Shoulders"
    case arms = "Arms"
    case legs = "Legs"
    case core = "Core"
    case conditioning = "Conditioning"
    case mobility = "Mobility"
    case custom = "Custom"

    var id: String { rawValue }

    var subGroups: [MuscleSubGroup] {
        switch self {
        case .all: return []
        case .chest: return [.chest]
        case .back: return [.lats, .upperBack, .traps, .lowerBack]
        case .shoulders: return [.frontDelts, .sideDelts, .rearDelts]
        case .arms: return [.biceps, .triceps, .forearms]
        case .legs: return [.quads, .hamstrings, .glutes, .calves]
        case .core: return [.abs, .obliques]
        case .conditioning: return [.cardio, .fullBodyPlyo]
        case .mobility: return [.mobility]
        case .custom: return [.custom]
        }
    }

    static var filterRegions: [MuscleRegion] {
        [.all, .chest, .back, .shoulders, .arms, .legs, .core, .conditioning, .mobility]
    }

    static var pickerRegions: [MuscleRegion] {
        [.chest, .back, .shoulders, .arms, .legs, .core, .conditioning, .mobility, .custom]
    }

    func matches(muscleHint: String, subGroup: MuscleSubGroup?) -> Bool {
        let normalized = muscleHint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let sub = subGroup {
            return normalized == sub.rawValue.lowercased()
        }
        if self == .all {
            return true
        }
        if subGroups.contains(where: { $0.rawValue.lowercased() == normalized }) {
            return true
        }
        switch self {
        case .chest: return normalized == "push"
        case .back: return normalized == "pull" || normalized == "back"
        case .shoulders: return normalized == "shoulders"
        case .arms: return normalized == "arms"
        case .legs: return normalized == "legs"
        case .core: return normalized == "core"
        case .conditioning: return normalized == "strength" || normalized == "conditioning"
        case .mobility: return normalized == "mobility"
        case .custom: return normalized == "custom"
        case .all: return true
        }
    }
}

enum MuscleSubGroup: String, CaseIterable, Identifiable {
    case chest = "Chest"
    case lats = "Lats"
    case upperBack = "Upper Back"
    case traps = "Traps"
    case lowerBack = "Lower Back"
    case frontDelts = "Front Delts"
    case sideDelts = "Side Delts"
    case rearDelts = "Rear Delts"
    case biceps = "Biceps"
    case triceps = "Triceps"
    case forearms = "Forearms"
    case quads = "Quads"
    case hamstrings = "Hamstrings"
    case glutes = "Glutes"
    case calves = "Calves"
    case abs = "Abs"
    case obliques = "Obliques"
    case cardio = "Cardio"
    case fullBodyPlyo = "Full Body & Plyo"
    case mobility = "Mobility"
    case custom = "Custom"

    var id: String { rawValue }

    var region: MuscleRegion {
        switch self {
        case .chest: return .chest
        case .lats, .upperBack, .traps, .lowerBack: return .back
        case .frontDelts, .sideDelts, .rearDelts: return .shoulders
        case .biceps, .triceps, .forearms: return .arms
        case .quads, .hamstrings, .glutes, .calves: return .legs
        case .abs, .obliques: return .core
        case .cardio, .fullBodyPlyo: return .conditioning
        case .mobility: return .mobility
        case .custom: return .custom
        }
    }

    static func fromHint(_ raw: String) -> MuscleSubGroup? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = allCases.first(where: { $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return exact
        }
        switch trimmed.lowercased() {
        case "push": return .chest
        case "pull", "back": return .lats
        case "shoulders": return .frontDelts
        case "arms": return .biceps
        case "legs": return .quads
        case "core": return .abs
        case "strength", "conditioning": return .fullBodyPlyo
        case "mobility": return .mobility
        case "custom": return .custom
        default: return nil
        }
    }
}

enum RoutineEmblemCatalog {
    static let shapes: [String] = ["●", "▲", "■", "◆", "★", "✦", "✚", "◉", "△", "□", "◇", "☆"]
    static let emojis: [String] = ["🏋️", "💪", "🔥", "⚡", "🏃", "🚴", "🏊", "🧘", "🤸", "🥊", "🦵", "🫀", "🧗", "🎯", "⏱️", "☀️", "🌙", "🌿"]
    static let shapeSet: Set<String> = Set(shapes)

    static func isShape(_ value: String) -> Bool {
        shapeSet.contains(value)
    }

    static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return String(trimmed.prefix(2))
    }
}

enum ExerciseTrackingType: String, CaseIterable, Identifiable, Codable {
    case weighted
    case bodyweight
    case timed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .weighted: return "Weighted"
        case .bodyweight: return "Bodyweight"
        case .timed: return "Timed (sec)"
        }
    }
}

struct Exercise: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let videoFilename: String?
    let muscleHint: String
    let isCustom: Bool
    var trackingType: String = "weighted"
    var equipment: String = ""
    var notes: String = ""
}

struct WorkoutSet: Identifiable, Equatable, Codable {
    let id: Int64
    var setNumber: Int
    var reps: Int
    var weight: Double
    var completed: Bool
}

struct SessionVolumePoint: Identifiable, Equatable {
    var id: String { date }
    let date: String
    let volume: Double
    let maxWeight: Double
    let sets: Int
}

enum ProgressionStatus: String, Equatable {
    case yes
    case no
    case flat
    case baseline
}

struct ProgressionSummary: Equatable {
    let status: ProgressionStatus
    let movingMore: Bool?
    let slope: Double
    let deltaPct: Double
    let metricUnit: String
    let latestVolume: Double
    let sessions: [SessionVolumePoint]
    let trendPoints: [Double]

    static let empty = ProgressionSummary(
        status: .baseline,
        movingMore: nil,
        slope: 0,
        deltaPct: 0,
        metricUnit: "vol",
        latestVolume: 0,
        sessions: [],
        trendPoints: []
    )
}

struct RoutineExerciseItem: Identifiable, Equatable {
    let id: String
    let name: String
    let videoFilename: String?
    let muscleHint: String
    let isCustom: Bool
    var trackingType: String = "weighted"
    var equipment: String = ""
    var notes: String = ""
    var sets: [WorkoutSet]
    let suggestedReps: Int
    let suggestedWeight: Double
    let progression: ProgressionSummary
}

enum ScheduleSource: String, Equatable {
    case weekly
    case dateOverride
    case clearedDate
    case unassigned
}

enum RoutineScheduleSpan: Int, CaseIterable, Identifiable, Codable {
    case oneWeek = 1
    case twoWeeks = 2
    case threeWeeks = 3
    case fourWeeks = 4
    case sixWeeks = 6
    case eightWeeks = 8
    case twelveWeeks = 12
    case sixteenWeeks = 16
    case twentyFourWeeks = 24
    case fiftyTwoWeeks = 52

    static let defaultSpan: RoutineScheduleSpan = .fourWeeks

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .oneWeek: return "1 Week"
        case .fiftyTwoWeeks: return "52 Weeks (1 Yr)"
        default: return "\(rawValue) Weeks"
        }
    }

    var shortLabel: String {
        rawValue == 1 ? "1 Wk" : "\(rawValue) Wks"
    }

    static func fromWeeks(_ weeks: Int) -> RoutineScheduleSpan {
        if let exact = RoutineScheduleSpan(rawValue: weeks) { return exact }
        return allCases.min(by: { abs($0.rawValue - weeks) < abs($1.rawValue - weeks) }) ?? .defaultSpan
    }
}

enum InlineAssignScope: Hashable, Identifiable {
    case thisDateOnly
    case weeks(RoutineScheduleSpan)

    var id: String {
        switch self {
        case .thisDateOnly: return "this_date"
        case .weeks(let span): return "weeks_\(span.rawValue)"
        }
    }

    static var allOptions: [InlineAssignScope] {
        [.thisDateOnly] + RoutineScheduleSpan.allCases.map { .weeks($0) }
    }

    func menuLabel(dateShort: String, weekdayFull: String) -> String {
        switch self {
        case .thisDateOnly:
            return "This Date Only (\(dateShort))"
        case .weeks(let span):
            let plural = span.rawValue == 1 ? weekdayFull : "\(weekdayFull)s"
            return "\(span.label) (\(span.rawValue) \(plural))"
        }
    }

    func triggerLabel(dateShort: String, weekdayShort: String) -> String {
        switch self {
        case .thisDateOnly: return "This Date (\(dateShort))"
        case .weeks(let span): return "\(span.shortLabel) · \(weekdayShort)s"
        }
    }
}

struct RoutineRemovalInfo: Identifiable, Equatable {
    var id: String { "\(routineId)_\(sessionDate)" }
    let routineId: String
    let title: String
    let sessionDate: String
    let displayDateShort: String
    let remainingCount: Int
    let hasRecurringWeekly: Bool

    var hasRemainingBeyondToday: Bool {
        remainingCount > 1 || hasRecurringWeekly
    }
}

struct RoutineSummary: Identifiable, Equatable, Codable {
    let id: String
    let title: String
    var emblem: String = ""
    let exercises: [Exercise]
    let assignedWeekdays: [Int] // 0=Mon .. 6=Sun
    var scheduleWeeks: Int = RoutineScheduleSpan.defaultSpan.rawValue
    var upcomingDateCount: Int = 0
    var scheduledThroughDate: String? = nil
    var hasLegacyWeekly: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, title, emblem, exercises, assignedWeekdays
        case scheduleWeeks, upcomingDateCount, scheduledThroughDate, hasLegacyWeekly
    }

    init(
        id: String,
        title: String,
        emblem: String = "",
        exercises: [Exercise],
        assignedWeekdays: [Int],
        scheduleWeeks: Int = RoutineScheduleSpan.defaultSpan.rawValue,
        upcomingDateCount: Int = 0,
        scheduledThroughDate: String? = nil,
        hasLegacyWeekly: Bool = false
    ) {
        self.id = id
        self.title = title
        self.emblem = emblem
        self.exercises = exercises
        self.assignedWeekdays = assignedWeekdays
        self.scheduleWeeks = scheduleWeeks
        self.upcomingDateCount = upcomingDateCount
        self.scheduledThroughDate = scheduledThroughDate
        self.hasLegacyWeekly = hasLegacyWeekly
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        emblem = try c.decodeIfPresent(String.self, forKey: .emblem) ?? ""
        exercises = try c.decode([Exercise].self, forKey: .exercises)
        assignedWeekdays = try c.decode([Int].self, forKey: .assignedWeekdays)
        scheduleWeeks = try c.decodeIfPresent(Int.self, forKey: .scheduleWeeks) ?? RoutineScheduleSpan.defaultSpan.rawValue
        upcomingDateCount = try c.decodeIfPresent(Int.self, forKey: .upcomingDateCount) ?? 0
        scheduledThroughDate = try c.decodeIfPresent(String.self, forKey: .scheduledThroughDate)
        hasLegacyWeekly = try c.decodeIfPresent(Bool.self, forKey: .hasLegacyWeekly) ?? false
    }
}

struct CalendarRoutineMarker: Identifiable, Equatable {
    let id: String
    let title: String
    let emblem: String
}

struct WeekDaySlot: Identifiable, Equatable {
    var id: String { isoDate }
    let isoDate: String
    let dayOfWeek: Int
    let dayShort: String
    let dayNumber: Int
    let isToday: Bool
    let hasRoutine: Bool
    let hasLoggedSets: Bool
    var routineMarkers: [CalendarRoutineMarker] = []
}

struct MonthDaySlot: Identifiable, Equatable {
    let id: String
    let isoDate: String?
    let dayNumber: Int?
    let isToday: Bool
    let hasRoutine: Bool
    let hasLoggedSets: Bool
    var routineMarkers: [CalendarRoutineMarker] = []
}

struct DayRoutineSection: Identifiable, Equatable {
    let id: String
    let title: String
    let emblem: String
    let exercises: [RoutineExerciseItem]
    let completedExercises: Int
    let totalExercises: Int
    let totalSetsDone: Int
}

struct DayWorkout: Equatable {
    let dayOfWeek: Int
    let dayName: String
    let dayFullName: String
    let sessionDate: String
    let displayDateShort: String
    let isToday: Bool
    let scheduleSource: ScheduleSource
    let routines: [DayRoutineSection]
    let completionPct: Int
    let completedExercises: Int
    let totalExercises: Int
    let totalSetsDone: Int

    var hasRoutines: Bool { !routines.isEmpty }
    var routineId: String? { routines.first?.id }
    var routineIds: Set<String> { Set(routines.map(\.id)) }
    var title: String {
        if routines.isEmpty { return "Rest Day" }
        if routines.count == 1 { return routines[0].title }
        return routines.map(\.title).joined(separator: " + ")
    }
    var exercises: [RoutineExerciseItem] { routines.flatMap(\.exercises) }
}

struct Recipe: Identifiable, Equatable, Codable {
    let id: String
    let title: String
    let sourceURL: String
    let sourceDomain: String
    let prepTime: String
    let servings: Int
    let kcal: Int
    let proteinG: Int
    let carbsG: Int
    let fatG: Int
    var sodiumMg: Int = 0
    var sugarG: Int = 0
    var cholesterolMg: Int = 0
    let mealType: String
    let dietaryTags: [String]
    let allergens: [String]
    let ingredients: [String]
    let steps: [String]
    let imagePath: String?
    let imageSource: String
    let isSaved: Bool
    let discoveredAt: String
    let savedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, title, sourceURL, sourceDomain, prepTime, servings
        case kcal, proteinG, carbsG, fatG, sodiumMg, sugarG, cholesterolMg
        case mealType, dietaryTags, allergens, ingredients, steps
        case imagePath, imageSource, isSaved, discoveredAt, savedAt
    }

    init(
        id: String,
        title: String,
        sourceURL: String,
        sourceDomain: String,
        prepTime: String,
        servings: Int,
        kcal: Int,
        proteinG: Int,
        carbsG: Int,
        fatG: Int,
        sodiumMg: Int = 0,
        sugarG: Int = 0,
        cholesterolMg: Int = 0,
        mealType: String,
        dietaryTags: [String],
        allergens: [String],
        ingredients: [String],
        steps: [String],
        imagePath: String?,
        imageSource: String,
        isSaved: Bool,
        discoveredAt: String,
        savedAt: String?
    ) {
        self.id = id
        self.title = title
        self.sourceURL = sourceURL
        self.sourceDomain = sourceDomain
        self.prepTime = prepTime
        self.servings = servings
        self.kcal = kcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.sodiumMg = sodiumMg
        self.sugarG = sugarG
        self.cholesterolMg = cholesterolMg
        self.mealType = mealType
        self.dietaryTags = dietaryTags
        self.allergens = allergens
        self.ingredients = ingredients
        self.steps = steps
        self.imagePath = imagePath
        self.imageSource = imageSource
        self.isSaved = isSaved
        self.discoveredAt = discoveredAt
        self.savedAt = savedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        sourceURL = try c.decode(String.self, forKey: .sourceURL)
        sourceDomain = try c.decode(String.self, forKey: .sourceDomain)
        prepTime = try c.decode(String.self, forKey: .prepTime)
        servings = try c.decode(Int.self, forKey: .servings)
        kcal = try c.decode(Int.self, forKey: .kcal)
        proteinG = try c.decode(Int.self, forKey: .proteinG)
        carbsG = try c.decode(Int.self, forKey: .carbsG)
        fatG = try c.decode(Int.self, forKey: .fatG)
        sodiumMg = try c.decodeIfPresent(Int.self, forKey: .sodiumMg) ?? 0
        sugarG = try c.decodeIfPresent(Int.self, forKey: .sugarG) ?? 0
        cholesterolMg = try c.decodeIfPresent(Int.self, forKey: .cholesterolMg) ?? 0
        mealType = try c.decode(String.self, forKey: .mealType)
        dietaryTags = try c.decode([String].self, forKey: .dietaryTags)
        allergens = try c.decode([String].self, forKey: .allergens)
        ingredients = try c.decode([String].self, forKey: .ingredients)
        steps = try c.decode([String].self, forKey: .steps)
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
        imageSource = try c.decode(String.self, forKey: .imageSource)
        isSaved = try c.decode(Bool.self, forKey: .isSaved)
        discoveredAt = try c.decode(String.self, forKey: .discoveredAt)
        savedAt = try c.decodeIfPresent(String.self, forKey: .savedAt)
    }
}

// MARK: - Diet & Macros Models

enum MacroMetric: String, CaseIterable, Identifiable {
    case kcal
    case protein
    case carbs
    case fat
    case sodium
    case sugar
    case cholesterol

    var id: String { rawValue }

    var label: String {
        switch self {
        case .kcal: return "Calories"
        case .protein: return "Protein"
        case .carbs: return "Carbs"
        case .fat: return "Fat"
        case .sodium: return "Sodium"
        case .sugar: return "Sugar"
        case .cholesterol: return "Cholesterol"
        }
    }

    var unit: String {
        switch self {
        case .kcal: return "kcal"
        case .protein, .carbs, .fat, .sugar: return "g"
        case .sodium, .cholesterol: return "mg"
        }
    }

    var isUpperLimit: Bool {
        switch self {
        case .sodium, .sugar, .cholesterol: return true
        default: return false
        }
    }

    func targetValue(from targets: MacroTargets) -> Int {
        switch self {
        case .kcal: return targets.kcal
        case .protein: return targets.proteinG
        case .carbs: return targets.carbsG
        case .fat: return targets.fatG
        case .sodium: return targets.sodiumMg
        case .sugar: return targets.sugarG
        case .cholesterol: return targets.cholesterolMg
        }
    }
}

struct MacroHistoryPoint: Identifiable, Equatable {
    var id: String { date }
    let date: String
    let value: Int
}

struct MacroTargets: Codable, Equatable {
    var kcal: Int
    var proteinG: Int
    var carbsG: Int
    var fatG: Int
    var sodiumMg: Int
    var sugarG: Int
    var cholesterolMg: Int

    static let `default` = MacroTargets(
        kcal: 2200,
        proteinG: 160,
        carbsG: 220,
        fatG: 70,
        sodiumMg: 2300,
        sugarG: 50,
        cholesterolMg: 300
    )

    enum CodingKeys: String, CodingKey {
        case kcal, proteinG, carbsG, fatG, sodiumMg, sugarG, cholesterolMg
    }

    init(
        kcal: Int,
        proteinG: Int,
        carbsG: Int,
        fatG: Int,
        sodiumMg: Int = 2300,
        sugarG: Int = 50,
        cholesterolMg: Int = 300
    ) {
        self.kcal = kcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.sodiumMg = sodiumMg
        self.sugarG = sugarG
        self.cholesterolMg = cholesterolMg
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kcal = try c.decode(Int.self, forKey: .kcal)
        proteinG = try c.decode(Int.self, forKey: .proteinG)
        carbsG = try c.decode(Int.self, forKey: .carbsG)
        fatG = try c.decode(Int.self, forKey: .fatG)
        sodiumMg = try c.decodeIfPresent(Int.self, forKey: .sodiumMg) ?? 2300
        sugarG = try c.decodeIfPresent(Int.self, forKey: .sugarG) ?? 50
        cholesterolMg = try c.decodeIfPresent(Int.self, forKey: .cholesterolMg) ?? 300
    }
}

struct MacroLogEntry: Identifiable, Codable, Equatable {
    let id: Int64
    let logDate: String
    var mealSlot: String
    var name: String
    var servings: Double
    var kcal: Int
    var proteinG: Int
    var carbsG: Int
    var fatG: Int
    var sodiumMg: Int
    var sugarG: Int
    var cholesterolMg: Int
    var recipeId: String?
    var notes: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, logDate, mealSlot, name, servings
        case kcal, proteinG, carbsG, fatG, sodiumMg, sugarG, cholesterolMg
        case recipeId, notes, createdAt
    }

    init(
        id: Int64,
        logDate: String,
        mealSlot: String,
        name: String,
        servings: Double,
        kcal: Int,
        proteinG: Int,
        carbsG: Int,
        fatG: Int,
        sodiumMg: Int = 0,
        sugarG: Int = 0,
        cholesterolMg: Int = 0,
        recipeId: String? = nil,
        notes: String = "",
        createdAt: String
    ) {
        self.id = id
        self.logDate = logDate
        self.mealSlot = mealSlot
        self.name = name
        self.servings = servings
        self.kcal = kcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.sodiumMg = sodiumMg
        self.sugarG = sugarG
        self.cholesterolMg = cholesterolMg
        self.recipeId = recipeId
        self.notes = notes
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        logDate = try c.decode(String.self, forKey: .logDate)
        mealSlot = try c.decode(String.self, forKey: .mealSlot)
        name = try c.decode(String.self, forKey: .name)
        servings = try c.decode(Double.self, forKey: .servings)
        kcal = try c.decode(Int.self, forKey: .kcal)
        proteinG = try c.decode(Int.self, forKey: .proteinG)
        carbsG = try c.decode(Int.self, forKey: .carbsG)
        fatG = try c.decode(Int.self, forKey: .fatG)
        sodiumMg = try c.decodeIfPresent(Int.self, forKey: .sodiumMg) ?? 0
        sugarG = try c.decodeIfPresent(Int.self, forKey: .sugarG) ?? 0
        cholesterolMg = try c.decodeIfPresent(Int.self, forKey: .cholesterolMg) ?? 0
        recipeId = try c.decodeIfPresent(String.self, forKey: .recipeId)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        createdAt = try c.decode(String.self, forKey: .createdAt)
    }
}

struct DailyMacroTotals: Equatable {
    let kcal: Int
    let proteinG: Int
    let carbsG: Int
    let fatG: Int
    let sodiumMg: Int
    let sugarG: Int
    let cholesterolMg: Int
    let entries: [MacroLogEntry]
}

struct DailyKcalPoint: Identifiable, Equatable {
    var id: String { date }
    let date: String
    let kcal: Int
    let proteinG: Int
}

struct EstimatedMealMacros: Codable, Equatable {
    let name: String
    let mealSlot: String
    let kcal: Int
    let proteinG: Int
    let carbsG: Int
    let fatG: Int
    var sodiumMg: Int = 0
    var sugarG: Int = 0
    var cholesterolMg: Int = 0
    let notes: String
}

struct SavedMeal: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var defaultMealSlot: String
    var kcal: Int
    var proteinG: Int
    var carbsG: Int
    var fatG: Int
    var sodiumMg: Int
    var sugarG: Int
    var cholesterolMg: Int
    var notes: String
    var useCount: Int
    var lastUsedAt: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, defaultMealSlot, kcal, proteinG, carbsG, fatG
        case sodiumMg, sugarG, cholesterolMg, notes, useCount, lastUsedAt, createdAt
    }

    init(
        id: String,
        name: String,
        defaultMealSlot: String = "Lunch",
        kcal: Int,
        proteinG: Int,
        carbsG: Int,
        fatG: Int,
        sodiumMg: Int = 0,
        sugarG: Int = 0,
        cholesterolMg: Int = 0,
        notes: String = "",
        useCount: Int = 1,
        lastUsedAt: String,
        createdAt: String
    ) {
        self.id = id
        self.name = name
        self.defaultMealSlot = defaultMealSlot
        self.kcal = kcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.sodiumMg = sodiumMg
        self.sugarG = sugarG
        self.cholesterolMg = cholesterolMg
        self.notes = notes
        self.useCount = max(1, useCount)
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? "meal_\(UUID().uuidString.prefix(8).lowercased())"
        name = try c.decode(String.self, forKey: .name)
        defaultMealSlot = try c.decodeIfPresent(String.self, forKey: .defaultMealSlot) ?? "Lunch"
        kcal = try c.decodeIfPresent(Int.self, forKey: .kcal) ?? 0
        proteinG = try c.decodeIfPresent(Int.self, forKey: .proteinG) ?? 0
        carbsG = try c.decodeIfPresent(Int.self, forKey: .carbsG) ?? 0
        fatG = try c.decodeIfPresent(Int.self, forKey: .fatG) ?? 0
        sodiumMg = try c.decodeIfPresent(Int.self, forKey: .sodiumMg) ?? 0
        sugarG = try c.decodeIfPresent(Int.self, forKey: .sugarG) ?? 0
        cholesterolMg = try c.decodeIfPresent(Int.self, forKey: .cholesterolMg) ?? 0
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        useCount = max(1, try c.decodeIfPresent(Int.self, forKey: .useCount) ?? 1)
        let now = DatabaseManager.nowISO()
        lastUsedAt = try c.decodeIfPresent(String.self, forKey: .lastUsedAt) ?? now
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? lastUsedAt
    }
}

// MARK: - Cycle / Menstrual Models

enum CyclePhase: String, CaseIterable, Equatable {
    case none
    case menstrual
    case predictedPeriod
    case follicular
    case ovulatory
    case luteal

    var label: String {
        switch self {
        case .none: return "Unassigned"
        case .menstrual: return "Period"
        case .predictedPeriod: return "Predicted"
        case .follicular: return "Follicular"
        case .ovulatory: return "Ovulatory"
        case .luteal: return "Luteal"
        }
    }
}

struct CycleRegularityInsight: Equatable {
    let isIrregular: Bool
    let headline: String
    let observations: [String]
    let guidance: String
}

enum CycleFlowLevel: String, CaseIterable, Identifiable, Codable {
    case none
    case spotting
    case light
    case medium
    case heavy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .spotting: return "Spotting"
        case .light: return "Light"
        case .medium: return "Medium"
        case .heavy: return "Heavy"
        }
    }

    var intensity: Int {
        switch self {
        case .none: return 0
        case .spotting: return 1
        case .light: return 2
        case .medium: return 3
        case .heavy: return 4
        }
    }
}

struct CycleLogEntry: Identifiable, Codable, Equatable {
    var id: String { logDate }
    let logDate: String
    var flow: CycleFlowLevel
    var symptoms: [String]
    var mood: String
    var energy: Int
    var bbt: Double?
    var notes: String
    let updatedAt: String
}

struct CyclePeriodSpan: Identifiable, Equatable {
    var id: String { startDate }
    let startDate: String
    let endDate: String
    let durationDays: Int
    let cycleLengthDays: Int?
}

struct CycleSummary: Equatable {
    let currentCycleDay: Int?
    let estimatedPhase: String
    let avgCycleLength: Int
    let avgPeriodLength: Int
    let nextPredictedStart: String?
    let daysUntilNextPeriod: Int?
    let predictedPeriodDates: Set<String>
    let periods: [CyclePeriodSpan]
    var dayPhases: [String: CyclePhase] = [:]
    var regularityInsight: CycleRegularityInsight? = nil
}

// MARK: - Verified Clinical & Dietary Sources

struct HealthReferenceSource: Identifiable, Equatable {
    let id: String
    let category: String
    let title: String
    let publisher: String
    let summary: String
    let urlString: String

    static let all: [HealthReferenceSource] = [
        HealthReferenceSource(
            id: "fda_dv",
            category: "Nutrition Reference",
            title: "Daily Value on the Nutrition and Supplement Facts Labels",
            publisher: "U.S. Food & Drug Administration (FDA.gov)",
            summary: "Adult Daily Value limits used for default nutrition targets: Sodium 2,300 mg, Added Sugars 50 g, and Cholesterol 300 mg.",
            urlString: "https://www.fda.gov/food/nutrition-facts-label/daily-value-nutrition-and-supplement-facts-labels"
        ),
        HealthReferenceSource(
            id: "usda_dga",
            category: "Nutrition Reference",
            title: "Dietary Guidelines for Americans",
            publisher: "USDA & U.S. Department of Health and Human Services",
            summary: "Federal guidance for daily calorie balance, macronutrients, added sugars, and sodium moderation.",
            urlString: "https://www.dietaryguidelines.gov/"
        ),
        HealthReferenceSource(
            id: "owh_cycle",
            category: "Cycle Reference",
            title: "Your Menstrual Cycle",
            publisher: "U.S. Office on Women's Health (WomensHealth.gov)",
            summary: "Overview of menstrual cycle phases, typical cycle durations, and signs that warrant consulting a doctor.",
            urlString: "https://www.womenshealth.gov/menstrual-cycle/your-menstrual-cycle"
        ),
        HealthReferenceSource(
            id: "nichd_pcos",
            category: "PCOS & Irregularity",
            title: "Polycystic Ovary Syndrome (PCOS)",
            publisher: "NIH National Institute of Child Health and Human Development",
            summary: "Federal health overview of PCOS symptoms, irregular ovulation patterns, and medical evaluation.",
            urlString: "https://www.nichd.nih.gov/health/topics/pcos"
        ),
        HealthReferenceSource(
            id: "figo_2018",
            category: "Peer-Reviewed Journal",
            title: "The two FIGO systems for normal and abnormal uterine bleeding symptoms (2018 revisions)",
            publisher: "Munro MG et al. · Int J Gynaecol Obstet (PubMed)",
            summary: "Standard adult menstrual cycle parameters: 24–38 day frequency, <= 7–9 day cycle variation, and <= 8 day bleeding duration.",
            urlString: "https://pubmed.ncbi.nlm.nih.gov/30198563/"
        ),
        HealthReferenceSource(
            id: "pcos_2023",
            category: "Clinical Guideline",
            title: "2023 International Evidence-based Guideline for the Assessment and Management of PCOS",
            publisher: "Teede HJ et al. · Eur J Endocrinol (PubMed)",
            summary: "Defines irregular adult cycles (<21 or >35 days, or >90 days for any single cycle) used as non-diagnostic pattern alerts.",
            urlString: "https://pubmed.ncbi.nlm.nih.gov/37580861/"
        ),
    ]
}

// MARK: - Multi-Provider AI Models

enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case gemini
    case openai
    case anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini: return "Gemini"
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    var shortLabel: String {
        switch self {
        case .gemini: return "GEMINI"
        case .openai: return "CHATGPT"
        case .anthropic: return "CLAUDE"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .gemini: return "AIza..."
        case .openai: return "sk-..."
        case .anthropic: return "sk-ant-..."
        }
    }

    var supportsSignInNow: Bool {
        self == .openai
    }

    var signInComingSoon: Bool {
        self == .gemini
    }
}

enum AIAuthMode: String, CaseIterable, Identifiable, Codable {
    case apiKey
    case signIn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .apiKey: return "API Key"
        case .signIn: return "Sign In"
        }
    }
}

struct AIPingResult: Equatable {
    let provider: AIProvider
    let authMode: AIAuthMode
    let success: Bool
    let latencyMs: Int
    let modelLabel: String
    let message: String
    let timestampISO: String
}

struct AIProviderConfigState: Equatable {
    let provider: AIProvider
    let authMode: AIAuthMode
    let hasCredential: Bool
    let maskedCredential: String
    let accountLabel: String
    let isVerified: Bool
    let lastPingLatencyMs: Int?
    let lastVerifiedAt: String?
}

// MARK: - Export, Sharing & Snapshot Models

enum ExportDomain: String, CaseIterable, Identifiable {
    case all
    case workouts
    case routines
    case customExercises
    case bodyWeight
    case macros
    case savedMeals
    case recipes
    case cycle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All Data"
        case .workouts: return "Workouts & Sets"
        case .routines: return "Routines"
        case .customExercises: return "Custom Exercises"
        case .bodyWeight: return "Body Weight"
        case .macros: return "Diet & Macros"
        case .savedMeals: return "Saved Meals"
        case .recipes: return "Recipes"
        case .cycle: return "Cycle Log"
        }
    }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case json
    case markdown
    case text

    var id: String { rawValue }

    var label: String {
        switch self {
        case .json: return "JSON"
        case .markdown: return "Markdown (.md)"
        case .text: return "Text (.txt)"
        }
    }

    var shortLabel: String {
        switch self {
        case .json: return "JSON"
        case .markdown: return ".MD"
        case .text: return ".TXT"
        }
    }

    var fileExtension: String {
        switch self {
        case .json: return "json"
        case .markdown: return "md"
        case .text: return "txt"
        }
    }
}

struct ExportWorkoutSet: Codable, Equatable {
    let id: Int64
    let sessionDate: String
    let exerciseId: String
    let exerciseName: String
    let setNumber: Int
    let reps: Int
    let weight: Double
    let completed: Bool
    let createdAt: String
}

struct ExportDateScheduleEntry: Codable, Equatable {
    let sessionDate: String
    let routineId: String?
}

struct VeldaFullSnapshot: Codable, Equatable {
    let schemaVersion: Int
    let appName: String
    let exportedAt: String
    let weightUnit: String
    let cycleTrackingEnabled: Bool
    let customExercises: [Exercise]
    let routines: [RoutineSummary]
    let dateSchedules: [ExportDateScheduleEntry]
    let workoutSets: [ExportWorkoutSet]
    let weightLogs: [WeightLogEntry]
    let macroTargets: MacroTargets
    let macroLogs: [MacroLogEntry]
    let savedMeals: [SavedMeal]
    let recipes: [Recipe]
    let cycleLogs: [CycleLogEntry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion, appName, exportedAt, weightUnit, cycleTrackingEnabled
        case customExercises, routines, dateSchedules, workoutSets, weightLogs
        case macroTargets, macroLogs, savedMeals, recipes, cycleLogs
    }

    init(
        schemaVersion: Int,
        appName: String,
        exportedAt: String,
        weightUnit: String,
        cycleTrackingEnabled: Bool,
        customExercises: [Exercise],
        routines: [RoutineSummary],
        dateSchedules: [ExportDateScheduleEntry],
        workoutSets: [ExportWorkoutSet],
        weightLogs: [WeightLogEntry],
        macroTargets: MacroTargets,
        macroLogs: [MacroLogEntry],
        savedMeals: [SavedMeal] = [],
        recipes: [Recipe],
        cycleLogs: [CycleLogEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.appName = appName
        self.exportedAt = exportedAt
        self.weightUnit = weightUnit
        self.cycleTrackingEnabled = cycleTrackingEnabled
        self.customExercises = customExercises
        self.routines = routines
        self.dateSchedules = dateSchedules
        self.workoutSets = workoutSets
        self.weightLogs = weightLogs
        self.macroTargets = macroTargets
        self.macroLogs = macroLogs
        self.savedMeals = savedMeals
        self.recipes = recipes
        self.cycleLogs = cycleLogs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        appName = try c.decode(String.self, forKey: .appName)
        exportedAt = try c.decode(String.self, forKey: .exportedAt)
        weightUnit = try c.decode(String.self, forKey: .weightUnit)
        cycleTrackingEnabled = try c.decode(Bool.self, forKey: .cycleTrackingEnabled)
        customExercises = try c.decode([Exercise].self, forKey: .customExercises)
        routines = try c.decode([RoutineSummary].self, forKey: .routines)
        dateSchedules = try c.decode([ExportDateScheduleEntry].self, forKey: .dateSchedules)
        workoutSets = try c.decode([ExportWorkoutSet].self, forKey: .workoutSets)
        weightLogs = try c.decode([WeightLogEntry].self, forKey: .weightLogs)
        macroTargets = try c.decode(MacroTargets.self, forKey: .macroTargets)
        macroLogs = try c.decode([MacroLogEntry].self, forKey: .macroLogs)
        savedMeals = try c.decodeIfPresent([SavedMeal].self, forKey: .savedMeals) ?? []
        recipes = try c.decode([Recipe].self, forKey: .recipes)
        cycleLogs = try c.decode([CycleLogEntry].self, forKey: .cycleLogs)
    }
}

struct VeldaSavedMealsExportPayload: Codable {
    let schemaVersion: Int
    let domain: String
    let exportedAt: String
    let savedMeals: [SavedMeal]

    enum CodingKeys: String, CodingKey {
        case schemaVersion, domain, exportedAt, savedMeals
    }

    init(schemaVersion: Int = 1, domain: String = "saved_meals", exportedAt: String, savedMeals: [SavedMeal]) {
        self.schemaVersion = schemaVersion
        self.domain = domain
        self.exportedAt = exportedAt
        self.savedMeals = savedMeals
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? "saved_meals"
        exportedAt = try c.decodeIfPresent(String.self, forKey: .exportedAt) ?? ""
        savedMeals = try c.decode([SavedMeal].self, forKey: .savedMeals)
    }
}

struct VeldaMacrosExportPayload: Codable {
    let domain: String
    let exportedAt: String
    let macroTargets: MacroTargets?
    let macroLogs: [MacroLogEntry]
    let savedMeals: [SavedMeal]

    enum CodingKeys: String, CodingKey {
        case domain, exportedAt, macroTargets, macroLogs, savedMeals
    }

    init(
        domain: String = "macros",
        exportedAt: String,
        macroTargets: MacroTargets?,
        macroLogs: [MacroLogEntry],
        savedMeals: [SavedMeal] = []
    ) {
        self.domain = domain
        self.exportedAt = exportedAt
        self.macroTargets = macroTargets
        self.macroLogs = macroLogs
        self.savedMeals = savedMeals
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? "macros"
        exportedAt = try c.decodeIfPresent(String.self, forKey: .exportedAt) ?? ""
        macroTargets = try c.decodeIfPresent(MacroTargets.self, forKey: .macroTargets)
        macroLogs = try c.decode([MacroLogEntry].self, forKey: .macroLogs)
        savedMeals = try c.decodeIfPresent([SavedMeal].self, forKey: .savedMeals) ?? []
    }
}

struct VeldaRecipeSharePayload: Codable {
    let schemaVersion: Int
    let kind: String
    let exportedAt: String
    let recipe: Recipe
}

struct VeldaRoutineSharePayload: Codable {
    let schemaVersion: Int
    let kind: String
    let exportedAt: String
    let routine: RoutineSummary
}

// MARK: - Storage & Utility

struct StorageMetrics: Equatable {
    let dbBytes: Int64
    let savedMediaBytes: Int64
    let savedMediaFiles: Int
    let cacheMediaBytes: Int64
    let cacheMediaFiles: Int
    let appDataBytes: Int64
    let bundleVideoCount: Int
    let bundleVideoBytes: Int64
    let savedRecipeCount: Int
    let cachedRecipeCount: Int
    let customExerciseCount: Int
    let totalSetCount: Int
    let macroLogCount: Int
    var savedMealCount: Int = 0
    let cycleLogCount: Int
    let hasAPIKey: Bool
    let maskedAPIKey: String
    let weightUnit: String
    let cacheTTLDays: Int
    let cacheMaxMB: Int
}

struct SweepResult: Equatable {
    let reclaimedBytes: Int64
    let deletedRecipes: Int
    let deletedOrphanFiles: Int
}

struct WeightLogEntry: Identifiable, Equatable, Codable {
    let id: Int64
    let logDate: String
    let displayDate: String
    let weight: Double
    let rawWeight: Double
    let rawUnit: String
    let note: String
    let createdAt: String
}

struct GeneratedRoutinePlan: Equatable {
    let title: String
    let summary: String
    let exercises: [Exercise]
}

enum BundleVideoResolver {
    static func url(for filename: String?) -> URL? {
        guard let filename = filename, !filename.isEmpty else { return nil }
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension.isEmpty ? "mp4" : (filename as NSString).pathExtension
        if let sub = Bundle.main.url(forResource: stem, withExtension: ext, subdirectory: "MoveKitVideos") {
            return sub
        }
        return Bundle.main.url(forResource: stem, withExtension: ext)
    }

    static func bundleVideoStats() -> (count: Int, bytes: Int64) {
        let urlsSub = Bundle.main.urls(forResourcesWithExtension: "mp4", subdirectory: "MoveKitVideos") ?? []
        let urlsRoot = Bundle.main.urls(forResourcesWithExtension: "mp4", subdirectory: nil) ?? []
        var unique = Set<URL>()
        for u in urlsSub + urlsRoot {
            unique.insert(u)
        }
        var total: Int64 = 0
        for u in unique {
            if let vals = try? u.resourceValues(forKeys: [.fileSizeKey]), let sz = vals.fileSize {
                total += Int64(sz)
            }
        }
        return (unique.count, total)
    }
}
