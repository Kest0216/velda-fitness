// MARK: - On-Device SQLite Persistence Engine
//
// Zero-server SQLite (`WAL` mode + foreign keys) serialized on a dedicated `DispatchQueue`.
// Handles one-time folder migration from legacy `ParchmentLedger` -> `VeldaFitness`, seeds the
// 588-item MoveKit exercise manifest, enforces 60-day TTL cleanup on unsaved recipe cache, and
// computes workout progression and cycle regularity summaries locally.

import Foundation
import SQLite3
import UIKit

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()

    private let queue = DispatchQueue(label: "com.veldaapp.veldafitness.db")
    private var db: OpaquePointer?

    let rootDir: URL
    let savedMediaDir: URL
    let cacheMediaDir: URL
    let dbURL: URL

    private let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private let dayFullNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    private lazy var bundleStats: (count: Int, bytes: Int64) = {
        BundleVideoResolver.bundleVideoStats()
    }()

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let newRoot = appSupport.appendingPathComponent("VeldaFitness", isDirectory: true)
        let legacyRoot = appSupport.appendingPathComponent("ParchmentLedger", isDirectory: true)
        if !FileManager.default.fileExists(atPath: newRoot.path),
           FileManager.default.fileExists(atPath: legacyRoot.path) {
            try? FileManager.default.moveItem(at: legacyRoot, to: newRoot)
        }
        self.rootDir = newRoot
        self.savedMediaDir = rootDir.appendingPathComponent("media/saved", isDirectory: true)
        self.cacheMediaDir = rootDir.appendingPathComponent("media/cache", isDirectory: true)
        self.dbURL = rootDir.appendingPathComponent("ledger.db")

        queue.sync {
            openAndInitialize()
        }
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    private func openAndInitialize() {
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: savedMediaDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cacheMediaDir, withIntermediateDirectories: true)

        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            return
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA foreign_keys=ON;")
        createTables()
        migrateSchemaIfNeeded()
        syncMoveKitManifest()
        initializeDefaultSettingsIfNeeded()
        purgeLegacyDemoDataOnce()
        _ = runStorageJanitorInternal(aggressive: false)
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db = db else { return false }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if let errMsg = errMsg {
            sqlite3_free(errMsg)
        }
        return rc == SQLITE_OK
    }

    private func scalarInt(_ sql: String, args: [String] = []) -> Int {
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        for (idx, val) in args.enumerated() {
            sqlite3_bind_text(stmt, Int32(idx + 1), val, -1, SQLITE_TRANSIENT)
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    private func createTables() {
        exec("""
        CREATE TABLE IF NOT EXISTS exercises (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            video_filename TEXT,
            muscle_hint TEXT,
            is_custom INTEGER NOT NULL DEFAULT 0,
            tracking_type TEXT NOT NULL DEFAULT 'weighted',
            equipment TEXT NOT NULL DEFAULT '',
            notes TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS day_routines (
            day_of_week INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS routine_exercises (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            day_of_week INTEGER NOT NULL,
            exercise_id TEXT NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0,
            UNIQUE(day_of_week, exercise_id)
        );

        CREATE TABLE IF NOT EXISTS routines (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            emblem TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS routine_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            routine_id TEXT NOT NULL,
            exercise_id TEXT NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0,
            UNIQUE(routine_id, exercise_id)
        );

        CREATE TABLE IF NOT EXISTS weekly_schedule (
            day_of_week INTEGER NOT NULL,
            routine_id TEXT NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (day_of_week, routine_id)
        );

        CREATE TABLE IF NOT EXISTS date_schedule (
            session_date TEXT NOT NULL,
            routine_id TEXT NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (session_date, routine_id)
        );

        CREATE TABLE IF NOT EXISTS workout_sets (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_date TEXT NOT NULL,
            exercise_id TEXT NOT NULL,
            set_number INTEGER NOT NULL,
            reps INTEGER NOT NULL,
            weight REAL NOT NULL,
            completed INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_sets_ex_date
            ON workout_sets(exercise_id, session_date);

        CREATE TABLE IF NOT EXISTS recipes (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            source_url TEXT NOT NULL,
            source_domain TEXT NOT NULL,
            prep_time TEXT,
            servings INTEGER DEFAULT 2,
            kcal INTEGER,
            protein_g INTEGER,
            carbs_g INTEGER,
            fat_g INTEGER,
            sodium_mg INTEGER NOT NULL DEFAULT 0,
            sugar_g INTEGER NOT NULL DEFAULT 0,
            cholesterol_mg INTEGER NOT NULL DEFAULT 0,
            meal_type TEXT NOT NULL DEFAULT '',
            dietary_tags TEXT NOT NULL DEFAULT '[]',
            allergens TEXT NOT NULL DEFAULT '[]',
            ingredients TEXT NOT NULL DEFAULT '[]',
            steps TEXT NOT NULL DEFAULT '[]',
            image_path TEXT,
            image_source TEXT DEFAULT 'placeholder',
            is_saved INTEGER NOT NULL DEFAULT 0,
            discovered_at TEXT NOT NULL,
            saved_at TEXT
        );

        CREATE TABLE IF NOT EXISTS app_settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS weight_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            log_date TEXT NOT NULL UNIQUE,
            weight REAL NOT NULL,
            unit TEXT NOT NULL DEFAULT 'lbs',
            note TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_weight_logs_date
            ON weight_logs(log_date DESC);

        CREATE TABLE IF NOT EXISTS macro_targets (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            kcal INTEGER NOT NULL DEFAULT 2200,
            protein_g INTEGER NOT NULL DEFAULT 160,
            carbs_g INTEGER NOT NULL DEFAULT 220,
            fat_g INTEGER NOT NULL DEFAULT 70,
            sodium_mg INTEGER NOT NULL DEFAULT 2300,
            sugar_g INTEGER NOT NULL DEFAULT 50,
            cholesterol_mg INTEGER NOT NULL DEFAULT 300
        );

        CREATE TABLE IF NOT EXISTS macro_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            log_date TEXT NOT NULL,
            meal_slot TEXT NOT NULL DEFAULT 'Lunch',
            name TEXT NOT NULL,
            servings REAL NOT NULL DEFAULT 1.0,
            kcal INTEGER NOT NULL DEFAULT 0,
            protein_g INTEGER NOT NULL DEFAULT 0,
            carbs_g INTEGER NOT NULL DEFAULT 0,
            fat_g INTEGER NOT NULL DEFAULT 0,
            sodium_mg INTEGER NOT NULL DEFAULT 0,
            sugar_g INTEGER NOT NULL DEFAULT 0,
            cholesterol_mg INTEGER NOT NULL DEFAULT 0,
            recipe_id TEXT,
            notes TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_macro_logs_date
            ON macro_logs(log_date DESC, id DESC);

        CREATE TABLE IF NOT EXISTS cycle_logs (
            log_date TEXT PRIMARY KEY,
            flow TEXT NOT NULL DEFAULT 'none',
            symptoms TEXT NOT NULL DEFAULT '[]',
            mood TEXT NOT NULL DEFAULT '',
            energy INTEGER NOT NULL DEFAULT 3,
            bbt REAL,
            notes TEXT NOT NULL DEFAULT '',
            updated_at TEXT NOT NULL
        );
        """)
    }

    private func tableColumns(_ table: String) -> Set<String> {
        guard let db = db else { return [] }
        var cols = Set<String>()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let ptr = sqlite3_column_text(stmt, 1) {
                    cols.insert(String(cString: ptr))
                }
            }
        }
        sqlite3_finalize(stmt)
        return cols
    }

    private func migrateSchemaIfNeeded() {
        let exCols = tableColumns("exercises")
        if !exCols.contains("tracking_type") {
            exec("ALTER TABLE exercises ADD COLUMN tracking_type TEXT NOT NULL DEFAULT 'weighted';")
        }
        if !exCols.contains("equipment") {
            exec("ALTER TABLE exercises ADD COLUMN equipment TEXT NOT NULL DEFAULT '';")
        }
        if !exCols.contains("notes") {
            exec("ALTER TABLE exercises ADD COLUMN notes TEXT NOT NULL DEFAULT '';")
        }

        let targetCols = tableColumns("macro_targets")
        if !targetCols.contains("sodium_mg") {
            exec("ALTER TABLE macro_targets ADD COLUMN sodium_mg INTEGER NOT NULL DEFAULT 2300;")
        }
        if !targetCols.contains("sugar_g") {
            exec("ALTER TABLE macro_targets ADD COLUMN sugar_g INTEGER NOT NULL DEFAULT 50;")
        }
        if !targetCols.contains("cholesterol_mg") {
            exec("ALTER TABLE macro_targets ADD COLUMN cholesterol_mg INTEGER NOT NULL DEFAULT 300;")
        }

        let logCols = tableColumns("macro_logs")
        if !logCols.contains("sodium_mg") {
            exec("ALTER TABLE macro_logs ADD COLUMN sodium_mg INTEGER NOT NULL DEFAULT 0;")
        }
        if !logCols.contains("sugar_g") {
            exec("ALTER TABLE macro_logs ADD COLUMN sugar_g INTEGER NOT NULL DEFAULT 0;")
        }
        if !logCols.contains("cholesterol_mg") {
            exec("ALTER TABLE macro_logs ADD COLUMN cholesterol_mg INTEGER NOT NULL DEFAULT 0;")
        }

        let recCols = tableColumns("recipes")
        if !recCols.contains("sodium_mg") {
            exec("ALTER TABLE recipes ADD COLUMN sodium_mg INTEGER NOT NULL DEFAULT 0;")
        }
        if !recCols.contains("sugar_g") {
            exec("ALTER TABLE recipes ADD COLUMN sugar_g INTEGER NOT NULL DEFAULT 0;")
        }
        if !recCols.contains("cholesterol_mg") {
            exec("ALTER TABLE recipes ADD COLUMN cholesterol_mg INTEGER NOT NULL DEFAULT 0;")
        }

        let routineCols = tableColumns("routines")
        if !routineCols.contains("emblem") {
            exec("ALTER TABLE routines ADD COLUMN emblem TEXT NOT NULL DEFAULT '';")
        }

        let weeklyCols = tableColumns("weekly_schedule")
        if !weeklyCols.isEmpty && !weeklyCols.contains("sort_order") {
            exec("""
            BEGIN IMMEDIATE;
            CREATE TABLE IF NOT EXISTS weekly_schedule_new (
                day_of_week INTEGER NOT NULL,
                routine_id TEXT NOT NULL,
                sort_order INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (day_of_week, routine_id)
            );
            INSERT OR IGNORE INTO weekly_schedule_new (day_of_week, routine_id, sort_order)
            SELECT day_of_week, routine_id, 0 FROM weekly_schedule WHERE routine_id IS NOT NULL AND routine_id != '';
            DROP TABLE weekly_schedule;
            ALTER TABLE weekly_schedule_new RENAME TO weekly_schedule;
            COMMIT;
            """)
        }

        let dateCols = tableColumns("date_schedule")
        if !dateCols.isEmpty && !dateCols.contains("sort_order") {
            exec("""
            BEGIN IMMEDIATE;
            CREATE TABLE IF NOT EXISTS date_schedule_new (
                session_date TEXT NOT NULL,
                routine_id TEXT NOT NULL,
                sort_order INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (session_date, routine_id)
            );
            INSERT OR IGNORE INTO date_schedule_new (session_date, routine_id, sort_order)
            SELECT session_date, COALESCE(routine_id, ''), 0 FROM date_schedule;
            DROP TABLE date_schedule;
            ALTER TABLE date_schedule_new RENAME TO date_schedule;
            COMMIT;
            """)
        }
    }

    private func syncMoveKitManifest() {
        guard let db = db else { return }
        guard let manifestURL = Bundle.main.url(forResource: "movekit_manifest", withExtension: "json"),
              let data = try? Data(contentsOf: manifestURL),
              let entries = try? JSONDecoder().decode([MoveKitManifestEntry].self, from: data) else {
            return
        }

        let stamp = Self.nowISO()
        exec("BEGIN IMMEDIATE;")
        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO exercises (id, name, video_filename, muscle_hint, is_custom, created_at)
        VALUES (?, ?, ?, ?, 0, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            video_filename = excluded.video_filename,
            muscle_hint = excluded.muscle_hint
        WHERE is_custom = 0
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            for e in entries {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_text(stmt, 1, e.id, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, e.name, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, e.videoFilename, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, e.muscleHint, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 5, stamp, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        exec("COMMIT;")
    }

    private func initializeDefaultSettingsIfNeeded() {
        if scalarInt("SELECT COUNT(*) FROM app_settings") == 0 {
            setSettingInternal(key: "weight_unit", value: "lbs")
            setSettingInternal(key: "cache_ttl_days", value: "60")
            setSettingInternal(key: "cache_max_mb", value: "25")
            setSettingInternal(key: "cycle_tracking_enabled", value: "1")
        }
        // Enforce 60-day fixed Discover cache TTL across existing and new ledgers
        setSettingInternal(key: "cache_ttl_days", value: "60")
        setSettingInternal(key: "routines_v2_migrated", value: "1")

        if scalarInt("SELECT COUNT(*) FROM macro_targets") == 0 {
            exec("INSERT OR IGNORE INTO macro_targets (id, kcal, protein_g, carbs_g, fat_g, sodium_mg, sugar_g, cholesterol_mg) VALUES (1, 2200, 160, 220, 70, 2300, 50, 300);")
        }
    }

    /// Removes legacy seeded demo routines, starter recipes, and demo workout sets once on existing TestFlight upgrades without deleting real user logs.
    private func purgeLegacyDemoDataOnce() {
        guard let db = db else { return }
        if getSettingInternal("demo_data_purged_v1", default: "") == "1" {
            return
        }

        // Collect exact timestamps generated during initial demo seeding so only matching demo workout sets are removed
        var seedTimestamps = Set<String>()
        var tsStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT updated_at FROM day_routines UNION SELECT created_at FROM routines WHERE id LIKE 'rt_seed_%'", -1, &tsStmt, nil) == SQLITE_OK {
            while sqlite3_step(tsStmt) == SQLITE_ROW {
                if let ptr = sqlite3_column_text(tsStmt, 0) {
                    let s = String(cString: ptr)
                    if !s.isEmpty { seedTimestamps.insert(s) }
                }
            }
        }
        sqlite3_finalize(tsStmt)

        let demoRecipeIds = [
            "rec_miso_salmon",
            "rec_lemon_chicken",
            "rec_matcha_chia",
            "rec_crispy_tofu",
            "rec_turkey_meatballs",
            "rec_shrimp_tacos",
            "rec_steak_chimichurri",
            "rec_chickpea_shakshuka",
        ]

        // Collect starter recipe image paths before deleting rows
        var demoImagePaths: [String] = []
        for recId in demoRecipeIds {
            var qStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT image_path FROM recipes WHERE id = ?", -1, &qStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(qStmt, 1, recId, -1, SQLITE_TRANSIENT)
                if sqlite3_step(qStmt) == SQLITE_ROW, let ptr = sqlite3_column_text(qStmt, 0) {
                    demoImagePaths.append(String(cString: ptr))
                }
            }
            sqlite3_finalize(qStmt)
        }

        exec("BEGIN IMMEDIATE;")
        for stamp in seedTimestamps {
            var wsDel: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM workout_sets WHERE updated_at = ?", -1, &wsDel, nil) == SQLITE_OK {
                sqlite3_bind_text(wsDel, 1, stamp, -1, SQLITE_TRANSIENT)
                sqlite3_step(wsDel)
            }
            sqlite3_finalize(wsDel)
        }

        exec("DELETE FROM date_schedule WHERE routine_id LIKE 'rt_seed_%';")
        exec("DELETE FROM weekly_schedule WHERE routine_id LIKE 'rt_seed_%';")
        exec("DELETE FROM routine_items WHERE routine_id LIKE 'rt_seed_%';")
        exec("DELETE FROM routines WHERE id LIKE 'rt_seed_%';")
        exec("DELETE FROM day_routines;")
        exec("DELETE FROM routine_exercises;")

        for recId in demoRecipeIds {
            deleteRecipeById(recId)
        }
        exec("COMMIT;")

        for path in demoImagePaths {
            unlinkMedia(path)
        }
        setSettingInternal(key: "demo_data_purged_v1", value: "1")
    }

    // MARK: - Low-level Inserts

    @discardableResult
    private func insertWorkoutSetRaw(
        sessionDate: String,
        exerciseId: String,
        setNumber: Int,
        reps: Int,
        weight: Double,
        completed: Bool,
        stamp: String
    ) -> Int64 {
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO workout_sets (session_date, exercise_id, set_number, reps, weight, completed, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, sessionDate, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, exerciseId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(setNumber))
            sqlite3_bind_int(stmt, 4, Int32(reps))
            sqlite3_bind_double(stmt, 5, weight)
            sqlite3_bind_int(stmt, 6, completed ? 1 : 0)
            sqlite3_bind_text(stmt, 7, stamp, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    private func insertRecipeRow(_ r: Recipe) {
        guard let db = db else { return }
        var stmt: OpaquePointer?
        let sql = """
        INSERT OR REPLACE INTO recipes (
            id, title, source_url, source_domain, prep_time, servings,
            kcal, protein_g, carbs_g, fat_g, sodium_mg, sugar_g, cholesterol_mg,
            meal_type, dietary_tags, allergens,
            ingredients, steps, image_path, image_source, is_saved,
            discovered_at, saved_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, r.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, r.title, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, r.sourceURL, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, r.sourceDomain, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, r.prepTime, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 6, Int32(r.servings))
            sqlite3_bind_int(stmt, 7, Int32(r.kcal))
            sqlite3_bind_int(stmt, 8, Int32(r.proteinG))
            sqlite3_bind_int(stmt, 9, Int32(r.carbsG))
            sqlite3_bind_int(stmt, 10, Int32(r.fatG))
            sqlite3_bind_int(stmt, 11, Int32(r.sodiumMg))
            sqlite3_bind_int(stmt, 12, Int32(r.sugarG))
            sqlite3_bind_int(stmt, 13, Int32(r.cholesterolMg))
            sqlite3_bind_text(stmt, 14, r.mealType, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 15, Self.encodeStringArray(r.dietaryTags), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 16, Self.encodeStringArray(r.allergens), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 17, Self.encodeStringArray(r.ingredients), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 18, Self.encodeStringArray(r.steps), -1, SQLITE_TRANSIENT)
            if let imgPath = r.imagePath {
                sqlite3_bind_text(stmt, 19, imgPath, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 19)
            }
            sqlite3_bind_text(stmt, 20, r.imageSource, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 21, r.isSaved ? 1 : 0)
            sqlite3_bind_text(stmt, 22, r.discoveredAt, -1, SQLITE_TRANSIENT)
            if let savedAt = r.savedAt {
                sqlite3_bind_text(stmt, 23, savedAt, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 23)
            }
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    // MARK: - Public Workouts & Routines API

    private func insertRoutineRowInternal(id: String, title: String, emblem: String = "", createdAt: String, updatedAt: String) {
        guard let db = db else { return }
        let cleanEmblem = RoutineEmblemCatalog.sanitize(emblem)
        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO routines (id, title, emblem, created_at, updated_at) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET title = excluded.title, emblem = excluded.emblem, updated_at = excluded.updated_at
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, title, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, cleanEmblem, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, createdAt, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, updatedAt, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    private func insertRoutineItemInternal(routineId: String, exerciseId: String, sortOrder: Int) {
        guard let db = db else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT OR IGNORE INTO routine_items (routine_id, exercise_id, sort_order) VALUES (?, ?, ?)"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, routineId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, exerciseId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(sortOrder))
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    private func resolveRoutines(forDate sessionDate: String) -> (routines: [(id: String, title: String, emblem: String)], source: ScheduleSource) {
        guard let db = db else { return ([], .unassigned) }

        let dateRowCount = scalarInt("SELECT COUNT(*) FROM date_schedule WHERE session_date = ?", args: [sessionDate])
        if dateRowCount > 0 {
            var rows: [(id: String, title: String, emblem: String)] = []
            var dsStmt: OpaquePointer?
            let dsSql = """
            SELECT ds.routine_id, r.title, COALESCE(r.emblem, '')
            FROM date_schedule ds
            JOIN routines r ON r.id = ds.routine_id
            WHERE ds.session_date = ? AND ds.routine_id != ''
            ORDER BY ds.sort_order ASC, ds.rowid ASC
            """
            if sqlite3_prepare_v2(db, dsSql, -1, &dsStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(dsStmt, 1, sessionDate, -1, SQLITE_TRANSIENT)
                while sqlite3_step(dsStmt) == SQLITE_ROW {
                    let rid = sqlite3_column_text(dsStmt, 0).map { String(cString: $0) } ?? ""
                    let title = sqlite3_column_text(dsStmt, 1).map { String(cString: $0) } ?? ""
                    let emblem = sqlite3_column_text(dsStmt, 2).map { String(cString: $0) } ?? ""
                    if !rid.isEmpty {
                        rows.append((rid, title, emblem))
                    }
                }
            }
            sqlite3_finalize(dsStmt)
            return rows.isEmpty ? ([], .clearedDate) : (rows, .dateOverride)
        }

        let dow = Self.weekdayIndex(Self.dateFromISO(sessionDate))
        var wsRows: [(id: String, title: String, emblem: String)] = []
        var wsStmt: OpaquePointer?
        let wsSql = """
        SELECT ws.routine_id, r.title, COALESCE(r.emblem, '')
        FROM weekly_schedule ws
        JOIN routines r ON r.id = ws.routine_id
        WHERE ws.day_of_week = ?
        ORDER BY ws.sort_order ASC, ws.rowid ASC
        """
        if sqlite3_prepare_v2(db, wsSql, -1, &wsStmt, nil) == SQLITE_OK {
            sqlite3_bind_int(wsStmt, 1, Int32(dow))
            while sqlite3_step(wsStmt) == SQLITE_ROW {
                let rid = sqlite3_column_text(wsStmt, 0).map { String(cString: $0) } ?? ""
                let title = sqlite3_column_text(wsStmt, 1).map { String(cString: $0) } ?? ""
                let emblem = sqlite3_column_text(wsStmt, 2).map { String(cString: $0) } ?? ""
                if !rid.isEmpty {
                    wsRows.append((rid, title, emblem))
                }
            }
        }
        sqlite3_finalize(wsStmt)

        return wsRows.isEmpty ? ([], .unassigned) : (wsRows, .weekly)
    }

    func getWeekDaySlots(containing sessionDate: String, todayDate: String) -> [WeekDaySlot] {
        queue.sync {
            let dates = Self.weekDates(containing: sessionDate)
            let cal = Calendar(identifier: .gregorian)
            return dates.enumerated().map { idx, d in
                let iso = Self.isoDate(d)
                let dayNum = cal.component(.day, from: d)
                let short = (0..<dayNames.count).contains(idx) ? dayNames[idx].uppercased() : "DAY"
                let resolved = resolveRoutines(forDate: iso)
                let markers = resolved.routines.map { CalendarRoutineMarker(id: $0.id, title: $0.title, emblem: $0.emblem) }
                let hasSets = scalarInt("SELECT COUNT(*) FROM workout_sets WHERE session_date = ? AND completed = 1", args: [iso]) > 0
                return WeekDaySlot(
                    isoDate: iso,
                    dayOfWeek: idx,
                    dayShort: short,
                    dayNumber: dayNum,
                    isToday: iso == todayDate,
                    hasRoutine: !markers.isEmpty,
                    hasLoggedSets: hasSets,
                    routineMarkers: markers
                )
            }
        }
    }

    func getMonthDaySlots(forMonthAnchor anchor: Date, todayDate: String) -> [MonthDaySlot] {
        queue.sync {
            let cal = Calendar(identifier: .gregorian)
            let comps = cal.dateComponents([.year, .month], from: anchor)
            guard let firstOfMonth = cal.date(from: comps),
                  let range = cal.range(of: .day, in: .month, for: firstOfMonth) else {
                return []
            }

            let leadingBlanks = Self.weekdayIndex(firstOfMonth)
            var out: [MonthDaySlot] = []
            for i in 0..<leadingBlanks {
                out.append(MonthDaySlot(id: "blank_\(i)", isoDate: nil, dayNumber: nil, isToday: false, hasRoutine: false, hasLoggedSets: false, routineMarkers: []))
            }

            for day in range {
                guard let d = cal.date(byAdding: .day, value: day - 1, to: firstOfMonth) else { continue }
                let iso = Self.isoDate(d)
                let resolved = resolveRoutines(forDate: iso)
                let markers = resolved.routines.map { CalendarRoutineMarker(id: $0.id, title: $0.title, emblem: $0.emblem) }
                let hasSets = scalarInt("SELECT COUNT(*) FROM workout_sets WHERE session_date = ? AND completed = 1", args: [iso]) > 0
                out.append(
                    MonthDaySlot(
                        id: iso,
                        isoDate: iso,
                        dayNumber: day,
                        isToday: iso == todayDate,
                        hasRoutine: !markers.isEmpty,
                        hasLoggedSets: hasSets,
                        routineMarkers: markers
                    )
                )
            }
            return out
        }
    }

    func getDayWorkout(sessionDate: String) -> DayWorkout {
        queue.sync {
            getDayWorkoutInternal(sessionDate: sessionDate)
        }
    }

    private func getDayWorkoutInternal(sessionDate: String) -> DayWorkout {
        let targetDate = Self.dateFromISO(sessionDate)
        let dayOfWeek = Self.weekdayIndex(targetDate)
        let todayStr = Self.isoDate()
        let shortDate = Self.shortDateLabel(sessionDate)
        let clampedDow = max(0, min(6, dayOfWeek))

        guard let db = db else {
            return DayWorkout(
                dayOfWeek: dayOfWeek,
                dayName: dayNames[clampedDow],
                dayFullName: dayFullNames[clampedDow],
                sessionDate: sessionDate,
                displayDateShort: shortDate,
                isToday: sessionDate == todayStr,
                scheduleSource: .unassigned,
                routines: [],
                completionPct: 100,
                completedExercises: 0,
                totalExercises: 0,
                totalSetsDone: 0
            )
        }

        let resolved = resolveRoutines(forDate: sessionDate)
        var sections: [DayRoutineSection] = []
        var totalSetsDone = 0
        var totalCompletedExercises = 0
        var totalExCount = 0

        for rt in resolved.routines {
            var exItems: [RoutineExerciseItem] = []
            var sectionSetsDone = 0
            var sectionCompletedEx = 0
            var exStmt: OpaquePointer?
            let exSql = """
            SELECT e.id, e.name, e.video_filename, e.muscle_hint, e.is_custom,
                   COALESCE(e.tracking_type, 'weighted'), COALESCE(e.equipment, ''), COALESCE(e.notes, '')
            FROM routine_items ri
            JOIN exercises e ON e.id = ri.exercise_id
            WHERE ri.routine_id = ?
            ORDER BY ri.sort_order ASC, ri.id ASC
            """
            if sqlite3_prepare_v2(db, exSql, -1, &exStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(exStmt, 1, rt.id, -1, SQLITE_TRANSIENT)
                while sqlite3_step(exStmt) == SQLITE_ROW {
                    let exId = sqlite3_column_text(exStmt, 0).map { String(cString: $0) } ?? ""
                    let name = sqlite3_column_text(exStmt, 1).map { String(cString: $0) } ?? ""
                    let videoFn = sqlite3_column_text(exStmt, 2).map { String(cString: $0) }
                    let muscleHint = sqlite3_column_text(exStmt, 3).map { String(cString: $0) } ?? "Strength"
                    let isCustom = sqlite3_column_int(exStmt, 4) != 0
                    let trackingType = sqlite3_column_text(exStmt, 5).map { String(cString: $0) } ?? "weighted"
                    let equipment = sqlite3_column_text(exStmt, 6).map { String(cString: $0) } ?? ""
                    let notes = sqlite3_column_text(exStmt, 7).map { String(cString: $0) } ?? ""

                    let sets = setsForExercise(sessionDate: sessionDate, exerciseId: exId)
                    let doneHere = sets.filter { $0.completed }.count
                    sectionSetsDone += doneHere
                    if doneHere > 0 { sectionCompletedEx += 1 }

                    let (sugReps, sugWeight) = lastCompletedSetSuggestion(exerciseId: exId)
                    let prog = computeProgressionInternal(exerciseId: exId, trackingType: trackingType)

                    exItems.append(
                        RoutineExerciseItem(
                            id: exId,
                            name: name,
                            videoFilename: videoFn,
                            muscleHint: muscleHint,
                            isCustom: isCustom,
                            trackingType: trackingType,
                            equipment: equipment,
                            notes: notes,
                            sets: sets,
                            suggestedReps: sugReps,
                            suggestedWeight: sugWeight,
                            progression: prog
                        )
                    )
                }
            }
            sqlite3_finalize(exStmt)

            totalSetsDone += sectionSetsDone
            totalCompletedExercises += sectionCompletedEx
            totalExCount += exItems.count

            sections.append(
                DayRoutineSection(
                    id: rt.id,
                    title: rt.title,
                    emblem: rt.emblem,
                    exercises: exItems,
                    completedExercises: sectionCompletedEx,
                    totalExercises: exItems.count,
                    totalSetsDone: sectionSetsDone
                )
            )
        }

        let pct = totalExCount == 0 ? 100 : Int(round((Double(totalCompletedExercises) / Double(totalExCount)) * 100.0))
        return DayWorkout(
            dayOfWeek: dayOfWeek,
            dayName: dayNames[clampedDow],
            dayFullName: dayFullNames[clampedDow],
            sessionDate: sessionDate,
            displayDateShort: shortDate,
            isToday: sessionDate == todayStr,
            scheduleSource: resolved.source,
            routines: sections,
            completionPct: pct,
            completedExercises: totalCompletedExercises,
            totalExercises: totalExCount,
            totalSetsDone: totalSetsDone
        )
    }

    private func setsForExercise(sessionDate: String, exerciseId: String) -> [WorkoutSet] {
        guard let db = db else { return [] }
        var out: [WorkoutSet] = []
        var stmt: OpaquePointer?
        let sql = """
        SELECT id, set_number, reps, weight, completed
        FROM workout_sets
        WHERE session_date = ? AND exercise_id = ?
        ORDER BY set_number ASC, id ASC
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, sessionDate, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, exerciseId, -1, SQLITE_TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(
                    WorkoutSet(
                        id: sqlite3_column_int64(stmt, 0),
                        setNumber: Int(sqlite3_column_int(stmt, 1)),
                        reps: Int(sqlite3_column_int(stmt, 2)),
                        weight: sqlite3_column_double(stmt, 3),
                        completed: sqlite3_column_int(stmt, 4) != 0
                    )
                )
            }
        }
        sqlite3_finalize(stmt)
        return out
    }

    private func lastCompletedSetSuggestion(exerciseId: String) -> (Int, Double) {
        guard let db = db else { return (8, 0) }
        var stmt: OpaquePointer?
        let sql = """
        SELECT reps, weight
        FROM workout_sets
        WHERE exercise_id = ? AND completed = 1
        ORDER BY session_date DESC, set_number DESC
        LIMIT 1
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, exerciseId, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let r = Int(sqlite3_column_int(stmt, 0))
                let w = sqlite3_column_double(stmt, 1)
                sqlite3_finalize(stmt)
                return (r, w)
            }
        }
        sqlite3_finalize(stmt)
        return (8, 0)
    }

    /// Aggregates up to the last 8 completed workout sessions for an exercise and computes a linear
    /// regression slope to determine progression status (`yes`, `no`, `flat`, `baseline`).
    /// Note: `workout_sets.reps` stores duration in seconds when `trackingType == "timed"`, so
    /// `metricUnit` is `"sec"` for timed movements, `"reps"` for zero-weight bodyweight work, and `"vol"` otherwise.
    private func computeProgressionInternal(exerciseId: String, trackingType: String = "weighted") -> ProgressionSummary {
        guard let db = db else { return .empty }
        var rawRows: [(date: String, totalVol: Double, totalReps: Int, maxW: Double, count: Int)] = []
        var stmt: OpaquePointer?
        let sql = """
        SELECT session_date,
               SUM(reps * weight) AS total_volume,
               SUM(reps) AS total_reps,
               MAX(weight) AS max_weight,
               COUNT(*) AS set_count
        FROM workout_sets
        WHERE exercise_id = ? AND completed = 1
        GROUP BY session_date
        ORDER BY session_date DESC
        LIMIT 8
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, exerciseId, -1, SQLITE_TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let d = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let vol = sqlite3_column_double(stmt, 1)
                let reps = Int(sqlite3_column_int(stmt, 2))
                let maxW = sqlite3_column_double(stmt, 3)
                let cnt = Int(sqlite3_column_int(stmt, 4))
                rawRows.append((d, vol, reps, maxW, cnt))
            }
        }
        sqlite3_finalize(stmt)

        let ordered = Array(rawRows.reversed())
        guard !ordered.isEmpty else { return .empty }

        let isTimed = trackingType == "timed"
        let useRepsOnly = isTimed || ordered.allSatisfy { $0.totalVol == 0.0 }
        let metricUnit = isTimed ? "sec" : (useRepsOnly ? "reps" : "vol")

        var sessions: [SessionVolumePoint] = []
        var ys: [Double] = []
        for row in ordered {
            let val = useRepsOnly ? Double(row.totalReps) : row.totalVol
            let rounded = (val * 10.0).rounded() / 10.0
            ys.append(rounded)
            sessions.append(
                SessionVolumePoint(
                    date: row.date,
                    volume: rounded,
                    maxWeight: (row.maxW * 10.0).rounded() / 10.0,
                    sets: row.count
                )
            )
        }

        let n = ys.count
        if n < 2 {
            return ProgressionSummary(
                status: .baseline,
                movingMore: nil,
                slope: 0,
                deltaPct: 0,
                metricUnit: metricUnit,
                latestVolume: ys.last ?? 0,
                sessions: sessions,
                trendPoints: ys
            )
        }

        let xMean = Double(n - 1) / 2.0
        let yMean = ys.reduce(0, +) / Double(n)
        var denom = 0.0
        var numer = 0.0
        for i in 0..<n {
            let dx = Double(i) - xMean
            denom += dx * dx
            numer += dx * (ys[i] - yMean)
        }
        let slope = denom != 0 ? (numer / denom) : 0.0
        let intercept = yMean - slope * xMean
        let trendPoints = (0..<n).map { i -> Double in
            let v = max(0.0, intercept + slope * Double(i))
            return (v * 10.0).rounded() / 10.0
        }

        let firstY = ys[0]
        let lastY = ys[n - 1]
        let deltaPct = firstY > 0 ? (((lastY - firstY) / firstY) * 1000.0).rounded() / 10.0 : 0.0

        let movingMore: Bool
        let status: ProgressionStatus
        if slope > 0.0001 {
            movingMore = true
            status = .yes
        } else {
            movingMore = false
            status = abs(deltaPct) <= 1.0 ? .flat : .no
        }

        return ProgressionSummary(
            status: status,
            movingMore: movingMore,
            slope: (slope * 1000.0).rounded() / 1000.0,
            deltaPct: deltaPct,
            metricUnit: metricUnit,
            latestVolume: lastY,
            sessions: sessions,
            trendPoints: trendPoints
        )
    }

    func listRoutines() -> [RoutineSummary] {
        queue.sync {
            guard let db = db else { return [] }
            var rows: [(String, String, String)] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT id, title, COALESCE(emblem, '') FROM routines ORDER BY created_at DESC, title ASC", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    let emblem = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                    if !id.isEmpty { rows.append((id, title, emblem)) }
                }
            }
            sqlite3_finalize(stmt)

            return rows.map { (rid, title, emblem) in
                var exercises: [Exercise] = []
                var exStmt: OpaquePointer?
                let exSql = """
                SELECT e.id, e.name, e.video_filename, e.muscle_hint, e.is_custom,
                       COALESCE(e.tracking_type, 'weighted'), COALESCE(e.equipment, ''), COALESCE(e.notes, '')
                FROM routine_items ri
                JOIN exercises e ON e.id = ri.exercise_id
                WHERE ri.routine_id = ?
                ORDER BY ri.sort_order ASC, ri.id ASC
                """
                if sqlite3_prepare_v2(db, exSql, -1, &exStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(exStmt, 1, rid, -1, SQLITE_TRANSIENT)
                    while sqlite3_step(exStmt) == SQLITE_ROW {
                        let exId = sqlite3_column_text(exStmt, 0).map { String(cString: $0) } ?? ""
                        let name = sqlite3_column_text(exStmt, 1).map { String(cString: $0) } ?? ""
                        let vf = sqlite3_column_text(exStmt, 2).map { String(cString: $0) }
                        let mh = sqlite3_column_text(exStmt, 3).map { String(cString: $0) } ?? "Strength"
                        let isCustom = sqlite3_column_int(exStmt, 4) != 0
                        let tt = sqlite3_column_text(exStmt, 5).map { String(cString: $0) } ?? "weighted"
                        let eq = sqlite3_column_text(exStmt, 6).map { String(cString: $0) } ?? ""
                        let nt = sqlite3_column_text(exStmt, 7).map { String(cString: $0) } ?? ""
                        exercises.append(Exercise(id: exId, name: name, videoFilename: vf, muscleHint: mh, isCustom: isCustom, trackingType: tt, equipment: eq, notes: nt))
                    }
                }
                sqlite3_finalize(exStmt)

                var days: [Int] = []
                var wsStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT day_of_week FROM weekly_schedule WHERE routine_id = ? ORDER BY day_of_week ASC", -1, &wsStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(wsStmt, 1, rid, -1, SQLITE_TRANSIENT)
                    while sqlite3_step(wsStmt) == SQLITE_ROW {
                        days.append(Int(sqlite3_column_int(wsStmt, 0)))
                    }
                }
                sqlite3_finalize(wsStmt)

                return RoutineSummary(id: rid, title: title, emblem: emblem, exercises: exercises, assignedWeekdays: days)
            }
        }
    }

    @discardableResult
    func createRoutine(title: String, emblem: String = "", exerciseIds: [String], assignWeekdays: [Int], assignDate: String?) -> String {
        queue.sync {
            let rid = "rt_\(UUID().uuidString.prefix(8).lowercased())"
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalTitle = cleanTitle.isEmpty ? "Custom Routine" : cleanTitle
            let cleanEmblem = RoutineEmblemCatalog.sanitize(emblem)
            let stamp = Self.nowISO()

            exec("BEGIN IMMEDIATE;")
            insertRoutineRowInternal(id: rid, title: finalTitle, emblem: cleanEmblem, createdAt: stamp, updatedAt: stamp)
            for (idx, exId) in exerciseIds.enumerated() {
                insertRoutineItemInternal(routineId: rid, exerciseId: exId, sortOrder: idx)
            }
            for dow in Set(assignWeekdays) where (0...6).contains(dow) {
                assignWeekdayInternal(routineId: rid, dayOfWeek: dow, syncOverrideForDate: nil)
            }
            if let dateStr = assignDate, !dateStr.isEmpty {
                addRoutineToDateInternal(routineId: rid, sessionDate: dateStr)
            }
            exec("COMMIT;")
            return rid
        }
    }

    func updateRoutine(id: String, title: String, emblem: String = "", exerciseIds: [String], assignWeekdays: [Int]) {
        queue.sync {
            guard let db = db else { return }
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalTitle = cleanTitle.isEmpty ? "Custom Routine" : cleanTitle
            let cleanEmblem = RoutineEmblemCatalog.sanitize(emblem)
            let stamp = Self.nowISO()
            let targetDays = Set(assignWeekdays.filter { (0...6).contains($0) })

            exec("BEGIN IMMEDIATE;")
            var updStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE routines SET title = ?, emblem = ?, updated_at = ? WHERE id = ?", -1, &updStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(updStmt, 1, finalTitle, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(updStmt, 2, cleanEmblem, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(updStmt, 3, stamp, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(updStmt, 4, id, -1, SQLITE_TRANSIENT)
                sqlite3_step(updStmt)
            }
            sqlite3_finalize(updStmt)

            var delItemsStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM routine_items WHERE routine_id = ?", -1, &delItemsStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(delItemsStmt, 1, id, -1, SQLITE_TRANSIENT)
                sqlite3_step(delItemsStmt)
            }
            sqlite3_finalize(delItemsStmt)

            for (idx, exId) in exerciseIds.enumerated() {
                insertRoutineItemInternal(routineId: id, exerciseId: exId, sortOrder: idx)
            }

            var existingDays: [Int] = []
            var curStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT day_of_week FROM weekly_schedule WHERE routine_id = ?", -1, &curStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(curStmt, 1, id, -1, SQLITE_TRANSIENT)
                while sqlite3_step(curStmt) == SQLITE_ROW {
                    existingDays.append(Int(sqlite3_column_int(curStmt, 0)))
                }
            }
            sqlite3_finalize(curStmt)

            for dow in existingDays where !targetDays.contains(dow) {
                var rmStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "DELETE FROM weekly_schedule WHERE day_of_week = ? AND routine_id = ?", -1, &rmStmt, nil) == SQLITE_OK {
                    sqlite3_bind_int(rmStmt, 1, Int32(dow))
                    sqlite3_bind_text(rmStmt, 2, id, -1, SQLITE_TRANSIENT)
                    sqlite3_step(rmStmt)
                }
                sqlite3_finalize(rmStmt)
            }

            for dow in targetDays {
                assignWeekdayInternal(routineId: id, dayOfWeek: dow, syncOverrideForDate: nil)
            }
            exec("COMMIT;")
        }
    }

    func updateRoutineTitle(routineId: String, title: String) {
        queue.sync {
            guard let db = db else { return }
            let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE routines SET title = ?, updated_at = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, clean, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, Self.nowISO(), -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, routineId, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func updateRoutineDetails(routineId: String, title: String, emblem: String) {
        queue.sync {
            guard let db = db else { return }
            let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanEmblem = RoutineEmblemCatalog.sanitize(emblem)
            if clean.isEmpty {
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "UPDATE routines SET emblem = ?, updated_at = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, cleanEmblem, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 2, Self.nowISO(), -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 3, routineId, -1, SQLITE_TRANSIENT)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
                return
            }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE routines SET title = ?, emblem = ?, updated_at = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, clean, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, cleanEmblem, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, Self.nowISO(), -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, routineId, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func deleteRoutine(id: String) {
        queue.sync {
            guard let db = db else { return }
            exec("BEGIN IMMEDIATE;")
            for sql in [
                "DELETE FROM routine_items WHERE routine_id = ?",
                "DELETE FROM weekly_schedule WHERE routine_id = ?",
                "DELETE FROM date_schedule WHERE routine_id = ?",
                "DELETE FROM routines WHERE id = ?",
            ] {
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            }
            exec("COMMIT;")
        }
    }

    func deleteAllRoutines() {
        queue.sync {
            exec("BEGIN IMMEDIATE;")
            exec("DELETE FROM routine_items;")
            exec("DELETE FROM weekly_schedule;")
            exec("DELETE FROM date_schedule;")
            exec("DELETE FROM routines;")
            exec("COMMIT;")
        }
    }

    func toggleRoutineWeekday(routineId: String, dayOfWeek: Int, clearOverrideForDate: String? = nil) {
        queue.sync {
            guard (0...6).contains(dayOfWeek) else { return }
            let exists = scalarInt(
                "SELECT COUNT(*) FROM weekly_schedule WHERE day_of_week = ? AND routine_id = ?",
                args: ["\(dayOfWeek)", routineId]
            ) > 0

            if exists {
                removeRoutineFromWeekdayInternal(routineId: routineId, dayOfWeek: dayOfWeek, syncOverrideForDate: clearOverrideForDate)
            } else {
                assignWeekdayInternal(routineId: routineId, dayOfWeek: dayOfWeek, syncOverrideForDate: clearOverrideForDate)
            }
        }
    }

    func assignRoutineToWeekday(routineId: String, dayOfWeek: Int, clearOverrideForDate: String?) {
        queue.sync {
            assignWeekdayInternal(routineId: routineId, dayOfWeek: dayOfWeek, syncOverrideForDate: clearOverrideForDate)
        }
    }

    func removeRoutineFromWeekday(routineId: String, dayOfWeek: Int, clearOverrideForDate: String?) {
        queue.sync {
            removeRoutineFromWeekdayInternal(routineId: routineId, dayOfWeek: dayOfWeek, syncOverrideForDate: clearOverrideForDate)
        }
    }

    private func assignWeekdayInternal(routineId: String, dayOfWeek: Int, syncOverrideForDate: String?) {
        guard let db = db, (0...6).contains(dayOfWeek) else { return }
        let exists = scalarInt(
            "SELECT COUNT(*) FROM weekly_schedule WHERE day_of_week = ? AND routine_id = ?",
            args: ["\(dayOfWeek)", routineId]
        ) > 0
        if !exists {
            var nextOrd = 0
            var ordStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM weekly_schedule WHERE day_of_week = ?", -1, &ordStmt, nil) == SQLITE_OK {
                sqlite3_bind_int(ordStmt, 1, Int32(dayOfWeek))
                if sqlite3_step(ordStmt) == SQLITE_ROW {
                    nextOrd = Int(sqlite3_column_int(ordStmt, 0))
                }
            }
            sqlite3_finalize(ordStmt)

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO weekly_schedule (day_of_week, routine_id, sort_order) VALUES (?, ?, ?)", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int(stmt, 1, Int32(dayOfWeek))
                sqlite3_bind_text(stmt, 2, routineId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 3, Int32(nextOrd))
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }

        if let dateStr = syncOverrideForDate, !dateStr.isEmpty {
            let hasDateRows = scalarInt("SELECT COUNT(*) FROM date_schedule WHERE session_date = ?", args: [dateStr]) > 0
            if hasDateRows {
                addRoutineToDateInternal(routineId: routineId, sessionDate: dateStr)
            }
        }
    }

    private func removeRoutineFromWeekdayInternal(routineId: String, dayOfWeek: Int, syncOverrideForDate: String?) {
        guard let db = db, (0...6).contains(dayOfWeek) else { return }
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM weekly_schedule WHERE day_of_week = ? AND routine_id = ?", -1, &delStmt, nil) == SQLITE_OK {
            sqlite3_bind_int(delStmt, 1, Int32(dayOfWeek))
            sqlite3_bind_text(delStmt, 2, routineId, -1, SQLITE_TRANSIENT)
            sqlite3_step(delStmt)
        }
        sqlite3_finalize(delStmt)

        if let dateStr = syncOverrideForDate, !dateStr.isEmpty {
            let hasDateRows = scalarInt("SELECT COUNT(*) FROM date_schedule WHERE session_date = ?", args: [dateStr]) > 0
            if hasDateRows {
                var rmStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "DELETE FROM date_schedule WHERE session_date = ? AND routine_id = ?", -1, &rmStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(rmStmt, 1, dateStr, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(rmStmt, 2, routineId, -1, SQLITE_TRANSIENT)
                    sqlite3_step(rmStmt)
                }
                sqlite3_finalize(rmStmt)
            }
        }
    }

    func clearWeekdaySchedule(dayOfWeek: Int, clearOverrideForDate: String?) {
        queue.sync {
            guard let db = db else { return }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM weekly_schedule WHERE day_of_week = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int(stmt, 1, Int32(dayOfWeek))
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)

            if let dateStr = clearOverrideForDate, !dateStr.isEmpty {
                var rmStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "DELETE FROM date_schedule WHERE session_date = ?", -1, &rmStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(rmStmt, 1, dateStr, -1, SQLITE_TRANSIENT)
                    sqlite3_step(rmStmt)
                }
                sqlite3_finalize(rmStmt)
            }
        }
    }

    private func materializeWeeklyIntoDateIfNeeded(sessionDate: String) {
        guard let db = db else { return }
        let existingCount = scalarInt("SELECT COUNT(*) FROM date_schedule WHERE session_date = ?", args: [sessionDate])
        guard existingCount == 0 else { return }

        let dow = Self.weekdayIndex(Self.dateFromISO(sessionDate))
        var weeklyRows: [(String, Int)] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT routine_id, sort_order FROM weekly_schedule WHERE day_of_week = ? ORDER BY sort_order ASC, rowid ASC", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(dow))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let rid = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let ord = Int(sqlite3_column_int(stmt, 1))
                if !rid.isEmpty {
                    weeklyRows.append((rid, ord))
                }
            }
        }
        sqlite3_finalize(stmt)

        for (rid, ord) in weeklyRows {
            var insStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO date_schedule (session_date, routine_id, sort_order) VALUES (?, ?, ?)", -1, &insStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(insStmt, 1, sessionDate, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(insStmt, 2, rid, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(insStmt, 3, Int32(ord))
                sqlite3_step(insStmt)
            }
            sqlite3_finalize(insStmt)
        }
    }

    func assignRoutineToDate(routineId: String, sessionDate: String) {
        queue.sync {
            addRoutineToDateInternal(routineId: routineId, sessionDate: sessionDate)
        }
    }

    func removeRoutineFromDate(routineId: String, sessionDate: String) {
        queue.sync {
            guard let db = db else { return }
            materializeWeeklyIntoDateIfNeeded(sessionDate: sessionDate)
            var delStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM date_schedule WHERE session_date = ? AND routine_id = ?", -1, &delStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(delStmt, 1, sessionDate, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(delStmt, 2, routineId, -1, SQLITE_TRANSIENT)
                sqlite3_step(delStmt)
            }
            sqlite3_finalize(delStmt)

            let remaining = scalarInt("SELECT COUNT(*) FROM date_schedule WHERE session_date = ? AND routine_id != ''", args: [sessionDate])
            if remaining == 0 {
                var clStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO date_schedule (session_date, routine_id, sort_order) VALUES (?, '', 0)", -1, &clStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(clStmt, 1, sessionDate, -1, SQLITE_TRANSIENT)
                    sqlite3_step(clStmt)
                }
                sqlite3_finalize(clStmt)
            }
        }
    }

    private func addRoutineToDateInternal(routineId: String, sessionDate: String) {
        guard let db = db, !routineId.isEmpty else { return }
        materializeWeeklyIntoDateIfNeeded(sessionDate: sessionDate)

        var clrStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM date_schedule WHERE session_date = ? AND routine_id = ''", -1, &clrStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(clrStmt, 1, sessionDate, -1, SQLITE_TRANSIENT)
            sqlite3_step(clrStmt)
        }
        sqlite3_finalize(clrStmt)

        let exists = scalarInt(
            "SELECT COUNT(*) FROM date_schedule WHERE session_date = ? AND routine_id = ?",
            args: [sessionDate, routineId]
        ) > 0
        guard !exists else { return }

        var nextOrd = 0
        var ordStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM date_schedule WHERE session_date = ?", -1, &ordStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(ordStmt, 1, sessionDate, -1, SQLITE_TRANSIENT)
            if sqlite3_step(ordStmt) == SQLITE_ROW {
                nextOrd = Int(sqlite3_column_int(ordStmt, 0))
            }
        }
        sqlite3_finalize(ordStmt)

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO date_schedule (session_date, routine_id, sort_order) VALUES (?, ?, ?)", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, sessionDate, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, routineId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(nextOrd))
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func clearDateSchedule(sessionDate: String) {
        queue.sync {
            guard let db = db else { return }
            var delStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM date_schedule WHERE session_date = ?", -1, &delStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(delStmt, 1, sessionDate, -1, SQLITE_TRANSIENT)
                sqlite3_step(delStmt)
            }
            sqlite3_finalize(delStmt)

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO date_schedule (session_date, routine_id, sort_order) VALUES (?, '', 0)", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, sessionDate, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func addExerciseToRoutine(routineId: String, exerciseId: String) {
        queue.sync {
            guard let db = db else { return }
            var maxOrd = -1
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(sort_order), -1) FROM routine_items WHERE routine_id = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, routineId, -1, SQLITE_TRANSIENT)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    maxOrd = Int(sqlite3_column_int(stmt, 0))
                }
            }
            sqlite3_finalize(stmt)
            insertRoutineItemInternal(routineId: routineId, exerciseId: exerciseId, sortOrder: maxOrd + 1)
        }
    }

    func removeExerciseFromRoutine(routineId: String, exerciseId: String) {
        queue.sync {
            guard let db = db else { return }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM routine_items WHERE routine_id = ? AND exercise_id = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, routineId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, exerciseId, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func createCustomExercise(
        name: String,
        muscleHint: String = "Custom",
        trackingType: String = "weighted",
        equipment: String = "",
        notes: String = "",
        videoFilename: String? = nil,
        routineId: String? = nil
    ) -> Exercise {
        queue.sync {
            let exId = "cust_\(UUID().uuidString.prefix(8).lowercased())"
            let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanMuscle = muscleHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom" : muscleHint.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanTracking = trackingType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "weighted" : trackingType
            let cleanEquip = equipment.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let stamp = Self.nowISO()
            if let db = db {
                var stmt: OpaquePointer?
                let sql = """
                INSERT INTO exercises (id, name, video_filename, muscle_hint, is_custom, tracking_type, equipment, notes, created_at)
                VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?)
                """
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, exId, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 2, cleanName, -1, SQLITE_TRANSIENT)
                    if let vf = videoFilename, !vf.isEmpty {
                        sqlite3_bind_text(stmt, 3, vf, -1, SQLITE_TRANSIENT)
                    } else {
                        sqlite3_bind_null(stmt, 3)
                    }
                    sqlite3_bind_text(stmt, 4, cleanMuscle, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 5, cleanTracking, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 6, cleanEquip, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 7, cleanNotes, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 8, stamp, -1, SQLITE_TRANSIENT)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)

                if let rid = routineId, !rid.isEmpty {
                    var maxOrd = -1
                    var ordStmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(sort_order), -1) FROM routine_items WHERE routine_id = ?", -1, &ordStmt, nil) == SQLITE_OK {
                        sqlite3_bind_text(ordStmt, 1, rid, -1, SQLITE_TRANSIENT)
                        if sqlite3_step(ordStmt) == SQLITE_ROW {
                            maxOrd = Int(sqlite3_column_int(ordStmt, 0))
                        }
                    }
                    sqlite3_finalize(ordStmt)
                    insertRoutineItemInternal(routineId: rid, exerciseId: exId, sortOrder: maxOrd + 1)
                }
            }
            return Exercise(
                id: exId,
                name: cleanName,
                videoFilename: videoFilename,
                muscleHint: cleanMuscle,
                isCustom: true,
                trackingType: cleanTracking,
                equipment: cleanEquip,
                notes: cleanNotes
            )
        }
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
        queue.sync {
            guard let db = db else { return }
            let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanName.isEmpty else { return }
            let cleanMuscle = muscleHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom" : muscleHint.trimmingCharacters(in: .whitespacesAndNewlines)
            var stmt: OpaquePointer?
            let sql = """
            UPDATE exercises
            SET name = ?, muscle_hint = ?, tracking_type = ?, equipment = ?, notes = ?, video_filename = ?
            WHERE id = ? AND is_custom = 1
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, cleanName, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, cleanMuscle, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, trackingType, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, equipment.trimmingCharacters(in: .whitespacesAndNewlines), -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 5, notes.trimmingCharacters(in: .whitespacesAndNewlines), -1, SQLITE_TRANSIENT)
                if let vf = videoFilename, !vf.isEmpty {
                    sqlite3_bind_text(stmt, 6, vf, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 6)
                }
                sqlite3_bind_text(stmt, 7, id, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func deleteCustomExercise(id: String) {
        queue.sync {
            guard let db = db else { return }
            exec("BEGIN IMMEDIATE;")
            for sql in [
                "DELETE FROM routine_items WHERE exercise_id = ?",
                "DELETE FROM exercises WHERE id = ? AND is_custom = 1",
            ] {
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            }
            exec("COMMIT;")
        }
    }

    func listCustomExercises() -> [Exercise] {
        queue.sync {
            guard let db = db else { return [] }
            var out: [Exercise] = []
            var stmt: OpaquePointer?
            let sql = """
            SELECT id, name, video_filename, COALESCE(muscle_hint, 'Custom'),
                   COALESCE(tracking_type, 'weighted'), COALESCE(equipment, ''), COALESCE(notes, '')
            FROM exercises WHERE is_custom = 1 ORDER BY name ASC
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    let vf = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                    let mh = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "Custom"
                    let tt = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "weighted"
                    let eq = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
                    let nt = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
                    out.append(Exercise(id: id, name: name, videoFilename: vf, muscleHint: mh, isCustom: true, trackingType: tt, equipment: eq, notes: nt))
                }
            }
            sqlite3_finalize(stmt)
            return out
        }
    }

    func upsertWorkoutSet(
        id: Int64?,
        sessionDate: String,
        exerciseId: String,
        reps: Int,
        weight: Double,
        completed: Bool
    ) {
        queue.sync {
            guard let db = db else { return }
            if let id = id {
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "UPDATE workout_sets SET reps = ?, weight = ?, completed = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_int(stmt, 1, Int32(max(0, reps)))
                    sqlite3_bind_double(stmt, 2, max(0, weight))
                    sqlite3_bind_int(stmt, 3, completed ? 1 : 0)
                    sqlite3_bind_int64(stmt, 4, id)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            } else {
                var nextNum = 1
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(set_number), 0) + 1 FROM workout_sets WHERE session_date = ? AND exercise_id = ?", -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, sessionDate, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 2, exerciseId, -1, SQLITE_TRANSIENT)
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        nextNum = Int(sqlite3_column_int(stmt, 0))
                    }
                }
                sqlite3_finalize(stmt)
                insertWorkoutSetRaw(
                    sessionDate: sessionDate,
                    exerciseId: exerciseId,
                    setNumber: nextNum,
                    reps: max(0, reps),
                    weight: max(0, weight),
                    completed: completed,
                    stamp: Self.nowISO()
                )
            }
        }
    }

    func deleteWorkoutSet(id: Int64) {
        queue.sync {
            guard let db = db else { return }
            var sDate = ""
            var exId = ""
            var infoStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT session_date, exercise_id FROM workout_sets WHERE id = ?", -1, &infoStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(infoStmt, 1, id)
                if sqlite3_step(infoStmt) == SQLITE_ROW {
                    sDate = sqlite3_column_text(infoStmt, 0).map { String(cString: $0) } ?? ""
                    exId = sqlite3_column_text(infoStmt, 1).map { String(cString: $0) } ?? ""
                }
            }
            sqlite3_finalize(infoStmt)

            var delStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM workout_sets WHERE id = ?", -1, &delStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(delStmt, 1, id)
                sqlite3_step(delStmt)
            }
            sqlite3_finalize(delStmt)

            if !sDate.isEmpty && !exId.isEmpty {
                var remIds: [Int64] = []
                var remStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT id FROM workout_sets WHERE session_date = ? AND exercise_id = ? ORDER BY set_number ASC, id ASC", -1, &remStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(remStmt, 1, sDate, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(remStmt, 2, exId, -1, SQLITE_TRANSIENT)
                    while sqlite3_step(remStmt) == SQLITE_ROW {
                        remIds.append(sqlite3_column_int64(remStmt, 0))
                    }
                }
                sqlite3_finalize(remStmt)
                for (idx, rid) in remIds.enumerated() {
                    var upStmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, "UPDATE workout_sets SET set_number = ? WHERE id = ?", -1, &upStmt, nil) == SQLITE_OK {
                        sqlite3_bind_int(upStmt, 1, Int32(idx + 1))
                        sqlite3_bind_int64(upStmt, 2, rid)
                        sqlite3_step(upStmt)
                    }
                    sqlite3_finalize(upStmt)
                }
            }
        }
    }

    // MARK: - Fuzzy Exercise Search (588 MoveKit + Custom)

    func fuzzySearchExercises(
        query: String,
        region: MuscleRegion = .all,
        subGroup: MuscleSubGroup? = nil,
        limit: Int = 25
    ) -> [Exercise] {
        queue.sync {
            guard let db = db else { return [] }
            var all: [Exercise] = []
            var stmt: OpaquePointer?
            let sql = """
            SELECT id, name, video_filename, muscle_hint, is_custom,
                   COALESCE(tracking_type, 'weighted'), COALESCE(equipment, ''), COALESCE(notes, '')
            FROM exercises ORDER BY is_custom DESC, name ASC
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    let vf = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                    let mh = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "Strength"
                    let cust = sqlite3_column_int(stmt, 4) != 0
                    let tt = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "weighted"
                    let eq = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
                    let nt = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? ""
                    all.append(Exercise(id: id, name: name, videoFilename: vf, muscleHint: mh, isCustom: cust, trackingType: tt, equipment: eq, notes: nt))
                }
            }
            sqlite3_finalize(stmt)

            let filtered = (region == .all && subGroup == nil)
                ? all
                : all.filter { region.matches(muscleHint: $0.muscleHint, subGroup: subGroup) }

            let qNorm = Self.normText(query)
            if qNorm.isEmpty {
                return Array(filtered.prefix(limit))
            }

            let aliases: [String: String] = [
                "rdl": "romanian deadlift",
                "rdls": "romanian deadlift",
                "ohp": "overhead press",
                "db": "dumbbell",
                "bb": "barbell",
                "kb": "kettlebell",
                "bw": "bodyweight",
                "bi": "biceps",
                "bis": "biceps",
                "bicep": "biceps curl",
                "biceps": "biceps curl",
                "tri": "triceps",
                "tris": "triceps",
                "tricep": "triceps pushdown skullcrusher",
                "triceps": "triceps pushdown skullcrusher",
                "delt": "delts",
                "delts": "delts",
                "pec": "chest",
                "pecs": "chest",
                "quad": "quads",
                "quads": "quads",
                "ham": "hamstrings",
                "hams": "hamstrings",
                "glute": "glutes",
                "glutes": "glutes",
                "lat": "lats",
                "lats": "lats",
                "calf": "calves",
                "calves": "calves",
                "trap": "traps",
                "traps": "traps",
                "forearm": "forearms",
                "forearms": "forearms",
                "oblique": "obliques",
                "obliques": "obliques",
                "abs": "abs core abdominal",
                "pullup": "pull up",
                "pullups": "pull up",
                "pushup": "push up",
                "pushups": "push up",
                "chinup": "chin up",
                "chinups": "chin up",
            ]

            var expanded: [String] = []
            for tok in qNorm.split(separator: " ").map(String.init) {
                if let mapped = aliases[tok] {
                    expanded.append(contentsOf: mapped.split(separator: " ").map(String.init))
                } else {
                    expanded.append(tok)
                }
            }
            let qTokens = expanded.map(Self.singularize)
            let qCompact = qTokens.joined()

            var scored: [(score: Double, item: Exercise)] = []
            for ex in filtered {
                let cNorm = Self.normText(ex.name)
                let cTokens = cNorm.split(separator: " ").map { Self.singularize(String($0)) }
                let cCompact = cTokens.joined()
                let mNorm = Self.normText(ex.muscleHint)
                let haystack = "\(cNorm) \(mNorm) \(cCompact)"

                var score = 0.0
                if cNorm == qNorm || cCompact == qCompact {
                    score = 100.0
                } else if cNorm.hasPrefix(qNorm) || cCompact.hasPrefix(qCompact) {
                    score = 95.0
                } else if qTokens.allSatisfy({ haystack.contains($0) }) {
                    let hits = qTokens.filter { cNorm.contains($0) || cCompact.contains($0) }.count
                    score = 82.0 + (Double(hits) / Double(max(1, qTokens.count))) * 10.0
                } else {
                    let candAllTokens = cTokens + mNorm.split(separator: " ").map { Self.singularize(String($0)) }
                    var ratios: [Double] = []
                    for qt in qTokens {
                        var best = 0.0
                        for ct in candAllTokens {
                            if ct.contains(qt) {
                                best = max(best, 0.92)
                            } else {
                                best = max(best, Self.similarity(qt, ct))
                            }
                        }
                        ratios.append(best)
                    }
                    let minR = ratios.min() ?? 0.0
                    let avgR = ratios.isEmpty ? 0.0 : ratios.reduce(0, +) / Double(ratios.count)
                    if minR >= 0.68 || avgR >= 0.74 {
                        score = 55.0 + avgR * 24.0
                    } else {
                        let fullR = Self.similarity(qCompact, cCompact)
                        if fullR >= 0.58 {
                            score = 35.0 + fullR * 25.0
                        }
                    }
                }

                if score > 0 {
                    scored.append((score, ex))
                }
            }

            scored.sort { a, b in
                if a.score != b.score { return a.score > b.score }
                if a.item.isCustom != b.item.isCustom { return a.item.isCustom && !b.item.isCustom }
                return a.item.name < b.item.name
            }
            return Array(scored.prefix(limit).map(\.item))
        }
    }

    // MARK: - MoveKit Catalog & Body Weight Ledger API

    func moveKitCatalogEntries() -> [MoveKitManifestEntry] {
        if let manifestURL = Bundle.main.url(forResource: "movekit_manifest", withExtension: "json"),
           let data = try? Data(contentsOf: manifestURL),
           let entries = try? JSONDecoder().decode([MoveKitManifestEntry].self, from: data),
           !entries.isEmpty {
            return entries
        }
        return queue.sync {
            guard let db = db else { return [] }
            var fallback: [MoveKitManifestEntry] = []
            var stmt: OpaquePointer?
            let sql = "SELECT id, name, COALESCE(video_filename, ''), COALESCE(muscle_hint, 'Strength') FROM exercises WHERE is_custom = 0 ORDER BY name ASC"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    let vf = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                    let mh = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "Strength"
                    if !id.isEmpty {
                        fallback.append(MoveKitManifestEntry(id: id, name: name, videoFilename: vf, muscleHint: mh))
                    }
                }
            }
            sqlite3_finalize(stmt)
            return fallback
        }
    }

    /// Resolves candidate identifiers strictly against MoveKit (`is_custom = 0`) exercises,
    /// enforcing a hard boundary so non-MoveKit or hallucinated items are never returned.
    func exercisesForMoveKitIds(_ rawCandidates: [String]) -> [Exercise] {
        exercisesForCatalogIds(rawCandidates, includeCustom: false)
    }

    func allCatalogEntries(includeCustom: Bool) -> [MoveKitManifestEntry] {
        var base = moveKitCatalogEntries()
        if includeCustom {
            let customs = listCustomExercises().map {
                MoveKitManifestEntry(id: $0.id, name: $0.name, videoFilename: $0.videoFilename ?? "", muscleHint: $0.muscleHint)
            }
            base.append(contentsOf: customs)
        }
        return base
    }

    func exercisesForCatalogIds(_ rawCandidates: [String], includeCustom: Bool = true) -> [Exercise] {
        queue.sync {
            guard let db = db else { return [] }
            var byId: [String: Exercise] = [:]
            var byLowerId: [String: Exercise] = [:]
            var byNormName: [String: Exercise] = [:]

            var stmt: OpaquePointer?
            let whereClause = includeCustom ? "" : "WHERE is_custom = 0"
            let sql = """
            SELECT id, name, video_filename, muscle_hint, is_custom,
                   COALESCE(tracking_type, 'weighted'), COALESCE(equipment, ''), COALESCE(notes, '')
            FROM exercises \(whereClause)
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    let vf = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                    let mh = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "Strength"
                    let isCustom = sqlite3_column_int(stmt, 4) != 0
                    let tt = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "weighted"
                    let eq = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
                    let nt = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? ""
                    guard !id.isEmpty else { continue }
                    let ex = Exercise(id: id, name: name, videoFilename: vf, muscleHint: mh, isCustom: isCustom, trackingType: tt, equipment: eq, notes: nt)
                    byId[id] = ex
                    byLowerId[id.lowercased()] = ex
                    byNormName[Self.normText(name)] = ex
                }
            }
            sqlite3_finalize(stmt)

            var resolved: [Exercise] = []
            var seen = Set<String>()
            for raw in rawCandidates {
                let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { continue }
                let lower = clean.lowercased()
                let prefixed = (lower.hasPrefix("mk_") || lower.hasPrefix("cust_")) ? lower : "mk_\(lower.replacingOccurrences(of: " ", with: "-"))"

                let match: Exercise? =
                    byId[clean] ??
                    byLowerId[lower] ??
                    byLowerId[prefixed] ??
                    byNormName[Self.normText(clean)]

                if let ex = match, !seen.contains(ex.id) {
                    seen.insert(ex.id)
                    resolved.append(ex)
                }
            }
            return resolved
        }
    }

    func upsertWeightLog(logDate: String, weight: Double, unit: String, note: String = "") {
        queue.sync {
            guard let db = db, weight > 0 else { return }
            let cleanUnit = unit.lowercased() == "kg" ? "kg" : "lbs"
            let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
            let stamp = Self.nowISO()
            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO weight_logs (log_date, weight, unit, note, created_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(log_date) DO UPDATE SET
                weight = excluded.weight,
                unit = excluded.unit,
                note = excluded.note,
                created_at = excluded.created_at
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, logDate, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 2, (weight * 10.0).rounded() / 10.0)
                sqlite3_bind_text(stmt, 3, cleanUnit, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, cleanNote, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 5, stamp, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func deleteWeightLog(id: Int64) {
        queue.sync {
            guard let db = db else { return }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM weight_logs WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, id)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func listWeightLogs(displayUnit: String, limit: Int = 90) -> [WeightLogEntry] {
        queue.sync {
            guard let db = db else { return [] }
            let targetUnit = displayUnit.lowercased() == "kg" ? "kg" : "lbs"
            var out: [WeightLogEntry] = []
            var stmt: OpaquePointer?
            let sql = """
            SELECT id, log_date, weight, unit, note, created_at
            FROM weight_logs
            ORDER BY log_date DESC, id DESC
            LIMIT ?
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int(stmt, 1, Int32(max(1, limit)))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = sqlite3_column_int64(stmt, 0)
                    let dStr = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    let rawW = sqlite3_column_double(stmt, 2)
                    let rawU = (sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "lbs").lowercased()
                    let note = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                    let createdAt = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""

                    let converted: Double
                    if rawU == targetUnit {
                        converted = rawW
                    } else if rawU == "kg" && targetUnit == "lbs" {
                        converted = rawW * 2.20462262
                    } else {
                        converted = rawW / 2.20462262
                    }
                    let rounded = (converted * 10.0).rounded() / 10.0

                    out.append(
                        WeightLogEntry(
                            id: id,
                            logDate: dStr,
                            displayDate: Self.mediumDateLabel(dStr),
                            weight: rounded,
                            rawWeight: rawW,
                            rawUnit: rawU,
                            note: note,
                            createdAt: createdAt
                        )
                    )
                }
            }
            sqlite3_finalize(stmt)
            return out
        }
    }

    // MARK: - Recipes API

    func listRecipes() -> (saved: [Recipe], discover: [Recipe]) {
        queue.sync {
            guard let db = db else { return ([], []) }
            var saved: [Recipe] = []
            var discover: [Recipe] = []
            var stmt: OpaquePointer?
            let sql = """
            SELECT id, title, source_url, source_domain, prep_time, servings,
                   kcal, protein_g, carbs_g, fat_g, COALESCE(sodium_mg, 0), COALESCE(sugar_g, 0), COALESCE(cholesterol_mg, 0),
                   meal_type, dietary_tags, allergens,
                   ingredients, steps, image_path, image_source, is_saved,
                   discovered_at, saved_at
            FROM recipes
            ORDER BY is_saved DESC, COALESCE(saved_at, discovered_at) DESC
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let rec = Self.readRecipeRow(stmt!)
                    if rec.isSaved {
                        saved.append(rec)
                    } else {
                        discover.append(rec)
                    }
                }
            }
            sqlite3_finalize(stmt)
            return (saved, discover)
        }
    }

    func insertDiscoveredRecipes(_ recipes: [Recipe]) {
        queue.sync {
            for r in recipes {
                insertRecipeRow(r)
            }
            _ = runStorageJanitorInternal(aggressive: false)
        }
    }

    func toggleRecipeSaved(id: String) -> Recipe? {
        queue.sync {
            guard let db = db else { return nil }
            var stmt: OpaquePointer?
            var found: Recipe?
            if sqlite3_prepare_v2(
                db,
                """
                SELECT id, title, source_url, source_domain, prep_time, servings,
                       kcal, protein_g, carbs_g, fat_g, COALESCE(sodium_mg, 0), COALESCE(sugar_g, 0), COALESCE(cholesterol_mg, 0),
                       meal_type, dietary_tags, allergens,
                       ingredients, steps, image_path, image_source, is_saved,
                       discovered_at, saved_at
                FROM recipes WHERE id = ? LIMIT 1
                """,
                -1,
                &stmt,
                nil
            ) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    found = Self.readRecipeRow(stmt!)
                }
            }
            sqlite3_finalize(stmt)
            guard let existing = found else { return nil }

            let newSaved = !existing.isSaved
            var newImagePath = existing.imagePath
            if let imgPath = existing.imagePath {
                let srcURL = rootDir.appendingPathComponent("media/\(imgPath)")
                let fname = URL(fileURLWithPath: imgPath).lastPathComponent
                let dstDir = newSaved ? savedMediaDir : cacheMediaDir
                let dstURL = dstDir.appendingPathComponent(fname)
                if FileManager.default.fileExists(atPath: srcURL.path) && srcURL != dstURL {
                    try? FileManager.default.removeItem(at: dstURL)
                    try? FileManager.default.moveItem(at: srcURL, to: dstURL)
                }
                if FileManager.default.fileExists(atPath: dstURL.path) {
                    newImagePath = "\(newSaved ? "saved" : "cache")/\(fname)"
                }
            }

            let savedAt: String? = newSaved ? Self.nowISO() : nil
            var upStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE recipes SET is_saved = ?, image_path = ?, saved_at = ? WHERE id = ?", -1, &upStmt, nil) == SQLITE_OK {
                sqlite3_bind_int(upStmt, 1, newSaved ? 1 : 0)
                if let nip = newImagePath {
                    sqlite3_bind_text(upStmt, 2, nip, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(upStmt, 2)
                }
                if let sa = savedAt {
                    sqlite3_bind_text(upStmt, 3, sa, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(upStmt, 3)
                }
                sqlite3_bind_text(upStmt, 4, id, -1, SQLITE_TRANSIENT)
                sqlite3_step(upStmt)
            }
            sqlite3_finalize(upStmt)

            return Recipe(
                id: existing.id,
                title: existing.title,
                sourceURL: existing.sourceURL,
                sourceDomain: existing.sourceDomain,
                prepTime: existing.prepTime,
                servings: existing.servings,
                kcal: existing.kcal,
                proteinG: existing.proteinG,
                carbsG: existing.carbsG,
                fatG: existing.fatG,
                sodiumMg: existing.sodiumMg,
                sugarG: existing.sugarG,
                cholesterolMg: existing.cholesterolMg,
                mealType: existing.mealType,
                dietaryTags: existing.dietaryTags,
                allergens: existing.allergens,
                ingredients: existing.ingredients,
                steps: existing.steps,
                imagePath: newImagePath,
                imageSource: existing.imageSource,
                isSaved: newSaved,
                discoveredAt: existing.discoveredAt,
                savedAt: savedAt
            )
        }
    }

    func saveCookedPhoto(recipeId: String, rawImageData: Data) -> Bool {
        saveRecipeImage(recipeId: recipeId, rawImageData: rawImageData, source: "custom_photo")
    }

    func saveRecipeImage(recipeId: String, rawImageData: Data, source: String) -> Bool {
        guard let compressed = Self.compressSquareJPEG(rawImageData, targetSize: 480, quality: 0.75) else {
            return false
        }
        return queue.sync {
            guard let db = db else { return false }
            var oldPath: String?
            var oldSavedAt: String?
            var wasSaved = false
            var qStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT image_path, saved_at, is_saved FROM recipes WHERE id = ?", -1, &qStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(qStmt, 1, recipeId, -1, SQLITE_TRANSIENT)
                if sqlite3_step(qStmt) == SQLITE_ROW {
                    oldPath = sqlite3_column_text(qStmt, 0).map { String(cString: $0) }
                    oldSavedAt = sqlite3_column_text(qStmt, 1).map { String(cString: $0) }
                    wasSaved = sqlite3_column_int(qStmt, 2) == 1
                }
            }
            sqlite3_finalize(qStmt)

            let promoteToSaved = (source == "custom_photo") || wasSaved
            let targetDir = promoteToSaved ? savedMediaDir : cacheMediaDir
            let folderPrefix = promoteToSaved ? "saved" : "cache"
            let fname = "\(recipeId)_\(source)_\(Int(Date().timeIntervalSince1970)).jpg"
            let dest = targetDir.appendingPathComponent(fname)
            do {
                try compressed.write(to: dest, options: .atomic)
            } catch {
                return false
            }

            let newRel = "\(folderPrefix)/\(fname)"
            if let op = oldPath, op != newRel {
                let oldURL = rootDir.appendingPathComponent("media/\(op)")
                try? FileManager.default.removeItem(at: oldURL)
            }

            let savedAt = oldSavedAt ?? (promoteToSaved ? Self.nowISO() : nil)
            var upStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE recipes SET image_path = ?, image_source = ?, is_saved = ?, saved_at = ? WHERE id = ?", -1, &upStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(upStmt, 1, newRel, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(upStmt, 2, source, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(upStmt, 3, promoteToSaved ? 1 : 0)
                if let savedAt {
                    sqlite3_bind_text(upStmt, 4, savedAt, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(upStmt, 4)
                }
                sqlite3_bind_text(upStmt, 5, recipeId, -1, SQLITE_TRANSIENT)
                sqlite3_step(upStmt)
            }
            sqlite3_finalize(upStmt)
            return true
        }
    }

    func createManualRecipe(_ recipe: Recipe, rawImageData: Data?) -> Recipe {
        let stamp = Self.nowISO()
        let newId = recipe.id.isEmpty ? "rec_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased())" : recipe.id
        let clean = Recipe(
            id: newId,
            title: recipe.title.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceURL: recipe.sourceURL,
            sourceDomain: recipe.sourceDomain.isEmpty ? "manual" : recipe.sourceDomain,
            prepTime: recipe.prepTime.isEmpty ? "20 min" : recipe.prepTime,
            servings: max(1, recipe.servings),
            kcal: max(0, recipe.kcal),
            proteinG: max(0, recipe.proteinG),
            carbsG: max(0, recipe.carbsG),
            fatG: max(0, recipe.fatG),
            sodiumMg: max(0, recipe.sodiumMg),
            sugarG: max(0, recipe.sugarG),
            cholesterolMg: max(0, recipe.cholesterolMg),
            mealType: recipe.mealType.isEmpty ? "Dinner" : recipe.mealType,
            dietaryTags: recipe.dietaryTags,
            allergens: recipe.allergens,
            ingredients: recipe.ingredients,
            steps: recipe.steps,
            imagePath: nil,
            imageSource: "placeholder",
            isSaved: true,
            discoveredAt: stamp,
            savedAt: stamp
        )
        queue.sync {
            insertRecipeRow(clean)
        }
        if let rawImageData {
            _ = saveRecipeImage(recipeId: clean.id, rawImageData: rawImageData, source: "custom_photo")
        }
        return clean
    }

    func clearRecipePhoto(recipeId: String) {
        queue.sync {
            guard let db = db else { return }
            var oldPath: String?
            var qStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT image_path FROM recipes WHERE id = ?", -1, &qStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(qStmt, 1, recipeId, -1, SQLITE_TRANSIENT)
                if sqlite3_step(qStmt) == SQLITE_ROW {
                    oldPath = sqlite3_column_text(qStmt, 0).map { String(cString: $0) }
                }
            }
            sqlite3_finalize(qStmt)
            if let oldPath {
                unlinkMedia(oldPath)
            }
            var upStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE recipes SET image_path = NULL, image_source = 'placeholder' WHERE id = ?", -1, &upStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(upStmt, 1, recipeId, -1, SQLITE_TRANSIENT)
                sqlite3_step(upStmt)
            }
            sqlite3_finalize(upStmt)
        }
    }

    func deleteRecipe(id: String) {
        queue.sync {
            guard let db = db else { return }
            var oldPath: String?
            var qStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT image_path FROM recipes WHERE id = ?", -1, &qStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(qStmt, 1, id, -1, SQLITE_TRANSIENT)
                if sqlite3_step(qStmt) == SQLITE_ROW {
                    oldPath = sqlite3_column_text(qStmt, 0).map { String(cString: $0) }
                }
            }
            sqlite3_finalize(qStmt)
            if let oldPath {
                unlinkMedia(oldPath)
            }
            deleteRecipeById(id)
        }
    }

    func resolveMediaURL(imagePath: String?) -> URL? {
        guard let imagePath = imagePath, !imagePath.isEmpty else { return nil }
        return rootDir.appendingPathComponent("media/\(imagePath)")
    }

    // MARK: - Settings, Storage Metrics & Clutter Janitor

    func getSetting(_ key: String, default fallback: String = "") -> String {
        queue.sync {
            getSettingInternal(key, default: fallback)
        }
    }

    func setSetting(_ key: String, value: String) {
        queue.sync {
            setSettingInternal(key: key, value: value)
        }
    }

    private func getSettingInternal(_ key: String, default fallback: String) -> String {
        guard let db = db else { return fallback }
        var stmt: OpaquePointer?
        var out = fallback
        if sqlite3_prepare_v2(db, "SELECT value FROM app_settings WHERE key = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW, let ptr = sqlite3_column_text(stmt, 0) {
                out = String(cString: ptr)
            }
        }
        sqlite3_finalize(stmt)
        return out
    }

    private func setSettingInternal(key: String, value: String) {
        guard let db = db else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO app_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func getStorageMetrics() -> StorageMetrics {
        queue.sync {
            let dbB = sqliteBytes()
            let (savedB, savedCount) = dirBytes(savedMediaDir)
            let (cacheB, cacheCount) = dirBytes(cacheMediaDir)

            let savedRecs = scalarInt("SELECT COUNT(*) FROM recipes WHERE is_saved = 1")
            let cachedRecs = scalarInt("SELECT COUNT(*) FROM recipes WHERE is_saved = 0")
            let customEx = scalarInt("SELECT COUNT(*) FROM exercises WHERE is_custom = 1")
            let totalSets = scalarInt("SELECT COUNT(*) FROM workout_sets")
            let macroLogs = scalarInt("SELECT COUNT(*) FROM macro_logs")
            let cycleLogs = scalarInt("SELECT COUNT(*) FROM cycle_logs")

            let ttl = 60
            let cap = Int(getSettingInternal("cache_max_mb", default: "25")) ?? 25
            let unit = getSettingInternal("weight_unit", default: "lbs")
            let rawKey = KeychainStore.shared.activeDisplayKey(for: getSettingInternal("active_ai_provider", default: "gemini"))
            let masked: String
            if rawKey.isEmpty {
                masked = ""
            } else if rawKey.count > 8 {
                masked = "\(rawKey.prefix(4))••••\(rawKey.suffix(4))"
            } else {
                masked = "••••"
            }

            return StorageMetrics(
                dbBytes: dbB,
                savedMediaBytes: savedB,
                savedMediaFiles: savedCount,
                cacheMediaBytes: cacheB,
                cacheMediaFiles: cacheCount,
                appDataBytes: dbB + savedB + cacheB,
                bundleVideoCount: bundleStats.count,
                bundleVideoBytes: bundleStats.bytes,
                savedRecipeCount: savedRecs,
                cachedRecipeCount: cachedRecs,
                customExerciseCount: customEx,
                totalSetCount: totalSets,
                macroLogCount: macroLogs,
                cycleLogCount: cycleLogs,
                hasAPIKey: !rawKey.isEmpty,
                maskedAPIKey: masked,
                weightUnit: unit.isEmpty ? "lbs" : unit,
                cacheTTLDays: ttl,
                cacheMaxMB: cap
            )
        }
    }

    func runStorageJanitor(aggressive: Bool) -> SweepResult {
        queue.sync {
            runStorageJanitorInternal(aggressive: aggressive)
        }
    }

    private func runStorageJanitorInternal(aggressive: Bool) -> SweepResult {
        guard let db = db else { return SweepResult(reclaimedBytes: 0, deletedRecipes: 0, deletedOrphanFiles: 0) }
        let beforeBytes = sqliteBytes() + dirBytes(cacheMediaDir).bytes
        var deletedRecipes = 0
        var deletedOrphans = 0

        let ttlDays = 60
        let maxMB = max(1, Int(getSettingInternal("cache_max_mb", default: "25")) ?? 25)
        let maxCacheBytes = Int64(maxMB) * 1024 * 1024

        if aggressive {
            var imgStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT image_path FROM recipes WHERE is_saved = 0", -1, &imgStmt, nil) == SQLITE_OK {
                while sqlite3_step(imgStmt) == SQLITE_ROW {
                    if let ptr = sqlite3_column_text(imgStmt, 0) {
                        unlinkMedia(String(cString: ptr))
                    }
                }
            }
            sqlite3_finalize(imgStmt)
            exec("DELETE FROM recipes WHERE is_saved = 0;")
            deletedRecipes = Int(sqlite3_changes(db))
        } else {
            let cutoffDate = Calendar.current.date(byAdding: .day, value: -ttlDays, to: Date()) ?? Date()
            let cutoffStr = Self.isoFormatter.string(from: cutoffDate)

            var expStmt: OpaquePointer?
            var toDelete: [(String, String?)] = []
            if sqlite3_prepare_v2(db, "SELECT id, image_path FROM recipes WHERE is_saved = 0 AND discovered_at < ?", -1, &expStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(expStmt, 1, cutoffStr, -1, SQLITE_TRANSIENT)
                while sqlite3_step(expStmt) == SQLITE_ROW {
                    let id = sqlite3_column_text(expStmt, 0).map { String(cString: $0) } ?? ""
                    let ip = sqlite3_column_text(expStmt, 1).map { String(cString: $0) }
                    toDelete.append((id, ip))
                }
            }
            sqlite3_finalize(expStmt)
            for (id, ip) in toDelete {
                if let ip = ip { unlinkMedia(ip) }
                deleteRecipeById(id)
                deletedRecipes += 1
            }

            while dirBytes(cacheMediaDir).bytes > maxCacheBytes {
                var oldestStmt: OpaquePointer?
                var oldest: (String, String?)?
                if sqlite3_prepare_v2(db, "SELECT id, image_path FROM recipes WHERE is_saved = 0 ORDER BY discovered_at ASC LIMIT 1", -1, &oldestStmt, nil) == SQLITE_OK {
                    if sqlite3_step(oldestStmt) == SQLITE_ROW {
                        let id = sqlite3_column_text(oldestStmt, 0).map { String(cString: $0) } ?? ""
                        let ip = sqlite3_column_text(oldestStmt, 1).map { String(cString: $0) }
                        oldest = (id, ip)
                    }
                }
                sqlite3_finalize(oldestStmt)
                guard let pair = oldest else { break }
                if let ip = pair.1 { unlinkMedia(ip) }
                deleteRecipeById(pair.0)
                deletedRecipes += 1
            }
        }

        // Remove orphaned cache files
        var referencedCache = Set<String>()
        var refStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT image_path FROM recipes WHERE image_path LIKE 'cache/%'", -1, &refStmt, nil) == SQLITE_OK {
            while sqlite3_step(refStmt) == SQLITE_ROW {
                if let ptr = sqlite3_column_text(refStmt, 0) {
                    referencedCache.insert(URL(fileURLWithPath: String(cString: ptr)).lastPathComponent)
                }
            }
        }
        sqlite3_finalize(refStmt)

        if let files = try? FileManager.default.contentsOfDirectory(at: cacheMediaDir, includingPropertiesForKeys: nil) {
            for f in files where !referencedCache.contains(f.lastPathComponent) {
                try? FileManager.default.removeItem(at: f)
                deletedOrphans += 1
            }
        }

        if aggressive || deletedRecipes > 0 {
            exec("VACUUM;")
        }

        let afterBytes = sqliteBytes() + dirBytes(cacheMediaDir).bytes
        return SweepResult(
            reclaimedBytes: max(0, beforeBytes - afterBytes),
            deletedRecipes: deletedRecipes,
            deletedOrphanFiles: deletedOrphans
        )
    }

    private func deleteRecipeById(_ id: String) {
        guard let db = db else { return }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM recipes WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    private func unlinkMedia(_ imagePath: String) {
        let target = rootDir.appendingPathComponent("media/\(imagePath)")
        try? FileManager.default.removeItem(at: target)
    }

    private func dirBytes(_ url: URL) -> (bytes: Int64, count: Int) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return (0, 0)
        }
        var total: Int64 = 0
        var count = 0
        for item in items {
            if let vals = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               vals.isRegularFile == true,
               let sz = vals.fileSize {
                total += Int64(sz)
                count += 1
            }
        }
        return (total, count)
    }

    private func sqliteBytes() -> Int64 {
        var total: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let p = URL(fileURLWithPath: dbURL.path + suffix)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: p.path),
               let sz = attrs[.size] as? NSNumber {
                total += sz.int64Value
            }
        }
        return total
    }

    // MARK: - Helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM"
        return f
    }()

    private static let mediumDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    private static let monthTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    static func nowISO() -> String {
        isoFormatter.string(from: Date())
    }

    static func isoDate(_ date: Date = Date()) -> String {
        dateOnlyFormatter.string(from: date)
    }

    static func dateFromISO(_ iso: String) -> Date {
        dateOnlyFormatter.date(from: iso) ?? Date()
    }

    static func shortDateLabel(_ iso: String) -> String {
        shortDateFormatter.string(from: dateFromISO(iso))
    }

    static func mediumDateLabel(_ iso: String) -> String {
        mediumDateFormatter.string(from: dateFromISO(iso))
    }

    static func shiftISODate(_ iso: String, byDays delta: Int) -> String {
        let base = dateFromISO(iso)
        let shifted = Calendar(identifier: .gregorian).date(byAdding: .day, value: delta, to: base) ?? base
        return isoDate(shifted)
    }

    static func monthTitle(_ date: Date) -> String {
        monthTitleFormatter.string(from: date).uppercased()
    }

    static func shiftMonth(_ date: Date, by delta: Int) -> Date {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month], from: date)
        let startOfMonth = cal.date(from: comps) ?? date
        return cal.date(byAdding: .month, value: delta, to: startOfMonth) ?? date
    }

    static func cycleMonthSlots(anchor: Date, todayDate: String) -> [MonthDaySlot] {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month], from: anchor)
        guard let firstOfMonth = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: firstOfMonth) else {
            return []
        }

        let leadingBlanks = weekdayIndex(firstOfMonth)
        var out: [MonthDaySlot] = []
        for i in 0..<leadingBlanks {
            out.append(MonthDaySlot(id: "cblank_\(i)", isoDate: nil, dayNumber: nil, isToday: false, hasRoutine: false, hasLoggedSets: false))
        }

        for day in range {
            guard let d = cal.date(byAdding: .day, value: day - 1, to: firstOfMonth) else { continue }
            let iso = isoDate(d)
            out.append(
                MonthDaySlot(
                    id: iso,
                    isoDate: iso,
                    dayNumber: day,
                    isToday: iso == todayDate,
                    hasRoutine: false,
                    hasLoggedSets: false
                )
            )
        }
        return out
    }

    static func weekDates(containing iso: String) -> [Date] {
        let d = dateFromISO(iso)
        let cal = Calendar(identifier: .gregorian)
        let dow = weekdayIndex(d)
        let monday = cal.date(byAdding: .day, value: -dow, to: d) ?? d
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: monday) }
    }

    static func weekdayIndex(_ date: Date = Date()) -> Int {
        // Calendar .weekday: 1=Sun, 2=Mon .. 7=Sat -> map to 0=Mon .. 6=Sun
        let wd = Calendar.current.component(.weekday, from: date)
        return (wd + 5) % 7
    }

    static func dateForWeekday(_ targetDow: Int, reference: Date = Date()) -> String {
        let currentDow = weekdayIndex(reference)
        let diff = targetDow - currentDow
        let target = Calendar.current.date(byAdding: .day, value: diff, to: reference) ?? reference
        return isoDate(target)
    }

    static func compressSquareJPEG(_ data: Data, targetSize: CGFloat = 480, quality: CGFloat = 0.75) -> Data? {
        guard let src = UIImage(data: data), src.size.width > 0, src.size.height > 0 else { return nil }
        let side = min(src.size.width, src.size.height)
        let originX = (src.size.width - side) / 2.0
        let originY = (src.size.height - side) / 2.0
        let cropRect = CGRect(x: originX, y: originY, width: side, height: side)

        let scale = src.scale
        let pixelCrop = CGRect(
            x: cropRect.origin.x * scale,
            y: cropRect.origin.y * scale,
            width: cropRect.width * scale,
            height: cropRect.height * scale
        )

        let targetCGSize = CGSize(width: targetSize, height: targetSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: targetCGSize, format: format)
        let outImg = renderer.image { _ in
            if let cg = src.cgImage?.cropping(to: pixelCrop) {
                UIImage(cgImage: cg, scale: 1.0, orientation: src.imageOrientation)
                    .draw(in: CGRect(origin: .zero, size: targetCGSize))
            } else {
                src.draw(in: CGRect(origin: .zero, size: targetCGSize))
            }
        }
        return outImg.jpegData(compressionQuality: quality)
    }

    private static func readRecipeRow(_ stmt: OpaquePointer) -> Recipe {
        let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        let sourceURL = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let sourceDomain = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
        let prepTime = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
        let servings = Int(sqlite3_column_int(stmt, 5))
        let kcal = Int(sqlite3_column_int(stmt, 6))
        let p = Int(sqlite3_column_int(stmt, 7))
        let c = Int(sqlite3_column_int(stmt, 8))
        let f = Int(sqlite3_column_int(stmt, 9))
        let sodiumMg = Int(sqlite3_column_int(stmt, 10))
        let sugarG = Int(sqlite3_column_int(stmt, 11))
        let cholesterolMg = Int(sqlite3_column_int(stmt, 12))
        let mealTypeRaw = sqlite3_column_text(stmt, 13).map { String(cString: $0) } ?? ""
        let tags = decodeStringArray(sqlite3_column_text(stmt, 14).map { String(cString: $0) })
        let allergens = decodeStringArray(sqlite3_column_text(stmt, 15).map { String(cString: $0) })
        let ingredients = decodeStringArray(sqlite3_column_text(stmt, 16).map { String(cString: $0) })
        let steps = decodeStringArray(sqlite3_column_text(stmt, 17).map { String(cString: $0) })
        let imagePath = sqlite3_column_text(stmt, 18).map { String(cString: $0) }
        let imageSource = sqlite3_column_text(stmt, 19).map { String(cString: $0) } ?? "placeholder"
        let isSaved = sqlite3_column_int(stmt, 20) != 0
        let discoveredAt = sqlite3_column_text(stmt, 21).map { String(cString: $0) } ?? ""
        let savedAt = sqlite3_column_text(stmt, 22).map { String(cString: $0) }

        return Recipe(
            id: id,
            title: title,
            sourceURL: sourceURL,
            sourceDomain: sourceDomain,
            prepTime: prepTime,
            servings: max(1, servings),
            kcal: kcal,
            proteinG: p,
            carbsG: c,
            fatG: f,
            sodiumMg: sodiumMg,
            sugarG: sugarG,
            cholesterolMg: cholesterolMg,
            mealType: mealTypeRaw.isEmpty ? "Dinner" : mealTypeRaw,
            dietaryTags: tags,
            allergens: allergens,
            ingredients: ingredients,
            steps: steps,
            imagePath: imagePath,
            imageSource: imageSource,
            isSaved: isSaved,
            discoveredAt: discoveredAt,
            savedAt: savedAt
        )
    }

    private static func encodeStringArray(_ arr: [String]) -> String {
        guard let d = try? JSONEncoder().encode(arr), let s = String(data: d, encoding: .utf8) else {
            return "[]"
        }
        return s
    }

    private static func decodeStringArray(_ raw: String?) -> [String] {
        guard let raw = raw, let d = raw.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: d) else {
            return []
        }
        return arr
    }

    private static func normText(_ s: String) -> String {
        let lowered = s.lowercased()
        let parts = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func singularize(_ tok: String) -> String {
        if tok.count > 3 && tok.hasSuffix("s") {
            return String(tok.dropLast())
        }
        return tok
    }

    private static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        let aChars = Array(a)
        let bChars = Array(b)
        let n = aChars.count
        let m = bChars.count
        if n == 0 || m == 0 { return 0.0 }
        var prev = Array(0...m)
        var curr = Array(repeating: 0, count: m + 1)
        for i in 1...n {
            curr[0] = i
            for j in 1...m {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = curr
        }
        let dist = Double(prev[m])
        return 1.0 - dist / Double(max(n, m))
    }

    // MARK: - Diet & Macros API

    func getMacroTargets() -> MacroTargets {
        queue.sync {
            getMacroTargetsInternal()
        }
    }

    private func getMacroTargetsInternal() -> MacroTargets {
        guard let db = db else { return .default }
        var stmt: OpaquePointer?
        var res = MacroTargets.default
        let sql = """
        SELECT kcal, protein_g, carbs_g, fat_g,
               COALESCE(sodium_mg, 2300), COALESCE(sugar_g, 50), COALESCE(cholesterol_mg, 300)
        FROM macro_targets WHERE id = 1 LIMIT 1
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                res = MacroTargets(
                    kcal: max(500, Int(sqlite3_column_int(stmt, 0))),
                    proteinG: max(10, Int(sqlite3_column_int(stmt, 1))),
                    carbsG: max(10, Int(sqlite3_column_int(stmt, 2))),
                    fatG: max(10, Int(sqlite3_column_int(stmt, 3))),
                    sodiumMg: max(100, Int(sqlite3_column_int(stmt, 4))),
                    sugarG: max(5, Int(sqlite3_column_int(stmt, 5))),
                    cholesterolMg: max(25, Int(sqlite3_column_int(stmt, 6)))
                )
            }
        }
        sqlite3_finalize(stmt)
        return res
    }

    func saveMacroTargets(_ targets: MacroTargets) {
        queue.sync {
            guard let db = db else { return }
            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO macro_targets (id, kcal, protein_g, carbs_g, fat_g, sodium_mg, sugar_g, cholesterol_mg)
            VALUES (1, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                kcal = excluded.kcal,
                protein_g = excluded.protein_g,
                carbs_g = excluded.carbs_g,
                fat_g = excluded.fat_g,
                sodium_mg = excluded.sodium_mg,
                sugar_g = excluded.sugar_g,
                cholesterol_mg = excluded.cholesterol_mg
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int(stmt, 1, Int32(max(500, targets.kcal)))
                sqlite3_bind_int(stmt, 2, Int32(max(0, targets.proteinG)))
                sqlite3_bind_int(stmt, 3, Int32(max(0, targets.carbsG)))
                sqlite3_bind_int(stmt, 4, Int32(max(0, targets.fatG)))
                sqlite3_bind_int(stmt, 5, Int32(max(100, targets.sodiumMg)))
                sqlite3_bind_int(stmt, 6, Int32(max(5, targets.sugarG)))
                sqlite3_bind_int(stmt, 7, Int32(max(25, targets.cholesterolMg)))
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func listMacroLogs(forDate logDate: String) -> DailyMacroTotals {
        queue.sync {
            guard let db = db else {
                return DailyMacroTotals(kcal: 0, proteinG: 0, carbsG: 0, fatG: 0, sodiumMg: 0, sugarG: 0, cholesterolMg: 0, entries: [])
            }
            var entries: [MacroLogEntry] = []
            var stmt: OpaquePointer?
            let sql = """
            SELECT id, log_date, meal_slot, name, servings, kcal, protein_g, carbs_g, fat_g,
                   COALESCE(sodium_mg, 0), COALESCE(sugar_g, 0), COALESCE(cholesterol_mg, 0),
                   recipe_id, notes, created_at
            FROM macro_logs
            WHERE log_date = ?
            ORDER BY id DESC
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, logDate, -1, SQLITE_TRANSIENT)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    entries.append(Self.readMacroLogRow(stmt!))
                }
            }
            sqlite3_finalize(stmt)
            return DailyMacroTotals(
                kcal: entries.reduce(0) { $0 + $1.kcal },
                proteinG: entries.reduce(0) { $0 + $1.proteinG },
                carbsG: entries.reduce(0) { $0 + $1.carbsG },
                fatG: entries.reduce(0) { $0 + $1.fatG },
                sodiumMg: entries.reduce(0) { $0 + $1.sodiumMg },
                sugarG: entries.reduce(0) { $0 + $1.sugarG },
                cholesterolMg: entries.reduce(0) { $0 + $1.cholesterolMg },
                entries: entries
            )
        }
    }

    func listAllMacroLogs() -> [MacroLogEntry] {
        queue.sync {
            listAllMacroLogsInternal()
        }
    }

    private func listAllMacroLogsInternal() -> [MacroLogEntry] {
        guard let db = db else { return [] }
        var out: [MacroLogEntry] = []
        var stmt: OpaquePointer?
        let sql = """
        SELECT id, log_date, meal_slot, name, servings, kcal, protein_g, carbs_g, fat_g,
               COALESCE(sodium_mg, 0), COALESCE(sugar_g, 0), COALESCE(cholesterol_mg, 0),
               recipe_id, notes, created_at
        FROM macro_logs
        ORDER BY log_date DESC, id DESC
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(Self.readMacroLogRow(stmt!))
            }
        }
        sqlite3_finalize(stmt)
        return out
    }

    @discardableResult
    func addMacroLog(
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
        notes: String = ""
    ) -> Int64 {
        queue.sync {
            insertMacroLogRaw(
                logDate: logDate,
                mealSlot: mealSlot,
                name: name,
                servings: servings,
                kcal: kcal,
                proteinG: proteinG,
                carbsG: carbsG,
                fatG: fatG,
                sodiumMg: sodiumMg,
                sugarG: sugarG,
                cholesterolMg: cholesterolMg,
                recipeId: recipeId,
                notes: notes,
                createdAt: Self.nowISO()
            )
        }
    }

    @discardableResult
    private func insertMacroLogRaw(
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
        recipeId: String?,
        notes: String,
        createdAt: String
    ) -> Int64 {
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO macro_logs (
            log_date, meal_slot, name, servings,
            kcal, protein_g, carbs_g, fat_g,
            sodium_mg, sugar_g, cholesterol_mg,
            recipe_id, notes, created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, logDate, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, mealSlot.isEmpty ? "Lunch" : mealSlot, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, name.trimmingCharacters(in: .whitespacesAndNewlines), -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 4, max(0.1, servings))
            sqlite3_bind_int(stmt, 5, Int32(max(0, kcal)))
            sqlite3_bind_int(stmt, 6, Int32(max(0, proteinG)))
            sqlite3_bind_int(stmt, 7, Int32(max(0, carbsG)))
            sqlite3_bind_int(stmt, 8, Int32(max(0, fatG)))
            sqlite3_bind_int(stmt, 9, Int32(max(0, sodiumMg)))
            sqlite3_bind_int(stmt, 10, Int32(max(0, sugarG)))
            sqlite3_bind_int(stmt, 11, Int32(max(0, cholesterolMg)))
            if let rid = recipeId, !rid.isEmpty {
                sqlite3_bind_text(stmt, 12, rid, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 12)
            }
            sqlite3_bind_text(stmt, 13, notes.trimmingCharacters(in: .whitespacesAndNewlines), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 14, createdAt, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    func updateMacroLog(
        id: Int64,
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
        notes: String
    ) {
        queue.sync {
            guard let db = db else { return }
            var stmt: OpaquePointer?
            let sql = """
            UPDATE macro_logs
            SET meal_slot = ?, name = ?, servings = ?,
                kcal = ?, protein_g = ?, carbs_g = ?, fat_g = ?,
                sodium_mg = ?, sugar_g = ?, cholesterol_mg = ?,
                notes = ?
            WHERE id = ?
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, mealSlot, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, name.trimmingCharacters(in: .whitespacesAndNewlines), -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 3, max(0.1, servings))
                sqlite3_bind_int(stmt, 4, Int32(max(0, kcal)))
                sqlite3_bind_int(stmt, 5, Int32(max(0, proteinG)))
                sqlite3_bind_int(stmt, 6, Int32(max(0, carbsG)))
                sqlite3_bind_int(stmt, 7, Int32(max(0, fatG)))
                sqlite3_bind_int(stmt, 8, Int32(max(0, sodiumMg)))
                sqlite3_bind_int(stmt, 9, Int32(max(0, sugarG)))
                sqlite3_bind_int(stmt, 10, Int32(max(0, cholesterolMg)))
                sqlite3_bind_text(stmt, 11, notes.trimmingCharacters(in: .whitespacesAndNewlines), -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 12, id)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func deleteMacroLog(id: Int64) {
        queue.sync {
            guard let db = db else { return }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM macro_logs WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, id)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func recentDailyKcalPoints(endingAt endDateISO: String, days: Int = 7) -> [DailyKcalPoint] {
        queue.sync {
            guard let db = db else { return [] }
            let totalDays = max(2, days)
            let startISO = Self.shiftISODate(endDateISO, byDays: -(totalDays - 1))
            var sums: [String: (Int, Int)] = [:]
            var stmt: OpaquePointer?
            let sql = """
            SELECT log_date, SUM(kcal), SUM(protein_g)
            FROM macro_logs
            WHERE log_date >= ? AND log_date <= ?
            GROUP BY log_date
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, startISO, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, endDateISO, -1, SQLITE_TRANSIENT)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let d = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    let k = Int(sqlite3_column_int(stmt, 1))
                    let p = Int(sqlite3_column_int(stmt, 2))
                    if !d.isEmpty { sums[d] = (k, p) }
                }
            }
            sqlite3_finalize(stmt)

            return (0..<totalDays).map { offset in
                let d = Self.shiftISODate(startISO, byDays: offset)
                let pair = sums[d] ?? (0, 0)
                return DailyKcalPoint(date: d, kcal: pair.0, proteinG: pair.1)
            }
        }
    }

    func macroHistoryPoints(metric: MacroMetric, endingAt endDateISO: String, days: Int) -> [MacroHistoryPoint] {
        queue.sync {
            guard let db = db else { return [] }
            let col: String
            switch metric {
            case .kcal: col = "kcal"
            case .protein: col = "protein_g"
            case .carbs: col = "carbs_g"
            case .fat: col = "fat_g"
            case .sodium: col = "sodium_mg"
            case .sugar: col = "sugar_g"
            case .cholesterol: col = "cholesterol_mg"
            }

            let totalDays = max(2, days)
            let startISO = Self.shiftISODate(endDateISO, byDays: -(totalDays - 1))
            var sums: [String: Int] = [:]
            var stmt: OpaquePointer?
            let sql = """
            SELECT log_date, SUM(COALESCE(\(col), 0))
            FROM macro_logs
            WHERE log_date >= ? AND log_date <= ?
            GROUP BY log_date
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, startISO, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, endDateISO, -1, SQLITE_TRANSIENT)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let d = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    let val = Int(sqlite3_column_int(stmt, 1))
                    if !d.isEmpty { sums[d] = val }
                }
            }
            sqlite3_finalize(stmt)

            return (0..<totalDays).map { offset in
                let d = Self.shiftISODate(startISO, byDays: offset)
                return MacroHistoryPoint(date: d, value: sums[d] ?? 0)
            }
        }
    }

    private static func readMacroLogRow(_ stmt: OpaquePointer) -> MacroLogEntry {
        MacroLogEntry(
            id: sqlite3_column_int64(stmt, 0),
            logDate: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
            mealSlot: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "Lunch",
            name: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "",
            servings: sqlite3_column_double(stmt, 4),
            kcal: Int(sqlite3_column_int(stmt, 5)),
            proteinG: Int(sqlite3_column_int(stmt, 6)),
            carbsG: Int(sqlite3_column_int(stmt, 7)),
            fatG: Int(sqlite3_column_int(stmt, 8)),
            sodiumMg: Int(sqlite3_column_int(stmt, 9)),
            sugarG: Int(sqlite3_column_int(stmt, 10)),
            cholesterolMg: Int(sqlite3_column_int(stmt, 11)),
            recipeId: sqlite3_column_text(stmt, 12).map { String(cString: $0) },
            notes: sqlite3_column_text(stmt, 13).map { String(cString: $0) } ?? "",
            createdAt: sqlite3_column_text(stmt, 14).map { String(cString: $0) } ?? ""
        )
    }

    // MARK: - Cycle / Menstrual API

    func upsertCycleLog(_ entry: CycleLogEntry) {
        queue.sync {
            upsertCycleLogInternal(entry)
        }
    }

    private func upsertCycleLogInternal(_ entry: CycleLogEntry) {
        guard let db = db else { return }
        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO cycle_logs (log_date, flow, symptoms, mood, energy, bbt, notes, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(log_date) DO UPDATE SET
            flow = excluded.flow,
            symptoms = excluded.symptoms,
            mood = excluded.mood,
            energy = excluded.energy,
            bbt = excluded.bbt,
            notes = excluded.notes,
            updated_at = excluded.updated_at
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, entry.logDate, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, entry.flow.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, Self.encodeStringArray(entry.symptoms), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, entry.mood.trimmingCharacters(in: .whitespacesAndNewlines), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 5, Int32(max(1, min(5, entry.energy))))
            if let bbt = entry.bbt, bbt > 0 {
                sqlite3_bind_double(stmt, 6, bbt)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            sqlite3_bind_text(stmt, 7, entry.notes.trimmingCharacters(in: .whitespacesAndNewlines), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 8, entry.updatedAt.isEmpty ? Self.nowISO() : entry.updatedAt, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func deleteCycleLog(logDate: String) {
        queue.sync {
            guard let db = db else { return }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM cycle_logs WHERE log_date = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, logDate, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func getCycleLog(forDate logDate: String) -> CycleLogEntry? {
        queue.sync {
            guard let db = db else { return nil }
            var stmt: OpaquePointer?
            var found: CycleLogEntry?
            let sql = "SELECT log_date, flow, symptoms, mood, energy, bbt, notes, updated_at FROM cycle_logs WHERE log_date = ? LIMIT 1"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, logDate, -1, SQLITE_TRANSIENT)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    found = Self.readCycleLogRow(stmt!)
                }
            }
            sqlite3_finalize(stmt)
            return found
        }
    }

    func listAllCycleLogs() -> [CycleLogEntry] {
        queue.sync {
            listAllCycleLogsInternal()
        }
    }

    private func listAllCycleLogsInternal() -> [CycleLogEntry] {
        guard let db = db else { return [] }
        var out: [CycleLogEntry] = []
        var stmt: OpaquePointer?
        let sql = "SELECT log_date, flow, symptoms, mood, energy, bbt, notes, updated_at FROM cycle_logs ORDER BY log_date DESC"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(Self.readCycleLogRow(stmt!))
            }
        }
        sqlite3_finalize(stmt)
        return out
    }

    func computeCycleSummary(todayDate: String) -> CycleSummary {
        queue.sync {
            let all = listAllCycleLogsInternal()
            let cal = Calendar(identifier: .gregorian)
            let bleedingLogs = all
                .filter { $0.flow != .none && $0.flow != .spotting }
                .sorted { $0.logDate < $1.logDate }

            // Group consecutive bleeding days (gap <= 2 days) into period spans
            var rawSpans: [(start: String, end: String, days: Int)] = []
            for entry in bleedingLogs {
                if let last = rawSpans.last {
                    let d1 = Self.dateFromISO(last.end)
                    let d2 = Self.dateFromISO(entry.logDate)
                    let diff = cal.dateComponents([.day], from: d1, to: d2).day ?? 99
                    if diff <= 2 {
                        let newDays = (cal.dateComponents([.day], from: Self.dateFromISO(last.start), to: d2).day ?? 0) + 1
                        rawSpans[rawSpans.count - 1] = (last.start, entry.logDate, max(1, newDays))
                        continue
                    }
                }
                rawSpans.append((entry.logDate, entry.logDate, 1))
            }

            var periods: [CyclePeriodSpan] = []
            var cycleLengths: [Int] = []
            var allObservedCycleGaps: [Int] = []
            for i in 0..<rawSpans.count {
                let cur = rawSpans[i]
                var cycleLen: Int? = nil
                if i + 1 < rawSpans.count {
                    let nextStart = rawSpans[i + 1].start
                    let diff = cal.dateComponents([.day], from: Self.dateFromISO(cur.start), to: Self.dateFromISO(nextStart)).day ?? 0
                    if diff >= 12 && diff <= 180 {
                        cycleLen = diff
                        allObservedCycleGaps.append(diff)
                        if diff >= 15 && diff <= 60 {
                            cycleLengths.append(diff)
                        }
                    }
                }
                periods.append(
                    CyclePeriodSpan(
                        startDate: cur.start,
                        endDate: cur.end,
                        durationDays: cur.days,
                        cycleLengthDays: cycleLen
                    )
                )
            }
            periods.reverse()

            let avgCycle = cycleLengths.isEmpty ? 28 : Int(round(Double(cycleLengths.reduce(0, +)) / Double(cycleLengths.count)))
            let avgPeriod = rawSpans.isEmpty ? 5 : max(2, Int(round(Double(rawSpans.map(\.days).reduce(0, +)) / Double(rawSpans.count))))

            guard let latestStart = periods.first?.startDate else {
                return CycleSummary(
                    currentCycleDay: nil,
                    estimatedPhase: "No Cycle Logged",
                    avgCycleLength: avgCycle,
                    avgPeriodLength: avgPeriod,
                    nextPredictedStart: nil,
                    daysUntilNextPeriod: nil,
                    predictedPeriodDates: [],
                    periods: [],
                    dayPhases: [:],
                    regularityInsight: nil
                )
            }

            let todayD = Self.dateFromISO(todayDate)
            let startD = Self.dateFromISO(latestStart)
            let dayDiff = cal.dateComponents([.day], from: startD, to: todayD).day ?? 0
            let cycleDay: Int? = dayDiff >= 0 ? (dayDiff + 1) : nil

            let nextStart = Self.shiftISODate(latestStart, byDays: avgCycle)
            let daysUntil = cal.dateComponents([.day], from: todayD, to: Self.dateFromISO(nextStart)).day

            var predictedSet = Set<String>()
            for offset in 0..<avgPeriod {
                predictedSet.insert(Self.shiftISODate(nextStart, byDays: offset))
            }

            // Build color-coded phase map across logged & projected cycles
            var dayPhases: [String: CyclePhase] = [:]
            func populateCyclePhases(startISO: String, cycleLen: Int, periodLen: Int, markPredictedPeriod: Bool) {
                let clampedLen = max(21, min(60, cycleLen))
                let clampedPeriod = max(2, min(10, periodLen))
                let ovulCenter = max(clampedPeriod + 2, clampedLen - 14)
                let ovulStart = max(clampedPeriod, ovulCenter - 2)
                let ovulEnd = min(clampedLen - 1, ovulCenter + 1)

                for offset in 0..<clampedLen {
                    let iso = Self.shiftISODate(startISO, byDays: offset)
                    if offset < clampedPeriod {
                        if markPredictedPeriod && dayPhases[iso] != .menstrual {
                            dayPhases[iso] = .predictedPeriod
                        }
                    } else if offset < ovulStart {
                        if dayPhases[iso] == nil { dayPhases[iso] = .follicular }
                    } else if offset <= ovulEnd {
                        if dayPhases[iso] == nil { dayPhases[iso] = .ovulatory }
                    } else {
                        if dayPhases[iso] == nil { dayPhases[iso] = .luteal }
                    }
                }
            }

            for span in rawSpans.reversed() {
                let len = periods.first(where: { $0.startDate == span.start })?.cycleLengthDays ?? avgCycle
                populateCyclePhases(startISO: span.start, cycleLen: len, periodLen: span.days, markPredictedPeriod: false)
            }
            // Project upcoming 2 cycles so future calendar days show phases + predicted period
            populateCyclePhases(startISO: nextStart, cycleLen: avgCycle, periodLen: avgPeriod, markPredictedPeriod: true)
            let secondNext = Self.shiftISODate(nextStart, byDays: avgCycle)
            populateCyclePhases(startISO: secondNext, cycleLen: avgCycle, periodLen: avgPeriod, markPredictedPeriod: true)

            // Logged bleeding days always win as .menstrual
            for entry in bleedingLogs {
                dayPhases[entry.logDate] = .menstrual
            }

            let phase: String
            if let cd = cycleDay {
                let ovulCenter = max(avgPeriod + 2, avgCycle - 14)
                if cd <= avgPeriod {
                    phase = "Menstrual Phase"
                } else if cd < max(avgPeriod + 1, ovulCenter - 1) {
                    phase = "Follicular Phase"
                } else if cd <= ovulCenter + 2 {
                    phase = "Ovulatory Window"
                } else if cd <= avgCycle {
                    phase = "Luteal Phase"
                } else {
                    phase = "Cycle Day \(cd) (Window Passed)"
                }
            } else {
                phase = "Cycle Ready"
            }

            // FIGO 2018 & 2023 International PCOS Guideline pattern check
            var observations: [String] = []
            let longCycles = allObservedCycleGaps.filter { $0 > 35 }
            let shortCycles = allObservedCycleGaps.filter { $0 < 21 }
            let prolongedBleeds = rawSpans.filter { $0.days > 8 }

            if !longCycles.isEmpty {
                let longest = longCycles.max() ?? 36
                observations.append("Cycle length exceeded 35 days (up to \(longest) days; typical adult range is 24–38 days).")
            }
            if !shortCycles.isEmpty {
                let shortest = shortCycles.min() ?? 20
                observations.append("Cycle length under 21 days observed (\(shortest) days).")
            }
            if allObservedCycleGaps.count >= 2,
               let minC = allObservedCycleGaps.min(),
               let maxC = allObservedCycleGaps.max(),
               (maxC - minC) > 9 {
                observations.append("Cycle-to-cycle variation of \(maxC - minC) days exceeds the typical <= 7–9 day window.")
            }
            if dayDiff > 90 {
                observations.append("\(dayDiff) days since last logged period start (exceeds 90-day clinical threshold).")
            }
            if !prolongedBleeds.isEmpty {
                let longestBleed = prolongedBleeds.map(\.days).max() ?? 9
                observations.append("Bleeding span of \(longestBleed) days exceeds typical <= 8 day duration.")
            }

            let insight: CycleRegularityInsight? = observations.isEmpty ? nil : CycleRegularityInsight(
                isIrregular: true,
                headline: "Irregular Cycle Pattern Observed",
                observations: observations,
                guidance: "Irregular, infrequent, or prolonged cycles can stem from many everyday factors—stress, training load, thyroid shifts, or Polycystic Ovary Syndrome (PCOS). Velda cannot diagnose any condition; consider sharing your exported cycle log with a physician."
            )

            return CycleSummary(
                currentCycleDay: cycleDay,
                estimatedPhase: phase,
                avgCycleLength: avgCycle,
                avgPeriodLength: avgPeriod,
                nextPredictedStart: nextStart,
                daysUntilNextPeriod: daysUntil,
                predictedPeriodDates: predictedSet,
                periods: periods,
                dayPhases: dayPhases,
                regularityInsight: insight
            )
        }
    }

    private static func readCycleLogRow(_ stmt: OpaquePointer) -> CycleLogEntry {
        let logDate = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        let flowRaw = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "none"
        let symptoms = decodeStringArray(sqlite3_column_text(stmt, 2).map { String(cString: $0) })
        let mood = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
        let energy = Int(sqlite3_column_int(stmt, 4))
        let bbt: Double? = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5)
        let notes = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
        let updatedAt = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? ""

        return CycleLogEntry(
            logDate: logDate,
            flow: CycleFlowLevel(rawValue: flowRaw) ?? .none,
            symptoms: symptoms,
            mood: mood,
            energy: max(1, min(5, energy)),
            bbt: bbt,
            notes: notes,
            updatedAt: updatedAt
        )
    }

    // MARK: - Snapshot Export, Import & Wipe

    func listAllWorkoutSets() -> [ExportWorkoutSet] {
        queue.sync {
            listAllWorkoutSetsInternal()
        }
    }

    private func listAllWorkoutSetsInternal() -> [ExportWorkoutSet] {
        guard let db = db else { return [] }
        var out: [ExportWorkoutSet] = []
        var stmt: OpaquePointer?
        let sql = """
        SELECT ws.id, ws.session_date, ws.exercise_id, COALESCE(e.name, ws.exercise_id),
               ws.set_number, ws.reps, ws.weight, ws.completed, ws.created_at
        FROM workout_sets ws
        LEFT JOIN exercises e ON e.id = ws.exercise_id
        ORDER BY ws.session_date DESC, ws.exercise_id ASC, ws.set_number ASC
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(
                    ExportWorkoutSet(
                        id: sqlite3_column_int64(stmt, 0),
                        sessionDate: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                        exerciseId: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
                        exerciseName: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "",
                        setNumber: Int(sqlite3_column_int(stmt, 4)),
                        reps: Int(sqlite3_column_int(stmt, 5)),
                        weight: sqlite3_column_double(stmt, 6),
                        completed: sqlite3_column_int(stmt, 7) != 0,
                        createdAt: sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? ""
                    )
                )
            }
        }
        sqlite3_finalize(stmt)
        return out
    }

    func exportAllDomainSnapshot() -> VeldaFullSnapshot {
        let customs = listCustomExercises()
        let routinesList = listRoutines()
        let unit = getSetting("weight_unit", default: "lbs")
        let cycleEnabled = getSetting("cycle_tracking_enabled", default: "1") != "0"
        let weightList = listWeightLogs(displayUnit: unit, limit: 5000)
        let macroTargets = getMacroTargets()
        let macroLogs = listAllMacroLogs()
        let recs = listRecipes()
        let cycleLogs = listAllCycleLogs()
        let sets = listAllWorkoutSets()
        let dateSchedules: [ExportDateScheduleEntry] = queue.sync {
            guard let db = db else { return [] }
            var list: [ExportDateScheduleEntry] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT session_date, routine_id FROM date_schedule ORDER BY session_date DESC, sort_order ASC, rowid ASC", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let sDate = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    let rawRId = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                    let rId = (rawRId?.isEmpty ?? true) ? nil : rawRId
                    if !sDate.isEmpty {
                        list.append(ExportDateScheduleEntry(sessionDate: sDate, routineId: rId))
                    }
                }
            }
            sqlite3_finalize(stmt)
            return list
        }

        return VeldaFullSnapshot(
            schemaVersion: 2,
            appName: "Velda Fitness",
            exportedAt: Self.nowISO(),
            weightUnit: unit,
            cycleTrackingEnabled: cycleEnabled,
            customExercises: customs,
            routines: routinesList,
            dateSchedules: dateSchedules,
            workoutSets: sets,
            weightLogs: weightList,
            macroTargets: macroTargets,
            macroLogs: macroLogs,
            recipes: recs.saved + recs.discover,
            cycleLogs: cycleLogs
        )
    }

    func importSnapshot(_ snapshot: VeldaFullSnapshot, merge: Bool = true) {
        queue.sync {
            guard let db = db else { return }
            let stamp = Self.nowISO()

            exec("BEGIN IMMEDIATE;")
            if !merge {
                exec("DELETE FROM routine_items;")
                exec("DELETE FROM weekly_schedule;")
                exec("DELETE FROM date_schedule;")
                exec("DELETE FROM routines;")
                exec("DELETE FROM workout_sets;")
                exec("DELETE FROM weight_logs;")
                exec("DELETE FROM macro_logs;")
                exec("DELETE FROM cycle_logs;")
                exec("DELETE FROM recipes;")
                exec("DELETE FROM exercises WHERE is_custom = 1;")
            }

            setSettingInternal(key: "weight_unit", value: snapshot.weightUnit.lowercased() == "kg" ? "kg" : "lbs")
            setSettingInternal(key: "cycle_tracking_enabled", value: snapshot.cycleTrackingEnabled ? "1" : "0")

            for ex in snapshot.customExercises {
                var stmt: OpaquePointer?
                let sql = """
                INSERT OR REPLACE INTO exercises (id, name, video_filename, muscle_hint, is_custom, tracking_type, equipment, notes, created_at)
                VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?)
                """
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, ex.id, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 2, ex.name, -1, SQLITE_TRANSIENT)
                    if let vf = ex.videoFilename, !vf.isEmpty {
                        sqlite3_bind_text(stmt, 3, vf, -1, SQLITE_TRANSIENT)
                    } else {
                        sqlite3_bind_null(stmt, 3)
                    }
                    sqlite3_bind_text(stmt, 4, ex.muscleHint, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 5, ex.trackingType, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 6, ex.equipment, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 7, ex.notes, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 8, stamp, -1, SQLITE_TRANSIENT)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            }

            for rt in snapshot.routines {
                insertRoutineRowInternal(id: rt.id, title: rt.title, emblem: rt.emblem, createdAt: stamp, updatedAt: stamp)
                var delStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "DELETE FROM routine_items WHERE routine_id = ?", -1, &delStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(delStmt, 1, rt.id, -1, SQLITE_TRANSIENT)
                    sqlite3_step(delStmt)
                }
                sqlite3_finalize(delStmt)

                for (idx, ex) in rt.exercises.enumerated() {
                    insertRoutineItemInternal(routineId: rt.id, exerciseId: ex.id, sortOrder: idx)
                }
                for dow in rt.assignedWeekdays where (0...6).contains(dow) {
                    assignWeekdayInternal(routineId: rt.id, dayOfWeek: dow, syncOverrideForDate: nil)
                }
            }

            let groupedSchedules = Dictionary(grouping: snapshot.dateSchedules, by: \.sessionDate)
            for (sessionDate, entries) in groupedSchedules where !sessionDate.isEmpty {
                let validIds = entries.compactMap { $0.routineId }.filter { !$0.isEmpty }
                if validIds.isEmpty {
                    var delStmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, "DELETE FROM date_schedule WHERE session_date = ?", -1, &delStmt, nil) == SQLITE_OK {
                        sqlite3_bind_text(delStmt, 1, sessionDate, -1, SQLITE_TRANSIENT)
                        sqlite3_step(delStmt)
                    }
                    sqlite3_finalize(delStmt)

                    var stmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO date_schedule (session_date, routine_id, sort_order) VALUES (?, '', 0)", -1, &stmt, nil) == SQLITE_OK {
                        sqlite3_bind_text(stmt, 1, sessionDate, -1, SQLITE_TRANSIENT)
                        sqlite3_step(stmt)
                    }
                    sqlite3_finalize(stmt)
                } else {
                    var clrStmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, "DELETE FROM date_schedule WHERE session_date = ? AND routine_id = ''", -1, &clrStmt, nil) == SQLITE_OK {
                        sqlite3_bind_text(clrStmt, 1, sessionDate, -1, SQLITE_TRANSIENT)
                        sqlite3_step(clrStmt)
                    }
                    sqlite3_finalize(clrStmt)

                    for (idx, rid) in validIds.enumerated() {
                        var stmt: OpaquePointer?
                        if sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO date_schedule (session_date, routine_id, sort_order) VALUES (?, ?, ?)", -1, &stmt, nil) == SQLITE_OK {
                            sqlite3_bind_text(stmt, 1, sessionDate, -1, SQLITE_TRANSIENT)
                            sqlite3_bind_text(stmt, 2, rid, -1, SQLITE_TRANSIENT)
                            sqlite3_bind_int(stmt, 3, Int32(idx))
                            sqlite3_step(stmt)
                        }
                        sqlite3_finalize(stmt)
                    }
                }
            }

            for ws in snapshot.workoutSets {
                let exists = scalarInt(
                    "SELECT COUNT(*) FROM workout_sets WHERE session_date = ? AND exercise_id = ? AND set_number = ?",
                    args: [ws.sessionDate, ws.exerciseId, "\(ws.setNumber)"]
                ) > 0
                if !exists {
                    _ = insertWorkoutSetRaw(
                        sessionDate: ws.sessionDate,
                        exerciseId: ws.exerciseId,
                        setNumber: ws.setNumber,
                        reps: ws.reps,
                        weight: ws.weight,
                        completed: ws.completed,
                        stamp: ws.createdAt.isEmpty ? stamp : ws.createdAt
                    )
                }
            }

            for wl in snapshot.weightLogs {
                var stmt: OpaquePointer?
                let sql = """
                INSERT INTO weight_logs (log_date, weight, unit, note, created_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(log_date) DO UPDATE SET
                    weight = excluded.weight,
                    unit = excluded.unit,
                    note = excluded.note,
                    created_at = excluded.created_at
                """
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, wl.logDate, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_double(stmt, 2, wl.rawWeight)
                    sqlite3_bind_text(stmt, 3, wl.rawUnit, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 4, wl.note, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 5, wl.createdAt.isEmpty ? stamp : wl.createdAt, -1, SQLITE_TRANSIENT)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            }

            var tStmt: OpaquePointer?
            let tSql = """
            INSERT INTO macro_targets (id, kcal, protein_g, carbs_g, fat_g, sodium_mg, sugar_g, cholesterol_mg)
            VALUES (1, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                kcal = excluded.kcal, protein_g = excluded.protein_g, carbs_g = excluded.carbs_g, fat_g = excluded.fat_g,
                sodium_mg = excluded.sodium_mg, sugar_g = excluded.sugar_g, cholesterol_mg = excluded.cholesterol_mg
            """
            if sqlite3_prepare_v2(db, tSql, -1, &tStmt, nil) == SQLITE_OK {
                sqlite3_bind_int(tStmt, 1, Int32(snapshot.macroTargets.kcal))
                sqlite3_bind_int(tStmt, 2, Int32(snapshot.macroTargets.proteinG))
                sqlite3_bind_int(tStmt, 3, Int32(snapshot.macroTargets.carbsG))
                sqlite3_bind_int(tStmt, 4, Int32(snapshot.macroTargets.fatG))
                sqlite3_bind_int(tStmt, 5, Int32(snapshot.macroTargets.sodiumMg))
                sqlite3_bind_int(tStmt, 6, Int32(snapshot.macroTargets.sugarG))
                sqlite3_bind_int(tStmt, 7, Int32(snapshot.macroTargets.cholesterolMg))
                sqlite3_step(tStmt)
            }
            sqlite3_finalize(tStmt)

            for ml in snapshot.macroLogs {
                let exists = scalarInt(
                    "SELECT COUNT(*) FROM macro_logs WHERE log_date = ? AND name = ? AND kcal = ? AND created_at = ?",
                    args: [ml.logDate, ml.name, "\(ml.kcal)", ml.createdAt]
                ) > 0
                if !exists {
                    _ = insertMacroLogRaw(
                        logDate: ml.logDate,
                        mealSlot: ml.mealSlot,
                        name: ml.name,
                        servings: ml.servings,
                        kcal: ml.kcal,
                        proteinG: ml.proteinG,
                        carbsG: ml.carbsG,
                        fatG: ml.fatG,
                        sodiumMg: ml.sodiumMg,
                        sugarG: ml.sugarG,
                        cholesterolMg: ml.cholesterolMg,
                        recipeId: ml.recipeId,
                        notes: ml.notes,
                        createdAt: ml.createdAt.isEmpty ? stamp : ml.createdAt
                    )
                }
            }

            for rec in snapshot.recipes {
                let exists = scalarInt("SELECT COUNT(*) FROM recipes WHERE id = ?", args: [rec.id]) > 0
                if !exists || !merge {
                    let cleanRec = Recipe(
                        id: rec.id,
                        title: rec.title,
                        sourceURL: rec.sourceURL,
                        sourceDomain: rec.sourceDomain,
                        prepTime: rec.prepTime,
                        servings: rec.servings,
                        kcal: rec.kcal,
                        proteinG: rec.proteinG,
                        carbsG: rec.carbsG,
                        fatG: rec.fatG,
                        sodiumMg: rec.sodiumMg,
                        sugarG: rec.sugarG,
                        cholesterolMg: rec.cholesterolMg,
                        mealType: rec.mealType,
                        dietaryTags: rec.dietaryTags,
                        allergens: rec.allergens,
                        ingredients: rec.ingredients,
                        steps: rec.steps,
                        imagePath: nil,
                        imageSource: "placeholder",
                        isSaved: rec.isSaved,
                        discoveredAt: rec.discoveredAt,
                        savedAt: rec.savedAt
                    )
                    insertRecipeRow(cleanRec)
                }
            }

            for cl in snapshot.cycleLogs {
                upsertCycleLogInternal(cl)
            }
            exec("COMMIT;")
        }
    }

    @discardableResult
    func importSingleRoutine(_ routine: RoutineSummary) -> String {
        let stamp = Self.nowISO()
        let newRid = "rt_\(UUID().uuidString.prefix(8).lowercased())"
        queue.sync {
            guard let db = db else { return }
            exec("BEGIN IMMEDIATE;")
            insertRoutineRowInternal(id: newRid, title: routine.title, emblem: routine.emblem, createdAt: stamp, updatedAt: stamp)
            for (idx, ex) in routine.exercises.enumerated() {
                if ex.isCustom {
                    let exists = scalarInt("SELECT COUNT(*) FROM exercises WHERE id = ?", args: [ex.id]) > 0
                    if !exists {
                        var stmt: OpaquePointer?
                        let sql = """
                        INSERT INTO exercises (id, name, video_filename, muscle_hint, is_custom, tracking_type, equipment, notes, created_at)
                        VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?)
                        """
                        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                            sqlite3_bind_text(stmt, 1, ex.id, -1, SQLITE_TRANSIENT)
                            sqlite3_bind_text(stmt, 2, ex.name, -1, SQLITE_TRANSIENT)
                            if let vf = ex.videoFilename, !vf.isEmpty {
                                sqlite3_bind_text(stmt, 3, vf, -1, SQLITE_TRANSIENT)
                            } else {
                                sqlite3_bind_null(stmt, 3)
                            }
                            sqlite3_bind_text(stmt, 4, ex.muscleHint, -1, SQLITE_TRANSIENT)
                            sqlite3_bind_text(stmt, 5, ex.trackingType, -1, SQLITE_TRANSIENT)
                            sqlite3_bind_text(stmt, 6, ex.equipment, -1, SQLITE_TRANSIENT)
                            sqlite3_bind_text(stmt, 7, ex.notes, -1, SQLITE_TRANSIENT)
                            sqlite3_bind_text(stmt, 8, stamp, -1, SQLITE_TRANSIENT)
                            sqlite3_step(stmt)
                        }
                        sqlite3_finalize(stmt)
                    }
                }
                insertRoutineItemInternal(routineId: newRid, exerciseId: ex.id, sortOrder: idx)
            }
            exec("COMMIT;")
        }
        return newRid
    }

    func importSingleRecipe(_ recipe: Recipe) {
        let stamp = Self.nowISO()
        let newId = "rec_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased())"
        let clean = Recipe(
            id: newId,
            title: recipe.title,
            sourceURL: recipe.sourceURL,
            sourceDomain: recipe.sourceDomain,
            prepTime: recipe.prepTime,
            servings: recipe.servings,
            kcal: recipe.kcal,
            proteinG: recipe.proteinG,
            carbsG: recipe.carbsG,
            fatG: recipe.fatG,
            sodiumMg: recipe.sodiumMg,
            sugarG: recipe.sugarG,
            cholesterolMg: recipe.cholesterolMg,
            mealType: recipe.mealType,
            dietaryTags: recipe.dietaryTags,
            allergens: recipe.allergens,
            ingredients: recipe.ingredients,
            steps: recipe.steps,
            imagePath: nil,
            imageSource: "placeholder",
            isSaved: true,
            discoveredAt: recipe.discoveredAt.isEmpty ? stamp : recipe.discoveredAt,
            savedAt: stamp
        )
        queue.sync {
            insertRecipeRow(clean)
        }
    }

    func consumeLegacySQLiteGeminiKey() -> String? {
        queue.sync {
            let legacy = getSettingInternal("gemini_api_key", default: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !legacy.isEmpty {
                exec("DELETE FROM app_settings WHERE key = 'gemini_api_key';")
                return legacy
            }
            return nil
        }
    }

    func wipeAllUserData() {
        queue.sync {
            exec("BEGIN IMMEDIATE;")
            exec("DELETE FROM routine_items;")
            exec("DELETE FROM weekly_schedule;")
            exec("DELETE FROM date_schedule;")
            exec("DELETE FROM routines;")
            exec("DELETE FROM workout_sets;")
            exec("DELETE FROM weight_logs;")
            exec("DELETE FROM macro_logs;")
            exec("DELETE FROM cycle_logs;")
            exec("DELETE FROM recipes;")
            exec("DELETE FROM exercises WHERE is_custom = 1;")
            exec("DELETE FROM day_routines;")
            exec("DELETE FROM routine_exercises;")
            exec("COMMIT;")
            exec("VACUUM;")

            for dir in [savedMediaDir, cacheMediaDir] {
                if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                    for f in files {
                        try? FileManager.default.removeItem(at: f)
                    }
                }
            }
            syncMoveKitManifest()
        }
    }
}
