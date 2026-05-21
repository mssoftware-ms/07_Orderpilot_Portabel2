# 🚀 OrderPilot Portabel – Flutter Trading App

Ein portabler, cross-platform Trading-App-Prototyp mit **Flutter UI** und **Rust Trading-Engine**.
Unterstützt BB+RSI-Backtesting mit echten Binance-Marktdaten, interaktive Charts und Paper-Trading.

---

## 📋 Features

| Feature | Status |
|---|---|
| **Backtest-Engine** (Dart + Rust) | ✅ Voll funktionsfähig |
| BB+RSI Mean-Reversion Strategie | ✅ Implementiert |
| Binance REST API (OHLCV-Daten) | ✅ Mit Caching & Retry |
| Equity-Curve Chart (fl_chart) | ✅ Interaktiv mit Tooltips |
| Performance-Metriken (Win Rate, Sharpe, PF, Drawdown) | ✅ |
| Trade-Log mit Export (CSV) | ✅ |
| Responsive Layout (Mobile + Desktop) | ✅ |
| Dark Theme (TR-inspiriert) | ✅ |
| Paper-Trading (Live WebSocket) | 🔧 Platzhalter |
| Strategie-Management | 🔧 Platzhalter |
| Rust FFI Bridge (native) | 🔧 Fallback-Modus |

---

## 🏗️ Architektur

```
trading_app/
├── lib/
│   ├── core/
│   │   ├── constants/app_constants.dart   # App-weite Konstanten
│   │   └── models/                        # CandleData, Trade-Modelle
│   ├── features/
│   │   └── backtest/backtest_provider.dart # State-Management (Provider)
│   ├── services/
│   │   ├── backtest_service.dart          # Dart BB+RSI Backtest-Engine
│   │   ├── binance_api_client.dart        # Binance REST API Client
│   │   ├── rust_bridge.dart               # Rust FFI Interface
│   │   └── websocket_client.dart          # Live-Daten WebSocket
│   ├── ui/
│   │   ├── screens/                       # 5 Hauptscreens
│   │   ├── themes/app_theme.dart          # Dark-Theme & Farben
│   │   └── widgets/                       # Wiederverwendbare Widgets
│   └── main.dart                          # App Entry-Point
├── rust/trading_engine/                   # Rust Trading-Engine
│   └── src/
│       ├── addins/bb_rsi.rs              # BB+RSI Strategie (Rust)
│       ├── backtest/mod.rs               # Backtest-Engine (Rust)
│       ├── models/                        # Candle, Trade, Metriken
│       ├── strategy/                      # StrategyAddin Trait
│       └── api.rs                        # FFI API-Funktionen
└── test/                                 # Flutter + Rust Tests
```

---

## ⚙️ Setup

### Voraussetzungen

- **Flutter SDK** ≥ 3.22 ([flutter.dev/get-started](https://flutter.dev/docs/get-started/install))
- **Dart SDK** ≥ 3.5 (wird mit Flutter mitgeliefert)
- **Rust** ≥ 1.75 ([rustup.rs](https://rustup.rs/))
- **Android Studio** / **VS Code** (optional, für IDE-Support)
- Für Android: Android SDK + NDK
- Für Windows: Visual Studio Build Tools mit C++ Desktop Workload

### 1. Repository klonen

```bash
git clone https://github.com/mssoftware-ms/07_Orderpilot_Portabel2.git
cd 07_Orderpilot_Portabel2
```

### 2. Flutter-Abhängigkeiten installieren

```bash
flutter pub get
```

### 3. Rust-Engine kompilieren (optional, für native Performance)

```bash
cd rust/trading_engine
cargo build --release
cargo test   # 57 Tests sollten bestehen
cd ../..
```

### 4. App starten

```bash
# Linux Desktop
flutter run -d linux

# Windows Desktop
flutter run -d windows

# Android (Emulator oder Gerät)
flutter run -d android

# Web (experimentell)
flutter run -d chrome
```

### 5. Tests ausführen

```bash
# Flutter-Tests (59 Tests)
flutter test

# Rust-Tests (57 Tests)
cd rust/trading_engine && cargo test
```

---

## 🎯 Backtest verwenden

1. App starten → Tab **„Backtest"** auswählen
2. **Konfiguration:**
   - Symbol: `BTCUSDT` oder `ETHUSDT`
   - Timeframe: `1m` bis `1d`
   - Zeitraum: Start-/Enddatum wählen
   - Balance & Fee-Rate einstellen
   - Optional: Strategie-Parameter anpassen (BB Period, RSI etc.)
3. **„Run Backtest"** klicken
4. Ergebnisse ansehen:
   - **Metriken-Grid**: PnL, Win Rate, Profit Factor, Drawdown, Sharpe Ratio
   - **Equity-Curve**: Interaktiver Chart mit Tooltips
   - **Trade-Log**: Expandierbare Liste aller Trades
5. **CSV-Export** über das Download-Icon in der AppBar

---

## 📦 Abhängigkeiten

| Paket | Zweck |
|---|---|
| `fl_chart` | Equity-Curve & Charts |
| `candlesticks` | Candlestick-Chart Widget |
| `http` | REST API Calls |
| `web_socket_channel` | WebSocket für Live-Daten |
| `provider` | State Management |
| `intl` | Datums-/Zahlenformatierung |
| `flutter_rust_bridge` | Rust ↔ Dart FFI |

---

## 📝 Lizenz

Privates Projekt – alle Rechte vorbehalten.
