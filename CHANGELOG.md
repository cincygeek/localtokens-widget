# Changelog

## 0.2.0 - 2026-11-23

- Reports tab: totals for the last 24 hours, today, the last 7 days, 30 days or 12 months, with the change from the period before, a chart by hour, day or month, a per-model breakdown, and a CSV export of just that period
- Model lists no longer show a model that only logged errors as "0 · 0 req"; its errors still count in the totals
- Two models whose short names match (e.g. `qwen/qwen3.5-9b` and `lmstudio-community/qwen3.5-9b`) are listed by their full IDs
- Bug report and feature request forms for the issue tracker

## 0.1.0

First release.

- Window and tray icon with live status, tokens this session, generation speed and context use
- Sessions restart on a model load or switch, or on a server start (`sessionMode`)
- Reads every LM Studio server-logs folder it finds (`server-logs` and `apps\*\server-logs`), each with its own state
- Details: last 24 hours by hour, totals (24 h, today, 7 days, all time), today's models, last request, loaded models, log folders
- Themes: Classic, OLED black, Midnight, Mocha, Forest, Paper (light), and Halloween, Space, Ocean, Cyberpunk with pixel-art backgrounds; Auto picks Halloween in October; custom accent colour
- Export to CSV, one row per day and model
- Start with Windows from the tray menu
- Settings in `config.json`, applied without a restart
