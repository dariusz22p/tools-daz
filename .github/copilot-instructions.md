# GitHub Copilot Instructions

## Script Version Management

When updating or fixing scripts in this repository via AI assistance:

### Version Bumping Rules
1. **Always increment `SCRIPT_VERSION`** at the top of shell scripts
2. **Use semantic versioning**:
   - **Patch** (X.Y.Z → X.Y.Z+1): Bug fixes, minor improvements
   - **Minor** (X.Y.Z → X.Y+1.0): New features, significant changes
   - **Major** (X.Y.Z → X+1.0.0): Breaking changes, major rewrites

3. **Update both locations**:
   ```bash
   # In the script header variable
   SCRIPT_VERSION="2.0.3"
   
   # In the script header comment
   # Version: 2.0.3
   ```

4. **Include in commit message**:
   ```
   Commit message format: "Feature/Fix: description (v2.0.3)"
   Example: "Fix arithmetic expansion bug (v2.0.3)"
   ```

## Current Script Versions

- `git-pull-only-if-new-changes.sh`: 2.0.2 → update to 2.0.3 on next change
- `generate_goaccess_report.sh`: 1.6.0 → update to 1.6.1 on next change

## Examples

### Before (bug fix):
```bash
SCRIPT_VERSION="2.0.2"
# Version: 2.0.2
```

### After (patch update):
```bash
SCRIPT_VERSION="2.0.3"
# Version: 2.0.3
```

## Why This Matters

- Tracks what changes were made between versions
- Helps with debugging by identifying which version caused issues
- Maintains consistency across deployments
- Makes rollbacks easier when needed
