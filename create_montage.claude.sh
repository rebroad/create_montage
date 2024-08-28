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

merge_deadzones() {
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
}

read_deadzones() {
    deadzones=()
    if [ -f "$DEADZONE_FILE" ]; then
        while IFS=':' read -r start end; do
            deadzones+=("$start:$end")
        done < "$DEADZONE_FILE"
    fi
}

is_in_deadzone() {
    local frame=$1
    for range in "${deadzones[@]}"; do
        IFS=':' read -r start end <<< "$range"
        if (( $(echo "$frame >= $start && $frame <= $end" | bc -l) )); then
            return 0  # Frame is in a deadzone
        fi
    done
    return 1  # Frame is not in a deadzone
}

redistribute_frames() {
    local start_frame=$1
    local end_frame=$2
    local range=$((end_frame - start_frame))
    local min_gap=$(echo "scale=2; $range / (${#frame_nums[@]} * 2)" | bc)
    echo "DEBUG: min_gap = $min_gap"
    for ((i=1; i<${#frame_nums[@]}-1; i++)); do
        local prev=${frame_nums[i-1]}
        local curr=${frame_nums[i]}
        local next=${frame_nums[i+1]}

        echo "DEBUG: Checking frame $curr (prev: $prev, next: $next)"
        if (( $(echo "$curr - $prev < $min_gap" | bc -l) )) || (( $(echo "$next - $curr < $min_gap" | bc -l) )); then
            echo "DEBUG: Gap too small for frame $curr"
            # Find the nearest larger gap
            local j=$i
            while ((j > 0)) && ((j < ${#frame_nums[@]}-1)); do
                local gap=$((frame_nums[j+1] - frame_nums[j-1]))
                echo "DEBUG: Checking gap between ${frame_nums[j-1]} and ${frame_nums[j+1]}: $gap"
                if (( $(echo "$gap > 3 * $min_gap" | bc -l) )); then
                    # Move the current frame to the middle of this larger gap
                    local new_pos=$(( (frame_nums[j-1] + frame_nums[j+1]) / 2 ))
                    # Ensure we're not creating a duplicate
                    if ((new_pos != frame_nums[j-1] && new_pos != frame_nums[j+1])); then
                        local old_pos=${frame_nums[i]}
                        frame_nums[i]=$new_pos
                        echo "DEBUG: Moved frame from $old_pos to $new_pos"
                        break
                    fi
                fi
                ((j++))
                [ $j -eq ${#frame_nums[@]}-1 ] && j=1  # Wrap around to the beginning
            done
        fi
    done
}

generate_montage() {
    local output_file=$1
    local start_frame=${2:-0}
    local end_frame=${3:-$((FRAMES - 1))}
    local frame_nums=()

    # Step 1: Select evenly spaced frames ignoring deadzones
    local range=$((end_frame - start_frame))
    local step=$(echo "scale=10; $range / ($TOTAL - 1)" | bc -l)
    for ((i=0; i<TOTAL; i++)); do
        frame_nums+=($(printf "%.0f" $(echo "$start_frame + $i * $step" | bc -l)))
    done

    # Step 2: Adjust for deadzones
    read_deadzones
    for dz_range in "${deadzones[@]}"; do
        IFS=':' read -r dz_start dz_end <<< "$dz_range"
        for i in "${!frame_nums[@]}"; do
            if ((frame_nums[i] >= dz_start && frame_nums[i] <= dz_end)); then
                # Move frame out of deadzone
                if ((i == 0 || frame_nums[i] - dz_start < dz_end - frame_nums[i])); then
                    frame_nums[i]=$((dz_start - 1))
                else
                    frame_nums[i]=$((dz_end + 1))
                fi
            fi
        done
    done

    # Step 3: Redistribute frames if too tightly packed
    redistribute_frames $start_frame $end_frame

    echo "Frame numbers: ${frame_nums[*]}"

    # Extract frames and create montage
    local inputs=()
    for i in "${!frame_nums[@]}"; do
        FRAME_NUM=${frame_nums[$i]}
        OUT_FRAME="$TEMP/frame_$i.png"
        PERCENT=$(echo "scale=2; ($FRAME_NUM - $start_frame) * 100 / $range" | bc -l)
        echo "Extracting frame $i ($PERCENT% of selected range) and resizing."
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
        FILTER=$(printf "[%d:v]" $(seq 0 $((TOTAL-1))))
        FILTER+="hstack=inputs=$TOTAL[v]"
    elif [ "$COLS" -eq 1 ]; then
        FILTER=$(printf "[%d:v]" $(seq 0 $((TOTAL-1))))
        FILTER+="vstack=inputs=$TOTAL[v]"
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

add_deadzone() {
    local start=$1
    local end=$2
    [ -z "$end" ] && end=$start  # If end is not provided, use start as end
    echo "$start:$end" >> "$DEADZONE_FILE"
    merge_deadzones
    echo "Added and merged deadzones. Current deadzones:"
    cat "$DEADZONE_FILE"
}

show_frames_between() {
    local start=$1
    local end=$2
    local temp_montage="${OUT%.*}_intermediate.png"
    generate_montage "$temp_montage" $start $end
    echo "Intermediate frames montage saved as $temp_montage"
}

# Main execution
if [ "$INTERACTIVE_MODE" = false ]; then
    generate_montage "$OUT"
fi

# Interactive mode
if [ "$INTERACTIVE_MODE" = true ]; then
    while true; do
        echo "1. Add deadzone  2. Show frames between points  3. Generate/Regenerate montage"
        echo "4. Show current deadzones  5. Exit"
        read -p "Enter your choice: " choice
        case $choice in
            1) read -p "Enter start and end frames: " start end
               add_deadzone $start $end ;;
            2) read -p "Enter start and end frames: " start end
               show_frames_between $start $end ;;
            3) generate_montage "$OUT" ;;
            4) echo "Current deadzones:"; cat "$DEADZONE_FILE" ;;
            5) break ;;
            *) echo "Invalid choice" ;;
        esac
    done
fi

rm -r "$TEMP"
echo "Temporary files deleted. Log file: $LOG"
