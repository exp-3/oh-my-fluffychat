<!--
SPDX-FileCopyrightText: 2019-Present Christian Kußowski
SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat and Oh-My-FluffyChat

SPDX-License-Identifier: AGPL-3.0-or-later
-->

Has been moved to https://fluffychat.im/privacy

## Optional LM translation and translation roaming

Optional LM translation sends message text, media descriptions, and drafts
(when input translation is enabled) to the provider you configure. This
includes content from encrypted rooms. The provider can read the original text
and translations; its privacy and retention policies apply.

Optional translation roaming stores encrypted message translations with a
service you configure. Encryption happens on your device; the pre-shared key
is never sent to that service. Devices sharing the key and storage configuration
can reuse translations. Drafts are not uploaded through roaming. Clearing local
data does not delete cloud copies, which expire after the configured period of
cloud inactivity.
