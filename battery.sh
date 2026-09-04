#!/bin/zsh
# battery.sh — behavior battery for the lanes-016 port (mirrors zlane's).
# Runs entirely in a scratch dir; never touches ~/.local/bin or the real
# ~/Library/Application Support/zigup config (ZIGUP_SETTINGS redirects).
set -u

BIN_SRC="${1:-/Users/alex/claude/zigfork/zigup/zig-out/bin/zigup}"
S=$(mktemp -d /tmp/zigup-battery.XXXXXX)
export ZIGUP_SETTINGS="$S/settings"
FAILS=0

note() { print -r -- "-- $*" }
check() {
  local name="$1" want="$2" got="$3"
  if [[ "$got" == *"$want"* ]]; then
    print -r -- "ok   $name"
  else
    FAILS=$((FAILS+1))
    print -r -- "FAIL $name: wanted [$want] got [$got]"
  fi
}

# --- fixtures: two fake lanes whose `zig version` differ, one broken dir
mkdir -p "$S/laneA" "$S/laneB" "$S/broken" "$S/bin"
printf '#!/bin/sh\necho "laneA-1.0.0"\n' > "$S/laneA/zig";  chmod +x "$S/laneA/zig"
printf '#!/bin/sh\necho "laneB-2.0.0"\n' > "$S/laneB/zig";  chmod +x "$S/laneB/zig"

cp "$BIN_SRC" "$S/bin/zigup"
ZIGUP="$S/bin/zigup"

# register lanes (also validates the set path)
"$ZIGUP" lane set laneA "$S/laneA" >/dev/null
"$ZIGUP" lane set laneB "$S/laneB" >/dev/null

# install shims next to the scratch binary
"$ZIGUP" lane shim >/dev/null

note "lane list shows both lanes"
check "lane list" "laneA" "$("$ZIGUP" lane list)"

# --- 1. project-first: .ziglane beats $ZIGUP_LANE
mkdir -p "$S/proj"
cd "$S/proj"
print -r -- "laneB" > .ziglane
ZIGUP_LANE=laneA "$S/bin/zig" version > "$S/out1" 2>&1
check ".ziglane beats env" "laneB-2.0.0" "$(cat "$S/out1")"

# ancestor walk: pin in parent dir applies in child
mkdir -p "$S/proj/sub/deep"
ZIGUP_LANE=laneA "$S/bin/zig" version > "$S/out1b" 2>&1
check "ancestor .ziglane walk" "laneB-2.0.0" "$(cat "$S/out1b")"

# --- 2. env pin (no .ziglane)
cd "$S"
ZIGUP_LANE=laneA "$S/bin/zig" version > "$S/out2" 2>&1
check "env pin" "laneA-1.0.0" "$(cat "$S/out2")"

# --- 3. broken pins are HARD errors, never substitutions
cd "$S/proj"
print -r -- "nosuchlane" > .ziglane
ZIGUP_LANE=laneA "$S/bin/zig" version > "$S/out3" 2>&1; rc3=$?
check "broken .ziglane errors" "refusing to substitute another compiler" "$(cat "$S/out3")"
[[ $rc3 -ne 0 ]] && print -r -- "ok   broken .ziglane nonzero exit ($rc3)" || { print -r -- "FAIL broken .ziglane rc=0"; FAILS=$((FAILS+1)); }
check "broken pin names the fix" "lane set nosuchlane <dir>" "$(cat "$S/out3")"
rm .ziglane

# broken via env
cd "$S"
ZIGUP_LANE=nosuchlane "$S/bin/zig" version > "$S/out3b" 2>&1; rc3b=$?
check "broken env pin errors" "refusing to substitute another compiler" "$(cat "$S/out3b")"
[[ $rc3b -ne 0 ]] && print -r -- "ok   broken env pin nonzero exit ($rc3b)" || { print -r -- "FAIL broken env pin rc=0"; FAILS=$((FAILS+1)); }

# registered lane with no zig executable = broken pin too
"$ZIGUP" lane set broken "$S/broken" >/dev/null 2>&1 && print -r -- "FAIL set accepted dir without zig" && FAILS=$((FAILS+1))
ZIGUP_LANE=broken "$S/bin/zig" version > "$S/out3c" 2>&1; rc3c=$?
check "lane dir without zig errors" "refusing to substitute another compiler" "$(cat "$S/out3c")"
[[ $rc3c -ne 0 ]] && print -r -- "ok   lane-without-zig nonzero exit" || { print -r -- "FAIL lane-without-zig rc=0"; FAILS=$((FAILS+1)); }

# --- 4. $ZIGUP_LANE=path forces PATH
# PATH with a real zig ahead: use laneA dir as the "PATH zig"
ZIGUP_LANE=path PATH="$S/laneA" "$S/bin/zig" version > "$S/out4" 2>&1
check "ZIGUP_LANE=path" "laneA-1.0.0" "$(cat "$S/out4")"

# --- 5. no pin at all -> PATH (not a machine-wide guess)
unset ZIGUP_LANE
PATH="$S/laneB" "$S/bin/zig" version > "$S/out5" 2>&1
check "no-pin PATH fallback" "laneB-2.0.0" "$(cat "$S/out5")"

# PATH search skips the shim's own directory
PATH="$S/bin:$S/laneA" "$S/bin/zig" version > "$S/out5b" 2>&1
check "PATH skips shim dir" "laneA-1.0.0" "$(cat "$S/out5b")"

# trailing separators and quotes in PATH entries
PATH="\"$S/laneB\":" "$S/bin/zig" version > "$S/out5c" 2>&1
check "PATH quote/sep trim" "laneB-2.0.0" "$(cat "$S/out5c")"

# --- 6. loop guard: fires when argv0 lies (self-exclusion fails) and the
# only zig on PATH is ourselves
mkdir -p "$S/other"
cp "$BIN_SRC" "$S/other/zig"
ZIGUP_LANE= PATH="$S/bin" "$S/other/zig" version > "$S/out6" 2>&1; rc6=$?
check "loop guard fires" "PATH fallback loop detected" "$(cat "$S/out6")"
[[ $rc6 -ne 0 ]] && print -r -- "ok   loop guard nonzero exit" || { print -r -- "FAIL loop guard rc=0"; FAILS=$((FAILS+1)); }
# and with a derivable argv0, self-exclusion (not the guard) handles it:
ZIGUP_LANE= PATH="$S/bin" "$S/bin/zig" version > "$S/out6b" 2>&1; rc6b=$?
check "self-dir excluded from fallback" "no lane resolved and no zig found on PATH" "$(cat "$S/out6b")"
[[ $rc6b -ne 0 ]] && print -r -- "ok   self-exclusion nonzero exit" || { print -r -- "FAIL self-exclusion rc=0"; FAILS=$((FAILS+1)); }

# --- 7. lane-named shims run exactly that lane (`lane shim` installs
# `zig` + bare lane names; zig_-prefixed shims are plain copies)
cp "$BIN_SRC" "$S/bin/zig_laneA"
"$S/bin/zig_laneA" version > "$S/out7" 2>&1
check "zig_<lane> shim" "laneA-1.0.0" "$(cat "$S/out7")"
cp "$BIN_SRC" "$S/bin/laneB"
"$S/bin/laneB" version > "$S/out7b" 2>&1
check "<lane> shim" "laneB-2.0.0" "$(cat "$S/out7b")"
# broken lane-named shim = hard error
cp "$BIN_SRC" "$S/bin/zig_broken"
"$S/bin/zig_broken" version > "$S/out7c" 2>&1; rc7c=$?
check "broken lane-named shim errors" "is not configured" "$(cat "$S/out7c")"
[[ $rc7c -ne 0 ]] && print -r -- "ok   broken lane-named shim nonzero exit" || { print -r -- "FAIL broken lane-named shim rc=0"; FAILS=$((FAILS+1)); }
# a REGISTERED lane whose dir lost its zig = "no zig executable" hard error
printf 'broken=%s\n' "$S/broken" >> "$ZIGUP_SETTINGS/lanes"
"$S/bin/zig_broken" version > "$S/out7e" 2>&1; rc7e=$?
check "registered broken lane shim errors" "has no zig executable" "$(cat "$S/out7e")"
[[ $rc7e -ne 0 ]] && print -r -- "ok   registered-broken shim nonzero exit" || { print -r -- "FAIL registered-broken shim rc=0"; FAILS=$((FAILS+1)); }

# unknown lane-named shim = hard error (zigup answers only zigup/zlane as CLI)
cp "$BIN_SRC" "$S/bin/zzz_unknown"
"$S/bin/zzz_unknown" version > "$S/out7d" 2>&1; rc7d=$?
check "unknown shim name errors" "not configured" "$(cat "$S/out7d")"
[[ $rc7d -ne 0 ]] && print -r -- "ok   unknown shim nonzero exit" || { print -r -- "FAIL unknown shim rc=0"; FAILS=$((FAILS+1)); }

# --- 8. which/path introspection
cd "$S"
check "which env pin" "laneA" "$(ZIGUP_LANE=laneA "$ZIGUP" which)"
check "path prints exe only" "$S/laneA/zig" "$(ZIGUP_LANE=laneA "$ZIGUP" path)"
ZIGUP_LANE=nosuch "$ZIGUP" which > "$S/out8" 2>&1; rc8=$?
check "which broken pin" "HARD ERROR" "$(cat "$S/out8")"
[[ $rc8 -ne 0 ]] && print -r -- "ok   which broken pin nonzero exit" || { print -r -- "FAIL which broken rc=0"; FAILS=$((FAILS+1)); }

# --- 9. `zigup lane run` acts as the zig shim; top-level `run` is stock
ZIGUP_LANE=laneA "$ZIGUP" lane run version > "$S/out9" 2>&1
check "zigup lane run = zig shim" "laneA-1.0.0" "$(cat "$S/out9")"
ZIGUP_LANE=laneA "$ZIGUP" run doesnotexist version > "$S/out9b" 2>&1; rc9b=$?
check "stock zigup run errors on unknown version" "fetch it first with: zigup fetch doesnotexist" "$(cat "$S/out9b")"
[[ $rc9b -ne 0 ]] && print -r -- "ok   stock run nonzero exit" || { print -r -- "FAIL stock run rc=0"; FAILS=$((FAILS+1)); }

# --- 10. legacy default lane is ignored by resolution
"$ZIGUP" lane default laneB > "$S/out10" 2>&1
check "default deprecated notice" "DEPRECATED" "$(cat "$S/out10")"
PATH="$S/laneA" "$S/bin/zig" version > "$S/out10b" 2>&1
check "default lane not in chain (uses PATH, not the legacy default)" "laneA-1.0.0" "$(cat "$S/out10b")"
# careful: with no PATH zig and no pin, this must fail (no machine-wide guess)
PATH="" ZIGUP_LANE= "$S/bin/zig" version > "$S/out10c" 2>&1; rc10c=$?
check "no default guessing" "no lane resolved and no zig found on PATH" "$(cat "$S/out10c")"
[[ $rc10c -ne 0 ]] && print -r -- "ok   no-guess nonzero exit" || { print -r -- "FAIL no-guess rc=0"; FAILS=$((FAILS+1)); }

# --- 11. help branding
"$ZIGUP" lane help > "$S/out11" 2>&1 || true
"$ZIGUP" lane > "$S/out11" 2>&1 || true
check "usage branded zigup" "zigup — the zig lane resolver" "$(cat "$S/out11")"
check "usage run alias" "lane run [args...]" "$(cat "$S/out11")"
"$ZIGUP" --help > "$S/out11b" 2>&1
check "main help mentions lanes" ".ziglane" "$(cat "$S/out11b")"

print -r -- "== scratch: $S"
if [[ $FAILS -eq 0 ]]; then
  print -r -- "battery: ALL PASS"
else
  print -r -- "battery: $FAILS FAIL(S)"
  exit 1
fi
