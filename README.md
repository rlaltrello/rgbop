Here is the updated Product Requirements Document, fully branded for **RGBop** so you can stash it in your project archives.

# Product Requirements Document (PRD)

## Project RGBop: ESP32-S3 Matrix Companion System

---

## 1. Executive Summary & Objectives

RGBop (RGB Operator) is a cross-platform mobile application built using Flutter, designed specifically to configure, manage, and provision a custom 64x64 HUB75 LED Matrix display powered by an ESP32-S3 (N16R8).

The primary objective is to transform a raw hardware project into a consumer-grade appliance. This system allows users (specifically family members) to easily connect and manage their physical display panels without requiring technical knowledge, command-line configuration, or manual firmware flashing.

### Primary Goals

* **Zero-Config Provisioning:** Seamlessly pass local Wi-Fi credentials from a mobile device to a headless ESP32-S3 panel.
* **Remote Configuration:** Update global system parameters such as geographic location for API consumption (e.g., weather, time zones, ISS tracking).
* **Dynamic Layout Management:** Enable real-time manipulation of active display components (widgets), including visibility toggles and display sequencing.
* **Asset Management:** Provide a wireless interface to upload, list, and delete custom graphics (GIFs) stored locally on the microcontroller's filesystem.

---

## 2. Hardware & Architecture Baseline

The RGBop app targets a highly capable hardware profile. The system requirements and configuration boundaries must respect these exact specifications:

* **Microcontroller:** ESP32-S3 (N16R8) featuring 16MB Flash and 8MB PSRAM.
* **Local Storage:** Custom partitioned LittleFS with exactly 9,437,184 bytes (~9.4MB) of total capacity (~7.7MB available for user assets).
* **Display Buffer Architecture:** Double-buffered frame generation executing within the 8MB PSRAM to prevent panel flicker during synchronous network operations.
* **Local File System Interaction:** Custom configurations and raw `.gif` assets persist dynamically within the `/` root directory of LittleFS via `<ArduinoJson.h>` and native file streaming handlers.

---

## 3. Functional Requirements

### Module 1: Device Provisioning & Network Onboarding

* **FR-1.1:** The mobile app must establish an out-of-band communication channel with the unprovisioned RGBop panel. BLE (Bluetooth Low Energy) is the preferred protocol to preserve native mobile system Wi-Fi execution loops and provide a premium "smart home" setup experience.
* **FR-1.2:** The app must present a localized Wi-Fi scanning interface or text inputs capturing `SSID` and `Password`.
* **FR-1.3:** Upon transmission of credentials, the app must listen for a confirmation packet from the hardware indicating a successful network handshake (`WIFI_CONNECTED`).
* **FR-1.4:** The app must handle fallback logic if connection fails, returning the device to provisioning mode without clearing pre-existing configuration files.

### Module 2: Local Discovery (mDNS)

* **FR-2.1:** Once both devices share a network layer, the app must resolve the microcontroller's IP address dynamically using Multicast DNS (e.g., `rgbop.local`).
* **FR-2.2:** The app must seamlessly handle IP address updates caused by DHCP lease renewals without requiring user intervention.

### Module 3: Remote System Configuration

* **FR-3.1:** The app must provide an input mechanism for location tracking (e.g., Latitude/Longitude coordinates or Zip Code) to drive remote API components on the display.
* **FR-3.2:** Changes saved in the app must fire an asynchronous HTTP `POST` request to the device endpoint `/api/config`.

### Module 4: Widget Sequencing & Layout Control

* **FR-4.1:** The app must fetch the current execution array of display modules (e.g., `MarioClock`, `WeatherModule`, `DateProgress`) via a `GET` request to `/api/widgets`.
* **FR-4.2:** The UI must display these modules in a draggable list view allowing the user to modify execution hierarchy and order.
* **FR-4.3:** Each widget must have a toggle switch to flag its runtime execution state (`enabled: true/false`).
* **FR-4.4:** Changes to order or state must immediately dispatch an organized JSON structure back to the device to modify the display queue.

### Module 5: LittleFS Remote File Manager

* **FR-5.1:** The app must parse a list of files matching `.gif` structures from `/api/gifs`.
* **FR-5.2:** The UI must list files alongside their respective sizes, displaying total and available storage space calculated from the 9.4MB LittleFS boundary.
* **FR-5.3:** The user must be able to select an asset from their mobile camera roll or file picker and stream it as `multipart/form-data` directly to `/api/upload`.
* **FR-5.4:** The app must include a deletion confirmation warning before executing a `DELETE` request to `/api/delete?file=filename.gif`.

---

## 4. Technical Stack & Implementation Architecture

### Mobile Client (Flutter)

* **State Management:** Riverpod or Provider for clean dependency injection and reactive UI states.
* **Network Layer:** `dio` or `http` for custom timeout mappings, progress tracking during asset uploads, and handling multipart requests.
* **Connectivity Packages:** `flutter_blue_plus` for low-level BLE abstraction; `multicast_dns` for zero-configuration mDNS lookups.
* **UI Components:** `ReorderableListView` for drag-and-drop widget prioritization loops.

### Firmware Server (ESP32-S3 C++)

* **Networking Engine:** `ESPAsyncWebServer` combined with `AsyncTCP` to prevent blockages on the core display loop during bulk transfers.
* **JSON Serialization:** `ArduinoJson` for parsing layout matrices and application states.
* **Storage Access:** `LittleFS` library managing persistent records on internal flash memories.

---

## 5. Phased Release Plan

| Phase | Milestone Name | Core Objectives | App Deliverables | Firmware Deliverables |
| --- | --- | --- | --- | --- |
| **Phase 1** | **Provisioning** | Bridge the gap between phone and hardware. | BLE Setup screen, SSID/Pass input forms, validation loops. | BLE service advertisement, Wi-Fi initialization handlers, credential storage. |
| **Phase 2** | **Discovery** | Locate the device over local networks automatically. | mDNS scanning sequence on app boot, connection status UI. | mDNS daemon broadcasting `rgbop.local`. |
| **Phase 3** | **State Syncing** | Read and write JSON states for configurations. | Main settings panel, location input, API communication logic. | `/api/config` REST endpoints, payload parsing routines. |
| **Phase 4** | **Widget Management** | Modify what displays on the panel dynamically. | Draggable list view interfaces with visibility switches. | `/api/widgets` handler, runtime display queue mapping mutations. |
| **Phase 5** | **Asset Server** | Remotely manage physical GIF media. | File manager dashboard, capacity indicators, native file pickers. | Async upload chunk processors, deletion hooks in LittleFS. |

---

## 6. Constraints & Edge Cases

> ### Critical System Warnings
> 
> 
> * **SPI Flash Write Delays:** Heavy writing activities to LittleFS (such as uploading larger animated GIFs) will briefly occupy the internal SPI flash bus. The app must expect potential momentary drops in server responsiveness, and the firmware must rely heavily on PSRAM frame storage to mitigate visible panel flicker during transfers.
> * **Payload Validation:** To safeguard the display code from unexpected crashes, the firmware must implement strict size-checking limits on incoming JSON arrays to verify they do not overflow memory allocations before writing them back down to the partition.
> 
>

