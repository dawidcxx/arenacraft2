# AGENTS.md

Guidance for AI agents working on Arenacraft2.

## Project Shape

Arenacraft2 is a WoW-inspired PvP-only MMO core. The main server is Zig. The `manager/` directory is a Bun + TypeScript + React/OpenTUI sidecar used for database migrations and admin commands.

Key directories:

- `src/server/`: TCP auth/world servers and process entrypoint.
- `src/protocol/`: isolated auth, world, chat, movement, update-object wire protocol code.
- `src/domain/`: domain value types and game-specific transfer objects.
- `src/db/`: Zig database query layer.
- `src/world/`: game world simulation and ECS integration.
- `src/stdx/`: shared utilities used by Zig modules.
- `src/game_data/`: JSON source data consumed by `build.zig` to generate a Zig module.
- `manager/src/db/migrations/sql/`: database migrations managed by the sidecar.

## Tooling

- Zig minimum version is `0.16.0` per `build.zig.zon`.
- `flake.nix` provides an optional dev shell with Zig, ZLS, pkg-config, and helper tools.
- The manager uses Bun and TypeScript.
- Postgres is provided by `docker-compose.yml`; either Docker Compose or Podman Compose should work.

## Common Commands

- Start dependencies: `podman compose up -d` or `docker compose up -d`.
- Run all Zig tests: `zig build all-test --summary all`.
- Run one Zig module test step: `zig build protocol-test`, `zig build domain-test`, `zig build db-test`, `zig build world-test`, `zig build server-test`, or `zig build stdx-test`.
- Run server in development: `zig build -fincremental --watch -Denable-verbose-packet-log=true server-run`.
- Build release server: `zig build --release=fast server-build`.
- Type-check manager: `cd manager && bun run check`.
- Run manager: `cd manager && bun install && bun dev`.

## Database Workflow

- Default local database URL is `postgresql://arenacraft:arenacraft@127.0.0.1:5432/arenacraft`.
- The Nix shell exports `DATABASE_URL` for the Zig server.
- The manager scripts read `manager/.env.local`; use `manager/.env.example` as the template.
- Initialize a fresh database through the manager with `/migrate`, `/addrealm Arenacraft`, and `/adduser gm gm`.
- Add schema changes as new SQL files in `manager/src/db/migrations/sql/` and wire them through `manager/src/db/migrations/index.ts`.

## Zig Conventions

- Keep modules separated by purpose. Protocol code should not grow server or DB behavior. Domain code should remain mostly leaf/value logic.
- Root module files re-export public API and include import-only `test { ... }` blocks so nested tests are discovered. Update the relevant root file when adding new Zig files.
- Prefer explicit allocator ownership and `defer` cleanup. Tests should catch ownership/lifetime changes when possible.
- Use existing build steps instead of ad-hoc `zig test` commands unless there is a specific reason.
- Do not edit generated Zig game-data output. Edit `src/game_data/*.json`; `build.zig` regenerates the module.
- For protocol changes, add or update wire-shape tests near the codec being changed.

## Manager Conventions

- Keep command behavior in `manager/src/commands/rootCommands.ts` and service behavior in `manager/src/db/*Service.ts` or other focused service files.
- Preserve strict TypeScript settings. Verify manager changes with `bun run check`.
- The OpenTUI UI is terminal-rendered React, not a browser app. Avoid DOM/browser APIs unless the runtime supports them.

## Verification Expectations

- For Zig-only changes, run the narrow module test first, then `zig build all-test --summary all` when practical.
- For manager changes, run `cd manager && bun run check`.
- For database or end-to-end server changes, start Postgres and run the manager migration flow before relying on server behavior.
- If full verification is skipped because it is slow or requires external services, state exactly what was and was not run.

## Files To Avoid

- Do not modify `.zig-cache/`, `zig-out/`, `manager/node_modules/`, `.direnv/`, or generated build outputs.
- Do not commit local secrets such as `manager/.env.local`.
- Do not rewrite lockfiles unless dependency changes require it.
