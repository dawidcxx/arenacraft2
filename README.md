# Arenacraft2 

WoW inspired PVP only MMO core, written in zig

# Structure overview

```
.
├── build.zig                # Zig build system
├── build.zig.zon            # Zig dependencies
├── docker-compose.yml       # Third party deps (like DB)
├── flake.lock               
├── flake.nix                # Nix pinned CLI tools (optional)
├── manager                  # Sidecar manager application
│   ├── src
│   │   ├── db               # Important: DB migrations are contained here
├── README.md
├── src                      # Main zig source directory (!)
|   | 
│   ├── db                   # Container for DB queries
│   ├── domain               # Leaf value types and other domain specific transferables
│   ├── game_data            # Container of dummy game data
│   ├── protocol             # Isolated protocol structs
│   ├── server               # TCP server 
│   ├── stdx                 # Collection of resuable utilities
│   └── world                # Game world simulation
```

# Development guide

1. Spin up third party dependencies in the background (see: [docker-compoose.yaml](docker-compose.yml)): `podman compose up -d`

2. Populate DB:

```bash
cd manager
bun install
bun dev
```

Run `/migrate up` `/addrealm Arenacraft` `/adduser gm gm`

3. Run it:

- Development ver: `zig build -fincremental --watch -Denable-verbose-packet-log=true server-run`
- Release ver: `zig build --release=fast server-build && ./zig-out/bin/arenacraft2`

### Development guide - extras

- ***Provide references cores for AI***: 
```
mkdir ~/code/arenacraft2-reference-cores
git clone -b 3.3.5 git@github.com:TrinityCore/TrinityCore.git
git clone git@github.com:azerothcore/azerothcore-wotlk.git
git clone git@github.com:vmangos/core.git
git clone git@github.com:dawidcxx/arenacraft.git
```