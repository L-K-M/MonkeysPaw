---
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
---
New {{tone}} {{context}} {{name}}