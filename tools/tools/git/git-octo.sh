#!/bin/sh
############################################################ LICENSE
#
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 Devin Teske <dteske@FreeBSD.org>
#
############################################################ IDENT(1)
#
# $Title: manage GitHub pull requests from git commits $
# $Copyright: 2026 Devin Teske. All rights reserved. $
#
############################################################ INFORMATION
#
# git octo creates and updates GitHub pull requests from git commits,
# one pull request per commit, in the same shape as git arc. Reviews
# live on the fork named by octo.fork. Nothing is merged through
# GitHub. git octo stage lands the commit on the local FreeBSD tree,
# the same way git arc stage does, and records a GitHub PR trailer.
#
# A stack is a pull request whose base is the parent commit's branch
# on that same fork. -p sets the parent of the first commit. Later
# commits in one invocation use the branch just pushed.
#
############################################################ CONFIGURATION

#
# API
#
API_HOST=api.github.com
API_PREFIX="https://$API_HOST"

############################################################ GLOBALS

pgm="${0##*/}" # Program basename

#
# Global exit status
#
SUCCESS=0
FAILURE=1

#
# Command-line flags
#
ASSUME_YES=		# -y
VERBOSE=		# -v

#
# Miscellaneous
#
BROWSE=
GH_TOKEN=
GH_STATUS=
OCTO_TMPDIR=
UPSTREAM=
FORK=
PUSH_SPEC=
BASE=main
PR_REPO=
PR_NUM=
PR_HEAD=
PR_COUNT=0
PR_NUMS=
PR_JSON=
SEEN=

############################################################ FUNCTIONS

quietly(){ "$@" > /dev/null 2>&1; }
have(){ quietly command -v "$@"; }

warn()
{
	local fmt="$1"
	[ "$fmt" ] || return
	shift 1 # fmt
	printf "%s: $fmt\n" "$pgm" "$@" >&2
}

die()
{
	warn "$@"
	exit $FAILURE
}

usage()
{
	warn "$@"
	cat >&2 <<EOF
Usage: git octo [-hvy] <command> <arguments>

Commands:
  create [-dhl] [-p parent] [-r <reviewer1>[,<reviewer2>...]] \\
                [-s subscriber[,...]] [-t tag[,...]] <commit>|<range>
  diff [-h] <commit>|<range>
  list [-h] <commit>|<range>
  patch [-bcrs] <pull> [<pull> ...]
  stage [-h] [-b branch] <commit>|<range>
  update [-hl] [-m message] <commit>|<range>

See git-octo(1) for details.
EOF
	die
}

cleanup()
{
	local rc=$?

	GH_TOKEN=
	if [ "$OCTO_TMPDIR" ]; then
		rm -fr "$OCTO_TMPDIR" || : cleanup
	fi
	trap - EXIT
	exit $rc
}

xmktemp()
{
	mktemp "$OCTO_TMPDIR/tmp.XXXXXXXXXX" || die
}

if ! have setvar; then
setvar()
{
	[ $# -gt 0 ] || return $SUCCESS
	local __setvar_var_to_set="$1" __setvar_right="$2" __setvar_left=
	case $# in
	1) unset "$__setvar_var_to_set"
	   return $? ;;
	2) : fall through ;;
	*) warn "setvar: too many arguments\n"
	   return $FAILURE
	esac
	case "$__setvar_var_to_set" in *[!0-9A-Za-z_]*)
		warn "setvar: %s: bad variable name\n" "$__setvar_var_to_set"
		return 2
	esac
	while case "$__setvar_r" in *\'*) : ;; *) false ; esac
	do
		__setvar_left="$__setvar_left${__setvar_right%%\'*}'\\''"
		__setvar_right="${__setvar_right#*\'}"
	done
	__setvar_left="$__setvar_left${__setvar_right#*\'}"
	eval "$__setvar_var_to_set='$__setvar_left'"
}
fi

get_bool_config()
{
	local key="$1" default="$2"
	local val

	val=$( git config --bool --get "$key" 2> /dev/null ||
		printf "%s\n" "$default" )
	[ "$val" != false ]
}

git_config()
{
	git config --get "$1" 2> /dev/null
}

prompt()
{
	local resp

	[ "$ASSUME_YES" ] && return $SUCCESS
	printf "\nDoes this look OK? [y/N] "
	read -r resp || return $FAILURE
	case "$resp" in
	[Yy]) return $SUCCESS ;;
	*) return $FAILURE
	esac
}

#
# Copy one scalar JSON value into the named variable. Missing keys and
# non-scalars fail. null becomes an empty value and succeeds.
#
json_get()
{
	local file="$1" path="$2"

	awk -v path="$path" '
	function skipws() {
		while (p <= n) {
			c = substr(s, p, 1)
			if (c != " " && c != "\t" && c != "\n" && c != "\r")
				return
			p++
		}
	}
	function skip_string(    rest, q, b) {
		p++
		while (p <= n) {
			rest = substr(s, p)
			q = index(rest, "\"")
			b = index(rest, "\\")
			if (q == 0)
				return
			if (b == 0 || q < b) {
				p += q
				return
			}
			p += b + 1
		}
	}
	function skip_value(    start, c) {
		start = p
		skipws()
		c = substr(s, p, 1)
		if (c == "\"")
			skip_string()
		else if (c == "{")
			skip_object()
		else if (c == "[")
			skip_array()
		else if (c == "t" || c == "f" || c == "n") {
			while (p <= n && substr(s, p, 1) ~ /[a-z]/)
				p++
		} else if (c ~ /[-0-9]/) {
			while (p <= n && substr(s, p, 1) ~ /[-+0-9.eE]/)
				p++
		}
		if (p <= start)
			p++
	}
	function skip_object(    c) {
		p++
		skipws()
		if (substr(s, p, 1) == "}") {
			p++
			return
		}
		while (p <= n) {
			skipws()
			if (substr(s, p, 1) != "\"")
				return
			skip_string()
			skipws()
			if (substr(s, p, 1) == ":")
				p++
			skip_value()
			skipws()
			c = substr(s, p, 1)
			if (c == ",") {
				p++
				continue
			}
			if (c == "}")
				p++
			return
		}
	}
	function skip_array(    c) {
		p++
		skipws()
		if (substr(s, p, 1) == "]") {
			p++
			return
		}
		while (p <= n) {
			skip_value()
			skipws()
			c = substr(s, p, 1)
			if (c == ",") {
				p++
				continue
			}
			if (c == "]")
				p++
			return
		}
	}
	function hexval(h,    i, c, v, d) {
		v = 0
		for (i = 1; i <= length(h); i++) {
			c = substr(h, i, 1)
			if (c >= "0" && c <= "9")
				d = index("0123456789", c) - 1
			else if (c >= "a" && c <= "f")
				d = index("abcdef", c) + 9
			else if (c >= "A" && c <= "F")
				d = index("ABCDEF", c) + 9
			else
				d = 0
			v = v * 16 + d
		}
		return v
	}
	function utf8(cp) {
		if (cp < 128)
			return sprintf("%c", cp)
		if (cp < 2048)
			return sprintf("%c%c", 192 + int(cp / 64),
				128 + (cp % 64))
		if (cp < 65536)
			return sprintf("%c%c%c",
				224 + int(cp / 4096),
				128 + (int(cp / 64) % 64),
				128 + (cp % 64))
		return "?"
	}
	function parse_string(    rest, q, b, c, out, hex) {
		out = ""
		p++
		while (p <= n) {
			rest = substr(s, p)
			q = index(rest, "\"")
			b = index(rest, "\\")
			if (q == 0)
				return out
			if (b == 0 || q < b) {
				out = out substr(rest, 1, q - 1)
				p += q
				return out
			}
			out = out substr(rest, 1, b - 1)
			c = substr(rest, b + 1, 1)
			p += b + 1
			if (c == "n")
				out = out "\n"
			else if (c == "t")
				out = out "\t"
			else if (c == "r")
				out = out "\r"
			else if (c == "b")
				out = out "\b"
			else if (c == "f")
				out = out "\f"
			else if (c == "u") {
				hex = substr(s, p, 4)
				p += 4
				out = out utf8(hexval(hex))
			} else
				out = out c
		}
		return out
	}
	function emit_value(    c, start, lit) {
		skipws()
		c = substr(s, p, 1)
		if (c == "\"") {
			printf "%s", parse_string()
			return 1
		}
		if (c == "{" || c == "[")
			return 0
		start = p
		if (c == "t" || c == "f" || c == "n") {
			while (p <= n && substr(s, p, 1) ~ /[a-z]/)
				p++
			lit = substr(s, start, p - start)
			if (lit == "null")
				return 1
			printf "%s", lit
			return 1
		}
		if (c ~ /[-0-9]/) {
			while (p <= n && substr(s, p, 1) ~ /[-+0-9.eE]/)
				p++
			printf "%s", substr(s, start, p - start)
			return 1
		}
		return 0
	}
	function extract_object(pi, want,    c, k) {
		p++
		skipws()
		if (substr(s, p, 1) == "}") {
			p++
			return 0
		}
		while (p <= n) {
			skipws()
			if (substr(s, p, 1) != "\"")
				return 0
			k = parse_string()
			skipws()
			if (substr(s, p, 1) != ":")
				return 0
			p++
			if (k == want)
				return extract(pi + 1)
			skip_value()
			skipws()
			c = substr(s, p, 1)
			if (c == ",") {
				p++
				continue
			}
			return 0
		}
		return 0
	}
	function extract_array(pi, want,    c, idx) {
		p++
		idx = 0
		skipws()
		if (substr(s, p, 1) == "]") {
			p++
			return 0
		}
		if (want !~ /^[0-9]+$/)
			return 0
		while (p <= n) {
			if (idx == want + 0)
				return extract(pi + 1)
			skip_value()
			idx++
			skipws()
			c = substr(s, p, 1)
			if (c == ",") {
				p++
				continue
			}
			return 0
		}
		return 0
	}
	function extract(pi,    c, want) {
		if (pi > nseg)
			return emit_value()
		skipws()
		c = substr(s, p, 1)
		want = seg[pi]
		if (c == "{")
			return extract_object(pi, want)
		if (c == "[")
			return extract_array(pi, want)
		return 0
	}
	BEGIN { RS = "\034"; ok = 0 }
	{
		s = $0
		n = length(s)
		p = 1
		nseg = split(path, seg, ".")
		if (nseg < 1)
			exit 1
		if (extract(1))
			ok = 1
	}
	END { if (!ok) exit 1 }
	' "$file"
}

json_escape_stdin()
{
	awk '
	BEGIN {
		for (i = 1; i < 256; i++)
			ord[sprintf("%c", i)] = i
	}
	function jesc(s,    i, c, o, len, code) {
		o = ""
		len = length(s)
		for (i = 1; i <= len; i++) {
			c = substr(s, i, 1)
			if (c == "\\")
				o = o "\\\\"
			else if (c == "\"")
				o = o "\\\""
			else if (c == "\n")
				o = o "\\n"
			else if (c == "\r")
				o = o "\\r"
			else if (c == "\t")
				o = o "\\t"
			else if (c in ord) {
				code = ord[c]
				if (code < 32 || code == 127)
					o = o sprintf("\\u%04x", code)
				else
					o = o c
			} else
				o = o c
		}
		return o
	}
	{
		if (NR == 1)
			s = $0
		else
			s = s "\n" $0
	}
	END { printf "%s", jesc(s) }
	' # END-QUOTE
}

json_escape()
{
	printf "%s\n" "$*" | json_escape_stdin
}

json_escape_file()
{
	json_escape_stdin < "$1"
}

url_encode()
{
	printf "%s\n" "$*" | awk '
	BEGIN {
		for (i = 1; i < 256; i++)
			ord[sprintf("%c", i)] = i
	}
	function uenc(s,    i, c, o, len) {
		o = ""
		len = length(s)
		for (i = 1; i <= len; i++) {
			c = substr(s, i, 1)
			if (c ~ /[A-Za-z0-9._~-]/)
				o = o c
			else if (c in ord)
				o = o sprintf("%%%02X", ord[c])
			else
				o = o "%3F"
		}
		return o
	}
	{
		if (NR == 1)
			s = $0
		else
			s = s "\n" $0
	}
	END { printf "%s", uenc(s) }
	' # END-QUOTE
}

trim()
{
	printf "%s\n" "$*" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

comma_file()
{
	local list="$1" out="$2"
	local rest="$list," item

	:> "$out"
	while [ "$rest" ]; do
		item="${rest%%,*}"
		rest="${rest#*,}"
		item=$( trim "$item" )
		[ "$item" ] || continue
		printf "%s\n" "$item" >> "$out"
	done
}

netrc_token()
{
	local __var_to_set="$1"
	local __file="${NETRC:-$HOME/.netrc}" __tok

	[ -f "$__file" ] || return $FAILURE
	__tok=$( awk -v host="$API_HOST" '
	{
		for (i = 1; i <= NF; i++) {
			if ($i == "machine") {
				i++
				active = ($i == host)
			} else if ($i == "default") {
				active = 1
			} else if ($i == "login" || $i == "account" ||
			    $i == "macdef") {
				i++
			} else if ($i == "password" && active && !found) {
				i++
				print $i
				found = 1
			}
		}
	}
	END { if (!found) exit 1 }
	' "$__file" ) || return $FAILURE
	case "$__tok" in
	\"*\")
		__tok="${__tok#\"}"
		__tok="${__tok%\"}"
		;;
	\'*\')
		__tok="${__tok#\'}"
		__tok="${__tok%\'}"
		;;
	esac
	[ "$__tok" ] || return $FAILURE
	setvar "$__var_to_set" "$__tok"
}

load_token()
{
	local tok

	if [ "$OCTO_TOKEN" ]; then
		GH_TOKEN="$OCTO_TOKEN"
	elif [ "$GH_TOKEN" ]; then
		: ok
	elif [ "$GITHUB_TOKEN" ]; then
		GH_TOKEN="$GITHUB_TOKEN"
	elif tok=$( git_config octo.token ); then
		GH_TOKEN="$tok"
		tok=
	elif have gh && tok=$( gh auth token 2> /dev/null ) &&
	     [ "$tok" ]; then
		GH_TOKEN="$tok"
		tok=
	elif netrc_token tok; then
		GH_TOKEN="$tok"
		tok=
	else
		GH_TOKEN=
	fi
	case "$GH_TOKEN" in
	*[[:space:]]*)
		GH_TOKEN=
		die "GitHub token contains whitespace"
		;;
	esac
}

http_exchange()
{
	local method="$1" path="$2" body="$3" raw="$4"
	local req len sslerr

	req=$( xmktemp )
	sslerr=$( xmktemp )
	len=0
	if [ "$body" ]; then
		len=$(( $( wc -c < "$body" ) ))
	fi
	{
		printf "%s %s HTTP/1.0\r\n" "$method" "$path"
		printf "Host: %s\r\n" "$API_HOST"
		printf "User-Agent: git-octo\r\n"
		printf "Accept: application/vnd.github+json\r\n"
		printf "X-GitHub-Api-Version: 2022-11-28\r\n"
		if [ "$GH_TOKEN" ]; then
			printf "Authorization: Bearer %s\r\n" "$GH_TOKEN"
		fi
		if [ "$body" ]; then
			printf "Content-Type: application/json\r\n"
			printf "Content-Length: %s\r\n" "$len"
		fi
		printf "Connection: close\r\n"
		printf "\r\n"
		if [ "$body" ]; then
			cat "$body"
		fi
	} > "$req"
	[ "$VERBOSE" ] &&
		printf "%s %s\n" "$method" "$path" >&2
	#
	# s_client often exits non-zero after the server closes the
	# connection. The HTTP status line is the success test.
	#
	openssl s_client -quiet -connect "$API_HOST:443" \
		-servername "$API_HOST" -ign_eof \
		-verify_return_error < "$req" > "$raw" 2> "$sslerr" ||
		: s_client status
	:> "$req"
	if ! grep -q '^HTTP/' "$raw"; then
		[ "$VERBOSE" ] && cat "$sslerr" >&2
		die "could not reach %s" "$API_HOST"
	fi
}

http_split()
{
	local __raw="$1" __body="$2" __var_to_set="$3"
	local __status

	if ! __status=$( awk -v body="$__body" '
	BEGIN { RS = "\034" }
	{
		s = $0
		h = index(s, "HTTP/")
		if (h > 1)
			s = substr(s, h)
		p = index(s, "\r\n\r\n")
		if (p == 0) exit 1
		hdr = substr(s, 1, p - 1)
		rest = substr(s, p + 4)
		n = split(hdr, lines, "\r\n")
		split(lines[1], st, " ")
		status = st[2]
		clen = -1
		chunked = 0
		for (i = 2; i <= n; i++) {
			key = tolower(lines[i])
			if (index(key, "content-length:") == 1)
				clen = substr(lines[i], 17) + 0
			if (index(key, "transfer-encoding:") == 1 &&
			    index(key, "chunked") > 0)
				chunked = 1
		}
		if (chunked) exit 2
		if (clen >= 0)
			rest = substr(rest, 1, clen)
		printf "%s", rest > body
		close(body)
		print status
	}
	' "$__raw" ); then
		return $FAILURE
	fi
	setvar "$__var_to_set" "$__status"
}

github_api()
{
	local method="$1" path="$2" body="$3" out="$4"
	local raw

	raw=$( xmktemp )
	:> "$out"
	http_exchange "$method" "$path" "$body" "$raw" || return $FAILURE
	http_split "$raw" "$out" GH_STATUS || return $FAILURE
	case "$GH_STATUS" in
	2[0-9][0-9]) return $SUCCESS ;;
	esac
	return $FAILURE
}

github_message()
{
	local __file="$1" __var_to_set="$2"
	local __msg __extra

	__msg=$( json_get "$__file" message ) || __msg=
	__extra=$( json_get "$__file" errors.0.message ) || __extra=
	if [ "$__extra" ]; then
		if [ "$__msg" ]; then
			__msg="$__msg: $__extra"
		else
			__msg="$__extra"
		fi
	fi
	[ "$__msg" ] || __msg="HTTP $GH_STATUS"
	case "$GH_STATUS" in
	401) __msg="$__msg (check OCTO_TOKEN or octo.token)" ;;
	403|429) __msg="$__msg (rate limited; set OCTO_TOKEN)" ;;
	esac
	setvar "$__var_to_set" "$__msg"
}

github_fail()
{
	local file="$1"
	local msg

	github_message "$file" msg
	die "%s" "$msg"
}

github_slug()
{
	local __github_slug_url="$1" __github_slug_var_to_set="$2"
	local __github_slug_rest __github_slug_owner __github_slug_repo

	case "$__github_slug_url" in
	git@github.com:*)
		__github_slug_rest="${__github_slug_url#git@github.com:}" ;;
	ssh://git@github.com/*)
		__github_slug_rest="${__github_slug_url#ssh://git@github.com/}"
		;;
	https://github.com/*|http://github.com/*)
		__github_slug_rest="${__github_slug_url#*://github.com/}" ;;
	git://github.com/*)
		__github_slug_rest="${__github_slug_url#git://github.com/}" ;;
	*) return $FAILURE
	esac
	__github_slug_rest="${__github_slug_rest%.git}"
	__github_slug_rest="${__github_slug_rest%/}"
	__github_slug_rest="${__github_slug_rest%%\?*}"
	case "$__github_slug_rest" in
	*/*) : ok ;;
	*) return $FAILURE
	esac
	__github_slug_owner="${__github_slug_rest%%/*}"
	__github_slug_repo="${__github_slug_rest#*/}"
	__github_slug_repo="${__github_slug_repo%%/*}"
	[ "$__github_slug_owner" ] && [ "$__github_slug_repo" ] ||
		return $FAILURE
	setvar "$__github_slug_var_to_set" \
		"$__github_slug_owner/$__github_slug_repo"
}

resolve_upstream()
{
	UPSTREAM=$( git_config octo.upstream ) || UPSTREAM=freebsd/freebsd-src
	case "$UPSTREAM" in
	*/*/*|""|/*|*/) die "octo.upstream must be owner/repo" ;;
	*/*) : ok ;;
	*) die "octo.upstream must be owner/repo"
	esac
	BASE=$( git_config octo.base ) || BASE=main
	[ "$BASE" ] || die "octo.base is empty"
}

require_fork()
{
	local repo="${UPSTREAM#*/}"
	local remote url slug kind tmp

	FORK=$( git_config octo.fork ) || FORK=
	PUSH_SPEC=$( git_config octo.pushurl ) || PUSH_SPEC=
	tmp=$( xmktemp )
	git remote -v > "$tmp"
	while read -r remote url kind; do
		github_slug "$url" slug || continue
		if [ ! "$FORK" ] && [ "$slug" != "$UPSTREAM" ]; then
			case "$slug" in
			*/"$repo") FORK="$slug" ;;
			esac
		fi
		if [ "$FORK" ] && [ "$slug" = "$FORK" ] &&
		   [ "$kind" = "(push)" ] && [ ! "$PUSH_SPEC" ]; then
			PUSH_SPEC="$remote"
		fi
	done < "$tmp"
	if [ ! "$FORK" ]; then
		warn "or add a github.com remote for that fork"
		die "set octo.fork to owner/repo of your GitHub fork"
	fi
	case "$FORK" in
	*/*/*|""|/*|*/) die "octo.fork must be owner/repo" ;;
	*/*) : ok ;;
	*) die "octo.fork must be owner/repo"
	esac
	[ "$PUSH_SPEC" ] || PUSH_SPEC="git@github.com:$FORK.git"
}

push_spec_for()
{
	local __repo="$1" __var_to_set="$2"
	local __remote __url __slug __kind __tmp __spec=

	if [ "$__repo" = "$FORK" ] && [ "$PUSH_SPEC" ]; then
		setvar "$__var_to_set" "$PUSH_SPEC"
		return $SUCCESS
	fi
	__tmp=$( xmktemp )
	git remote -v > "$__tmp"
	while read -r __remote __url __kind; do
		github_slug "$__url" __slug || continue
		if [ "$__slug" = "$__repo" ] &&
		   [ "$__kind" = "(push)" ] && [ ! "$__spec" ]; then
			__spec="$__remote"
		fi
	done < "$__tmp"
	[ "$__spec" ] || __spec="git@github.com:$__repo.git"
	setvar "$__var_to_set" "$__spec"
}

show_url()
{
	local url="$1"
	local cmd

	printf "%s\n" "$url"
	[ "$BROWSE" ] || return $SUCCESS
	cmd=$( git_config octo.browser ) || cmd="${BROWSER:-}"
	[ "$cmd" ] || return $SUCCESS
	( eval "$cmd \"\$url\"" > /dev/null 2>&1 & )
}

git_edit()
{
	local file="$1"
	local editor

	editor=$( git var GIT_EDITOR 2> /dev/null ) || editor=vi
	eval "$editor \"\$file\""
}

build_commit_list()
{
	local __var_to_set="$1"
	local __chash __one __all=

	shift # __var_to_set
	for __chash in "$@"; do
		if quietly git cat-file -e "$__chash^{commit}"; then
			__one=$( git rev-parse "$__chash" ) ||
				die "invalid commit ID %s" "$__chash"
		else
			__one=$( git rev-list --reverse "$__chash" ) ||
				die "invalid commit ID %s" "$__chash"
		fi
		[ "$__one" ] || die "invalid commit ID %s" "$__chash"
		if [ "$__all" ]; then
			__all="$__all
$__one"
		else
			__all="$__one"
		fi
	done
	setvar "$__var_to_set" "$__all"
}

show_and_prompt()
{
	local commit="$1"

	git show "$commit"
	prompt
}

#
# git-sh-setup treats a leading -h as help. Source it only after this
# verb's getopts has run, so "create -t -h" is a tag named -h and not
# a usage request.
#
setup()
{
	local git_sh_setup

	have git || die "git is required, install devel/git"
	have openssl || die "openssl is required"
	have awk || die "awk is required"
	have mktemp || die "mktemp is required"

	git_sh_setup=$( git --exec-path )/git-sh-setup
	[ -f "$git_sh_setup" ] || die "cannot find git-sh-setup"
	SUBDIRECTORY_OK=y
	USAGE=
	# shellcheck disable=SC1090
	. "$git_sh_setup"

	if [ "$GIT_EDITOR" ]; then
		EDITOR="$GIT_EDITOR"
	fi
	if [ "$GIT_PAGER" ]; then
		PAGER="$GIT_PAGER"
	fi

	case "$verb" in
	diff|list|patch) : ok ;;
	*) require_clean_work_tree "$verb"
	esac

	if get_bool_config octo.browse false; then
		BROWSE=1
	fi

	umask 077
	OCTO_TMPDIR=$( mktemp -d "${TMPDIR:-/tmp}/git-octo.XXXXXXXX" ) || die
	trap cleanup EXIT HUP INT QUIT TRAP USR1 TERM

	load_token
	resolve_upstream
}

log2pr()
{
	local commit="$1"
	local hit n owner repo rest

	hit=$( git show -s --format=%B "$commit" | sed -nE \
		-e 's/^GitHub PR:[[:space:]]+//' \
		-e 's/[[:space:]]*$//' \
		-e 's#^https://github\.com/##' \
		-e 's#^([^/]+)/([^/]+)/pull/([0-9]+)$#\1 \2 \3#p' )
	[ "$hit" ] || return $FAILURE
	n=$( printf "%s\n" "$hit" | wc -l )
	n=$(( $n ))
	[ "$n" -eq 1 ] || return $FAILURE
	owner="${hit%% *}"
	rest="${hit#* }"
	repo="${rest%% *}"
	PR_NUM="${rest#* }"
	PR_REPO="$owner/$repo"
	return $SUCCESS
}

# Search pages are large. number and title are adjacent, so take
# those pairs with grep instead of walking every JSON string.
search_titles()
{
	awk '
	function hexval(h,    i, c, v, d) {
		v = 0
		for (i = 1; i <= length(h); i++) {
			c = substr(h, i, 1)
			if (c >= "0" && c <= "9")
				d = index("0123456789", c) - 1
			else if (c >= "a" && c <= "f")
				d = index("abcdef", c) + 9
			else if (c >= "A" && c <= "F")
				d = index("ABCDEF", c) + 9
			else
				d = 0
			v = v * 16 + d
		}
		return v
	}
	function utf8(cp) {
		if (cp < 128)
			return sprintf("%c", cp)
		if (cp < 2048)
			return sprintf("%c%c", 192 + int(cp / 64),
				128 + (cp % 64))
		if (cp < 65536)
			return sprintf("%c%c%c",
				224 + int(cp / 4096),
				128 + (int(cp / 64) % 64),
				128 + (cp % 64))
		return "?"
	}
	function unesc(raw,    i, n, c, out, hex) {
		n = length(raw)
		out = ""
		i = 1
		while (i <= n) {
			c = substr(raw, i, 1)
			if (c == "\\") {
				i++
				c = substr(raw, i, 1)
				if (c == "n" || c == "r")
					out = out " "
				else if (c == "t")
					out = out " "
				else if (c == "u") {
					hex = substr(raw, i + 1, 4)
					i += 4
					out = out utf8(hexval(hex))
				} else
					out = out c
			} else
				out = out c
			i++
		}
		gsub(/\034/, "", out)
		return out
	}
	{
		if (!match($0, /^"number":[0-9]+,"title":"/))
			next
		num = substr($0, RSTART + 9, RLENGTH - 19)
		rest = substr($0, RSTART + RLENGTH)
		sub(/"$/, "", rest)
		printf "%s\034%s\n", num, unesc(rest)
	}
	' "$1"
}

title2pr()
{
	local title="$1"
	local q qenc path out hits tsv page rows
	local num t nums count qtitle

	[ "$FORK" ] || require_fork
	PR_COUNT=0
	PR_NUM=
	PR_NUMS=
	PR_REPO="$FORK"
	qtitle=$( printf "%s\n" "$title" | tr '"' ' ' )
	q="repo:$FORK is:pr is:open in:title:\"$qtitle\""
	qenc=$( url_encode "$q" )
	out=$( xmktemp )
	hits=$( xmktemp )
	tsv=$( xmktemp )
	nums=
	count=0
	page=1
	while :; do
		path="/search/issues?q=$qenc&per_page=100&page=$page"
		github_api GET "$path" "" "$out" || github_fail "$out"
		# BSD grep -o. A character walk of this page is too slow.
		grep -oE \
			'"number":[0-9]+,"title":"(\\.|[^"\\])*"' \
			"$out" > "$hits" || :
		search_titles "$hits" > "$tsv"
		while IFS=$( printf '\034' ) read -r num t ||
		      [ "$num" ]; do
			[ "$num" ] || break
			if [ "$t" = "$title" ]; then
				count=$(( $count + 1 ))
				if [ "$nums" ]; then
					nums="$nums, #$num"
				else
					nums="#$num"
				fi
				PR_NUM="$num"
			fi
			num=
		done < "$tsv"
		rows=$( wc -l < "$hits" )
		rows=$(( $rows ))
		[ "$rows" -eq 100 ] || break
		[ "$count" -lt 2 ] || break
		page=$(( $page + 1 ))
		[ "$page" -le 5 ] || break
	done
	PR_COUNT="$count"
	PR_NUMS="$nums"
	if [ "$PR_COUNT" -ne 1 ]; then
		PR_NUM=
	fi
}

commit2pr()
{
	local commit="$1"
	local title

	if log2pr "$commit"; then
		return $SUCCESS
	fi
	title=$( git show -s --format=%s "$commit" )
	title2pr "$title"
	case "$PR_COUNT" in
	0) die "could not find pull request for: %s" "$title" ;;
	1) return $SUCCESS ;;
	*) die "found multiple pull requests with the same title"
	esac
}

pr_get()
{
	PR_JSON=$( xmktemp )
	github_api GET "/repos/$PR_REPO/pulls/$PR_NUM" "" "$PR_JSON" ||
		github_fail "$PR_JSON"
}

pr_print_status()
{
	local title state draft merged label

	pr_get
	title=$( json_get "$PR_JSON" title ) || title=
	state=$( json_get "$PR_JSON" state ) || state=
	draft=$( json_get "$PR_JSON" draft ) || draft=
	merged=$( json_get "$PR_JSON" merged ) || merged=
	if [ "$merged" = true ]; then
		label=Merged
	elif [ "$draft" = true ]; then
		label=Draft
	elif [ "$state" = open ]; then
		label=Open
	elif [ "$state" = closed ]; then
		label=Closed
	else
		label="$state"
	fi
	printf "%-16s  #%s: %s\n" "$label" "$PR_NUM" "$title"
}

branch_from_title()
{
	local __title="$1" __var_to_set="$2"
	local __slug

	__slug=$( printf "%s\n" "$__title" |
		tr '[:upper:]' '[:lower:]' |
		tr -cs 'a-z0-9' '-' |
		sed -e 's/^-//' -e 's/-$//' )
	__slug=$( printf "%s\n" "$__slug" | awk '{ print substr($0, 1, 60) }' )
	__slug="${__slug%-}"
	[ "$__slug" ] || __slug=commit
	setvar "$__var_to_set" "git-octo/$__slug"
}

resolve_pr_arg()
{
	local spec="$1"
	local rest owner repo num

	case "$spec" in
	https://github.com/*/pull/*)
		rest="${spec#https://github.com/}"
		rest="${rest%%\?*}"
		owner="${rest%%/*}"
		rest="${rest#*/}"
		repo="${rest%%/*}"
		rest="${rest#*/}"
		num="${rest#pull/}"
		num="${num%%[^0-9]*}"
		;;
	"#"[0-9]*)
		[ "$FORK" ] || require_fork
		owner="${FORK%%/*}"
		repo="${FORK#*/}"
		num="${spec#"#"}"
		;;
	[0-9]*)
		[ "$FORK" ] || require_fork
		owner="${FORK%%/*}"
		repo="${FORK#*/}"
		num="$spec"
		;;
	*)
		if quietly git cat-file -e "$spec^{commit}"; then
			commit2pr "$spec"
			return $SUCCESS
		fi
		die "invalid pull request: %s" "$spec"
	esac
	case "$num" in
	""|*[!0-9]*) die "invalid pull request: %s" "$spec" ;;
	*) : ok
	esac
	PR_REPO="$owner/$repo"
	PR_NUM="$num"
}

post_comment_file()
{
	local file="$1"
	local json esc out msg

	esc=$( json_escape_file "$file" )
	[ "$esc" ] || return $SUCCESS
	json=$( xmktemp )
	printf '{"body":"%s"}\n' "$esc" > "$json"
	out=$( xmktemp )
	if ! github_api POST \
		"/repos/$PR_REPO/issues/$PR_NUM/comments" \
		"$json" "$out"; then
		github_message "$out" msg
		warn "could not post comment: %s" "$msg"
		return $FAILURE
	fi
	return $SUCCESS
}

request_reviewers()
{
	local file="$1"
	local users teams item json out uj tj msg

	[ -s "$file" ] || return $SUCCESS
	users=$( xmktemp )
	teams=$( xmktemp )
	:> "$users"
	:> "$teams"
	while read -r item; do
		case "$item" in
		"#"*)
			item="${item#"#"}"
			printf "%s\n" "$item" >> "$teams"
			;;
		*/*)
			item="${item#*/}"
			printf "%s\n" "$item" >> "$teams"
			;;
		@*)
			item="${item#@}"
			printf "%s\n" "$item" >> "$users"
			;;
		*)
			printf "%s\n" "$item" >> "$users"
		esac
	done < "$file"
	if [ ! -s "$users" ] && [ ! -s "$teams" ]; then
		return $SUCCESS
	fi
	json_string_array "$users" uj
	json_string_array "$teams" tj
	json=$( xmktemp )
	printf '{"reviewers":%s,"team_reviewers":%s}\n' "$uj" "$tj" > "$json"
	out=$( xmktemp )
	if ! github_api POST \
		"/repos/$PR_REPO/pulls/$PR_NUM/requested_reviewers" \
		"$json" "$out"
	then
		github_message "$out" msg
		warn "could not request reviewers: %s" "$msg"
		return $FAILURE
	fi
	return $SUCCESS
}

request_labels()
{
	local file="$1"
	local json arr out msg

	[ -s "$file" ] || return $SUCCESS
	json_string_array "$file" arr
	json=$( xmktemp )
	printf '{"labels":%s}\n' "$arr" > "$json"
	out=$( xmktemp )
	if ! github_api POST \
		"/repos/$PR_REPO/issues/$PR_NUM/labels" \
		"$json" "$out"
	then
		github_message "$out" msg
		warn "could not set labels: %s" "$msg"
		return $FAILURE
	fi
	return $SUCCESS
}

json_string_array()
{
	local __file="$1" __var_to_set="$2"
	local __item __esc __out= __first=1

	while read -r __item || [ "$__item" ]; do
		[ "$__item" ] || break
		__esc=$( json_escape "$__item" )
		if [ "$__first" ]; then
			__out="\"$__esc\""
			__first=
		else
			__out="$__out,\"$__esc\""
		fi
		__item=
	done < "$__file"
	setvar "$__var_to_set" "[$__out]"
}

write_pr_json()
{
	local file="$1" title="$2" bodyfile="$3"
	local branch="$4" base="$5" draft="$6"
	local et eb ehead ebase

	et=$( json_escape "$title" )
	eb=$( json_escape_file "$bodyfile" )
	ehead=$( json_escape "$branch" )
	ebase=$( json_escape "$base" )
	printf '{\n' > "$file"
	printf '\t"title": "%s",\n' "$et" >> "$file"
	printf '\t"body": "%s",\n' "$eb" >> "$file"
	printf '\t"head": "%s",\n' "$ehead" >> "$file"
	printf '\t"base": "%s",\n' "$ebase" >> "$file"
	printf '\t"draft": %s\n' "$draft" >> "$file"
	printf '}\n' >> "$file"
}

notify_subscribers()
{
	local file="$1"
	local cc= item cfile

	[ -s "$file" ] || return $SUCCESS
	while read -r item; do
		case "$item" in
		@*) : ok ;;
		*) item="@$item"
		esac
		if [ "$cc" ]; then
			cc="$cc $item"
		else
			cc="$item"
		fi
	done < "$file"
	[ "$cc" ] || return $SUCCESS
	cfile=$( xmktemp )
	printf "cc %s\n" "$cc" > "$cfile"
	post_comment_file "$cfile" || : comment is optional
}

# $2 is octo.reviewer text. Set $1 to that entry's GitHub login.
github_login()
{
	local __var_to_set="$1" __name="$2"
	local __cfg __line __key __val __hit __hits= __n=0

	__name="${__name#@}"
	case "$__name" in
	""|"#"*|*/*) return $FAILURE ;;
	esac
	__cfg=$( xmktemp )
	git config --get-regexp '^octo\.reviewer\.' > "$__cfg" 2> /dev/null
	while read -r __line; do
		__key="${__line%% *}"
		__val="${__line#* }"
		[ "$__val" = "$__name" ] || continue
		__hit="${__key#octo.reviewer.}"
		[ "$__hit" ] || continue
		if [ "$__hits" ]; then
			__hits="$__hits $__hit"
		else
			__hits="$__hit"
		fi
		__n=$(( $__n + 1 ))
	done < "$__cfg"
	if [ "$__n" -gt 1 ]; then
		die "%s names more than one GitHub login: %s" \
			"$__name" "$__hits"
	fi
	[ "$__n" -eq 1 ] || return $FAILURE
	setvar "$__var_to_set" "$__hit"
}

map_reviewer_file()
{
	local file="$1"
	local item login out

	out=$( xmktemp )
	while read -r item; do
		case "$item" in
		""|"#"*|*/*)
			[ "$item" ] && printf "%s\n" "$item" >> "$out"
			;;
		*)
			if github_login login "$item"; then
				printf "%s\n" "$login" >> "$out"
			else
				printf "%s\n" "$item" >> "$out"
			fi
		esac
	done < "$file"
	cat "$out" > "$file" || die "could not record reviewer names"
}

create_one()
{
	local commit="$1" reviewers="$2" subscribers="$3"
	local pbase="$4" doprompt="$5" draft="$6" tags="$7"
	local title body branch json out url
	local rfile sfile tfile len draftjson exist

	if [ "$doprompt" ]; then
		show_and_prompt "$commit" || return $FAILURE
	fi
	rfile=$( xmktemp )
	sfile=$( xmktemp )
	comma_file "$reviewers" "$rfile"
	comma_file "$subscribers" "$sfile"
	map_reviewer_file "$rfile"
	map_reviewer_file "$sfile"
	title=$( git show -s --format=%s "$commit" )
	[ "$title" ] || die "commit %s has an empty subject" "$commit"
	if [ "${#title}" -gt 256 ]; then
		die "commit subject is too long for a pull request title"
	fi
	title2pr "$title"
	case "$PR_COUNT" in
	0) : ok ;;
	1) die "pull request already exists for: %s (#%s)" \
		"$title" "$PR_NUM" ;;
	*) die "found multiple pull requests with the same title"
	esac
	branch_from_title "$title" branch
	[ "$pbase" ] || pbase="$BASE"
	exist=$( git ls-remote "$PUSH_SPEC" "refs/heads/$pbase" ) ||
		die "could not list %s on the fork" "$pbase"
	[ "$exist" ] ||
		die "base branch %s does not exist on the fork" "$pbase"
	exist=$( git ls-remote "$PUSH_SPEC" "refs/heads/$branch" ) ||
		die "could not list %s on the fork" "$branch"
	[ ! "$exist" ] || die "branch %s already exists on the fork" "$branch"
	git push "$PUSH_SPEC" "$commit:refs/heads/$branch" ||
		die "could not push %s" "$branch"
	body=$( xmktemp )
	git show -s --format=%b "$commit" > "$body"
	len=$(( $( wc -c < "$body" ) ))
	if [ "$len" -gt 65000 ]; then
		die "commit message is too long for a pull request body"
	fi
	if [ "$draft" -eq 1 ]; then
		draftjson=true
	else
		draftjson=false
	fi
	json=$( xmktemp )
	out=$( xmktemp )
	write_pr_json "$json" "$title" "$body" \
		"$branch" "$pbase" "$draftjson"
	github_api POST "/repos/$FORK/pulls" "$json" "$out" ||
		github_fail "$out"
	PR_NUM=$( json_get "$out" number ) ||
		die "pull request created but number is missing"
	url=$( json_get "$out" html_url ) || url=
	PR_REPO="$FORK"
	PR_HEAD="$branch"
	[ "$url" ] || url="https://github.com/$FORK/pull/$PR_NUM"
	show_url "$url"
	tfile=$( xmktemp )
	comma_file "$tags" "$tfile"
	request_reviewers "$rfile" || : reviewers are optional
	request_labels "$tfile" || : labels are optional
	notify_subscribers "$sfile"
	return $SUCCESS
}

approved_reviewers()
{
	local __var_to_set="$1"
	local __file __i=0 __login __state __flag __mapped __out __name __map

	__file=$( xmktemp )
	github_api GET "/repos/$PR_REPO/pulls/$PR_NUM/reviews" "" \
		"$__file" || github_fail "$__file"
	__map=$( xmktemp )
	:> "$__map"
	while __login=$( json_get "$__file" "$__i.user.login" ); do
		__state=$( json_get "$__file" "$__i.state" ) || __state=
		case "$__state" in
		APPROVED) __flag=1 ;;
		CHANGES_REQUESTED|DISMISSED) __flag=0 ;;
		*)
			__i=$(( $__i + 1 ))
			continue
			;;
		esac
		awk -F "$( printf '\t' )" -v login="$__login" '
			$1 != login { print }
		' "$__map" > "$__map.new"
		printf "%s\t%s\n" "$__login" "$__flag" >> "$__map.new"
		mv "$__map.new" "$__map"
		__i=$(( $__i + 1 ))
	done
	__out=
	while IFS=$( printf '\t' ) read -r __login __flag; do
		[ "$__flag" = 1 ] || continue
		if __mapped=$( git_config "octo.reviewer.$__login" ); then
			__name="$__mapped"
		else
			__name="$__login"
		fi
		if [ "$__out" ]; then
			__out="$__out, $__name"
		else
			__out="$__name"
		fi
	done < "$__map"
	setvar "$__var_to_set" "$__out"
}

author_of_head()
{
	local __var_to_set="$1"
	local __file __sha __name __email __login

	__sha=$( json_get "$PR_JSON" head.sha ) ||
		die "pull request #%s has no head" "$PR_NUM"
	__file=$( xmktemp )
	github_api GET "/repos/$PR_REPO/commits/$__sha" "" "$__file" ||
		github_fail "$__file"
	__name=$( json_get "$__file" commit.author.name ) || __name=
	__email=$( json_get "$__file" commit.author.email ) || __email=
	__login=$( json_get "$__file" author.login ) || __login=
	if [ ! "$__email" ] && [ "$__login" ]; then
		__email="$__login@users.noreply.github.com"
	fi
	if [ ! "$__name" ]; then
		__name="$__login"
	fi
	[ "$__name" ] && [ "$__email" ] ||
		die "could not determine author of #%s" "$PR_NUM"
	setvar "$__var_to_set" "$__name <$__email>"
}

patch_branch()
{
	local base new suffix=1

	if [ $# -eq 1 ]; then
		base="gitocto-$1"
	else
		base=$( printf "gitocto-%s-" "$@" | sed 's/-$//' )
	fi
	new="$base"
	while git show-ref --quiet --branches "$new"; do
		new="${base}_$suffix"
		suffix=$(( $suffix + 1 ))
	done
	git checkout -b "$new"
}

pr_parent()
{
	local __num="$1" __var_to_set="$2"
	local __base __file __qenc __n __owner

	PR_NUM="$__num"
	pr_get
	__base=$( json_get "$PR_JSON" base.ref ) || __base=
	if [ ! "$__base" ] || [ "$__base" = "$BASE" ]; then
		setvar "$__var_to_set" ""
		return $SUCCESS
	fi
	__owner="${PR_REPO%%/*}"
	__file=$( xmktemp )
	__qenc=$( url_encode "$__owner:$__base" )
	github_api GET \
		"/repos/$PR_REPO/pulls?head=$__qenc&state=open" \
		"" "$__file" || github_fail "$__file"
	__n=$( json_get "$__file" 0.number ) || __n=
	if [ ! "$__n" ]; then
		warn "no open pull request for base branch %s" "$__base"
	fi
	setvar "$__var_to_set" "$__n"
}

apply_raw()
{
	local num="$1"
	local sha url diff top

	PR_NUM="$num"
	pr_get
	sha=$( json_get "$PR_JSON" head.sha ) ||
		die "pull request #%s has no head" "$num"
	url="https://github.com/$PR_REPO/commit/$sha.diff"
	diff=$( xmktemp )
	have fetch || die "fetch is required for patch -r"
	fetch -q -o "$diff" "$url" ||
		die "could not download #%s" "$num"
	top=$( git rev-parse --show-toplevel )
	git -C "$top" apply --index --reject "$diff" ||
		die "could not apply #%s" "$num"
}

patch_commit()
{
	local num="$1"
	local tmp title body author reviewers url

	PR_NUM="$num"
	pr_get
	title=$( json_get "$PR_JSON" title ) || title=
	body=$( json_get "$PR_JSON" body ) || body=
	author_of_head author
	approved_reviewers reviewers || reviewers=
	tmp=$( xmktemp )
	printf "%s\n" "$title" > "$tmp"
	if [ "$body" ]; then
		printf "\n%s\n" "$body" >> "$tmp"
	fi
	if [ "$reviewers" ]; then
		printf "Reviewed by:\t%s\n" "$reviewers" >> "$tmp"
	fi
	url="https://github.com/$PR_REPO/pull/$PR_NUM"
	printf "GitHub PR:\t%s\n" "$url" >> "$tmp"
	git commit --author "$author" --file "$tmp"
}

apply_pr()
{
	local num="$1" docommit="$2" raw="$3" stack="$4"
	local parent repo

	case " $SEEN " in
	*" $num "*) return $SUCCESS ;;
	esac
	SEEN="$SEEN $num"
	repo="$PR_REPO"
	PR_NUM="$num"
	PR_REPO="$repo"
	if [ "$stack" = true ]; then
		pr_parent "$num" parent
		if [ "$parent" ]; then
			printf "Applying parent #%s...\n" "$parent"
			PR_REPO="$repo"
			apply_pr "$parent" "$docommit" "$raw" "$stack"
		fi
		PR_NUM="$num"
		PR_REPO="$repo"
	fi
	if [ "$raw" = true ]; then
		apply_raw "$num"
	else
		git fetch --no-tags "https://github.com/$PR_REPO.git" \
			"refs/pull/$num/head" ||
			die "could not fetch #%s" "$num"
		git cherry-pick --no-commit FETCH_HEAD ||
			die "could not apply #%s" "$num"
	fi
	if [ "$docommit" = true ]; then
		PR_NUM="$num"
		PR_REPO="$repo"
		patch_commit "$num"
	fi
}

############################################################ VERBS

gitocto__create()
{
	local OPTIND=1 OPTARG flag
	local list= prev= draft=0 doprompt commits commit
	local reviewers subscribers tags parent

	if get_bool_config octo.list false; then
		list=1
	fi
	while getopts dhlp:r:s:t: flag; do
		case "$flag" in
		d) draft=1 ;;
		l) list=1 ;;
		p) prev="$OPTARG" ;;
		r) reviewers="$OPTARG" ;;
		s) subscribers="$OPTARG" ;;
		t) tags="$OPTARG" ;;
		*) usage # NOTREACHED
		esac
	done
	shift $(( $OPTIND - 1 ))

	[ $# -gt 0 ] || usage "Too few arguments" # NOTREACHED

	setup
	require_fork
	[ "$GH_TOKEN" ] ||
		die "set OCTO_TOKEN or git config octo.token to create"
	if [ "$prev" ]; then
		resolve_pr_arg "$prev"
		pr_get
		parent=$( json_get "$PR_JSON" head.ref ) ||
			die "parent #%s has no head branch" "$PR_NUM"
		[ "$parent" ] || die "parent #%s has no head branch" "$PR_NUM"
	else
		parent=
	fi
	build_commit_list commits "$@"
	doprompt=1
	if [ "$list" ]; then
		for commit in $commits; do
			git --no-pager show --oneline --no-patch "$commit"
		done | git_pager
		prompt || return $SUCCESS
		doprompt=
	fi
	for commit in $commits; do
		if create_one "$commit" "$reviewers" \
		    "$subscribers" "$parent" "$doprompt" \
		    "$draft" "$tags"
	then
			parent="$PR_HEAD"
		else
			parent=
		fi
	done
}

gitocto__diff()
{
	local OPTIND=1 OPTARG flag
	local commits commit short

	while getopts h flag; do
		case "$flag" in
		*) usage # NOTREACHED
		esac
	done
	shift $(( $OPTIND - 1 ))

	setup
	build_commit_list commits "$@"
	for commit in $commits; do
		commit2pr "$commit"
		git fetch --no-tags "https://github.com/$PR_REPO.git" \
			"refs/pull/$PR_NUM/head" ||
			die "could not fetch #%s" "$PR_NUM"
		short=$( git rev-parse --short "$commit" )
		printf "Comparing #%s against %s...\n" \
			"$PR_NUM" "$short" >&2
		git diff FETCH_HEAD "$commit"
	done
}

gitocto__list()
{
	local OPTIND=1 OPTARG flag
	local commits commit chash title

	while getopts h flag; do
		case "$flag" in
		*) usage # NOTREACHED
		esac
	done
	shift $(( $OPTIND - 1 ))

	setup
	build_commit_list commits "$@"
	for commit in $commits; do
		chash=$( git show -s --format='%C(auto)%h' "$commit" )
		printf "%s " "$chash"
		if log2pr "$commit"; then
			pr_print_status
			continue
		fi
		title=$( git show -s --format=%s "$commit" )
		title2pr "$title"
		case "$PR_COUNT" in
		0) printf "%-16s  : %s\n" "No Pull Request" "$title" ;;
		1) pr_print_status ;;
		*) printf "%-16s  : %s\n" "Ambiguous" "$PR_NUMS" ;;
		esac
	done
}

gitocto__patch()
{
	local OPTIND=1 OPTARG flag
	local branch= docommit=false raw=false stack=false
	local list rev repo num

	while getopts bcrsh flag; do
		case "$flag" in
		b) branch=1 ;;
		c) docommit=true ;;
		r) raw=true ;;
		s) stack=true ;;
		*) usage # NOTREACHED
		esac
	done
	shift $(( $OPTIND - 1 ))

	[ $# -gt 0 ] || usage "Too few arguments" # NOTREACHED

	setup
	list=$( xmktemp )
	for rev in "$@"; do
		resolve_pr_arg "$rev"
		printf "%s %s\n" "$PR_REPO" "$PR_NUM" >> "$list"
	done
	if [ "$branch" ]; then
		require_clean_work_tree "patch -b"
		set --
		while read -r repo num; do
			set -- "$@" "$num"
		done < "$list"
		patch_branch "$@"
	fi
	if [ "$docommit" = true ]; then
		require_clean_work_tree "patch -c"
	fi
	SEEN=
	while read -r PR_REPO PR_NUM; do
		printf "Applying #%s...\n" "$PR_NUM"
		apply_pr "$PR_NUM" "$docommit" "$raw" "$stack"
	done < "$list"
}

gitocto__stage()
{
	local OPTIND=1 OPTARG flag
	local branch= commits commit tmp title author
	local reviewers short url

	while getopts b:h flag; do
		case "$flag" in
		b) branch="$OPTARG" ;;
		*) usage # NOTREACHED
		esac
	done
	shift $(( $OPTIND - 1 ))

	[ $# -gt 0 ] || usage "Too few arguments" # NOTREACHED

	setup
	# -b names the branch to check out; octo.base is where it starts.
	[ "$branch" ] || branch="$BASE"
	if [ "$branch" = "$BASE" ]; then
		git checkout -q "$BASE" ||
			die "could not check out %s" "$BASE"
	else
		git checkout -q -b "$branch" "$BASE" ||
			die "could not create %s from %s" "$branch" "$BASE"
	fi
	build_commit_list commits "$@"
	tmp=$( xmktemp )
	for commit in $commits; do
		git show -s --format=%B "$commit" > "$tmp"
		title=$( git show -s --format=%s "$commit" )
		PR_NUM=
		if ! log2pr "$commit"; then
			title2pr "$title"
		fi
		if [ "$PR_NUM" ]; then
			approved_reviewers reviewers || reviewers=
			if [ "$reviewers" ]; then
				if ! grep -q '^Reviewed by:' "$tmp"; then
					printf "Reviewed by:\t%s\n" \
						"$reviewers" >> "$tmp"
				fi
			fi
			if ! grep -q '^GitHub PR:' "$tmp"; then
				url="https://github.com/$PR_REPO"
				url="$url/pull/$PR_NUM"
				printf "GitHub PR:\t%s\n" \
					"$url" >> "$tmp"
			fi
		fi
		author=$( git show -s --format='%an <%ae>' "$commit" )
		if ! git cherry-pick --no-commit "$commit"; then
			short=$( git rev-parse --short "$commit" )
			warn "could not apply %s (wrong order?)" "$short"
			git checkout -f
			break
		fi
		git commit --edit --file "$tmp" --author "$author"
	done
}

gitocto__update()
{
	local OPTIND=1 OPTARG flag
	local list= have_msg= msg= doprompt commits commit
	local ref sha hrepo spec cfile

	if get_bool_config octo.list false; then
		list=1
	fi
	while getopts hlm: flag; do
		case "$flag" in
		l) list=1 ;;
		m) have_msg=1 msg="$OPTARG" ;;
		*) usage # NOTREACHED
		esac
	done
	shift $(( $OPTIND - 1 ))

	[ $# -gt 0 ] || usage "Too few arguments" # NOTREACHED

	setup
	require_fork
	if [ ! "$GH_TOKEN" ]; then
		die "set OCTO_TOKEN or git config octo.token to update"
	fi
	build_commit_list commits "$@"
	doprompt=1
	if [ "$list" ]; then
		for commit in $commits; do
			git --no-pager show --oneline --no-patch "$commit"
		done | git_pager
		prompt || return $SUCCESS
		doprompt=
	fi
	for commit in $commits; do
		commit2pr "$commit"
		if [ "$doprompt" ]; then
			show_and_prompt "$commit" || break
		fi
		pr_get
		ref=$( json_get "$PR_JSON" head.ref ) ||
			die "pull request #%s has no head branch" "$PR_NUM"
		sha=$( json_get "$PR_JSON" head.sha ) ||
			die "pull request #%s has no head" "$PR_NUM"
		hrepo=$( json_get "$PR_JSON" head.repo.full_name ) ||
			hrepo="$FORK"
		push_spec_for "$hrepo" spec
		git push --force-with-lease="refs/heads/$ref:$sha" \
			"$spec" "$commit:refs/heads/$ref" ||
			die "could not update #%s" "$PR_NUM"
		cfile=$( xmktemp )
		if [ "$have_msg" ]; then
			[ "$msg" ] || continue
			printf "%s\n" "$msg" > "$cfile"
		else
			git_edit "$cfile" || die "editor failed"
			[ -s "$cfile" ] || continue
		fi
		post_comment_file "$cfile" || : comment is optional
	done
}

############################################################ MAIN

if get_bool_config octo.assume-yes false; then
	ASSUME_YES=1
fi
if get_bool_config octo.verbose false; then
	VERBOSE=1
fi

while getopts hvy flag; do
	case "$flag" in
	v) VERBOSE=1 ;;
	y) ASSUME_YES=1 ;;
	*) usage # NOTREACHED
	esac
done
shift $(( $OPTIND - 1 ))

[ $# -gt 0 ] || usage "Too few arguments" # NOTREACHED

case "$1" in
create|diff|list|patch|stage|update) : ok ;;
*) usage "Unrecognized sub-command: %s" "$1" # NOTREACHED
esac
verb="$1"
shift # verb

[ $# -gt 0 ] || usage "Too few arguments" # NOTREACHED

gitocto__"$verb" "$@"

################################################################################
# END
################################################################################
