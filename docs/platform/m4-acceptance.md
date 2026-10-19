# M4 assistant acceptance

This maps every [§15 M4 acceptance item](../plan/15-milestones.md) to its
automated gate. Record the main commit, CI run and tester with the results.
M4 remains open until the owner checks below are recorded; a skipped native
secret-store test supplies no acceptance proof.

- Commit / CI run:
- Platform / date / tester:
- Provider host / model / storage tier (no credentials):

| Acceptance item | Proof | CI job in [ci.yml](../../.github/workflows/ci.yml) |
|---|---|---|
| “Stub-transport tests pass for both protocols and every §7.2 stop reason.” | [AnthropicClientTests](../../Tests/MonkeysPawCoreTests/Assistant/AnthropicClientTests.swift) and [OpenAIClientTests](../../Tests/MonkeysPawCoreTests/Assistant/OpenAIClientTests.swift), mapped by exact function below. They answer requests, assert protocol-specific headers/bodies and typed outcomes, and reject valid-looking output when its stop reason fails. | `linux-app` Core tests and `core-macos` |
| “A random runtime key saved through the settings service and native driver is scanned after Save, Test connection, restart, rename, switch and delete, across the repository and isolated config, data, log and temporary roots, including raw, base64, percent-encoded and JSON-escaped forms.” | [KeychainSecretScanTests](../../MonkeysPawTests/KeychainSecretScanTests.swift): `testKeychainLifecycleLeavesNoSentinelOnDiskWithoutPrompts`; [LinuxSecretScanTests](../../Tests/MonkeysPawLinuxTests/LinuxSecretScanTests.swift): `testSecretServiceLifecycleLeavesNoSentinelOnDisk` and `testFileLifecycleLeavesOnlyOneUnencryptedPrivateCopy`. Each uses a random escaped sentinel, ProviderSettingsService and the native driver, scans all named roots after successful/failed Test, reconstructed services, rename, switching away/back and both unrelated/sentinel profile deletion. In both files, `testScannerFindsRawEncodedAndNestedJSONInHiddenDirectories` calibrates raw/base64/percent/JSON/nested-JSON detection, hidden files and chunk boundaries. | `macos-app` for Keychain; `linux-app`, required display and private D-Bus session, for Linux |
| “Keychain and Secret Service must leave zero copies there; while saved, the Linux file tier must leave exactly one copy in the atomic 0600 `<config>/secrets-unencrypted.json`, visibly labelled "unencrypted", with zero other copies.” | The lifecycle tests above assert the matching-file set at each checkpoint. Linux's file case also asserts exactly one sentinel occurrence, one account, mode 0600, owner/link count, the `unencrypted` map label and Settings strings. [LinuxSecretFileTests](../../Tests/MonkeysPawLinuxTests/LinuxSecretFileTests.swift): `testLabelVersionModeAndAtomicReplacementPreserveOtherAccounts` proves atomic replacement through an old open inode, the new inode/mode/version/label, preserved other accounts and no temporary copies. [LinuxAssistantSettingsTests](../../Tests/MonkeysPawLinuxTests/LinuxAssistantSettingsTests.swift): `testStorageTiersUnencryptedNoticeAndEnvironmentClear` asserts the actual GTK warning label contains “unencrypted” for the file tier. | `macos-app`; `linux-app` |
| “Deleting the profile leaves zero copies in every tier (§12, §19 B29).” | The three lifecycle tests scan after deleting the sentinel profile and again after reconstructing the graph; they assert empty scans, absent persisted credentials and empty profile metadata. | `macos-app`; `linux-app` |
| “README carries minimum assistant privacy/key-tier disclosures (§19 B33); full SECURITY.md/PRIVACY.md follow in M7.” | M7 D19 moved the disclosures to [Privacy](../../PRIVACY.md#requests-and-recipients) and [Security](../../SECURITY.md#credentials), linked before launch guidance in README. Source review on main `2ad595d5a4b6311b11d000bb20dc2aee5b7c0e00` verified explicit outbound actions/payloads, provider access/charges, template versus fill values, `private: true`, Test connection, Keychain, Secret Service/environment/file tiers, atomic 0600 storage, the visible unencrypted warning and logging exclusions. | M4-D1 disposition: reviewed documentation proof under §12/§19 B33 and M7 D19; no automated prose assertion or runtime/provider acceptance is claimed. |
| “Owner-run: write, review, and improve work against Anthropic and a local Ollama on macOS and Linux ([checklist](assistant.md)); skipped native-store tests do not close acceptance.” | The four live-provider rows and native-store checks in [assistant.md](assistant.md#m4-assistant-owner-checks) remain **NOT RUN**. Stub responses cannot establish live-provider or native ACL compatibility. | Owner-run |

§7.2 stop coverage (all functions are in the linked protocol test files;
every row runs in `linux-app` Core tests and `core-macos`):

| Protocol | Reason or response | Asserted outcome | Test function |
|---|---|---|---|
| Anthropic | `end_turn`, `stop_sequence` | Artifact and review decode normally | `testBothNormalStopReasonsDecodeArtifactAndReview` |
| Anthropic | `max_tokens` | `truncated`, before valid/malformed/empty JSON or missing content | `testEveryNonNormalStopReasonWinsOverValidMalformedAndEmptyOutput` |
| Anthropic | `model_context_window_exceeded` | `truncated`, with the same precedence | `testEveryNonNormalStopReasonWinsOverValidMalformedAndEmptyOutput` |
| Anthropic | `refusal` | `declined`, with the same precedence | `testEveryNonNormalStopReasonWinsOverValidMalformedAndEmptyOutput` |
| Anthropic | Unknown/empty reason (`pause_turn`, `tool_use`, `other`, `""`) | Exact `unexpectedStop(reason)`, never a draft | `testEveryNonNormalStopReasonWinsOverValidMalformedAndEmptyOutput` |
| Anthropic | Missing/null reason | Nonempty text: `unexpectedStop("missing")`; empty: `emptyResponse` | `testMissingAndNullReasonsAreUnexpectedOnNonemptyTextAndEmptyOtherwise` |
| Anthropic | Empty/whitespace 200 or normal completion without text | `emptyResponse`, including thinking-only blocks | `testEmptySuccessfulBodiesAndNormalEnvelopesWithoutTextAreEmptyResponses` |
| OpenAI-compatible | `stop` | Artifact/review decode; usage maps to input/output counts | `testNormalStopDecodesArtifactReviewAndUsage` |
| OpenAI-compatible | `length` | `truncated`, before valid/malformed/empty text or malformed/missing message | `testEveryNonNormalFinishReasonPrecedesValidMalformedAndMissingContent` |
| OpenAI-compatible | `content_filter` | `declined`, with the same precedence | `testEveryNonNormalFinishReasonPrecedesValidMalformedAndMissingContent` |
| OpenAI-compatible | `tool_calls`, `function_call`, `other`, `""` | Exact `unexpectedStop(reason)` | `testEveryNonNormalFinishReasonPrecedesValidMalformedAndMissingContent` |
| OpenAI-compatible | Missing/null reason | Nonempty text: `unexpectedStop("missing")`; empty: `emptyResponse`; empty-string reason never accepts nonempty text | `testMissingNullAndEmptyReasonsNeverAcceptNonemptyContent` |
| OpenAI-compatible | Nonempty `message.refusal` with `stop` | `declined`, even with valid artifact content; refusal text stays out of diagnostics | `testMessageRefusalDeclinesWithoutExposingRefusalText` |
| OpenAI-compatible | Empty/whitespace 200, no choices, or normal choice without text | `emptyResponse` | `testEmptySuccessfulBodiesAndNormalChoicesWithoutContentAreEmpty` |
| Both | Normal stop with invalid structured output | `invalidOutput`: missing/extra/duplicate keys, wrong field types/enums, duplicate fields and malformed JSON never become drafts | Anthropic `testNormalCompletionsStillRequireStrictArtifactAndReviewValidation`; OpenAI `testRecoveryAlwaysUsesA5AndStillRequiresStrictValidation` |

No §7.2 stop-reason assertion gap was found for either protocol. The final
row separates successful stop classification from successful validation.

Additional [§13 transport proof](../plan/13-testing.md):

| Contract | Proof | CI job |
|---|---|---|
| Protocol auth, endpoint normalization, strict schema and original 300-second action budget | Anthropic `testOfficialWriteUsesNormalizedEndpointHeadersCatalogSchemaAndBudget` also asserts no sampling/thinking fields; `testCustomAndLookalikeHostsReceiveNoBetaOrFallbacks` limits beta/fallbacks to the official host. OpenAI `testWriteUsesNormalizedEndpointBearerCatalogStrictSchemaAndBudget` asserts only Bearer/Content-Type headers and `testKeylessLoopbackUsesNoAuthorizationForBothOperations` checks keyless actions/model listing. | `linux-app`, `core-macos` |
| OpenAI's recognized 400 format probes; success-only cache and shared deadline | OpenAI `testLadderPersistsOnlyAfterLowerSuccessAndNextActionSkipsRejectedFormats`, `testGeneric400MalformedErrorsAndInvalidSchemasNeverProbe` and `testAllProbesShareOneDeadlineAndRemainInsideTheBudget`. Assert schema → object → no format, persisted lower capability only on success, no generic/schema-error probe, and identical deadlines. Anthropic `testEveryHTTPStatusMappingIsBodyFreeAndNeverRetriesEitherOperation` asserts one request for 400 and all listed failures. | `linux-app`, `core-macos` |
| Redirect refusal and monotonic end-to-end timeout | [URLSessionHTTPTransportTests](../../Tests/MonkeysPawCoreTests/Assistant/URLSessionHTTPTransportTests.swift): `testRefusesEveryRedirectWithoutConnectingToTarget` asserts typed refusal and zero target connections; `testDeadlineCancelsWhileWaitingForResponseHeaders` and `testDripResponseCannotExtendMonotonicDeadline` assert deadline failure and peer closure for stalled headers and a dripping body. | `linux-app`, `core-macos` |

The Keychain lifecycle uses a uniquely named real login-Keychain item and
suppresses interaction per call. Locked/unavailable access skips it. Linux
uses LinuxSecretStore with a fake `secret-tool` bridge to an in-memory test
interface on the private bus, not a real libsecret service. Reconstruction
exercises persisted settings and credentials, not an actual process relaunch.
The scanners inspect regular files without following symlinks. These limits
leave the real native-store, restart and UI checks below pending.

Owner-run gates:

| Check | Status | Record results in |
|---|---|---|
| macOS / Anthropic: Test connection, Write, Review and Improve | **NOT RUN** | [Provider matrix](assistant.md#m4-assistant-owner-checks) and every [Library flow](assistant.md#library-flows) |
| macOS / local Ollama: Test connection, Write, Review and Improve | **NOT RUN** | [Provider matrix](assistant.md#m4-assistant-owner-checks) and every [Library flow](assistant.md#library-flows) |
| Linux / Anthropic: Test connection, Write, Review and Improve | **NOT RUN** | [Provider matrix](assistant.md#m4-assistant-owner-checks) and every [Library flow](assistant.md#library-flows) |
| Linux / local Ollama: Test connection, Write, Review and Improve | **NOT RUN** | [Provider matrix](assistant.md#m4-assistant-owner-checks) and every [Library flow](assistant.md#library-flows) |
| Validation/diff, Reject/Accept exact bytes, provenance/usage, exact/unmatched review quotes, merge/identity preservation, stale buffer/disk/provider/library replies, cancellation and explicit retry | **NOT RUN** | [Library flows](assistant.md#library-flows), all rows for each provider/platform |
| Private-template refusal and template-only outbound requests, with no rendered or remembered fill values | **NOT RUN** | [Library flows privacy procedures](assistant.md#library-flows) |
| Saved-key quit/relaunch/rename/switch, native tier and zero plaintext, blank Keep/masked field, draft-only Test, destination re-entry/Clear, Clear/Delete isolation, absent-tool file warning/migration and read-only environment override | **NOT RUN** | [Key tiers and profile lifecycle](assistant.md#key-tiers-and-profile-lifecycle), every applicable row and the native Keychain ACL/update and Linux keyring procedures |
| Random sentinel scans at every lifecycle checkpoint: zero copies for strict tiers, exactly one named atomic 0600 unencrypted file while saved, zero after Clear/Delete | **NOT RUN** | [Manual sentinel scan](assistant.md#manual-sentinel-scan) |
| Real Assistant Settings/panel keyboard, screen-reader, focus, input-method, window and native-store behavior | **NOT RUN** | [Native controls and desktop behavior](assistant.md#native-controls-and-desktop-behavior-not-run) |

M4-D1 is resolved by the documented source review above, not a new
string-presence test. The README links the current B33 disclosures after
M7 D19. Live-provider/native-store checks remain open; record actual CI
results and skips before assessing M4 completion.
