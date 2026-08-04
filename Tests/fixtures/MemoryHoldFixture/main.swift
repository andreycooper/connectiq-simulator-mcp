import Darwin
import Foundation

// Test fixture for the process-inspection teardown gate.
//
// KERN_PROCARGS2 only reports EIO while a dying process's address space is
// still being removed, and that window does not open for a process with
// nothing to tear down — which is exactly why four earlier probes using
// /usr/bin/true and /bin/sleep missed the defect entirely.
//
// Allocates and touches a fixed number of megabytes, announces readiness, then
// parks on pause(). No sleep: pause() blocks until the test signals it.

let megabytes = CommandLine.arguments.count > 1 ? (Int(CommandLine.arguments[1]) ?? 0) : 0
let chunk = 1 << 20
var blocks: [UnsafeMutableRawPointer] = []
blocks.reserveCapacity(megabytes)
for _ in 0..<megabytes {
    guard let block = malloc(chunk) else { break }
    // Touch every page so the pages are resident and must actually be removed.
    memset(block, 1, chunk)
    blocks.append(block)
}

FileHandle.standardOutput.write(Data("ready\n".utf8))

// Optional self-destruct mode. When the inspecting parent sends SIGKILL it is
// descheduled by the kill itself, and the target is reliably gone before the
// parent's first inspection — so the teardown window is never sampled. Having
// the child kill itself on a trigger byte leaves the parent already running its
// polling loop while the address space is being removed.
if CommandLine.arguments.contains("--self-kill-on-stdin") {
    var trigger: UInt8 = 0
    _ = read(0, &trigger, 1)
    raise(SIGKILL)
}

while true { pause() }
