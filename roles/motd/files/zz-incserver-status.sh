# Managed by Ansible (IncServer repo, roles/motd). The status screen at login, for members of `sudo` only: Tenant
# users never see other Environments' state, they get the previous login line (sshd's "Last login" is off, role
# base). Interactive shells on a terminal; ~/.hushlogin skips it. Never fails: a `set -e` login shell would exit on a
# timeout.
if [ -t 1 ] && [ -x /usr/local/bin/incserver-status ] && [ ! -e "${HOME:-/}/.hushlogin" ]; then
    case $- in
    *i*)
        case " $(id -Gn 2>/dev/null) " in
        *" sudo "*) timeout --foreground 5 /usr/local/bin/incserver-status || : ;;
        *) timeout --foreground 5 /usr/local/bin/incserver-status --last-login || : ;;
        esac
        ;;
    esac
fi
