import AppKit

// Explicit entry point rather than `@main` on the delegate: the delegate is
// created and attached here, before `NSApplicationMain` runs, so nothing about
// launch depends on how the AppKit overlay instantiates `@main` delegates.
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
