// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/image_send_options.dart';
import 'package:fluffychat/utils/image_send_preparation.dart';
import 'package:fluffychat/widgets/settings_switch_list_tile.dart';
import 'package:material_ui/material_ui.dart';

class SettingsImageSending extends StatefulWidget {
  final ImageSendPreparation? preparation;

  const SettingsImageSending({super.key, this.preparation});

  @override
  State<SettingsImageSending> createState() => _SettingsImageSendingState();
}

class _SettingsImageSendingState extends State<SettingsImageSending> {
  late ImageSendOptions _options;
  late final TextEditingController _dimension;
  final _dimensionFocus = FocusNode();
  Set<ImageOutputFormat> _formats = ImageSendOptions.basicFormats;
  bool _invalidDimension = false;

  @override
  void initState() {
    super.initState();
    _options = ImageSendOptions.fromSettings();
    _dimension = TextEditingController(text: _options.maxDimension.toString());
    _dimensionFocus.addListener(_onDimensionFocusChanged);
    (widget.preparation ?? ImageSendPreparation.instance)
        .supportedFormats()
        .then((formats) {
          if (mounted) setState(() => _formats = formats);
        });
  }

  void _onDimensionFocusChanged() {
    if (!_dimensionFocus.hasFocus) _saveDimension();
  }

  Future<void> _saveDimension() async {
    final text = _dimension.text.trim();
    final value = RegExp(r'^[0-9]+$').hasMatch(text)
        ? int.tryParse(text)
        : null;
    final invalid = value == null || value <= 0;
    if (mounted) setState(() => _invalidDimension = invalid);
    if (!invalid) await AppSettings.imageMaxDimension.setItem(value);
  }

  @override
  void dispose() {
    _dimensionFocus.removeListener(_onDimensionFocusChanged);
    _dimensionFocus.dispose();
    _dimension.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final preferred = _formats.contains(_options.preferredFormat)
        ? _options.preferredFormat
        : ImageOutputFormat.webp;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: Text(
            l10n.compressImagesWhenSending,
            style: TextStyle(
              color: theme.colorScheme.secondary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        SettingsSwitchListTile.adaptive(
          title: l10n.compressImagesByDefault,
          setting: AppSettings.compressImagesByDefault,
          defaultValue: AppSettings.compressImagesByDefault.defaultValue,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: DropdownButtonFormField<ImageFormatPolicy>(
            initialValue: _options.formatPolicy,
            isExpanded: true,
            decoration: InputDecoration(labelText: l10n.imageFormatPolicy),
            items: [
              DropdownMenuItem(
                value: ImageFormatPolicy.preserve,
                child: Text(l10n.preserveImageFormat),
              ),
              DropdownMenuItem(
                value: ImageFormatPolicy.legacyOnly,
                child: Text(l10n.convertLegacyImageFormats),
              ),
              DropdownMenuItem(
                value: ImageFormatPolicy.preferred,
                child: Text(l10n.alwaysUsePreferredImageFormat),
              ),
            ],
            onChanged: (value) async {
              if (value == null) return;
              await AppSettings.imageFormatPolicy.setItem(value.name);
              if (mounted) {
                setState(() => _options = ImageSendOptions.fromSettings());
              }
            },
          ),
        ),
        if (_options.formatPolicy != ImageFormatPolicy.preserve)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: DropdownButtonFormField<ImageOutputFormat>(
              key: ValueKey(preferred),
              initialValue: preferred,
              isExpanded: true,
              decoration: InputDecoration(labelText: l10n.preferredImageFormat),
              items: [
                for (final format in ImageOutputFormat.values)
                  if (_formats.contains(format))
                    DropdownMenuItem(value: format, child: Text(format.label)),
              ],
              onChanged: (value) async {
                if (value == null) return;
                await AppSettings.preferredImageFormat.setItem(value.name);
                if (mounted) {
                  setState(() => _options = ImageSendOptions.fromSettings());
                }
              },
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: TextField(
            controller: _dimension,
            focusNode: _dimensionFocus,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: l10n.imageMaxDimension,
              helperText: l10n.imageMaxDimensionDescription,
              helperMaxLines: 2,
              suffixText: l10n.imageDimensionPixels,
              errorText: _invalidDimension ? l10n.invalidInput : null,
            ),
            onSubmitted: (_) => _saveDimension(),
          ),
        ),
      ],
    );
  }
}
