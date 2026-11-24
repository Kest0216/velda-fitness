import SwiftUI

struct CustomExerciseSheet: View {
    @EnvironmentObject var store: LedgerStore
    @Environment(\.dismiss) private var dismiss

    @State private var editingId: String? = nil
    @State private var isCreating: Bool = false
    @State private var sheetEpoch: Int = 0
    @State private var deleteTarget: Exercise? = nil

    @State private var nameDraft: String = ""
    @State private var muscleDraft: String = "Strength"
    @State private var trackingDraft: ExerciseTrackingType = .weighted
    @State private var equipmentDraft: String = ""
    @State private var notesDraft: String = ""
    @State private var filmSearch: String = ""
    @State private var filmFilename: String = ""
    @State private var addToSelectedDay: Bool = false
    @State private var pendingConfirm: PendingActionConfirmation? = nil

    private let muscleGroups = ["Strength", "Push", "Pull", "Legs", "Shoulders", "Arms", "Core", "Mobility", "Cardio", "Custom"]

    private var inEditor: Bool {
        isCreating || editingId != nil
    }

    var body: some View {
        ZStack {
            ParchmentBackgroundView()

            VStack(alignment: .leading, spacing: 14) {
                headerBar

                Rectangle()
                    .fill(Color.white.opacity(0.55))
                    .frame(height: 1.2)

                if inEditor {
                    editorBody
                } else {
                    listBody
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
        .onAppear {
            sheetEpoch &+= 1
        }
        .actionConfirmationAlert($pendingConfirm)
        .alert("Delete Custom Exercise?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let target = deleteTarget {
                    store.deleteCustomExercise(target.id)
                    deleteTarget = nil
                    sheetEpoch &+= 1
                }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Removes “\(deleteTarget?.name ?? "")” from your custom library and any routines using it. Logged workout history stays safe.")
        }
    }

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("CUSTOM EXERCISE STUDIO")
                    .font(LedgerFont.sansSm())
                    .tracking(1.8)
                    .foregroundStyle(LedgerColor.inkSecondary)

                Text(inEditor ? (isCreating ? "New Movement" : "Edit Movement") : "My Movements (\(store.customExercises.count))")
                    .font(LedgerFont.serifLg(bold: true))
                    .foregroundStyle(LedgerColor.inkPrimary)
                    .lineLimit(1)
            }

            Spacer()

            if inEditor {
                Button("Back") {
                    LedgerHaptics.light()
                    resetEditor()
                    sheetEpoch &+= 1
                }
                .buttonStyle(WarmActionButtonStyle())

                Button("Save") {
                    let clean = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else {
                        store.showToast("Enter a movement name")
                        return
                    }
                    let verb = editingId != nil ? "Update" : "Create"
                    pendingConfirm = PendingActionConfirmation(
                        title: "\(verb) Custom Movement?",
                        message: "\(verb) \"\(clean)\" (\(muscleDraft), \(trackingDraft.label)) in your custom exercise library?",
                        confirmLabel: verb,
                        isDestructive: false
                    ) {
                        saveDraft()
                    }
                }
                .buttonStyle(PrimaryActionButtonStyle())
            } else {
                Button("Done") {
                    LedgerHaptics.light()
                    dismiss()
                }
                .buttonStyle(PrimaryActionButtonStyle())
            }
        }
    }

    private var listBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("+ New Custom Exercise") {
                    LedgerHaptics.light()
                    startCreate()
                }
                .buttonStyle(PrimaryActionButtonStyle())

                Spacer()
            }
            .inkWritten(index: 0, epoch: sheetEpoch)

            if store.customExercises.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("No Custom Movements Yet")
                        .font(LedgerFont.serifLg(italic: true))
                        .foregroundStyle(LedgerColor.inkPrimary)
                    Text("BUILD EXERCISES OUTSIDE THE 588 MOVEKIT CATALOG WITH YOUR OWN TRACKING MODE & CUES")
                        .font(LedgerFont.sansSm())
                        .tracking(0.8)
                        .foregroundStyle(LedgerColor.inkSecondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .inkWritten(index: 1, epoch: sheetEpoch)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(store.customExercises.enumerated()), id: \.element.id) { idx, ex in
                            customCard(ex)
                                .inkWritten(index: idx + 1, epoch: sheetEpoch)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func customCard(_ ex: Exercise) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ex.name)
                        .font(LedgerFont.serifMd(semibold: true))
                        .foregroundStyle(LedgerColor.inkPrimary)

                    let meta = [
                        ex.muscleHint.uppercased(),
                        ex.trackingType.uppercased(),
                        ex.equipment.isEmpty ? nil : ex.equipment.uppercased(),
                        ex.videoFilename != nil ? "LINKED FILM" : "STANDALONE",
                    ].compactMap { $0 }.joined(separator: " · ")

                    Text(meta)
                        .font(LedgerFont.sansSm())
                        .tracking(0.6)
                        .foregroundStyle(LedgerColor.inkSecondary)
                }

                Spacer()
            }

            if !ex.notes.isEmpty {
                Text(ex.notes)
                    .font(LedgerFont.serifMd(italic: true))
                    .foregroundStyle(LedgerColor.inkSecondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Button("+ Add to \(DatabaseManager.shortDateLabel(store.selectedDate))") {
                    store.addExerciseToCurrentDay(ex.id)
                }
                .buttonStyle(WarmActionButtonStyle(isActive: false))

                Spacer()

                Button("Edit") {
                    LedgerHaptics.light()
                    startEdit(ex)
                }
                .buttonStyle(WarmActionButtonStyle())

                Button("Delete") {
                    LedgerHaptics.heavy()
                    deleteTarget = ex
                }
                .buttonStyle(WarmActionButtonStyle())
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LedgerColor.parchmentLight.opacity(0.56))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.36), lineWidth: 0.8)
        )
    }

    private var editorBody: some View {
        let filmCandidates = DatabaseManager.shared.fuzzySearchExercises(query: filmSearch, limit: 12)
            .filter { $0.videoFilename != nil }

        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("MOVEMENT NAME")
                        .font(LedgerFont.sansSm())
                        .tracking(1.6)
                        .foregroundStyle(LedgerColor.inkSecondary)

                    TextField("e.g. Ring Muscle-Up, Sled Push, Neck Curl...", text: $nameDraft)
                        .font(LedgerFont.serifMd())
                        .foregroundStyle(LedgerColor.inkPrimary)
                        .warmRecessedField()
                }
                .inkWritten(index: 0, epoch: sheetEpoch)

                VStack(alignment: .leading, spacing: 8) {
                    Text("MUSCLE / FOCUS GROUP")
                        .font(LedgerFont.sansSm())
                        .tracking(1.6)
                        .foregroundStyle(LedgerColor.inkSecondary)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], spacing: 6) {
                        ForEach(muscleGroups, id: \.self) { group in
                            Button(group) {
                                LedgerHaptics.light()
                                muscleDraft = group
                            }
                            .buttonStyle(WarmActionButtonStyle(isActive: muscleDraft.caseInsensitiveCompare(group) == .orderedSame))
                        }
                    }
                }
                .inkWritten(index: 1, epoch: sheetEpoch)

                VStack(alignment: .leading, spacing: 8) {
                    Text("TRACKING MODE")
                        .font(LedgerFont.sansSm())
                        .tracking(1.6)
                        .foregroundStyle(LedgerColor.inkSecondary)

                    HStack(spacing: 8) {
                        ForEach(ExerciseTrackingType.allCases) { mode in
                            Button(mode.label) {
                                LedgerHaptics.light()
                                trackingDraft = mode
                            }
                            .buttonStyle(WarmActionButtonStyle(isActive: trackingDraft == mode))
                        }
                    }
                }
                .inkWritten(index: 2, epoch: sheetEpoch)

                VStack(alignment: .leading, spacing: 6) {
                    Text("EQUIPMENT (OPTIONAL)")
                        .font(LedgerFont.sansSm())
                        .tracking(1.6)
                        .foregroundStyle(LedgerColor.inkSecondary)

                    TextField("e.g. Gymnastic Rings, Kettlebell, Sled...", text: $equipmentDraft)
                        .font(LedgerFont.serifMd())
                        .foregroundStyle(LedgerColor.inkPrimary)
                        .warmRecessedField()
                }
                .inkWritten(index: 3, epoch: sheetEpoch)

                VStack(alignment: .leading, spacing: 6) {
                    Text("FORM CUES / PERSONAL NOTES")
                        .font(LedgerFont.sansSm())
                        .tracking(1.6)
                        .foregroundStyle(LedgerColor.inkSecondary)

                    TextField("Tempo, grip width, depth cue, setup notes...", text: $notesDraft, axis: .vertical)
                        .lineLimit(2...5)
                        .font(LedgerFont.serifMd())
                        .foregroundStyle(LedgerColor.inkPrimary)
                        .warmRecessedField()
                }
                .inkWritten(index: 4, epoch: sheetEpoch)

                VStack(alignment: .leading, spacing: 8) {
                    Text("OPTIONAL REFERENCE MOVEKIT FILM")
                        .font(LedgerFont.sansSm())
                        .tracking(1.6)
                        .foregroundStyle(LedgerColor.inkSecondary)

                    TextField("Filter MoveKit films (leave blank for standalone)...", text: $filmSearch)
                        .font(LedgerFont.sansMd())
                        .foregroundStyle(LedgerColor.inkPrimary)
                        .warmRecessedField()

                    Picker("Reference Film", selection: $filmFilename) {
                        Text("None (Standalone Custom Movement)").tag("")
                        ForEach(filmCandidates) { cand in
                            Text(cand.name).tag(cand.videoFilename ?? "")
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(LedgerColor.inkPrimary)
                }
                .softPanel()
                .inkWritten(index: 5, epoch: sheetEpoch)

                if isCreating {
                    Button {
                        LedgerHaptics.light()
                        addToSelectedDay.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            HandDrawnCheckboxView(isChecked: addToSelectedDay)
                            Text("ADD TO \(DatabaseManager.shortDateLabel(store.selectedDate).uppercased()) ROUTINE")
                                .font(LedgerFont.sansSm())
                                .tracking(1.0)
                                .foregroundStyle(LedgerColor.inkPrimary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func startCreate() {
        editingId = nil
        isCreating = true
        nameDraft = ""
        muscleDraft = "Strength"
        trackingDraft = .weighted
        equipmentDraft = ""
        notesDraft = ""
        filmSearch = ""
        filmFilename = ""
        addToSelectedDay = true
        sheetEpoch &+= 1
    }

    private func startEdit(_ ex: Exercise) {
        isCreating = false
        editingId = ex.id
        nameDraft = ex.name
        muscleDraft = ex.muscleHint.isEmpty ? "Custom" : ex.muscleHint
        trackingDraft = ExerciseTrackingType(rawValue: ex.trackingType) ?? .weighted
        equipmentDraft = ex.equipment
        notesDraft = ex.notes
        filmSearch = ""
        filmFilename = ex.videoFilename ?? ""
        addToSelectedDay = false
        sheetEpoch &+= 1
    }

    private func resetEditor() {
        isCreating = false
        editingId = nil
    }

    private func saveDraft() {
        let clean = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            store.showToast("Enter a movement name")
            return
        }
        let vf = filmFilename.isEmpty ? nil : filmFilename
        if let eid = editingId {
            store.updateCustomExercise(
                id: eid,
                name: clean,
                muscleHint: muscleDraft,
                trackingType: trackingDraft.rawValue,
                equipment: equipmentDraft,
                notes: notesDraft,
                videoFilename: vf
            )
        } else {
            _ = store.createCustomExerciseFull(
                name: clean,
                muscleHint: muscleDraft,
                trackingType: trackingDraft.rawValue,
                equipment: equipmentDraft,
                notes: notesDraft,
                videoFilename: vf,
                addToCurrentDay: addToSelectedDay
            )
        }
        resetEditor()
        sheetEpoch &+= 1
    }
}
