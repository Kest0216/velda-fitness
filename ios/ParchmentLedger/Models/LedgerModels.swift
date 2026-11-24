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

struct RoutineSummary: Identifiable, Equatable, Codable {
    let id: String
    let title: String
    let exercises: [Exercise]
    let assignedWeekdays: [Int] // 0=Mon .. 6=Sun
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
}

struct MonthDaySlot: Identifiable, Equatable {
    let id: String
    let isoDate: String?
    let dayNumber: Int?
    let isToday: Bool
    let hasRoutine: Bool
    let hasLoggedSets: Bool
}

struct DayWorkout: Equatable {
    let dayOfWeek: Int
    let dayName: String
    let dayFullName: String
    let sessionDate: String
    let displayDateShort: String
    let isToday: Bool
    let routineId: String?
    let scheduleSource: ScheduleSource
    let title: String
    let exercises: [RoutineExerciseItem]
    let completionPct: Int
    let completedExercises: Int
    let totalExercises: Int
    let totalSetsDone: Int
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
    let recipes: [Recipe]
    let cycleLogs: [CycleLogEntry]
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
