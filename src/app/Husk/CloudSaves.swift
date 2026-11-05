// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A game's saves kept off the iPhone, two ways:
///
/// - **The game's own online saves**, through Google Play Games (Play/PlayGamesSignIn.swift): a game that saves to its own
///   server under its Play Games player (Idling to Rule the Gods) gets the same player as on Android, from the Google account
///   signed in to Husk, and loads and saves its online progress itself.
/// - **iCloud Drive**: every game's saves, as the .zip Back Up Saves makes (SaveBackup), written to a folder the person
///   chooses once in iCloud Drive (no iCloud entitlement needed, so sideloaded Husk can do it). Each time Husk leaves the
///   screen with a game loaded, that game's saves are copied there, the last ten kept, so a lost or replaced iPhone loses
///   nothing; the latest is restored from the game's page.
enum ICloudSaves {
    struct Failure: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    private static let folderKey = "husk.cloudSaves.folder"
    static let autoKey = "husk.cloudSaves.auto"
    private static let keep = 10

    static var hasFolder: Bool { UserDefaults.standard.data(forKey: folderKey) != nil }
    static var isAutomatic: Bool { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }

    /// The folder's name, for the page.
    static var folderName: String? {
        guard let data = UserDefaults.standard.data(forKey: folderKey) else { return nil }
        var stale = false
        return (try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))?.lastPathComponent
    }

    /// Keep access to the folder picked in Files (a bookmark carries the permission the picker gave).
    static func chooseFolder(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            throw Failure("Choose a folder in iCloud Drive, not a file.")
        }
        UserDefaults.standard.set(try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), forKey: folderKey)
        HuskLog.log("saves", "iCloud Drive folder for saves: \(url.lastPathComponent)")
    }

    private static func withFolder<T>(_ body: (URL) throws -> T) throws -> T {
        guard let data = UserDefaults.standard.data(forKey: folderKey) else { throw Failure("Choose an iCloud Drive folder first.") }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            throw Failure("The saves folder cannot be found any more. Choose it again.")
        }
        guard folder.startAccessingSecurityScopedResource() else { throw Failure("Husk may no longer use the saves folder. Choose it again.") }
        defer { folder.stopAccessingSecurityScopedResource() }
        // A bookmark that went stale still opens; it is renewed while it does.
        if stale, let fresh = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: folderKey)
        }
        return try body(folder)
    }

    /// Backups of one game are named after its package, so they are found again on another iPhone and never mixed up.
    private static func filePrefix(_ app: TLApp) -> String {
        let pkg = app.packageName ?? app.id
        return "husk-" + String(pkg.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") ? $0 : "-" }) + "-"
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static func backups(_ app: TLApp, in folder: URL) throws -> [URL] {
        var listed: [URL] = [], failure: Error?, coordination: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: folder, options: [], error: &coordination) { dir in
            do {
                listed = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                    .filter { $0.lastPathComponent.hasPrefix(filePrefix(app)) && $0.pathExtension.lowercased() == "zip" }
            } catch { failure = error }
        }
        if let coordination { throw coordination }
        if let failure { throw failure }
        return listed.sorted { $0.lastPathComponent < $1.lastPathComponent }      // the names sort by time
    }

    /// A new backup in the folder (never over an older one), then all but the last ten removed. Returns its name.
    @discardableResult
    static func backUp(_ app: TLApp) throws -> String {
        try withFolder { folder in
            let fm = FileManager.default
            let archive = try SaveBackup.export(app)
            defer { try? fm.removeItem(at: archive) }
            let name = filePrefix(app) + stamp() + ".zip"
            let dest = folder.appendingPathComponent(name)
            var failure: Error?, coordination: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: dest, options: .forReplacing, error: &coordination) { target in
                do {
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.copyItem(at: archive, to: target)
                } catch { failure = error }
            }
            if let coordination { throw coordination }
            if let failure { throw failure }
            let all = (try? backups(app, in: folder)) ?? []
            for old in all.dropLast(keep) {
                var c: NSError?
                NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: old, options: .forDeleting, error: &c) { url in _ = try? fm.removeItem(at: url) }
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "husk.cloudSaves.last.\(app.id)")
            HuskLog.log("saves", "\(app.label): saves copied to iCloud Drive as \(name)")
            return name
        }
    }

    /// When this game's saves were last copied to iCloud Drive from this iPhone.
    static func lastBackup(_ app: TLApp) -> Date? {
        let t = UserDefaults.standard.double(forKey: "husk.cloudSaves.last.\(app.id)")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// The newest backup of this game, copied out of iCloud Drive (downloaded first if only its placeholder is here) for
    /// SaveBackup.restore, which checks it is this game's.
    static func latest(_ app: TLApp) throws -> (file: URL, name: String) {
        try withFolder { folder in
            guard let newest = try backups(app, in: folder).last else { throw Failure("There is no backup of \(app.label) in iCloud Drive yet.") }
            let fm = FileManager.default
            try? fm.startDownloadingUbiquitousItem(at: newest)
            let tmp = fm.temporaryDirectory.appendingPathComponent("husk-icloud-\(UUID().uuidString).zip")
            var failure: Error?, coordination: NSError?
            // Coordinated reading waits for iCloud Drive to bring the file down.
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: newest, options: [], error: &coordination) { src in
                do { try fm.copyItem(at: src, to: tmp) } catch { failure = error }
            }
            if let coordination { throw coordination }
            if let failure { throw failure }
            return (tmp, newest.lastPathComponent)
        }
    }

    // MARK: automatically

    /// Once, at launch: each time Husk goes to the background with a game loaded, its saves go to iCloud Drive.
    static func install() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in backUpLoadedGame(reason: "Husk went to the background") }
        }
    }

    @MainActor static func backUpLoadedGame(reason: String) {
        guard isAutomatic, hasFolder,
              let loaded = husk_native_loaded_apk().map({ String(cString: $0) }),
              let app = TranslationLayerStore.shared.apps.first(where: { $0.apks.first == loaded }),
              SaveBackup.hasData(app) else { return }
        // Not more than once a minute: switching apps back and forth should not fill the folder.
        if let last = lastBackup(app), Date().timeIntervalSince(last) < 60 { return }
        // Time to finish once the screen is off; ended on the main thread, once, whichever comes first.
        final class Grace { var id: UIBackgroundTaskIdentifier = .invalid
            func end() { if id != .invalid { UIApplication.shared.endBackgroundTask(id); id = .invalid } } }
        let grace = Grace()
        grace.id = UIApplication.shared.beginBackgroundTask(withName: "Husk iCloud saves") { grace.end() }
        // The game has just been paused, and Unity writes its preferences as it pauses: a moment for that first.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
            do { try backUp(app) } catch { HuskLog.log("saves", "\(app.label): iCloud Drive backup (\(reason)) failed: \(error.localizedDescription)") }
            DispatchQueue.main.async { grace.end() }
        }
    }
}

/// The game page's Cloud Saves section: Play Games (the game's own online saves) and iCloud Drive.
struct CloudSavesSection: View {
    let app: TLApp
    /// The game was started in this run of Husk: its files are in use, so restoring waits for a fresh start.
    let loadedNow: Bool
    /// A restore the page confirms and runs (as for a .zip picked in Files); the name is shown instead of the temporary file's.
    let restore: (URL, String) -> Void

    @ObservedObject private var store = PlayStoreManager.shared
    @AppStorage(ICloudSaves.autoKey) private var automatic = true
    @State private var showSignIn = false
    @State private var checking = false
    @State private var player: PlayGamesSignIn.Player?
    @State private var message: String?
    @State private var busy = false
    @State private var folder: String? = ICloudSaves.folderName

    private var googleAccount: PlaySession? {
        guard let s = store.session, !s.isAnonymous, !s.aasToken.isEmpty else { return nil }
        return s
    }

    var body: some View {
        Section {
            // Play Games
            if let s = googleAccount {
                LabeledContent("Google Account", value: s.email)
                if let player {
                    LabeledContent("Play Games Player", value: player.name.isEmpty ? player.id : player.name)
                    LabeledContent("Player ID", value: player.id).textSelection(.enabled)
                }
                Button { check() } label: {
                    Label(checking ? "Signing In to Play Games…" : "Check Play Games Sign-In", systemImage: "person.crop.circle.badge.checkmark")
                }
                .disabled(checking)
            } else {
                Button { showSignIn = true } label: {
                    Label(store.session?.isAnonymous == true ? "Sign In with Your Own Google Account" : "Sign In with Google", systemImage: "person.badge.key")
                }
            }

            // iCloud Drive
            Button { chooseFolder() } label: {
                Label(folder.map { "iCloud Drive Folder: \($0)" } ?? "Choose iCloud Drive Folder", systemImage: "folder.badge.plus")
            }
            .disabled(busy)
            if folder != nil {
                Toggle(isOn: $automatic) { Label("Back Up When Leaving Husk", systemImage: "icloud") }
                Button { backUpNow() } label: { Label("Back Up to iCloud Drive Now", systemImage: "icloud.and.arrow.up") }
                    .disabled(busy || !SaveBackup.hasData(app))
                Button { restoreLatest() } label: { Label("Restore Latest from iCloud Drive", systemImage: "icloud.and.arrow.down") }
                    .disabled(busy || loadedNow)
            }
        } header: {
            Text("Cloud Saves")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let message { Text(message) }
                if googleAccount == nil {
                    Text("Games that save online with Google Play Games (Idling to Rule the Gods' Save Online and Load Online) need your own Google account: the game then finds the same player, and the same online saves, as on Android.")
                } else {
                    Text("\(app.label) signs in to Google Play Games as this account's player, as on Android. In-game online saves and loads go to the game's own servers.")
                }
                if folder == nil {
                    Text("Choose a folder in iCloud Drive (for example a new \"Husk Saves\" folder) and every game's saves are copied there each time you leave Husk while it is loaded.")
                } else if let d = ICloudSaves.lastBackup(app) {
                    Text("Last copied to iCloud Drive \(d.formatted(.relative(presentation: .named))).")
                }
            }
        }
        .sheet(isPresented: $showSignIn) { GoogleSignInSheet() }
    }

    private func check() {
        checking = true; message = nil
        let game = PlayGamesSignIn.Game(package: app.packageName, apk: app.apks.first)
        DispatchQueue.global(qos: .userInitiated).async {
            let r = PlayGamesSignIn.player(game, interactive: true)
            DispatchQueue.main.async {
                checking = false
                switch r {
                case .success(let p): player = p; message = "Signed in to Play Games for \(app.label)."
                case .failure(let e): player = nil; message = e.errorDescription
                }
            }
        }
    }

    private func chooseFolder() {
        HuskFilePicker.present(types: [.folder], multiple: false) { urls in
            guard let url = urls.first else { return }
            do { try ICloudSaves.chooseFolder(url); folder = ICloudSaves.folderName; message = nil }
            catch { message = error.localizedDescription }
        } onFail: { message = $0 }
    }

    private func backUpNow() {
        busy = true; message = nil
        let app = self.app
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try ICloudSaves.backUp(app) }
            DispatchQueue.main.async {
                busy = false
                switch r {
                case .success(let name): message = "Copied to iCloud Drive as \(name)."
                case .failure(let e): message = e.localizedDescription
                }
            }
        }
    }

    private func restoreLatest() {
        busy = true; message = nil
        let app = self.app
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try ICloudSaves.latest(app) }
            DispatchQueue.main.async {
                busy = false
                switch r {
                case .success(let found): restore(found.file, found.name)
                case .failure(let e): message = e.localizedDescription
                }
            }
        }
    }
}
