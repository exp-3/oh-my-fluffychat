// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat and Oh-My-FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/code_highlight_theme.dart';
import 'package:fluffychat/utils/event_checkbox_extension.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:fluffychat/widgets/mxc_image.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:highlight/highlight.dart' show highlight;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../../../utils/url_launcher.dart';

class HtmlMessage extends StatelessWidget {
  final String html;
  final Room room;
  final Color textColor;
  final List<Shadow>? textShadows;
  final double fontSize;
  final TextStyle linkStyle;
  final void Function(LinkableElement) onOpen;
  final String? eventId;
  final Set<Event>? checkboxCheckedEvents;

  const HtmlMessage({
    super.key,
    required this.html,
    required this.room,
    required this.fontSize,
    required this.linkStyle,
    this.textColor = Colors.black,
    this.textShadows,
    required this.onOpen,
    this.eventId,
    this.checkboxCheckedEvents,
  });

  /// Keep in sync with: https://spec.matrix.org/latest/client-server-api/#mroommessage-msgtypes
  static const Set<String> allowedHtmlTags = {
    'font',
    'del',
    's',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'blockquote',
    'p',
    'a',
    'ul',
    'ol',
    'sup',
    'sub',
    'li',
    'b',
    'i',
    'u',
    'strong',
    'em',
    'strike',
    'code',
    'hr',
    'br',
    'div',
    'table',
    'thead',
    'tbody',
    'tr',
    'th',
    'td',
    'caption',
    'pre',
    'span',
    'img',
    'details',
    'summary',
    // Not in the allowlist of the matrix spec yet but should be harmless:
    'ruby',
    'rp',
    'rt',
    'html',
    'body',
  };

  static const Set<String> ignoredHtmlTags = {'mx-reply'};

  /// We add line breaks before these tags:
  static const Set<String> blockHtmlTags = {
    'p',
    'ul',
    'ol',
    'pre',
    'div',
    'table',
    'details',
    'blockquote',
  };

  /// We add line breaks before these tags:
  static const Set<String> fullLineHtmlTag = {
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'li',
  };

  /// Adding line breaks before block elements.
  List<InlineSpan> _renderWithLineBreaks(
    dom.NodeList nodes,
    BuildContext context, {
    int depth = 1,
  }) {
    final onlyElements = nodes.whereType<dom.Element>().toList();
    return [
      for (var i = 0; i < nodes.length; i++) ...[
        // Actually render the node child:
        _renderHtml(nodes[i], context, depth: depth + 1),
        // Add linebreaks between blocks:
        if (nodes[i] is dom.Element &&
            onlyElements.indexOf(nodes[i] as dom.Element) <
                onlyElements.length - 1) ...[
          if (blockHtmlTags.contains((nodes[i] as dom.Element).localName))
            const TextSpan(text: '\n\n'),
          if (fullLineHtmlTag.contains((nodes[i] as dom.Element).localName))
            const TextSpan(text: '\n'),
        ],
      ],
    ];
  }

  InlineSpan _renderCodeBlockNode(dom.Node node) {
    if (node is! dom.Element) {
      return TextSpan(text: node.text);
    }
    final style =
        atomOneDarkTheme[node.className.split('-').last] ??
        atomOneDarkTheme['root'];

    return TextSpan(
      children: node.nodes.map(_renderCodeBlockNode).toList(),
      style: style,
    );
  }

  /// Transforms a Node to an InlineSpan.
  InlineSpan _renderHtml(dom.Node node, BuildContext context, {int depth = 1}) {
    // We must not render elements nested more than 100 elements deep:
    if (depth >= 100) return const TextSpan();

    if (node is dom.Element &&
        ignoredHtmlTags.contains(node.localName?.toLowerCase())) {
      return const TextSpan();
    }

    // This is a text node or not permitted node, so we render it as text:
    if (node is! dom.Element || !allowedHtmlTags.contains(node.localName)) {
      var text = node.text ?? '';
      // Single linebreak nodes between Elements are ignored:
      if (text == '\n') text = '';

      return LinkifySpan(
        text: text,
        options: const LinkifyOptions(humanize: false),
        linkStyle: linkStyle,
        onOpen: onOpen,
      );
    }

    switch (node.localName) {
      case 'br':
        return const TextSpan(text: '\n');
      case 'a':
        final href = node.attributes['href'];
        if (href == null) continue block;
        final matrixId = node.attributes['href']
            ?.parseIdentifierIntoParts()
            ?.primaryIdentifier;
        if (matrixId != null) {
          if (matrixId.sigil == '@') {
            final user = room.unsafeGetUserFromMemoryOrFallback(matrixId);
            return WidgetSpan(
              child: MatrixPill(
                key: Key('user_pill_$matrixId'),
                name: user.calcDisplayname(),
                avatar: user.avatarUrl,
                uri: href,
                outerContext: context,
                fontSize: fontSize,
                color: linkStyle.color,
              ),
            );
          }
          if (matrixId.sigil == '#' || matrixId.sigil == '!') {
            final room = matrixId.sigil == '!'
                ? this.room.client.getRoomById(matrixId)
                : this.room.client.getRoomByAlias(matrixId);
            return WidgetSpan(
              child: MatrixPill(
                name: room?.getLocalizedDisplayname() ?? matrixId,
                avatar: room?.avatar,
                uri: href,
                outerContext: context,
                fontSize: fontSize,
                color: linkStyle.color,
              ),
            );
          }
        }
        return WidgetSpan(
          child: Tooltip(
            message: href,
            child: InkWell(
              splashColor: Colors.transparent,
              onTap: () => UrlLauncher(context, href, node.text).launchUrl(),
              child: Text.rich(
                TextSpan(
                  children: _renderWithLineBreaks(
                    node.nodes,
                    context,
                    depth: depth,
                  ),
                  style: linkStyle,
                ),
                style: const TextStyle(height: 1.25),
              ),
            ),
          ),
        );
      case 'li':
        if (!{'ol', 'ul'}.contains(node.parent?.localName)) {
          continue block;
        }
        final eventId = this.eventId;

        final isCheckbox = node.className == 'task-list-item';
        final checkboxIndex = isCheckbox
            ? node.rootElement
                      .getElementsByClassName('task-list-item')
                      .indexOf(node) +
                  1
            : null;
        final checkedByReaction = !isCheckbox
            ? null
            : checkboxCheckedEvents?.firstWhereOrNull(
                (event) => event.checkedCheckboxId == checkboxIndex,
              );
        final staticallyChecked =
            isCheckbox && node.children.first.attributes['checked'] == 'true';

        return WidgetSpan(
          child: Padding(
            padding: EdgeInsetsDirectional.only(start: fontSize),
            child: Text.rich(
              TextSpan(
                children: [
                  if (!isCheckbox) ...[
                    if (node.parent?.localName == 'ul')
                      const TextSpan(text: '• '),
                    if (node.parent?.localName == 'ol')
                      TextSpan(
                        text:
                            '${(node.parent?.nodes.whereType<dom.Element>().toList().indexOf(node) ?? 0) + (int.tryParse(node.parent?.attributes['start'] ?? '1') ?? 1)}. ',
                      ),
                  ],
                  if (node.className == 'task-list-item')
                    WidgetSpan(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8.0),
                        child: SizedBox.square(
                          dimension: fontSize + 2,
                          child: CupertinoCheckbox(
                            checkColor: textColor,
                            side: BorderSide(color: textColor),
                            activeColor: textColor.withAlpha(64),
                            value:
                                staticallyChecked || checkedByReaction != null,
                            onChanged:
                                eventId == null ||
                                    checkboxIndex == null ||
                                    staticallyChecked ||
                                    !room.canSendDefaultMessages ||
                                    (checkedByReaction != null &&
                                        checkedByReaction.senderId !=
                                            room.client.userID)
                                ? null
                                : (_) => showFutureLoadingDialog(
                                    context: context,
                                    future: () => checkedByReaction != null
                                        ? room.redactEvent(
                                            checkedByReaction.eventId,
                                          )
                                        : room.checkCheckbox(
                                            eventId,
                                            checkboxIndex,
                                          ),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ..._renderWithLineBreaks(node.nodes, context, depth: depth),
                ],
                style: TextStyle(fontSize: fontSize, color: textColor),
              ),
            ),
          ),
        );
      case 'blockquote':
        return WidgetSpan(
          child: Container(
            padding: const EdgeInsetsDirectional.only(start: 8.0),
            decoration: BoxDecoration(
              border: BorderDirectional(
                start: BorderSide(color: textColor, width: 5),
              ),
            ),
            child: Text.rich(
              TextSpan(
                children: _renderWithLineBreaks(
                  node.nodes,
                  context,
                  depth: depth,
                ),
              ),
              style: TextStyle(
                fontStyle: FontStyle.italic,
                fontSize: fontSize,
                color: textColor,
              ),
            ),
          ),
        );
      case 'pre':
        if (node.children.length == 1 &&
            node.children.first.localName == 'code') {
          return _renderHtml(node.children.first, context, depth: depth + 1);
        }
        continue code;
      code:
      case 'code':
        final isInline =
            node.localName == 'code' && node.parent?.localName != 'pre';
        final lang =
            node.className
                .split(' ')
                .singleWhereOrNull(
                  (className) => className.startsWith('language-'),
                )
                ?.split('language-')
                .last ??
            'md';
        final highlightedHtml = highlight
            .parse(node.text, language: lang)
            .toHtml();
        final element = parser.parse(highlightedHtml).body;
        if (element == null) {
          return const TextSpan(text: 'Unable to render code block!');
        }

        final codeBlock = Material(
          color: atomOneBackgroundColor,
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: hightlightTextColor),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Padding(
            padding: isInline
                ? const EdgeInsets.symmetric(horizontal: 4.0)
                : const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
            child: Text.rich(
              TextSpan(children: [_renderCodeBlockNode(element)]),
              selectionColor: hightlightTextColor.withAlpha(128),
            ),
          ),
        );
        return WidgetSpan(child: codeBlock);
      case 'img':
        final mxcUrl = Uri.tryParse(node.attributes['src'] ?? '');
        if (mxcUrl == null || mxcUrl.scheme != 'mxc') {
          return TextSpan(text: node.attributes['alt']);
        }

        final width = double.tryParse(node.attributes['width'] ?? '');
        final height = double.tryParse(node.attributes['height'] ?? '');
        const defaultDimension = 64.0;
        final actualWidth = width ?? height ?? defaultDimension;
        final actualHeight = height ?? width ?? defaultDimension;

        return WidgetSpan(
          child: SizedBox(
            width: actualWidth,
            height: actualHeight,
            child: MxcImage(
              uri: mxcUrl,
              width: actualWidth,
              height: actualHeight,
              isThumbnail: (actualWidth * actualHeight) > (256 * 256),
            ),
          ),
        );
      case 'table':
        return WidgetSpan(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Table(
              defaultColumnWidth: const IntrinsicColumnWidth(),
              border: TableBorder.all(color: textColor.withAlpha(100)),
              children: node.nodes
                  .whereType<dom.Element>()
                  .expand(
                    (e) =>
                        e.localName == 'thead' ||
                            e.localName == 'tbody' ||
                            e.localName == 'tfoot'
                        ? e.nodes.whereType<dom.Element>()
                        : [e],
                  )
                  .where((e) => e.localName == 'tr')
                  .map(
                    (tr) => TableRow(
                      children: tr.nodes
                          .whereType<dom.Element>()
                          .where(
                            (e) => e.localName == 'td' || e.localName == 'th',
                          )
                          .map(
                            (cell) => Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 3,
                              ),
                              child: Text.rich(
                                TextSpan(
                                  children: _renderWithLineBreaks(
                                    cell.nodes,
                                    context,
                                    depth: depth,
                                  ),
                                  style: cell.localName == 'th'
                                      ? const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        )
                                      : null,
                                ),
                                style: TextStyle(
                                  fontSize: fontSize,
                                  color: textColor,
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  )
                  .toList(),
            ),
          ),
        );
      case 'thead':
      case 'tbody':
      case 'tfoot':
      case 'tr':
      case 'th':
      case 'td':
      case 'caption':
        // These are handled by the 'table' case above; if encountered
        // outside a table, render children inline as fallback.
        return TextSpan(
          children: _renderWithLineBreaks(node.nodes, context, depth: depth),
        );
      case 'hr':
        return const WidgetSpan(child: Divider());
      case 'details':
        final obscure = ValueNotifier(true);
        final summary = node.nodes
            .where((node) => node is dom.Element && node.localName == 'summary')
            .map((node) => _renderHtml(node, context, depth: depth))
            .toList();
        final details = _renderWithLineBreaks(
          node.nodes,
          context,
          depth: depth,
        );
        return WidgetSpan(
          child: ValueListenableBuilder<bool>(
            valueListenable: obscure,
            builder: (context, hidden, _) => InkWell(
              splashColor: Colors.transparent,
              onTap: () => obscure.value = !obscure.value,
              child: Text.rich(
                TextSpan(
                  children: [
                    WidgetSpan(
                      child: Icon(
                        hidden ? Icons.arrow_right : Icons.arrow_drop_down,
                        size: fontSize * 1.2,
                        color: textColor,
                      ),
                    ),
                    if (hidden) ...summary else ...details,
                  ],
                ),
                style: TextStyle(fontSize: fontSize, color: textColor),
              ),
            ),
          ),
        );
      case 'span':
        if (!node.attributes.containsKey('data-mx-spoiler')) {
          continue block;
        }
        final obscure = ValueNotifier(true);
        final spoiler = _renderWithLineBreaks(
          node.nodes,
          context,
          depth: depth,
        );
        return WidgetSpan(
          child: ValueListenableBuilder<bool>(
            valueListenable: obscure,
            builder: (context, hidden, _) => InkWell(
              splashColor: Colors.transparent,
              onTap: () => obscure.value = !obscure.value,
              child: Text.rich(
                TextSpan(children: spoiler),
                style: TextStyle(
                  fontSize: fontSize,
                  color: textColor,
                  backgroundColor: hidden ? textColor : null,
                ),
              ),
            ),
          ),
        );
      block:
      default:
        return TextSpan(
          style: switch (node.localName) {
            'body' => TextStyle(fontSize: fontSize, color: textColor),
            'a' => linkStyle,
            'strong' => const TextStyle(fontWeight: FontWeight.bold),
            'em' || 'i' => const TextStyle(fontStyle: FontStyle.italic),
            'del' || 's' || 'strikethrough' => const TextStyle(
              decoration: TextDecoration.lineThrough,
            ),
            'u' => const TextStyle(decoration: TextDecoration.underline),
            'h1' => TextStyle(fontSize: fontSize * 1.6, height: 2),
            'h2' => TextStyle(fontSize: fontSize * 1.5, height: 2),
            'h3' => TextStyle(fontSize: fontSize * 1.4, height: 2),
            'h4' => TextStyle(fontSize: fontSize * 1.3, height: 1.75),
            'h5' => TextStyle(fontSize: fontSize * 1.2, height: 1.75),
            'h6' => TextStyle(fontSize: fontSize * 1.1, height: 1.5),
            'span' => TextStyle(
              color:
                  node.attributes['color']?.hexToColor ??
                  node.attributes['data-mx-color']?.hexToColor ??
                  textColor,
              backgroundColor: node.attributes['data-mx-bg-color']?.hexToColor,
            ),
            'sup' => const TextStyle(
              fontFeatures: [FontFeature.superscripts()],
            ),
            'sub' => const TextStyle(fontFeatures: [FontFeature.subscripts()]),
            _ => null,
          },
          children: _renderWithLineBreaks(node.nodes, context, depth: depth),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final element = parser.parse(html).body ?? dom.Element.html('');
    for (final reply in element.querySelectorAll('mx-reply')) {
      reply.remove();
    }
    final configuredMaxLines = AppSettings.messagePreviewMaxLines.value;
    final maxLines = configuredMaxLines <= 0 ? null : configuredMaxLines;
    final span = _renderHtml(element, context);
    final style = TextStyle(
      fontSize: fontSize,
      color: textColor,
      shadows: textShadows,
    );

    if (maxLines == null) {
      return Text.rich(
        span,
        style: style,
        selectionColor: textColor.withAlpha(128),
      );
    }

    return _CollapsibleText(
      html: html,
      span: span,
      style: style,
      maxLines: maxLines,
      textColor: textColor,
      linkColor: linkStyle.color ?? textColor,
    );
  }
}

class _CollapsibleText extends StatefulWidget {
  final String html;
  final InlineSpan span;
  final TextStyle style;
  final int maxLines;
  final Color textColor;
  final Color linkColor;

  const _CollapsibleText({
    required this.html,
    required this.span,
    required this.style,
    required this.maxLines,
    required this.textColor,
    required this.linkColor,
  });

  @override
  State<_CollapsibleText> createState() => _CollapsibleTextState();
}

class _CollapsibleTextState extends State<_CollapsibleText> {
  bool _expanded = false;
  int? _cutoff;
  bool _measured = false;

  @override
  void didUpdateWidget(_CollapsibleText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html ||
        oldWidget.maxLines != widget.maxLines ||
        oldWidget.style != widget.style) {
      _cutoff = null;
      _measured = false;
    }
  }

  void _updateCutoff(int? cutoff) {
    if (!mounted || (_measured && _cutoff == cutoff)) return;
    setState(() {
      _measured = true;
      _cutoff = cutoff;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final cutoff = _cutoff;
    final collapsed = !_expanded && cutoff != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSize(
          duration: FluffyThemes.animationDuration,
          curve: FluffyThemes.animationCurve,
          alignment: AlignmentDirectional.topStart,
          child: Stack(
            children: [
              _MessageLayoutProbe(
                maxLines: widget.maxLines,
                onCutoffChanged: _updateCutoff,
                measure: !collapsed,
                child: Text.rich(
                  !_expanded && cutoff != null
                      ? _takeSpan(widget.span, cutoff)
                      : widget.span,
                  style: widget.style,
                  selectionColor: widget.textColor.withAlpha(128),
                ),
              ),
              if (collapsed)
                // Measure the complete body without exposing hidden text to
                // selection, focus, or accessibility in the visible subtree.
                Offstage(
                  child: TickerMode(
                    enabled: false,
                    child: ExcludeSemantics(
                      child: ExcludeFocus(
                        child: IgnorePointer(
                          child: SelectionContainer.disabled(
                            child: _MessageLayoutProbe(
                              maxLines: widget.maxLines,
                              onCutoffChanged: _updateCutoff,
                              child: Text.rich(
                                widget.span,
                                style: widget.style,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (cutoff != null)
          Center(
            child: TextButton.icon(
              onPressed: () => setState(() {
                _expanded = !_expanded;
              }),
              style: TextButton.styleFrom(foregroundColor: widget.linkColor),
              icon: Icon(
                _expanded ? Icons.arrow_drop_up : Icons.arrow_drop_down,
              ),
              label: Text(_expanded ? l10n.showLess : l10n.showMore),
            ),
          ),
      ],
    );
  }
}

InlineSpan _takeSpan(InlineSpan span, int length) {
  if (length >= span.toPlainText(includeSemanticsLabels: false).length) {
    return span;
  }
  if (span is! TextSpan) return length > 0 ? span : const TextSpan();
  final text = span.text;
  final textLength = text?.length ?? 0;
  final visibleText = text?.substring(0, math.min(length, textLength));
  var remaining = math.max(0, length - textLength);
  final children = <InlineSpan>[];
  for (final child in span.children ?? const <InlineSpan>[]) {
    if (remaining == 0) break;
    final childLength = child.toPlainText(includeSemanticsLabels: false).length;
    children.add(_takeSpan(child, remaining));
    remaining = math.max(0, remaining - childLength);
  }
  return TextSpan(
    text: visibleText,
    children: children,
    style: span.style,
    recognizer: span.recognizer,
    mouseCursor: span.mouseCursor,
    onEnter: span.onEnter,
    onExit: span.onExit,
    locale: span.locale,
    spellOut: span.spellOut,
  );
}

class _MessageLayoutProbe extends SingleChildRenderObjectWidget {
  final int maxLines;
  final ValueChanged<int?> onCutoffChanged;
  final bool measure;

  const _MessageLayoutProbe({
    required this.maxLines,
    required this.onCutoffChanged,
    this.measure = true,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMessageLayoutProbe(maxLines, onCutoffChanged, measure);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMessageLayoutProbe renderObject,
  ) {
    renderObject
      ..maxLines = maxLines
      ..onCutoffChanged = onCutoffChanged
      ..measure = measure
      ..markNeedsLayout();
  }
}

class _RenderMessageLayoutProbe extends RenderProxyBox {
  _RenderMessageLayoutProbe(
    this._maxLines,
    this.onCutoffChanged,
    this._measure,
  );

  int _maxLines;
  ValueChanged<int?> onCutoffChanged;
  bool _measure;
  bool _measurementPending = false;
  int _measurementGeneration = 0;

  set measure(bool value) {
    if (_measure == value) return;
    _measure = value;
    markNeedsLayout();
  }

  set maxLines(int value) {
    if (_maxLines == value) return;
    _maxLines = value;
    markNeedsLayout();
  }

  RenderParagraph? _findParagraph(RenderObject node) {
    if (node is RenderParagraph) return node;
    RenderParagraph? paragraph;
    node.visitChildren((child) {
      paragraph ??= _findParagraph(child);
    });
    return paragraph;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    markNeedsLayout();
  }

  @override
  void detach() {
    _measurementGeneration++;
    _measurementPending = false;
    super.detach();
  }

  @override
  void performLayout() {
    super.performLayout();
    if (!_measure || _measurementPending) return;
    _measurementPending = true;
    final generation = _measurementGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (generation != _measurementGeneration) return;
      _measurementPending = false;
      if (!attached || !_measure || !hasSize) return;
      // Inline widgets are descendants of the paragraph. Their sizes may only
      // be inspected once the active layout pass has finished.
      final paragraph = child == null ? null : _findParagraph(child!);
      if (paragraph == null || !paragraph.hasSize) return;
      onCutoffChanged(_calculateCutoff(paragraph));
    });
  }

  int? _calculateCutoff(RenderParagraph paragraph) {
    final layout = _layoutParagraph(paragraph);
    try {
      final lines = layout.painter.computeLineMetrics();
      var remainingLines = _maxLines;
      for (var index = 0; index < lines.length; index++) {
        final line = lines[index];
        final boundary = layout.painter.getLineBoundary(
          layout.painter.getPositionForOffset(Offset(line.left, line.baseline)),
        );
        final placeholders = layout.placeholders.where(
          (placeholder) =>
              placeholder.offset >= boundary.start &&
              placeholder.offset < boundary.end,
        );
        final lineCount = placeholders.fold(
          1,
          (count, placeholder) => math.max(count, placeholder.lines),
        );
        if (remainingLines < lineCount) {
          final crossing = placeholders.where(
            (placeholder) => placeholder.lines > remainingLines,
          );
          final offset = crossing.isNotEmpty
              ? crossing.first.offset
              : boundary.start;
          return _nonemptyPrefix(paragraph.text, offset);
        }
        remainingLines -= lineCount;
        if (remainingLines == 0 && index < lines.length - 1) {
          return _nonemptyPrefix(paragraph.text, boundary.end);
        }
      }
      return null;
    } finally {
      layout.painter.dispose();
    }
  }

  _ParagraphLayout _layoutParagraph(RenderParagraph paragraph) {
    final dimensions = <PlaceholderDimensions>[];
    final placeholders = <({int offset, int lines})>[];
    var textOffset = 0;
    var placeholder = paragraph.firstChild;
    paragraph.text.visitChildren((span) {
      if (span is TextSpan) {
        textOffset += span.text?.length ?? 0;
      } else if (span is PlaceholderSpan) {
        final box = placeholder;
        if (box != null) {
          dimensions.add(
            PlaceholderDimensions(
              size: box.size,
              alignment: span.alignment,
              baseline: span.baseline,
              baselineOffset: span.alignment == PlaceholderAlignment.baseline
                  ? box.getDryBaseline(box.constraints, span.baseline!)
                  : null,
            ),
          );
          placeholders.add((offset: textOffset, lines: _countLines(box)));
          placeholder = paragraph.childAfter(box);
        }
        textOffset++;
      }
      return true;
    });
    final painter = TextPainter(
      text: paragraph.text,
      textAlign: paragraph.textAlign,
      textDirection: paragraph.textDirection,
      textScaler: paragraph.textScaler,
      locale: paragraph.locale,
      strutStyle: paragraph.strutStyle,
      textWidthBasis: paragraph.textWidthBasis,
      textHeightBehavior: paragraph.textHeightBehavior,
    );
    painter
      ..setPlaceholderDimensions(dimensions)
      ..layout(
        minWidth: paragraph.constraints.minWidth,
        maxWidth: paragraph.constraints.maxWidth,
      );
    return _ParagraphLayout(painter, placeholders);
  }

  int _countLines(RenderObject node) {
    if (node is RenderTable) {
      var count = 0;
      for (var row = 0; row < node.rows; row++) {
        count += node
            .row(row)
            .fold(1, (lines, cell) => math.max(lines, _countLines(cell)));
      }
      return count;
    }
    if (node is RenderParagraph) {
      final layout = _layoutParagraph(node);
      try {
        return layout.painter.computeLineMetrics().fold(0, (count, line) {
          final boundary = layout.painter.getLineBoundary(
            layout.painter.getPositionForOffset(
              Offset(line.left, line.baseline),
            ),
          );
          return count +
              layout.placeholders
                  .where(
                    (placeholder) =>
                        placeholder.offset >= boundary.start &&
                        placeholder.offset < boundary.end,
                  )
                  .fold(
                    1,
                    (lines, placeholder) => math.max(lines, placeholder.lines),
                  );
        });
      } finally {
        layout.painter.dispose();
      }
    }
    var count = 1;
    node.visitChildren((child) {
      count = math.max(count, _countLines(child));
    });
    return count;
  }

  int? _nonemptyPrefix(InlineSpan span, int offset) {
    final text = span.toPlainText(includeSemanticsLabels: false);
    if (offset >= text.length || text.substring(offset).trim().isEmpty) {
      return null;
    }
    final prefix = text.substring(0, offset).trimRight();
    if (prefix.trim().isEmpty) return null;
    return prefix.length;
  }
}

class _ParagraphLayout {
  final TextPainter painter;
  final List<({int offset, int lines})> placeholders;

  const _ParagraphLayout(this.painter, this.placeholders);
}

class MatrixPill extends StatelessWidget {
  final String name;
  final BuildContext outerContext;
  final Uri? avatar;
  final String uri;
  final double? fontSize;
  final Color? color;

  const MatrixPill({
    super.key,
    required this.name,
    required this.outerContext,
    this.avatar,
    required this.uri,
    required this.fontSize,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      splashColor: Colors.transparent,
      onTap: UrlLauncher(outerContext, uri).launchUrl,
      child: Text.rich(
        TextSpan(
          children: [
            WidgetSpan(
              child: Padding(
                padding: const EdgeInsetsDirectional.only(end: 4.0),
                child: Avatar(mxContent: avatar, name: name, size: 16),
              ),
            ),
            TextSpan(
              text: name,
              style: TextStyle(
                color: color,
                decorationColor: color,
                decoration: TextDecoration.underline,
                fontSize: fontSize,
                height: 1.25,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

extension on String {
  Color? get hexToColor {
    var hexCode = this;
    if (hexCode.startsWith('#')) hexCode = hexCode.substring(1);
    if (hexCode.length == 6) hexCode = 'FF$hexCode';
    final colorValue = int.tryParse(hexCode, radix: 16);
    return colorValue == null ? null : Color(colorValue);
  }
}

extension on dom.Element {
  dom.Element get rootElement => parent?.rootElement ?? this;
}
