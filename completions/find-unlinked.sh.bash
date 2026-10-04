# Bash completion for find-unlinked.sh
_find_unlinked() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    opts="-d --downloads -m --media -s --search"

    case "${prev}" in
        -d|--downloads|-m|--media|-s|--search)
            COMPREPLY=()
            return 0
            ;;
    esac

    if [[ ${cur} == -* ]] ; then
        mapfile -t COMPREPLY < <(compgen -W "${opts}" -- "${cur}")
        return 0
    fi
}
complete -F _find_unlinked find-unlinked.sh
complete -F _find_unlinked ./find-unlinked.sh
