//
//  Log.swift
//  Agent in the Notch
//
//  Lightweight stdout/stderr logger. Drop-in replacement for os.log Logger.
//  Errors go to stderr; everything else to stdout.
//

import Darwin

struct Log: Sendable {
    let category: String

    func info(_ message: String)    { print("[INFO]  [\(category)] \(message)") }
    func warning(_ message: String) { print("[WARN]  [\(category)] \(message)") }
    func debug(_ message: String)   { print("[DEBUG] [\(category)] \(message)") }
    func error(_ message: String)   { fputs("[ERROR] [\(category)] \(message)\n", Darwin.stderr) }
}
