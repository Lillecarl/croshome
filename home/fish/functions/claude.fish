function claude
    set --export BASH_ENV /etc/profile
    if command -v wrapty 2>/dev/null then
        wrapty claude $argv
    else
        command claude $argv
    end
end
