import Foundation
import TestKit

// Suites are registered explicitly: without XCTest there is no runtime test
// discovery, and an explicit list is easier to reason about than reflection.
let allSuites: [Suite] =
    tomlSuites
    + configSuites

let filter = CommandLine.arguments.dropFirst().first
exit(TestRunner.run(allSuites, filter: filter))
