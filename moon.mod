// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "hackwaly/moonhub"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/moonbitlang/moonhub"

license = "Apache-2.0"

keywords = [ "cli", "git", "collaboration" ]

description = "MoonHub collaboration CLI for merge requests, issues and CI"

import {
  "moonbitlang/async@0.22.4",
  "moonbitlang/x@0.5.5",
  "moonbitstack/moondb@0.1.8",
  "moonbitstack/moonsqlite@0.3.0",
  "moonbitlang/moonback@0.8.5",
  "moonbit-community/rabbita@0.17.0",
  "moonbit-community/email@0.0.1",
  "moonbit-community/moondiff@0.1.3",
}

preferred_target = "native"
