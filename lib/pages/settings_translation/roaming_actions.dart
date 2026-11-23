// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

const _actionSpacing = 8.0;

/// Keeps testing at the end of the key actions, or on a full-width next row.
class RoamingActions extends MultiChildRenderObjectWidget {
  RoamingActions({
    super.key,
    required List<Widget> keyActions,
    required Widget testAction,
  }) : super(
         children: [
           Wrap(
             spacing: _actionSpacing,
             runSpacing: _actionSpacing,
             children: keyActions,
           ),
           testAction,
         ],
       );

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderRoamingActions(Directionality.of(context));

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderRoamingActions).textDirection = Directionality.of(
      context,
    );
  }
}

class _RoamingActionsParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderRoamingActions extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _RoamingActionsParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _RoamingActionsParentData> {
  _RenderRoamingActions(this._textDirection);

  TextDirection _textDirection;

  set textDirection(TextDirection value) {
    if (_textDirection == value) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _RoamingActionsParentData) {
      child.parentData = _RoamingActionsParentData();
    }
  }

  ({Size size, Offset keyOffset, Offset testOffset}) _layoutActions(
    BoxConstraints constraints,
    Size Function(RenderBox, BoxConstraints) layoutChild,
  ) {
    final keys = firstChild!;
    final test = childAfter(keys)!;
    final keySize = layoutChild(keys, const BoxConstraints());
    final testSize = layoutChild(test, const BoxConstraints());
    final naturalWidth = keySize.width + _actionSpacing + testSize.width;
    final width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.constrainWidth(naturalWidth);
    final leftToRight = _textDirection == TextDirection.ltr;

    if (naturalWidth <= width) {
      final height = constraints.constrainHeight(
        keySize.height > testSize.height ? keySize.height : testSize.height,
      );
      return (
        size: Size(width, height),
        keyOffset: Offset(
          leftToRight ? 0 : width - keySize.width,
          (height - keySize.height) / 2,
        ),
        testOffset: Offset(
          leftToRight ? width - testSize.width : 0,
          (height - testSize.height) / 2,
        ),
      );
    }

    final wrappedKeys = layoutChild(keys, BoxConstraints(maxWidth: width));
    final fullWidthTest = layoutChild(
      test,
      BoxConstraints.tightFor(width: width),
    );
    return (
      size: Size(
        width,
        constraints.constrainHeight(
          wrappedKeys.height + _actionSpacing + fullWidthTest.height,
        ),
      ),
      keyOffset: Offset(leftToRight ? 0 : width - wrappedKeys.width, 0),
      testOffset: Offset(0, wrappedKeys.height + _actionSpacing),
    );
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final geometry = _layoutActions(
      constraints,
      (child, limits) => child.getDryLayout(limits),
    );
    return geometry.size;
  }

  @override
  void performLayout() {
    final geometry = _layoutActions(constraints, (child, limits) {
      child.layout(limits, parentUsesSize: true);
      return child.size;
    });
    size = geometry.size;
    final keys = firstChild!;
    final test = childAfter(keys)!;
    (keys.parentData! as _RoamingActionsParentData).offset = geometry.keyOffset;
    (test.parentData! as _RoamingActionsParentData).offset =
        geometry.testOffset;
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
