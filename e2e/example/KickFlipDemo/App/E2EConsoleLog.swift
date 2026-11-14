import Foundation

/// E2E only: copies the app's stdout (the SDK's `[LinkTrail]` lines) into the app container, so the
/// e2e runner can put the last lines of a failed flow in its report.
///
/// An app that SpringBoard (or Maestro) launches on a simulator has nowhere visible to print to, so
/// without this the `[LinkTrail]` lines of a CI run are simply lost. `scripts/e2e-maestro.sh` sets
/// `E2E_CONSOLE_LOG=1` on the simulator (`launchctl setenv`) and reads
/// `Library/Caches/e2e-console.log` from the data container after each attempt. Debug builds only,
/// and only when that variable is set: a normal run in Xcode keeps its console.
enum E2EConsoleLog {
    static func startIfRequested() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["E2E_CONSOLE_LOG"] == "1",
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return }
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let path = caches.appendingPathComponent("e2e-console.log").path
        guard freopen(path, "a", stdout) != nil else { return }
        // Line-buffered: a flow that fails mid-way must still leave its last lines in the file.
        setvbuf(stdout, nil, _IOLBF, 0)
        #endif
    }
}
