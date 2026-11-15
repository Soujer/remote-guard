import Foundation
import AppKit
import Darwin

if CommandLine.arguments.contains("--self-test") {
    do { try SelfTests.run(); exit(0) } catch { fputs("Self-test failed: \(error.localizedDescription)\n", stderr); exit(1) }
}
do { try ensureDirectory(supportRoot) } catch { fputs("Cannot create local settings directory\n", stderr); exit(1) }
let instanceFile = open(supportRoot.appendingPathComponent("desktop.lock").path, O_CREAT | O_RDWR, 0o600)
guard instanceFile >= 0, flock(instanceFile, LOCK_EX | LOCK_NB) == 0 else {
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.soujer.remote-guard.show"), object: String(getuid()), userInfo: nil, deliverImmediately: true)
    exit(0)
}
let application = NSApplication.shared
let delegate = GuardDesktop()
application.delegate = delegate
application.setActivationPolicy(CommandLine.arguments.contains("--background") ? .accessory : .regular)
application.run()
