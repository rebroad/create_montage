#!/bin/bash

[ "$#" -lt 1 ] && { echo "Usage: $0 <video.mp4> [aspect_ratio] [NxN | Nx | xN] [before_image.png] [after_image.png] [-i]"; exit 1; }

TEMP="/tmp/temp_frames_$$"
LOG="/tmp/ffmpeg_log_$$.log"
mkdir -p "$TEMP" && : > "$LOG"

INTERACTIVE_MODE=false

for arg; do
    case "$arg" in
        *.mp4) VID="$arg" ;;
        *:*) ASPECT_RATIO="$arg" ;;
        *x*) GRID="$arg" ;;
        -i) INTERACTIVE_MODE=true ;;
        *) [ -z "$START" ] && START="$arg" || END="$arg" ;;
    esac
done

[ -z "$VID" ] && { echo "Error: Video file not specified."; exit 1; }
[ ! -f "$VID" ] && { echo "Error: Video file '$VID' does not exist."; exit 1; }
OUT="${VID%.*}_montage.png"
DEADZONE_FILE="${VID%.*}_deadzones.txt"

FFMPEG_VERSION=$(ffmpeg -version | grep -i "built with gcc")
[[ "$FFMPEG_VERSION" == *"MSYS2"* ]] && echo "Detected Windows-native ffmpeg."

convert_path() {
    [[ "$FFMPEG_VERSION" == *"MSYS2"* ]] && cygpath -w "$1" || echo "$1"
}

clean_num() {
    echo "$1" | tr -d '[:space:]'
}

echo "Determining video information for: $VID" | tee -a "$LOG"
FRAMES=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$(convert_path "$VID")" 2>> "$LOG")
FRAMES=$(clean_num "$FRAMES")
echo "Total frames determined: $FRAMES" | tee -a "$LOG"
[[ "$FRAMES" =~ ^[0-9]+$ ]] || { echo "Error: FRAMES is not a valid number: $FRAMES. See $LOG for details."; exit 1; }

get_dimensions() {
    echo $(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$(convert_path "$1")")
}

if [ -n "$START" ]; then
    DIM=$(get_dimensions "$START")
    SW=${DIM%x*}
    SH=${DIM#*x}
    [ -n "$SW" ] && [ -n "$SH" ] && RESIZE=",scale=${SW}:${SH}" || echo "Error: Could not determine START_IMAGE dimensions."
    FRAME_WIDTH=$SW
    FRAME_HEIGHT=$SH
else
    DIM=$(get_dimensions "$VID")
    FRAME_WIDTH=${DIM%x*}
    FRAME_HEIGHT=${DIM#*x}
fi
echo "Frame dimensions: $FRAME_WIDTH by $FRAME_HEIGHT"
FRAME_WIDTH=$(clean_num "$FRAME_WIDTH")
FRAME_HEIGHT=$(clean_num "$FRAME_HEIGHT")

if [ -n "$ASPECT_RATIO" ]; then
    IFS=':' read -r WIDTH HEIGHT <<< "$ASPECT_RATIO"
else
    WIDTH=16; HEIGHT=9
fi
TARGET_RATIO=$(bc -l <<< "scale=10; $WIDTH/$HEIGHT")
echo "Target aspect ratio: $WIDTH:$HEIGHT ($TARGET_RATIO)"

if [ -n "$GRID" ]; then
    if [[ "$GRID" =~ ^x[0-9]+$ ]]; then
        ROWS=${GRID#x}
        COLS=$(bc <<< "scale=0; ($ROWS * $TARGET_RATIO * $FRAME_HEIGHT) / $FRAME_WIDTH")
    elif [[ "$GRID" =~ ^[0-9]+x$ ]]; then
        COLS=${GRID%x}
        ROWS=$(bc <<< "scale=0; ($COLS * $FRAME_WIDTH) / ($TARGET_RATIO * $FRAME_HEIGHT)")
    else
        COLS=${GRID%x*}
        ROWS=${GRID#*x}
    fi
    echo "Using grid: ${COLS}x${ROWS}"
elif [ -n "$ASPECT_RATIO" ]; then
    echo "Searching for optimal grid for $ASPECT_RATIO aspect ratio"
    MIN_RATIO_DIFF=1000000
    for ((y=1; y<=FRAMES; y++)); do
        x=$(( (FRAMES + y - 1) / y ))
        GRID_RATIO=$(bc -l <<< "scale=10; ($x * $FRAME_WIDTH) / ($y * $FRAME_HEIGHT)")
        echo "Grid ${x}x${y}, ratio: $GRID_RATIO" | tee -a "$LOG"
        RATIO_DIFF=$(bc -l <<< "scale=10; ($GRID_RATIO - $TARGET_RATIO)^2")
        if (( $(bc -l <<< "$RATIO_DIFF < $MIN_RATIO_DIFF") )); then
            MIN_RATIO_DIFF=$RATIO_DIFF
            COLS=$x
            ROWS=$y
            echo "Best grid so far: ${COLS}x${ROWS}"
        else
            break
        fi
    done
    echo "Optimal grid for aspect ratio $ASPECT_RATIO: ${COLS}x${ROWS}"
else
    echo "No grid or aspect ratio specified. Using default 3 row grid."
    ROWS=3
    COLS=$(bc <<< "scale=0; ($ROWS * $TARGET_RATIO * $FRAME_HEIGHT) / $FRAME_WIDTH")
fi

echo DEBUG COLS=${COLS} ROWS=${ROWS}
TOTAL=$((COLS * ROWS))
[ "$TOTAL" -lt 2 ] && { echo "Error: The grid must allow for at least 2 images."; exit 1; }
[ "$TOTAL" -gt "$FRAMES" ] && { echo "Error: Grid (${COLS}x${ROWS}) requires more images ($TOTAL) than video frames ($FRAMES)."; exit 1; }

for ((i=0; i<TOTAL; i++)); do
    FRAME_NUMS+=($((i * (FRAMES - 1) / (TOTAL - 1))))
done
echo "Frame numbers: ${FRAME_NUMS[*]}"

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
ffmpeg -loglevel error -y "${inputs[@]}" -filter_complex "$FILTER" -map "[v]" "$(convert_path "$OUT")" >> "$LOG" 2>&1
[ $? -eq 0 ] && [ -f "$OUT" ] && echo "Final image saved as $OUT" || { echo "Error: Failed to create montage. See $LOG for details." | tee -a "$LOG"; cat "$LOG"; exit 1; }

# Interactive mode
if [ "$INTERACTIVE_MODE" = true ]; then
    while true; do
        echo "1. Add deadzone  2. Show frames between points  3. Regenerate montage"
        echo "4. Show current deadzones  5. Exit"
        read -p "Enter your choice: " choice
        case $choice in
            1) read -p "Enter start and end frames: " start end
               add_deadzone $start $end ;;
            2) read -p "Enter start and end frames: " start end
               show_frames_between $start $end ;;
            3) generate_montage $TOTAL $COLS $ROWS "$OUT"
               echo "Montage regenerated: $OUT" ;;
            4) echo "Current deadzones:"; cat "$DEADZONE_FILE" ;;
            5) break ;;
            *) echo "Invalid choice" ;;
        esac
    done
fi

rm -r "$TEMP"
echo "Temporary files deleted. Log file: $LOG"
