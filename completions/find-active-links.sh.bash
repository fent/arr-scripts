# Bash completion for find-active-links.sh
_find_active_links() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    opts="-m --media -f --folders"

    case "${prev}" in
        -m|--media|-f|--folders)
            COMPREPLY=()
            return 0
            ;;
    esac

    if [[ ${cur} == -* ]] ; then
        mapfile -t COMPREPLY < <(compgen -W "${opts}" -- "${cur}")
        return 0
    fi
}
complete -F _find_active_links find-active-links.sh
complete -F _find_active_links ./find-active-links.sh
