#!/bin/sh -e

BUFFER="#test"
BUFFILE="buffers/#test/messages"
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

NOACT=0

MSGFMT="%9s | %s${ESC}[0m"
NOTICEFMT="${ESC}[7m%9s${ESC}[0m | %s${ESC}[0m"
ACTIONFMT="%9s ${ESC}[3m%s${ESC}[0m"
JOINFMT="            --> %s joined"
PARTFMT="            <-- %s left"
PARTREASONFMT="            <-- %s left: %s"
QUITFMT="            <-- %s quit: %s"

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
	echo "PRIVMSG $BUFFER :$LINEIN" > "$CONTROL"
	echo ":$NICKNAME!.@. PRIVMSG $BUFFER :$LINEIN" >> "$BUFFILE"
}

read_input() {
	inp="$(timeout --foreground 1s dd bs=1 count=1 2>/dev/null || true)"
	if [ -z "$inp" ]; then
		# check for activity in the buffer
		mod="$(stat --printf=%Y "$BUFFILE")"
		if [ "$mod" -ne "$BUFLAST" ]; then
			NOACT=0
			return
		fi

		NOACT=1
		return
	else
		NOACT=0
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

	count=$((ROWS-1))
	tac "$BUFFILE" | format_lines | while read -r _line; do
		if [ "$count" -le 0 ]; then
			break
		fi

		# set line and clear line
		printf "${ESC}[${count};0H${ESC}[2K"
		printf "%s" "$_line"
		count=$((count-1))
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
	if [ "$NOACT" -ne 1 ]; then
		# Redraw only when necessary
		hide_cursor
		draw_buffer
		draw_input
		show_cursor
	fi

	read_input
done
