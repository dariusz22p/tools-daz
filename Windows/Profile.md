
notepad $PROFILE.CurrentUserAllHosts
notepad $PROFILE.AllUsersAllHosts

function awscreds {
    py -3 "C:\Users\panasid\git_c\scripts-aws\scripts\auth\aws-export-creds.py" @args
}
