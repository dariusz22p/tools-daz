


# Show merged config (all scopes)
git config --show-origin --list

# show config
git config --global --list
git config --system --list

# open git config
notepad $env:USERPROFILE\.gitconfig





# Git hooks
Get-ChildItem .git/hooks
Get-ChildItem .husky
Select-String -Path package.json -Pattern "husky"
pre-commit --version
## disable ALL pre‑commit hooks (temporarily)
git commit --no-verify
### permanently
Rename-Item .git/hooks/pre-commit pre-commit.disabled




# Set safe LF defaults:
git config --global core.autocrlf input
git config --global core.eol lf
## Make Git show line‑ending changes:
git config --global core.whitespace cr-at-eolArgoCD runs inside the AWS control plane
