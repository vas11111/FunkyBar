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
      --dump-json         same, machine-readable (used by funkybar-measure)
      --capture PATH      render the bar to a PNG, then exit
      --capture-popup ID  open an item's popup and render it with --capture
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
    let dumpJSON: Bool
    let capturePath: String?
    let popupItem: String?

    init(runtime: BarRuntime, configPath: String, duration: Double?, selfTest: Bool, dump: Bool, dumpJSON: Bool, capturePath: String?, popupItem: String?) {
        self.runtime = runtime
        self.configPath = configPath
        self.duration = duration
        self.selfTest = selfTest
        self.dump = dump
        self.dumpJSON = dumpJSON
        self.capturePath = capturePath
        self.popupItem = popupItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try runtime.start(configPath: configPath)
        } catch {
            FileHandle.standardError.write(Data("funkybar: config is unusable, not starting\n".utf8))
            exit(1)
        }

        FileHandle.standardError.write(Data("funkybar started\n\(runtime.status)\n".utf8))

        if let popupItem = self.popupItem, let capturePath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                MainActor.assumeIsolated {
                    let ok = self.runtime.capturePopup(popupItem, to: capturePath)
                    print(ok ? "wrote \(capturePath)" : "popup capture failed")
                    self.runtime.stop()
                    exit(ok ? 0 : 1)
                }
            }
            return
        }

        if let capturePath {
            // One extra turn so providers have reported before we draw.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    let ok = self.runtime.capture(to: capturePath)
                    print(ok ? "wrote \(capturePath)" : "capture failed")
                    self.runtime.stop()
                    exit(ok ? 0 : 1)
                }
            }
            return
        }

        if dump {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    print(self.dumpJSON ? self.runtime.dumpJSON : self.runtime.dump)
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
    dump: arguments.contains("--dump") || arguments.contains("--dump-json"),
    dumpJSON: arguments.contains("--dump-json"),
    capturePath: value(after: "--capture"),
    popupItem: value(after: "--capture-popup")
)
app.delegate = delegate
app.run()
