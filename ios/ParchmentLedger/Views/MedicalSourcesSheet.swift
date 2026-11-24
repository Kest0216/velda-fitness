// MARK: - Health & Dietary Sources Sheet
//
// Displays the non-medical disclaimer alongside clickable links to public U.S. government
// (`FDA.gov`, `DietaryGuidelines.gov`, `WomensHealth.gov`, `NICHD.NIH.gov`) and PubMed references.

import SwiftUI

struct MedicalSourcesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            ParchmentBackgroundView()

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    SectionHeaderView(
                        title: "Health & Dietary Sources",
                        subtitle: "GOVERNMENT & PEER-REVIEWED REFERENCES"
                    )

                    Spacer()

                    Button("Done") {
                        LedgerHaptics.light()
                        dismiss()
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                }

                Rectangle()
                    .fill(Color.white.opacity(0.55))
                    .frame(height: 1.2)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("NOT MEDICAL ADVICE")
                                .font(LedgerFont.sansSm(semibold: true))
                                .tracking(1.4)
                                .foregroundStyle(LedgerColor.errorRust)

                            Text("Velda Fitness is an informational personal wellness ledger, not a medical device or diagnostic tool. Nutrition targets, cycle phase colors, and irregular-cycle alerts are general educational patterns only. Always consult a qualified physician or healthcare provider before making medical, dietary, or reproductive health decisions.")
                                .font(LedgerFont.serifMd())
                                .foregroundStyle(LedgerColor.inkPrimary)
                        }
                        .softPanel()

                        ForEach(HealthReferenceSource.all) { src in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(src.category.uppercased())
                                    .font(LedgerFont.sansSm(semibold: true))
                                    .tracking(1.0)
                                    .foregroundStyle(LedgerColor.warmTerracotta)

                                Text(src.title)
                                    .font(LedgerFont.serifMd(semibold: true))
                                    .foregroundStyle(LedgerColor.inkPrimary)

                                Text(src.publisher)
                                    .font(LedgerFont.sansSm())
                                    .foregroundStyle(LedgerColor.inkSecondary)

                                Text(src.summary)
                                    .font(LedgerFont.serifMd(italic: true))
                                    .foregroundStyle(LedgerColor.inkSecondary)

                                if let url = URL(string: src.urlString) {
                                    Link("Open Source ↗", destination: url)
                                        .font(LedgerFont.sansSm(semibold: true))
                                        .foregroundStyle(LedgerColor.inkPrimary)
                                        .underline()
                                        .padding(.top, 2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(LedgerColor.parchmentLight.opacity(0.75))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(LedgerColor.inkPrimary.opacity(0.14), lineWidth: 0.9)
                            )
                        }
                    }
                    .padding(.bottom, 28)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
    }
}
