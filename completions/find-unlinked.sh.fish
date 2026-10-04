# Fish completion for find-unlinked.sh
complete -c find-unlinked.sh -c ./find-unlinked.sh -f
complete -c find-unlinked.sh -c ./find-unlinked.sh -s d -l downloads -x -d "Downloads root folder"
complete -c find-unlinked.sh -c ./find-unlinked.sh -s m -l media -x -d "Media target folder"
complete -c find-unlinked.sh -c ./find-unlinked.sh -s s -l search -x -d "Search terms for release names"
