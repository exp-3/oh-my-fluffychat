// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/translation/translation_roaming_upload.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:fluffychat/widgets/layouts/settings_spacing.dart';
import 'package:material_ui/material_ui.dart';

import 'translation_roaming_upload_page.dart';

class TranslationRoamingUploadView extends StatelessWidget {
  final TranslationRoamingUploadController controller;

  const TranslationRoamingUploadView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final session = controller.session;
    final scanning = controller.scanning;
    return PopScope(
      onPopInvokedWithResult: controller.onPopInvoked,
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: controller.back),
          title: Text(l10n.translationRoamingUploadLocal),
        ),
        body: MaxWidthBody(
          withScrolling: false,
          contentPadding: EdgeInsets.zero,
          child: Builder(
            builder: (context) {
              if (scanning) {
                return Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(SettingsSpacing.inset),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: SettingsSpacing.field),
                        Text(l10n.translationRoamingUploadScanning),
                        const SizedBox(height: SettingsSpacing.actions),
                        TextButton(
                          onPressed: controller.back,
                          child: Text(l10n.cancel),
                        ),
                      ],
                    ),
                  ),
                );
              }
              if (controller.unavailable ||
                  session == null ||
                  (session.phase == TranslationRoamingUploadPhase.ready &&
                      session.rooms.isEmpty)) {
                final message = controller.unavailable || session == null
                    ? l10n.translationRoamingUploadUnavailable
                    : l10n.translationRoamingUploadEmpty;
                return Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(SettingsSpacing.inset),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(message),
                        const SizedBox(height: SettingsSpacing.actions),
                        OutlinedButton.icon(
                          onPressed: controller.load,
                          icon: const Icon(Icons.refresh),
                          label: Text(l10n.tryAgain),
                        ),
                      ],
                    ),
                  ),
                );
              }
              if (session.phase != TranslationRoamingUploadPhase.ready) {
                final uploading =
                    session.phase == TranslationRoamingUploadPhase.uploading;
                final failed =
                    session.phase == TranslationRoamingUploadPhase.failed;
                final stopped =
                    session.phase == TranslationRoamingUploadPhase.stopped;
                return Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(SettingsSpacing.inset),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (uploading) ...[
                          LinearProgressIndicator(
                            value: session.total == 0
                                ? null
                                : session.processed / session.total,
                          ),
                          const SizedBox(height: SettingsSpacing.field),
                          Text(
                            l10n.translationRoamingUploadProgress(
                              session.processed,
                              session.total,
                            ),
                          ),
                        ],
                        if (failed) Text(l10n.oopsSomethingWentWrong),
                        if (stopped) Text(l10n.translationRoamingUploadStopped),
                        if (uploading || failed || stopped)
                          const SizedBox(height: SettingsSpacing.field),
                        Text(
                          l10n.translationRoamingUploadResult(
                            session.uploaded,
                            session.existing,
                            session.skipped,
                            session.failed,
                          ),
                        ),
                        const SizedBox(height: SettingsSpacing.actions),
                        if (uploading)
                          OutlinedButton(
                            onPressed: controller.cancelUpload,
                            child: Text(l10n.cancel),
                          ),
                        if (!uploading)
                          OutlinedButton.icon(
                            onPressed: controller.load,
                            icon: const Icon(Icons.refresh),
                            label: Text(l10n.tryAgain),
                          ),
                      ],
                    ),
                  ),
                );
              }
              final visible = controller.visibleRooms;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: CustomScrollView(
                      slivers: [
                        SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  SettingsSpacing.inset,
                                  SettingsSpacing.inset,
                                  SettingsSpacing.inset,
                                  SettingsSpacing.field,
                                ),
                                child: Text(
                                  l10n.translationRoamingUploadDescription,
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: SettingsSpacing.inset,
                                ),
                                child: TextField(
                                  controller: controller.search,
                                  onChanged: controller.searchChanged,
                                  decoration: InputDecoration(
                                    hintText: l10n.search,
                                    prefixIcon: const Icon(
                                      Icons.search_outlined,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: SettingsSpacing.field),
                              CheckboxListTile.adaptive(
                                title: Text(
                                  l10n.translationRoamingUploadSelectAll,
                                ),
                                tristate: true,
                                value: controller.selectAllValue,
                                onChanged: visible.isEmpty
                                    ? null
                                    : controller.toggleVisibleSelection,
                              ),
                            ],
                          ),
                        ),
                        SliverList.builder(
                          itemCount: visible.length,
                          itemBuilder: (context, index) {
                            final room = visible[index];
                            final id = room.candidate.roomId;
                            return CheckboxListTile.adaptive(
                              key: ValueKey(id),
                              title: Text(room.name),
                              subtitle: Text(
                                l10n.translationRoamingUploadCount(
                                  room.candidate.count,
                                ),
                              ),
                              value: controller.isSelected(id),
                              onChanged: (value) =>
                                  controller.changeSelection(id, value),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  Divider(height: 1, color: Theme.of(context).dividerColor),
                  Padding(
                    padding: const EdgeInsets.all(SettingsSpacing.inset),
                    child: FilledButton.icon(
                      onPressed: controller.canUpload
                          ? controller.upload
                          : null,
                      icon: const Icon(Icons.cloud_upload_outlined),
                      label: Text(l10n.translationRoamingUploadLocal),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
