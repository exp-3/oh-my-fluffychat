<!--
SPDX-FileCopyrightText: 2019-Present Christian Kußowski
SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat

SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Instructions for Coding Agents

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the full contribution guidelines and code examples.

No repository collaborator access is required to open a pull request.

## Contributing Guidelines

1. AI-assisted and AI-generated contributions, including vibe coding, are allowed. If you plan to rely on prompts to produce an implementation rather than use AI as a coding assistant, and/or you do not plan to verify the changes in detail, using a top-tier frontier model is recommended.
2. Prefer each pull request to contain a single commit and focus on one change topic.
3. Do not add merge commits. Use rebases.
4. Keep each pull request focused on one change; split larger changes into separate pull requests.
5. [Signing your commits](https://docs.github.com/en/authentication/managing-commit-signature-verification/signing-commits) is recommended. If commit signing is already configured, sign commits whenever possible; configuring commit signing is not required.
6. Format the commit message as [Conventional Commits](https://www.conventionalcommits.org).
7. If you plan to contribute a new feature, consider discussing it with this repository's maintainers before starting implementation. If you have already implemented it for your own use, feel free to open a pull request directly.
8. Prefer simple, maintainable solutions over complexity.
9. Upstream manages its `.arb` translations through [Weblate](https://hosted.weblate.org/projects/fluffychat/). When adding new features to this fork, you may add the new strings and their translations directly to `.arb` files. For missing translations of existing upstream strings, please use Weblate.
10. Add comments only for workarounds with an upstream issue link or for unusual decisions that require a rationale.
11. Avoid overengineering and abstractions used only once; fit code to the current architecture.
12. Avoid using `else` and prefer function guards, early returns and `switch`.
13. Do not add functionality in platform directories. Use external packages for platform channels. Remove existing workarounds where possible and do not add new ones, except for edge cases such as the iOS Notification Service Extension.
14. Keep dependencies and external packages minimal and maintained.

## Code Style

Keep code clean, simple, and readable. Application source is under `/lib`; the entry point is `/lib/main.dart`.

### Directory Structure:

- /lib
  - /config
  - /utils
  - /pages
    - /chat
      - chat.dart
      - chat_view.dart
    - /chat_list
      - chat_list.dart
      - chat_list_view.dart
    - Controller and view files
  - /widgets
    - /layouts
  - main.dart

Keep business models in the Matrix Dart SDK; extend them under `/utils` instead of duplicating them in the application source.

### Separation of Controllers and Views

Use stateful widgets as controllers and stateless widgets as views. Controllers own state and actions; views receive state, build the widget tree, and pass callbacks back.

Keep view code descriptive. Put other parameters and logic in the controller; put nontrivial view calculations in `/lib/utils/`.

Use lower_snake_case file names. Suffix views with `View` and controllers with `Controller`. Pass widget callbacks back to views where possible; call one-line view methods directly only when they need no parameters.

### Formatting

Run `flutter format lib` and keep the code free of formatting errors.

### Code Analyzis

Keep Dart code free of errors and warnings. Use [flutter_lints](https://pub.dev/packages/flutter_lints) and the additional rules in `analysis_options.yaml`.
