import Foundation

enum ExportImportResult {
    case fullSnapshot(VeldaFullSnapshot)
    case singleRoutine(RoutineSummary)
    case singleRecipe(Recipe)
}

enum ExportImportError: LocalizedError {
    case unrecognizedFormat

    var errorDescription: String? {
        switch self {
        case .unrecognizedFormat:
            return "File is not a recognized Velda Fitness JSON backup, routine, or recipe."
        }
    }
}

final class ExportShareService: @unchecked Sendable {
    static let shared = ExportShareService()

    private let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    private init() {}

    // MARK: - Share Individual Recipe / Routine

    func createRecipeShareFile(_ recipe: Recipe, format: ExportFormat) throws -> URL {
        let slug = slugify(recipe.title)
        let filename = "velda-recipe-\(slug).\(format.fileExtension)"
        let content: String

        switch format {
        case .json:
            let payload = VeldaRecipeSharePayload(
                schemaVersion: 1,
                kind: "velda_recipe",
                exportedAt: DatabaseManager.nowISO(),
                recipe: recipe
            )
            content = try encodePrettyJSON(payload)

        case .markdown:
            var lines: [String] = [
                "# \(recipe.title)",
                "",
                "- **Meal:** \(recipe.mealType) · **Prep:** \(recipe.prepTime) · **Servings:** \(recipe.servings)",
                "- **Macros / Serving:** \(recipe.kcal) kcal | \(recipe.proteinG)g P | \(recipe.carbsG)g C | \(recipe.fatG)g F",
            ]
            if !recipe.dietaryTags.isEmpty {
                lines.append("- **Tags:** \(recipe.dietaryTags.joined(separator: ", "))")
            }
            if !recipe.allergens.isEmpty {
                lines.append("- **Allergens:** \(recipe.allergens.joined(separator: ", "))")
            }
            if !recipe.sourceURL.isEmpty {
                lines.append("- **Source:** \(recipe.sourceURL)")
            }
            lines.append("")
            lines.append("## Ingredients")
            for ing in recipe.ingredients {
                lines.append("- \(ing)")
            }
            lines.append("")
            lines.append("## Preparation")
            for (idx, st) in recipe.steps.enumerated() {
                lines.append("\(idx + 1). \(st)")
            }
            lines.append("")
            lines.append("_Exported from Velda Fitness_")
            content = lines.joined(separator: "\n")

        case .text:
            var lines: [String] = [
                recipe.title.uppercased(),
                String(repeating: "-", count: min(48, max(12, recipe.title.count))),
                "Meal: \(recipe.mealType) | Prep: \(recipe.prepTime) | Servings: \(recipe.servings)",
                "Macros/Serving: \(recipe.kcal) kcal · \(recipe.proteinG)g P · \(recipe.carbsG)g C · \(recipe.fatG)g F",
            ]
            if !recipe.allergens.isEmpty {
                lines.append("Allergens: \(recipe.allergens.joined(separator: ", "))")
            }
            if !recipe.sourceURL.isEmpty {
                lines.append("Source: \(recipe.sourceURL)")
            }
            lines.append("")
            lines.append("INGREDIENTS:")
            for ing in recipe.ingredients {
                lines.append("  * \(ing)")
            }
            lines.append("")
            lines.append("PREPARATION:")
            for (idx, st) in recipe.steps.enumerated() {
                lines.append("  \(idx + 1). \(st)")
            }
            content = lines.joined(separator: "\n")
        }

        return try writeTempFile(filename: filename, content: content)
    }

    func createRoutineShareFile(_ routine: RoutineSummary, format: ExportFormat) throws -> URL {
        let slug = slugify(routine.title)
        let filename = "velda-routine-\(slug).\(format.fileExtension)"
        let daysLabel = routine.assignedWeekdays
            .sorted()
            .compactMap { (0..<weekdayNames.count).contains($0) ? weekdayNames[$0] : nil }
            .joined(separator: ", ")

        let content: String
        switch format {
        case .json:
            let payload = VeldaRoutineSharePayload(
                schemaVersion: 1,
                kind: "velda_routine",
                exportedAt: DatabaseManager.nowISO(),
                routine: routine
            )
            content = try encodePrettyJSON(payload)

        case .markdown:
            var lines: [String] = [
                "# \(routine.title)",
                "",
                "- **Movements:** \(routine.exercises.count)",
                "- **Weekly Days:** \(daysLabel.isEmpty ? "Unassigned" : daysLabel)",
                "",
                "## Exercises",
            ]
            for (idx, ex) in routine.exercises.enumerated() {
                let meta = [ex.muscleHint, ex.trackingType, ex.equipment].filter { !$0.isEmpty }.joined(separator: " · ")
                lines.append("\(idx + 1). **\(ex.name)** (\(meta))")
                if !ex.notes.isEmpty {
                    lines.append("   - _Cues:_ \(ex.notes)")
                }
            }
            lines.append("")
            lines.append("_Exported from Velda Fitness_")
            content = lines.joined(separator: "\n")

        case .text:
            var lines: [String] = [
                routine.title.uppercased(),
                String(repeating: "-", count: min(48, max(12, routine.title.count))),
                "Movements: \(routine.exercises.count) | Schedule: \(daysLabel.isEmpty ? "Unassigned" : daysLabel)",
                "",
            ]
            for (idx, ex) in routine.exercises.enumerated() {
                lines.append("  \(idx + 1). \(ex.name) [\(ex.muscleHint) · \(ex.trackingType)]")
                if !ex.notes.isEmpty {
                    lines.append("     Cues: \(ex.notes)")
                }
            }
            content = lines.joined(separator: "\n")
        }

        return try writeTempFile(filename: filename, content: content)
    }

    // MARK: - Domain / Full Ledger Export (No Secrets Ever Included)

    func createDomainExportFile(domain: ExportDomain, format: ExportFormat) throws -> URL {
        let snapshot = DatabaseManager.shared.exportAllDomainSnapshot()
        let dateStamp = DatabaseManager.isoDate()
        let filename = "velda-\(domain.rawValue)-\(dateStamp).\(format.fileExtension)"
        let content: String

        switch format {
        case .json:
            content = try encodeDomainJSON(domain: domain, snapshot: snapshot)
        case .markdown:
            content = renderDomainMarkdown(domain: domain, snapshot: snapshot)
        case .text:
            content = renderDomainText(domain: domain, snapshot: snapshot)
        }

        return try writeTempFile(filename: filename, content: content)
    }

    private func encodeDomainJSON(domain: ExportDomain, snapshot: VeldaFullSnapshot) throws -> String {
        switch domain {
        case .all:
            return try encodePrettyJSON(snapshot)
        case .workouts:
            struct Box: Codable { let domain: String; let exportedAt: String; let weightUnit: String; let workoutSets: [ExportWorkoutSet] }
            return try encodePrettyJSON(Box(domain: "workouts", exportedAt: snapshot.exportedAt, weightUnit: snapshot.weightUnit, workoutSets: snapshot.workoutSets))
        case .routines:
            struct Box: Codable { let domain: String; let exportedAt: String; let routines: [RoutineSummary]; let dateSchedules: [ExportDateScheduleEntry] }
            return try encodePrettyJSON(Box(domain: "routines", exportedAt: snapshot.exportedAt, routines: snapshot.routines, dateSchedules: snapshot.dateSchedules))
        case .customExercises:
            struct Box: Codable { let domain: String; let exportedAt: String; let customExercises: [Exercise] }
            return try encodePrettyJSON(Box(domain: "custom_exercises", exportedAt: snapshot.exportedAt, customExercises: snapshot.customExercises))
        case .bodyWeight:
            struct Box: Codable { let domain: String; let exportedAt: String; let weightUnit: String; let weightLogs: [WeightLogEntry] }
            return try encodePrettyJSON(Box(domain: "body_weight", exportedAt: snapshot.exportedAt, weightUnit: snapshot.weightUnit, weightLogs: snapshot.weightLogs))
        case .macros:
            struct Box: Codable { let domain: String; let exportedAt: String; let macroTargets: MacroTargets; let macroLogs: [MacroLogEntry] }
            return try encodePrettyJSON(Box(domain: "macros", exportedAt: snapshot.exportedAt, macroTargets: snapshot.macroTargets, macroLogs: snapshot.macroLogs))
        case .recipes:
            struct Box: Codable { let domain: String; let exportedAt: String; let recipes: [Recipe] }
            return try encodePrettyJSON(Box(domain: "recipes", exportedAt: snapshot.exportedAt, recipes: snapshot.recipes))
        case .cycle:
            struct Box: Codable { let domain: String; let exportedAt: String; let cycleLogs: [CycleLogEntry] }
            return try encodePrettyJSON(Box(domain: "cycle", exportedAt: snapshot.exportedAt, cycleLogs: snapshot.cycleLogs))
        }
    }

    private func renderDomainMarkdown(domain: ExportDomain, snapshot: VeldaFullSnapshot) -> String {
        var lines: [String] = [
            "# Velda Fitness — \(domain.label) Export",
            "_Exported \(snapshot.exportedAt) · Unit: \(snapshot.weightUnit.uppercased())_",
            "",
        ]

        if domain == .all || domain == .routines {
            lines.append("## Routines (\(snapshot.routines.count))")
            for rt in snapshot.routines {
                let days = rt.assignedWeekdays.compactMap { (0..<7).contains($0) ? weekdayNames[$0] : nil }.joined(separator: ", ")
                lines.append("### \(rt.title)\(days.isEmpty ? "" : " (\(days))")")
                for ex in rt.exercises {
                    lines.append("- \(ex.name) [\(ex.muscleHint)]")
                }
                lines.append("")
            }
        }

        if domain == .all || domain == .customExercises {
            lines.append("## Custom Exercises (\(snapshot.customExercises.count))")
            for ex in snapshot.customExercises {
                lines.append("- **\(ex.name)** · \(ex.muscleHint) · \(ex.trackingType)\(ex.equipment.isEmpty ? "" : " · \(ex.equipment)")")
            }
            lines.append("")
        }

        if domain == .all || domain == .workouts {
            lines.append("## Workout Sets (\(snapshot.workoutSets.count))")
            for s in snapshot.workoutSets.prefix(400) {
                lines.append("- \(s.sessionDate) · \(s.exerciseName) · Set \(s.setNumber): \(s.reps) × \(formatNum(s.weight)) \(snapshot.weightUnit) \(s.completed ? "✓" : "○")")
            }
            lines.append("")
        }

        if domain == .all || domain == .bodyWeight {
            lines.append("## Body Weight (\(snapshot.weightLogs.count))")
            for w in snapshot.weightLogs {
                lines.append("- \(w.logDate): \(formatNum(w.weight)) \(snapshot.weightUnit)\(w.note.isEmpty ? "" : " — \(w.note)")")
            }
            lines.append("")
        }

        if domain == .all || domain == .macros {
            lines.append("## Diet & Macros (\(snapshot.macroLogs.count) entries)")
            lines.append("Daily Targets: \(snapshot.macroTargets.kcal) kcal | \(snapshot.macroTargets.proteinG)g P | \(snapshot.macroTargets.carbsG)g C | \(snapshot.macroTargets.fatG)g F | \(snapshot.macroTargets.sodiumMg)mg Na | \(snapshot.macroTargets.sugarG)g Sugar | \(snapshot.macroTargets.cholesterolMg)mg Chol")
            lines.append("")
            for m in snapshot.macroLogs {
                lines.append("- \(m.logDate) [\(m.mealSlot)] **\(m.name)**: \(m.kcal) kcal (\(m.proteinG)g P / \(m.carbsG)g C / \(m.fatG)g F / \(m.sodiumMg)mg Na / \(m.sugarG)g Sugar / \(m.cholesterolMg)mg Chol)")
            }
            lines.append("")
        }

        if domain == .all || domain == .recipes {
            let saved = snapshot.recipes.filter(\.isSaved)
            lines.append("## Saved Recipes (\(saved.count))")
            for r in saved {
                lines.append("### \(r.title)")
                lines.append("- \(r.mealType) · \(r.prepTime) · \(r.kcal) kcal (\(r.proteinG)g P / \(r.carbsG)g C / \(r.fatG)g F)")
                if !r.sourceURL.isEmpty { lines.append("- Source: \(r.sourceURL)") }
                lines.append("")
            }
        }

        if domain == .all || domain == .cycle {
            lines.append("## Cycle Log (\(snapshot.cycleLogs.count))")
            for c in snapshot.cycleLogs {
                let syms = c.symptoms.isEmpty ? "" : " · Symptoms: \(c.symptoms.joined(separator: ", "))"
                let bbtStr = c.bbt.map { String(format: " · BBT %.1f°", $0) } ?? ""
                lines.append("- \(c.logDate): Flow \(c.flow.label) · Energy \(c.energy)/5\(c.mood.isEmpty ? "" : " · Mood: \(c.mood)")\(bbtStr)\(syms)\(c.notes.isEmpty ? "" : " — \(c.notes)")")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func renderDomainText(domain: ExportDomain, snapshot: VeldaFullSnapshot) -> String {
        // Clean plain-text rendering without markdown punctuation
        renderDomainMarkdown(domain: domain, snapshot: snapshot)
            .replacingOccurrences(of: "### ", with: "")
            .replacingOccurrences(of: "## ", with: "")
            .replacingOccurrences(of: "# ", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    // MARK: - JSON Import Parser

    func parseImportedJSON(from url: URL) throws -> ExportImportResult {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()

        if let full = try? decoder.decode(VeldaFullSnapshot.self, from: data) {
            return .fullSnapshot(full)
        }
        if let routineWrap = try? decoder.decode(VeldaRoutineSharePayload.self, from: data) {
            return .singleRoutine(routineWrap.routine)
        }
        if let recipeWrap = try? decoder.decode(VeldaRecipeSharePayload.self, from: data) {
            return .singleRecipe(recipeWrap.recipe)
        }
        if let bareRecipe = try? decoder.decode(Recipe.self, from: data) {
            return .singleRecipe(bareRecipe)
        }
        if let bareRoutine = try? decoder.decode(RoutineSummary.self, from: data) {
            return .singleRoutine(bareRoutine)
        }
        throw ExportImportError.unrecognizedFormat
    }

    // MARK: - Helpers

    private func encodePrettyJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func writeTempFile(filename: String, content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("VeldaExports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(filename)
        try content.write(to: dest, atomically: true, encoding: .utf8)
        return dest
    }

    private func slugify(_ raw: String) -> String {
        let lower = raw.lowercased()
        let parts = lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let joined = parts.prefix(5).joined(separator: "-")
        return joined.isEmpty ? "item" : joined
    }

    private func formatNum(_ d: Double) -> String {
        d.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(d))" : String(format: "%.1f", d)
    }
}
