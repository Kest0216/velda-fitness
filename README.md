# Velda Fitness

A pure on-device iOS 17+ fitness, nutrition, recipe, and cycle journal in SwiftUI (`com.veldaapp.veldafitness`), paired with the static [veldaapp.com](https://veldaapp.com) website.

- **Website:** [https://veldaapp.com](https://veldaapp.com)
- **Terms & Public Health Sources:** [https://veldaapp.com/terms.html](https://veldaapp.com/terms.html)
- **Support:** `support@veldaapp.com`
- **License:** MIT (provided "as is", with zero obligation for perpetual maintenance or updates)

---

## Core Architecture (Zero Backend Servers)

All personal health data stays strictly on-device in SQLite and local app media folders, with optional backups to the user's own private Apple iCloud and encrypted Apple Keychain:

1. **Workouts:** 588 bundled offline exercise demo support (`.mp4` assets are excluded from git; see setup below), custom movement studio, weighted/bodyweight/timed set logging, progression trendlines, weekly/date-specific routine scheduling, and a Weight Over Time line graph.
2. **Diet & Macros:** Track Calories, Protein, Carbs, Fat, Sodium, Sugar, and Cholesterol against customizable targets, inspect nutrient Trends over time (`7D`, `14D`, `30D`, `90D`), or log saved recipes in one tap.
3. **Recipes:** Create recipes manually, attach dish photos from Camera or Photo Library, or connect your own AI provider to search web recipes, import recipe text/links/files, or generate dish illustrations (OpenAI or Gemini).
4. **Cycle Tracker (Optional):** Color-coded period/cycle calendar (`Period`, `Predicted`, `Follicular`, `Ovulatory`, `Luteal`), symptom/mood/energy/temperature logging, non-diagnostic cycle variation alerts citing published `.gov`/PubMed guidelines, and an on/off toggle in Vault.
5. **Vault:** Storage meters, 60-day auto-cleanup for unsaved web recipe cache, Bring-Your-Own-AI settings (OpenAI ChatGPT sign-in/API key, Gemini API key, Anthropic API key with live connection testing), iCloud backup, JSON/Markdown/Text export/import, and two-step data erasure.

---

## Building from Source in Xcode

Because this repository is kept completely credential-free:

1. Open `ios/ParchmentLedger.xcodeproj` in Xcode 15 or newer.
2. Create an untracked `ios/Config/Signing.local.xcconfig` file (already gitignored) with your Apple Developer Team ID:
   ```
   DEVELOPMENT_TEAM = YOUR_APPLE_TEAM_ID
   ```
   Or select your Signing Team directly in Xcode under **ParchmentLedger → Signing & Capabilities**.
3. Update `PRODUCT_BUNDLE_IDENTIFIER` if building under your own App Store / personal team.
4. *(Optional Exercise Video Demos)* `ios/ParchmentLedger/MoveKitVideos/*.mp4` files are excluded from git due to media size. Drop matching `.mp4` clips into `ios/ParchmentLedger/MoveKitVideos/` or build without them—the app gracefully handles missing video clips and supports standalone custom exercises.
5. Build and run on an iOS 17+ device or simulator.

---

## Health & Medical Disclaimer

Velda Fitness is strictly an informational personal journal and **not medical advice, clinical diagnosis, or contraception**. Default nutrition reference limits and cycle regularity notices cite public U.S. government (`FDA.gov`, `DietaryGuidelines.gov`, `WomensHealth.gov`, `NICHD.NIH.gov`) and peer-reviewed PubMed sources (`PMID: 30198563`, `PMID: 37580861`), listed inside the app and on [veldaapp.com/terms.html#health-sources](https://veldaapp.com/terms.html#health-sources).
