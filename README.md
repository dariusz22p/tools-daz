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

## Notes

- Ensure proper permissions are set for executable scripts (`chmod +x` where needed)
- Review configuration files before deploying to production environments
