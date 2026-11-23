// jankprobe — validation & diagnostics CLI for real hardware. See docs/VALIDATION.md.
import Foundation
import JankWatchCore

struct Args {
    let all: [String]
    init(_ a: [String]) { all = a }
    var command: String? { all.first }
    func value(_ name: String) -> String? {
        guard let i = all.firstIndex(of: name), i + 1 < all.count else { return nil }
        return all[i + 1]
    }
    func double(_ name: String, _ def: Double) -> Double { value(name).flatMap(Double.init) ?? def }
    func has(_ name: String) -> Bool { all.contains(name) }
    var positional: [String] { Array(all.dropFirst()).filter { !$0.hasPrefix("--") } }
}

func printJSON<T: Encodable>(_ label: String, _ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    if let d = try? enc.encode(value), let s = String(data: d, encoding: .utf8) {
        print("=== \(label) ===")
        print(s)
    }
}

let usageText = """
jankprobe <command> [options]

  env                         Machine / OS / permission summary
  clock [--seconds 20]        V1: which clock CGEvent.timestamp uses (needs Input Monitoring for the terminal)
  rusage                      V2: can we read other users' processes? rusage time unit?
  ax --bundle <id> [--seconds 30]
                              V3: Accessibility probe latency and whether probing raises the app's CPU
  probe [--seconds 120] [--input] [--csv out.csv]
                              V4: live scheduling-latency probe + system metrics, 1 line per second
  topology                    V5: which CPU indices are efficiency cores (Apple Silicon)
  act <bg-on|bg-off|stop|cont|term> <pid>
                              V8: apply one process action and show the resulting state
  engine [--seconds 0] [--data DIR]
                              V6: run the full detection engine headless and print episodes / alerts
  evaluate [--data DIR]       V10: precision / recall from recorded data (default: the app's data directory)
"""

let args = Args(Array(CommandLine.arguments.dropFirst()))

switch args.command {
case "evaluate":
    let root = args.value("--data").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? EventStore.defaultRoot()
    let store = EventStore(root: root)
    let report = Evaluator.evaluate(store.loadEpisodes(), marks: store.loadMarks(), feedback: store.loadFeedback(),
                                    activeTicks: store.countActiveTicks())
    print("data: \(root.path)")
    printJSON("RESULT evaluate", report)
case nil, "help", "--help", "-h":
    print(usageText)
default:
    #if os(macOS)
    runMacCommand(args)
    #else
    print("This command needs macOS. Only `evaluate` works on this platform.")
    exit(2)
    #endif
}
