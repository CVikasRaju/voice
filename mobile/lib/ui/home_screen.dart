import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/permissions.dart';
import '../core/theme.dart';
import '../ml/languages.dart';
import '../state/battery_monitor.dart';
import '../state/transceiver_controller.dart';
import 'widgets/alarm_overlay.dart';
import 'widgets/pipeline_strip.dart';
import 'widgets/ptt_button.dart';

/// Main transceiver screen — the core UI for iTantra.
///
/// Layout (top to bottom):
/// - App bar with transceiver toggle
/// - Settings bar (sender/receiver language, GPS toggle)
/// - Pipeline strip (live STT → encode → TX → decode → TTS)
/// - PTT button (center)
/// - Packet log (scrollable list)
/// - Emergency alarm overlay (fullscreen, when active)
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _transceiverOn = false;
  bool _permissionsChecked = false;
  final _textController = TextEditingController();
  final _textFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  @override
  void dispose() {
    _textController.dispose();
    _textFocusNode.dispose();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    if (_permissionsChecked) return;
    _permissionsChecked = true;

    final result = await PermissionManager.requestAll();
    if (!result.allGranted && mounted) {
      final denied = result.denied.join(', ');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Permissions needed: $denied'),
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () => _requestPermissions(),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<TransceiverController>(
      builder: (context, ctrl, _) {
        return Stack(
          children: [
            Scaffold(
              appBar: AppBar(
                title: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cell_tower, size: 20, color: iTantraTheme.saffron),
                    SizedBox(width: 8),
                    Text('iTantra'),
                  ],
                ),
                actions: [
                  // Queue indicator
                  if (ctrl.hasQueuedMessages)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: iTantraTheme.saffron.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '📤 ${ctrl.queuedCount}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: iTantraTheme.saffron,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  // Transceiver toggle
                  Switch(
                    value: _transceiverOn,
                    onChanged: (v) {
                      setState(() => _transceiverOn = v);
                    },
                    activeColor: iTantraTheme.saffron,
                  ),
                  const SizedBox(width: 8),
                ],
              ),
              body: Column(
                children: [
                  // ── Settings Bar ──────────────────────────────
                  _SettingsBar(
                    enabled: _transceiverOn,
                    senderLang: ctrl.senderLang,
                    receiverLang: ctrl.receiverLang,
                    gpsEnabled: ctrl.gpsEnabled,
                    onSenderLangChanged: (l) => ctrl.senderLang = l,
                    onReceiverLangChanged: (l) => ctrl.receiverLang = l,
                    onGpsToggled: (v) => ctrl.gpsEnabled = v,
                  ),

                  // ── Pipeline Strip ────────────────────────────
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    child: PipelineStrip(
                      phase: ctrl.phase,
                      interimText: ctrl.interimText,
                      sttMs: ctrl.log.isNotEmpty ? ctrl.log.last.sttMs : null,
                      transferMs:
                          ctrl.log.isNotEmpty ? ctrl.log.last.transferMs : null,
                      ttsMs: ctrl.log.isNotEmpty ? ctrl.log.last.ttsMs : null,
                    ),
                  ),

                  // ── Transcription Preview + Correction ──────────
                  if (ctrl.interimText.isNotEmpty && ctrl.phase == TransceiverPhase.recording)
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: iTantraTheme.surface,
                        border: Border.all(color: iTantraTheme.saffron.withOpacity(0.3)),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.edit_note, size: 18, color: iTantraTheme.saffron),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              ctrl.interimText,
                              style: const TextStyle(
                                fontSize: 14,
                                color: iTantraTheme.textPrimary,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Release to send',
                            style: TextStyle(
                              fontSize: 10,
                              color: iTantraTheme.saffron.withOpacity(0.7),
                            ),
                          ),
                        ],
                      ),
                    ),

                  // ── PTT Button ────────────────────────────────
                  Expanded(
                    flex: 2,
                    child: Center(
                      child: PttButton(
                        isActive: _transceiverOn &&
                            ctrl.phase == TransceiverPhase.idle,
                        onPressed: () => ctrl.startPtt(),
                        onReleased: () => ctrl.stopPtt(),
                      ),
                    ),
                  ),

                  // ── Typed Text Fallback ──────────────────────
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _textController,
                            focusNode: _textFocusNode,
                            enabled: _transceiverOn &&
                                ctrl.phase == TransceiverPhase.idle,
                            decoration: InputDecoration(
                              hintText: 'Type a message…',
                              hintStyle: const TextStyle(
                                fontSize: 13,
                                color: iTantraTheme.textMuted,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(
                                    color: iTantraTheme.border),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(
                                    color: iTantraTheme.border),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(
                                    color: iTantraTheme.saffron),
                              ),
                              filled: true,
                              fillColor: iTantraTheme.surface,
                              suffixIcon: IconButton(
                                icon: const Icon(Icons.send,
                                    size: 18, color: iTantraTheme.saffron),
                                onPressed: _transceiverOn &&
                                        ctrl.phase == TransceiverPhase.idle &&
                                        _textController.text.trim().isNotEmpty
                                    ? () {
                                        ctrl.sendTypedText(_textController.text);
                                        _textController.clear();
                                        _textFocusNode.unfocus();
                                      }
                                    : null,
                              ),
                            ),
                            style: const TextStyle(
                              fontSize: 13,
                              color: iTantraTheme.textPrimary,
                            ),
                            onSubmitted: (v) {
                              if (v.trim().isNotEmpty) {
                                ctrl.sendTypedText(v);
                                _textController.clear();
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  // ── Packet Log ────────────────────────────────
                  Expanded(
                    flex: 3,
                    child: _PacketLog(log: ctrl.log),
                  ),
                ],
              ),
            ),

            // ── Emergency Alarm Overlay ────────────────────────
            if (ctrl.alarmActive)
              const AlarmOverlay(),
          ],
        );
      },
    );
  }
}

/// ── Settings Bar ───────────────────────────────────────────────

class _SettingsBar extends StatelessWidget {
  final bool enabled;
  final Lang senderLang;
  final Lang receiverLang;
  final bool gpsEnabled;
  final ValueChanged<Lang> onSenderLangChanged;
  final ValueChanged<Lang> onReceiverLangChanged;
  final ValueChanged<bool> onGpsToggled;

  const _SettingsBar({
    required this.enabled,
    required this.senderLang,
    required this.receiverLang,
    required this.gpsEnabled,
    required this.onSenderLangChanged,
    required this.onReceiverLangChanged,
    required this.onGpsToggled,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: iTantraTheme.surface,
        border: Border(bottom: BorderSide(color: iTantraTheme.border)),
      ),
      child: Row(
        children: [
          // Sender language
          Expanded(
            child: _LangSelector(
              label: 'Speak',
              value: senderLang,
              enabled: enabled,
              onChanged: onSenderLangChanged,
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Icon(Icons.arrow_forward, size: 16, color: iTantraTheme.textMuted),
          ),
          // Receiver language
          Expanded(
            child: _LangSelector(
              label: 'Listen',
              value: receiverLang,
              enabled: enabled,
              onChanged: onReceiverLangChanged,
            ),
          ),
          const SizedBox(width: 12),
          // GPS toggle
          GestureDetector(
            onTap: enabled ? () => onGpsToggled(!gpsEnabled) : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.location_on,
                  size: 18,
                  color: gpsEnabled
                      ? iTantraTheme.saffron
                      : iTantraTheme.textMuted,
                ),
                const SizedBox(width: 4),
                Text(
                  'GPS',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: gpsEnabled
                        ? iTantraTheme.saffron
                        : iTantraTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LangSelector extends StatelessWidget {
  final String label;
  final Lang value;
  final bool enabled;
  final ValueChanged<Lang> onChanged;

  const _LangSelector({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: iTantraTheme.textMuted,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 2),
        DropdownButton<Lang>(
          value: value,
          isDense: true,
          isExpanded: true,
          underline: const SizedBox(),
          dropdownColor: iTantraTheme.surfaceLight,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: iTantraTheme.textPrimary,
          ),
          items: kLanguages
              .map((l) => DropdownMenuItem(value: l, child: Text(l.name)))
              .toList(),
          onChanged: enabled ? (l) { if (l != null) onChanged(l); } : null,
        ),
      ],
    );
  }
}

/// ── Packet Log ─────────────────────────────────────────────────

class _PacketLog extends StatelessWidget {
  final List<LogEntry> log;
  const _PacketLog({required this.log});

  @override
  Widget build(BuildContext context) {
    if (log.isEmpty) {
      return const Center(
        child: Text(
          'No packets yet\nHold the PTT button to send',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            color: iTantraTheme.textMuted,
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: log.length,
      reverse: true, // newest at top
      itemBuilder: (context, index) {
        final entry = log[log.length - 1 - index];
        return _LogEntryCard(entry: entry);
      },
    );
  }
}

class _LogEntryCard extends StatelessWidget {
  final LogEntry entry;
  const _LogEntryCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final isEmergency = entry.priority == Priority.emergency;
    final isError = entry.error != null;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isError
            ? iTantraTheme.danger.withOpacity(0.1)
            : isEmergency
                ? iTantraTheme.danger.withOpacity(0.08)
                : iTantraTheme.surface,
        border: Border.all(
          color: isError
              ? iTantraTheme.danger.withOpacity(0.4)
              : isEmergency
                  ? iTantraTheme.danger.withOpacity(0.3)
                  : iTantraTheme.border,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            children: [
              Icon(
                entry.isSent ? Icons.arrow_upward : Icons.arrow_downward,
                size: 14,
                color: entry.isSent
                    ? iTantraTheme.saffron
                    : iTantraTheme.success,
              ),
              const SizedBox(width: 4),
              Text(
                entry.isSent ? 'SENT' : 'RECEIVED',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: entry.isSent
                      ? iTantraTheme.saffron
                      : iTantraTheme.success,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: isEmergency
                      ? iTantraTheme.danger.withOpacity(0.2)
                      : iTantraTheme.surfaceLight,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  entry.langName,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: isEmergency
                        ? iTantraTheme.danger
                        : iTantraTheme.textSecondary,
                  ),
                ),
              ),
              if (isEmergency) ...[
                const SizedBox(width: 4),
                const Icon(Icons.warning_amber_rounded,
                    size: 12, color: iTantraTheme.danger),
              ],
              const Spacer(),
              Text(
                _formatTime(entry.timestamp),
                style: const TextStyle(
                  fontSize: 10,
                  color: iTantraTheme.textMuted,
                ),
              ),
            ],
          ),

          // Text
          const SizedBox(height: 6),
          Text(
            entry.text,
            style: TextStyle(
              fontSize: 13,
              color: isError
                  ? iTantraTheme.danger
                  : iTantraTheme.textPrimary,
            ),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),

          // Timing row
          if (entry.sttMs != null ||
              entry.transferMs != null ||
              entry.ttsMs != null ||
              entry.e2eMs != null) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                if (entry.sttMs != null)
                  _Timing(label: 'STT', ms: entry.sttMs!),
                if (entry.transferMs != null)
                  _Timing(label: 'TX', ms: entry.transferMs!),
                if (entry.ttsMs != null)
                  _Timing(label: 'TTS', ms: entry.ttsMs!),
                if (entry.e2eMs != null)
                  _Timing(label: 'E2E', ms: entry.e2eMs!, bold: true),
              ],
            ),
          ],

          // GPS coordinates
          if (entry.lat != null && entry.lon != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.location_on,
                    size: 11, color: iTantraTheme.textMuted),
                const SizedBox(width: 3),
                Text(
                  '${entry.lat!.toStringAsFixed(4)}, ${entry.lon!.toStringAsFixed(4)}',
                  style: const TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
                    color: iTantraTheme.textMuted,
                  ),
                ),
              ],
            ),
          ],

          // Error
          if (isError) ...[
            const SizedBox(height: 4),
            Text(
              entry.error!,
              style: const TextStyle(
                fontSize: 10,
                color: iTantraTheme.danger,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
  }
}

class _Timing extends StatelessWidget {
  final String label;
  final int ms;
  final bool bold;
  const _Timing({required this.label, required this.ms, this.bold = false});

  @override
  Widget build(BuildContext context) {
    return Text(
      '$label ${ms}ms',
      style: TextStyle(
        fontSize: 10,
        fontFamily: 'monospace',
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
        color: iTantraTheme.textSecondary,
      ),
    );
  }
}
