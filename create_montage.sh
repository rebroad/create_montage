#!/bin/bash

[ "$#" -lt 1 ] || [ "$#" -gt 4 ] && { echo "Usage: $0 <video.mp4> [NxN | 16:9] [before_image.png] [after_image.png]"; exit 1; }

GRID="5x2"
USE_16_9=false

for arg; do
    if [[ "$arg" == "16:9" ]]; then
        USE_16_9=true
    elif [[ "$arg" =~ ^[0-9]+x[0-9]+$ ]]; then
        GRID="$arg"
    elif [[ "$arg" =~ \.mp4$ ]]; then
        VID="$arg"
    else
        [ -z "$START" ] && START="$arg" || END="$arg"
    fi
done

[ -z "$VID" ] && { echo "Error: Video file not specified."; exit 1; }
[ ! -f "$VID" ] && { echo "Error: Video file '$VID' does not exist."; exit 1; }

COLS=${GRID%x*}
ROWS=${GRID#*x}
TOTAL=$((COLS * ROWS))

[ "$TOTAL" -lt 2 ] && { echo "Error: The grid must allow for at least 2 images."; exit 1; }

TEMP="/tmp/temp_frames_$$"
LOG="/tmp/ffmpeg_log_$$.log"
OUT="${VID%.*}_montage.png"
mkdir -p "$TEMP" && touch "$LOG"

FFMPEG_VERSION=$(ffmpeg -version | grep -i "built with gcc")
[[ "$FFMPEG_VERSION" == *"MSYS2"* ]] && echo "Detected Windows-native ffmpeg."

convert_path() {
    [[ "$FFMPEG_VERSION" == *"MSYS2"* ]] && cygpath -w "$1" || echo "$1"
}

echo "Attempting to determine total frames for video: $VID" | tee -a "$LOG"
FRAMES=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$(convert_path "$VID")" 2>> "$LOG")
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
