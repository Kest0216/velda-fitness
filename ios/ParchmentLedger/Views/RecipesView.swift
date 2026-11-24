import PhotosUI
import SwiftUI
import UIKit

struct RecipesView: View {
    @EnvironmentObject var store: LedgerStore

    @State private var photoPickerItem: PhotosPickerItem?
    @State private var photoTargetRecipeId: String?
    @State private var showCameraSheet: Bool = false
    @State private var shareItem: IdentifiedShareURL? = nil
    @State private var showManualCreator: Bool = false
    @State private var showAIImporter: Bool = false
    @State private var pendingConfirm: PendingActionConfirmation? = nil
    @State private var missingAIFeatureName: String? = nil
    @State private var imageDisclaimerMessage: String? = nil
    @State private var imageErrorByRecipe: [String: String] = [:]

    var body: some View {
        let savedFiltered = store.filteredRecipes(in: .saved)
        let discoverFiltered = store.filteredRecipes(in: .discover)

        ZStack(alignment: .top) {
            VStack(spacing: 10) {
                // Row 1: Saved / Discover tabs
                HStack(spacing: 8) {
                    tabButton(.saved, label: "Saved (\(savedFiltered.count))")
                    tabButton(.discover, label: "Discover (\(discoverFiltered.count))")
                }
                .inkWritten(index: 0, epoch: store.inkWriteEpoch)

                // Row 2: Create Manual Recipe / AI Import
                HStack(spacing: 8) {
                    Button {
                        LedgerHaptics.light()
                        showManualCreator = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                            Text("New Recipe")
                        }
                    }
                    .buttonStyle(PrimaryActionButtonStyle(fullWidth: true))

                    Button {
                        LedgerHaptics.light()
                        guard store.hasConfiguredAICredential else {
                            missingAIFeatureName = "AI Recipe Import"
                            return
                        }
                        showAIImporter = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 10, weight: .semibold))
                            Text("AI Import")
                        }
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: false, fullWidth: true))
                }
                .inkWritten(index: 1, epoch: store.inkWriteEpoch)

                // Row 3: Meal / Dietary Dropdowns
                HStack(spacing: 8) {
                    dropdownTrigger(
                        label: store.mealFilter.triggerLabel,
                        isActive: store.mealFilter != .all
                    ) {
                        LedgerHaptics.light()
                        withAnimation(.easeOut(duration: 0.16)) {
                            store.openDropdown = store.openDropdown == .meal ? nil : .meal
                        }
                    }

                    dropdownTrigger(
                        label: store.dietaryFilters.isEmpty ? "Dietary" : "Dietary (\(store.dietaryFilters.count))",
                        isActive: !store.dietaryFilters.isEmpty
                    ) {
                        LedgerHaptics.light()
                        withAnimation(.easeOut(duration: 0.16)) {
                            store.openDropdown = store.openDropdown == .dietary ? nil : .dietary
                        }
                    }
                }
                .inkWritten(index: 2, epoch: store.inkWriteEpoch)
                .zIndex(35)

                // Recipe List Content
                Group {
                    if store.recipeTab == .saved {
                        ScrollView(showsIndicators: false) {
                            recipeList(savedFiltered, emptyTitle: "Saved", baseIndex: 3)
                                .padding(.top, 4)
                                .padding(.bottom, 56)
                        }
                    } else {
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 20) {
                                discoverSearchCard
                                    .inkWritten(index: 3, epoch: store.inkWriteEpoch)
                                recipeList(discoverFiltered, emptyTitle: "Discover", baseIndex: 4)
                            }
                            .padding(.top, 4)
                            .padding(.bottom, 56)
                        }
                        .scrollDismissesKeyboard(.interactively)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.top, 6)

            // Floating Dropdown Popovers
            if store.openDropdown != nil {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.14)) {
                            store.openDropdown = nil
                        }
                    }
                    .zIndex(45)

                HStack(alignment: .top, spacing: 12) {
                    if store.openDropdown == .meal {
                        mealDropdownPopover
                        Spacer()
                    } else {
                        Spacer()
                        dietaryDropdownPopover
                    }
                }
                .padding(.top, 134)
                .zIndex(50)
            }
        }
        .onChange(of: photoPickerItem) { _, newItem in
            guard let newItem, let targetId = photoTargetRecipeId else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    imageErrorByRecipe[targetId] = nil
                    store.saveCookedPhoto(recipeId: targetId, rawData: data)
                }
                photoPickerItem = nil
            }
        }
        .fullScreenCover(isPresented: $showCameraSheet) {
            ZStack {
                Color.black.ignoresSafeArea()
                CameraImagePicker { image in
                    if let targetId = photoTargetRecipeId,
                       let data = image.jpegData(compressionQuality: 0.9) {
                        imageErrorByRecipe[targetId] = nil
                        store.saveCookedPhoto(recipeId: targetId, rawData: data)
                    }
                }
                .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $showManualCreator) {
            ManualRecipeSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $showAIImporter) {
            RecipeImportSheet()
                .environmentObject(store)
        }
        .sheet(item: $shareItem) { item in
            ActivityShareSheet(activityItems: [item.url])
        }
        .actionConfirmationAlert($pendingConfirm)
        .aiCredentialRequiredAlert(featureName: $missingAIFeatureName) {
            store.selectPillar(.vault)
        }
        .alert(
            "Image Generation Unavailable",
            isPresented: Binding(
                get: { imageDisclaimerMessage != nil },
                set: { if !$0 { imageDisclaimerMessage = nil } }
            ),
            presenting: imageDisclaimerMessage
        ) { _ in
            Button("Open Vault") {
                imageDisclaimerMessage = nil
                store.selectPillar(.vault)
            }
            Button("OK", role: .cancel) {
                imageDisclaimerMessage = nil
            }
        } message: { msg in
            Text(msg)
        }
    }

    private func tabButton(_ tab: RecipeTab, label: String) -> some View {
        let isActive = store.recipeTab == tab
        return Button(label) {
            guard store.recipeTab != tab else { return }
            LedgerHaptics.light()
            withAnimation(.easeInOut(duration: 0.22)) {
                store.openDropdown = nil
                store.expandedRecipeId = nil
                store.recipeTab = tab
            }
            store.triggerInkWrite()
        }
        .buttonStyle(WarmActionButtonStyle(isActive: isActive, fullWidth: true))
    }

    private func dropdownTrigger(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label.uppercased())
                Spacer()
                Text("▾")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(WarmActionButtonStyle(isActive: isActive, fullWidth: true))
    }

    private var mealDropdownPopover: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(MealFilter.allCases) { opt in
                let selected = store.mealFilter == opt
                Button {
                    LedgerHaptics.light()
                    store.mealFilter = opt
                    withAnimation(.easeOut(duration: 0.14)) {
                        store.openDropdown = nil
                    }
                } label: {
                    HStack {
                        Text(opt.displayLabel)
                            .font(LedgerFont.sansSm(semibold: selected))
                        Spacer()
                        if selected {
                            Text("✓")
                                .font(LedgerFont.sansSm(semibold: true))
                        }
                    }
                    .foregroundStyle(selected ? LedgerColor.buttonTextLight : LedgerColor.inkPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(selected ? LedgerColor.inkPrimary : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .frame(width: 178)
        .padding(6)
        .background(LedgerColor.parchmentPopover)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: LedgerColor.inkPrimary.opacity(0.20), radius: 14, x: 0, y: 6)
    }

    private var dietaryDropdownPopover: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(LedgerStore.dietaryOptions, id: \.self) { opt in
                let checked = store.dietaryFilters.contains(opt)
                Button {
                    store.toggleDietaryFilter(opt)
                } label: {
                    HStack {
                        Text(opt)
                            .font(LedgerFont.sansSm(semibold: checked))
                        Spacer()
                        if checked {
                            Text("✓")
                                .font(LedgerFont.sansSm(semibold: true))
                        }
                    }
                    .foregroundStyle(checked ? LedgerColor.buttonTextLight : LedgerColor.inkPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(checked ? LedgerColor.inkPrimary : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            if !store.dietaryFilters.isEmpty {
                Button {
                    LedgerHaptics.light()
                    store.dietaryFilters.removeAll()
                    store.openDropdown = nil
                } label: {
                    HStack {
                        Text("Clear filters")
                            .font(LedgerFont.sansSm())
                        Spacer()
                        Text("×")
                            .font(LedgerFont.sansSm())
                    }
                    .foregroundStyle(LedgerColor.inkSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
            }
        }
        .frame(width: 186)
        .padding(6)
        .background(LedgerColor.parchmentPopover)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: LedgerColor.inkPrimary.opacity(0.20), radius: 14, x: 0, y: 6)
    }

    private var discoverSearchCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("AI RECIPE SEARCH · \(store.activeAIProvider.shortLabel)")
                Spacer()
                Text("5 VERIFIED LINKS")
            }
            .font(LedgerFont.sansSm())
            .tracking(1.0)
            .foregroundStyle(LedgerColor.inkSecondary)

            HStack(spacing: 8) {
                TextField("Describe any craving or ingredients...", text: $store.discoverQuery)
                    .font(LedgerFont.serifMd())
                    .foregroundStyle(LedgerColor.inkPrimary)
                    .disabled(store.isDiscovering)
                    .warmRecessedField()
                    .onSubmit {
                        triggerDiscoverWithConfirmation()
                    }

                Button(store.isDiscovering ? "Crawling…" : "Crawl") {
                    triggerDiscoverWithConfirmation()
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(store.isDiscovering)
            }

            if store.isDiscovering {
                InkLoadingQuillView(
                    label: "Searching live recipe sites with \(store.activeAIProvider.displayName)…"
                )
            }

            if let err = store.discoverError, !err.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(err)
                        .font(LedgerFont.sansSm())
                        .foregroundStyle(LedgerColor.inkPrimary)
                    if err.localizedCaseInsensitiveContains("key") || err.localizedCaseInsensitiveContains("credential") || err.localizedCaseInsensitiveContains("vault") {
                        Button("Open Vault →") {
                            store.selectPillar(.vault)
                        }
                        .buttonStyle(WarmActionButtonStyle(isActive: true))
                    }
                }
            }
        }
        .softPanel()
    }

    private func triggerDiscoverWithConfirmation() {
        guard store.hasConfiguredAICredential else {
            missingAIFeatureName = "AI Recipe Search"
            return
        }
        let q = store.discoverQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            store.showToast("Enter a dish or craving")
            return
        }
        pendingConfirm = PendingActionConfirmation(
            title: "Search Web Recipes with \(store.activeAIProvider.displayName)?",
            message: "Sends your search \"\(q)\" to \(store.activeAIProvider.displayName) to find up to 5 live web recipes and save them in Discover.",
            confirmLabel: "Search Recipes",
            isDestructive: false
        ) {
            Task { await store.crawlRecipes() }
        }
    }

    @ViewBuilder
    private func recipeList(_ recipes: [Recipe], emptyTitle: String, baseIndex: Int) -> some View {
        if recipes.isEmpty {
            VStack(spacing: 6) {
                Text("No recipes in \(emptyTitle)")
                    .font(LedgerFont.serifLg(italic: true))
                    .foregroundStyle(LedgerColor.inkPrimary)
                Text(emptyTitle == "Saved" ? "TAP + NEW RECIPE, AI IMPORT, OR SAVE FROM DISCOVER" : "ADJUST FILTERS OR SEARCH ABOVE")
                    .font(LedgerFont.sansSm())
                    .tracking(0.8)
                    .foregroundStyle(LedgerColor.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .inkWritten(index: baseIndex, epoch: store.inkWriteEpoch)
        } else {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(Array(recipes.enumerated()), id: \.element.id) { idx, rec in
                    recipeRow(rec)
                        .inkWritten(index: baseIndex + idx, epoch: store.inkWriteEpoch)
                }
            }
        }
    }

    private func recipeRow(_ rec: Recipe) -> some View {
        let isOpen = store.expandedRecipeId == rec.id
        let allergenText = rec.allergens.isEmpty ? "Allergens: None listed" : "Allergens: \(rec.allergens.joined(separator: ", "))"
        let hasImage = store.mediaURL(for: rec).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let isGeneratingThis = store.generatingImageRecipeId == rec.id

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                RecipeThumbnailView(url: store.mediaURL(for: rec), size: 60, cornerRadius: 12)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 6) {
                        Text("\(rec.mealType.uppercased()) · \(rec.prepTime.uppercased())")
                            .font(LedgerFont.sansSm())
                            .tracking(0.8)
                            .foregroundStyle(LedgerColor.inkSecondary)
                            .lineLimit(1)

                        Spacer()

                        Button(rec.isSaved ? "✓ Saved" : "+ Save") {
                            store.toggleRecipeSave(rec.id)
                        }
                        .buttonStyle(WarmActionButtonStyle(isActive: rec.isSaved))
                    }

                    Text(rec.title)
                        .font(LedgerFont.serifLg(semibold: true))
                        .foregroundStyle(LedgerColor.inkPrimary)
                        .multilineTextAlignment(.leading)

                    Text("\(rec.kcal) KCAL · \(rec.proteinG)G P · \(rec.carbsG)G C · \(rec.fatG)G F")
                        .font(LedgerFont.sansSm())
                        .tracking(0.6)
                        .foregroundStyle(LedgerColor.inkSecondary)

                    if isOpen && (rec.sodiumMg > 0 || rec.sugarG > 0 || rec.cholesterolMg > 0) {
                        Text("SODIUM \(rec.sodiumMg)MG · SUGAR \(rec.sugarG)G · CHOLESTEROL \(rec.cholesterolMg)MG")
                            .font(LedgerFont.sansSm())
                            .tracking(0.5)
                            .foregroundStyle(LedgerColor.inkSecondary)
                    }

                    HStack {
                        Text(allergenText)
                            .font(LedgerFont.serifSmItalic())
                            .foregroundStyle(LedgerColor.inkSecondary)
                            .lineLimit(1)
                        Spacer()
                        if !rec.sourceURL.isEmpty, let siteURL = URL(string: rec.sourceURL) {
                            Link("↗ \(rec.sourceDomain)", destination: siteURL)
                                .font(LedgerFont.sansSm())
                                .foregroundStyle(LedgerColor.inkPrimary)
                                .underline()
                                .lineLimit(1)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                LedgerHaptics.light()
                withAnimation(.easeInOut(duration: 0.2)) {
                    store.expandedRecipeId = isOpen ? nil : rec.id
                }
            }

            if isOpen {
                VStack(alignment: .leading, spacing: 14) {
                    // Clean Header Row inside expanded card
                    HStack(alignment: .center, spacing: 14) {
                        RecipeThumbnailView(url: store.mediaURL(for: rec), size: 76, cornerRadius: 14)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(photoStatusLabel(for: rec, hasImage: hasImage))
                                .font(LedgerFont.sansSm(semibold: true))
                                .tracking(0.9)
                                .foregroundStyle(LedgerColor.inkSecondary)

                            Text("\(rec.servings) SERVING\(rec.servings == 1 ? "" : "S") · \(rec.prepTime.uppercased())")
                                .font(LedgerFont.sansSm())
                                .foregroundStyle(LedgerColor.inkPrimary)

                            if hasImage {
                                Button("Remove Photo") {
                                    pendingConfirm = PendingActionConfirmation(
                                        title: "Remove Recipe Photo?",
                                        message: "Deletes the saved dish photo for \"\(rec.title)\" from this device.",
                                        confirmLabel: "Remove Photo",
                                        isDestructive: true
                                    ) {
                                        store.clearRecipePhoto(recipeId: rec.id)
                                    }
                                }
                                .buttonStyle(WarmActionButtonStyle(isActive: false))
                            }
                        }

                        Spacer()
                    }

                    // Uniform 3-button Photo Row: Camera | Library | Generate
                    HStack(spacing: 8) {
                        let cameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)
                        Button {
                            photoTargetRecipeId = rec.id
                            showCameraSheet = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "camera")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Camera")
                            }
                        }
                        .buttonStyle(WarmActionButtonStyle(isActive: false, fullWidth: true))
                        .disabled(!cameraAvailable)
                        .opacity(cameraAvailable ? 1.0 : 0.42)

                        PhotosPicker(selection: $photoPickerItem, matching: .images) {
                            HStack(spacing: 4) {
                                Image(systemName: "photo")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Library")
                            }
                            .uniformSecondaryButtonChrome(disabled: false, fullWidth: true)
                        }
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                photoTargetRecipeId = rec.id
                            }
                        )

                        Button {
                            handleGenerateImageTap(for: rec)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(isGeneratingThis ? "Making…" : "Generate")
                            }
                        }
                        .buttonStyle(WarmActionButtonStyle(isActive: false, fullWidth: true))
                        .disabled(hasImage || isGeneratingThis)
                        .opacity((hasImage || isGeneratingThis) ? 0.42 : 1.0)
                    }

                    if !hasImage && !store.activeProviderSupportsImageGeneration {
                        Text("Note: \(store.activeAIProvider.displayName) does not generate images. Switch to OpenAI or Gemini in Vault, or use Camera / Library.")
                            .font(LedgerFont.serifMd(italic: true))
                            .foregroundStyle(LedgerColor.inkSecondary)
                    }

                    if isGeneratingThis {
                        InkLoadingQuillView(label: "Generating dish photo with \(store.activeAIProvider.displayName)…")
                    }

                    if let imgErr = imageErrorByRecipe[rec.id], !imgErr.isEmpty {
                        Text(imgErr)
                            .font(LedgerFont.sansSm())
                            .foregroundStyle(LedgerColor.errorRust)
                    }

                    // Uniform 3-button Action Row: Log Macros | Share | Delete
                    HStack(spacing: 8) {
                        Button("+ Log Macros") {
                            pendingConfirm = PendingActionConfirmation(
                                title: "Log Recipe to Macros?",
                                message: "Add 1 serving of \"\(rec.title)\" (\(rec.kcal) kcal) to \(DatabaseManager.mediumDateLabel(store.macroDate))?",
                                confirmLabel: "Log Macros",
                                isDestructive: false
                            ) {
                                store.logRecipeToMacros(rec, servings: 1.0)
                            }
                        }
                        .buttonStyle(PrimaryActionButtonStyle(fullWidth: true))

                        Menu {
                            ForEach(ExportFormat.allCases) { fmt in
                                Button("Share as \(fmt.label)") {
                                    if let url = store.prepareRecipeShareFile(rec, format: fmt) {
                                        shareItem = IdentifiedShareURL(url: url)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Share")
                            }
                            .uniformSecondaryButtonChrome(disabled: false, fullWidth: true)
                        }

                        Button("Delete") {
                            pendingConfirm = PendingActionConfirmation(
                                title: "Delete Recipe?",
                                message: "Permanently remove \"\(rec.title)\" and any saved dish photo from this device?",
                                confirmLabel: "Delete",
                                isDestructive: true
                            ) {
                                store.deleteRecipe(rec.id)
                            }
                        }
                        .buttonStyle(WarmActionButtonStyle(isActive: false, fullWidth: true))
                    }

                    if !rec.sourceURL.isEmpty, let siteURL = URL(string: rec.sourceURL) {
                        Link(destination: siteURL) {
                            HStack(spacing: 4) {
                                Text("Open Original Source (\(rec.sourceDomain))")
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .font(LedgerFont.sansSm(semibold: true))
                        .foregroundStyle(LedgerColor.inkPrimary)
                        .underline()
                    }

                    if !rec.ingredients.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("INGREDIENTS (\(rec.servings) SERVINGS)")
                                .font(LedgerFont.sansSm())
                                .tracking(1.6)
                                .foregroundStyle(LedgerColor.inkSecondary)

                            ForEach(Array(rec.ingredients.enumerated()), id: \.offset) { _, ing in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("✦")
                                        .font(LedgerFont.sansSm())
                                        .padding(.top, 2)
                                    Text(ing)
                                        .font(LedgerFont.serifMd())
                                        .foregroundStyle(LedgerColor.inkPrimary)
                                }
                            }
                        }
                    }

                    if !rec.steps.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("PREPARATION")
                                .font(LedgerFont.sansSm())
                                .tracking(1.6)
                                .foregroundStyle(LedgerColor.inkSecondary)

                            ForEach(Array(rec.steps.enumerated()), id: \.offset) { idx, st in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(String(format: "%02d.", idx + 1))
                                        .font(LedgerFont.sansSm(semibold: true))
                                        .foregroundStyle(LedgerColor.inkSecondary)
                                        .padding(.top, 2)
                                    Text(st)
                                        .font(LedgerFont.serifMd())
                                        .foregroundStyle(LedgerColor.inkPrimary)
                                }
                            }
                        }
                    }
                }
                .softPanel()
            }
        }
    }

    private func photoStatusLabel(for rec: Recipe, hasImage: Bool) -> String {
        if !hasImage { return "NO PHOTO YET" }
        switch rec.imageSource {
        case "custom_photo": return "COOKED PHOTO"
        case "ai_generated", "generated": return "AI GENERATED IMAGE"
        case "source_og": return "SOURCE PHOTO"
        default: return "SAVED PHOTO"
        }
    }

    private func handleGenerateImageTap(for rec: Recipe) {
        guard store.hasConfiguredAICredential else {
            missingAIFeatureName = "AI Recipe Image Generation"
            return
        }
        guard store.activeProviderSupportsImageGeneration else {
            imageDisclaimerMessage = "\(store.activeAIProvider.displayName) does not support generating images. Switch your provider to OpenAI or Gemini in Vault, or attach your own photo with Camera or Photo Library."
            return
        }
        pendingConfirm = PendingActionConfirmation(
            title: "Generate Dish Image with \(store.activeAIProvider.displayName)?",
            message: "Sends \"\(rec.title)\" and its ingredient list to \(store.activeAIProvider.displayName) to generate a custom dish photo and save it to your recipe.",
            confirmLabel: "Generate Image",
            isDestructive: false
        ) {
            imageErrorByRecipe[rec.id] = nil
            Task {
                if let err = await store.generateAIImage(for: rec) {
                    imageErrorByRecipe[rec.id] = err
                }
            }
        }
    }
}

struct RecipeThumbnailView: View {
    let url: URL?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if let url, let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LedgerColor.parchmentLight
                    Image(systemName: "fork.knife")
                        .font(.system(size: size * 0.35))
                        .foregroundStyle(LedgerColor.inkSecondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: LedgerColor.inkPrimary.opacity(0.14), radius: 6, x: 0, y: 3)
    }
}

struct CameraImagePicker: UIViewControllerRepresentable {
    let onPicked: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.modalPresentationStyle = .fullScreen
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraImagePicker
        init(parent: CameraImagePicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.onPicked(img)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
