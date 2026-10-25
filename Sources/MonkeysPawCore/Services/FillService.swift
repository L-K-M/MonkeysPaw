import Foundation

/// Shared fill pipeline (§5.3). Clock/time-zone reads are lock-serialized;
/// ValuesStore serializes its own state. Clipboard snapshots must be requested
/// on the port's owning UI thread. Completion runs there, inline or async, and
/// models marshal it through MainThread. This service owns no driver or UI.
public final class FillService: @unchecked Sendable {
    private let values: ValuesStore
    private let clipboard: Clipboard
    private let clock: WallClock
    private let timeZone: @Sendable () -> TimeZone
    private let lock = NSLock()

    public init(values: ValuesStore, clipboard: Clipboard, clock: WallClock,
                timeZone: @escaping @Sendable () -> TimeZone) {
        self.values = values
        self.clipboard = clipboard
        self.clock = clock
        self.timeZone = timeZone
    }

    /// Resolve once at form open (or direct fieldless use). Merely selecting a
    /// picker row never reads the clipboard. Empty/unavailable clipboard text
    /// resolves as an empty string, so that builtin never blocks delivery.
    public func builtinSnapshot(for document: PromptDocument,
                                completion: @escaping @Sendable (PromptBuiltinValues) -> Void) {
        builtinSnapshot(for: document, moment: builtinMoment(), completion: completion)
    }

    /// Repeat fixes date/time at invocation even while source I/O is pending.
    func builtinMoment() -> PromptBuiltinValues {
        lock.lock()
        let now = clock.now()
        let zone = timeZone()
        lock.unlock()

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: now)
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: now)

        return PromptBuiltinValues(date: date, time: time)
    }

    func builtinSnapshot(for document: PromptDocument, moment: PromptBuiltinValues,
                         completion: @escaping @Sendable (PromptBuiltinValues) -> Void) {
        guard document.template.builtins.contains(.clipboard) else {
            completion(moment)
            return
        }
        clipboard.readText { text in
            completion(PromptBuiltinValues(clipboard: text ?? "", date: moment.date, time: moment.time))
        }
    }

    public func form(for entry: LibraryEntry) -> FillForm {
        let remembered: [String: String]
        let warning: PromptPersistenceWarning?
        do {
            remembered = try values.rememberedValues(for: entry.identity)
            warning = nil
        } catch {
            remembered = [:]
            warning = .rememberedValuesUnavailable
        }
        let document = entry.document
        let fields = document.effectiveFields.map { field in
            let rememberedValue = field.remember ? remembered[field.name] : nil
            return FillFormField(field, prefill: rememberedValue ?? field.defaultValue,
                                 prefillSource: rememberedValue != nil ? .remembered : .defaultValue)
        }
        return FillForm(fields: fields, issues: document.issues, canRender: document.canRender,
                        isReadOnly: document.isReadOnly, warning: warning)
    }

    public func preview(_ document: PromptDocument, values: [String: String],
                        builtins: PromptBuiltinValues) -> FillPreview {
        do { return .rendered(try render(document, values: values, builtins: builtins)) }
        catch let error as PromptRenderError { return .blocked(error, issues: document.issues) }
        catch { return .blocked(.invalidPrompt, issues: document.issues) }
    }

    public func render(_ document: PromptDocument, values: [String: String],
                       builtins: PromptBuiltinValues) throws -> String {
        try PromptRenderer.render(document, values: values, builtins: builtins)
    }

    /// Record exactly delivered remember-fields, including empty strings. A
    /// later prefill repeats that last choice; non-remembered fields are omitted.
    public func rememberedOnDelivery(identity: PromptIdentity, fields: [PromptField],
                                     values delivered: [String: String]) throws {
        var remembered = [String: String]()
        for field in fields where field.remember {
            // Only verbatim delivered text is remembered; an absent value must
            // not pin the declared default forever (remembered text wins over
            // defaults even after the prompt's default changes).
            guard let deliveredValue = delivered[field.name] else { continue }
            remembered[field.name] = deliveredValue
        }
        try values.record(identity: identity, values: remembered)
    }

    /// Forget this identity's whole remembered map, propagating store errors.
    public func forgetValues(for identity: PromptIdentity) throws {
        try values.remove(identity: identity)
    }

    /// Explicitly reset every remembered map, including rejected or unreadable state.
    public func forgetAllValues() throws {
        try values.removeAll()
    }
}
