// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat and Oh-My-FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat_search/chat_search_files_tab.dart';
import 'package:fluffychat/pages/chat_search/chat_search_images_tab.dart';
import 'package:fluffychat/pages/chat_search/chat_search_message_tab.dart';
import 'package:fluffychat/pages/chat_search/chat_search_page.dart';
import 'package:fluffychat/pages/chat_search/search_status.dart';
import 'package:fluffychat/utils/chat_search_models.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class ChatSearchView extends StatelessWidget {
  final ChatSearchController controller;

  const ChatSearchView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final room = controller.room;
    if (room == null ||
        !room.client.isLogged() ||
        room.membership != Membership.join) {
      return Scaffold(
        appBar: AppBar(title: Text(L10n.of(context).oopsSomethingWentWrong)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(L10n.of(context).youAreNoLongerParticipatingInThisChat),
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    final session = controller.session;

    return Scaffold(
      appBar: AppBar(
        leading: const Center(child: BackButton()),
        titleSpacing: 0,
        title: Text(
          L10n.of(context).searchIn(
            room.getLocalizedDisplayname(MatrixLocals(L10n.of(context))),
          ),
        ),
      ),
      body: MaxWidthBody(
        withScrolling: false,
        child: Column(
          children: [
            if (FluffyThemes.isThreeColumnMode(context))
              const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: controller.searchController,
                onSubmitted: (_) => controller.submitQuery(),
                textInputAction: TextInputAction.search,
                autofocus: true,
                enabled: controller.tabController.index == 0,
                decoration: InputDecoration(
                  hintText: L10n.of(context).search,
                  prefixIcon: const Icon(Icons.search_outlined),
                  filled: true,
                  fillColor: theme.colorScheme.secondaryContainer,
                  border: OutlineInputBorder(
                    borderSide: BorderSide.none,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  hintStyle: TextStyle(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.normal,
                  ),
                ),
              ),
            ),
            if (session != null)
              ListenableBuilder(
                listenable: session,
                builder: (context, _) => ChatSearchStatus(
                  query: session.query,
                  runState: session.runState,
                  searchedUntil: session.searchedUntil,
                  undecryptableCount: session.undecryptableCount,
                  onPause: controller.pauseSearch,
                  onResume: controller.resumeSearch,
                ),
              ),
            TabBar(
              controller: controller.tabController,
              tabs: [
                Tab(child: Text(L10n.of(context).messages)),
                Tab(child: Text(L10n.of(context).gallery)),
                Tab(child: Text(L10n.of(context).files)),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: controller.tabController,
                children: [
                  ListenableBuilder(
                    listenable: session ?? controller.tabController,
                    builder: (context, _) => ChatSearchMessageTab(
                      key: ObjectKey(session),
                      searchQuery: session?.query ?? '',
                      room: room,
                      onResume: controller.resumeSearch,
                      results: session?.results ?? const [],
                      runState: session?.runState ?? ChatSearchRunState.idle,
                      queryRevision: session?.queryRevision ?? 0,
                    ),
                  ),
                  ChatSearchImagesTab(
                    room: room,
                    onStartSearch: controller.loadImages,
                    events: controller.imagesState.events,
                    endReached: controller.imagesState.endReached,
                    isLoading: controller.imagesState.isLoading,
                    searchedUntil: controller.imagesState.searchedUntil,
                    error: controller.imagesState.error,
                  ),
                  ChatSearchFilesTab(
                    room: room,
                    onStartSearch: controller.loadFiles,
                    events: controller.filesState.events,
                    endReached: controller.filesState.endReached,
                    isLoading: controller.filesState.isLoading,
                    searchedUntil: controller.filesState.searchedUntil,
                    error: controller.filesState.error,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
