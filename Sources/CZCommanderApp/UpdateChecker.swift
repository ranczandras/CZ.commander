import SwiftUI
import AppKit
import Security
import CZCommanderCore

/// Checks GitHub Releases for a newer CZ.commander and offers the download.
/// Only the public GitHub API is contacted; nothing about the user is sent.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let repository = "ranczandras/CZ.commander"

    struct AvailableUpdate: Equatable {
        let version: String
        let pageURL: URL
        let zipURL: URL?
    }

    @Published var available: AvailableUpdate?
    @Published var isChecking = false
    @Published var installStatus: String?   // non-nil while downloading / installing

    private let defaults = UserDefaults.standard
    private let lastCheckKey = "CZLastUpdateCheck"
    private let skippedKey = "CZSkippedUpdateVersion"
    private let autoKey = "CZCheckForUpdatesAtLaunch"

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var releasesPage: URL { URL(string: "https://github.com/\(Self.repository)/releases")! }

    var checksAutomatically: Bool {
        get { defaults.object(forKey: autoKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: autoKey); objectWillChange.send() }
    }

    /// Dev self-test: `CZ_UPDATE_SELFTEST_ZIP=/path/CZ.commander-x.zip` installs that zip over the
    /// running copy exactly like a GitHub update.
    func runSelfTestIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["CZ_UPDATE_SELFTEST_ZIP"] else { return false }
        available = AvailableUpdate(version: "99.0.0", pageURL: releasesPage, zipURL: URL(fileURLWithPath: path))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.installAndRelaunch() }
        return true
    }

    /// At launch: at most once every 12 hours, and only when enabled.
    func checkAtLaunchIfDue() {
        guard checksAutomatically else { return }
        let last = defaults.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 12 * 3600 else { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CZ.commander", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        struct Release: Decodable {
            let tag_name: String
            let html_url: String
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]?
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                if userInitiated { report("Could not reach GitHub to check for updates.") }
                return
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            defaults.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
            let latest = AppVersion.components(release.tag_name).map(String.init).joined(separator: ".")
            guard release.draft != true, release.prerelease != true,
                  AppVersion.isNewer(latest, than: currentVersion) else {
                if userInitiated { report("CZ.commander \(currentVersion) is up to date.") }
                return
            }
            if !userInitiated, defaults.string(forKey: skippedKey) == latest { return }
            let zip = release.assets?.first { $0.name.hasPrefix("CZ.commander") && $0.name.hasSuffix(".zip") }
            available = AvailableUpdate(
                version: latest,
                pageURL: URL(string: release.html_url) ?? releasesPage,
                zipURL: zip.flatMap { URL(string: $0.browser_download_url) }
            )
        } catch {
            if userInitiated { report("Update check failed: \(error.localizedDescription)") }
        }
    }

    func openReleasePage() {
        if let available { NSWorkspace.shared.open(available.pageURL) }
    }

    // MARK: - In-app install

    /// Downloads the release zip, checks that the new app is signed by the same identity as the
    /// running one, replaces the installed bundle and relaunches.
    func installAndRelaunch() {
        guard let update = available, let zipURL = update.zipURL, installStatus == nil else {
            openReleasePage(); return
        }
        installStatus = "Downloading CZ.commander \(update.version)…"
        Task {
            do {
                let fm = FileManager.default
                let work = fm.temporaryDirectory.appendingPathComponent("CZ.commander-update-\(UUID().uuidString)")
                try fm.createDirectory(at: work, withIntermediateDirectories: true)

                var request = URLRequest(url: zipURL)
                request.setValue("CZ.commander", forHTTPHeaderField: "User-Agent")
                let (tmpZip, response) = try await URLSession.shared.download(for: request)
                guard zipURL.isFileURL || (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.message("Download failed.") }
                let zip = work.appendingPathComponent("update.zip")
                try fm.moveItem(at: tmpZip, to: zip)

                installStatus = "Installing CZ.commander \(update.version)…"
                let unpacked = work.appendingPathComponent("unpacked")
                try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
                guard let newApp = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.message("The download contains no app.") }
                try Self.verifySameSigner(newApp: newApp)
                try Self.replaceAndRelaunch(newApp: newApp, work: work)
            } catch {
                installStatus = nil
                report("Update failed: \(error.localizedDescription) Opening the release page instead.")
                openReleasePage()
            }
        }
    }

    enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    /// The new bundle must satisfy the running app's designated requirement (same bundle id and
    /// same signing certificate), so only builds signed by the same identity can be installed.
    private static func verifySameSigner(newApp: URL) throws {
        var selfCode: SecCode?
        var requirement: SecRequirement?
        var staticSelf: SecStaticCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &staticSelf) == errSecSuccess, let staticSelf,
              SecCodeCopyDesignatedRequirement(staticSelf, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError.message("Cannot read this app's signature.")
        }
        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(newApp as CFURL, [], &newCode) == errSecSuccess, let newCode else {
            throw UpdateError.message("Cannot read the update's signature.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(newCode, flags, requirement) == errSecSuccess else {
            throw UpdateError.message("The update is not signed by the same identity as this app.")
        }
    }

    /// A detached helper waits for this process to quit, swaps the bundle and opens the new app.
    private static func replaceAndRelaunch(newApp: URL, work: URL) throws {
        let target = Bundle.main.bundleURL
        let script = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(target.path).old"
        mv "\(target.path)" "\(target.path).old" && /usr/bin/ditto "\(newApp.path)" "\(target.path)" && rm -rf "\(target.path).old" || mv "\(target.path).old" "\(target.path)"
        /usr/bin/xattr -dr com.apple.quarantine "\(target.path)" 2>/dev/null
        open "\(target.path)"
        rm -rf "\(work.path)"
        """
        let scriptURL = work.appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [scriptURL.path]
        try helper.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.message("\((tool as NSString).lastPathComponent) failed.") }
    }

    func skipThisVersion() {
        if let available { defaults.set(available.version, forKey: skippedKey) }
        available = nil
    }

    func later() { available = nil }

    private func report(_ message: String) {
        CommanderViewModel.shared.statusBannerMessage = message
    }
}

/// Banner shown under the title bar when a newer release exists.
struct UpdateBanner: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        if let update = checker.available {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.white)
                Text(checker.installStatus ?? "CZ.commander \(update.version) is available (you have \(checker.currentVersion)).")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                if checker.installStatus == nil {
                    Button(update.zipURL == nil ? "Download" : "Install & Restart") { checker.installAndRelaunch() }
                        .buttonStyle(SquareProminentButtonStyle())
                    Button("Release Notes") { checker.openReleasePage() }
                    Button("Skip This Version") { checker.skipThisVersion() }
                    Button("Later") { checker.later() }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(red: 0.16, green: 0.42, blue: 0.85))
        }
    }
}
