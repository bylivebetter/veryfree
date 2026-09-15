//
//  main.swift
//  Speakin
//
//  Nib-less AppKit entry point: create the delegate ourselves, then hand over to NSApplicationMain.
//  NSApplication only holds its delegate weakly, so `Main.delegate` is the owning reference.
//

import AppKit

@MainActor
enum Main {
    static let delegate = AppDelegate()

    static func run() {
        NSApplication.shared.delegate = delegate
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}

MainActor.assumeIsolated {
    Main.run()
}
