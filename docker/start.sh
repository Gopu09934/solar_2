#!/bin/bash
set -euo pipefail

#############################################
# Validate Environment Variables
#############################################
if [ -z "${VIDEO_URL:-}" ]; then
    echo "ERROR: VIDEO_URL is not set"
    exit 1
fi
if [ -z "${YOUTUBE_STREAM_KEY:-}" ]; then
    echo "ERROR: YOUTUBE_STREAM_KEY is not set"
    exit 1
fi
if [ -z "${AUDIO_URL:-}" ]; then
    echo "ERROR: AUDIO_URL is not set"
    echo "The video sources have no audio track, so AUDIO_URL (one or more"
    echo "background music/ambience files) is required. Same format as"
    echo "VIDEO_URL — comma-separated for multiple tracks: url1,url2,url3"
    exit 1
fi

# Subscriber count + live viewer count are optional — if the API creds
# aren't provided, those panel elements just stay blank instead of
# failing the whole stream.
SHOW_STATS=true
if [ -z "${YOUTUBE_API_KEY:-}" ] || [ -z "${YOUTUBE_CHANNEL_ID:-}" ]; then
    echo "NOTICE: YOUTUBE_API_KEY / YOUTUBE_CHANNEL_ID not set — subscriber/viewer stats will be hidden."
    SHOW_STATS=false
fi

echo "========================================"
echo "Starting 24/7 YouTube Stream (Sun / SDO Overlay)"
echo "Output Resolution : 1280x720 (720p — sized for a 2-core CI runner)"
echo "FPS               : 30"
echo "========================================"

FONT="font.ttf"
GOLD="0xE8A33D"
RED="0xE8453C"
ASSET_DIR="panel_assets"
INFO_FILE="solar_info.txt"
SLOT=6            # seconds each headline is shown
FACT_SLOT=8       # seconds each fun fact is shown
TICKER_SPEED=110  # pixels/second for the bottom ticker scroll
CHANNEL_NAME="Solar Watch Live"
SHADOW="shadowcolor=black@0.6:shadowx=1:shadowy=1"
HEADLINE_FONTSIZE=21
HEADLINE_LINE_SPACING=9
HEADLINE_LINE_H=$((HEADLINE_FONTSIZE + HEADLINE_LINE_SPACING))
FACT_FONTSIZE=16
FACT_LINE_SPACING=7
FACT_LINE_H=$((FACT_FONTSIZE + FACT_LINE_SPACING))

# ---------------------------------------------------------------
# Layout: the Sun stays centered and full-height. A dedicated
# panel sits on EACH side (left = story/headlines, right = live
# stats + instrument info + fun facts), instead of the single
# left-hand panel drawn over the video in the original design.
# Because nothing now overlaps the video, panels can use a solid
# background instead of a semi-transparent one over footage.
# ---------------------------------------------------------------
PANEL_W=333          # width of each side panel
CENTER_X0=$PANEL_W                     # left edge of the video strip
CENTER_W=$((1280 - PANEL_W * 2))       # width of the video strip (614)
RIGHT_X0=$((1280 - PANEL_W))           # left edge of the right panel (947)
TEXT_INSET=33                          # left panel text left-inset
RTEXT_INSET=$((RIGHT_X0 + 33))         # right panel text left-inset
PANEL_TEXT_W=$((PANEL_W - 66))         # usable text width inside a panel

# Don't show "N watching now" until the live viewer count reaches this
# many — a very low number (e.g. "5 watching") reads worse to a new
# visitor than showing nothing at all. Raise/lower to taste.
VIEWER_MIN_TO_SHOW=10


#############################################
# Auto-restart on failure
#############################################
MAX_RETRIES=5       # per-video retry attempts before moving on
RETRY_DELAY=5        # seconds between retries

mkdir -p "$ASSET_DIR"

#############################################
# Background audio (one or more tracks, looped)
#
# The source video has no audio, so shared
# music/ambience tracks are downloaded ONCE here
# (same comma-separated format as VIDEO_URL) and
# rotated across videos — each video picks the
# next track in the list and loops it locally
# (via -stream_loop -1) for its own duration.
# Because each video is streamed by its own
# separate ffmpeg process (see run_video), a
# track always restarts from its beginning at
# the start of whichever video it's assigned to,
# rather than playing as one continuous playhead
# across the whole 24 hours.
#
# Downloaded once (not re-fetched per video) so
# a flaky/slow AUDIO_URL host can't stall video
# transitions, and so -stream_loop is looping
# local files instead of repeatedly re-requesting
# a remote URL every time it repeats.
#############################################
IFS=',' read -ra RAW_AUDIO_URLS <<< "$AUDIO_URL"
AUDIO_LOCAL_FILES=()
audio_i=0
for au in "${RAW_AUDIO_URLS[@]}"; do
    au="${au#"${au%%[![:space:]]*}"}"
    au="${au%"${au##*[![:space:]]}"}"
    [ -z "$au" ] && continue
    audio_i=$((audio_i + 1))
    dest="bg_audio_track_${audio_i}"
    echo "Downloading background audio track ${audio_i}..."
    if curl -sL --fail -o "$dest" "$au" && [ -s "$dest" ]; then
        AUDIO_LOCAL_FILES+=("$dest")
        echo "  OK ($(du -h "$dest" | cut -f1))"
    else
        echo "  WARNING: failed to download track ${audio_i} — skipping it."
    fi
done

NUM_AUDIO=${#AUDIO_LOCAL_FILES[@]}
AUDIO_AVAILABLE=false
if [ "$NUM_AUDIO" -gt 0 ]; then
    AUDIO_AVAILABLE=true
    echo "Loaded $NUM_AUDIO background audio track(s); rotating across videos."
else
    echo "WARNING: no background audio tracks downloaded — stream will run with silent audio instead."
fi
AUDIO_COUNTER=0   # persists across the whole run; advances one track per video

#############################################
# Generate the coordinate-label marker dot once
# at startup: a small transparent PNG with a
# gold-filled center and white ring, matching
# the panel's gold accent color. Used by
# build_labels_chain() as ffmpeg input index 2.
# Always generated (cheap, one frame, 20x20) —
# harmless/unused by ffmpeg on videos that don't
# have a matching .labels.txt file.
#############################################
DOT_MARKER="dot_marker.png"
GOLD_R=232; GOLD_G=163; GOLD_B=61
DOT_VF="format=rgba,geq=r=(if(lte(hypot(X-10\,Y-10)\,5)\,${GOLD_R}\,if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))):g=(if(lte(hypot(X-10\,Y-10)\,5)\,${GOLD_G}\,if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))):b=(if(lte(hypot(X-10\,Y-10)\,5)\,${GOLD_B}\,if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))):a=(if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))"
ffmpeg -y -f lavfi -i "color=c=black@0.0:s=20x20" -vf "$DOT_VF" -frames:v 1 "$DOT_MARKER" -loglevel error
if [ ! -s "$DOT_MARKER" ]; then
    # Guarantee the file always exists and is a valid PNG, even in the
    # unlikely case the geq-based generation above fails — this is what
    # gets passed to ffmpeg as a real input on every stream start, so it
    # must never be missing. Falls back to an invisible 1x1 transparent
    # pixel (labels would render without a visible dot, but the stream
    # itself keeps running instead of crashing on a missing input file).
    echo "WARNING: geq-based marker generation failed — using a blank 1x1 fallback."
    echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=" | base64 -d > "$DOT_MARKER"
fi

#############################################
# Trending-event image (left panel), downloaded
# ONCE at startup — e.g. a picture for the Aug 12,
# 2026 total solar eclipse callout.
#
# Optional: set EVENT_IMAGE_URL to a direct image
# link. If it's unset or the download fails, the
# TRENDING NOW block still renders with text only
# (no picture, no crash) — see prepare_video_content.
#############################################
EVENT_IMAGE="event_image.jpg"
EVENT_IMAGE_AVAILABLE=false
if [ -n "${EVENT_IMAGE_URL:-}" ]; then
    echo "Downloading trending-event image..."
    if curl -sL --fail -o "$EVENT_IMAGE" "$EVENT_IMAGE_URL" && [ -s "$EVENT_IMAGE" ]; then
        EVENT_IMAGE_AVAILABLE=true
        echo "  OK ($(du -h "$EVENT_IMAGE" | cut -f1))"
    else
        echo "  WARNING: failed to download EVENT_IMAGE_URL — TRENDING NOW block will show text only."
    fi
else
    echo "NOTICE: EVENT_IMAGE_URL not set — TRENDING NOW block will show text only."
fi

#############################################
# Live "time until totality" countdown writer.
# Pure local date-math — no API needed, unlike
# the subs/viewers writers. Target is the moment
# of greatest eclipse for the Aug 12, 2026 total
# solar eclipse: 17:47:06 UTC.
# Updates every 30s; ffmpeg re-reads the file via
# reload=1 (same pattern as clock.txt / subs.txt).
# Once the target has passed, switches the panel
# to a "LIVE NOW" message instead of going negative.
#############################################
EVENT_COUNTDOWN_TARGET_EPOCH=$(date -u -d "2026-08-12 17:47:06" +%s)
printf ' ' > "$ASSET_DIR/countdown.txt"
(
    while true; do
        NOW_EPOCH=$(date -u +%s)
        REMAIN=$((EVENT_COUNTDOWN_TARGET_EPOCH - NOW_EPOCH))
        if [ "$REMAIN" -le 0 ]; then
            printf 'TOTALITY IS LIVE NOW' > "$ASSET_DIR/countdown.txt.tmp"
        else
            CD_DAYS=$((REMAIN / 86400))
            CD_HOURS=$(((REMAIN % 86400) / 3600))
            CD_MINS=$(((REMAIN % 3600) / 60))
            printf '%dD  %02dH  %02dM LEFT' "$CD_DAYS" "$CD_HOURS" "$CD_MINS" > "$ASSET_DIR/countdown.txt.tmp"
        fi
        mv -f "$ASSET_DIR/countdown.txt.tmp" "$ASSET_DIR/countdown.txt"
        sleep 30
    done
) &
COUNTDOWN_PID=$!

#############################################
# Background clock writer (avoids fragile
# drawtext %{gmtime} expansion syntax)
#############################################
date -u +'%d %b %Y  •  %H:%M:%S UTC' > "$ASSET_DIR/clock.txt"
(
    while true; do
        date -u +'%d %b %Y  •  %H:%M:%S UTC' > "$ASSET_DIR/clock.txt.tmp"
        mv -f "$ASSET_DIR/clock.txt.tmp" "$ASSET_DIR/clock.txt"
        sleep 1
    done
) &
CLOCK_PID=$!

#############################################
# Background subscriber-count writer
# (polls YouTube Data API every 60s — subs
# don't change second to second, and this
# respects API quota)
#############################################
printf ' ' > "$ASSET_DIR/subs.txt"
SUBS_PID=""
if [ "$SHOW_STATS" = true ]; then
    (
        WARNED_ONCE=false
        while true; do
            RESP=$(curl -s "https://www.googleapis.com/youtube/v3/channels?part=statistics&id=${YOUTUBE_CHANNEL_ID}&key=${YOUTUBE_API_KEY}" || true)
            COUNT=$(echo "$RESP" | grep -o '"subscriberCount"[^"]*"[0-9]*"' | grep -oE '[0-9]+')
            if [ -n "$COUNT" ]; then
                # Manual comma insertion — locale-independent, so it works
                # the same regardless of the container's default locale
                # (printf "%'d" silently fails to group digits under the
                # bare "C" locale that Ubuntu containers ship with).
                FORMATTED=$(echo "$COUNT" | rev | sed 's/\(...\)/\1,/g' | rev | sed 's/^,//')
                printf '%s subscribers' "$FORMATTED" > "$ASSET_DIR/subs.txt.tmp"
                mv -f "$ASSET_DIR/subs.txt.tmp" "$ASSET_DIR/subs.txt"
                WARNED_ONCE=false
            elif [ "$WARNED_ONCE" = false ]; then
                echo "WARNING: could not parse subscriberCount from API response. Raw response:"
                echo "$RESP"
                WARNED_ONCE=true
            fi
            sleep 60
        done
    ) &
    SUBS_PID=$!
fi

#############################################
# Background live-viewer-count writer
# Strategy: find the channel's currently-live
# video once (search.list — costs more quota,
# so only called when we don't already have an
# id), then poll videos.list (cheap, 1 unit)
# every 30s for concurrentViewers. If the
# broadcast ends/restarts, re-search.
#############################################
printf ' ' > "$ASSET_DIR/viewers.txt"
VIEWERS_PID=""
if [ "$SHOW_STATS" = true ]; then
    (
        LIVE_VIDEO_ID=""
        while true; do
            if [ -z "$LIVE_VIDEO_ID" ]; then
                SEARCH_RESP=$(curl -s "https://www.googleapis.com/youtube/v3/search?part=id&channelId=${YOUTUBE_CHANNEL_ID}&eventType=live&type=video&key=${YOUTUBE_API_KEY}" || true)
                LIVE_VIDEO_ID=$(echo "$SEARCH_RESP" | grep -o '"videoId": *"[^"]*"' | head -1 | sed -E 's/.*"videoId": *"([^"]*)".*/\1/')
            fi
            if [ -n "$LIVE_VIDEO_ID" ]; then
                VRESP=$(curl -s "https://www.googleapis.com/youtube/v3/videos?part=liveStreamingDetails&id=${LIVE_VIDEO_ID}&key=${YOUTUBE_API_KEY}" || true)
                VIEWERS=$(echo "$VRESP" | grep -o '"concurrentViewers": *"[0-9]*"' | grep -o '[0-9]*')
                if [ -n "$VIEWERS" ] && [ "$VIEWERS" -ge "$VIEWER_MIN_TO_SHOW" ]; then
                    printf '%s watching now' "$VIEWERS" > "$ASSET_DIR/viewers.txt.tmp"
                    mv -f "$ASSET_DIR/viewers.txt.tmp" "$ASSET_DIR/viewers.txt"
                elif [ -n "$VIEWERS" ]; then
                    printf ' ' > "$ASSET_DIR/viewers.txt.tmp"
                    mv -f "$ASSET_DIR/viewers.txt.tmp" "$ASSET_DIR/viewers.txt"
                else
                    LIVE_VIDEO_ID=""
                    printf ' ' > "$ASSET_DIR/viewers.txt"
                fi
            fi
            sleep 30
        done
    ) &
    VIEWERS_PID=$!
fi

trap 'kill "$CLOCK_PID" 2>/dev/null || true; [ -n "$SUBS_PID" ] && kill "$SUBS_PID" 2>/dev/null || true; [ -n "$VIEWERS_PID" ] && kill "$VIEWERS_PID" 2>/dev/null || true; kill "$COUNTDOWN_PID" 2>/dev/null || true' EXIT

#############################################
# Static panel text (unchanged across videos)
#############################################
printf 'S O L A R   D Y N A M I C S'        > "$ASSET_DIR/title1.txt"
printf 'O B S E R V A T O R Y'              > "$ASSET_DIR/title2.txt"
printf "T O D A Y ' S   S O L A R   S T O R Y" > "$ASSET_DIR/header.txt"
printf 'LIVE FROM SDO'                      > "$ASSET_DIR/eyebrow.txt"
printf 'SUBSCRIBE for the Sun, live 24/7'   > "$ASSET_DIR/cta.txt"
printf 'DID YOU KNOW'                       > "$ASSET_DIR/fact_label.txt"
printf 'INSTRUMENT'                         > "$ASSET_DIR/instr_label.txt"
printf 'SDO · AIA'                          > "$ASSET_DIR/instr_title.txt"
printf 'TRENDING NOW'                       > "$ASSET_DIR/trend_label.txt"
printf 'TOTAL SOLAR ECLIPSE'                > "$ASSET_DIR/trend_title.txt"
printf 'Greenland · Iceland · Spain'        > "$ASSET_DIR/trend_sub.txt"
printf 'COUNTDOWN TO TOTALITY'              > "$ASSET_DIR/countdown_label.txt"

#############################################
# Default headline / fact pools (used as a
# last resort if solar_info.txt / facts.txt
# are missing or empty)
#############################################
DEFAULT_HEADLINES=(
    "NASA's Solar Dynamics Observatory watches the Sun around the clock from Earth orbit."
    "SDO captures the Sun in many wavelengths, each revealing a different layer of its atmosphere."
    "This live view tracks the Sun through solar maximum, the most active point of its eleven-year cycle."
    "Bright active regions glow in extreme ultraviolet light where the Sun's magnetic field is strongest."
    "Powerful X-class flares appear as sudden bright flashes with vertical streaks from camera saturation."
    "Looping plasma structures called prominences and filaments trace the Sun's magnetic field lines."
    "Twice a year Earth passes between SDO and the Sun, producing brief on-screen eclipses."
    "Each SDO frame captures just twelve seconds of real time, the observatory's finest resolution."
    "The 304-angstrom wavelength highlights prominences and filaments arcing above the solar surface."
    "The 171-angstrom wavelength reveals the Sun's outer atmosphere and eruptions along its edge."
    "Occasional blocky dark patches in the footage mark brief gaps in the data stream."
    "Solar maximum brings far more sunspots, flares, and eruptions than the quieter years of the cycle."
    "SDO has been watching the Sun continuously since its launch in 2010."
    "The corona, the Sun's faint outer atmosphere, is far hotter than the surface beneath it."
    "TRENDING: a total solar eclipse sweeps over Greenland, Iceland, and Spain on August 12."
)

DEFAULT_FACTS=(
    "SDO orbits Earth so it can keep an almost unbroken watch on the Sun."
    "The Sun's visible surface sits around 5,500 degrees Celsius."
    "The Sun's corona can reach temperatures above a million degrees Celsius."
    "A single solar flare can release as much energy as billions of hydrogen bombs."
    "The Sun's magnetic field flips polarity roughly every eleven years."
    "Sunspots are cooler, darker patches caused by intense magnetic activity."
    "A coronal mass ejection can hurl billions of tons of solar plasma into space."
    "Sunlight takes about eight minutes to travel from the Sun to Earth."
    "The Sun holds more than 99 percent of the mass in our solar system."
    "Solar wind streams outward from the Sun and shapes the magnetic fields of nearby planets."
    "X-class flares are the most powerful category and can disrupt radio signals on Earth."
    "Auroras form when solar particles collide with gases in Earth's upper atmosphere."
    "The Sun is a middle-aged star, roughly 4.6 billion years old."
    "Prominences are loops of relatively cool plasma suspended by the Sun's magnetic field."
    "The Sun rotates faster at its equator than near its poles."
    "It takes light from the Sun's core about 100,000 years to reach its surface."
    "The Sun converts about four million tons of mass into energy every second."
    "Solar maximum and solar minimum mark the peaks and lulls of the roughly eleven-year solar cycle."
    "Extreme ultraviolet light lets telescopes like SDO see structures invisible in ordinary light."
    "The Sun is close enough that its light and heat make life on Earth possible."
    "On August 12, 2026, mainland Europe sees its first total solar eclipse since 1999."
)

#############################################
# build_labels_chain: optional feature — draws
# pointer/callout labels onto specific
# coordinates in the video (e.g. pointing out
# an active region or a flare), similar to
# hand-annotated documentary footage. Fully
# optional per video: only activates if a file
# named <basename>.labels.txt exists.
#
# File format — one label per line, comma
# separated:
#   x,y,Label text here
# where x,y is the pixel position on the
# 1280x720 output frame that the label should
# point at.
#
# Notes/limits:
#  - Keep label text under ~28 characters — the
#    box is a fixed width and does not
#    reflow/resize to fit longer text.
#  - Coordinates should fall roughly within the
#    center video strip (x between ~350 and
#    ~930) so labels point at the Sun itself
#    rather than overlapping the side panels.
#  - The connector is a right-angle line
#    (vertical then horizontal).
#  - Requires dot_marker.png (generated once at
#    startup) to be wired in as ffmpeg input
#    index 2 — see run_video()'s -i list.
#
# Sets globals: LABELS_CHAIN (filter string to
# append), LABELS_OUT (bracketed output label
# to continue the chain from).
#############################################
build_labels_chain() {
    local url="$1"
    local base
    base="${url##*/}"
    base="${base%.*}"

    # `local` on every loop variable here is required — without it these
    # would be global bash variables and would silently clobber the
    # outer stream loop's `i` counter (see prepare_video_content for the
    # full explanation of this bug class).
    local i idx

    LABELS_CHAIN=""
    LABELS_OUT="[base]"

    local labels_file="${base}.labels.txt"
    if [ ! -f "$labels_file" ]; then
        return 0
    fi

    local xs=() ys=() texts=()
    while IFS=',' read -r x y text; do
        x="$(echo "$x" | tr -d '[:space:]')"
        y="$(echo "$y" | tr -d '[:space:]')"
        text="$(echo "$text" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ "$x" =~ ^[0-9]+$ ]] || continue
        [[ "$y" =~ ^[0-9]+$ ]] || continue
        [ -z "$text" ] && continue
        xs+=("$x"); ys+=("$y"); texts+=("$text")
    done < "$labels_file"

    local n=${#xs[@]}
    if [ "$n" -eq 0 ]; then
        echo "NOTICE: $labels_file had no valid lines — skipping labels for this video."
        return 0
    fi
    echo "Using coordinate labels: $labels_file ($n label(s))"

    local BOX_H=42
    local V_OFFSET=70
    local H_OFFSET=40
    local ACCENT_W=4
    local BOX_GAP=10
    local LABEL_FONTSIZE=18
    local LABEL_PAD_L=14
    local LABEL_PAD_R=16
    local AVG_CHAR_W=10
    local BOX_W_MIN=110
    local BOX_W_MAX=260
    local placed_x=() placed_y=() placed_w=()
    local k collision tries

    local split_outs=""
    for ((i = 1; i <= n; i++)); do split_outs+="[dm${i}]"; done
    LABELS_CHAIN+="[1:v]split=${n}${split_outs};"

    local prev="base"
    for ((i = 0; i < n; i++)); do
        idx=$((i + 1))
        local x="${xs[$i]}" y="${ys[$i]}" text="${texts[$i]}"
        printf '%s' "$text" > "$ASSET_DIR/label${idx}.txt"

        local box_w=$(( ${#text} * AVG_CHAR_W + ACCENT_W + LABEL_PAD_L + LABEL_PAD_R ))
        [ "$box_w" -lt "$BOX_W_MIN" ] && box_w=$BOX_W_MIN
        [ "$box_w" -gt "$BOX_W_MAX" ] && box_w=$BOX_W_MAX

        local box_y=$((y - V_OFFSET))
        if [ "$box_y" -lt 20 ]; then
            box_y=$((y + V_OFFSET - BOX_H))
        fi
        local box_x=$((x + H_OFFSET))
        # Keep the label box from drifting into the side panels.
        if [ $((box_x + box_w)) -gt $((RIGHT_X0 - 10)) ]; then
            box_x=$((x - H_OFFSET - box_w))
        fi
        [ "$box_x" -lt $((CENTER_X0 + 10)) ] && box_x=$((CENTER_X0 + 10))

        tries=0
        while :; do
            collision=false
            for ((k = 0; k < ${#placed_x[@]}; k++)); do
                local px="${placed_x[$k]}" py="${placed_y[$k]}" pw="${placed_w[$k]}"
                if [ $((box_x)) -lt $((px + pw + BOX_GAP)) ] && \
                   [ $((box_x + box_w + BOX_GAP)) -gt $((px)) ] && \
                   [ $((box_y)) -lt $((py + BOX_H + BOX_GAP)) ] && \
                   [ $((box_y + BOX_H + BOX_GAP)) -gt $((py)) ]; then
                    collision=true
                    break
                fi
            done
            [ "$collision" = false ] && break
            box_y=$((box_y + BOX_H + BOX_GAP))
            if [ $((box_y + BOX_H)) -gt 700 ]; then
                box_y=20
            fi
            tries=$((tries + 1))
            [ "$tries" -gt 12 ] && break
        done
        placed_x+=("$box_x")
        placed_y+=("$box_y")
        placed_w+=("$box_w")

        local seg_y_top seg_y_bot
        if [ "$box_y" -gt "$y" ]; then
            seg_y_top=$y; seg_y_bot=$box_y
        else
            seg_y_top=$box_y; seg_y_bot=$y
        fi
        local seg_h=$((seg_y_bot - seg_y_top))
        [ "$seg_h" -lt 2 ] && seg_h=2

        local h_left h_w
        if [ "$box_x" -gt "$x" ]; then
            h_left=$x; h_w=$((box_x - x))
        else
            h_left=$box_x; h_w=$((x - box_x))
        fi
        [ "$h_w" -lt 2 ] && h_w=2

        local n1="lbl${idx}_dot" n2="lbl${idx}_v" n3="lbl${idx}_h" n4="lbl${idx}_bg" n5="lbl${idx}_bar" n6="lbl${idx}_outline" n7="lbl${idx}_txt"

        LABELS_CHAIN+="[${prev}]drawbox=x=${x}:y=${seg_y_top}:w=2:h=${seg_h}:color=${GOLD}@0.85:t=fill[${n2}];"
        LABELS_CHAIN+="[${n2}]drawbox=x=${h_left}:y=${box_y}:w=${h_w}:h=2:color=${GOLD}@0.85:t=fill[${n3}];"
        LABELS_CHAIN+="[${n3}]drawbox=x=${box_x}:y=${box_y}:w=${box_w}:h=${BOX_H}:color=black@0.78:t=fill[${n4}];"
        LABELS_CHAIN+="[${n4}]drawbox=x=${box_x}:y=${box_y}:w=${ACCENT_W}:h=${BOX_H}:color=${GOLD}:t=fill[${n5}];"
        LABELS_CHAIN+="[${n5}]drawbox=x=${box_x}:y=${box_y}:w=${box_w}:h=${BOX_H}:color=${GOLD}@0.5:t=1[${n6}];"
        LABELS_CHAIN+="[${n6}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/label${idx}.txt:fontcolor=white:fontsize=${LABEL_FONTSIZE}:x=$((box_x + ACCENT_W + LABEL_PAD_L)):y=$((box_y + (BOX_H - LABEL_FONTSIZE) / 2)):${SHADOW}[${n7}];"
        LABELS_CHAIN+="[${n7}][dm${idx}]overlay=x=$((x - 8)):y=$((y - 8))[${n1}];"

        prev="$n1"
    done

    LABELS_OUT="[${prev}]"
    echo "Drew $n label(s) from $labels_file"
}

#############################################
# prepare_video_content: (re)loads headlines +
# facts for the video about to stream, and
# rebuilds BASE_CHAIN / FACT_END to match.
#
# Per-video override: if files named
#   <basename>.headlines.txt
#   <basename>.facts.txt
#   <basename>.wavelength.txt   (single line, e.g. "304 Å — Prominences")
# exist (basename = video filename without
# extension), they're used verbatim. The
# wavelength line shows in the right panel's
# INSTRUMENT block — handy since different SDO
# clips use different AIA channels.
#
# Otherwise falls back to the shared pool
# (solar_info.txt / facts.txt / built-in
# defaults), shuffled fresh each video.
#############################################
prepare_video_content() {
    local url="$1"
    local base
    base="${url##*/}"
    base="${base%.*}"

    # See build_labels_chain() for why every loop var here must be `local`.
    local i idx

    RAW_LINES=()
    if [ -f "${base}.headlines.txt" ]; then
        echo "Using curated headlines: ${base}.headlines.txt"
        while IFS= read -r line; do
            [ -n "$(echo "$line" | tr -d '[:space:]')" ] && RAW_LINES+=("$line")
        done < "${base}.headlines.txt"
    fi
    if [ "${#RAW_LINES[@]}" -eq 0 ]; then
        local pool=()
        if [ -f "$INFO_FILE" ]; then
            while IFS= read -r line; do
                [ -n "$(echo "$line" | tr -d '[:space:]')" ] && pool+=("$line")
            done < "$INFO_FILE"
        fi
        [ "${#pool[@]}" -eq 0 ] && pool=("${DEFAULT_HEADLINES[@]}")
        while IFS= read -r line; do
            RAW_LINES+=("$line")
        done < <(printf '%s\n' "${pool[@]}" | shuf)
    fi

    FACTS=()
    if [ -f "${base}.facts.txt" ]; then
        echo "Using curated facts: ${base}.facts.txt"
        while IFS= read -r line; do
            [ -n "$(echo "$line" | tr -d '[:space:]')" ] && FACTS+=("$line")
        done < "${base}.facts.txt"
    fi
    if [ "${#FACTS[@]}" -eq 0 ]; then
        local fpool=()
        if [ -f "facts.txt" ]; then
            while IFS= read -r line; do
                [ -n "$(echo "$line" | tr -d '[:space:]')" ] && fpool+=("$line")
            done < "facts.txt"
        fi
        [ "${#fpool[@]}" -eq 0 ] && fpool=("${DEFAULT_FACTS[@]}")
        while IFS= read -r line; do
            FACTS+=("$line")
        done < <(printf '%s\n' "${fpool[@]}" | shuf)
    fi

    if [ -f "${base}.wavelength.txt" ]; then
        head -n 1 "${base}.wavelength.txt" > "$ASSET_DIR/instr_sub.txt"
    else
        printf 'Extreme ultraviolet imaging of the solar atmosphere' > "$ASSET_DIR/instr_sub.txt"
    fi
    fold -s -w 26 "$ASSET_DIR/instr_sub.txt" > "$ASSET_DIR/instr_sub.wrapped.txt"

    N=${#RAW_LINES[@]}
    CYCLE=$((N * SLOT))
    echo "This video: $N headline(s), rotation cycle ${CYCLE}s"

    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        echo "${RAW_LINES[$i]}" | fold -s -w 25 > "$ASSET_DIR/headline${idx}.txt"
    done

    MAX_HEADLINE_LINES=1
    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        lines=$(grep -c '' "$ASSET_DIR/headline${idx}.txt")
        [ "$lines" -gt "$MAX_HEADLINE_LINES" ] && MAX_HEADLINE_LINES=$lines
    done
    echo "Longest headline wraps to $MAX_HEADLINE_LINES line(s)."

    # ---- Left panel vertical rhythm (headlines + progress + dots) ----
    HEADLINE_Y=230
    PROGRESS_Y=$((HEADLINE_Y + MAX_HEADLINE_LINES * HEADLINE_LINE_H + 40))
    DOTS_Y=$((PROGRESS_Y + 20))

    TICKER_STRING=""
    for i in "${!RAW_LINES[@]}"; do
        TICKER_STRING+="${RAW_LINES[$i]}     •     "
    done
    printf '%s' "$TICKER_STRING" > "$ASSET_DIR/ticker.txt"

    FACT_N=${#FACTS[@]}
    FACT_CYCLE=$((FACT_N * FACT_SLOT))
    local max_fact_lines=1
    for i in "${!FACTS[@]}"; do
        idx=$((i + 1))
        echo "${FACTS[$i]}" | fold -s -w 24 > "$ASSET_DIR/fact${idx}.txt"
        lines=$(grep -c '' "$ASSET_DIR/fact${idx}.txt")
        [ "$lines" -gt "$max_fact_lines" ] && max_fact_lines=$lines
    done
    MAX_FACT_LINES=$max_fact_lines

    # ---- Right panel vertical rhythm (stats + instrument + facts) ----
    RSTAT_Y=19            # credits / clock / subs / viewers block start
    RDIV1_Y=$((RSTAT_Y + 4 * 20 + 6))
    RINSTR_LABEL_Y=$((RDIV1_Y + 20))
    RINSTR_TITLE_Y=$((RINSTR_LABEL_Y + 22))
    RINSTR_SUB_Y=$((RINSTR_TITLE_Y + 30))
    RDIV2_Y=$((RINSTR_SUB_Y + 44 + 16))
    RFACT_LABEL_Y=$((RDIV2_Y + 14))
    RFACT_TEXT_Y=$((RFACT_LABEL_Y + 24))

    #########################################
    # Rebuild BASE_CHAIN for this video's content
    #########################################
    # Fit the (typically square) SDO frame into the center strip: scale
    # up so it fully covers CENTER_W x 720, then crop the small excess
    # off the sides. That keeps the Sun large and edge-to-edge with no
    # black bars, at the cost of a modest side crop.
    CHAIN="color=c=black:s=1280x720[canvas];"
    CHAIN+="[0:v]scale=${CENTER_W}:720:force_original_aspect_ratio=increase,crop=${CENTER_W}:720[vidfit];"
    CHAIN+="[canvas][vidfit]overlay=${CENTER_X0}:0:shortest=1[base];"

    # Optional coordinate-based callout labels for this video, drawn
    # onto the Sun before the panels so the panels stay on top.
    build_labels_chain "$url"
    CHAIN+="$LABELS_CHAIN"

    # ---------------- Left panel: story / headlines ----------------
    CHAIN+="${LABELS_OUT}drawbox=x=0:y=0:w=${PANEL_W}:h=720:color=black@0.92:t=fill[p1];"
    CHAIN+="[p1]drawbox=x=${PANEL_W}:y=0:w=3:h=720:color=${GOLD}@0.75:t=fill[p2];"
    CHAIN+="[p2]drawbox=x=0:y=0:w=${PANEL_W}:h=4:color=${GOLD}@0.9:t=fill[p3];"

    CHAIN+="[p3]drawbox=x=27:y=28:w=11:h=11:color=${RED}:t=fill:enable='lt(mod(t\,1)\,0.6)'[p4];"
    CHAIN+="[p4]drawtext=fontfile=${FONT}:text='LIVE':fontcolor=white:fontsize=30:x=44:y=19[p5];"
    CHAIN+="[p5]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/eyebrow.txt:fontcolor=${GOLD}@0.9:fontsize=13:x=${TEXT_INSET}-text_w+280:y=39[p6];"

    CHAIN+="[p6]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title1.txt:fontcolor=white:fontsize=22:x=${TEXT_INSET}:y=95:${SHADOW}[p7];"
    CHAIN+="[p7]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title2.txt:fontcolor=white@0.85:fontsize=16:x=${TEXT_INSET}:y=123:${SHADOW}[p8];"
    CHAIN+="[p8]drawbox=x=${TEXT_INSET}:y=153:w=${PANEL_TEXT_W}:h=2:color=white@0.3:t=fill[p9];"

    CHAIN+="[p9]drawbox=x=${TEXT_INSET}:y=171:w=8:h=8:color=${GOLD}:t=fill[p10];"
    CHAIN+="[p10]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/header.txt:fontcolor=${GOLD}:fontsize=14:x=$((TEXT_INSET + 16)):y=168[p11];"

    local prev="p11"
    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        local start=$((i * SLOT))
        local end=$((start + SLOT))
        local nxt="h${idx}"
        local ALPHA="if(between(mod(t\,${CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${CYCLE})-${start}\,0.6)\,(mod(t\,${CYCLE})-${start})/0.6\,if(gt(mod(t\,${CYCLE})-${start}\,${SLOT}-0.6)\,(${end}-mod(t\,${CYCLE}))/0.6\,1))\,0)"
        CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/headline${idx}.txt:fontcolor=white:fontsize=${HEADLINE_FONTSIZE}:line_spacing=${HEADLINE_LINE_SPACING}:x=${TEXT_INSET}:y=${HEADLINE_Y}:alpha='${ALPHA}':${SHADOW}[${nxt}];"
        prev="$nxt"
    done

    CHAIN+="[${prev}]drawtext=fontfile=${FONT}:text='STORY PROGRESS':fontcolor=white@0.35:fontsize=9:x=${TEXT_INSET}:y=$((PROGRESS_Y - 15))[pgcap];"
    CHAIN+="[pgcap]drawbox=x=${TEXT_INSET}:y=${PROGRESS_Y}:w=${PANEL_TEXT_W}:h=2:color=white@0.15:t=fill[pg1];"
    CHAIN+="[pg1]drawbox=x=${TEXT_INSET}:y=${PROGRESS_Y}:w='${PANEL_TEXT_W}*(mod(t\,${SLOT}))/${SLOT}':h=2:color=${GOLD}:t=fill[pg2];"
    prev="pg2"

    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        local x=$((TEXT_INSET + i * 17))
        local nxt="db${idx}"
        CHAIN+="[${prev}]drawbox=x=${x}:y=${DOTS_Y}:w=7:h=7:color=white@0.3:t=fill[${nxt}];"
        prev="$nxt"
    done

    local last=$((N - 1))
    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        local x=$((TEXT_INSET + i * 17))
        local start=$((i * SLOT))
        local end=$((start + SLOT))
        local ENABLE="between(mod(t\,${CYCLE})\,${start}\,${end})"
        if [ "$i" -eq "$last" ]; then
            CHAIN+="[${prev}]drawbox=x=${x}:y=${DOTS_Y}:w=7:h=7:color=${GOLD}:t=fill:enable='${ENABLE}'[pdotend];"
            prev="pdotend"
        else
            local nxt="da${idx}"
            CHAIN+="[${prev}]drawbox=x=${x}:y=${DOTS_Y}:w=7:h=7:color=${GOLD}:t=fill:enable='${ENABLE}'[${nxt}];"
            prev="$nxt"
        fi
    done

    # ---------------- Left panel: TRENDING NOW (Aug 12 eclipse) ----------------
    # Replaces the old animated "solar activity" bar graph with a
    # callout for the Aug 12, 2026 total solar eclipse: a pulsing
    # "TRENDING NOW" tag, the event image (if EVENT_IMAGE_URL was
    # downloaded at startup — see top of script), and a caption.
    # If no image was downloaded, the picture frame is simply skipped
    # and the text block is used on its own — nothing breaks.
    local TREND_LABEL_Y=$((DOTS_Y + 34))
    local TREND_IMG_Y=$((TREND_LABEL_Y + 20))
    local TREND_IMG_W=$PANEL_TEXT_W
    # The block's total height depends on how many lines the current
    # headline wrapped to (DOTS_Y shifts with it), so the image height
    # is computed to fit — never a fixed value — reserving TREND_TEXT_H
    # below the image for the title + caption + countdown row, and
    # keeping the whole thing above TREND_MAX_BOTTOM (comfortably clear
    # of the bottom ticker bar, which starts at y=680). This is what
    # broke before: a fixed image height could push text down into the
    # ticker's y=680-720 band, where the ticker's opaque background
    # (drawn later, on top) hid it.
    local TREND_TEXT_H=88
    local TREND_MAX_BOTTOM=670
    local TREND_IMG_H=$((TREND_MAX_BOTTOM - TREND_IMG_Y - TREND_TEXT_H))
    [ "$TREND_IMG_H" -gt 120 ] && TREND_IMG_H=120
    [ "$TREND_IMG_H" -lt 40 ] && TREND_IMG_H=40
    local TREND_TITLE_Y=$((TREND_IMG_Y + TREND_IMG_H + 8))
    local TREND_SUB_Y=$((TREND_TITLE_Y + 24))
    local TREND_CD_LABEL_Y=$((TREND_SUB_Y + 22))
    local TREND_CD_VALUE_Y=$((TREND_CD_LABEL_Y + 15))

    CHAIN+="[${prev}]drawbox=x=$((TEXT_INSET - 2)):y=$((TREND_LABEL_Y - 2)):w=6:h=6:color=${RED}:t=fill:enable='lt(mod(t\,1.2)\,0.75)'[tr1];"
    CHAIN+="[tr1]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/trend_label.txt:fontcolor=white@0.55:fontsize=11:x=$((TEXT_INSET + 14)):y=$((TREND_LABEL_Y - 8))[tr2];"
    prev="tr2"

    if [ "$EVENT_IMAGE_AVAILABLE" = true ]; then
        CHAIN+="[${prev}]drawbox=x=$((TEXT_INSET - 3)):y=$((TREND_IMG_Y - 3)):w=$((TREND_IMG_W + 6)):h=$((TREND_IMG_H + 6)):color=${GOLD}@0.7:t=2[tr3];"
        CHAIN+="[3:v]scale=${TREND_IMG_W}:${TREND_IMG_H}:force_original_aspect_ratio=increase,crop=${TREND_IMG_W}:${TREND_IMG_H}[trimg];"
        CHAIN+="[tr3][trimg]overlay=${TEXT_INSET}:${TREND_IMG_Y}:shortest=1[tr4];"
        prev="tr4"
    fi

    CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/trend_title.txt:fontcolor=${GOLD}:fontsize=18:x=${TEXT_INSET}:y=${TREND_TITLE_Y}:${SHADOW}[tr5];"
    CHAIN+="[tr5]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/trend_sub.txt:fontcolor=white@0.8:fontsize=13:x=${TEXT_INSET}:y=${TREND_SUB_Y}[tr6];"
    CHAIN+="[tr6]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/countdown_label.txt:fontcolor=white@0.45:fontsize=10:x=${TEXT_INSET}:y=${TREND_CD_LABEL_Y}[tr7];"
    CHAIN+="[tr7]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/countdown.txt:reload=1:fontcolor=${GOLD}:fontsize=17:x=${TEXT_INSET}:y=${TREND_CD_VALUE_Y}:${SHADOW}[trend_out];"
    prev="trend_out"

    # ---------------- Right panel: stats + instrument + facts ----------------
    CHAIN+="[${prev}]drawbox=x=${RIGHT_X0}:y=0:w=${PANEL_W}:h=720:color=black@0.92:t=fill[r1];"
    CHAIN+="[r1]drawbox=x=$((RIGHT_X0 - 3)):y=0:w=3:h=720:color=${GOLD}@0.75:t=fill[r2];"
    CHAIN+="[r2]drawbox=x=${RIGHT_X0}:y=0:w=${PANEL_W}:h=4:color=${GOLD}@0.9:t=fill[r3];"

    CHAIN+="[r3]drawtext=fontfile=${FONT}:text='Credits\: NASA / SDO':fontcolor=white@0.85:fontsize=14:x=${RTEXT_INSET}:y=${RSTAT_Y}[r4];"
    CHAIN+="[r4]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/clock.txt:reload=1:fontcolor=${GOLD}:fontsize=14:x=${RTEXT_INSET}:y=$((RSTAT_Y + 20))[r5];"
    CHAIN+="[r5]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/subs.txt:reload=1:fontcolor=white@0.75:fontsize=13:x=${RTEXT_INSET}:y=$((RSTAT_Y + 40))[r6];"
    CHAIN+="[r6]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/viewers.txt:reload=1:fontcolor=white@0.75:fontsize=13:x=${RTEXT_INSET}:y=$((RSTAT_Y + 60))[r7];"

    CHAIN+="[r7]drawbox=x=${RTEXT_INSET}:y=${RDIV1_Y}:w=${PANEL_TEXT_W}:h=2:color=white@0.15:t=fill[r8];"

    CHAIN+="[r8]drawbox=x=${RTEXT_INSET}:y=${RINSTR_LABEL_Y}:w=8:h=8:color=${GOLD}:t=fill[r9];"
    CHAIN+="[r9]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/instr_label.txt:fontcolor=${GOLD}:fontsize=14:x=$((RTEXT_INSET + 16)):y=$((RINSTR_LABEL_Y - 3))[r10];"
    CHAIN+="[r10]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/instr_title.txt:fontcolor=white:fontsize=20:x=${RTEXT_INSET}:y=${RINSTR_TITLE_Y}:${SHADOW}[r11];"
    CHAIN+="[r11]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/instr_sub.wrapped.txt:fontcolor=white@0.75:fontsize=14:line_spacing=6:x=${RTEXT_INSET}:y=${RINSTR_SUB_Y}[r12];"

    CHAIN+="[r12]drawbox=x=${RTEXT_INSET}:y=${RDIV2_Y}:w=${PANEL_TEXT_W}:h=2:color=${GOLD}@0.4:t=fill[r13];"
    CHAIN+="[r13]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/fact_label.txt:fontcolor=${GOLD}@0.85:fontsize=12:x=${RTEXT_INSET}:y=${RFACT_LABEL_Y}[r14];"
    prev="r14"
    for i in "${!FACTS[@]}"; do
        idx=$((i + 1))
        local start=$((i * FACT_SLOT))
        local end=$((start + FACT_SLOT))
        local nxt="f${idx}"
        local FALPHA="if(between(mod(t\,${FACT_CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${FACT_CYCLE})-${start}\,0.6)\,(mod(t\,${FACT_CYCLE})-${start})/0.6\,if(gt(mod(t\,${FACT_CYCLE})-${start}\,${FACT_SLOT}-0.6)\,(${end}-mod(t\,${FACT_CYCLE}))/0.6\,1))\,0)"
        CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/fact${idx}.txt:fontcolor=white@0.9:fontsize=${FACT_FONTSIZE}:line_spacing=${FACT_LINE_SPACING}:x=${RTEXT_INSET}:y=${RFACT_TEXT_Y}:alpha='${FALPHA}'[${nxt}];"
        prev="$nxt"
    done

    # ---------------- Right panel: live readings + EUV graph ----------------
    # Same idea as the left panel's activity graph, mirrored on this
    # side with a temperature readout on top (using the same live-number
    # %{eif:...} trick) so both panels feel "alive" instead of static.
    local RREAD_DIV_Y=$((RFACT_TEXT_Y + MAX_FACT_LINES * FACT_LINE_H + 16))
    local RREAD_LABEL_Y=$((RREAD_DIV_Y + 14))
    local RREAD_LINE1_Y=$((RREAD_LABEL_Y + 22))
    local RREAD_LINE2_Y=$((RREAD_LINE1_Y + 20))
    local RGRAPH_LABEL_Y=$((RREAD_LINE2_Y + 30))
    local RGRAPH_BASE_Y=$((RGRAPH_LABEL_Y + 150))

    CHAIN+="[${prev}]drawbox=x=${RTEXT_INSET}:y=${RREAD_DIV_Y}:w=${PANEL_TEXT_W}:h=2:color=white@0.15:t=fill[rr0];"
    CHAIN+="[rr0]drawtext=fontfile=${FONT}:text='LIVE READINGS':fontcolor=${GOLD}@0.85:fontsize=12:x=${RTEXT_INSET}:y=${RREAD_LABEL_Y}[rr1];"
    CHAIN+="[rr1]drawtext=fontfile=${FONT}:text='SURFACE   5\,500 C':fontcolor=white@0.85:fontsize=14:x=${RTEXT_INSET}:y=${RREAD_LINE1_Y}[rr2];"
    CHAIN+="[rr2]drawtext=fontfile=${FONT}:text='CORE   %{eif\:14900000+400000*sin(t/7)\:d} K':fontcolor=white@0.85:fontsize=14:x=${RTEXT_INSET}:y=${RREAD_LINE2_Y}[rr3];"
    prev="rr3"

    CHAIN+="[${prev}]drawbox=x=$((RTEXT_INSET - 2)):y=$((RGRAPH_LABEL_Y - 2)):w=6:h=6:color=${RED}:t=fill:enable='lt(mod(t\,1.2)\,0.75)'[rg1];"
    CHAIN+="[rg1]drawtext=fontfile=${FONT}:text='EUV FLUX':fontcolor=white@0.55:fontsize=11:x=$((RTEXT_INSET + 14)):y=$((RGRAPH_LABEL_Y - 8))[rg2];"
    prev="rg2"

    local RBAR_COUNT=14
    local RBAR_W=13
    local RBAR_GAP=6
    local RBAR_MINH=8
    local RBAR_MAXH=100
    local ri rbx rh_expr ry_expr rnxt
    for ((ri = 0; ri < RBAR_COUNT; ri++)); do
        rbx=$((RTEXT_INSET + ri * (RBAR_W + RBAR_GAP)))
        rh_expr="clip(55+34*sin(2*PI*t/2.6+${ri}*0.7)+20*sin(2*PI*t/1.3+${ri}*1.1)\,${RBAR_MINH}\,${RBAR_MAXH})"
        ry_expr="${RGRAPH_BASE_Y}-(${rh_expr})"
        rnxt="rgbar${ri}"
        CHAIN+="[${prev}]drawbox=x=${rbx}:y='${ry_expr}':w=${RBAR_W}:h='${rh_expr}':color=${GOLD}@0.75:t=fill[${rnxt}];"
        prev="$rnxt"
    done
    CHAIN+="[${prev}]drawbox=x=${RTEXT_INSET}:y=${RGRAPH_BASE_Y}:w=${PANEL_TEXT_W}:h=1:color=white@0.2:t=fill[rgbase];"
    prev="rgbase"

    BASE_CHAIN="$CHAIN"
    FACT_END="$prev"
}

#############################################
# build_final_filter: appends the CTA / next-
# video countdown / ticker / watermark section
# onto BASE_CHAIN. Called fresh for each video
# since the countdown depends on that video's
# probed duration.
#############################################
build_final_filter() {
    local total_duration="$1"
    local tail="$BASE_CHAIN"

    local CTA_CYCLE=240
    local CTA_SHOW=8
    local CTA_ALPHA="if(between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})\,if(lt(mod(t\,${CTA_CYCLE})\,0.6)\,mod(t\,${CTA_CYCLE})/0.6\,if(gt(mod(t\,${CTA_CYCLE})\,${CTA_SHOW}-0.6)\,(${CTA_SHOW}-mod(t\,${CTA_CYCLE}))/0.6\,1))\,0)"
    local CTA_ENABLE="between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})"
    local COUNTDOWN_ENABLE="not(${CTA_ENABLE})"

    # CTA / countdown box sits centered under the Sun, inside the video
    # strip, so it doesn't have to compete for space with either panel.
    local CTA_W=460
    local CTA_X=$((CENTER_X0 + (CENTER_W - CTA_W) / 2))
    local CTA_Y=640

    tail+="[${FACT_END}]drawbox=x=${CTA_X}:y=${CTA_Y}:w=${CTA_W}:h=43:color=black@0.75:t=fill[cta_bg];"
    tail+="[cta_bg]drawbox=x=${CTA_X}:y=${CTA_Y}:w=4:h=43:color=${GOLD}:t=fill[cta_bar];"
    tail+="[cta_bar]drawbox=x=$((CTA_X + 22)):y=$((CTA_Y + 16)):w=11:h=11:color=${RED}:t=fill:enable='${CTA_ENABLE}'[cta_dot];"
    tail+="[cta_dot]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/cta.txt:fontcolor=white:fontsize=18:x=$((CTA_X + 40)):y=$((CTA_Y + 13)):alpha='${CTA_ALPHA}'[cta_sub];"

    if [[ "$total_duration" =~ ^[0-9]+$ ]] && [ "$total_duration" -gt 0 ]; then
        tail+="[cta_sub]drawtext=fontfile=${FONT}:text='Next view in %{eif\:max(${total_duration}-t\,0)\:d}s':fontcolor=white:fontsize=18:x=$((CTA_X + 40)):y=$((CTA_Y + 13)):enable='${COUNTDOWN_ENABLE}'[cta_final];"
    else
        tail+="[cta_sub]drawtext=fontfile=${FONT}:text='Coming up next...':fontcolor=white@0.85:fontsize=18:x=$((CTA_X + 40)):y=$((CTA_Y + 13)):enable='${COUNTDOWN_ENABLE}'[cta_final];"
    fi

    # Bottom ticker spans the full width, under both panels and the Sun.
    tail+="[cta_final]drawbox=x=0:y=680:w=1280:h=40:color=black@0.85:t=fill[tk1];"
    tail+="[tk1]drawbox=x=0:y=680:w=1280:h=2:color=${GOLD}@0.9:t=fill[tk2];"
    tail+="[tk2]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/ticker.txt:fontcolor=white:fontsize=17:borderw=2:bordercolor=black@0.6:y=695:x='w-mod(t*${TICKER_SPEED}\,text_w+w)'[tk3];"
    tail+="[tk3]drawbox=x=0:y=680:w=120:h=40:color=black@0.9:t=fill[tk4];"
    tail+="[tk4]drawbox=x=0:y=682:w=113:h=38:color=${GOLD}:t=fill[tk5];"
    tail+="[tk5]drawtext=fontfile=${FONT}:text='LIVE NOW':fontcolor=black:fontsize=15:x=13:y=695[tk6];"

    tail+="[tk6]drawtext=fontfile=${FONT}:text='${CHANNEL_NAME}':fontcolor=white@0.45:fontsize=14:borderw=1.5:bordercolor=black@0.7:x=(w-text_w)/2:y=657[final]"

    echo "$tail"
}

#############################################
#############################################
# Stream one video with automatic retry on
# failure/crash (e.g. Bus error, network drop),
# instead of letting set -e kill the script.
#############################################
run_video() {
    local url="$1"
    local attempt=1

    prepare_video_content "$url"

    local duration
    duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$url" 2>/dev/null || echo "")
    duration=${duration%.*}
    [[ "$duration" =~ ^[0-9]+$ ]] || duration=""

    local HARD_CAP=""
    if [ -n "$duration" ]; then
        HARD_CAP=$((duration + 90))   # grace period past expected end
        echo "Probed duration: ${duration}s (hard cap ${HARD_CAP}s)"
    else
        echo "Could not probe duration — countdown will show generic filler text, and no hard cap will apply (relying on natural EOF)."
    fi

    local filter
    filter=$(build_final_filter "$duration")

    # Audio input for this segment: the next track in rotation, looped
    # locally, or a silent fallback if no tracks downloaded at startup.
    local AUDIO_INPUT_ARGS=()
    local AUDIO_MAP="2:a"
    if [ "$AUDIO_AVAILABLE" = true ]; then
        local this_audio="${AUDIO_LOCAL_FILES[$((AUDIO_COUNTER % NUM_AUDIO))]}"
        AUDIO_COUNTER=$((AUDIO_COUNTER + 1))
        echo "Background audio for this video: $this_audio"
        AUDIO_INPUT_ARGS=(-stream_loop -1 -i "$this_audio")
    else
        AUDIO_INPUT_ARGS=(-f lavfi -i "anullsrc=r=48000:cl=stereo")
    fi

    # Trending-event image goes AFTER audio so it lands at input index 3
    # without disturbing AUDIO_MAP (still "2:a"). Only added when a real
    # image was downloaded at startup — the filter graph only ever
    # references [3:v] when EVENT_IMAGE_AVAILABLE is true (see
    # prepare_video_content), so it's safe to omit this input otherwise.
    local EVENT_IMAGE_INPUT_ARGS=()
if [ "$EVENT_IMAGE_AVAILABLE" = true ]; then
    EVENT_IMAGE_INPUT_ARGS=(-thread_queue_size 512 -loop 1 -framerate 30 -i "$EVENT_IMAGE")
fi

    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        echo "----------------------------------------"
        echo "Streaming (attempt ${attempt}/${MAX_RETRIES}):"
        echo "$url"
        echo "----------------------------------------"

        set +e
        ffmpeg \
        -hide_banner \
        -loglevel info \
        -reconnect 1 \
        -reconnect_streamed 1 \
        -reconnect_delay_max 5 \
        -re \
        -i "$url" \
        -loop 1 -framerate 30 -i "$DOT_MARKER" \
        "${AUDIO_INPUT_ARGS[@]}" \
        "${EVENT_IMAGE_INPUT_ARGS[@]}" \
        -filter_complex "$filter" \
        -map "[final]" \
        -map "$AUDIO_MAP" \
        -r 30 \
        -s 1280x720 \
        -c:v libx264 \
        -preset ultrafast \
        -tune zerolatency \
        -threads 2 \
        -profile:v high \
        -level 4.1 \
        -pix_fmt yuv420p \
        -b:v 3000k \
        -maxrate 3000k \
        -bufsize 6000k \
        -g 60 \
        -keyint_min 60 \
        -sc_threshold 0 \
        -c:a aac \
        -b:a 128k \
        -ar 48000 \
        -ac 2 \
        -shortest \
        -f flv \
        "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}" &
        local FFMPEG_PID=$!

        local WATCHDOG_PID=""
        if [ -n "$HARD_CAP" ]; then
            (
                sleep "$HARD_CAP"
                if kill -0 "$FFMPEG_PID" 2>/dev/null; then
                    echo "WARNING: ffmpeg overran hard cap (${HARD_CAP}s) — force-killing to advance to next video."
                    kill -9 "$FFMPEG_PID" 2>/dev/null
                fi
            ) &
            WATCHDOG_PID=$!
        fi

        wait "$FFMPEG_PID"
        local exit_code=$?
        [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null
        set -e

        if [ "$exit_code" -eq 0 ]; then
            echo "Video finished normally."
            return 0
        fi

        echo "WARNING: ffmpeg exited with code ${exit_code} (attempt ${attempt}/${MAX_RETRIES})."
        attempt=$((attempt + 1))
        if [ "$attempt" -le "$MAX_RETRIES" ]; then
            echo "Retrying in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
        else
            echo "ERROR: Max retries reached for this video. Moving on."
        fi
    done
    return 1
}

#############################################
# Stream loop
#############################################
IFS=',' read -ra RAW_URLS <<< "$VIDEO_URL"
URLS=()
for u in "${RAW_URLS[@]}"; do
    u="${u#"${u%%[![:space:]]*}"}"
    u="${u%"${u##*[![:space:]]}"}"
    [ -n "$u" ] && URLS+=("$u")
done
NUM_URLS=${#URLS[@]}
if [ "$NUM_URLS" -eq 0 ]; then
    echo "ERROR: VIDEO_URL contained no valid entries after parsing"
    exit 1
fi

# Shuffle playback order fresh for every workflow run, so the sequence
# of videos isn't identical every time the container restarts.
if [ "$NUM_URLS" -gt 1 ]; then
    mapfile -t URLS < <(printf '%s\n' "${URLS[@]}" | shuf)
    echo "Shuffled playback order for this run:"
    for u in "${URLS[@]}"; do
        echo "  - $u"
    done
fi

while true; do
    for ((i = 0; i < NUM_URLS; i++)); do
        url="${URLS[$i]}"

        run_video "$url"

        echo "Loading next video..."
        echo ""
    done
done
