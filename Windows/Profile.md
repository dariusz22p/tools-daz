
notepad $PROFILE.CurrentUserAllHosts
notepad $PROFILE.AllUsersAllHosts

function awscreds {
    py -3 "C:\Users\panasid\git_c\scripts-aws\scripts\auth\aws-export-creds.py" @args
}

# See all profile paths (string properties, no piping)

```
$PSVersionTable.PSEdition
$PROFILE
$PROFILE | Get-Member   # just to see it's a string

# The four canonical paths:
$PROFILE.CurrentUserCurrentHost
$PROFILE.CurrentUserAllHosts
$PROFILE.AllUsersCurrentHost
$PROFILE.AllUsersAllHosts
```

# Create (or open) the CurrentUserAllHosts profile

```
# Ensure the directory exists for PS 7+
$dir = Split-Path $PROFILE.CurrentUserAllHosts
New-Item -ItemType Directory -Force -Path $dir | Out-Null

# Create the profile file if missing
if (-not (Test-Path $PROFILE.CurrentUserAllHosts)) {
    New-Item -ItemType File -Path $PROFILE.CurrentUserAllHosts -Force | Out-Null
}

# Open it for editing
notepad $PROFILE.CurrentUserAllHosts
```

# unblock a profile file

`Unblock-File -Path $PROFILE.CurrentUserAllHosts`

# Alternative: system‑wide wrapper (works in any shell)

If you ever want a global command available in CMD and PowerShell without touching profiles, drop a small wrapper into a directory on your %PATH%:
Create C:\Users\panasid\bin\awscreds.cmd with:

```
@echo off
py -3 C:\Users\panasid\git_c\scripts-aws\scripts\auth\aws-export-creds.py %*
``
```
