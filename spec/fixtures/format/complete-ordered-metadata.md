---
zeta:
  second: ["on", "010", true, null, 12, 1.5]
  first:
    "yes": literal
format: 1
private: false
fields:
  notes:
    description: Details
    label: Notes
    type: multiline
    optional: true
    remember: false
    default: seed
    hint:
      z: last
      a: first
  language:
    type: choice
    options:
      - Rust
      - label: Python 3
        value: Python
        extra: keep
    default: Rust
favorite: true
tags: [code, review]
description: Review a pasted diff.
title: Review
id: 01arz3ndektsv4rrffq69g5fav
alpha: tail
---
{{language}} :: {{notes}} :: {{language}}