import Foundation

/// A dependency-free test harness.
///
/// Why this exists: XCTest and swift-testing both ship inside Xcode, not the
/// Command Line Tools. On a CLT-only machine `swift test` cannot link
/// (`library '_TestingInterop' not found`). The API here is deliberately
/// shaped like swift-testing so the suites can be ported by find-and-replace
/// if a full Xcode ever lands on the build machine.

// MARK: - Failure record

public struct TestFailure: Sendable {
    public let message: String
    public let file: String
    public let line: UInt

    var location: String {
        "\((file as NSString).lastPathComponent):\(line)"
    }
}

/// Thrown by `require` to abandon the current test without failing the run twice.
public struct TestAborted: Error {}

// MARK: - Context

/// Passed to each test body; collects assertion failures.
public final class TestContext {
    public private(set) var failures: [TestFailure] = []

    public init() {}

    /// Asserts a condition. Records a failure and continues.
    public func expect(
        _ condition: Bool,
        _ message: @autoclosure () -> String = "",
        file: String = #fileID,
        line: UInt = #line
    ) {
        guard !condition else { return }
        let detail = message()
        record(detail.isEmpty ? "expectation failed" : detail, file: file, line: line)
    }

    /// Asserts equality, reporting both operands on failure.
    public func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ message: @autoclosure () -> String = "",
        file: String = #fileID,
        line: UInt = #line
    ) {
        guard actual != expected else { return }
        var detail = "expected \(pretty(expected)), got \(pretty(actual))"
        let note = message()
        if !note.isEmpty { detail += " (\(note))" }
        record(detail, file: file, line: line)
    }

    public func expectNil<T>(
        _ value: T?,
        _ message: @autoclosure () -> String = "",
        file: String = #fileID,
        line: UInt = #line
    ) {
        guard let value else { return }
        var detail = "expected nil, got \(pretty(value))"
        let note = message()
        if !note.isEmpty { detail += " (\(note))" }
        record(detail, file: file, line: line)
    }

    /// Asserts a string contains a substring, quoting both on failure.
    public func expectContains(
        _ haystack: String,
        _ needle: String,
        file: String = #fileID,
        line: UInt = #line
    ) {
        guard !haystack.contains(needle) else { return }
        record("expected to find \"\(needle)\" in \"\(haystack)\"", file: file, line: line)
    }

    /// Unwraps an optional or aborts this test.
    public func require<T>(
        _ value: T?,
        _ message: @autoclosure () -> String = "",
        file: String = #fileID,
        line: UInt = #line
    ) throws -> T {
        guard let value else {
            let note = message()
            record(note.isEmpty ? "required value was nil" : note, file: file, line: line)
            throw TestAborted()
        }
        return value
    }

    /// Records an unconditional failure.
    public func fail(
        _ message: String,
        file: String = #fileID,
        line: UInt = #line
    ) {
        record(message, file: file, line: line)
    }

    /// Asserts that `body` throws, returning the error for further inspection.
    @discardableResult
    public func expectThrows<T>(
        _ body: () throws -> T,
        _ message: @autoclosure () -> String = "",
        file: String = #fileID,
        line: UInt = #line
    ) throws -> Error {
        do {
            _ = try body()
        } catch {
            return error
        }
        let note = message()
        record(note.isEmpty ? "expected an error, but none was thrown" : note, file: file, line: line)
        throw TestAborted()
    }

    /// Asserts that `body` does not throw.
    public func expectNoThrow<T>(
        _ body: () throws -> T,
        file: String = #fileID,
        line: UInt = #line
    ) {
        do {
            _ = try body()
        } catch {
            record("unexpected error: \(error)", file: file, line: line)
        }
    }

    private func record(_ message: String, file: String, line: UInt) {
        failures.append(TestFailure(message: message, file: file, line: line))
    }

    private func pretty(_ value: Any) -> String {
        if let s = value as? String { return "\"\(s)\"" }
        return String(describing: value)
    }
}

// MARK: - Suite

/// A named group of test cases.
///
/// A `Sendable` value type so suites can live as top-level `let`s without
/// tripping Swift 6's global-variable isolation rule. Mutation is confined to
/// the non-escaping `Builder` handed to `init`.
public struct Suite: Sendable {
    public let name: String
    fileprivate let cases: [Case]

    fileprivate struct Case: Sendable {
        let name: String
        let body: @Sendable (TestContext) throws -> Void
    }

    public final class Builder {
        fileprivate var cases: [Case] = []

        public func test(_ name: String, _ body: @escaping @Sendable (TestContext) throws -> Void) {
            cases.append(Case(name: name, body: body))
        }
    }

    public init(_ name: String, _ build: (Builder) -> Void) {
        let builder = Builder()
        build(builder)
        self.name = name
        self.cases = builder.cases
    }
}

// MARK: - Runner

public enum TestRunner {
    /// Runs every suite, printing a report. Returns a process exit code.
    ///
    /// Pass a filter (or set `FUNKYBAR_TEST_FILTER`) to run a subset; the filter
    /// matches case-insensitively against "suite name / test name".
    public static func run(_ suites: [Suite], filter: String? = nil) -> Int32 {
        let filter = filter ?? ProcessInfo.processInfo.environment["FUNKYBAR_TEST_FILTER"]
        let tty = isatty(fileno(stdout)) == 1

        func paint(_ text: String, _ code: String) -> String {
            tty ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
        }
        let dim   = { paint($0, "2") }
        let red   = { paint($0, "31") }
        let green = { paint($0, "32") }
        let bold  = { paint($0, "1") }

        var passed = 0
        var failed = 0
        var skipped = 0
        var failureLines: [String] = []
        let started = Date()

        for suite in suites {
            var printedHeader = false

            for testCase in suite.cases {
                let label = "\(suite.name) / \(testCase.name)"

                if let filter, !label.lowercased().contains(filter.lowercased()) {
                    skipped += 1
                    continue
                }

                if !printedHeader {
                    print("\n\(bold(suite.name))")
                    printedHeader = true
                }

                let context = TestContext()
                var thrown: Error?

                do {
                    try testCase.body(context)
                } catch is TestAborted {
                    // Already recorded by require/expectThrows.
                } catch {
                    thrown = error
                }

                if let thrown {
                    context.fail("unexpected error: \(thrown)")
                }

                if context.failures.isEmpty {
                    passed += 1
                    print("  \(green("ok"))   \(testCase.name)")
                } else {
                    failed += 1
                    print("  \(red("FAIL")) \(testCase.name)")
                    for failure in context.failures {
                        print("       \(dim(failure.location))  \(failure.message)")
                        failureLines.append("\(label)\n       \(failure.location)  \(failure.message)")
                    }
                }
            }
        }

        let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
        print("")

        if failed > 0 {
            print(bold("Failures:"))
            for line in failureLines { print("  \(line)") }
            print("")
        }

        var summary = "\(passed) passed"
        if failed > 0 { summary += ", \(failed) failed" }
        if skipped > 0 { summary += ", \(skipped) filtered out" }
        summary += " in \(elapsed)"

        print(failed > 0 ? red(bold(summary)) : green(bold(summary)))
        return failed > 0 ? 1 : 0
    }
}
