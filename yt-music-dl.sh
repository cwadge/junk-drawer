#!/usr/bin/env bash
# yt-music-dl — Download purchased YouTube Music content with proper structure
#
# Usage: yt-music-dl [options] <url> [url...]
#
# Requires: yt-dlp, ffmpeg
# Post-tagging: run `beet import <OUTDIR>` to fix release years and track numbers

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
# An empty BROWSER sends no cookies. That's the default because authenticating
# against a music.youtube.com URL costs you the audio: yt-dlp adds the web_music
# client for authenticated music requests, and that client's HTTPS and DASH
# formats sit behind a GVS PO token. Without one, every audio-only stream is
# dropped and only muxed HLS is left, which no audio-only selector matches.
# Public releases need no account, so set BROWSER only for content that does.
BROWSER=""
OUTDIR="$HOME/Music/YouTube"
SLEEP_MIN=1
SLEEP_MAX=5
RETRIES=10
CODEC="m4a"       # remux to M4A by default; use --codec copy for raw stream
DRY_RUN=false
VERBOSE=false
NO_CROP=false
NO_ALBUM_DIR=false
ALBUM_DIR_YEAR=true    # suffix album directories with "(YYYY)" when a release year is known
MINIMAL_TAGS=false     # write only title/artist/album/date/track/genre + cover

# Extra arguments appended verbatim to every yt-dlp invocation, set from the
# config file. Declared here so it always exists as an array. See CONFIG FILE.
declare -a YTDLP_EXTRA=()

# YouTube Music internal API — update these if artist resolution starts failing
YTM_API_KEY="AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"   # baked into YTM web app JS
YTM_CLIENT_VER="1.20231101.01.00"

# ── Colors (suppressed when not a TTY) ───────────────────────────────────────
if [[ -t 2 ]]; then
    RED=$'\033[0;31m' YLW=$'\033[0;33m' GRN=$'\033[0;32m'
    BLU=$'\033[0;34m' RST=$'\033[0m'    BLD=$'\033[1m'
else
    RED='' YLW='' GRN='' BLU='' RST='' BLD=''
fi

# All status output goes to stderr so stdout carries only data (e.g. OLAK URLs
# emitted by resolve_artist), keeping mapfile captures clean.
info() { echo -e "${BLU}[info]${RST}  $*" >&2; }
ok()   { echo -e "${GRN}[ ok ]${RST} $*" >&2; }
warn() { echo -e "${YLW}[warn]${RST}  $*" >&2; }
die()  { echo -e "${RED}[err ]${RST}  $*" >&2; exit 1; }

# ── Signal handling ───────────────────────────────────────────────────────────
# Ctrl+C sends SIGINT to the whole foreground process group, so the current
# child (yt-dlp / curl) is already dying when this trap fires in the parent.
trap 'printf "\n" >&2; warn "Interrupted — stopping."; exit 130' INT TERM

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BLD}yt-music-dl${RST} — Download purchased YouTube Music content

${BLD}USAGE${RST}
  $(basename "$0") [options] <url> [url...]

${BLD}OPTIONS${RST}
  -b, --browser <name>    Browser to pull cookies from (default: none)
                          Any yt-dlp-supported browser: firefox, chrome,
                          chromium, opera, edge, safari, vivaldi, whale, brave
                          Only needed for content behind your account. Public
                          releases fetch fine without it, and cookies actively
                          break audio format selection on music.youtube.com
                          URLs unless a PO token is available (see NOTES)
      --no-cookies        Force cookies off, overriding a BROWSER set in the
                          config file
  -o, --output <dir>      Root output directory (default: ~/Music/YouTube)
                          Tracks land at
                          <dir>/<Artist>/<Album> (<Year>)/<N> - <Title>.<ext>
  -c, --codec <fmt>       Output audio codec/container (default: m4a)
                            m4a   — remux to M4A/AAC; re-encode only if source
                                    isn't AAC (purchased tracks never re-encode)
                            mp3   — re-encode to MP3 V0 VBR (lossy → lossy;
                                    use only if m4a isn't supported by target)
                            opus  — remux to Opus; re-encode only if source
                                    isn't Opus (good for Linux/Android, not cars)
                            flac  — re-encode to FLAC (lossless container;
                                    source is still lossy — bigger, no quality gain)
                            copy  — write the raw stream verbatim, no processing
                                    (may produce .webm on non-purchased content)
      --no-crop           Skip the square thumbnail crop (keep 16:9 padding)
      --no-album-dir      Don't probe the release for a fixed output directory;
                          build the path from each track's own artist/album
                          fields instead (may scatter one album across dirs)
      --no-album-year     Don't append "(YYYY)" to album directory names.
                          Same-titled releases by one artist (self-titled
                          debuts, reissues) will then share a directory
      --minimal-tags      Write only Title, Artist, Album Artist, Album, Date,
                          Track and Genre, plus the cover image. Drops the
                          YouTube description, comment, purl, composer, disc
                          and episode/series fields
  -n, --dry-run           Print what would be downloaded; nothing is fetched
  -v, --verbose           Pass --verbose to yt-dlp (very noisy)
  -h, --help              Show this help and exit

${BLD}CONFIG FILE${RST}
  ${XDG_CONFIG_HOME:-$HOME/.config}/yt-music-dl.conf is sourced if present,
  before argument parsing. CLI flags always take precedence. Format: plain
  shell variable assignments, one per line. Any default can be overridden:

    BROWSER=firefox        # empty (the default) means send no cookies at all
    OUTDIR=/mnt/nas/Music/YouTube
    CODEC=copy             # revert to raw stream if you only use Linux hosts
    NO_CROP=true
    YTM_API_KEY=AIza...    # if the bundled key goes stale
    NO_ALBUM_DIR=true      # revert to per-track artist/album paths
    ALBUM_DIR_YEAR=false   # revert to bare album names, no "(YYYY)" suffix
    MINIMAL_TAGS=true      # strip everything but the core music tags

  YTDLP_EXTRA is a bash array appended verbatim to every yt-dlp call, after
  everything this script builds, so it can also override earlier arguments.
  Use it to reach yt-dlp options this script doesn't expose:

    # force the PO-token-gated formats to be offered anyway (may 403)
    YTDLP_EXTRA=(--extractor-args "youtube:formats=missing_pot")

    # hand yt-dlp a token from a POT provider running elsewhere
    YTDLP_EXTRA=(--extractor-args "youtube:po_token=web_music.gvs+XXXX")

    # throttle harder, or pin a client set
    YTDLP_EXTRA=(--limit-rate 500K --extractor-args "youtube:player_client=default,tv")

${BLD}EXAMPLES${RST}
  # Artist page (all albums — resolved automatically via YouTube Music API)
  $(basename "$0") 'https://music.youtube.com/browse/MPADxxx'

  # Single album
  $(basename "$0") 'https://music.youtube.com/browse/MPREb_xxx'

  # Multiple URLs in one run
  $(basename "$0") 'https://music.youtube.com/browse/MPADxxx' \\
                   'https://music.youtube.com/browse/MPREb_yyy'

  # Firefox cookies, custom output dir
  $(basename "$0") --browser firefox -o /mnt/nas/Music \\
                   'https://music.youtube.com/browse/MPADxxx'

  # Force MP3 for a device that won't handle M4A
  $(basename "$0") --codec mp3 'https://music.youtube.com/browse/MPREb_xxx'

  # Dry-run to preview what would be fetched
  $(basename "$0") --dry-run 'https://music.youtube.com/browse/MPADxxx'

${BLD}NOTES${RST}
  • Cookies are off by default, and turning them on has a cost. When yt-dlp is
    authenticated and the URL is a music.youtube.com one, it appends the
    web_music client unconditionally — the exclusion syntax can't remove it,
    because the append happens after exclusions are processed. That client's
    HTTPS and DASH formats require a GVS PO token, so without one every
    audio-only itag (139/140/249/251) is dropped and only muxed HLS is left.
    An audio-only selector then matches nothing: "Requested format is not
    available". Unauthenticated, yt-dlp uses clients that need no token and
    the full set of audio streams is available. For public releases, cookies
    aren't merely unnecessary — they're what breaks the download.
    For content that does need an account, either run a PO token provider
    plugin (bgutil-ytdlp-pot-provider) and pass the token via YTDLP_EXTRA, or
    use a Premium subscription, which waives the token requirement. Failing
    both, the muxed fallback described under --codec keeps the run alive.
  • Artist pages (MPAD* URLs) are not handled by yt-dlp directly. This script
    detects them and resolves each album/single/EP to an OLAK playlist URL by
    calling the YouTube Music internal browse API (curl + jq), then feeds those
    to yt-dlp one by one. No Python required; no authentication needed for
    public artist/album enumeration.
    If resolution fails, update YTM_API_KEY/YTM_CLIENT_VER in the defaults.
  • Default (--codec m4a) remuxes to M4A without re-encoding when the source
    is AAC — which purchased YouTube Music tracks always are. The result plays
    on virtually everything: car stereos, dedicated media players, phones, etc.
    Use --codec copy to skip all processing and write whatever container yt-dlp
    pulls natively; on non-purchased content this is often .webm (Opus), which
    many devices won't play and which can't have thumbnails embedded.
  • --codec mp3/flac always re-encodes. MP3 is lossy→lossy degradation from
    AAC; FLAC is a lossless container around a lossy source. Both exist for
    device/software compatibility only, not quality.
  • Re-runs are idempotent: --no-overwrites skips any track whose output file
    already exists. The filesystem is the state — no external tracking file.
  • Every track from a single album/playlist URL lands in one directory. The
    release is probed once (first track) for album artist + album title, and
    that pair is used verbatim for the whole release, so featured artists or
    per-track album variants ("Deluxe", "B-Sides") can't split it up. Use
    --no-album-dir to go back to per-track path fields.
  • Album directories carry a "(YYYY)" suffix so that same-titled releases by
    one artist stay apart — a self-titled debut and its self-titled successor
    a decade later would otherwise collapse into one directory, and any track
    whose filename collided would be silently skipped by --no-overwrites. Only
    a real release_year is used; when YouTube Music doesn't supply one the
    suffix is omitted rather than filled in from the upload date, which would
    bake a wrong year into the path. --no-album-year turns this off (note that
    switching conventions on an existing library makes every album re-download
    into a parallel directory, since the old paths no longer match).
  • --minimal-tags drops the fields FFmpegMetadataPP writes that aren't music
    metadata — most usefully the YouTube description and the webpage URL that
    lands in 'comment'. It works by setting each unwanted meta_* field empty,
    which makes the postprocessor skip it; no extra ffmpeg pass is involved.
    'album_artist' is deliberately kept: without it, compilations and
    guest-heavy albums split by track artist in players that key on it.
    ffmpeg still stamps its own 'encoder' tag; add
    --ppa "Metadata:-fflags +bitexact" if you want that gone as well.
  • There is no original-release-date here to use. yt-dlp exposes only
    release_year/release_date, and YouTube Music has no notion of a release
    group, so a 2005 reissue of a 1980 record reports 2005. Only MusicBrainz
    knows the difference; set 'original_date: yes' in beets, or put
    \$original_year in its path format, and let the import be the authority.
    The year here is for keeping releases in separate directories, a job the
    original date can't do — two editions of one album share it.
  • Track numbers: upstream metadata wins when it's present and non-zero. In
    practice YouTube Music almost never provides it, so the number is derived
    — from a leading number in the title ("03 - Foo", "3. Foo"), else from the
    playlist position. A separator after the digits is required, so
    "99 Luftballons" and "1979" survive intact. When the title does carry a
    number it's stripped from the title tag, since the filename already
    prefixes it.
  • Release years from YouTube Music are often wrong (upload date, not release
    date). Run 'beet import <OUTDIR>' after downloading to fix tags via
    MusicBrainz. Picard (GUI) is the alternative.
  • If --ppa thumbnail cropping fails on your yt-dlp version, pass --no-crop
    and square the art manually: ffmpeg -i cover.jpg -vf crop=ih:ih:(iw-ih)/2:0 out.jpg
EOF
}

# ── Config file ───────────────────────────────────────────────────────────────
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/yt-music-dl.conf"
# shellcheck source=/dev/null
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# ── Argument parsing ──────────────────────────────────────────────────────────
URLS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -b|--browser)  BROWSER="${2:?'--browser requires a value'}"; shift 2 ;;
        --no-cookies)  BROWSER=""; shift ;;
        -o|--output)   OUTDIR="${2:?'--output requires a value'}";   shift 2 ;;
        -c|--codec)    CODEC="${2:?'--codec requires a value'}";     shift 2 ;;
        --no-crop)     NO_CROP=true;  shift ;;
        --no-album-dir) NO_ALBUM_DIR=true; shift ;;
        --no-album-year) ALBUM_DIR_YEAR=false; shift ;;
        --minimal-tags) MINIMAL_TAGS=true; shift ;;
        -n|--dry-run)  DRY_RUN=true;  shift ;;
        -v|--verbose)  VERBOSE=true;  shift ;;
        -h|--help)     usage; exit 0 ;;
        -*)            die "Unknown option: '$1'\nRun '$(basename "$0") --help' for usage." ;;
        *)             URLS+=("$1"); shift ;;
    esac
done

[[ ${#URLS[@]} -gt 0 ]] || { usage; exit 1; }

# ── Dependency check ──────────────────────────────────────────────────────────
missing=()
for cmd in yt-dlp ffmpeg curl jq; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
done
[[ ${#missing[@]} -eq 0 ]] || die "Missing required tools: ${missing[*]}"

# ── Build yt-dlp argument array ───────────────────────────────────────────────
#
# The filename portion is per-track; the directory portion is decided per
# release (see album_dir below) and prepended in the run loop, so -o is not
# part of the shared argument array.
#
#   track_number → playlist_index  (position in playlist, zero-padded to 2)
#
TRACK_TMPL="%(track_number,playlist_index|00)02d - %(title)s.%(ext)s"

# Fallback path used when the album probe fails or --no-album-dir is set:
#   artist → uploader   (channel name if artist tag missing)
#   album  → playlist   (playlist title as album name)
LOOSE_TMPL="${OUTDIR}/%(artist,uploader)s/%(album,playlist)s/${TRACK_TMPL}"

# Auth. An empty BROWSER sends no cookies; see the note on authentication and
# audio formats in the defaults block. The album probe reuses this array so both
# halves of a run present the same identity to YouTube.
COOKIE_ARGS=()
[[ -n "$BROWSER" ]] && COOKIE_ARGS=(--cookies-from-browser "$BROWSER")

YTDLP_ARGS=(
    ${COOKIE_ARGS[@]+"${COOKIE_ARGS[@]}"}

    # Resilience — don't abort the whole artist on one bad track
    --ignore-errors
    --retries          "$RETRIES"
    --fragment-retries "$RETRIES"

    # Art & tags
    --embed-thumbnail
    --convert-thumbnails jpg
    --add-metadata
    # Prefer release_year if yt-dlp has it; fall back to upload_date
    --parse-metadata "%(release_year,upload_date)s:%(meta_date)s"

    # Track number, in order of preference:
    #   1. Upstream track_number, when present and non-zero
    #   2. A leading number in the title ("03 - Foo"), stripped from the title
    #   3. Position in the playlist
    # YouTube Music functionally never supplies (1), so (2)/(3) carry nearly
    # every download — but upstream still wins when it's actually there.
    # FFmpegMetadataPP maps track_number → the 'track' tag on its own, so
    # setting the field here populates both the tag and the filename.
    #
    # Step 1: lift a leading number out of the title into a scratch field. The
    # separator after the digits is mandatory, or "99 Luftballons" and "1979"
    # would lose their leading number. YTM sets 'track' alongside 'title' when
    # it has real music metadata; strip both so the tag and filename agree.
    # Both captures sit inside one optional group, so a title without a number
    # matches empty and sets nothing — no "Could not interpret" line per track,
    # and no risk of writing the literal 'NA' back when the field is absent.
    --parse-metadata "title:^\s*(?:(?P<titletrack>\d{1,3})\s*[-–—.):]\s*(?P<title>\S.*)$)?"
    --parse-metadata "track:^\s*(?:(?P<titletrack>\d{1,3})\s*[-–—.):]\s*(?P<track>\S.*)$)?"
    #
    # Step 2: take the first non-zero candidate. Missing fields default to 0,
    # so a source reporting track 0 counts as no answer rather than as a real
    # number. If every candidate is 0 the regex doesn't match and track_number
    # is left alone — correct for a standalone single with no playlist.
    --parse-metadata "%(track_number|0)s|%(titletrack|0)s|%(playlist_index|0)s:^(?:0*\|)*0*(?P<track_number>[1-9]\d*)"

    # Idempotency — skip tracks whose output file already exists
    --no-overwrites

    # Politeness — random sleep between tracks to avoid rate-limiting
    --sleep-interval     "$SLEEP_MIN"
    --max-sleep-interval "$SLEEP_MAX"

    # Treat artist pages and playlists as full collections
    --yes-playlist
)

# ── Minimal tag set ───────────────────────────────────────────────────────────
#
# FFmpegMetadataPP writes more than music metadata: the full YouTube
# description (as both description and synopsis), the watch URL (as both purl
# and comment), plus series/episode fields that mean nothing for an album.
# Setting a meta_* field to the empty string makes the postprocessor skip it,
# so the unwanted tags are never written in the first place — no second pass,
# no re-embedding of cover art.
#
# Fields the PP derives in pairs are listed by both names, since which one it
# checks for an override depends on how the pair is declared internally.
if $MINIMAL_TAGS; then
    for _field in description synopsis comment purl composer \
                  disc show season_number episode_id episode_sort language; do
        YTDLP_ARGS+=(--parse-metadata ":(?P<meta_${_field}>)")
    done
    unset _field
fi

# ── Codec / format selection ───────────────────────────────────────────────────
#
# 'best': select audio-only stream and write it verbatim — no ffmpeg involved,
#         no re-encode. --extract-audio is intentionally omitted; it would
#         trigger a post-processor pass even when the codec arg is 'copy'.
#
# All other codecs: provide a format selector that prefers a matching source
#         stream (avoiding unnecessary transcode), then --extract-audio with
#         --audio-format to remux/re-encode into the target container.
#
#
# Selectors that end in --extract-audio close with a muxed fallback,
# 'best*[acodec!=none]'. It sits last, so it's reached only when no audio-only
# stream matched — which happens when the audio-only formats are PO-token gated
# and only muxed HLS is on offer. Pulling ~128k AAC out of a 360p container and
# throwing away the video beats failing the whole release. It's a floor, not a
# preference. --codec copy has no fallback: a muxed stream written verbatim is
# a video file, not a track.
#
MUXED_FALLBACK="best*[acodec!=none]"

case "$CODEC" in
    m4a)
        # Prefer a native AAC/M4A source; re-encode only if unavoidable.
        # Purchased tracks are always AAC — this remuxes without touching audio.
        YTDLP_ARGS+=(
            -f "bestaudio[ext=m4a]/bestaudio[acodec=aac]/bestaudio/${MUXED_FALLBACK}"
            --extract-audio --audio-format m4a --audio-quality 0
        )
        ;;
    mp3)
        # Always re-encodes — lossy → lossy. Use only for device compatibility.
        YTDLP_ARGS+=(
            -f "bestaudio/${MUXED_FALLBACK}"
            --extract-audio --audio-format mp3 --audio-quality 0
        )
        ;;
    opus)
        # Prefer a native Opus/WebM source; re-encode only if unavoidable.
        YTDLP_ARGS+=(
            -f "bestaudio[ext=webm]/bestaudio[acodec=opus]/bestaudio/${MUXED_FALLBACK}"
            --extract-audio --audio-format opus --audio-quality 0
        )
        ;;
    flac)
        # Always re-encodes — lossless container around a lossy source.
        # Larger files with no quality gain; useful for pipeline compatibility.
        YTDLP_ARGS+=(
            -f "bestaudio/${MUXED_FALLBACK}"
            --extract-audio --audio-format flac
        )
        ;;
    copy)
        # Write the raw stream verbatim — no ffmpeg, no container change.
        # --extract-audio intentionally omitted; it triggers a postprocessor
        # pass even with codec=copy. On non-purchased content this often yields
        # .webm (Opus), which won't embed thumbnails and has poor device support.
        YTDLP_ARGS+=(-f bestaudio)
        ;;
    *)
        die "Unknown codec: '${CODEC}'. Valid options: m4a, mp3, opus, flac, copy"
        ;;
esac

# Square thumbnail crop: hook into ThumbnailsConvertor (which runs before
# EmbedThumbnail) so the thumbnail file is cropped on disk before it gets
# embedded. ffmpeg_o adds output-side args to the conversion ffmpeg call.
# crop=ih:ih:(iw-ih)/2:0 — out_w=ih, out_h=ih, x=centred, y=0 (top).
# Requires --convert-thumbnails (already set above) to trigger the convertor.
if ! $NO_CROP; then
    YTDLP_ARGS+=(--ppa "ThumbnailsConvertor+ffmpeg_o:-vf crop=ih:ih:(iw-ih)/2:0")
fi

$VERBOSE  && YTDLP_ARGS+=(--verbose)

# In dry-run mode: simulate without downloading and print resolved output paths.
# 'filename' is the fully resolved path, so it reflects the per-release
# directory without having to restate the output template here.
if $DRY_RUN; then
    YTDLP_ARGS+=(--simulate --print filename)
fi

# Config-supplied arguments go last so they override anything built above.
YTDLP_ARGS+=(${YTDLP_EXTRA[@]+"${YTDLP_EXTRA[@]}"})

# ── Artist URL resolver ───────────────────────────────────────────────────────
#
# yt-dlp cannot resolve YouTube Music artist pages (browse/MPAD*) to playlists.
# We call the YouTube Music internal browse API directly with curl, then use jq
# to walk the response tree — no Python required.
#
# Two-step resolution:
#   1. Artist page (MPAD*) → album browse IDs (MPREb_*) via recursive jq descent
#   2. Each album page  (MPREb*) → OLAK playlist ID via recursive jq descent
#
# No authentication needed for public artist/album enumeration. YTM_API_KEY is
# the public key baked into the YouTube Music web app JS; update it in the
# defaults block above if requests start returning 403s.

# POST to the YouTube Music browse API; print raw JSON response.
_ytm_browse() {
    local browse_id="$1"
    local payload
    # Build payload with printf to avoid heredoc indentation/quoting issues
    payload=$(printf \
        '{"browseId":"%s","context":{"client":{"clientName":"WEB_REMIX","clientVersion":"%s","hl":"en"}}}' \
        "$browse_id" "$YTM_CLIENT_VER")

    curl -s --fail \
        "https://music.youtube.com/youtubei/v1/browse?key=${YTM_API_KEY}&prettyPrint=false" \
        -H "Content-Type: application/json" \
        -H "X-YouTube-Client-Name: 67" \
        -H "X-YouTube-Client-Version: ${YTM_CLIENT_VER}" \
        -H "Origin: https://music.youtube.com" \
        -H "Referer: https://music.youtube.com/" \
        -d "$payload"
}

resolve_artist() {
    local browse_id
    browse_id="${1##*/browse/}"    # strip URL prefix → MPADUCxxxxxxx

    info "Fetching artist page for ${browse_id}..."
    local artist_json
    artist_json=$(_ytm_browse "$browse_id") || {
        warn "API request failed for ${browse_id} — check YTM_API_KEY or try again"
        return 1
    }

    # Recursively find all album browse IDs (MPREb_*) anywhere in the response.
    # Artist pages embed these in shelf/carousel shelf renderers; unique[] dedupes.
    local -a album_ids
    mapfile -t album_ids < <(
        jq -r '[.. | .browseEndpoint?.browseId? // empty | select(startswith("MPREb_"))] | unique[]' \
            <<< "$artist_json"
    )

    if [[ ${#album_ids[@]} -eq 0 ]]; then
        warn "No releases found for ${browse_id}"
        warn "The API key may be stale, or this artist page requires sign-in"
        return 1
    fi

    info "Found ${#album_ids[@]} release(s) — resolving to playlist IDs..."

    # For each album, fetch its page and extract the OLAK5uy_* playlist ID.
    # OLAK strings appear in watch/play navigation endpoints throughout the page.
    local album_json pid
    for abid in "${album_ids[@]}"; do
        album_json=$(_ytm_browse "$abid") || { warn "API request failed for ${abid} — skipping"; continue; }
        pid=$(jq -r '[.. | strings | select(startswith("OLAK5uy_"))] | first // empty' <<< "$album_json")
        if [[ -n "$pid" ]]; then
            echo "https://music.youtube.com/playlist?list=${pid}"
        else
            warn "Could not resolve playlist ID for ${abid} — skipping"
        fi
    done
}

# ── Release directory probe ───────────────────────────────────────────────────
#
# Per-track fields aren't stable within a release: a guest spot changes
# %(artist)s ("X feat. Y"), and edition/variant suffixes can change %(album)s
# from one track to the next. Using them in the path scatters one album across
# several directories. Instead, resolve the release once from its first track
# and use that pair as literal path components for every track in it.

# Make a string safe as a single path component and as literal output-template
# text. Slashes would create spurious directories; a bare % would be read as a
# template field; trailing dots/spaces are hostile on SMB and FAT targets.
_sanitize() {
    local s="$1"
    s="${s//\//-}"
    s="${s//$'\n'/ }"
    s="${s//$'\t'/ }"
    s="${s//%/%%}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    while [[ "$s" == *[.\ ] ]]; do s="${s%[.\ ]}"; done
    printf '%s' "$s"
}

# Print "<album artist>\t<album title>\t<release year>" for a playlist/album
# URL, or fail. The year field may be empty; upload_date is deliberately not a
# fallback for it, since a wrong year in a directory name outlives a wrong tag.
# --ignore-no-formats-error keeps the probe honest about its own job: only the
# metadata matters here, so a release with no selectable format still yields a
# directory name. Without it the probe applies yt-dlp's default selector and
# succeeds on formats the download would reject, reporting a release that then
# fails on every track.
album_dir() {
    local url="$1" line
    line=$(yt-dlp ${COOKIE_ARGS[@]+"${COOKIE_ARGS[@]}"} \
                  --ignore-no-formats-error \
                  --playlist-items 1 --skip-download --no-warnings \
                  --print "%(album_artist,artist,playlist_uploader,uploader|)s"$'\t'"%(album,playlist_title,playlist|)s"$'\t'"%(release_year|)s" \
                  "$url" 2>/dev/null | head -n1) || return 1
    [[ -n "$line" ]] || return 1
    printf '%s' "$line"
}

# ── Run ───────────────────────────────────────────────────────────────────────
info "Output dir : ${OUTDIR}"
info "Cookies    : ${BROWSER:-none}"
info "Codec      : ${CODEC}"
info "URLs       : ${#URLS[@]}"
[[ ${#YTDLP_EXTRA[@]} -gt 0 ]] && info "Extra args : ${YTDLP_EXTRA[*]}"
$NO_CROP  && warn "Thumbnail crop disabled — art will be 16:9 padded"
$MINIMAL_TAGS && info "Tags       : minimal (title/artist/albumartist/album/date/track/genre + cover)"
$DRY_RUN  && warn "DRY RUN — nothing will be downloaded"

# Cookies plus a music.youtube.com URL is the combination that loses the
# audio-only formats, so flag it before the first track rather than after the
# last failure. A token or an explicit opt-in to the gated formats in
# YTDLP_EXTRA means the caller has already handled it; stay quiet then.
if [[ -n "$BROWSER" && "${URLS[*]}" == *music.youtube.com* \
      && "${YTDLP_EXTRA[*]-}" != *po_token* && "${YTDLP_EXTRA[*]-}" != *missing_pot* ]]; then
    warn "Cookies + music.youtube.com — web_music formats are PO-token gated"
    warn "If tracks fail with 'Requested format is not available', retry with --no-cookies"
fi
echo

ERRORS=0
for url in "${URLS[@]}"; do
    # Artist pages (browse/MPAD*) can't be resolved by yt-dlp; expand them to
    # individual album/single/EP playlist URLs via the YouTube Music browse API.
    if [[ "$url" =~ music\.youtube\.com/browse/MPAD ]]; then
        info "Artist URL detected — resolving releases..."
        mapfile -t targets < <(resolve_artist "$url")
        if [[ ${#targets[@]} -eq 0 ]]; then
            warn "No releases resolved for: ${url} — skipping"
            (( ERRORS++ )) || true
            continue
        fi
        info "Resolved ${#targets[@]} release(s)"
        echo
    else
        targets=("$url")
    fi

    for target in "${targets[@]}"; do
        info "Fetching: ${target}"

        # Decide this release's directory before handing the URL to yt-dlp.
        tmpl="$LOOSE_TMPL"
        if ! $NO_ALBUM_DIR; then
            if probe=$(album_dir "$target"); then
                IFS=$'\t' read -r p_artist p_album p_year <<< "$probe"
                dir_artist=$(_sanitize "$p_artist")
                dir_album=$(_sanitize "$p_album")
                if [[ -n "$dir_artist" && -n "$dir_album" ]]; then
                    # Suffix after sanitizing, so trailing-dot trimming can't
                    # eat the parens; a non-four-digit year counts as absent.
                    if $ALBUM_DIR_YEAR && [[ "$p_year" =~ ^[0-9]{4}$ ]]; then
                        dir_album="${dir_album} (${p_year})"
                    fi
                    tmpl="${OUTDIR}/${dir_artist}/${dir_album}/${TRACK_TMPL}"
                    info "Release    : ${dir_artist} / ${dir_album}"
                else
                    warn "Release metadata incomplete — using per-track paths"
                fi
            else
                warn "Could not probe release metadata — using per-track paths"
            fi
        fi

        if yt-dlp "${YTDLP_ARGS[@]}" -o "$tmpl" "$target"; then
            ok "Finished: ${target}"
        else
            warn "Completed with errors: ${target}"
            (( ERRORS++ )) || true
        fi
        echo
    done
done

if [[ $ERRORS -gt 0 ]]; then
    warn "${ERRORS} URL(s) completed with errors — check output above"
    exit 1
fi
ok "All done."
