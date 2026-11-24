// MARK: - Private Apple iCloud Backup & Sync
//
// Optional zero-developer-server sync to the user's own CloudKit private zone (`VeldaPrivateZone`)
// and local/iCloud Drive JSON snapshots. Live CloudKit calls are gated behind `VeldaCloudKitEnabled`
// in `Info.plist` so builds without an active iCloud container fall back gracefully to Drive export.

import CloudKit
import Foundation
import UIKit

@MainActor
final class CloudSyncService: ObservableObject {
    static let shared = CloudSyncService()

    static let containerIdentifier = "iCloud.com.veldaapp.veldafitness"
    private let zoneID = CKRecordZone.ID(zoneName: "VeldaPrivateZone", ownerName: CKCurrentUserDefaultName)
    private let recordID = CKRecord.ID(
        recordName: "primary_snapshot",
        zoneID: CKRecordZone.ID(zoneName: "VeldaPrivateZone", ownerName: CKCurrentUserDefaultName)
    )

    @Published var isSyncing: Bool = false
    @Published var statusLabel: String = "Checking iCloud…"
    @Published var lastSyncAt: String? = UserDefaults.standard.string(forKey: "velda.icloud.last_sync_at")
    @Published var lastBackupAt: String? = UserDefaults.standard.string(forKey: "velda.icloud.last_backup_at")
    @Published var lastError: String? = nil
    @Published var driveBackups: [URL] = []

    var isCloudKitConfiguredInBuild: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "VeldaCloudKitEnabled") as? Bool) ?? false
    }

    var isAppleIDSignedInOnDevice: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    private init() {
        refreshStatus()
    }

    func refreshStatus() {
        if !isCloudKitConfiguredInBuild {
            statusLabel = "Private iCloud Sync Ready · Enable iCloud capability with your Apple Developer Team to activate live CloudKit sync. Files / iCloud Drive export works now."
            return
        }
        if !isAppleIDSignedInOnDevice {
            statusLabel = "Sign in to iCloud in iOS Settings to sync with your private Apple storage."
            return
        }

        let container = CKContainer(identifier: Self.containerIdentifier)
        container.accountStatus { [weak self] status, err in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let err {
                    self.statusLabel = "iCloud status check: \(err.localizedDescription)"
                    return
                }
                switch status {
                case .available:
                    self.statusLabel = "Connected to your private Apple iCloud (uses your personal iCloud quota, zero Velda servers)."
                    self.refreshDriveBackupList()
                case .noAccount:
                    self.statusLabel = "No iCloud account signed in on this device."
                case .restricted:
                    self.statusLabel = "iCloud access is restricted on this device."
                case .couldNotDetermine:
                    self.statusLabel = "Could not determine iCloud account status."
                case .temporarilyUnavailable:
                    self.statusLabel = "iCloud is temporarily unavailable."
                @unknown default:
                    self.statusLabel = "Unknown iCloud status."
                }
            }
        }
    }

    func pushSnapshotToCloudKit(_ snapshot: VeldaFullSnapshot) async -> Bool {
        lastError = nil
        guard isCloudKitConfiguredInBuild else {
            lastError = "Enable iCloud capability & set VeldaCloudKitEnabled = YES in Info.plist once your Apple Developer Team is configured."
            return false
        }
        guard isAppleIDSignedInOnDevice else {
            lastError = "Sign in to iCloud in iOS Settings first."
            return false
        }

        isSyncing = true
        defer { isSyncing = false }

        do {
            let container = CKContainer(identifier: Self.containerIdentifier)
            let db = container.privateCloudDatabase
            try await ensurePrivateZoneExists(in: db)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)

            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("velda-cloudkit-\(UUID().uuidString.prefix(8)).json")
            try data.write(to: tmpURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: tmpURL) }

            let record: CKRecord
            do {
                record = try await db.record(for: recordID)
            } catch let ckErr as CKError where ckErr.code == .unknownItem {
                record = CKRecord(recordType: "VeldaLedgerSnapshot", recordID: recordID)
            }

            record["schemaVersion"] = snapshot.schemaVersion as CKRecordValue
            record["updatedAt"] = snapshot.exportedAt as CKRecordValue
            record["deviceName"] = UIDevice.current.name as CKRecordValue
            record["payloadAsset"] = CKAsset(fileURL: tmpURL)

            _ = try await db.save(record)
            let stamp = DatabaseManager.nowISO()
            lastSyncAt = stamp
            UserDefaults.standard.set(stamp, forKey: "velda.icloud.last_sync_at")
            statusLabel = "Synced to your private iCloud Database."
            return true
        } catch let ckErr as CKError {
            lastError = describeCKError(ckErr)
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func pullSnapshotFromCloudKit() async -> VeldaFullSnapshot? {
        lastError = nil
        guard isCloudKitConfiguredInBuild else {
            lastError = "Enable iCloud capability & set VeldaCloudKitEnabled = YES in Info.plist once your Apple Developer Team is configured."
            return nil
        }
        guard isAppleIDSignedInOnDevice else {
            lastError = "Sign in to iCloud in iOS Settings first."
            return nil
        }

        isSyncing = true
        defer { isSyncing = false }

        do {
            let container = CKContainer(identifier: Self.containerIdentifier)
            let db = container.privateCloudDatabase
            let record = try await db.record(for: recordID)
            guard let asset = record["payloadAsset"] as? CKAsset,
                  let fileURL = asset.fileURL else {
                lastError = "Private iCloud snapshot record had no payload asset."
                return nil
            }
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder().decode(VeldaFullSnapshot.self, from: data)
            let stamp = DatabaseManager.nowISO()
            lastSyncAt = stamp
            UserDefaults.standard.set(stamp, forKey: "velda.icloud.last_sync_at")
            statusLabel = "Restored from your private iCloud Database."
            return snapshot
        } catch let ckErr as CKError {
            lastError = describeCKError(ckErr)
            return nil
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - iCloud Drive Container Backups

    func ubiquityBackupDirectory() -> URL? {
        guard isCloudKitConfiguredInBuild,
              let root = FileManager.default.url(forUbiquityContainerIdentifier: Self.containerIdentifier) else {
            return nil
        }
        let dir = root.appendingPathComponent("Documents/VeldaBackups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func refreshDriveBackupList() {
        guard let dir = ubiquityBackupDirectory(),
              let items = try? FileManager.default.contentsOfDirectory(
                  at: dir,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ) else {
            driveBackups = []
            return
        }
        driveBackups = items
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func writeICloudDriveBackup(_ snapshot: VeldaFullSnapshot) -> URL? {
        lastError = nil
        guard let dir = ubiquityBackupDirectory() else {
            lastError = "iCloud Drive container requires iCloud Documents capability with your Apple Developer Team. Use Export Backup to save directly via the iOS Files sheet."
            return nil
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            let day = DatabaseManager.isoDate()
            let dest = dir.appendingPathComponent("velda-backup-\(day).json")
            try data.write(to: dest, options: .atomic)
            let stamp = DatabaseManager.nowISO()
            lastBackupAt = stamp
            UserDefaults.standard.set(stamp, forKey: "velda.icloud.last_backup_at")
            refreshDriveBackupList()
            return dest
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private func ensurePrivateZoneExists(in db: CKDatabase) async throws {
        do {
            _ = try await db.recordZone(for: zoneID)
        } catch let ckErr as CKError where ckErr.code == .zoneNotFound || ckErr.code == .userDeletedZone {
            _ = try await db.save(CKRecordZone(zoneID: zoneID))
        }
    }

    private func describeCKError(_ err: CKError) -> String {
        switch err.code {
        case .quotaExceeded:
            return "Your personal iCloud storage is full. Free up iCloud space or upgrade iCloud+ to continue syncing."
        case .notAuthenticated:
            return "Not signed into iCloud on this device."
        case .networkUnavailable, .networkFailure:
            return "Network unavailable. Your ledger remains saved locally on device."
        case .unknownItem:
            return "No backup found in your private iCloud yet. Tap Sync Now first."
        default:
            return err.localizedDescription
        }
    }
}
