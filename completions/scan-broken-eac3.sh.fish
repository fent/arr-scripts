# Fish completion for scan-broken-eac3.sh
complete -c scan-broken-eac3.sh -c ./scan-broken-eac3.sh -f
complete -c scan-broken-eac3.sh -c ./scan-broken-eac3.sh -s h -l help -d "Show help message"
complete -c scan-broken-eac3.sh -c ./scan-broken-eac3.sh -l continue-from -x -d "Resume scanning from a specific file index"
complete -c scan-broken-eac3.sh -c ./scan-broken-eac3.sh -l recent -x -d "Only scan files added in the last X hours"
