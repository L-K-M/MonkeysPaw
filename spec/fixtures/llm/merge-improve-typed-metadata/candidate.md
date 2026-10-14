---
id: 01K6Z4V9KQWZX7MPQ4T8ZNB2PD
title: New title
description: New description
tags:
- "on"
- "010"
- "true"
favorite: true
private: true
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
format: 1
model:
  settings:
    enabled: true
    count: 2
    ratio: 1.5
    absent: null
  strings:
  - "on"
  - "010"
  - "true"
  nested:
  - second:
    - false
    - deep: value
    first: 1
extension:
  "1": string key
  1: integer key
notes: User metadata
---
New {{tone}} {{context}} {{name}}