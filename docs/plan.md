## Plan: Game Controller Screen + Dashboard Launcher

Add a new Flutter Game Controller screen reachable from the dashboard, with D-pad + Fire controls that send compact boolean state payloads over a persistent WebSocket stream at a fixed tick while held. Keep explicit Start/Stop buttons for game mode control, and retain HTTP only for start/stop or fallback paths.

**Steps**
1. Phase 1 - Create controller screen foundation
2. Add `/Users/rob/development/rgbop/lib/game_controller_screen.dart` with a `StatefulWidget` accepting `panelIp`.
3. Build core state: button press booleans (`up/down/left/right/fire`), status text, optional 16x16 local preview position, `Timer?` for repeat dispatch, and `http.Client` lifecycle ownership.
4. Implement API methods:
5. `startGameMode()` via `POST http://<panelIp>/api/game/start`.
6. `stopGameMode()` via `POST http://<panelIp>/api/game/stop`.
7. `sendInput()` via a persistent WebSocket channel on `ws://<panel-ip>:81/`, sending compact state payload `{seq,ts,buttons}` at a fixed rate while game mode is active and any input changed/held.
8. Apply timeouts and mounted-guarded status updates after async gaps.
9. Phase 2 - Add explicit control flow (depends on Phase 1)
10. Implement Start and Stop buttons in the screen UI.
11. Ensure controller input dispatch is active only when game mode is started.
12. On button press: set matching boolean true, send immediate input, start/restart 50ms periodic timer.
13. On button release/cancel: set boolean false, send immediate input, stop timer when all controls are released.
14. In `dispose()`: cancel timer and close `http.Client`; do not auto-call start/stop because lifecycle is explicit by decision.
15. Phase 3 - Dashboard integration (parallel with final screen polish once screen compiles)
16. Update `/Users/rob/development/rgbop/lib/dashboard_screen.dart` to import the new screen.
17. Insert a new management-style card between existing management sections (after Doodle section, before Location section): title `Game Mode`, subtitle describing D-pad + Fire, and game icon.
18. Card tap behavior:
19. Dismiss keyboard focus.
20. Guard `_panelIp` null/empty and show `SnackBar` if missing.
21. Navigate with `Navigator.push(MaterialPageRoute(...))` passing `panelIp`.
22. Phase 4 - Validation and cleanup (depends on Phases 1-3)
23. Run formatter on modified files.
24. Run analyzer checks focused on changed files.
25. Verify no regressions in dashboard card spacing/order.
26. Manual smoke test on iPhone: open dashboard, launch Game Mode, press Start, hold directions/fire, press Stop, return to dashboard.

**Relevant files**
- `/Users/rob/development/rgbop/lib/game_controller_screen.dart` — new screen implementation for game control UI, timer loop, and API calls.
- `/Users/rob/development/rgbop/lib/dashboard_screen.dart` — add import and launcher card using established dashboard card/navigation patterns.
- `/Users/rob/development/rgbop/analysis_options.yaml` — reference only for lint behavior expectations (`flutter_lints`); no direct changes planned.

**Verification**
1. Static checks:
2. `dart format lib/game_controller_screen.dart lib/dashboard_screen.dart`
3. `flutter analyze lib/game_controller_screen.dart lib/dashboard_screen.dart`
4. Manual behavior checks:
5. Dashboard shows new Game Mode card in intended location and style.
6. Missing panel IP path shows SnackBar and does not navigate.
7. Start button updates status and enables input flow.
8. Holding direction or fire sends repeated state payloads approximately every 50ms.
9. Releasing all controls stops repeat timer.
10. Stop button posts `/api/game/stop` and updates status.

**Decisions**
- Include:
- New screen, dashboard entry point, explicit Start/Stop UX, boolean payload schema, D-pad + Fire only.
- Exclude:
- Additional game buttons, adjustable repeat rate UI, BLE transport changes, backend gameplay logic changes beyond input transport contract.
- Assumptions:
- Firmware supports `POST /api/game/start`, `POST /api/game/stop`, and a persistent WebSocket input endpoint on port 81 for live control state.

**Further Considerations**
1. Optional future enhancement: add a small connection-health indicator based on WebSocket heartbeat latency and last acked sequence.
2. Optional future enhancement: add haptic feedback on button press for iOS if desired.


## Minimal Wire Spec Draft (App <-> ESP32 Game Input)

Purpose: Define the smallest stable transport contract for responsive game controls.

Transport
- Control stream: WebSocket endpoint at ws://<panel-ip>:81/
- Session control: HTTP endpoints POST /api/game/start and POST /api/game/stop
- Do not use repeated HTTP POST /api/game/input for gameplay loop input

Session lifecycle
1. App calls POST /api/game/start
2. ESP32 enters game mode, resets input state to neutral, returns 200 with session info
3. App opens WebSocket ws://<panel-ip>:81/ and starts sending state packets at fixed tick
4. App calls POST /api/game/stop (or socket closes unexpectedly)
5. ESP32 exits game mode, clears input state, resumes normal panel loop

WebSocket packet format (client to ESP32)
- v: protocol version integer (start with 1)
- seq: monotonically increasing uint32 sequence
- ts: client timestamp in ms
- buttons: uint8 bitmask

Button bitmask
- bit 0: up
- bit 1: down
- bit 2: left
- bit 3: right
- bit 4: fire
- bits 5-7 reserved (must be zero)

Recommended payload example semantics
- Neutral state: buttons = 0
- Up + Fire held: buttons = 17 (bit0 + bit4)

Timing
- Send at fixed 30 to 60 Hz
- Default target: 50 Hz
- Send immediately on edge changes; continue fixed-rate while held

Server processing rules
- Treat every packet as full authoritative current state, not an event delta
- If packets queue up, consume newest and drop stale packets
- Input processing must be non-blocking relative to render/game loop

Safety and timeout
- If no valid packet arrives for 250 ms, force neutral input state
- On WebSocket disconnect/error, force neutral input state immediately
- Ignore malformed packets without crashing; keep last valid state or neutral

Optional server ack/heartbeat (recommended)
- ESP32 may send lightweight ack messages with last seq received and server time
- App can use this for connection health UI; gameplay must not depend on ack latency

Error behavior
- POST /api/game/start or /api/game/stop non-200 should include JSON error reason
- If start fails, app must not send control packets

Versioning
- Unknown fields: ignore
- Unknown version v: reject with protocol error and close socket

Out of scope
- Gameplay rules, collision, scoring
- Additional buttons beyond up/down/left/right/fire
- Transport alternatives such as BLE
