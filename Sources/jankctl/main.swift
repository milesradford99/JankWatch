// jankctl — tiny helper that performs one process operation. JankWatch runs it through the administrator
// password dialog when the target belongs to another user (e.g. root-owned Spotlight workers).
// Every target is given as pid:starttime and re-verified here, so a recycled pid is never touched.
//
// Usage: jankctl <bg-on|bg-off|stop|cont|term|kill> <pid:starttime>...
#if os(macOS)
import Darwin
import Foundation
import JankWatchCore
import JankWatchMac

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: jankctl <bg-on|bg-off|stop|cont|term|kill> <pid:starttime>...\n".utf8))
    exit(64)
}

let args = CommandLine.arguments.dropFirst()
guard let op = args.first, args.count >= 2 else { usage() }

var failures = 0
for spec in args.dropFirst() {
    let parts = spec.split(separator: ":")
    guard parts.count == 2, let pid = Int32(parts[0]), let start = Double(parts[1]) else {
        FileHandle.standardError.write(Data("bad target \(spec)\n".utf8))
        failures += 1
        continue
    }
    guard let entry = ProcessTable.lookup(pid: pid) else {
        print("\(pid): gone")
        continue
    }
    let ref = PIDRef(pid: pid, startTime: start, uid: entry.uid)
    let result: ProcessOpResult
    switch op {
    case "bg-on": result = ProcessOps.setBackground(ref, on: true)
    case "bg-off": result = ProcessOps.setBackground(ref, on: false)
    case "stop": result = ProcessOps.signal(ref, SIGSTOP)
    case "cont": result = ProcessOps.signal(ref, SIGCONT)
    case "term": result = ProcessOps.signal(ref, SIGTERM)
    case "kill": result = ProcessOps.signal(ref, SIGKILL)
    default: usage()
    }
    print("\(pid): \(result)")
    if result != .ok && result != .gone { failures += 1 }
}
exit(failures == 0 ? 0 : 1)
#else
print("jankctl is macOS only")
#endif
