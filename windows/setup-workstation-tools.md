# Windows Workstation Setup

Developer tools and configuration for a new Windows workstation.

## CLI Tools

```powershell
# ripgrep — fast recursive search
winget install BurntSushi.ripgrep.MSVC

# Windows Terminal
winget install Microsoft.WindowsTerminal

# WSL2
wsl --install -d Ubuntu

# Kubernetes
winget install Kubernetes.kubectl
winget install Helm.Helm
winget install k9s

# Stern — tail multiple pod logs with colour
winget install stern

# GitHub CLI
winget install GitHub.cli

# fzf — fuzzy finder for files and command history
winget install fzf

# bat — cat with syntax highlighting
winget install sharkdp.bat

# jq / yq — JSON and YAML processors
winget install jqlang.jq
winget install MikeFarah.yq
```

## Fonts

```powershell
# Nerd Fonts (for k9s, powerline prompts)
winget install --id=SourceFoundry.HackFonts -e
```

## Quality-of-Life Config

```powershell
# Enable long paths (fixes old Windows path limit)
reg add HKLM\SYSTEM\CurrentControlSet\Control\FileSystem /v LongPathsEnabled /t REG_DWORD /d 1 /f
```

## SSH Agent

```powershell
Get-Service ssh-agent | Set-Service -StartupType Automatic
Start-Service ssh-agent
ssh-add ~/.ssh/id_rsa
```





#end