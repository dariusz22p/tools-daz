# Tools and Scripts

![CI](https://github.com/dariusz22p/tools-daz/actions/workflows/tests.yml/badge.svg)

A collection of utility scripts and tools for server management, web server configuration, and video processing.

## Directory Structure

### `server/`

Server and web server management scripts:

- **generate_goaccess_report.sh** - Generate GoAccess web analytics reports
- **git-pull-only-if-new-changes.sh** - Git pull with change detection and Nginx deploy
- **pull_repo.sh** - Repository pull utility script
- **validate_goaccess_reports.sh** - Validate GoAccess report integrity
- **config/** - Crontab, logrotate, and Nginx configuration

### `macbook/`

Local machine utilities:

- **compress-foty-i-video-v3.sh** - Image/video compression script (HEIC→JPEG, H.265 video)

### `minecraft/`

Minecraft server management:

- **scripts/backup.sh** - World backup with rotation
- **scripts/start.sh** - Server launch with G1GC tuning
- **config/** - Nginx, Geyser, Plan plugin configs
- **how-to/** - Setup guides (Bedrock, SSL, iptables, analytics)

### `sharepoint/`

SharePoint video downloader — downloads videos from SharePoint/Stream when direct download is blocked by tenant policy:

- **sharepoint_dl.py** - Main downloader (extracts browser cookies, fetches DASH segments, muxes with ffmpeg)
- **sharepoint_dl.sh** - macOS/Linux wrapper (auto-installs deps in a venv)
- **sharepoint_dl.bat** - Windows wrapper (auto-installs deps in a venv)
- **test_sharepoint_dl.py** - Unit tests

Supported browsers: Opera (default), Chrome, Edge, Brave, Firefox.
See [sharepoint/](sharepoint/) for full usage details.

### `windows/`

Windows utilities:

- **c-drive-cleanup/** - PowerShell C: drive storage analyser
- **profile.md** - PowerShell profile setup
- **setup-workstation-tools.md** - Workstation provisioning notes

### `git-config/`

Git configuration reference and tips.

### `tests/`

Unit tests organised by repo section:

- **server/** - GoAccess report generation, validation, caching, pull_repo logic
- **macbook/** - Compress script utilities (format_duration, human_size, require_tool)
- **minecraft/** - Backup cleanup logic, dependency checks
- **SharePoint** Python tests live in `sharepoint/test_sharepoint_dl.py`

Run locally:

```bash
bats tests/server/*.bats       # Server scripts
bats tests/macbook/*.bats      # MacBook scripts
bats tests/minecraft/*.bats    # Minecraft scripts
cd sharepoint && pytest -v     # SharePoint Python tests
```

## Usage

Most scripts are shell scripts designed for server automation and maintenance tasks. All server scripts support `--version` to print their version.

### Environment Variables Reference

#### `generate_goaccess_report.sh`

| Variable | Default | Description |
|---|---|---|
| `GOACCESS_BIN` | `goaccess` | Path to goaccess binary |
| `GOACCESS_ARGS` | `--log-format=COMBINED` | Extra args for goaccess |
| `GOACCESS_OUTPUT_DIR` | `/var/log/goaccess_reports` | Directory for report output |
| `TARGET_DIR` | `/usr/share/nginx/html` | Web root for serving reports |
| `MAX_ROTATED_LOGS` | `365` | Max old logs to process (0=unlimited) |
| `MIN_DISK_SPACE_MB` | `500` | Minimum free disk space in MB |
| `ENABLE_CACHE` | `true` | Skip regeneration if logs unchanged |
| `DEBUG` | `false` | Enable verbose debugging output |

#### `git-pull-only-if-new-changes.sh`

| Variable | Default | Description |
|---|---|---|
| `DEBUG` | `0` | Set to `1` for verbose tracing and live logging |
| `ROLLBACK` | `0` | Set to `1` to restore previous deployment |
| `TARGET_DIR` | `/usr/share/nginx/html` | Web root deploy target |
| `REMOTE_HASH_CACHE_TTL` | `30` | Seconds to cache remote hash |
| `REPORT_ON_NO_CHANGES` | `false` | Generate reports even if no git changes |
| `KEEP_ROTATED_LOGS` | `7` | Days to keep rotated update-repo logs |
| `KEEP_AGGREGATED_LOGS` | `30` | Days to keep aggregated nginx logs |
| `KEEP_CUMULATIVE_LOGS` | `365` | Days to keep cumulative logs |
| `GOACCESS_LOG_FORMAT` | `COMBINED` | Log format for goaccess |
| `PARALLEL_PROCESSING` | `true` | Process multiple logs in parallel |
| `AUTO_CREATE_DEPLOYED_MARKER` | `0` | Set to `1` to auto-create `.deployed_commit` |

#### `pull_repo.sh`

| Variable | Default | Description |
|---|---|---|
| `TARGET_BASE` | `/git` | Base directory for clone/update (also accepts `$1` arg) |

#### `validate_goaccess_reports.sh`

Takes report directory as `$1` (default: `/var/log/goaccess_reports`). No environment variable overrides.

## Version Management

When updating scripts (especially via AI assistance):

1. **Always increment the `SCRIPT_VERSION`** variable at the top of the script
2. Version format: Use semantic versioning (e.g., `2.0.2` → `2.0.3` for patches, `2.1.0` for minor updates)
3. Update the version comment in the header (e.g., `# Version: 2.0.3`)
4. Commit message should reference the version change

### Example Version Bump

```bash
# Before
SCRIPT_VERSION="2.0.2"
# Version: 2.0.2

# After (for patch)
SCRIPT_VERSION="2.0.3"
# Version: 2.0.3
```

This ensures version consistency and helps track changes across deployments.

## Notes

- Ensure proper permissions are set for executable scripts (`chmod +x` where needed)
- Review configuration files before deploying to production environments
