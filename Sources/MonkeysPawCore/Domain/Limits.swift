import Foundation

/// Initial shared timings and resource bounds from the plan (§4.2).
public enum Limits {
    private static let kibibyte = 1_024
    private static let mebibyte = kibibyte * kibibyte

    /// §6.3: 100 ms for the macOS panel to hide before restoring focus.
    public static let settleDelayMacOS: Duration = .milliseconds(100)

    /// §6.3: 140 ms for Linux compositors to refocus after the panel hides.
    public static let settleDelayLinux: Duration = .milliseconds(140)

    /// §6.3: wait up to 500 ms for Accessibility to confirm the paste target.
    public static let accessibilityFocusWait: Duration = .milliseconds(500)

    /// §11.1: the initial 640 × 420 picker size, without platform UI types.
    public static let panelSize: (width: Int, height: Int) = (640, 420)

    /// §5.1: retain 50 local revisions per prompt to bound history storage.
    public static let historyCapPerPrompt: Int = 50

    /// §5.5: debounce 500 ms so editor delete/create saves become one change.
    public static let watchDebounce: Duration = .milliseconds(500)

    /// §7.1: bound each complete non-streaming LLM call to 300 seconds.
    public static let llmBudget: Duration = .seconds(300)

    /// §7.1: cap LLM response bodies at 2 MiB to bound transport memory.
    public static let responseCap: Int = 2 * mebibyte

    /// §7.1: allow sync batches up to 16 MiB on the same bounded transport.
    public static let syncResponseCap: Int = 16 * mebibyte

    /// §8.3: cap prompt bodies at 256 KiB on both clients and the server.
    public static let maxPromptBytes: Int = 256 * kibibyte

    /// §8.4: bound a complete relative prompt path to 1,024 UTF-8 bytes.
    public static let maxPathBytes: Int = kibibyte

    /// §12: rotate each desktop log at 1 MiB to bound diagnostic storage.
    public static let logFileMaxBytes: Int = mebibyte

    /// §12: retain five desktop log files for a bounded diagnostic history.
    public static let logFileKeep: Int = 5
}
