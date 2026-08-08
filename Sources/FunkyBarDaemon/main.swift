import AppKit
import Foundation
import FunkyBarCore

// The daemon is a plain launchd executable, not an .app bundle. AppKit still
// needs an NSApplication for windows and workspace notifications, but
// `.accessory` keeps it out of the Dock and the app switcher entirely.

let arguments = Array(CommandLine.arguments.dropFirst())

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let defaultConfigPath = (NSHomeDirectory() as NSString)
    .appendingPathComponent(".config/funkybar/funkybar.toml")

let configPath = value(after: "--config") ?? value(after: "-c") ?? defaultConfigPath

if arguments.contains("--version") {
    print("funkybar 0.1.0")
    exit(0)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    funkybard - the funkybar daemon

    usage: funkybard [--config PATH] [--check] [--duration SECONDS]

      --config PATH       config file (default ~/.config/funkybar/funkybar.toml)
      --check             validate the config and exit
      --duration SECONDS  run for a fixed time, then exit (for testing)
      --selftest          start, verify the window is really on screen, exit
      --dump              print what every item will draw, then exit
      --version
    """)
    exit(0)
}

// `--check` validates without touching the display, so it works over ssh and
// in CI.
if arguments.contains("--check") {
    guard let source = try? String(contentsOfFile: configPath, encoding: .utf8) else {
        FileHandle.standardError.write(Data("funkybar: cannot read \(configPath)\n".utf8))
        exit(2)
    }
    do {
        let outcome = ConfigDecoder.decode(try TOMLParser.parse(source))
        if !outcome.diagnostics.isEmpty {
            print(outcome.diagnostics.render(path: configPath, source: source), terminator: "")
        }
        if outcome.isUsable {
            let errors = outcome.diagnostics.errors.count
            let warnings = outcome.diagnostics.warnings.count
            print("ok: \(outcome.config.allItems.count) items, \(outcome.config.nodes.count) top-level nodes"
                  + (warnings > 0 ? ", \(warnings) warning\(warnings == 1 ? "" : "s")" : ""))
            exit(errors > 0 ? 1 : 0)
        }
        exit(1)
    } catch let diagnostics as ConfigDiagnostics {
        print(diagnostics.render(path: configPath, source: source), terminator: "")
        exit(1)
    } catch {
        FileHandle.standardError.write(Data("funkybar: \(error)\n".utf8))
        exit(2)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let runtime = BarRuntime()

final class AppDelegate: NSObject, NSApplicationDelegate {
    let runtime: BarRuntime
    let configPath: String
    let duration: Double?
    let selfTest: Bool
    let dump: Bool

    init(runtime: BarRuntime, configPath: String, duration: Double?, selfTest: Bool, dump: Bool) {
        self.runtime = runtime
        self.configPath = configPath
        self.duration = duration
        self.selfTest = selfTest
        self.dump = dump
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try runtime.start(configPath: configPath)
        } catch {
            FileHandle.standardError.write(Data("funkybar: config is unusable, not starting\n".utf8))
            exit(1)
        }

        FileHandle.standardError.write(Data("funkybar started\n\(runtime.status)\n".utf8))

        if dump {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    print(self.runtime.dump)
                    self.runtime.stop()
                    exit(0)
                }
            }
            return
        }

        if selfTest {
            // Give providers one turn to report and the server one turn to
            // composite before asking what it sees.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    let (report, passed) = SelfTest.run(runtime: self.runtime)
                    print(report)
                    self.runtime.stop()
                    exit(passed ? 0 : 1)
                }
            }
            return
        }

        if let duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime.stop()
    }
}

let delegate = AppDelegate(
    runtime: runtime,
    configPath: configPath,
    duration: value(after: "--duration").flatMap(Double.init),
    selfTest: arguments.contains("--selftest"),
    dump: arguments.contains("--dump")
)
app.delegate = delegate
app.run()
