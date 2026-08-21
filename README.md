# Zero Temperature

A small home climate-monitoring system: DHT22 sensors on Raspberry Pi Zeros
report readings into a central PostgreSQL database (project [`db`](../db),
the "Hive"), hosted on a Raspberry Pi 5. This repo is split into the two
things that actually get deployed, one per device role:

```
                    ┌─────────────┐        ┌─────────────┐
DHT22 sensor  →     │  RPi Zero   │  →     │    RPi 5    │  →  dashboard
                    │ rpi-zero/   │  psql  │ (Hive DB +  │     (browser)
                    └─────────────┘        │  rpi5/)     │
                                            └─────────────┘
```

| Directory | Runs on | Purpose |
|---|---|---|
| [`rpi-zero/`](rpi-zero/) | Each Raspberry Pi Zero | Reads the DHT22 sensor and writes readings into the central database. Also keeps a local SQLite mirror + tiny single-sensor dashboard, so a Zero is still useful standalone if the network or the Pi 5 is down. |
| [`rpi5/`](rpi5/) | The Raspberry Pi 5 (Hive) | Web dashboard that reads every sensor's readings out of the central PostgreSQL database and shows them together — the whole-apartment view. |
| [`IoT Temperature Dashboard Wireframe/`](IoT%20Temperature%20Dashboard%20Wireframe/) | — | Design reference the `rpi5/` dashboard is built from (not deployed anywhere). |

The central database itself — schema, roles, deployment — lives in the
separate [`db`](../db) project ("Hive"); this repo only writes to it
(`rpi-zero/`) and reads from it (`rpi5/`).

See each directory's own README for setup instructions.
