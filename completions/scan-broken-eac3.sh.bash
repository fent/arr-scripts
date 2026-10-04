# Bash completion for scan-broken-eac3.sh
_scan_broken_eac3() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    opts="--continue-from --recent --help -h"

    case "${prev}" in
        --continue-from|--recent)
            COMPREPLY=()
            return 0
            ;;
    esac

    if [[ ${cur} == -* ]] ; then
        mapfile -t COMPREPLY < <(compgen -W "${opts}" -- "${cur}")
        return 0
    fi
}
complete -F _scan_broken_eac3 scan-broken-eac3.sh
complete -F _scan_broken_eac3 ./scan-broken-eac3.sh
