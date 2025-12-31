# Tools and Scripts

A collection of utility scripts and tools for server management, web server configuration, and video processing.

## Directory Structure

### `java-snake/`
Server and web server management scripts:
- **crontab.txt** - Crontab configuration entries
- **etc_nginx_nginx.conf** - Nginx web server configuration
- **generate_goaccess_report.sh** - Generate GoAccess web analytics reports
- **git-pull-only-if-new-changes.sh** - Git pull with change detection
- **pull_repo.sh** - Repository pull utility script
- **validate_goaccess_reports.sh** - Validate GoAccess report integrity

### `MacBook/`
Local machine utilities:
- **compress-foty-i-video-v3.sh** - Video compression script (v3)`

## Usage

Most scripts are shell scripts designed for server automation and maintenance tasks. Review each script's contents for specific usage instructions and requirements.

## Version Management

When updating scripts (especially via AI assistance):
1. **Always increment the `SCRIPT_VERSION`** variable at the top of the script
2. Version format: Use semantic versioning (e.g., `2.0.2` → `2.0.3` for patches, `2.1.0` for minor updates)
3. Update the version comment in the header (e.g., `# Version: 2.0.3`)
4. Commit message should reference the version change

### Example Version Bump:
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
