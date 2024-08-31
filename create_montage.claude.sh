#!/bin/bash

[ "$#" -lt 1 ] && { echo "Usage: $0 <video.mp4> [aspect_ratio] [NxN | Nx | xN] [before_image.png] [after_image.png] [-i]"; exit 1; }

TEMP="/tmp/temp_frames_$$"
LOG="/tmp/ffmpeg_log_$$.log"
mkdir -p "$TEMP" && : > "$LOG"

INTERACTIVE_MODE=false

for arg; do
    case "$arg" in
        *.mp4) INPUT_VIDEO="$arg" ;;
        *:*) ASPECT_RATIO="$arg" ;;
        *x*) GRID="$arg" ;;
        -i) INTERACTIVE_MODE=true ;;
        *) [ -z "$START_IMAGE" ] && START_IMAGE="$arg" || END_IMAGE="$arg" ;;
    esac
done

[ -z "$INPUT_VIDEO" ] && { echo "Error: Video file not specified."; exit 1; }
[ ! -f "$INPUT_VIDEO" ] && { echo "Error: Video file '$INPUT_VIDEO' does not exist."; exit 1; }
OUT="${INPUT_VIDEO%.*}_montage.png"
DEADZONE_FILE="${INPUT_VIDEO%.*}_deadzones.txt"

FFMPEG_VERSION=$(ffmpeg -version | grep -i "built with gcc")
[[ "$FFMPEG_VERSION" == *"MSYS2"* ]] && echo "Detected Windows-native ffmpeg."

convert_path() {
    [[ "$FFMPEG_VERSION" == *"MSYS2"* ]] && cygpath -w "$1" || echo "$1"
}

clean_num() {
    echo "$1" | tr -d '[:space:]'
}

echo "Determining video information for: $INPUT_VIDEO" | tee -a "$LOG"
TOTAL_FRAMES=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$(convert_path "$INPUT_VIDEO")" 2>> "$LOG")
TOTAL_FRAMES=$(clean_num "$TOTAL_FRAMES")
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
    DIM=$(get_dimensions "$INPUT_VIDEO")
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
    for ((y=1; y<=TOTAL_FRAMES; y++)); do
        x=$(( (TOTAL_FRAMES + y - 1) / y ))
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

echo "DEBUG: COLS=${COLS} ROWS=${ROWS}"
TOTAL_IMAGES=$((COLS * ROWS))
[ "$TOTAL_IMAGES" -lt 2 ] && { echo "Error: The grid must allow for at least 2 images."; exit 1; }
[ "$TOTAL_IMAGES" -gt "$TOTAL_FRAMES" ] && { echo "Error: Grid (${COLS}x${ROWS}) requires more images ($TOTAL_IMAGES) than video frames ($TOTAL_FRAMES)."; exit 1; }

add_deadzone() {
    local start=$1
    local end=$2
    [ -z "$end" ] && end=$start  # If end is not provided, use start as end
    echo "$start:$end" >> "$DEADZONE_FILE"
    # Hide the file on Windows after writing
    [[ "$OSTYPE" == "cygwin"* ]] && attrib +h "$(cygpath -w "$DEADZONE_FILE")" >/dev/null 2>&1
    local temp_file="${DEADZONE_FILE}.temp"
    sort -n -t: -k1,1 "$DEADZONE_FILE" | uniq > "$temp_file"
    local prev_start=""
    local prev_end=""
    : > "$DEADZONE_FILE"
    while IFS=':' read -r start end; do
        if [ -z "$prev_start" ]; then
            prev_start=$start
            prev_end=$end
        elif [ $start -le $((prev_end + 1)) ]; then
            prev_end=$((end > prev_end ? end : prev_end))
        else
            echo "${prev_start}:${prev_end}" >> "$DEADZONE_FILE"
            prev_start=$start
            prev_end=$end
        fi
    done < "$temp_file"
    [ -n "$prev_start" ] && echo "${prev_start}:${prev_end}" >> "$DEADZONE_FILE"
    rm "$temp_file"
    echo "Added and merged deadzones. Current deadzones:"
    cat "$DEADZONE_FILE"
}

# Frame distribution function
frame_distribution() {
    local -a livezones=()
    local -a deadzones=()
    
    # Read deadzones
    if [ -f "$DEADZONE_FILE" ]; then
        while IFS=':' read -r start end; do
            deadzones+=("$start:$end")
        done < "$DEADZONE_FILE"
    fi
    
    # Sort and validate deadzones
    local prev_end="-1"
    IFS=$'\n' deadzones=($(sort -n -t: -k1,1 <<< "${deadzones[*]}"))
    for zone in "${deadzones[@]}"; do
        IFS=':' read -r start end <<< "$zone"
        if [ "$start" -le "$prev_end" ]; then
            echo "Error: Overlapping or invalid deadzones detected. Please fix the deadzone configuration."
            exit 1
        fi
        prev_end=$end
    done

    # Create livezones
    prev_end="-1"
    for zone in "${deadzones[@]}"; do
        IFS=':' read -r start end <<< "$zone"
        if [ "$start" -gt "$((prev_end + 1))" ]; then
            livezones+=("$((prev_end + 1)):$((start - 1)):0:$((prev_end + 1 == 0 ? 0 : prev_end - (prev_end + 1) + 1)):$((end - start + 1))")
        fi
        prev_end=$end
    done
    if [ "$prev_end" -lt "$((TOTAL_FRAMES - 1))" ]; then
        livezones+=("$((prev_end + 1)):$((TOTAL_FRAMES - 1)):0:$((prev_end - (prev_end + 1) + 1)):0")
    fi

    # Distribute images among livezones
    local remaining_images=$TOTAL_IMAGES
    local total_livezone_space=0
    for zone in "${livezones[@]}"; do
        IFS=':' read -r start end population prev_deadzone next_deadzone <<< "$zone"
        total_livezone_space=$((total_livezone_space + end - start + 1))
    done

    for ((i=0; i<${#livezones[@]}; i++)); do
        IFS=':' read -r start end population prev_deadzone next_deadzone <<< "${livezones[$i]}"
        zone_space=$((end - start + 1))
        zone_images=$((remaining_images * zone_space / total_livezone_space))
        livezones[$i]="$start:$end:$zone_images:$prev_deadzone:$next_deadzone"
        remaining_images=$((remaining_images - zone_images))
        total_livezone_space=$((total_livezone_space - zone_space))
    done

    # Distribute remaining images
    while [ "$remaining_images" -gt 0 ]; do
        min_density=999999
        min_index=-1
        for ((i=0; i<${#livezones[@]}; i++)); do
            IFS=':' read -r start end population prev_deadzone next_deadzone <<< "${livezones[$i]}"
            density=$(bc <<< "scale=6; $population / ($end - $start + 1)")
            if (( $(bc <<< "$density < $min_density") )); then
                min_density=$density
                min_index=$i
            elif (( $(bc <<< "$density == $min_density") )) && [ $((end - start + 1)) -gt $((${livezones[$min_index]%:*:*:*:*} - ${livezones[$min_index]#*:*:*:*:})) ]; then
                min_index=$i
            fi
        done
        IFS=':' read -r start end population prev_deadzone next_deadzone <<< "${livezones[$min_index]}"
        livezones[$min_index]="$start:$end:$((population + 1)):$prev_deadzone:$next_deadzone"
        remaining_images=$((remaining_images - 1))
    done

    # Select frames for each livezone
    frame_nums=()
    for zone in "${livezones[@]}"; do
        IFS=':' read -r start end population prev_deadzone next_deadzone <<< "$zone"
        range=$((end - start))
        step=$(echo "scale=10; ($range - ($prev_deadzone + $next_deadzone) / 2) / ($population - 1)" | bc -l)
        for ((i=0; i<population; i++)); do
            frame_nums+=($(printf "%.0f" $(echo "$start + ($prev_deadzone / 2) + $i * $step" | bc -l)))
        done
    done

    echo "Frame distribution complete. Selected frames: ${frame_nums[*]}"
}

generate_montage() {
    local output_file=$1
    local start_frame=${2:-0}
    local end_frame=${3:-$((TOTAL_FRAMES - 1))}

    local inputs=()
    local what="video"
    [ -n "$2" ] && { what="selected range"; }
    [ -n "$3" ] && { what="selected range"; }
    [ -n "$RESIZE" ] && { local resizing=" and resizing"; }
    for i in "${!frame_nums[@]}"; do
        FRAME_NUM=${frame_nums[$i]}
        OUT_FRAME="$TEMP/frame_$i.png"
        PERCENT=$(echo "scale=2; ($FRAME_NUM - $start_frame) * 100 / $range" | bc)
        echo "Extracting frame $i ($PERCENT% of $what)$resizing"
        if [ "$INTERACTIVE_MODE" = true ]; then
            ffmpeg -loglevel error -y -i "$(convert_path "$INPUT_VIDEO")" -vf "select=eq(n\,${FRAME_NUM}),drawtext=fontfile=/path/to/font.ttf:fontsize=24:fontcolor=white:box=1:boxcolor=black@0.5:boxborderw=5:x=10:y=10:text='${FRAME_NUM}'$RESIZE" -vsync vfr "$(convert_path "$OUT_FRAME")" >> "$LOG" 2>&1
        else
            ffmpeg -loglevel error -y -i "$(convert_path "$INPUT_VIDEO")" -vf "select=eq(n\,${FRAME_NUM})$RESIZE" -vsync vfr "$(convert_path "$OUT_FRAME")" >> "$LOG" 2>&1
        fi
        [ ! -f "$OUT_FRAME" ] && { echo "Error: Failed to extract frame $i. See $LOG"; exit 1; }
        inputs+=("-i" "$(convert_path "$OUT_FRAME")")
    done

    # Create montage
    local FILTER=""
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
    echo "inputs = ${inputs[@]}" | tee -a "$LOG"

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
        echo "Current frame distribution: ${frame_nums[*]}"
        echo "1. Add deadzone  2. Show frames between points  3. Generate/Regenerate montage"
        echo "4. Show current deadzones  5. Exit"
        read -p "Enter your choice: " choice
        case $choice in
            1) read -p "Enter start and end frames: " start end
               add_deadzone $start $end
               frame_distribution ;;
            2) read -p "Enter start and end frames: " start end
               generate_montage "${OUT%.*}_intermediate.png" $start $end
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
