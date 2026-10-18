<!--
SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project

SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Translation cache

The v3 SQLite/IndexedDB schema separates encrypted content from message
references. Identical source text shares a translation across rooms for the
same full Matrix user ID. Other accounts, source/target languages and message
types remain separate. The resolved target language is used for the system
language option.

Provider IDs, endpoints, protocols, prompt revisions and models do not change
cache identity. Model names and persistence times are encrypted provenance.
The existing secure-storage master key, keyed source bindings, source-derived
AES-GCM keys and native SQLCipher protection are retained. Plaintext source
text is never written to the cache or retry settings. Payload versions are
independent of content identity.

With translation enabled, loaded messages restore cached translations even
when room automatic translation is off. Automatic translation only controls
new network requests on genuine misses. Missing credentials do not hide
cached translations. Storage failures are unavailable results, not misses.
Globally disabling translation removes the translation display components and
bypasses input translation. Only edit/delete/logout safety cleanup remains.

A manual click with no current translation may restore a shared cache entry.
A click on an already translated message forces the current provider/model
to translate again. Concurrent refreshes of identical content share one
request. Old translations remain visible on refresh and failure; request
ordering prevents older responses from replacing a newer refresh.

Editing or deleting a message destroys every language/type/account variant
for its previous source binding and all shared references, including original
and edit references. Transactional source generations reject late writes.
No rollback restores a deleted snapshot. Room leave/logout use ordinary
reference and orphan cleanup. Web contexts notify each other about content
changes and safety cleanup, and recheck on reactivation.

Web Locks coordinate key creation, cache access and cleanup across tabs.
Browsers without that facility treat cache storage as unavailable. A database
instance identifier also prevents requests from writing back into a cache
that was explicitly cleared and recreated. Every alias records a reference,
including messages joining an in-flight shared request. Timeline display
events retain their original-message relationship for deletion safety.

An absent database is a normal noncreating no-op. Missing keys never cause
database deletion or replacement key generation. Storage/key failures defer
cleanup using deduplicated identifiers in application settings; cleanup is
replayed before cache hits. An unresolvable scope suspends hits until resolved
or explicitly cleared. Secure keys/databases are created lazily when a
successful authorized network translation is persisted.

## Legacy migration

Migration runs only as part of the manual "Clean obsolete cache" action,
before invalid entries are checked. Manual maintenance also works while
translation is disabled. Each atomic batch processes at most 200 rows with
keyset pagination and a persisted checkpoint. Ownerless rows remain sealed.
Available sources are checked against local edits/redactions and re-encrypted
during migration; temporarily unavailable sources are retained. Sealed
envelopes retain their original AAD until the source is available for
authentication and re-encryption.

Legacy data has no timestamps. The winner is the greatest surviving SQLite
rowid, or the lexicographically greatest IndexedDB cache key. The Web rule is
deterministic and cannot establish actual chronological order. Losing rows
still contribute references, so deleting any represented message destroys the
shared content. Actual new-format writes take precedence over backfills.
Migration never makes translation API requests.
