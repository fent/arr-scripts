# Fish completion for find-active-links.sh
complete -c find-active-links.sh -c ./find-active-links.sh -f
complete -c find-active-links.sh -c ./find-active-links.sh -s m -l media -x -d "Target media directory"
complete -c find-active-links.sh -c ./find-active-links.sh -s f -l folders -x -d "Target download folders to scan"
