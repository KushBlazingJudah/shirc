#!/bin/sh -e

# PoC frontend in POSIX sh.
# Uses even more dirty hacks, performs terribly even on a modern system.
# Probably could be improved but it's a proof of concept.
#
# If I ever say I'm writing a graphical application in shell again, please hit me with a brick.
# Also word wrapping is awful. I don't want to do that again.

BUFFER=${BUFFER?no buffer}
BUFFILE="buffers/$BUFFER/messages"
NICKNAME="${NICKNAME:-$(whoami)}"
CONTROL="./control"

LINEIN=""
LINEPOS=0

cleanup() {
	stty -raw
	stty echo

	# disable alternative buffer
	printf "${ESC}[?1049l"

	show_cursor
}
trap cleanup EXIT INT HUP

ESC="$(printf "\033")"
BS="$(printf "\177")"
BS2="$(printf "\010")"
RET="$(printf "\015")"
CTRLC="$(printf "\003")"
CR="$(printf '\015')"
C1="$(printf '\001')"

ACT=0

# ^A hack: prevents read from stripping spaces
WRAPPREFIX="                  "
MSGFMT="%9s | %s${ESC}[0m"
NOTICEFMT="${ESC}[7m%9s${ESC}[0m | %s${ESC}[0m"
ACTIONFMT="%9s ${ESC}[3m%s${ESC}[0m"
JOINFMT="            ${ESC}[3;32m--> ${ESC}[0;1m%s${ESC}[0;3m joined${ESC}[0m"
PARTFMT="            ${ESC}[3;31m<-- ${ESC}[0;1m%s${ESC}[0;3m left${ESC}[0m"
PARTREASONFMT="            ${ESC}[3;31m<-- ${ESC}[0;1m%s${ESC}[0;3m left: %s${ESC}[0m"
QUITFMT="            ${ESC}[3;31m<-- ${ESC}[0;1m%s${ESC}[0;3m quit: %s${ESC}[0m"

# Get a nickname from a prefix.
prefix_get_nick() {
	case "$1" in
		:*!*@*)
			# nick, user, host
			_tmp="${1%%!*}"
			printf "%s" "${_tmp#:}"
			;;
		*)
			return 1
			;;
	esac
}

timehhmm() {
	date +%H:%m "$@"
}

sendmsg() {
	ACT=0
	echo "PRIVMSG $BUFFER :$LINEIN" > "$CONTROL"
	echo ":$NICKNAME!.@. PRIVMSG $BUFFER :$LINEIN" >> "$BUFFILE"
}

read_input() {
	inp="$(timeout --foreground 1s dd bs=1 count=1 2>/dev/null || true)"
	if [ -z "$inp" ]; then
		# check for activity in the buffer
		mod="$(stat --printf=%Y "$BUFFILE")"
		if [ "$mod" -ne "$BUFLAST" ]; then
			ACT=3 # redraw buffer
			return
		fi

		ACT=1 # draw nothing
		return
	else
		ACT=2 # draw input
	fi

	if [ "$inp" = "$CTRLC" ]; then
		exit
	fi

	case "$inp" in
		"$ESC")
			read_escape
			;;
		"$CTRLC")
			exit
			;;
		"$RET")
			sendmsg
			LINEIN=""
			LINEPOS=0
			;;
		"$BS"|"$BS2")
			if [ "${#LINEIN}" -eq 0 ]; then
				return
			fi

			if [ "$LINEPOS" -eq 0 ]; then
				# do nothing
				return
			elif [ "$LINEPOS" -eq "${#LINEIN}" ]; then
				if [ "$((LINEPOS-1))" -eq 0 ]; then
					LINEIN=""
				else
					LINEIN="$(printf '%s' "$LINEIN" | cut -c 1-$((${#LINEIN}-1)) 2>/dev/null)"
				fi

				LINEPOS=$((LINEPOS-1))
			else
				# lies in between start and end
				LEFT="$(printf '%s' "$LINEIN" | cut -c 1-$((LINEPOS-1)))"
				RIGHT="$(printf '%s' "$LINEIN" | cut -c $((LINEPOS+1))-${#LINEIN})"
				LINEIN="$LEFT$RIGHT"
				LINEPOS=$((LINEPOS-1))
			fi
			;;
		*)
			LINEIN="$LINEIN$inp"
			LINEPOS=$((LINEPOS+1))
			;;
	esac
}

linewrap() {
	# NOTE: WRAPPREFIX contains unprintable characters.
	# that's why we subtract one
	wrapat=$((COLS-${#WRAPPREFIX}-1))
	while read -r line; do
		# this is horribly ugly and most likely won't work with control chars
		printf '%s\n' "$(printf '%s' "$line" | cut -c -"$COLS")"

		printf '%s\n' "$line" | cut -c $((COLS+1))- | fold -s -w "$wrapat" | while read -r linef; do
			if [ -z "$linef" ]; then continue; fi
			printf '%s%s\n' "$WRAPPREFIX" "$linef"
		done
	done
}

read_escape() {
	# TODO: word navigation and ctrl-backspace

	inp="$(dd bs=1 count=1 2>/dev/null)"
	if [ -z "$inp" ] || [ "$inp" != "[" ]; then
		return # we don't care
	fi

	inp="$(dd bs=1 count=1 2>/dev/null)"
	case "$inp" in
		1)	# home
			LINEPOS=0
			# consume ~
			dd bs=1 count=1 >/dev/null 2>&1
			;;
		3)	# delete
			if [ "$LINEPOS" -ne "${#LINEIN}" ] || [ "$LINEPOS" -ne 0 ]; then
				LEFT="$(printf '%s' "$LINEIN" | cut -c 1-$((LINEPOS)))"
				if [ "$((LINEPOS+2))" -gt "${#LINEIN}" ]; then
					RIGHT=""
				else
					RIGHT="$(printf '%s' "$LINEIN" | cut -c $((LINEPOS+2))-${#LINEIN})"
				fi
				LINEIN="$LEFT$RIGHT"
			fi
			# consume ~
			dd bs=1 count=1 >/dev/null 2>&1
			;;
		4)	# end
			LINEPOS="${#LINEIN}"
			# consume ~
			dd bs=1 count=1 >/dev/null 2>&1
			;;
		A)	# up arrow
			# ignore
			;;
		B)	# down arrow
			# ignore
			;;
		C)	# right arrow
			# move right on line editor
			LINEPOS=$((LINEPOS+1))
			if [ "$LINEPOS" -gt "${#LINEIN}" ]; then
				LINEPOS="${#LINEIN}"
			fi
			;;
		D)	# left arrow
			# move left on line editor
			LINEPOS=$((LINEPOS-1))
			if [ "$LINEPOS" -lt 0 ]; then
				LINEPOS=0
			fi
			;;
		*)
			return
	esac
}

draw_input() {
	# move to bottom & clear cursor
	printf "${ESC}[${ROWS};0H${ESC}[2K"

	# draw
	PREFIX="[$BUFFER] "
	printf "%s%s" "$PREFIX" "$LINEIN"

	# REMEMBER TO UPDATE THIS WHEN MESSING WITH THE PREFIX.
	printf "${ESC}[$((${#PREFIX}+$LINEPOS+1))G"
}

format_lines() {
	while read -r line; do
		# split it up
		line="${line%%"$CR"}"
		prefix="${line%% *}"
		nick="$(prefix_get_nick "$prefix")"

		tokens="${line#:* }"
		command="${tokens%% *}"
		args="${tokens##"$command" }"
		trailing="${tokens#* :}" # HACK: really shouldn't do this but makes life easier

		if [ -z "$trailing" ]; then
			# use last argument
			trailing="${args##* }"
		fi

		# TODO: word wrap

		case "$command" in
			PRIVMSG)
				# TODO: CTCP ACTION
				printf "$(timehhmm) $MSGFMT\n" "$nick" "$trailing"
				;;
			NOTICE)
				printf "$(timehhmm) $NOTICEFMT\n" "$nick" "$trailing"
				;;
			JOIN)
				printf "$(timehhmm) $JOINFMT\n" "$nick"
				;;
			PART)
				if [ -z "$trailing" ]; then
					printf "$(timehhmm) $PARTFMT\n" "$nick"
				else
					printf "$(timehhmm) $PARTREASONFMT\n" "$nick" "$trailing"
				fi
				;;
			QUIT)
				printf "$(timehhmm) $QUITFMT" "$nick" "$trailing"
				;;
			*)
				printf "%s\n" "$line"
				;;
		esac
	done
}


draw_buffer() {
	# could've been done better but i'm lazy
	# scrollback shouldn't be too terrible to implement if you want to try
	BUFLAST="$(stat --printf=%Y "$BUFFILE")"

	# this is godawful but works
	# we will never need more than ROWS-1 rows, as if none of those wrap we will be displaying ROWS-1 lines
	# we tail again because we won't ever display more than ROWS-1 lines, and we may have more if some lines wrapped
	count=1
	tail -n "$((ROWS-1))" "$BUFFILE" | format_lines | linewrap | tail -n "$((ROWS-1))" | while read -r _line; do
		# set line and clear line
		printf "${ESC}[${count};0H${ESC}[2K"
		printf "%s" "$_line"

		count=$((count+1))
		if [ "$count" -gt $((ROWS)) ]; then
			break
		fi
	done
}

hide_cursor() {
	printf "${ESC}[?25l"
}

show_cursor() {
	printf "${ESC}[?25h"
}

# enable raw, timeout, alt buffer
stty raw
stty time 1
stty -echo
printf "${ESC}[?1049h"

# get lines
_size="$(stty size)"
ROWS="${_size% *}"
COLS="${_size#* }"

while true; do
	if [ "$ACT" -eq 0 ]; then
		# Full redraw
		hide_cursor
		draw_buffer
		draw_input
		show_cursor
		# 1 is no draw
	elif [ "$ACT" -eq 2 ]; then
		# 2 is just input
		hide_cursor
		draw_input
		show_cursor
	elif [ "$ACT" -eq 3 ]; then
		# 3 is just buffer
		printf "${ESC}[s" # save cursor
		hide_cursor
		draw_buffer
		printf "${ESC}[u" # restore cursor
		show_cursor
	fi

	read_input
done
