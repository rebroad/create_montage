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

add_deadzone() {
    local start=$1
    local end=$2
    echo "$start:$end" >> "$DEADZONE_FILE"
    merge_deadzones
    echo "Added and merged deadzones. Current deadzones:"
    cat "$DEADZONE_FILE"
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

generate_montage() {
    local total_frames=$1
    local cols=$2
    local rows=$3
    local output_file=$4
    local frame_nums=()

    read_deadzones

    # Always include first and last frames
    frame_nums=(0 $((FRAMES - 1)))
    local frames_to_select=$((total_frames - 2))

    # Calculate initial ideal step size
    local ideal_step=$(echo "scale=10; ($FRAMES - 1) / ($total_frames - 1)" | bc -l)
    
    local current_step=$ideal_step
    local last_adjusted_index=0
    local current_frame=0

    for ((i=1; i < total_frames - 1; i++)); do
        current_frame=$(echo "$current_frame + $current_step" | bc -l)
        local target=$(printf "%.0f" $current_frame)
        
        if is_in_deadzone $target; then
            # Find the closest valid frame
            local before_deadzone=$target
            local after_deadzone=$target
            
            while is_in_deadzone $before_deadzone && [ $before_deadzone -gt 0 ]; do
                before_deadzone=$((before_deadzone - 1))
            done
            
            while is_in_deadzone $after_deadzone && [ $after_deadzone -lt $FRAMES ]; do
                after_deadzone=$((after_deadzone + 1))
            done
            
            # Choose the closest valid frame
            if [ $((target - before_deadzone)) -le $((after_deadzone - target)) ] && [ $before_deadzone -gt 0 ]; then
                target=$before_deadzone
            else
                target=$after_deadzone
            fi
            
            # Adjust previous frames if necessary
            local frames_to_adjust=$((i - last_adjusted_index))
            if [ $frames_to_adjust -gt 0 ]; then
                local new_step=$(echo "scale=10; ($target - ${frame_nums[$last_adjusted_index]}) / $frames_to_adjust" | bc -l)
                local adjust_frame=${frame_nums[$last_adjusted_index]}
                
                for ((j=last_adjusted_index + 1; j<=i; j++)); do
                    adjust_frame=$(echo "$adjust_frame + $new_step" | bc -l)
                    frame_nums[$j]=$(printf "%.0f" $adjust_frame)
                done
            fi
            
            last_adjusted_index=$i
            current_frame=$target
            current_step=$ideal_step
        fi
        
        frame_nums+=($target)
    done

    # Sort frame numbers
    IFS=$'\n' sorted=($(sort -n <<<"${frame_nums[*]}"))
    unset IFS
    frame_nums=("${sorted[@]}")

    echo "Frame numbers: ${frame_nums[*]}"

    # Extract frames and create montage
    local inputs=()
    for i in "${!frame_nums[@]}"; do
        FRAME_NUM=${frame_nums[$i]}
        OUT_FRAME="$TEMP/frame_$i.png"
        PERCENT=$(echo "scale=2; $FRAME_NUM * 100 / ($FRAMES - 1)" | bc -l)
        echo "Extracting frame $i ($PERCENT% of video) and resizing."
        if [ "$INTERACTIVE_MODE" = true ]; then
            ffmpeg -loglevel error -y -i "$(convert_path "$VID")" -vf "select=eq(n\,${FRAME_NUM}),drawtext=fontfile=/path/to/font.ttf:fontsize=24:fontcolor=white:box=1:boxcolor=black@0.5:boxborderw=5:x=10:y=10:text='${FRAME_NUM}'$RESIZE" -vsync vfr "$(convert_path "$OUT_FRAME")" >> "$LOG" 2>&1
        else
            ffmpeg -loglevel error -y -i "$(convert_path "$VID")" -vf "select=eq(n\,${FRAME_NUM})$RESIZE" -vsync vfr "$(convert_path "$OUT_FRAME")" >> "$LOG" 2>&1
        fi
        [ ! -f "$OUT_FRAME" ] && { echo "Error: Failed to extract frame $i. See $LOG"; exit 1; }
        inputs+=("-i" "$(convert_path "$OUT_FRAME")")
    done

    FILTER=""
    if [ "$rows" -eq 1 ]; then
        FILTER=$(printf "[%d:v]" $(seq 0 $((cols-1))))
        FILTER+="hstack=inputs=$cols[v]"
    elif [ "$cols" -eq 1 ]; then
        FILTER=$(printf "[%d:v]" $(seq 0 $((rows-1))))
        FILTER+="vstack=inputs=$rows[v]"
    else
        for ((r=0; r<rows; r++)); do
            FILTER+=$(printf "[%d:v]" $(seq $((r*cols)) $((r*cols+cols-1))))
            FILTER+="hstack=inputs=$cols[row$r]; "
        done
        FILTER+=$(printf "[row%d]" $(seq 0 $((rows-1))))
        FILTER+="vstack=inputs=$rows[v]"
    fi

    echo "Creating montage..." | tee -a "$LOG"
    echo inputs = "${inputs[@]}" | tee -a "$LOG"
    ffmpeg -loglevel error -y "${inputs[@]}" -filter_complex "$FILTER" -map "[v]" "$(convert_path "$output_file")" >> "$LOG" 2>&1
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
    local step=$(( (end - start) / 10 ))  # Show 10 frames between start and end
    [ $step -lt 1 ] && step=1

    local temp_montage="${OUT%.*}_intermediate_${start}_${end}.png"
    local frame_nums=()

    for ((i=start; i<=end; i+=step)); do
        frame_nums+=($i)
    done

    generate_montage ${#frame_nums[@]} 5 2 "$temp_montage"
    echo "Intermediate frames montage saved as $temp_montage"
}

# Main execution
generate_montage $TOTAL $COLS $ROWS "$OUT"
echo "Montage generated: $OUT"

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
