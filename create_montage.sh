#!/bin/bash

[ "$#" -lt 1 ] || [ "$#" -gt 4 ] && { echo "Usage: $0 <video.mp4> [NxN] [before_image.png] [after_image.png]"; exit 1; }

GRID="5x2"

for arg; do
    if [[ "$arg" =~ ^[0-9]+x[0-9]+$ ]]; then
        GRID="$arg"
    elif [[ "$arg" =~ \.mp4$ ]]; then
        VID="$arg"
    else
        [ -z "$START" ] && START="$arg" || END="$arg"
    fi
done

[ -z "$VID" ] && { echo "Error: Video file not specified."; exit 1; }
[ ! -f "$VID" ] && { echo "Error: Video file '$VID' does not exist."; exit 1; }

# New check: Verify if the specified file is actually a video
VIDEO_CHECK=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_type -of csv=p=0 "$VID" 2>/dev/null)

# Debug line to check ffprobe output
echo "ffprobe output: '$VIDEO_CHECK'"

# Trim any extra whitespace from VIDEO_CHECK
VIDEO_CHECK=$(echo "$VIDEO_CHECK" | xargs)

if [ "$VIDEO_CHECK" != "video" ]; then
    echo "Error: The specified file is not a video or cannot be read."
    exit 1
fi

COLS=${GRID%x*}
ROWS=${GRID#*x}
TOTAL=$((COLS * ROWS))

[ "$TOTAL" -lt 2 ] && { echo "Error: The grid must allow for at least 2 images."; exit 1; }

TEMP="/tmp/temp_frames_$$"
LOG="/tmp/ffmpeg_log_$$.log"
OUT="${VID%.*}_montage.png"

mkdir -p "$TEMP" && touch "$LOG"

# Broader check if running in a Windows environment using $OSTYPE
# NOTE - at some point get rid of references to cygpath
if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]] || [[ "$OSTYPE" == "win32" ]]; then
    echo "Detected Windows environment."

    convert_path() {
    # If running in a Windows-like environment, not using cygpath as it may not be available in other shell environments
    if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]] || [[ "$OSTYPE" == "win32" ]]; then
        # Check if the path starts with a Unix-style root (e.g., /c/)
        if [[ "$1" =~ ^/([a-zA-Z])/ ]]; then
            # Convert Unix-style /c/path to Windows-style C:\path
            drive_letter=${BASH_REMATCH[1]}
            windows_path="${drive_letter}:\\${1:3}"
            windows_path="${windows_path//\//\\}" # Replace forward slashes with backslashes
            echo "$windows_path"
        else
            # Assume it's already a Windows path
            echo "$1"
        fi
    else
        # If not in a Windows environment, return the path unchanged
        echo "$1"
    fi
    }
else
    # If not on Windows shell, no path conversion needed
    convert_path() {
        echo "$1"
    }
fi

echo "Attempting to determine total frames for video: $VID" | tee -a "$LOG"
# get the frames without having to use external grep command, rely on ffprobe functionality.
FRAMES=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$(convert_path "$VID")" 2>/dev/null)

# If ffprobe failed to determine frame count, fallback to alternative method
if [ $? -ne 0 ] || [ -z "$FRAMES" ]; then
    echo "Error: Could not determine total frames using ffprobe. Attempting alternative method..." | tee -a "$LOG"
    FRAMES=$(ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames -of default=noprint_wrappers=1:nokey=1 "$(convert_path "$VID")" 2>/dev/null)
fi


[ -z "$FRAMES" ] && { echo "Error: Failed to determine total frames. See $LOG for details."; exit 1; }
FRAMES=$(echo "$FRAMES" | tr -d '[:space:]')

echo "Total frames determined: $FRAMES" | tee -a "$LOG"

[[ "$FRAMES" =~ ^[0-9]+$ ]] || { echo "Error: FRAMES is not a valid number: $FRAMES"; exit 1; }
[ "$TOTAL" -gt "$FRAMES" ] && { echo "Error: Grid ($GRID) requires more images ($TOTAL) than video frames ($FRAMES)."; exit 1; }

for ((i=0; i<TOTAL; i++)); do
    FRAME_NUMS+=($((i * (FRAMES - 1) / (TOTAL - 1))))
done

echo "Frame numbers: ${FRAME_NUMS[*]}"

[ -n "$START" ] && {
    START_DIM=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$(convert_path "$START")")
    SW=${START_DIM%x*}
    SH=${START_DIM#*x}
    [ -n "$SW" ] && [ -n "$SH" ] && RESIZE=",scale=${SW}:${SH}" || echo "Error: Could not determine START_IMAGE dimensions."
}

inputs=()
echo "Extracting frames..."
for i in "${!FRAME_NUMS[@]}"; do
    if [ "$i" -eq 0 ] && [ -n "$START" ]; then
        inputs+=("-i" "$(convert_path "$START")")
        echo "Using START_IMAGE as frame 0."
    elif [ "$i" -eq $((TOTAL - 1)) ] && [ -n "$END" ]; then
        inputs+=("-i" "$(convert_path "$END")")
        echo "Using END_IMAGE as the last frame."
    else
        FRAME_NUM=${FRAME_NUMS[$i]}
        OUT_FRAME="$TEMP/frame_$i.png"
        PERCENT=$((FRAME_NUM * 100 / (FRAMES - 1)))
        echo "Extracting frame $i (${PERCENT}% of video) and resizing."
        ffmpeg -loglevel error -y -i "$(convert_path "$VID")" -vf "select=eq(n\,${FRAME_NUM})$RESIZE" -vsync vfr "$(convert_path "$OUT_FRAME")" >> "$LOG" 2>&1
        [ ! -f "$OUT_FRAME" ] && { echo "Error: Failed to extract frame $i. See $LOG"; exit 1; }
        inputs+=("-i" "$(convert_path "$OUT_FRAME")")
    fi
done

FILTER=""
if [ "$ROWS" -eq 1 ]; then
    FILTER=$(printf "[%d:v]" $(seq 0 $((COLS-1))))
    FILTER+="hstack=inputs=$COLS[v]"
elif [ "$COLS" -eq 1 ]; then
    FILTER=$(printf "[%d:v]" $(seq 0 $((ROWS-1))))
    FILTER+="vstack=inputs=$ROWS[v]"
else
    for ((r=0; r<ROWS; r++)); do
        FILTER+=$(printf "[%d:v]" $(seq $((r*COLS)) $((r*COLS+COLS-1))))
        FILTER+="hstack=inputs=$COLS[row$r]; "
    done
    FILTER+=$(printf "[row%d]" $(seq 0 $((ROWS-1))))
    FILTER+="vstack=inputs=$ROWS[v]"
fi

echo "Creating montage..." | tee -a "$LOG"
echo inputs = "${inputs[@]}" | tee -a "$LOG"
ffmpeg -loglevel error -y "${inputs[@]}" -filter_complex "$FILTER" -map "[v]" "$(convert_path "$OUT")" >> "$LOG" 2>&1

[ $? -eq 0 ] && [ -f "$OUT" ] && echo "Final image saved as $OUT" || { echo "Error: Failed to create montage. See $LOG for details." | tee -a "$LOG"; cat "$LOG"; exit 1; }

rm -r "$TEMP"
echo "Temporary files deleted. Log file: $LOG"
