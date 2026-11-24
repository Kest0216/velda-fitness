import PhotosUI
import SwiftUI
import UIKit

struct ManualRecipeSheet: View {
    @EnvironmentObject var store: LedgerStore
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var mealType: String = "Dinner"
    @State private var prepTime: String = "20 min"
    @State private var servingsText: String = "2"

    @State private var kcalText: String = ""
    @State private var proteinText: String = ""
    @State private var carbsText: String = ""
    @State private var fatText: String = ""
    @State private var sodiumText: String = ""
    @State private var sugarText: String = ""
    @State private var cholesterolText: String = ""

    @State private var selectedDietary: Set<String> = []
    @State private var allergensText: String = ""
    @State private var ingredientsText: String = ""
    @State private var stepsText: String = ""

    @State private var photoData: Data? = nil
    @State private var photoPickerItem: PhotosPickerItem? = nil
    @State private var showCameraSheet: Bool = false
    @State private var pendingConfirm: PendingActionConfirmation? = nil

    private let mealTypes = ["Breakfast", "Lunch", "Dinner", "Snacks"]

    var body: some View {
        ZStack {
            ParchmentBackgroundView()

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    SectionHeaderView(
                        title: "New Recipe",
                        subtitle: "MANUAL LEDGER ENTRY"
                    )

                    Spacer()

                    Button("Cancel") {
                        LedgerHaptics.light()
                        dismiss()
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: false))
                }

                Rectangle()
                    .fill(Color.white.opacity(0.55))
                    .frame(height: 1.2)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        basicsSection
                        nutritionSection
                        dietarySection
                        ingredientsStepsSection
                        photoSection

                        Button("Create Recipe") {
                            requestCreateConfirmation()
                        }
                        .buttonStyle(PrimaryActionButtonStyle(fullWidth: true))
                    }
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
        .onChange(of: photoPickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    photoData = data
                }
                photoPickerItem = nil
            }
        }
        .fullScreenCover(isPresented: $showCameraSheet) {
            ZStack {
                Color.black.ignoresSafeArea()
                CameraImagePicker { image in
                    if let data = image.jpegData(compressionQuality: 0.9) {
                        photoData = data
                    }
                }
                .ignoresSafeArea()
            }
        }
        .actionConfirmationAlert($pendingConfirm)
    }

    private var basicsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RECIPE DETAILS")
                .font(LedgerFont.sansSm(semibold: true))
                .tracking(1.4)
                .foregroundStyle(LedgerColor.inkSecondary)

            TextField("Recipe title (e.g. Grilled Salmon Bowl)...", text: $title)
                .font(LedgerFont.serifMd())
                .foregroundStyle(LedgerColor.inkPrimary)
                .warmRecessedField()

            HStack(spacing: 6) {
                ForEach(mealTypes, id: \.self) { m in
                    Button(m) {
                        LedgerHaptics.light()
                        mealType = m
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: mealType == m, fullWidth: true))
                }
            }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PREP TIME")
                        .font(LedgerFont.sansSm())
                        .foregroundStyle(LedgerColor.inkSecondary)
                    TextField("20 min", text: $prepTime)
                        .font(LedgerFont.sansMd())
                        .foregroundStyle(LedgerColor.inkPrimary)
                        .warmRecessedField()
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 4) {
                    Text("SERVINGS")
                        .font(LedgerFont.sansSm())
                        .foregroundStyle(LedgerColor.inkSecondary)
                    TextField("2", text: $servingsText)
                        .keyboardType(.numberPad)
                        .font(LedgerFont.sansMd())
                        .foregroundStyle(LedgerColor.inkPrimary)
                        .warmRecessedField()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .softPanel()
    }

    private var nutritionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PER-SERVING NUTRITION (OPTIONAL)")
                .font(LedgerFont.sansSm(semibold: true))
                .tracking(1.4)
                .foregroundStyle(LedgerColor.inkSecondary)

            HStack(spacing: 8) {
                numBox("KCAL", text: $kcalText)
                numBox("PROTEIN (G)", text: $proteinText)
                numBox("CARBS (G)", text: $carbsText)
                numBox("FAT (G)", text: $fatText)
            }

            HStack(spacing: 8) {
                numBox("SODIUM (MG)", text: $sodiumText)
                numBox("SUGAR (G)", text: $sugarText)
                numBox("CHOLEST (MG)", text: $cholesterolText)
            }
        }
        .softPanel()
    }

    private var dietarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DIETARY TAGS & ALLERGENS")
                .font(LedgerFont.sansSm(semibold: true))
                .tracking(1.4)
                .foregroundStyle(LedgerColor.inkSecondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                ForEach(LedgerStore.dietaryOptions, id: \.self) { opt in
                    let active = selectedDietary.contains(opt)
                    Button(opt) {
                        LedgerHaptics.light()
                        if active { selectedDietary.remove(opt) } else { selectedDietary.insert(opt) }
                    }
                    .buttonStyle(WarmActionButtonStyle(isActive: active, fullWidth: true))
                }
            }

            TextField("Allergens separated by commas (optional)...", text: $allergensText)
                .font(LedgerFont.serifMd())
                .foregroundStyle(LedgerColor.inkPrimary)
                .warmRecessedField()
        }
        .softPanel()
    }

    private var ingredientsStepsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("INGREDIENTS (ONE PER LINE)")
                    .font(LedgerFont.sansSm(semibold: true))
                    .tracking(1.4)
                    .foregroundStyle(LedgerColor.inkSecondary)

                TextField("e.g.\n6 oz salmon fillet\n1 cup jasmine rice", text: $ingredientsText, axis: .vertical)
                    .lineLimit(3...8)
                    .font(LedgerFont.serifMd())
                    .foregroundStyle(LedgerColor.inkPrimary)
                    .warmRecessedField()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("PREPARATION STEPS (ONE PER LINE)")
                    .font(LedgerFont.sansSm(semibold: true))
                    .tracking(1.4)
                    .foregroundStyle(LedgerColor.inkSecondary)

                TextField("e.g.\nSeason salmon and sear 4 minutes per side.\nServe over warm rice.", text: $stepsText, axis: .vertical)
                    .lineLimit(3...8)
                    .font(LedgerFont.serifMd())
                    .foregroundStyle(LedgerColor.inkPrimary)
                    .warmRecessedField()
            }
        }
        .softPanel()
    }

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RECIPE PHOTO (OPTIONAL)")
                .font(LedgerFont.sansSm(semibold: true))
                .tracking(1.4)
                .foregroundStyle(LedgerColor.inkSecondary)

            if let data = photoData, let uiImg = UIImage(data: data) {
                HStack(spacing: 12) {
                    Image(uiImage: uiImg)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Photo attached")
                            .font(LedgerFont.serifMd(semibold: true))
                            .foregroundStyle(LedgerColor.inkPrimary)
                        Button("Clear Photo") {
                            photoData = nil
                        }
                        .buttonStyle(WarmActionButtonStyle(isActive: false))
                    }
                    Spacer()
                }
            }

            HStack(spacing: 8) {
                Button {
                    LedgerHaptics.light()
                    showCameraSheet = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "camera")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Camera")
                    }
                }
                .buttonStyle(WarmActionButtonStyle(isActive: false, fullWidth: true))
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

                PhotosPicker(selection: $photoPickerItem, matching: .images) {
                    HStack(spacing: 5) {
                        Image(systemName: "photo")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Photo Library")
                    }
                    .uniformSecondaryButtonChrome(disabled: false, fullWidth: true)
                }
            }
        }
        .softPanel()
    }

    private func numBox(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(LedgerFont.sansSm())
                .foregroundStyle(LedgerColor.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            TextField("0", text: text)
                .keyboardType(.numberPad)
                .font(LedgerFont.sansMd())
                .foregroundStyle(LedgerColor.inkPrimary)
                .warmRecessedField()
        }
        .frame(maxWidth: .infinity)
    }

    private func requestCreateConfirmation() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            store.showToast("Enter a recipe title")
            return
        }

        pendingConfirm = PendingActionConfirmation(
            title: "Create Recipe?",
            message: "Save \"\(cleanTitle)\" to your Saved Recipes on this device?",
            confirmLabel: "Create Recipe",
            isDestructive: false
        ) {
            let ingredients = ingredientsText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let steps = stepsText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let allergens = allergensText
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let recipe = Recipe(
                id: "rec_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased())",
                title: cleanTitle,
                sourceURL: "",
                sourceDomain: "manual",
                prepTime: prepTime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "20 min" : prepTime.trimmingCharacters(in: .whitespacesAndNewlines),
                servings: max(1, Int(servingsText) ?? 2),
                kcal: max(0, Int(kcalText) ?? 0),
                proteinG: max(0, Int(proteinText) ?? 0),
                carbsG: max(0, Int(carbsText) ?? 0),
                fatG: max(0, Int(fatText) ?? 0),
                sodiumMg: max(0, Int(sodiumText) ?? 0),
                sugarG: max(0, Int(sugarText) ?? 0),
                cholesterolMg: max(0, Int(cholesterolText) ?? 0),
                mealType: mealType,
                dietaryTags: Array(selectedDietary).sorted(),
                allergens: allergens,
                ingredients: ingredients,
                steps: steps,
                imagePath: nil,
                imageSource: "placeholder",
                isSaved: true,
                discoveredAt: DatabaseManager.nowISO(),
                savedAt: DatabaseManager.nowISO()
            )
            store.createManualRecipe(recipe, rawImageData: photoData)
            dismiss()
        }
    }
}
