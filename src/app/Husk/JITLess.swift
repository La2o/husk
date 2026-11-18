// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Husk 3.2's experimental JIT-less mode. An Android game's libraries run from Mach-O dylibs made from them ahead of time, with the
/// translation layer's code rewrites already applied, and signed: iOS maps signed code as executable on its own, so the game needs
/// no JIT -- no debugger, no StikJIT. The dylibs come from two places: the app's Frameworks (aot-<hash>-<library>.dylib, made on
/// the Mac and signed with the app by the installer), and a folder of the app's own where Husk converts a game's libraries before
/// its first JIT-less start and signs them with the user's developer certificate (SigningCertificate). An engine that generates
/// code at run time (Geode's mods, a Mono or LuaJIT JIT) still needs JIT.
enum JITLess {
    static let key = "husk.jitless"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Prebuilt: the app's Frameworks, where the installer signs them with the app.
    static var bundledDirectory: String? { Bundle.main.privateFrameworksPath }

    /// Made on this device.
    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("JITless", isDirectory: true)
    }

    /// How many libraries this build carries as dylibs.
    static var libraryCount: Int {
        guard let dir = bundledDirectory, let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return 0 }
        return names.filter { $0.hasPrefix("aot-") && $0.hasSuffix(".dylib") }.count
    }

    /// The size of what was made on this device, for Settings.
    static var cacheBytes: Int64 {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)) ?? []
        return names.reduce(0) { sum, n in
            sum + ((try? FileManager.default.attributesOfItem(atPath: cacheDirectory.appendingPathComponent(n).path)[.size] as? Int64) ?? 0)
        }
    }

    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        HuskLog.log("tl", "JIT-less: converted libraries removed")
    }

    enum PrepareError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let why) = self { return why }; return nil }
    }

    /// Before a game's JIT-less start: its libraries converted and signed (once; again only when the certificate changes). With no
    /// certificate imported, only prebuilt dylibs can be used, and this does nothing.
    /// The Java runtime's own native libraries (libjavacore, libopenjdk, ICU, conscrypt...), which apps on Husk's Java runtime load
    /// from the app bundle: converted on the device like a game's, once.
    static var runtimeLibraries: [String] {
        guard let root = Bundle.main.resourcePath.map({ $0 + "/java-runtime" }),
              let e = FileManager.default.enumerator(atPath: root) else { return [] }
        return e.compactMap { $0 as? String }.filter { $0.hasSuffix(".so") }.map { root + "/" + $0 }
    }

    private static var chainLoaded = false

    static func prepare(apks: [String], progress: @escaping @Sendable (String) -> Void) async throws {
        guard enabled, let cred = SigningCertificate.credentials() else { return }
        // An expired certificate signs libraries iOS will not load: say so now rather than after converting them.
        let expires = await MainActor.run { SigningCertificate.shared.info?.expires }
        if let expires, expires < Date() {
            HuskLog.log("sign", "JIT-less: the imported certificate expired on \(expires)")
            throw PrepareError.failed("The certificate imported for Play without JIT expired on "
                + "\(expires.formatted(date: .abbreviated, time: .omitted)). Refresh Husk in SideStore or AltStore (or get a new "
                + "certificate from your signing service), then import its certificate again in Settings › Play without JIT.")
        }
        let apks = apks + runtimeLibraries
        // The certificates above the developer certificate, for iOS to trust the signatures: from Husk's own signature, which the
        // store made with the same certificate and its whole chain (a store's .p12 holds the developer certificate alone).
        if !chainLoaded, let exe = Bundle.main.executablePath {
            chainLoaded = true
            HuskLog.log("sign", "certificate chain from Husk's own signature: \(husk_codesign_chain_from_executable(exe)) certificates")
        }
        // The signer revision and the running app's bundle ID are part of the tag: libraries signed by an older signer, or
        // under another install's identifier (SideStore appends the team, a TrollStore/enterprise install may not), are signed again.
        let ident = Bundle.main.bundleIdentifier ?? "com.husk.app"
        let tag = cred.tag + "-s15-" + ident
        let dir = cacheDirectory.path
        try await Task.detached(priority: .userInitiated) { [ident] in
            final class Box { let report: (String) -> Void; init(_ r: @escaping (String) -> Void) { report = r } }
            let box = Box(progress)
            let user = Unmanaged.passRetained(box).toOpaque()
            defer { Unmanaged<Box>.fromOpaque(user).release() }
            var cPaths = apks.map { strdup($0) }
            defer { cPaths.forEach { free($0) } }
            var err = [CChar](repeating: 0, count: 300)
            let started = Date()
            let n = cPaths.withUnsafeMutableBufferPointer { paths -> Int32 in
                paths.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: paths.count) { list in
                    cred.p12.withUnsafeBytes { p12 in
                        ident.withCString { identC in
                            husk_aot_prepare(list, Int32(paths.count), dir, p12.bindMemory(to: UInt8.self).baseAddress, p12.count,
                                             cred.password, tag, identC, { user, index, total, lib in
                                                 guard let user, let lib else { return }
                                                 let box = Unmanaged<Box>.fromOpaque(user).takeUnretainedValue()
                                                 box.report("Preparing \(String(cString: lib)) (\(index + 1) of \(total))")
                                             }, user, &err, err.count)
                        }
                    }
                }
            }
            guard n >= 0 else {
                let why = String(cString: err)
                HuskLog.log("tl", "JIT-less: preparing failed: \(why)")
                throw PrepareError.failed(why)
            }
            HuskLog.log("tl", "JIT-less: \(n) libraries ready in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            try JITLess.testSigned(tag: tag, dir: dir)
        }.value
    }

    /// Tags whose signed libraries were tested in this run (testSigned), so the test is not repeated on every Play.
    private static var testedTags = Set<String>()
    private static let testLock = NSLock()

    /// Whether iOS accepts what was signed with the certificate: one library signed under `tag` dlopen()ed, the smallest, preferring
    /// one every game loads anyway. The dylibs hold no initializers (Husk runs the ELF constructors itself), so dlopen only maps and
    /// validates it. It is never dlclose()d: the loader dlopen()s the same path later and gets the same handle, and dyld cannot be
    /// asked to forget it safely (husk-tl-ld.c aot_import). Throws when iOS refuses the signature, after making the libraries
    /// signed under `tag` be signed again next time; any other failure is only logged, for the loader to report.
    private static func testSigned(tag: String, dir: String) throws {
        testLock.lock()
        defer { testLock.unlock() }
        if testedTags.contains(tag) { return }
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        func signer(_ name: String) -> String? { try? String(contentsOfFile: dir + "/" + name, encoding: .utf8) }
        func size(_ name: String) -> Int64 { (try? fm.attributesOfItem(atPath: dir + "/" + name)[.size] as? Int64) ?? Int64.max }
        let signed = names.filter { $0.hasSuffix(".dylib") && signer($0 + ".signer") == tag }
        let preferred = signed.filter { $0.contains("libnativehelper") || $0.contains("libandroidio") }
        guard let pick = (preferred.isEmpty ? signed : preferred).min(by: { size($0) < size($1) }) else { return }
        if dlopen(dir + "/" + pick, RTLD_NOW | RTLD_LOCAL) != nil {
            testedTags.insert(tag)
            HuskLog.log("tl", "JIT-less: iOS accepts the signed libraries (\(pick))")
            return
        }
        var why = "no reason given"
        if let e = dlerror() { why = String(cString: e) }
        guard why.contains("code signature") else {
            testedTags.insert(tag)
            HuskLog.log("tl", "JIT-less: test load of \(pick) failed: \(why)")
            return
        }
        HuskLog.log("tl", "JIT-less: iOS refused a signed library: \(why)")
        // The libraries stay; without their .signer files they are signed again on the next start.
        for name in names where name.hasSuffix(".signer") && signer(name) == tag {
            try? fm.removeItem(atPath: dir + "/" + name)
        }
        throw PrepareError.failed("iOS refused the libraries Husk signed with your certificate, so the game cannot start without JIT. "
            + "Usually the certificate imported in Settings › Play without JIT has been revoked or replaced: SideStore and AltStore "
            + "make a new one when they refresh, and signing in with the same Apple ID elsewhere (another phone, Sideloadly, Xcode) "
            + "can revoke it. Import the certificate that installed Husk again, then start the game. Or turn off Play without JIT "
            + "and use JIT.")
    }

    /// Before a game starts: no executable memory is made in this run (even when JIT is on, so the test is real), and libraries
    /// come from the dylibs. A library with no dylib cannot load, and the log says which one.
    static func prepareLaunch() {
        guard enabled else { return }
        setenv("TL_NO_XMEM", "1", 1)
        let dirs = [bundledDirectory, cacheDirectory.path].compactMap { $0 }.joined(separator: ":")
        tl_ld_set_aot_dir(dirs)
        HuskLog.log("tl", "JIT-less mode (experimental): libraries from dylibs (\(libraryCount) prebuilt, certificate "
                         + "\(SigningCertificate.credentials() == nil ? "not imported" : "imported")); no executable memory is made")
    }
}
