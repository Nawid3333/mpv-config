# What may go into this public repository - shared by the commit guard (pre-commit)
# and the push guard (pre-push). Sourced by them, never run: no git hook has this name.

# A user folder path (C:\Users\<name>, in any case) or a link to a private claude.ai
# session or artifact (grep -E -i), and an e-mail address but a noreply one. Neither is
# looked for in mpv's own manual, which names an example path (users\USERNAME) and its
# authors' addresses (a git pathspec, for the diff that lists added lines).
private_path_re='[A-Za-z]:[\\/]+Users[\\/]+[A-Za-z0-9_]|claude\.ai/(code|artifact|chat|share)/'
private_path_skip=':(exclude)doc/manual.txt'
email_re='[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
# (support@github.com: Dependabot signs its commits with it)
noreply_re='(noreply@anthropic\.com|noreply@github\.com|support@github\.com|@users\.noreply\.github\.com|@example\.(com|org))$'

# Succeeds when stdin holds an e-mail address that is not a noreply one
private_email() {
	grep -o -E "$email_re" | grep -q -v -i -E "$noreply_re"
}

# $1 = "Name <email>" (what git var prints may follow it: " time zone"). A public
# identity names no one: a GitHub noreply address whose name is its login
# (<id>+<login>@users.noreply.github.com, the numeric id first - CI's Test-PublicIdentity
# asks the same), or Claude <noreply@anthropic.com>.
public_ident() {
	name=${1%% <*}
	email=${1#*<}
	email=${email%%>*}
	case $email in
	noreply@anthropic.com) [ "$name" = Claude ] ;;
	*@users.noreply.github.com)
		addr=${email%@users.noreply.github.com}
		id=${addr%%+*}
		login=${addr#*+}
		case $id in
		'' | *[!0-9]*) false ;;
		*) [ "$addr" != "$login" ] && [ "$name" = "$login" ] ;;
		esac
		;;
	*) false ;;
	esac
}

# The words in the clone's own .git/info/private-words (real name, user name, PC name,
# private paths), one per line; nothing without the file. It is never committed.
private_words() {
	words=$(git rev-parse --git-path info/private-words)
	if [ -s "$words" ]; then
		tr -d '\r' <"$words" | grep -v -e '^[[:space:]]*$' -e '^#'
	fi
	return 0
}
