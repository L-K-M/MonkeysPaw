/// UI-thread composition intent for Settings → General (§5.4/§11.1), following
/// LibraryLocationControl's composition boundary (§4.2).
public protocol RememberedValuesControl {
    /// Forward to the composition root's current PickerModel.forgetAllValues()
    /// on every call, including while its panel is closed. Do not retain a
    /// picker across library replacement or call FillService directly: the
    /// picker also owns session drafts, form reset and delivery refusal.
    /// Return its outcome directly rather than reading forgetValuesError.
    func forgetAllValues() -> RememberedValuesOutcome
}
