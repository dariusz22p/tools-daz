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

### `yt/`

YouTube playlist audio downloader and queue runner:

- **yt-dlp-script-auto-playlist.sh** - Downloads playlist audio as MP3, follows related playlists, writes a JSON download index, and performs periodic health checks
- **playlist_queue.txt** - Queue of playlists to process
- **seen_playlists.txt** - Deduplicated history of processed playlists

See [yt/README.md](yt/README.md) for usage details.

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
- **yt/** - yt-dlp auto-playlist queue, retry, indexing, and health-check logic
- **SharePoint** Python tests live in `sharepoint/test_sharepoint_dl.py`

Run locally:

```bash
bats tests/server/*.bats       # Server scripts
bats tests/macbook/*.bats      # MacBook scripts
bats tests/minecraft/*.bats    # Minecraft scripts
bats tests/yt/*.bats           # YouTube playlist downloader script
cd sharepoint && pytest -v     # SharePoint Python tests
```

## Usage

Most scripts are shell scripts designed for server automation and maintenance tasks. All server scripts support `--version` to print their version.

### Environment Variables Reference

#### `generate_goaccess_report.sh`

- `GOACCESS_BIN`: default `goaccess`. Path to goaccess binary.
- `GOACCESS_ARGS`: default `--log-format=COMBINED`. Extra args for goaccess.
- `GOACCESS_OUTPUT_DIR`: default `/var/log/goaccess_reports`. Directory for report output.
- `TARGET_DIR`: default `/usr/share/nginx/html`. Web root for serving reports.
- `MAX_ROTATED_LOGS`: default `365`. Max old logs to process, `0` means unlimited.
- `MIN_DISK_SPACE_MB`: default `500`. Minimum free disk space in MB.
- `ENABLE_CACHE`: default `true`. Skip regeneration if logs are unchanged.
- `DEBUG`: default `false`. Enable verbose debugging output.

#### `git-pull-only-if-new-changes.sh`

- `DEBUG`: default `0`. Set to `1` for verbose tracing and live logging.
- `ROLLBACK`: default `0`. Set to `1` to restore the previous deployment.
- `TARGET_DIR`: default `/usr/share/nginx/html`. Web root deploy target.
- `REMOTE_HASH_CACHE_TTL`: default `30`. Seconds to cache the remote hash.
- `REPORT_ON_NO_CHANGES`: default `false`. Generate reports even if no git changes are found.
- `KEEP_ROTATED_LOGS`: default `7`. Days to keep rotated update-repo logs.
- `KEEP_AGGREGATED_LOGS`: default `30`. Days to keep aggregated nginx logs.
- `KEEP_CUMULATIVE_LOGS`: default `365`. Days to keep cumulative logs.
- `GOACCESS_LOG_FORMAT`: default `COMBINED`. Log format for goaccess.
- `PARALLEL_PROCESSING`: default `true`. Process multiple logs in parallel.
- `AUTO_CREATE_DEPLOYED_MARKER`: default `0`. Set to `1` to auto-create `.deployed_commit`.

#### `pull_repo.sh`

- `TARGET_BASE`: default `/git`. Base directory for clone or update; also accepts `$1`.

#### `validate_goaccess_reports.sh`

Takes report directory as `$1` (default: `/var/log/goaccess_reports`). No environment variable overrides.

#### `yt-dlp-script-auto-playlist.sh`

- `DOWNLOAD_DIR`: default current working directory. Where MP3 files are written.
- `DOWNLOAD_INDEX_FILE`: default `$DOWNLOAD_DIR/yt-dlp-download-index.json`. JSON index of completed downloads.
- `RETRY_COUNT`: default `3`. Number of download attempts per playlist.
- `RETRY_BACKOFF_SECONDS`: default `5`. Linear backoff multiplier between retries.
- `MIN_YTDLP_VERSION`: default `2025.01.15`. Minimum supported yt-dlp version.
- `HEALTH_CHECK_INTERVAL_SECONDS`: default `120`. Minimum time between full health checks.
- `MIN_FREE_SPACE_MB`: default `2048`. Abort when free disk space drops below this threshold.
- `SCRIPT_START_EPOCH`: default launch time. Used to compute runtime in health output.

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
