import Foundation

if CommandLine.arguments.contains("--self-test") {
    do { try SelfTests.run(); exit(0) } catch { fputs("Self-test failed: \(error.localizedDescription)\n", stderr); exit(1) }
}
fputs("Desktop integration is being built. Use --self-test for verification.\n", stderr)
exit(1)
