import MonkeysPawCore

enum SettingsAssistantStrings {
    static let tab = "Assistant"
    static let profiles = "Provider profiles"
    static let profile = "Profile"
    static let add = "Add profile"
    static let delete = "Delete profile"
    static let disable = "Disable Assistant"
    static let makeActive = "Make Active"
    static let name = "Name"
    static let kind = "Provider"
    static let anthropic = "Anthropic"
    static let compatible = "OpenAI-compatible"
    static let baseURL = "Base URL"
    static let modelID = "Model"
    static let chooseModel = "Choose a listed model"
    static let manualModel = "Enter any model ID, or use Test connection to list models."
    static let key = "API Key"
    static let keyPlaceholder = "Enter a replacement key"
    static let keepKey = "Keep saved key"
    static let clearKey = "Clear saved key"
    static let save = "Save"
    static let test = "Test Connection"
    static let cancelTest = "Cancel test"
    static let refresh = "Discard Changes"
    static let newProfile = "New profile. Save to add it to your profiles."
    static let empty = "Add a profile to configure your assistant."
    static let inactive = "No active provider. Assistant is disabled."
    static let unencrypted = "Warning: your key is stored in an unencrypted file."

    static let syncGroup = "Provider Settings Sync"
    static let syncGenerate = "Generate Key"
    static let syncEnter = "Enter Key"
    static let syncEntryPlaceholder = "Paste the 43-character key from another device"
    static let syncRemove = "Remove Key"
    static let syncDismissReveal = "Hide Key"
    static let syncReveal = "Copy this key to your other devices. It is shown once and never uploaded."
    static let syncKeyValue = "Sync Key"

    static func syncStatus(_ status: ProviderSyncKeyModel.Status) -> String {
        switch status {
        case .noAccount: return "Provider settings sync needs a signed-in sync account."
        case .missing: return "No sync key. Generate one, or enter the key from another device."
        case .provisioned(.keychain): return "Sync key stored · Keychain"
        case .provisioned(.secretService): return "Sync key stored · Secret Service"
        case .provisioned(.environment): return "Sync key provided · Environment"
        case .provisioned(.file): return "Sync key stored · File (unencrypted)"
        case .unavailable: return "Sync key status is unavailable."
        }
    }

    static func syncNotice(_ notice: ProviderSyncKeyModel.Notice) -> String {
        switch notice {
        case .invalidKey: return "That is not a valid sync key. Paste the key shown on another device."
        case .operationFailed: return "The sync key could not be updated. Try again."
        }
    }

    static func activeProfile(_ name: String) -> String { "Active provider: \(name)" }
    static func profileRow(_ name: String, isActive: Bool) -> String {
        isActive ? "\(name) (active)" : name
    }

    static func modelLabel(_ model: ModelDescriptor) -> String {
        guard let name = model.displayName, name != model.id else { return model.id }
        return "\(name) (\(model.id))"
    }

    static func keyEdit(_ edit: AssistantSettingsModel.KeyEdit) -> String {
        switch edit {
        case .keep: return "Leave the key blank to keep your saved key."
        case .replace: return "The entered key will replace your saved key when you save."
        case .clear: return "Your saved key will be removed when you save."
        }
    }

    static func storage(_ storage: AssistantSettingsModel.KeyStorage) -> String {
        switch storage {
        case .none: return "No key saved."
        case .loading: return "Checking saved key…"
        case .saved(.keychain): return "Key saved · Keychain"
        case .saved(.secretService): return "Key saved · Secret Service"
        case .saved(.environment): return "Key provided · Environment (read-only)"
        case .saved(.file): return "Key saved · File (unencrypted)"
        case .failed: return "Saved key status is unavailable."
        }
    }

    static func progress(_ operation: AssistantSettingsModel.Operation) -> String {
        switch operation {
        case .loading: return "Loading provider settings…"
        case .saving: return "Saving profile…"
        case .selecting: return "Selecting profile…"
        case .deleting: return "Deleting profile…"
        }
    }

    static let testing = "Testing connection…"

    static func testResult(_ result: ConnectionTestResult) -> String {
        switch result {
        case .ok(let models):
            return models.isEmpty ? "Connection succeeded. No models were listed; enter a model ID."
                : "Connection succeeded. \(models.count) models available."
        case .authentication: return "Authentication failed. Check your API key."
        case .notFound: return "Model-list endpoint not found. Check your base URL or enter a model ID."
        case .rateLimited: return "The provider rate limited this request. Try again later."
        case .network: return "Could not connect. Check your base URL and network."
        case .timeout: return "The connection test timed out. Try again."
        case .unsupportedListing: return "This provider does not support model listing. Enter a model ID."
        case .invalidResponse: return "The provider returned an invalid model list. Enter a model ID or try again."
        case .cancelled: return "Connection test cancelled."
        case .settings(let error): return settingsError(error)
        case .providerFailure(let status): return "The provider returned HTTP \(status). Try again later."
        }
    }

    static func settingsError(_ error: ProviderSettingsError) -> String {
        switch error {
        case .futureVersion: return "Provider settings were saved by a newer app. Update the app to edit them."
        case .unsupportedVersion: return "This provider settings version is unsupported. Settings are read-only."
        case .corruptFile: return "Provider settings are invalid. Settings are read-only."
        case .readFailed: return "Could not read provider settings. Check app-data permissions."
        case .writeFailed: return "Could not save provider settings. Check app-data permissions and try again."
        case .invalidBaseURL: return "Enter a valid provider base URL."
        case .insecureBaseURL: return "Use HTTPS, or HTTP for a local loopback server."
        case .credentialsInURL: return "Remove credentials from the base URL. Enter the key in the API key field."
        case .queryOrFragmentInURL: return "Remove the query and fragment from the base URL."
        case .invalidProfile: return "Enter a profile name and model ID without control characters."
        case .invalidKey: return "Enter a key without control characters."
        case .duplicateProfile: return "This profile already exists. Reload your profiles and try again."
        case .profileNotFound: return "This profile no longer exists. Reload your profiles."
        case .keyRequiredForChangedDestination:
            return "Re-enter the key or choose Clear saved key after changing the provider kind or destination."
        case .secret(let error):
            switch error {
            case .invalidAccount: return "The key's storage account is invalid."
            case .unavailable: return "Key storage is unavailable. Check your secret store and try again."
            case .locked: return "Key storage is locked or access was denied. Unlock it or allow access, then try again."
            case .readOnly: return "The environment key is read-only. Change it outside the app."
            case .readFailed: return "Could not read your saved key. Check your secret store and try again."
            case .writeFailed: return "Could not save your key. Your previous key was kept. Try again."
            case .deleteFailed: return "Could not remove your saved key. Try again."
            }
        case .secretRollbackFailed:
            return "Settings could not be saved and the previous key could not be restored. Key status is unknown; restart and re-enter or clear the key."
        }
    }
}
