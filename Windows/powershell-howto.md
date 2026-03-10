
# mv
Rename-Item .git/hooks/pre-commit pre-commit.disabled


# find 
Get-ChildItem .git/hooks | Where-Object { $_.Name -notlike "*.sample" }
