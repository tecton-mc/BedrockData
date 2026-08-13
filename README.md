# BedrockData

Extracts Minecraft Bedrock Edition game data (Blocks, Items, Entities and their
permutations) using an addon that runs inside the Bedrock Dedicated Server (BDS).

A Zig 0.16 port of the original TypeScript project at
[https://github.com/SerenityJS/bedrock-data](https://github.com/SerenityJS/bedrock-data).
Data is generated for the requested version and saved into `dump/<version>/`.

## Structure

```
zig/
├── src/      → main.zig (orchestration), cli.zig, http.zig, bds.zig, dump.zig, nbt.zig
├── addon/    → JS addon that runs inside BDS
├── template/ → base world copied before each run
├── server/   → BDS installation (downloaded automatically)
└── dump/     → results, one folder per version
```

## Requirements

- [Zig 0.16](https://ziglang.org/download/)
- `curl`
- Linux: `unzip` · Windows: `tar` (bundled) + `curl.exe`

### Build

```sh
zig build
```

This produces the executable at `zig-out/bin/bedrock-data`.

### Run

The first run downloads and installs BDS automatically; it only happens once per
version (the installed version is tracked in `server/.bds-version`).

```sh
# run with the latest stable version (also does: zig build first)
zig build run

# or run the already built binary
./zig-out/bin/bedrock-data
```

### Commands

| Command                                                   | Description                                |
| --------------------------------------------------------- | ------------------------------------------ |
| `./zig-out/bin/bedrock-data`                              | Dump data for the latest stable version    |
| `./zig-out/bin/bedrock-data -l` or `--list`               | List available stable and preview versions |
| `./zig-out/bin/bedrock-data -p` or `--preview`            | Use the latest preview version             |
| `./zig-out/bin/bedrock-data -v 1.26.40.30` or `--version` | Use a specific version                     |
| `./zig-out/bin/bedrock-data -h` or `--help`               | Show help                                  |

Examples:

```sh
./zig-out/bin/bedrock-data --list
./zig-out/bin/bedrock-data --version 1.26.40.30
./zig-out/bin/bedrock-data --preview
```

### How it works

1. Resolves the target version (latest stable / preview / specific version).
2. If the BDS installed in `server/` does not match, it downloads, cleans and extracts
   the correct version for your platform (linux/windows). Platform is detected automatically.
3. Copies the addon and the template world into the server and patches `permissions.json`.
4. **Phase 1**: runs BDS with `generate_documentation` to generate
   `docs/vanilladata_modules/mojang-blocks.json`.
5. **Phase 2**: restarts BDS; the addon sends items/entities over HTTP (localhost:8080).
6. Writes the output JSON files into `dump/<version>/`.

## Generated files

In `dump/<version>/`:

| File                      | Content                                              |
| ------------------------- | ---------------------------------------------------- |
| `block_types.json`        | All blocks with their states and the `loggable` flag |
| `block_states.json`       | Block states (identifier, type, possible values)     |
| `block_permutations.json` | Every block state permutation with its FNV-1a hash   |
| `item_types.json`         | Item types                                           |
| `entity_types.json`       | Entity types                                         |
| `r12_to_current_block_map.bin` | Enriched legacy block map with current states      |
| `r12_warnings.json`       | Entries skipped during r12 enrichment               |

### r12 block map enrichment

The last step of every run enriches the PMMP legacy block map against the
target version's block states and permutations: missing state defaults are
injected, every entry is validated by its FNV-1a hash, and the result is
written to `dump/<version>/r12_to_current_block_map.bin`.

This step depends on a base `r12_to_current_block_map.bin` placed in the
project root. It is **not** generated from scratch per version: if the base
file is missing the step is skipped (`r12: skipping (cannot read ...)`) and no
r12 output is produced for that version. Existing dumps generated before this
step was added do not contain r12 files.
