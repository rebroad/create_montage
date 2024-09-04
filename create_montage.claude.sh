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
    # TODO - this can be optimized to skip most of the configs
    MIN_RATIO_DIFF=1000000
    start_y=1; end_y=$AVAILABLE_FRAMES; end_x=$AVAILABLE_FRAMES
    [ -n "$target_rows" ] && start_y=$target_rows && end_y=$target_rows
    for ((y=start_y; y<=end_y; y++)); do
        LAST_X_DIFF=1000000
        start_x=$(bc <<< "scale=0; ($y * $TARGET_RATIO * $FRAME_HEIGHT) / $FRAME_WIDTH")
        if [ $((start_x * y)) -gt $AVAILABLE_FRAMES ]; then
            break
        fi
        [ -n "$target_cols" ] && start_x=$target_cols && end_x=$target_cols
        for ((x=start_x; x<=end_x; x++)); do
            GRID_RATIO=$(bc <<< "scale=10; ($x * $FRAME_WIDTH) / ($y * $FRAME_HEIGHT)")
            RATIO_DIFF=$(bc <<< "scale=10; ($GRID_RATIO - $TARGET_RATIO)^2")
            if (( $(bc <<< "$RATIO_DIFF < $MIN_RATIO_DIFF") )); then
                MIN_RATIO_DIFF=$RATIO_DIFF
                COLS=$x
                ROWS=$y
                echo -n "BEST! "
            elif (( $(bc <<< "$LAST_X_DIFF < $RATIO_DIFF") )); then
                echo "x=$x y=$y RATIO_DIFF=$RATIO_DIFF - XBreak"
                break
            fi
            LAST_X_DIFF=$RATIO_DIFF
            echo x=$x y=$y RATIO_DIFF=$RATIO_DIFF
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

deadzones=()

echo "DEBUG: Reading deadzones"
if [ -f "$DEADZONE_FILE" ]; then
    while IFS=':' read start end; do
        end=$(trim "$end")
        deadzones+=($start $end)
        echo "DEBUG: Added deadzone $start:$end"
    done < "$DEADZONE_FILE"
fi

distribute_images() {
    start_frame=${1:-0}
    local end_frame=${2:-$((TOTAL_FRAMES - 1))}
    population=${3:-$TOTAL_IMAGES}
    start_image=${4:-0}
    local end_image=${5:-$((TOTAL_IMAGES - 1))}
    ignore_deadzones=$4
    echo "Distribute_images: $start_frame to $end_frame"

    # Distribute the images evenly among this frames
    for ((i=$start_image; i<=$end_image; i++)); do
        images[$i]=$((start_frame + i * (end_frame - start_frame) / population - 1)))
    done
    echo "For range start: $start_frame to $end_frame\nSelected frames: ${images[*]}"

    if [ -n "$ignore_deadzones" ]; then
        echo Ignoring deadzones
        return
    fi

    abs() {
        if (( $1 < 0 )); then
            echo $(( -1 * $1 ))
        else
            echo $1
        fi
    }

    # Find the largest deadzone (or nearest the center) within the frames for this run
    max_size=0
    closest_to_center
    center=$(( (start_frame + end_frame) / 2))
    for ((i=0; i<${#deadzones[@]}; i+=2)); do
        temp_dead_start=${deadzones[i]}
        temp_dead_end=${deadzones[i+1]}
        if (( temp_dead_end < start_frame || temp_dead_start > end_frame )); then
            continue
        fi
        size=$((temp_dead_end - temp_dead_start + 1))
        midpoint=$(( (temp_dead_start + temp_dead_end) / 2))
        if (( size > max_size || (size == max_size && abs(midpoint-center) < abs(closest_to_center-center)) )); then
            max_size=$size
            closest_to_center=$midpoint
            dead_start=$temp_dead_start
            local dead_end=$temp_dead_end
        fi
    done

    # Find number of images within this deadzone
    dead_images=0
    to_the_left=0
    local to_the_right=0
    echo "Processing deadzone: $dead_start:$dead_end"
    for ((i=$start_image; i<=$end_image; i++)); do
        if [[ ${images[$i]} -lt $dead_start ]]; then
            to_the_left=$((to_the_left + 1))
            left_end_image=$i
        elif [[ ${images[$i]} -ge $dead_start && ${images[$i]} -le $dead_end ]]; then
            dead_images=$((dead_images + 1))
            right_start_image=$(i + 1)
        elif [[ ${images[$i]} -gt $dead_end ];; then
            to_the_right=$((to_the_right + 1))
        fi
    done

    calculate_density() {
        echo "scale=6; $3 / ($2 / $1 + 1)" | bc
    }

    left_density=$(calculate_density $start_frame $((dead_start - 1)) $to_the_left)
    right_density=$(calculate_density $((dead_end + 1)) $end_frame $to_the_right)
    move_left=$(echo "scale=0; $dead_images * $right_density / ($left_density) / 1" | bc)
    local move_right=$((dead_images - move_left))

    # Recursive into either livezone
    if [[ ${move_left} -gt 0 ]; then
        distribute_images $start_frame $((dead_start - 1)) $((to_the_left + move_left)) $start_image $left_end_image
    fi
    if [[ ${move_right} -gt 0 ]; then
        distribute_images $((dead_end + 1)) $end_frame $((to_the_right + move_right)) $right_start_image $end_image
    fi
    echo "For range final: $start_frame to $end_frame\nSelected frames: ${images[*]}"
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
distribute_images
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
               distribute_images ;;
            2) read -p "Enter start and end frames: " start end
               distribute_images $start $end $TOTAL_IMAGES 0 0 1
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
