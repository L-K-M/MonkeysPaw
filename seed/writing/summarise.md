---
title: Summarise
description: Condense clipboard text while preserving claims, caveats and decisions.
tags: [writing, summary]
fields:
  audience:
    type: text
    label: Audience
    default: A reader who needs the key facts without prior context
  length:
    type: choice
    label: Length
    options: [Short, Medium, Detailed]
    default: Short
  emphasis:
    type: text
    label: Particular emphasis
    description: Optional topic or question to prioritize.
    optional: true
---
Write a {{length}} summary for {{audience}}.
Particular emphasis, if supplied: {{emphasis}}

<source>
{{clipboard}}
</source>

Lead with the main point. Preserve the source's central claims, decisions,
numbers, qualifications and unresolved questions. Distinguish what the source
establishes from what it merely proposes. Do not add facts or strengthen its
certainty. Prefer connected prose; use bullets when they make parallel points
easier to scan. End with action items only if the source contains them.
