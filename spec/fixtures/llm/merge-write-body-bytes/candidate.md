---
id: 01K6Z4V9KQWZX7MPQ4T8ZNB2PD
title: "true"
description: "line one\n---\nline two"
tags:
- "on"
- "010"
- "true"
fields:
  tone:
    type: choice
    label: Tone
    description: Help
    optional: false
    remember: true
    default: Swift
    options:
    - Rust
    - label: Swift 6
      value: Swift
  context:
    type: multiline
    label: Context
    description: ""
    optional: true
    remember: false
  name:
    type: text
    label: Name
    description: ""
    optional: false
    remember: true
    default: Reader
---
﻿  文書 {{tone}}
é {{context}} {{name}}

