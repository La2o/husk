// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// User-controlled iCloud Drive / Files backup for translation-layer games.
///
/// This is NOT Google Play Games or the game's own online account. Husk stores
/// complete, restorable local-save ZIPs in a Files folder chosen by the player.
/// Choosing iCloud Drive lets iOS sync those ZIPs between devices without
/// requiring an iCloud container entitlement on a Feather-signed app.
///
/// Backups and restores are explicit actions. Never upload during gameplay or
/// silently overwrite either the game's local files or an existing cloud ZIP.
enum CloudSave {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func key(_ app: TLApp) -> String {
        "husk.cloudSave.folder." + (app.packageName ?? app.id)
    }

    static func hasFolder(_ app: TLApp) -> Bool {
        UserDefaults.standard.data(forKey: key(app)) != nil
    }

    /// Remember access to the folder chosen with UIDocumentPicker (.folder).
    /// On iOS the bookmark includes the user's security-scoped permission.
    static func chooseFolder(_ app: TLApp, url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw Failure(message: "Choose a folder in iCloud Drive, not a file.")
        }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: key(app))
        HuskLog.log("saves", "cloud folder selected for \(app.label): \(url.lastPathComponent)")
    }

    private static func withFolder<T>(_ app: TLApp, _ body: (URL) throws -> T) throws -> T {
        guard let data = UserDefaults.standard.data(forKey: key(app)) else {
            throw Failure(message: "Choose an iCloud Drive folder first.")
        }
        var stale = false
        let folder: URL
        do {
            folder = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            throw Failure(message: "The cloud folder is no longer accessible. Choose it again.")
        }
        if stale {
            throw Failure(message: "The cloud folder permission expired. Choose the folder again.")
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        guard scoped else {
            throw Failure(message: "Cannot access the saved cloud folder. Choose it again in Files.")
        }
        defer { folder.stopAccessingSecurityScopedResource() }
        return try body(folder)
    }

    /// A stable prefix allows files to be found across Husk reinstalls and on
    /// another iPhone. We never list or restore backups for another package.
    private static func prefix(_ app: TLApp) -> String {
        let pkg = (app.packageName ?? app.id)
        let safe = pkg.map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber || ch == "." || ch == "-")) ? ch : "-"
        }
        return "husk-" + String(safe) + "-"
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// Save a new ZIP with a unique filename; never overwrite a previous save.
    /// GamePage disables this while the game's engine is loaded.
    static func backUp(_ app: TLApp) throws -> String {
        try withFolder(app) { folder in
            let fm = FileManager.default
            let archive = try SaveBackup.export(app)
            defer { try? fm.removeItem(at: archive) }

            let filename = prefix(app) + timestamp() + "-" + String(UUID().uuidString.prefix(8)) + ".zip"
            let destination = folder.appendingPathComponent(filename, isDirectory: false)
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var operationError: Error?
            coordinator.coordinate(writingItemAt: destination, options: [], error: &coordinationError) { target in
                do { try fm.copyItem(at: archive, to: target) }
                catch { operationError = error }
            }
            if let error = coordinationError { throw error }
            if let error = operationError { throw error }
            HuskLog.log("saves", "cloud backup of \(app.label): \(filename)")
            return filename
        }
    }

    /// Download the newest matching ZIP into Husk's sandbox. The ordinary
    /// SaveBackup.restore() manifest/package checks then validate the archive.
    /// GamePage asks for explicit confirmation before replacing local saves.
    static func newestBackupForRestore(_ app: TLApp) throws -> (file: URL, name: String) {
        try withFolder(app) { folder in
            let fm = FileManager.default
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var listError: NSError?
            var operationError: Error?
            var candidates: [URL] = []

            coordinator.coordinate(readingItemAt: folder, options: [], error: &listError) { readableFolder in
                do {
                    candidates = try fm.contentsOfDirectory(at: readableFolder,
                        includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).filter {
                            $0.lastPathComponent.hasPrefix(prefix(app)) && $0.pathExtension.lowercased() == "zip"
                        }
                } catch { operationError = error }
            }
            if let error = listError { throw error }
            if let error = operationError { throw error }
            guard let newest = candidates.max(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
                throw Failure(message: "No cloud backup for \(app.label) in that folder.")
            }

            let temporary = fm.temporaryDirectory.appendingPathComponent("husk-cloud-restore-" + UUID().uuidString + ".zip")
            var readError: NSError?
            operationError = nil
            coordinator.coordinate(readingItemAt: newest, options: [], error: &readError) { readableFile in
                do { try fm.copyItem(at: readableFile, to: temporary) }
                catch { operationError = error }
            }
            if let error = readError { throw error }
            if let error = operationError { throw error }
            HuskLog.log("saves", "cloud restore downloaded for \(app.label): \(newest.lastPathComponent)")
            return (temporary, newest.lastPathComponent)
        }
    }
}
