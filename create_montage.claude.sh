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
        *) [ -z "$START_IMAGE" ] && START_IMAGE="$arg" || END_IMAGE="$arg" ;;
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

trim() {
    echo "$1" | tr -d '[:space:]'
}

echo "Determining video information for: $VID" | tee -a "$LOG"
TOTAL_FRAMES=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$(convert_path "$VID")" 2>> "$LOG")
TOTAL_FRAMES=$(trim "$TOTAL_FRAMES")
echo "Total frames determined: $TOTAL_FRAMES" | tee -a "$LOG"
[[ "$TOTAL_FRAMES" =~ ^[0-9]+$ ]] || { echo "Error: TOTAL_FRAMES is not a valid number: $TOTAL_FRAMES. See $LOG for details."; exit 1; }

get_dimensions() {
    ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$(convert_path "$1")"
}

if [ -n "$START_IMAGE" ]; then
    DIM=$(get_dimensions "$START_IMAGE")
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
FRAME_WIDTH=$(trim "$FRAME_WIDTH")
FRAME_HEIGHT=$(trim "$FRAME_HEIGHT")

if [ -n "$ASPECT_RATIO" ]; then
    IFS=':' read WIDTH HEIGHT <<< "$ASPECT_RATIO"
else
    WIDTH=16; HEIGHT=9
fi
TARGET_RATIO=$(bc -l <<< "scale=10; $WIDTH/$HEIGHT")
echo "Target aspect ratio: $WIDTH:$HEIGHT ($TARGET_RATIO)"

calc_available_frames() {
    local num=$TOTAL_FRAMES
    if [ -f "$DEADZONE_FILE" ]; then
        while IFS=':' read start end; do
            end=$(trim "$end")
            num=$((num - (end - start + 1)))
        done < "$DEADZONE_FILE"
    fi
    echo "$num"
}
AVAILABLE_FRAMES=$(calc_available_frames)
echo "Total available frames (excluding deadzones): $AVAILABLE_FRAMES"

find_optimal_grid() {
    local target_rows=$1
    local target_cols=$2
    echo "Searching for optimal grid for $WIDTH:$HEIGHT aspect ratio"
    MIN_RATIO_DIFF=1000000
    for ((y=1; y<=AVAILABLE_FRAMES; y++)); do
        for ((x=1; x<=AVAILABLE_FRAMES; x++)); do
            [ -n "$target_rows" ] && [ "$y" -ne "$target_rows" ] && continue
            [ -n "$target_cols" ] && [ "$x" -ne "$target_cols" ] && continue
            GRID_RATIO=$(bc -l <<< "scale=10; ($x * $FRAME_WIDTH) / ($y * $FRAME_HEIGHT)")
            RATIO_DIFF=$(bc -l <<< "scale=10; ($GRID_RATIO - $TARGET_RATIO)^2")
            if (( $(bc -l <<< "$RATIO_DIFF < $MIN_RATIO_DIFF") )); then
                MIN_RATIO_DIFF=$RATIO_DIFF
                COLS=$x
                ROWS=$y
            fi
        done
    done
    echo "Optimal grid: ${COLS}x${ROWS}"
}

if [ -n "$GRID" ]; then
    if [[ "$GRID" =~ ^x[0-9]+$ ]]; then
        find_optimal_grid ${GRID#x}
    elif [[ "$GRID" =~ ^[0-9]+x$ ]]; then
        find_optimal_grid . ${GRID%x}
    else
        COLS=${GRID%x*}
        ROWS=${GRID#*x}
    fi
elif [ -n "$ASPECT_RATIO" ]; then
    find_optimal_grid
else
    echo "No grid or aspect ratio specified. Using default 3 row grid."
    find_optimal_grid 3
fi

echo "Using grid: ${COLS}x${ROWS}"
TOTAL_IMAGES=$((COLS * ROWS))
[ "$TOTAL_IMAGES" -lt 2 ] && { echo "Error: The grid must allow for at least 2 images."; exit 1; }
[ "$TOTAL_IMAGES" -gt "$TOTAL_FRAMES" ] && { echo "Error: Grid (${COLS}x${ROWS}) requires more images ($TOTAL_IMAGES) than video frames ($TOTAL_FRAMES)."; exit 1; }

add_deadzone() {
    echo "$1:$2" >> "$DEADZONE_FILE"
    sort -n -t: -k1,1 -k2,2 "$DEADZONE_FILE" | awk -F: '
        BEGIN { OFS=":" }
        NR==1 { prev_start=$1; prev_end=$2; next }
        $1 <= prev_end+1 { prev_end = ($2 > prev_end ? $2 : prev_end); next }
        { print prev_start, prev_end; prev_start=$1; prev_end=$2 }
        END { print prev_start, prev_end }
    ' > "${DEADZONE_FILE}.tmp" && mv "${DEADZONE_FILE}.tmp" "$DEADZONE_FILE"
    [[ "$OSTYPE" == "cygwin"* ]] && attrib +h "$(cygpath -w "$DEADZONE_FILE")" >/dev/null 2>&1
    echo "Added and merged deadzones. Current deadzones:"
    cat "$DEADZONE_FILE"
}

frame_distribution() {
    echo "DEBUG: Entering frame_distribution function"
    livezones=()
    deadzones=()

    echo "DEBUG: Reading deadzones"
    if [ -f "$DEADZONE_FILE" ]; then
        while IFS=':' read start end; do
            end=$(trim "$end")
            deadzones+=("$start:$end")
            echo "DEBUG: Added deadzone $start:$end"
        done < "$DEADZONE_FILE"
    fi
    
    echo "DEBUG: Creating livezones"
    prev_end="-1"
    prev_deadzone_size=0
    for zone in "${deadzones[@]}"; do
        IFS=':' read start end <<< "$zone"
        end=$(trim "$end")
        if [ "$start" -gt "$((prev_end + 1))" ]; then
            next_deadzone_size=$((end - start + 1))
            livezone="$((prev_end + 1)):$((start - 1)):0:$prev_deadzone_size:$next_deadzone_size"
            livezones+=("$livezone")
            echo "DEBUG: Added livezone $livezone"
        fi
        prev_end=$end
        prev_deadzone_size=$next_deadzone_size
    done
    if [ "$prev_end" -lt "$((TOTAL_FRAMES - 1))" ]; then
        livezone="$((prev_end + 1)):$((TOTAL_FRAMES - 1)):0:$prev_deadzone_size:0"
        livezones+=("$livezone")
        echo "DEBUG: Added final livezone $livezone"
    fi

    echo "DEBUG: Distributing images across livezones"
    local remaining_frames=$(calc_available_frames)
    local remaining_images=$TOTAL_IMAGES
    for ((i=0; i<${#livezones[@]}; i++)); do
        IFS=':' read start end population prev_deadzone next_deadzone <<< "${livezones[$i]}"
        zone_space=$((end - start + 1))
        zone_images=$((remaining_images * zone_space / remaining_frames))
        livezones[$i]="$start:$end:$zone_images:$prev_deadzone:$next_deadzone"
        echo "DEBUG: Updated livezone $i: ${livezones[$i]}"
        remaining_images=$((remaining_images - zone_images))
        remaining_frames=$((remaining_frames - zone_space))
    done

    echo "DEBUG: Selecting frames for each livezone"
    frame_nums=()
    for zone in "${livezones[@]}"; do
        IFS=':' read start end population prev_deadzone next_deadzone <<< "$zone"
        range=$((end - start))
        step=$(bc -l <<< "scale=10; $range / ($population - 1)") # Risk of divide by 0
        echo "DEBUG: Zone $start:$end, population: $population, step: $step"
        for ((i=0; i<population; i++)); do
            frame=$(printf "%.0f" $(bc -l <<< "$start + ($i * $step)"))
            frame_nums+=($frame)
        done
    done

    echo "Selected frames: ${frame_nums[*]}"
}

generate_montage() {
    output_file=$1
    start_frame=${2:-0}
    end_frame=${3:-$((TOTAL_FRAMES - 1))}
    range=$((end_frame - start_frame))
    inputs=()
    what="video"
    [ -n "$2" ] && { what="selected range"; }
    [ -n "$3" ] && { what="selected range"; }
    [ -n "$RESIZE" ] && { resizing=" and resizing"; }
    for i in "${!frame_nums[@]}"; do
        FRAME_NUM=${frame_nums[$i]}
        OUT_FRAME="$TEMP/frame_$i.png"
        PERCENT=$(echo "scale=2; ($FRAME_NUM - $start_frame) * 100 / $range" | bc)
        echo "Extracting frame $i ($PERCENT% of $what)$resizing"
        if [ "$INTERACTIVE_MODE" = true ]; then
            ffmpeg -loglevel error -y -i "$(convert_path "$VID")" -vf "select=eq(n\,${FRAME_NUM}),drawtext=fontfile=/path/to/font.ttf:fontsize=24:fontcolor=white:box=1:boxcolor=black@0.5:boxborderw=5:x=10:y=10:text='${FRAME_NUM}'$RESIZE" -vsync vfr "$(convert_path "$OUT_FRAME")" >> "$LOG" 2>&1
        else
            ffmpeg -loglevel error -y -i "$(convert_path "$VID")" -vf "select=eq(n\,${FRAME_NUM})$RESIZE" -vsync vfr "$(convert_path "$OUT_FRAME")" >> "$LOG" 2>&1
        fi
        [ ! -f "$OUT_FRAME" ] && { echo "Error: Failed to extract frame $i. See $LOG"; exit 1; }
        inputs+=("-i" "$(convert_path "$OUT_FRAME")")
    done

    # Create montage
    FILTER=""
    if [ "$ROWS" -eq 1 ]; then
        FILTER=$(printf "[%d:v]" $(seq 0 $((TOTAL_IMAGES-1))))
        FILTER+="hstack=inputs=$TOTAL_IMAGES[v]"
    elif [ "$COLS" -eq 1 ]; then
        FILTER=$(printf "[%d:v]" $(seq 0 $((TOTAL_IMAGES-1))))
        FILTER+="vstack=inputs=$TOTAL_IMAGES[v]"
    else
        for ((r=0; r<ROWS; r++)); do
            FILTER+=$(printf "[%d:v]" $(seq $((r*COLS)) $((r*COLS+COLS-1))))
            FILTER+="hstack=inputs=$COLS[row$r];"
        done
        FILTER+=$(printf "[row%d]" $(seq 0 $((ROWS-1))))
        FILTER+="vstack=inputs=$ROWS[v]"
    fi

    echo "Creating montage..." | tee -a "$LOG"
    echo "Filter complex: $FILTER" | tee -a "$LOG"

    # Suppress Fontconfig warnings
    export FONTCONFIG_FILE="/dev/null"

    ffmpeg -loglevel error -y "${inputs[@]}" -filter_complex "$FILTER" -map "[v]" "$(convert_path "$output_file")" 2>> "$LOG"
    [ $? -eq 0 ] && [ -f "$output_file" ] && echo "Montage saved as $output_file" || { echo "Error: Failed to create montage. See $LOG for details." | tee -a "$LOG"; cat "$LOG"; exit 1; }
}

# Main execution
frame_distribution
if [ "$INTERACTIVE_MODE" = false ]; then
    generate_montage "$OUT"
else
    while true; do
        echo "1. Add deadzone  2. Show frames between points  3. Generate/Regenerate montage"
        echo "4. Show current deadzones  5. Exit"
        read -p "Enter your choice: " choice
        case $choice in
            1) read -p "Enter start and end frames: " start end
               add_deadzone $start $end
               frame_distribution ;;
            2) read -p "Enter start and end frames: " start end
               generate_montage "${OUT%.*}_intermediate.png" $start $end # This no longer works as it needs to ignore deadzones and re-do frame selection
               echo "Intermediate frames montage saved as ${OUT%.*}_intermediate.png" ;;
            3) generate_montage "$OUT" ;;
            4) echo "Current deadzones:"; cat "$DEADZONE_FILE" ;;
            5) break ;;
            *) echo "Invalid choice" ;;
        esac
    done
fi

rm -r "$TEMP"
echo "Temporary files deleted. Log file: $LOG"
