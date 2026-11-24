// MARK: - Bring-Your-Own-AI Provider Adapter
//
// Stateless client routing optional AI tasks (web recipe discovery, recipe text/URL import, meal
// macro estimation, workout routine assembly, and dish image generation) directly to the user's
// chosen provider: Gemini (`generativelanguage.googleapis.com`), OpenAI (API key or ChatGPT OAuth),
// or Anthropic (text-only; image generation explicitly excluded).

import Foundation

enum AIProviderError: LocalizedError {
    case missingCredential(AIProvider)
    case emptyPrompt
    case emptyCatalog
    case invalidResponse(String)
    case apiError(String)
    case noVerifiedRecipes
    case noMatchingMovements
    case imageGenerationUnsupported(AIProvider)

    var errorDescription: String? {
        switch self {
        case .missingCredential(let p):
            return "Add your \(p.displayName) credential in Vault to use AI features."
        case .emptyPrompt:
            return "Describe what you want first."
        case .emptyCatalog:
            return "Exercise catalog could not be loaded."
        case .invalidResponse(let msg), .apiError(let msg):
            return msg
        case .noVerifiedRecipes:
            return "Found candidate links, but none returned an active recipe page. Try a broader query."
        case .noMatchingMovements:
            return "No matching catalog movements were selected. Try describing target muscles or equipment."
        case .imageGenerationUnsupported:
            return "Anthropic (Claude) does not support image generation. Switch your provider to OpenAI or Gemini in Vault, or add a photo using Camera or Photo Library."
        }
    }
}

private struct AIRecipesResponse: Decodable {
    let recipes: [AIRecipeCandidate]
}

private struct AIRecipeCandidate: Decodable {
    let title: String
    let source_url: String
    let prep_time: String?
    let servings: Int?
    let kcal: Int?
    let protein_g: Int?
    let carbs_g: Int?
    let fat_g: Int?
    let sodium_mg: Int?
    let sugar_g: Int?
    let cholesterol_mg: Int?
    let meal_type: String?
    let dietary_tags: [String]?
    let allergens: [String]?
    let ingredients: [String]?
    let steps: [String]?
}

private struct AIRoutinePayload: Decodable {
    let title: String
    let summary: String?
    let exercise_ids: [String]
}

private struct AIMacroEstimatePayload: Decodable {
    let name: String
    let meal_slot: String?
    let kcal: Int?
    let protein_g: Int?
    let carbs_g: Int?
    let fat_g: Int?
    let sodium_mg: Int?
    let sugar_g: Int?
    let cholesterol_mg: Int?
    let notes: String?
}

private struct CompactCatalogItem: Encodable {
    let id: String
    let name: String
    let muscle: String
}

final class AIProviderService: @unchecked Sendable {
    static let shared = AIProviderService()

    private let geminiEndpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
    private let geminiRevision = "2026-05-20"
    private let openAIEndpoint = URL(string: "https://api.openai.com/v1/responses")!
    private let anthropicEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let anthropicVersion = "2023-06-01"
    private let browserUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 110
        cfg.timeoutIntervalForResource = 150
        return URLSession(configuration: cfg)
    }()

    private init() {}

    // MARK: - Active Provider Resolution

    func activeProvider() -> AIProvider {
        let raw = DatabaseManager.shared.getSetting("active_ai_provider", default: AIProvider.gemini.rawValue)
        return AIProvider(rawValue: raw) ?? .gemini
    }

    func resolveToken(for provider: AIProvider, overrideKey: String? = nil) async throws -> (mode: AIAuthMode, token: String) {
        if let override = overrideKey?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return (.apiKey, override)
        }
        let mode = KeychainStore.shared.authMode(for: provider)
        if provider == .openai && mode == .signIn {
            let token = try await OpenAIOAuthService.shared.validAccessToken()
            return (.signIn, token)
        }
        let stored = KeychainStore.shared.get(forKey: KeychainStore.apiKeyIdentifier(for: provider))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !stored.isEmpty else {
            throw AIProviderError.missingCredential(provider)
        }
        return (.apiKey, stored)
    }

    // MARK: - Live Ping Test

    func testPing(provider: AIProvider, authMode: AIAuthMode, overrideKey: String? = nil) async -> AIPingResult {
        let start = Date()
        do {
            let token: String
            if let override = overrideKey?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty, authMode == .apiKey {
                token = override
            } else if provider == .openai && authMode == .signIn {
                token = try await OpenAIOAuthService.shared.validAccessToken()
            } else {
                let stored = KeychainStore.shared.get(forKey: KeychainStore.apiKeyIdentifier(for: provider))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !stored.isEmpty else {
                    throw AIProviderError.missingCredential(provider)
                }
                token = stored
            }

            let modelLabel: String
            switch provider {
            case .gemini:
                modelLabel = "gemini-4-hydrogen"
                let payload: [String: Any] = [
                    "model": modelLabel,
                    "input": "Reply with OK.",
                    "generation_config": ["thinking_level": "low"],
                ]
                _ = try await postGemini(apiKey: token, payload: payload)
            case .openai:
                modelLabel = "gpt-6-luna"
                let payload: [String: Any] = [
                    "model": modelLabel,
                    "input": "Reply with OK.",
                    "max_output_tokens": 16,
                ]
                _ = try await postOpenAI(bearer: token, payload: payload)
            case .anthropic:
                modelLabel = "claude-haiku-5-5"
                let payload: [String: Any] = [
                    "model": modelLabel,
                    "max_tokens": 16,
                    "messages": [["role": "user", "content": "Reply with OK."]],
                ]
                _ = try await postAnthropic(apiKey: token, payload: payload)
            }

            let ms = max(1, Int(Date().timeIntervalSince(start) * 1000.0))
            return AIPingResult(
                provider: provider,
                authMode: authMode,
                success: true,
                latencyMs: ms,
                modelLabel: modelLabel,
                message: "Operational · \(ms) ms (\(modelLabel))",
                timestampISO: DatabaseManager.nowISO()
            )
        } catch {
            let ms = max(1, Int(Date().timeIntervalSince(start) * 1000.0))
            return AIPingResult(
                provider: provider,
                authMode: authMode,
                success: false,
                latencyMs: ms,
                modelLabel: provider.displayName,
                message: error.localizedDescription,
                timestampISO: DatabaseManager.nowISO()
            )
        }
    }

    // MARK: - Recipe Discovery

    func discoverRecipes(
        query: String,
        mealType: MealFilter,
        dietaryFilters: [String],
        cacheMediaDir: URL
    ) async throws -> [Recipe] {
        let provider = activeProvider()
        let (_, token) = try await resolveToken(for: provider)

        var parts = [
            "Use live web search to find 7 real, well-rated web recipes matching: '\(query)' (interpret casual phrasing, cravings, or typos naturally)."
        ]
        if mealType != .all {
            parts.append("Meal category: \(mealType.rawValue).")
        }
        if !dietaryFilters.isEmpty {
            parts.append("Dietary restrictions: \(dietaryFilters.joined(separator: ", ")).")
        }
        parts.append(
            "Return live recipe URLs found in search results, concise ingredients and steps, per-serving macros, explicit food allergens (or [] if none), meal_type (Breakfast, Lunch, Dinner, or Snacks), and relevant dietary_tags."
        )
        let prompt = parts.joined(separator: " ")

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "recipes": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "source_url": ["type": "string"],
                            "prep_time": ["type": "string"],
                            "servings": ["type": "integer"],
                            "kcal": ["type": "integer"],
                            "protein_g": ["type": "integer"],
                            "carbs_g": ["type": "integer"],
                            "fat_g": ["type": "integer"],
                            "sodium_mg": ["type": "integer"],
                            "sugar_g": ["type": "integer"],
                            "cholesterol_mg": ["type": "integer"],
                            "meal_type": ["type": "string", "enum": ["Breakfast", "Lunch", "Dinner", "Snacks"]],
                            "dietary_tags": ["type": "array", "items": ["type": "string"]],
                            "allergens": ["type": "array", "items": ["type": "string"]],
                            "ingredients": ["type": "array", "items": ["type": "string"]],
                            "steps": ["type": "array", "items": ["type": "string"]],
                        ],
                        "required": [
                            "title", "source_url", "prep_time", "servings",
                            "kcal", "protein_g", "carbs_g", "fat_g",
                            "sodium_mg", "sugar_g", "cholesterol_mg",
                            "meal_type", "dietary_tags", "allergens", "ingredients", "steps",
                        ],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "required": ["recipes"],
            "additionalProperties": false,
        ]

        let rawText = try await executeStructuredJSON(
            provider: provider,
            token: token,
            systemInstruction: "You are a culinary researcher returning verified live web recipes with accurate macro estimates.",
            prompt: prompt,
            schemaName: "velda_recipes",
            schema: schema,
            enableWebSearch: true
        )

        let cleanedText = stripMarkdownJSONFence(rawText)
        guard let jsonData = cleanedText.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(AIRecipesResponse.self, from: jsonData),
              !parsed.recipes.isEmpty else {
            throw AIProviderError.invalidResponse("Could not parse structured recipe data from \(provider.displayName).")
        }

        let validMeals = Set(["Breakfast", "Lunch", "Dinner", "Snacks"])
        let stamp = DatabaseManager.nowISO()
        var verified: [Recipe] = []

        for item in parsed.recipes.prefix(10) {
            if verified.count >= 5 { break }
            let (isLive, finalURL, pageImgBytes) = await verifyURLAndFetchImage(item.source_url)
            if !isLive { continue }

            let recId = "rec_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased())"
            let fname = "\(recId).jpg"
            let destURL = cacheMediaDir.appendingPathComponent(fname)
            var imagePath: String?
            var imageSource = "placeholder"

            if let imgData = pageImgBytes,
               let compressed = DatabaseManager.compressSquareJPEG(imgData, targetSize: 480, quality: 0.75) {
                try? compressed.write(to: destURL, options: .atomic)
                imagePath = "cache/\(fname)"
                imageSource = "source_og"
            }

            let rawMeal = (item.meal_type ?? "").trimmingCharacters(in: .whitespacesAndNewlines).capitalized
            let chosenMeal: String
            if validMeals.contains(rawMeal) {
                chosenMeal = rawMeal
            } else if mealType != .all {
                chosenMeal = mealType.rawValue
            } else {
                chosenMeal = "Dinner"
            }

            let domain = URL(string: finalURL)?.host?.replacingOccurrences(of: "www.", with: "") ?? "web"
            verified.append(
                Recipe(
                    id: recId,
                    title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    sourceURL: finalURL,
                    sourceDomain: domain,
                    prepTime: item.prep_time?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "25 min",
                    servings: max(1, item.servings ?? 2),
                    kcal: max(0, item.kcal ?? 0),
                    proteinG: max(0, item.protein_g ?? 0),
                    carbsG: max(0, item.carbs_g ?? 0),
                    fatG: max(0, item.fat_g ?? 0),
                    sodiumMg: max(0, item.sodium_mg ?? 0),
                    sugarG: max(0, item.sugar_g ?? 0),
                    cholesterolMg: max(0, item.cholesterol_mg ?? 0),
                    mealType: chosenMeal,
                    dietaryTags: item.dietary_tags ?? [],
                    allergens: item.allergens ?? [],
                    ingredients: item.ingredients ?? [],
                    steps: item.steps ?? [],
                    imagePath: imagePath,
                    imageSource: imageSource,
                    isSaved: false,
                    discoveredAt: stamp,
                    savedAt: nil
                )
            )
        }

        if verified.isEmpty {
            throw AIProviderError.noVerifiedRecipes
        }
        return verified
    }

    // MARK: - Routine Builder

    func buildRoutine(userInstruction: String, includeCustomExercises: Bool = true) async throws -> GeneratedRoutinePlan {
        let provider = activeProvider()
        let (_, token) = try await resolveToken(for: provider)

        let cleanPrompt = userInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty else {
            throw AIProviderError.emptyPrompt
        }

        let catalog = DatabaseManager.shared.allCatalogEntries(includeCustom: includeCustomExercises)
        guard !catalog.isEmpty else {
            throw AIProviderError.emptyCatalog
        }

        let compactCatalog = catalog.map {
            CompactCatalogItem(id: $0.id, name: $0.name, muscle: $0.muscleHint)
        }
        let catalogData = try JSONEncoder().encode(compactCatalog)
        let catalogJSON = String(data: catalogData, encoding: .utf8) ?? "[]"

        let systemInstruction = """
        You are an expert strength and conditioning coach building a structured workout routine strictly from the user's exercise catalog.
        HARD BOUNDARY RULES:
        1. You MUST ONLY select movements that exist in the provided CATALOG_JSON array.
        2. Every item in `exercise_ids` MUST be an exact `id` string copied verbatim from CATALOG_JSON. Never invent or modify IDs outside the catalog.
        3. Choose 4 to 8 movements (unless the user asks for a different count) ordered logically.
        4. Provide a concise, clean routine `title` (2 to 4 words) and a brief 1-sentence `summary`.
        """

        let prompt = """
        USER REQUEST:
        \(cleanPrompt)

        CATALOG_JSON (\(compactCatalog.count) available movements):
        \(catalogJSON)
        """

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "summary": ["type": "string"],
                "exercise_ids": [
                    "type": "array",
                    "items": ["type": "string"],
                ],
            ],
            "required": ["title", "summary", "exercise_ids"],
            "additionalProperties": false,
        ]

        let rawText = try await executeStructuredJSON(
            provider: provider,
            token: token,
            systemInstruction: systemInstruction,
            prompt: prompt,
            schemaName: "velda_routine",
            schema: schema,
            enableWebSearch: false
        )

        let cleaned = stripMarkdownJSONFence(rawText)
        guard let jsonData = cleaned.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(AIRoutinePayload.self, from: jsonData) else {
            throw AIProviderError.invalidResponse("Could not parse structured routine from \(provider.displayName).")
        }

        let verifiedExercises = DatabaseManager.shared.exercisesForCatalogIds(
            parsed.exercise_ids,
            includeCustom: includeCustomExercises
        )
        guard !verifiedExercises.isEmpty else {
            throw AIProviderError.noMatchingMovements
        }

        let finalTitle = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return GeneratedRoutinePlan(
            title: finalTitle.isEmpty ? "Velda Routine" : finalTitle,
            summary: (parsed.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            exercises: verifiedExercises
        )
    }

    // MARK: - Diet & Macro Estimator

    func estimateMealMacros(description: String) async throws -> EstimatedMealMacros {
        let provider = activeProvider()
        let (_, token) = try await resolveToken(for: provider)

        let clean = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw AIProviderError.emptyPrompt
        }

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
                "meal_slot": ["type": "string", "enum": ["Breakfast", "Lunch", "Dinner", "Snacks"]],
                "kcal": ["type": "integer"],
                "protein_g": ["type": "integer"],
                "carbs_g": ["type": "integer"],
                "fat_g": ["type": "integer"],
                "sodium_mg": ["type": "integer"],
                "sugar_g": ["type": "integer"],
                "cholesterol_mg": ["type": "integer"],
                "notes": ["type": "string"],
            ],
            "required": ["name", "meal_slot", "kcal", "protein_g", "carbs_g", "fat_g", "sodium_mg", "sugar_g", "cholesterol_mg", "notes"],
            "additionalProperties": false,
        ]

        let prompt = """
        Estimate realistic nutrition macros for this meal or food log entry:
        "\(clean)"
        Return a clean concise meal name, best meal_slot (Breakfast, Lunch, Dinner, or Snacks), integer kcal, protein_g, carbs_g, fat_g, sodium_mg, sugar_g, cholesterol_mg, and brief portion assumptions in notes.
        """

        let rawText = try await executeStructuredJSON(
            provider: provider,
            token: token,
            systemInstruction: "You are a precise nutrition logger estimating realistic kcal and macronutrients.",
            prompt: prompt,
            schemaName: "velda_meal_macros",
            schema: schema,
            enableWebSearch: false
        )

        let cleaned = stripMarkdownJSONFence(rawText)
        guard let data = cleaned.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(AIMacroEstimatePayload.self, from: data) else {
            throw AIProviderError.invalidResponse("Could not parse macro estimate from \(provider.displayName).")
        }

        let validSlots = Set(["Breakfast", "Lunch", "Dinner", "Snacks"])
        let rawSlot = (parsed.meal_slot ?? "Lunch").capitalized
        let notesText = (parsed.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return EstimatedMealMacros(
            name: parsed.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? clean : parsed.name.trimmingCharacters(in: .whitespacesAndNewlines),
            mealSlot: validSlots.contains(rawSlot) ? rawSlot : "Lunch",
            kcal: max(0, parsed.kcal ?? 0),
            proteinG: max(0, parsed.protein_g ?? 0),
            carbsG: max(0, parsed.carbs_g ?? 0),
            fatG: max(0, parsed.fat_g ?? 0),
            sodiumMg: max(0, parsed.sodium_mg ?? 0),
            sugarG: max(0, parsed.sugar_g ?? 0),
            cholesterolMg: max(0, parsed.cholesterol_mg ?? 0),
            notes: notesText
        )
    }

    // MARK: - AI Recipe Import & Image Generation

    func parseImportedRecipe(rawContent: String) async throws -> Recipe {
        let clean = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw AIProviderError.emptyPrompt
        }

        let provider = activeProvider()
        let (_, token) = try await resolveToken(for: provider)
        let isURL = clean.lowercased().hasPrefix("http://") || clean.lowercased().hasPrefix("https://")

        let prompt = """
        Convert the following recipe source into a structured recipe entry. Extract the title, meal_type (Breakfast, Lunch, Dinner, or Snacks), prep_time, servings, per-serving nutrition estimates (kcal, protein_g, carbs_g, fat_g, sodium_mg, sugar_g, cholesterol_mg), dietary_tags, allergens, ingredients, steps, and source_url (empty string if not a URL).

        SOURCE CONTENT:
        \(String(clean.prefix(12000)))
        """

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "source_url": ["type": "string"],
                "prep_time": ["type": "string"],
                "servings": ["type": "integer"],
                "kcal": ["type": "integer"],
                "protein_g": ["type": "integer"],
                "carbs_g": ["type": "integer"],
                "fat_g": ["type": "integer"],
                "sodium_mg": ["type": "integer"],
                "sugar_g": ["type": "integer"],
                "cholesterol_mg": ["type": "integer"],
                "meal_type": ["type": "string"],
                "dietary_tags": ["type": "array", "items": ["type": "string"]],
                "allergens": ["type": "array", "items": ["type": "string"]],
                "ingredients": ["type": "array", "items": ["type": "string"]],
                "steps": ["type": "array", "items": ["type": "string"]],
            ],
            "required": [
                "title", "source_url", "prep_time", "servings",
                "kcal", "protein_g", "carbs_g", "fat_g",
                "sodium_mg", "sugar_g", "cholesterol_mg",
                "meal_type", "dietary_tags", "allergens", "ingredients", "steps",
            ],
            "additionalProperties": false,
        ]

        let rawText = try await executeStructuredJSON(
            provider: provider,
            token: token,
            systemInstruction: "You are a culinary assistant parsing arbitrary recipe text, markdown, JSON, or web pages into a structured recipe with accurate per-serving macro and micronutrient estimates.",
            prompt: prompt,
            schemaName: "velda_imported_recipe",
            schema: schema,
            enableWebSearch: isURL
        )

        let cleanedText = stripMarkdownJSONFence(rawText)
        guard let jsonData = cleanedText.data(using: .utf8),
              let item = try? JSONDecoder().decode(AIRecipeCandidate.self, from: jsonData) else {
            throw AIProviderError.invalidResponse("Could not parse recipe structure from \(provider.displayName).")
        }

        let validMeals = Set(["Breakfast", "Lunch", "Dinner", "Snacks"])
        let rawMeal = (item.meal_type ?? "Dinner").trimmingCharacters(in: .whitespacesAndNewlines).capitalized
        let chosenMeal = validMeals.contains(rawMeal) ? rawMeal : "Dinner"
        let srcURL = item.source_url.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = URL(string: srcURL)?.host?.replacingOccurrences(of: "www.", with: "") ?? "imported"
        let stamp = DatabaseManager.nowISO()
        let recId = "rec_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased())"

        return Recipe(
            id: recId,
            title: item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Imported Recipe" : item.title.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceURL: srcURL,
            sourceDomain: domain,
            prepTime: item.prep_time?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "25 min",
            servings: max(1, item.servings ?? 2),
            kcal: max(0, item.kcal ?? 0),
            proteinG: max(0, item.protein_g ?? 0),
            carbsG: max(0, item.carbs_g ?? 0),
            fatG: max(0, item.fat_g ?? 0),
            sodiumMg: max(0, item.sodium_mg ?? 0),
            sugarG: max(0, item.sugar_g ?? 0),
            cholesterolMg: max(0, item.cholesterol_mg ?? 0),
            mealType: chosenMeal,
            dietaryTags: item.dietary_tags ?? [],
            allergens: item.allergens ?? [],
            ingredients: item.ingredients ?? [],
            steps: item.steps ?? [],
            imagePath: nil,
            imageSource: "placeholder",
            isSaved: true,
            discoveredAt: stamp,
            savedAt: stamp
        )
    }

    func generateRecipeImage(title: String, ingredients: [String]) async throws -> Data {
        let provider = activeProvider()
        if provider == .anthropic {
            throw AIProviderError.imageGenerationUnsupported(.anthropic)
        }
        let (mode, token) = try await resolveToken(for: provider)

        let ingSummary = ingredients.prefix(6).joined(separator: ", ")
        let prompt = ingSummary.isEmpty
            ? "Overhead editorial food photography of \(title), plated cleanly on matte ceramic stoneware in soft natural daylight, warm minimalist styling, no text, no watermarks."
            : "Overhead editorial food photography of \(title) made with \(ingSummary), plated cleanly on matte ceramic stoneware in soft natural daylight, warm minimalist styling, no text, no watermarks."

        switch provider {
        case .gemini:
            let payload: [String: Any] = [
                "model": "gemini-nano-banana-2.1",
                "input": prompt,
                "response_format": [
                    "type": "image",
                    "mime_type": "image/jpeg",
                    "aspect_ratio": "1:1",
                    "image_size": "1K",
                ],
            ]
            let resp = try await postGemini(apiKey: token, payload: payload)
            guard let data = extractGeminiImageData(resp) else {
                throw AIProviderError.invalidResponse("Gemini did not return an image.")
            }
            return data

        case .openai:
            let endpoint = URL(string: "https://api.openai.com/v1/images/generations")!
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "model": "gpt-image-1",
                "prompt": prompt,
                "n": 1,
                "size": "1024x1024",
                "quality": "medium",
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                if mode == .signIn && (http.statusCode == 401 || http.statusCode == 403) {
                    throw AIProviderError.apiError("OpenAI image generation requires an OpenAI API key with image access (ChatGPT subscription sign-in may not cover the Images endpoint). You can add an OpenAI API key or switch to Gemini in Vault.")
                }
                let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                throw AIProviderError.apiError("OpenAI Images HTTP \(http.statusCode): \(String(msg.prefix(240)))")
            }

            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["data"] as? [[String: Any]],
                  let first = arr.first else {
                throw AIProviderError.invalidResponse("OpenAI returned an unexpected image payload.")
            }

            if let b64 = first["b64_json"] as? String, let decoded = Data(base64Encoded: b64) {
                return decoded
            }
            if let urlStr = first["url"] as? String, let imgURL = URL(string: urlStr) {
                let (imgBytes, _) = try await session.data(from: imgURL)
                if !imgBytes.isEmpty { return imgBytes }
            }
            throw AIProviderError.invalidResponse("OpenAI did not return image data.")

        case .anthropic:
            throw AIProviderError.imageGenerationUnsupported(.anthropic)
        }
    }

    // MARK: - Provider Transport Layer

    private func executeStructuredJSON(
        provider: AIProvider,
        token: String,
        systemInstruction: String,
        prompt: String,
        schemaName: String,
        schema: [String: Any],
        enableWebSearch: Bool
    ) async throws -> String {
        switch provider {
        case .gemini:
            var payload: [String: Any] = [
                "model": "gemini-4-hydrogen",
                "system_instruction": systemInstruction,
                "input": prompt,
                "generation_config": ["thinking_level": "low"],
                "response_format": [
                    "type": "text",
                    "mime_type": "application/json",
                    "schema": schema,
                ],
            ]
            if enableWebSearch {
                payload["tools"] = [["type": "google_search"]]
            }
            let resp = try await postGemini(apiKey: token, payload: payload)
            let txt = extractGeminiText(resp)
            if txt.isEmpty {
                throw AIProviderError.invalidResponse("Gemini returned an empty response.")
            }
            return txt

        case .openai:
            var payload: [String: Any] = [
                "model": "gpt-6.2-sol",
                "instructions": systemInstruction,
                "input": prompt,
                "text": [
                    "format": [
                        "type": "json_schema",
                        "name": schemaName,
                        "strict": true,
                        "schema": schema,
                    ],
                ],
            ]
            if enableWebSearch {
                payload["tools"] = [["type": "web_search", "search_context_size": "low"]]
            }
            let resp = try await postOpenAI(bearer: token, payload: payload)
            let txt = extractOpenAIText(resp)
            if txt.isEmpty {
                throw AIProviderError.invalidResponse("OpenAI returned an empty response.")
            }
            return txt

        case .anthropic:
            var payload: [String: Any] = [
                "model": "claude-sonnet-5-5",
                "max_tokens": 4096,
                "system": systemInstruction,
                "messages": [
                    ["role": "user", "content": prompt],
                ],
                "output_config": [
                    "format": [
                        "type": "json_schema",
                        "schema": schema,
                    ],
                ],
            ]
            if enableWebSearch {
                payload["tools"] = [["type": "web_search_20260209", "name": "web_search"]]
            }
            let resp = try await postAnthropic(apiKey: token, payload: payload)
            let txt = extractAnthropicText(resp)
            if txt.isEmpty {
                throw AIProviderError.invalidResponse("Claude returned an empty response.")
            }
            return txt
        }
    }

    private func postGemini(apiKey: String, payload: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: geminiEndpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(geminiRevision, forHTTPHeaderField: "Api-Revision")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return try await sendJSONRequest(req, providerName: "Gemini")
    }

    private func postOpenAI(bearer: String, payload: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: openAIEndpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return try await sendJSONRequest(req, providerName: "OpenAI")
    }

    private func postAnthropic(apiKey: String, payload: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: anthropicEndpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return try await sendJSONRequest(req, providerName: "Anthropic")
    }

    private func sendJSONRequest(_ req: URLRequest, providerName: String) async throws -> [String: Any] {
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AIProviderError.apiError("\(providerName) HTTP \(http.statusCode): \(String(msg.prefix(240)))")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIProviderError.invalidResponse("Unexpected response format from \(providerName).")
        }
        return obj
    }

    private func extractGeminiText(_ resp: [String: Any]) -> String {
        var chunks: [String] = []
        if let steps = resp["steps"] as? [[String: Any]] {
            for step in steps where (step["type"] as? String) == "model_output" {
                if let content = step["content"] as? [[String: Any]] {
                    for item in content where (item["type"] as? String) == "text" {
                        if let t = item["text"] as? String, !t.isEmpty {
                            chunks.append(t)
                        }
                    }
                }
            }
        }
        if !chunks.isEmpty {
            return chunks.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let ot = resp["output_text"] as? String {
            return ot.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private func extractOpenAIText(_ resp: [String: Any]) -> String {
        if let ot = resp["output_text"] as? String, !ot.isEmpty {
            return ot.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var chunks: [String] = []
        if let output = resp["output"] as? [[String: Any]] {
            for item in output where (item["type"] as? String) == "message" {
                if let content = item["content"] as? [[String: Any]] {
                    for c in content where ((c["type"] as? String) == "output_text" || (c["type"] as? String) == "text") {
                        if let t = c["text"] as? String, !t.isEmpty {
                            chunks.append(t)
                        }
                    }
                }
            }
        }
        return chunks.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractAnthropicText(_ resp: [String: Any]) -> String {
        var chunks: [String] = []
        if let content = resp["content"] as? [[String: Any]] {
            for item in content where (item["type"] as? String) == "text" {
                if let t = item["text"] as? String, !t.isEmpty {
                    chunks.append(t)
                }
            }
        }
        return chunks.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractGeminiImageData(_ resp: [String: Any]) -> Data? {
        if let steps = resp["steps"] as? [[String: Any]] {
            for step in steps.reversed() where (step["type"] as? String) == "model_output" {
                if let content = step["content"] as? [[String: Any]] {
                    for item in content where (item["type"] as? String) == "image" {
                        if let b64 = item["data"] as? String, let d = Data(base64Encoded: b64) {
                            return d
                        }
                    }
                }
            }
        }
        if let outImg = resp["output_image"] as? [String: Any],
           let b64 = outImg["data"] as? String,
           let d = Data(base64Encoded: b64) {
            return d
        }
        return nil
    }

    private func generateGeminiFallbackThumbnail(apiKey: String, title: String) async -> Data? {
        let payload: [String: Any] = [
            "model": "gemini-nano-banana-2.1",
            "input": "Overhead editorial food photography of \(title), plated cleanly on matte stoneware in soft natural daylight, minimalist styling, no text, no watermarks.",
            "response_format": [
                "type": "image",
                "mime_type": "image/jpeg",
                "aspect_ratio": "1:1",
                "image_size": "1K",
            ],
        ]
        guard let resp = try? await postGemini(apiKey: apiKey, payload: payload) else {
            return nil
        }
        return extractGeminiImageData(resp)
    }

    // MARK: - Live URL Verification & OG Image Fetch

    private func verifyURLAndFetchImage(_ rawURL: String) async -> (Bool, String, Data?) {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return (false, rawURL, nil)
        }

        var req = URLRequest(url: url, timeoutInterval: 7)
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        do {
            let (data, resp) = try await session.data(for: req)
            let finalURL = resp.url?.absoluteString ?? trimmed
            if let http = resp as? HTTPURLResponse {
                if [401, 403, 429].contains(http.statusCode) {
                    return (true, finalURL, nil)
                }
                if http.statusCode < 200 || http.statusCode >= 400 {
                    return (false, trimmed, nil)
                }
            }
            let capped = data.prefix(350_000)
            let html = String(data: capped, encoding: .utf8) ?? String(decoding: capped, as: UTF8.self)
            guard let imgURLString = extractImageURL(from: html, baseURL: resp.url ?? url),
                  let imgURL = URL(string: imgURLString) else {
                return (true, finalURL, nil)
            }

            var imgReq = URLRequest(url: imgURL, timeoutInterval: 8)
            imgReq.setValue(browserUA, forHTTPHeaderField: "User-Agent")
            imgReq.setValue(finalURL, forHTTPHeaderField: "Referer")
            if let (imgData, imgResp) = try? await session.data(for: imgReq),
               let httpImg = imgResp as? HTTPURLResponse,
               httpImg.statusCode >= 200, httpImg.statusCode < 400 {
                return (true, finalURL, imgData)
            }
            return (true, finalURL, nil)
        } catch {
            return (false, trimmed, nil)
        }
    }

    private func extractImageURL(from html: String, baseURL: URL) -> String? {
        let patterns = [
            #"<meta[^>]+(?:property|name)=["']og:image["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["']og:image["']"#,
            #"<meta[^>]+(?:property|name)=["']twitter:image(?::src)?["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["']twitter:image(?::src)?["']"#,
        ]
        for pat in patterns {
            if let regex = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let candidate = decodeHTMLEntities(String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines))
                if !candidate.isEmpty, !candidate.hasPrefix("data:"),
                   let resolved = URL(string: candidate, relativeTo: baseURL)?.absoluteString {
                    return resolved
                }
            }
        }
        return nil
    }

    private func stripMarkdownJSONFence(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            }
            if s.hasSuffix("```") {
                s = String(s.dropLast(3))
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeHTMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
