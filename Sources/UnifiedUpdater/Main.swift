import AppKit
import SwiftUI
import UpdaterCore

@main
enum Entry {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--scan-json") || CommandLine.arguments.contains("--inventory-json") || CommandLine.arguments.contains("--check-startup-script") {
            let finished = DispatchSemaphore(value: 0)
            Task.detached {
                await diagnostics()
                finished.signal()
            }
            finished.wait()
            return
        }
        // Enter AppKit from a synchronous main, rather than holding a Swift
        // actor job open around its run loop and starving later UI Tasks.
        NSApplication.shared.setActivationPolicy(.regular)
        DesktopApp.main()
    }
    private static func diagnostics() async {
        if CommandLine.arguments.contains("--check-startup-script") {
            do {
                _ = try await ProcessRunner().run("/bin/bash", ["-n", DependencySetup.scriptURL.path]).checked()
                print("Bundled startup script is available and has valid syntax.")
            } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
            return
        }
            var preferences = Preferences()
            if let index = CommandLine.arguments.firstIndex(of: "--folder"), CommandLine.arguments.count > index + 1 {
                preferences.scanRoots = [CommandLine.arguments[index + 1]]
                preferences.includeSystemApplications = false
            }
            do {
                let result: ScanResult
                if CommandLine.arguments.contains("--inventory-json") {
                    let inventory = AppInventory().discover(roots: preferences.inventoryRoots, includeSystem: preferences.includeSystemApplications ?? true)
                    result = ScanResult(apps: inventory.apps, sources: [], warnings: inventory.warnings)
                } else {
                    let root = ProcessInfo.processInfo.environment["UNIFIED_UPDATER_DATA_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("SourceCache") }
                    result = await ScanService(cacheRoot: root).scan(preferences: preferences)
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                FileHandle.standardOutput.write(try encoder.encode(result)); FileHandle.standardOutput.write(Data("\n".utf8))
            } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
}

struct DesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Unified Updater") {
            ContentView().environmentObject(model).onAppear {
                AppDelegate.model = model
                model.start()
            }
        }
            .defaultSize(width: 1240, height: 800)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates") { model.scan() }.keyboardShortcut("r", modifiers: .command).disabled(model.busy)
                    Button("Export Report…") { model.exportReport() }
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, model.updating || model.settingUp else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = model.settingUp ? "Update sources are being prepared" : "An update queue is still running"
        alert.informativeText = model.settingUp
            ? "Keep the app open until source setup finishes. You can cancel authorization in the macOS dialog. An active installer must finish before the app quits."
            : "Keep the app open until the active installer finishes. You can cancel the remaining apps and quit after the current operation completes."
        alert.addButton(withTitle: "Keep App Open")
        if !model.settingUp { alert.addButton(withTitle: "Cancel Remaining") }
        if alert.runModal() == .alertSecondButtonReturn { model.cancelRequested = true }
        return .terminateCancel
    }
}
