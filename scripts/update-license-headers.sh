#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2019-Present Christian Kußowski
# SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat and Oh-My-FluffyChat
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Keep project-owned files from receiving upstream copyright attributions.
find . -type f \
  -not -path "*/.*" \
  -not -path "*/*.json" \
  -not -path "*/pubspec.lock" \
  -not -path "*/build/*" \
  -not -path "*/assets/*" \
  -not -path "*/lib/l10n/*" \
  -not -path "*/android/*" \
  -not -path "*/ios/*" \
  -not -path "*/linux/*" \
  -not -path "*/macos/*" \
  -not -path "*/LICENSE" \
  -not -path "*/LICENSES/*" \
  -not -path "*/integration_test/synapse/*" \
  -not -path "*/integration_test/data/*" \
  -not -path "*/snap/*" \
  -not -path "*/web/*" \
  -not -path "*/windows/*" \
  -not -exec grep -q 'SPDX-FileCopyrightText: .*The Oh-My-FluffyChat Project' {} \; \
  -exec reuse annotate \
  --copyright="Christian Kußowski" \
  --copyright="Contributors to FluffyChat and Oh-My-FluffyChat" \
  --license="AGPL-3.0-or-later" \
  --year="2019-Present" \
  --merge-copyrights \
  {} +
