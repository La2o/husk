// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// Updating a game that is already in the library.
///
/// Downloading a game again from the Store adds it as a second game with nothing saved in it. An update puts the newer
/// version's APKs in the place of the ones the game has (TranslationLayerStore.update) and keeps everything the game saved,
/// as an update on Android does. The newer version comes from Google Play (asked through the Store's session), or from files
/// the person picks or shares to Husk.
@MainActor
final class GameUpdates: ObservableObject {
    static let shared = GameUpdates()

    enum Phase: Equatable {
        case idle
        case checking
        /// Google Play has nothing newer than this version.
        case current(String)
        /// Google Play has this version, which is newer.
        case available(String)
        case downloading(Double)
        case installing
        /// Updated to this version.
        case updated(String)
        case failed(String)
    }

    /// By the game's id.
    @Published private(set) var phases: [String: Phase] = [:]
    private var offers: [String: PlayAPI.PlayApp] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var checked: [String: Date] = [:]

    func phase(_ app: TLApp) -> Phase { phases[app.id] ?? .idle }

    func isWorking(_ app: TLApp) -> Bool {
        switch phase(app) {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    /// The game's engine is loaded in this run of Husk, so its files are open: it cannot be updated until Husk is opened again.
    nonisolated static func loadedNow(_ app: TLApp) -> Bool {
        guard let loaded = husk_native_loaded_apk().map({ String(cString: $0) }) else { return false }
        return loaded == app.apks.first
    }

    nonisolated static func closeFirst(_ app: TLApp) -> String {
        "\(app.label) has been started in this run of Husk. Close Husk and open it again to update it."
    }

    private static func name(of play: PlayAPI.PlayApp) -> String {
        play.versionString.isEmpty ? "build \(play.versionCode)" : play.versionString
    }

    /// Ask Google Play which version it has. A quiet check (the game's page opening) is made at most once an hour per game,
    /// says nothing when it cannot be made, and never replaces what an update under way is showing.
    func check(_ app: TLApp, quiet: Bool = false) {
        guard !isWorking(app) else { return }
        guard let package = app.packageName else {
            if !quiet { phases[app.id] = .failed("Husk could not read which app this is, so it cannot look it up on Google Play.") }
            return
        }
        guard let session = PlayStoreManager.shared.session, !session.bearer.isEmpty else {
            if !quiet { phases[app.id] = .failed("Sign in on the Store tab first: Husk asks Google Play which version is the newest.") }
            return
        }
        if quiet {
            if case .available = phase(app) { return }
            if let last = checked[app.id], Date().timeIntervalSince(last) < 3600 { return }
        }
        checked[app.id] = Date()
        if !quiet { phases[app.id] = .checking }
        let id = app.id
        Task {
            let here = await Task.detached { TranslationLayerStore.installedVersion(app) }.value
            let answer: Phase?
            do {
                if let play = try await PlayAPI.details(packageName: package, session: session), play.versionCode > 0 {
                    if let mine = here?.code, play.versionCode <= mine {
                        answer = .current(here?.text ?? Self.name(of: play))
                    } else {
                        self.offers[id] = play
                        answer = .available(Self.name(of: play))
                    }
                    HuskLog.log("store", "update check for \(package): here \(here?.code.map { String($0) } ?? "?"), Google Play \(play.versionCode)")
                } else {
                    answer = quiet ? nil : .failed("Google Play does not list \(app.label) for this account, so Husk cannot tell whether there is a newer version. A newer APK can still be put in with Update from a File.")
                }
            } catch {
                HuskLog.log("store", "update check for \(package) failed: \(error.localizedDescription)")
                answer = quiet ? nil : .failed("Google Play did not answer (\(error.localizedDescription)). Open the Store tab once, then try again.")
            }
            // An update started meanwhile keeps what it shows.
            switch self.phase(app) {
            case .downloading, .installing, .updated: return
            default: break
            }
            if let answer { self.phases[id] = answer } else if self.phases[id] == .checking { self.phases[id] = .idle }
        }
    }

    /// Download the version Google Play has and put it in the game's place.
    func update(_ app: TLApp) {
        guard !isWorking(app), let play = offers[app.id] else { return }
        guard !Self.loadedNow(app) else { phases[app.id] = .failed(Self.closeFirst(app)); return }
        guard let session = PlayStoreManager.shared.session, !session.bearer.isEmpty else {
            phases[app.id] = .failed("Sign in on the Store tab first: the update is downloaded from Google Play.")
            return
        }
        let id = app.id
        phases[id] = .downloading(0)
        HuskLog.log("store", "downloading \(play.id) \(Self.name(of: play)) (vc \(play.versionCode)) as an update of \(app.label)")
        tasks[id] = Task {
            defer { self.tasks[id] = nil }
            do {
                let files = try await PlayAPI.downloadApp(packageName: play.id, versionCode: play.versionCode, session: session) { [weak self] fraction in
                    if case .downloading? = self?.phases[id] { self?.phases[id] = .downloading(fraction) }
                }
                defer { if let folder = files.first?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: folder) } }
                try Task.checkCancellation()
                await self.install(app, files: files, move: true)
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.phases[id] = .available(Self.name(of: play))
                    return
                }
                HuskLog.log("store", "update download of \(play.id) failed: \(error.localizedDescription)")
                self.phases[id] = .failed("The update could not be downloaded: \(error.localizedDescription)")
            }
        }
    }

    /// Stop a download under way.
    func cancel(_ app: TLApp) {
        if case .downloading = phase(app) { tasks[app.id]?.cancel() }
    }

    /// A newer version's files (a download, or what the person picked or shared), put in the game's place.
    @discardableResult
    func install(_ app: TLApp, files: [URL], move: Bool) async -> Result<TLAppVersion, TLUpdateFailure> {
        phases[app.id] = .installing
        let result = await TranslationLayerStore.shared.update(app, with: files, move: move)
        switch result {
        case .success(let version):
            offers[app.id] = nil
            phases[app.id] = .updated(version.text)
        case .failure(let failure):
            phases[app.id] = .failed(failure.message)
        }
        return result
    }

    func report(_ app: TLApp, failure: String) { phases[app.id] = .failed(failure) }
}

/// The game page's Version section: which version is here, whether Google Play has a newer one, and updating to it.
struct GameUpdateSection: View {
    let app: TLApp

    @ObservedObject private var updates = GameUpdates.shared
    @State private var installed: TLAppVersion?

    private var loaded: Bool { GameUpdates.loadedNow(app) }

    private var versionShown: String {
        if case .updated(let version) = updates.phase(app) { return version }
        return installed?.text ?? "—"
    }

    var body: some View {
        let phase = updates.phase(app)
        Section {
            LabeledContent("Installed", value: versionShown)
            switch phase {
            case .downloading(let fraction):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: min(max(fraction, 0), 1))
                    Text("Downloading the update…").font(.footnote).foregroundStyle(.secondary)
                }
                Button("Stop", role: .cancel) { updates.cancel(app) }
            case .installing:
                Label("Putting the new version in place…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            case .available(let version):
                Button { updates.update(app) } label: {
                    Label("Update to \(version)", systemImage: "arrow.down.circle.fill")
                }
                .disabled(loaded)
            default:
                Button { updates.check(app) } label: {
                    Label(phase == .checking ? "Asking Google Play…" : "Check for Update", systemImage: "arrow.clockwise")
                }
                .disabled(phase == .checking)
            }
            Button { pickFiles() } label: { Label("Update from a File", systemImage: "doc.badge.plus") }
                .disabled(updates.isWorking(app) || loaded)
        } header: {
            Text("Version")
        } footer: {
            Text(footer(phase))
        }
        .task(id: app.apks) {
            let app = self.app
            installed = await Task.detached { TranslationLayerStore.installedVersion(app) }.value
            updates.check(app, quiet: true)
        }
    }

    private func footer(_ phase: GameUpdates.Phase) -> String {
        switch phase {
        case .failed(let why): return why
        case .updated(let version): return "Updated to \(version). Everything \(app.label) had saved is kept."
        case .available(let version) where loaded: return "Version \(version) is on Google Play. " + GameUpdates.closeFirst(app)
        case .available(let version):
            return "Version \(version) is on Google Play. Updating replaces the game's files and keeps everything it has saved. To be able to go back, back up its saves first."
        case .current(let version): return "\(version) is the newest version on Google Play."
        default:
            if loaded { return GameUpdates.closeFirst(app) }
            return "An update replaces \(app.label)'s files with a newer version's and keeps everything it has saved, as an update on Android does. Downloading the game again from the Store would add a second copy with nothing saved in it."
        }
    }

    /// A newer version from Files: its APK, or its base APK and splits together, or a bundle of them (.xapk, .apkm, .apks).
    private func pickFiles() {
        let app = self.app
        HuskFilePicker.present(types: [.item], multiple: true, onPick: { urls in
            let wanted = urls.filter { IncomingFiles.extensions.contains($0.pathExtension.lowercased()) }
            Task { @MainActor in
                guard !wanted.isEmpty else {
                    GameUpdates.shared.report(app, failure: "Pick the newer version's APK (or its APKs together, or an .xapk, .apkm or .apks bundle).")
                    return
                }
                await GameUpdates.shared.install(app, files: wanted, move: false)
            }
        }, onFail: { why in
            Task { @MainActor in GameUpdates.shared.report(app, failure: why) }
        })
    }
}
