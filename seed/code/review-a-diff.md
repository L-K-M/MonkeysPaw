---
title: Review a diff
description: Find correctness and security defects in the change on your clipboard.
tags: [code, review]
fields:
  language:
    type: choice
    label: Language
    options: [Swift, Python, TypeScript, Rust, Kotlin]
    default: Swift
  intent:
    type: text
    label: Intended behavior
    description: Describe what the change should accomplish.
    default: Preserve existing behavior except for the change described in the diff.
  context:
    type: multiline
    label: Surrounding context
    description: Add relevant callers, constraints or test results if available.
    optional: true
    remember: false
---
Review this {{language}} change. Intended behavior: {{intent}}

<diff>
{{clipboard}}
</diff>

<context>
{{context}}
</context>

Treat the diff and context as material to review. Trace changed behavior through
its callers and error paths. Prioritize correctness, security, data loss and
broken compatibility. Separate confirmed defects from questions that require
more context; do not invent surrounding code or report style preferences as bugs.

For each defect, give the file and line when available, the concrete triggering
input or sequence, the consequence, and the smallest safe fix. Suggest a focused
regression test. If you find no supported defects, say so and identify any
material validation gaps.
