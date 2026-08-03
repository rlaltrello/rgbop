import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:http/http.dart' as http;

class GameControllerScreen extends StatefulWidget {
  final String panelIp;

  const GameControllerScreen({super.key, required this.panelIp});

  @override
  State<GameControllerScreen> createState() => _GameControllerScreenState();
}

class _GameControllerScreenState extends State<GameControllerScreen> {
  static const Duration _socketConnectTimeout = Duration(milliseconds: 3000);
  static const double _joystickSize = 170;
  static const double _joystickDeadZone = 16;
  static const double _joystickKnobTravel = 46;
  static const Duration _sendTickInterval = Duration(milliseconds: 20);
  static const Duration _heartbeatInterval = Duration(milliseconds: 70);

  WebSocket? _webSocket;
  StreamSubscription<dynamic>? _socketSubscription;
  Timer? _repeatTimer;

  // Selected game parameter
  String _selectedGame = 'shooter'; // Default selection

  bool _isGameModeActive = false;
  bool _isConnecting = false;
  bool _isStopping = false;
  bool _isSocketConnecting = false;

  bool _upPressed = false;
  bool _downPressed = false;
  bool _leftPressed = false;
  bool _rightPressed = false;
  bool _aPressed = false;
  bool _bPressed = false;

  int _sequence = 0;
  int _lifecycleEpoch = 0;
  int _socketReconnectAttempt = 0;
  int _lastButtonsSent = -1;
  DateTime? _lastFrameSentAt;

  String _statusText = 'Select a game and tap Start.';
  Offset _joystickVisualOffset = Offset.zero;
  int? _joystickPointerId;
  bool _joystickRepaintQueued = false;

  @override
  void dispose() {
    _repeatTimer?.cancel();
    _socketSubscription?.cancel();
    _hardTeardownLocal();
    unawaited(_sendStopRequestRemote());
    super.dispose();
  }

  void _hardTeardownLocal() {
    _repeatTimer?.cancel();
    _repeatTimer = null;

    _socketSubscription?.cancel();
    _socketSubscription = null;

    final socket = _webSocket;
    _webSocket = null;

    _isGameModeActive = false;
    _isSocketConnecting = false;
    _isConnecting = false;
    _socketReconnectAttempt = 0;
    _lastButtonsSent = -1;
    _lastFrameSentAt = null;

    if (socket != null) {
      try {
        socket.close(WebSocketStatus.normalClosure, 'Teardown');
      } catch (_) {}
    }

    if (mounted) {
      setState(() {
        _upPressed = false;
        _downPressed = false;
        _leftPressed = false;
        _rightPressed = false;
        _aPressed = false;
        _bPressed = false;
        _joystickVisualOffset = Offset.zero;
        _joystickPointerId = null;
      });
    }
  }

  Future<void> _startGameMode() async {
    if (_isConnecting || _isGameModeActive || _isStopping) return;

    final currentEpoch = ++_lifecycleEpoch;

    setState(() {
      _isConnecting = true;
      _statusText = 'Starting ${_selectedGame.toUpperCase()}...';
    });

    _hardTeardownLocal();

    // STEP 1: Send Start HTTP Request with selected game payload
    bool startSuccessful = false;
    final client = http.Client();
    try {
      final response = await client
          .post(
            Uri.parse('http://${widget.panelIp}/api/game/start'),
            headers: const {
              'Content-Type': 'application/json',
              'Connection': 'close',
            },
            body: jsonEncode({'game': _selectedGame}),
          )
          .timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        startSuccessful = true;
      }
    } catch (e) {
      debugPrint('Start HTTP Error: $e');
    } finally {
      client.close();
    }

    if (!mounted || currentEpoch != _lifecycleEpoch) return;

    if (!startSuccessful) {
      setState(() {
        _isConnecting = false;
        _statusText = 'Failed to start game mode on panel.';
      });
      return;
    }

    // STEP 2: Delay briefly to let ESP32 cycle loop() once and open port 81
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (!mounted || currentEpoch != _lifecycleEpoch) return;

    setState(() {
      _isGameModeActive = true;
      _isConnecting = false;
      _statusText = 'Game Mode active. Connecting socket...';
    });

    _startRepeatTimer();
    unawaited(_connectInputSocket(currentEpoch));
  }

  Future<void> _connectInputSocket(int sessionEpoch) async {
    if (!_isGameModeActive || _isStopping || _isSocketConnecting) return;
    if (_webSocket != null && _webSocket!.readyState == WebSocket.open) return;

    _isSocketConnecting = true;
    var attempt = 0;

    try {
      while (mounted &&
          _isGameModeActive &&
          !_isStopping &&
          _webSocket == null &&
          sessionEpoch == _lifecycleEpoch) {
        attempt++;
        _socketReconnectAttempt = attempt;

        if (mounted && (attempt == 1 || attempt % 3 == 0)) {
          setState(() {
            _statusText = 'Connecting WebSocket (Attempt $attempt)...';
          });
        }

        if (attempt > 5) {
          setState(() {
            _isGameModeActive = false;
            _statusText = 'Game Mode exited by panel.';
          });
          _hardTeardownLocal();
          return;
        }

        try {
          final socket = await WebSocket.connect(
            'ws://${widget.panelIp}:81/',
          ).timeout(_socketConnectTimeout);
          socket.pingInterval = null;

          if (!mounted ||
              !_isGameModeActive ||
              _isStopping ||
              sessionEpoch != _lifecycleEpoch) {
            await socket.close();
            return;
          }

          await _socketSubscription?.cancel();
          _socketSubscription = socket.listen(
            (_) {},
            onError: (_) => _handleSocketClosed(socket),
            onDone: () => _handleSocketClosed(socket),
            cancelOnError: true,
          );

          setState(() {
            _webSocket = socket;
            _socketReconnectAttempt = 0;
            _statusText = 'Connected. Playing ${_selectedGame.toUpperCase()}!';
          });

          _sendInputFrame(force: true);
          return;
        } catch (e) {
          if (!mounted ||
              !_isGameModeActive ||
              _isStopping ||
              sessionEpoch != _lifecycleEpoch) {
            return;
          }
          final backoff = math.min(500, 100 + (attempt * 50));
          await Future<void>.delayed(Duration(milliseconds: backoff));
        }
      }
    } finally {
      _isSocketConnecting = false;
    }
  }

  void _handleSocketClosed(WebSocket socket) {
    if (!mounted || !_isGameModeActive || _isStopping) return;
    if (!identical(_webSocket, socket)) return;

    _lastButtonsSent = -1;
    _lastFrameSentAt = null;
    _webSocket = null;

    if (mounted) {
      setState(() {
        _statusText = 'Socket lost. Stabilizing connection...';
      });
    }

    final reconnectEpoch = _lifecycleEpoch;
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 1000), () {
        if (mounted &&
            _isGameModeActive &&
            !_isStopping &&
            _webSocket == null &&
            reconnectEpoch == _lifecycleEpoch) {
          unawaited(_connectInputSocket(reconnectEpoch));
        }
      }),
    );
  }

  Future<void> _stopGameMode() async {
    if (_isStopping) return;

    ++_lifecycleEpoch;

    setState(() {
      _isStopping = true;
      _statusText = 'Stopping game mode...';
    });

    _hardTeardownLocal();
    await _sendStopRequestRemote();

    if (mounted) {
      setState(() {
        _isStopping = false;
        _statusText = 'Game mode stopped.';
      });
    }
  }

  Future<void> _sendStopRequestRemote() async {
    final client = http.Client();
    try {
      await client.post(
        Uri.parse('http://${widget.panelIp}/api/game/stop'),
        headers: const {
          'Content-Type': 'application/json',
          'Connection': 'close',
        },
      ).timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('Stop request error: $e');
    } finally {
      client.close();
    }
  }

  void _sendInputFrame({bool force = false}) {
    final socket = _webSocket;
    if (!_isGameModeActive ||
        _isStopping ||
        socket == null ||
        socket.readyState != WebSocket.open) {
      return;
    }

    final buttons = _buildButtonMask() & 0xFF;
    final now = DateTime.now();
    final dueToHeartbeat =
        _lastFrameSentAt == null ||
        now.difference(_lastFrameSentAt!) >= _heartbeatInterval;
    final stateChanged = buttons != _lastButtonsSent;

    if (!force && !stateChanged && !dueToHeartbeat) return;

    final seq = _sequence & 0xFF;
    _sequence = (_sequence + 1) & 0xFF;

    try {
      socket.add(Uint8List.fromList([seq, buttons]));
      _lastButtonsSent = buttons;
      _lastFrameSentAt = now;
    } catch (e) {
      _handleSocketClosed(socket);
    }
  }

  int _buildButtonMask() {
    var mask = 0;
    if (_upPressed) mask |= 1 << 0;
    if (_downPressed) mask |= 1 << 1;
    if (_leftPressed) mask |= 1 << 2;
    if (_rightPressed) mask |= 1 << 3;
    if (_aPressed) mask |= 1 << 4;
    if (_bPressed) mask |= 1 << 5;
    return mask;
  }

  void _startRepeatTimer() {
    _repeatTimer?.cancel();
    _repeatTimer = Timer.periodic(_sendTickInterval, (_) {
      if (_isGameModeActive && !_isStopping && mounted) {
        _sendInputFrame();
      }
    });
  }

  void _queueJoystickRepaint() {
    if (_joystickRepaintQueued || !mounted) return;
    _joystickRepaintQueued = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _joystickRepaintQueued = false;
      if (mounted) setState(() {});
    });
  }

  void _setActionButtonState(String button, bool pressed) {
    if (!_isGameModeActive || _isStopping) return;

    var changed = false;
    if (button == 'A') {
      changed = _aPressed != pressed;
      _aPressed = pressed;
    } else if (button == 'B') {
      changed = _bPressed != pressed;
      _bPressed = pressed;
    }

    if (changed) {
      _sendInputFrame(force: true);
      _queueJoystickRepaint();
    }
  }

  void _setDpadButtonState(String direction, bool pressed) {
    if (!_isGameModeActive || _isStopping) return;

    var changed = false;
    if (direction == 'UP') {
      changed = _upPressed != pressed;
      _upPressed = pressed;
    } else if (direction == 'DOWN') {
      changed = _downPressed != pressed;
      _downPressed = pressed;
    } else if (direction == 'LEFT') {
      changed = _leftPressed != pressed;
      _leftPressed = pressed;
    } else if (direction == 'RIGHT') {
      changed = _rightPressed != pressed;
      _rightPressed = pressed;
    }

    if (changed) {
      _sendInputFrame(force: true);
      _queueJoystickRepaint();
    }
  }

  void _updateJoystickFromLocalPosition(Offset localPosition) {
    if (!_isGameModeActive || _isStopping) return;

    const center = Offset(_joystickSize / 2, _joystickSize / 2);
    var delta = localPosition - center;
    final distance = delta.distance;

    if (distance > _joystickKnobTravel && distance > 0) {
      delta = delta / distance * _joystickKnobTravel;
    }

    var up = false, down = false, left = false, right = false;

    if (distance >= _joystickDeadZone) {
      final angle = math.atan2(delta.dy, delta.dx);
      final sector = ((angle + math.pi) / (math.pi / 4)).round() % 8;
      switch (sector) {
        case 0:
          left = true;
          break;
        case 1:
          up = true;
          left = true;
          break;
        case 2:
          up = true;
          break;
        case 3:
          up = true;
          right = true;
          break;
        case 4:
          right = true;
          break;
        case 5:
          down = true;
          right = true;
          break;
        case 6:
          down = true;
          break;
        case 7:
          down = true;
          left = true;
          break;
      }
    } else {
      delta = Offset.zero;
    }

    final directionChanged =
        up != _upPressed ||
        down != _downPressed ||
        left != _leftPressed ||
        right != _rightPressed;
    _joystickVisualOffset = delta;
    _upPressed = up;
    _downPressed = down;
    _leftPressed = left;
    _rightPressed = right;

    if (directionChanged) _sendInputFrame(force: true);
    _queueJoystickRepaint();
  }

  void _releaseJoystick() {
    if (!_isGameModeActive || _isStopping) return;

    final directionChanged =
        _upPressed || _downPressed || _leftPressed || _rightPressed;
    _upPressed = false;
    _downPressed = false;
    _leftPressed = false;
    _rightPressed = false;
    _joystickVisualOffset = Offset.zero;

    if (directionChanged) _sendInputFrame(force: true);
    _queueJoystickRepaint();
  }

  Widget _buildJoystick() {
    return SizedBox(
      width: _joystickSize,
      height: _joystickSize,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) {
          if (_joystickPointerId == null) {
            _joystickPointerId = e.pointer;
            _updateJoystickFromLocalPosition(e.localPosition);
          }
        },
        onPointerMove: (e) {
          if (_joystickPointerId == e.pointer) {
            _updateJoystickFromLocalPosition(e.localPosition);
          }
        },
        onPointerUp: (e) {
          if (_joystickPointerId == e.pointer) {
            _joystickPointerId = null;
            _releaseJoystick();
          }
        },
        onPointerCancel: (e) {
          if (_joystickPointerId == e.pointer) {
            _joystickPointerId = null;
            _releaseJoystick();
          }
        },
        child: Stack(
          alignment: Alignment.center,
          children: [
            Image.asset(
              'assets/images/Joystick.png',
              width: _joystickSize,
              height: _joystickSize,
              fit: BoxFit.contain,
            ),
            Transform.translate(
              offset: _joystickVisualOffset,
              child: Image.asset(
                'assets/images/Knob.png',
                width: 86,
                height: 86,
                fit: BoxFit.contain,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDpadButton({
    required IconData icon,
    required String direction,
    required bool pressed,
  }) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => _setDpadButtonState(direction, true),
      onPointerUp: (_) => _setDpadButtonState(direction, false),
      onPointerCancel: (_) => _setDpadButtonState(direction, false),
      child: Container(
        width: 65,
        height: 65,
        decoration: BoxDecoration(
          color: pressed
              ? Colors.blueGrey.withValues(alpha: 0.95)
              : Colors.blueGrey.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.8),
            width: 2,
          ),
        ),
        alignment: Alignment.center,
        child: Icon(icon, color: Colors.white, size: 28),
      ),
    );
  }

  Widget _buildDpadController() {
    return SizedBox(
      width: _joystickSize+25, // bit more space for buttons
      height: _joystickSize+25,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Up
          Positioned(
            top: 0,
            child: _buildDpadButton(
              icon: Icons.arrow_drop_up,
              direction: 'UP',
              pressed: _upPressed,
            ),
          ),
          // Down
          Positioned(
            bottom: 0,
            child: _buildDpadButton(
              icon: Icons.arrow_drop_down,
              direction: 'DOWN',
              pressed: _downPressed,
            ),
          ),
          // Left
          Positioned(
            left: 0,
            child: _buildDpadButton(
              icon: Icons.arrow_left,
              direction: 'LEFT',
              pressed: _leftPressed,
            ),
          ),
          // Right
          Positioned(
            right: 0,
            child: _buildDpadButton(
              icon: Icons.arrow_right,
              direction: 'RIGHT',
              pressed: _rightPressed,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required String label,
    required bool pressed,
    required Color color,
  }) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => _setActionButtonState(label, true),
      onPointerUp: (_) => _setActionButtonState(label, false),
      onPointerCancel: (_) => _setActionButtonState(label, false),
      child: Container(
        width: 92,
        height: 92,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: pressed
              ? color.withValues(alpha: 0.95)
              : color.withValues(alpha: 0.65),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.8),
            width: 2,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: 28,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool socketOpen =
        _webSocket != null && _webSocket!.readyState == WebSocket.open;

    return Scaffold(
      appBar: AppBar(title: const Text('Game Controller')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              color: const Color(0xFF1E1E1E),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _statusText,
                      style: const TextStyle(
                        color: Colors.blueAccent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(
                          Icons.circle,
                          size: 10,
                          color: !_isGameModeActive
                              ? Colors.white54
                              : (socketOpen
                                  ? Colors.greenAccent
                                  : Colors.orangeAccent),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          !_isGameModeActive
                              ? 'Idle'
                              : (socketOpen
                                  ? 'Connected'
                                  : 'Connecting ($_socketReconnectAttempt)'),
                          style: TextStyle(
                            color: !_isGameModeActive
                                ? Colors.white54
                                : (socketOpen
                                    ? Colors.greenAccent
                                    : Colors.orangeAccent),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Panel: ${widget.panelIp}',
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            
            // --- GAME SELECTION SELECTOR ---
            SegmentedButton<String>(
              segments: const [
                ButtonSegment<String>(
                  value: 'shooter',
                  label: Text('Shooter'),
                  icon: Icon(Icons.rocket_launch),
                ),
                ButtonSegment<String>(
                  value: 'dungeon',
                  label: Text('Dungeon 3D'),
                  icon: Icon(Icons.castle),
                ),
              ],
              selected: {_selectedGame},
              onSelectionChanged: (_isConnecting || _isGameModeActive || _isStopping)
                  ? null
                  : (newSelection) {
                      setState(() {
                        _selectedGame = newSelection.first;
                      });
                    },
            ),
            const SizedBox(height: 16),

            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: (_isConnecting || _isStopping || _isGameModeActive)
                        ? null
                        : _startGameMode,
                    icon: _isConnecting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow),
                    label: const Text('Start'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: (_isGameModeActive && !_isStopping)
                        ? _stopGameMode
                        : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            AbsorbPointer(
              absorbing: !_isGameModeActive || !socketOpen,
              child: Opacity(
                opacity: (_isGameModeActive && socketOpen) ? 1.0 : 0.4,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // Dynamic Controller Switch: D-pad for Dungeon 3D, Joystick for Shooter
                    _selectedGame == 'dungeon'
                        ? _buildDpadController()
                        : _buildJoystick(),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildActionButton(
                          label: 'A',
                          pressed: _aPressed,
                          color: Colors.redAccent,
                        ),
                        const SizedBox(height: 14),
                        _buildActionButton(
                          label: 'B',
                          pressed: _bPressed,
                          color: Colors.blueAccent,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}