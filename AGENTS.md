# AGENTS.md

Guidance for AI agents working on Arenacraft2.

## Project Shape

Arenacraft2 is a WoW-inspired PvP-only MMO core. The main server is Zig. The `manager/` directory is a Bun + TypeScript + React/OpenTUI sidecar used for database migrations and admin commands.

Key directories:

- `src/server/`: TCP auth/world servers and process entrypoint.
- `src/protocol/`: isolated auth, world, chat, movement, update-object wire protocol code.
- `src/domain/`: plain data types shared across the application (ids, defs, transfer objects). No lookups, no JSON parsing.
- `src/game_data/`: parses the generated `game_data_db` rows into lookups conforming to domain types.
- `src/game_data/db/`: plain JSON source data consumed by `build.zig` to generate the `game_data_db` module.
- `src/db/`: Zig database query layer.
- `src/world/`: game world simulation and ECS integration.
- `src/stdx/`: shared utilities used by Zig modules.
- `manager/src/db/migrations/sql/`: database migrations managed by the sidecar.

Where to put things: plain types (id enums, def structs, transfer objects) belong in `domain`. Data mapped from a `.dbc` file belongs in `game_data/db` as JSON, with its lookup in `game_data`. Static tables that never need JSON (e.g. hardcoded client creation templates) live in `game_data` as Zig. Anything that binary-searches over rows is a `game_data` lookup, never a `domain` resident; small convenience switches on domain enums (like `Class.powerTypeId`) are fine in `domain`.

## Tooling

- Zig minimum version is `0.16.0` per `build.zig.zon`.
- `flake.nix` provides an optional dev shell with Zig, ZLS, pkg-config, and helper tools.
- The manager uses Bun and TypeScript.
- Postgres is provided by `docker-compose.yml`; either Docker Compose or Podman Compose should work.

## Common Commands

- Start dependencies: `podman compose up -d` or `docker compose up -d`.
- Run all Zig tests: `zig build all-test --summary all`.
- Run one Zig module test step: `zig build protocol-test`, `zig build domain-test`, `zig build game_data-test`, `zig build db-test`, `zig build world-test`, `zig build server-test`, or `zig build stdx-test`.
- Run server in development: `zig build -fincremental --watch -Denable-verbose-packet-log=true server-run`.
- Build release server: `zig build --release=fast server-build`.
- Type-check manager: `cd manager && bun run check`.
- Run manager: `cd manager && bun install && bun dev`.

## Extra AI instructions 

- Only use reference cores for protocol level, data representation issues. Azerothcore in particular has awful coding pratices in it, never bias your implementation using it though u can use it to extract protocol information
- **NEVER** bias zig code implementation using a existing .cpp solution
- VMAngos core contains better architecture coding style, cleaner logic encoding, Azerothcore must only be used for be used for its protocol information
- Avoid AzerothCore it's badly coded
- Be efficient on tokens, feel free to bail out early and prompt the user for input
- Assume the user is a expert developer that can guide you with architectural decisions
- Updating `docs/*.md` is allowed and encouraged for durable knowledge (protocol quirks, debugging sessions, gotchas). Keep it short and only write down things that don't rot: no call-site inventories, line numbers, or summaries of code that will move. A wrong doc is worse than no doc.

