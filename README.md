# Tools and Scripts

A collection of utility scripts and tools for server management, web server configuration, and video processing.

## Directory Structure

### `java-snake/`

Server and web server management scripts:

- **generate_goaccess_report.sh** - Generate GoAccess web analytics reports
- **git-pull-only-if-new-changes.sh** - Git pull with change detection and Nginx deploy
- **pull_repo.sh** - Repository pull utility script
- **validate_goaccess_reports.sh** - Validate GoAccess report integrity
- **config/** - Crontab and logrotate configuration

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
- **setup-workstation-tools.txt** - Workstation provisioning notes

### `git-config/`

Git configuration reference and tips.

### `tests/`

Unit tests for shell scripts (bats) — run via `bats tests/*.bats`.

## Usage

Most scripts are shell scripts designed for server automation and maintenance tasks. Review each script's contents for specific usage instructions and requirements.

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
