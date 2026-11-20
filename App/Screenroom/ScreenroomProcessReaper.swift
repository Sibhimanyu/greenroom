//
//  ScreenroomProcessReaper.swift
//  Greenroom
//
//  Ending the outside tools an analysis starts (whisper, the user's agent CLI).
//
//  They run as `zsh -lc <command>`, so the shell is not always the thing doing
//  the work: a command with a pipe or a wrapper script leaves the real program
//  as a child that SIGTERM to the shell does not reach, still holding the
//  pipes open. Stopping therefore walks the tree, asks politely, and after a
//  short grace period kills whatever is left.
//
import Foundation

enum ScreenroomProcessReaper {

    /// How long a tool gets to exit after being asked, before it is killed.
    static let grace: TimeInterval = 2

    /// Every process below `pid`, found with pgrep. Empty when there are none
    /// or pgrep is missing.
    static func descendants(of pid: pid_t) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = Pipe()
        guard (try? pgrep.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let children = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        return children + children.flatMap { descendants(of: $0) }
    }

    /// Asks the tool and everything it started to exit, then kills what is
    /// still there after `grace`. Returns at once; the kill happens later on a
    /// background queue.
    static func stop(_ process: Process, grace: TimeInterval = ScreenroomProcessReaper.grace) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        let children = descendants(of: pid)
        process.terminate()
        for child in children { kill(child, SIGTERM) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            for child in children where kill(child, 0) == 0 { kill(child, SIGKILL) }
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// Stops a tool that has run past its limit. `fired` says it did, so the
    /// caller can tell a timeout from a failure.
    final class Watchdog {
        private let item: DispatchWorkItem
        private let lock = NSLock()
        private var didFire = false

        var fired: Bool {
            lock.lock(); defer { lock.unlock() }
            return didFire
        }

        init(_ process: Process, limit: TimeInterval) {
            var fire: (() -> Void)?
            item = DispatchWorkItem { fire?() }
            fire = { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.didFire = true; self.lock.unlock()
                ScreenroomProcessReaper.stop(process)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit, execute: item)
        }

        func cancel() { item.cancel() }
    }
}
