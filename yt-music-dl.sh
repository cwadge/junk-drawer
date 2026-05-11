#!/usr/bin/env bash
# yt-music-dl — Download purchased YouTube Music content with proper structure
#
# Usage: yt-music-dl [options] <url> [url...]
#
# Requires: yt-dlp, ffmpeg
# Post-tagging: run `beet import <OUTDIR>` to fix release years and track numbers

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
BROWSER="brave"
OUTDIR="$HOME/Music/YouTube"
SLEEP_MIN=1
SLEEP_MAX=5
RETRIES=10
CODEC="m4a"       # remux to M4A by default; use --codec copy for raw stream
DRY_RUN=false
VERBOSE=false
NO_CROP=false

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
  -b, --browser <name>    Browser to pull cookies from (default: brave)
                          Any yt-dlp-supported browser: firefox, chrome,
                          chromium, opera, edge, safari, vivaldi, whale
  -o, --output <dir>      Root output directory (default: ~/Music/YouTube)
                          Tracks land at <dir>/<Artist>/<Album>/<N> - <Title>.<ext>
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
  -n, --dry-run           Print what would be downloaded; nothing is fetched
  -v, --verbose           Pass --verbose to yt-dlp (very noisy)
  -h, --help              Show this help and exit

${BLD}CONFIG FILE${RST}
  ${XDG_CONFIG_HOME:-$HOME/.config}/yt-music-dl.conf is sourced if present,
  before argument parsing. CLI flags always take precedence. Format: plain
  shell variable assignments, one per line. Any default can be overridden:

    BROWSER=firefox
    OUTDIR=/mnt/nas/Music/YouTube
    CODEC=copy             # revert to raw stream if you only use Linux hosts
    NO_CROP=true
    YTM_API_KEY=AIza...    # if the bundled key goes stale

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
        -o|--output)   OUTDIR="${2:?'--output requires a value'}";   shift 2 ;;
        -c|--codec)    CODEC="${2:?'--codec requires a value'}";     shift 2 ;;
        --no-crop)     NO_CROP=true;  shift ;;
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
# Output template fallback chains:
#   artist      → uploader        (channel name if artist tag missing)
#   album       → playlist        (playlist title as album name)
#   track_number → playlist_index  (position in playlist, zero-padded to 2)
#
OUTPUT_TMPL="${OUTDIR}/%(artist,uploader)s/%(album,playlist)s/%(track_number,playlist_index|00)02d - %(title)s.%(ext)s"

YTDLP_ARGS=(
    # Auth
    --cookies-from-browser "$BROWSER"

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

    # Idempotency — skip tracks whose output file already exists
    --no-overwrites

    # Politeness — random sleep between tracks to avoid rate-limiting
    --sleep-interval     "$SLEEP_MIN"
    --max-sleep-interval "$SLEEP_MAX"

    # Treat artist pages and playlists as full collections
    --yes-playlist

    # Output path
    -o "$OUTPUT_TMPL"
)

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
case "$CODEC" in
    m4a)
        # Prefer a native AAC/M4A source; re-encode only if unavoidable.
        # Purchased tracks are always AAC — this remuxes without touching audio.
        YTDLP_ARGS+=(
            -f "bestaudio[ext=m4a]/bestaudio[acodec=aac]/bestaudio"
            --extract-audio --audio-format m4a --audio-quality 0
        )
        ;;
    mp3)
        # Always re-encodes — lossy → lossy. Use only for device compatibility.
        YTDLP_ARGS+=(
            -f bestaudio
            --extract-audio --audio-format mp3 --audio-quality 0
        )
        ;;
    opus)
        # Prefer a native Opus/WebM source; re-encode only if unavoidable.
        YTDLP_ARGS+=(
            -f "bestaudio[ext=webm]/bestaudio[acodec=opus]/bestaudio"
            --extract-audio --audio-format opus --audio-quality 0
        )
        ;;
    flac)
        # Always re-encodes — lossless container around a lossy source.
        # Larger files with no quality gain; useful for pipeline compatibility.
        YTDLP_ARGS+=(
            -f bestaudio
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

# In dry-run mode: simulate without downloading and print resolved output paths
if $DRY_RUN; then
    YTDLP_ARGS+=(
        --simulate
        --print "%(artist,uploader)s/%(album,playlist)s/%(track_number,playlist_index|00)02d - %(title)s.%(ext)s"
    )
fi

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

# ── Run ───────────────────────────────────────────────────────────────────────
info "Output dir : ${OUTDIR}"
info "Browser    : ${BROWSER}"
info "Codec      : ${CODEC}"
info "URLs       : ${#URLS[@]}"
$NO_CROP  && warn "Thumbnail crop disabled — art will be 16:9 padded"
$DRY_RUN  && warn "DRY RUN — nothing will be downloaded"
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
        if yt-dlp "${YTDLP_ARGS[@]}" "$target"; then
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
