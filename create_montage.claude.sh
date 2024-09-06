#!/bin/bash

[ "$#" -lt 1 ] && { echo "Usage: $0 <video.mp4> [aspect_ratio] [NxN | Nx | xN] [before_image.png] [after_image.png] [-i] [-n] [-z]"; exit 1; }

TEMP="/tmp/temp_frames_$$"
LOG="/tmp/ffmpeg_log_$$.log"
mkdir -p "$TEMP" && : > "$LOG"

INTERACTIVE_MODE=false
SHOW_NUMBERS=false
SHOW_ZONES=false

for arg; do
    case "$arg" in
        *.mp4) VID="$arg" ;;
        *:*) ASPECT_RATIO="$arg" ;;
        *x*) GRID="$arg" ;;
        -i) INTERACTIVE_MODE=true ;;
        -n) SHOW_NUMBERS=true ;;
        -z) SHOW_ZONES=true ;;
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

load_deadzones() {
    AVAILABLE_FRAMES=$TOTAL_FRAMES
    deadzones=()
    if [ -f "$DEADZONE_FILE" ]; then
        while IFS=':' read start end; do
            end=$(trim "$end")
            AVAILABLE_FRAMES=$((AVAILABLE_FRAMES - (end - start + 1)))
            deadzones+=("$start" "$end")
            echo "DEBUG: Added deadzone $start:$end"
        done < "$DEADZONE_FILE"
    fi
    echo "Total available frames (excluding deadzones): $AVAILABLE_FRAMES"
}

load_deadzones

find_optimal_grid() {
    local target_rows=$1
    local target_cols=$2
    echo "Searching for optimal grid for $WIDTH:$HEIGHT aspect ratio"
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
    echo "$1:${2:-$1}" >> "$DEADZONE_FILE"
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
    load_deadzones
}

dist_images() {
    local start_frame=${1:-0}
    local ignore_deadzones=""
    if [ $start_frame -eq -1 ]; then
        start_frame=0
        ignore_deadzones=1
    fi
    local end_frame=${2:-$((TOTAL_FRAMES - 1))}
    local start_image=${3:-0}
    local end_image=${4:-$((TOTAL_IMAGES - 1))}
    if [ $start_frame -eq 0 ] && [ $end_frame -eq $((TOTAL_FRAMES - 1)) ]; then
        zone_id=1
    else
        zone_id=$((zone_id + 1))
    fi
    echo "Entering dist_images: frames=$start_frame-$end_frame images=$start_image-$end_image zone=$zone_id"

    if [ $start_image -eq $end_image ]; then
        frame=${image[$start_image]}
        if [ $frame -ne 0 ] && [ $frame -ne $((TOTAL_FRAMES - 1)) ]; then
            image[$start_image]=$(( (start_frame + end_frame) / 2))
            echo "Placing image $start_frame in center of $start_frame:$end_frame at frame=${image[$start_image]}"
        else
            echo "Keep image $start_image at its current position (${image[$start_image]}) as it's special."
        fi
        direction=0
    else
        direction=$((end_image > start_image ? 1 : -1))
        step=$(echo "scale=6; ($end_frame - $start_frame) / ($end_image - $start_image)" | bc)
        echo Distribute images "$start_image"-"$end_image" between frames "$start_frame"-"$end_frame" step=$step
    fi

    # Distribute the images evenly among these frames
    for ((i=start_image; i!=end_image+direction; i+=direction)); do
        frame=$(echo "($start_frame + (($i - $start_image) * $step)+0.5)/1" | bc)
        echo image=$i frame: ${image[$i]} -> $frame
        if [ -n "${image[$i]}" ] && [ $frame -eq "${image[$i]}" ]; then
            break
        fi
        image[$i]=$frame
        livezones[$i]=$zone_id
    done
    echo "After dist frames: ${image[*]}"

    if [ "$ignore_deadzones" != "" ]; then
        echo Ignoring deadzones = ".$ignore_deadzones."
        return
    fi

    # Find the largest deadzone (or nearest the center) within the frames for this run
    max_size=0
    closest_to_center=0
    center=$(( (start_frame + end_frame) / 2))

    local min_frame=$(( start_frame < end_frame ? start_frame : end_frame ))
    local max_frame=$(( start_frame < end_frame ? end_frame : start_frame ))
    local dead_start
    local dead_end

    echo Finding largest deadzone within frames $min_frame to $max_frame
    for ((i=0; i<${#deadzones[@]}; i+=2)); do
        temp_dead_start=${deadzones[i]}
        temp_dead_end=${deadzones[i+1]}
        #echo temp_dead_start=$temp_dead_start temp_dead_end=$temp_dead_end
        if (( temp_dead_end < min_frame || temp_dead_start > max_frame )); then
            continue
        fi
        size=$((temp_dead_end - temp_dead_start + 1))
        midpoint=$(( (temp_dead_start + temp_dead_end) / 2))
        dist_from_center=$((midpoint - center))
        best_dist_from_center=$((closest_to_center - center))
        if (( size > max_size )) || (( size == max_size && ${dist_from_center#-} < ${best_dist_from_center#-} )); then
            max_size=$size
            closest_to_center=$midpoint
            dead_start=$temp_dead_start
            dead_end=$temp_dead_end
            #echo best deadzone found so far: $dead_start:$dead_end
        fi
    done

    if [ $max_size -eq 0 ]; then
        echo No deadzones within frames $min_frame to $max_frame
        return
    fi

    # Find number of images within this deadzone
    dead_images=0
    local images_left=0
    local images_right=0
    echo "Processing deadzone: $dead_start:$dead_end"
    local min_image=$(( start_image < end_image ? start_image : end_image ))
    local max_image=$(( start_image < end_image ? end_image : start_image ))
    for ((i=min_image; i<=max_image; i++)); do
        if [[ ${image[$i]} -lt $dead_start ]]; then
            images_left=$((images_left + 1))
            local left_end_image=$i
        elif [[ ${image[$i]} -ge $dead_start && ${image[$i]} -le $dead_end ]]; then
            dead_images=$((dead_images + 1))
            local right_start_image=$((i + 1))
        elif [[ ${image[$i]} -gt $dead_end ]]; then
            images_right=$((images_right + 1))
        fi
    done
    echo dead_images=$dead_images images_on_left=$images_left images_on_right=$images_right
    if [ $dead_images -eq 0 ]; then
        return
    fi

    echo "livezones: left: $min_frame:$((dead_start - 1)) right: $((dead_end + 1)):$max_frame"
    spaces_left=$((dead_start - min_frame))
    spaces_right=$((max_frame - dead_end))
    best_diff=999999
    best_move_left=0
    local move_left=0
    local move_right=0

    if [ $spaces_left -gt 0 ] && [ $spaces_right -gt 0 ]; then
        for move_left in $(seq 0 $dead_images); do
            move_right=$((dead_images - move_left))
            left_density=$(echo "scale=6; ($images_left + $move_left) / $spaces_left" | bc)
            #echo "left_density = $left_density = ($images_left + $move_left) / $spaces_left"
            right_density=$(echo "scale=6; ($images_right + $move_right) / $spaces_right" | bc)
            #echo "right_density = $right_density = ($images_right + $move_right) / $spaces_right"
            diff=$(echo "scale=10; ($left_density - $right_density)^2" | bc)
            if (( $(echo "$diff < $best_diff" | bc) )); then
                best_diff=$diff
                best_move_left=$move_left
                #echo best_move_left=$move_left best_diff=$diff
            fi
        done
        move_left=$best_move_left
        move_right=$((dead_images - move_left))
    elif [ $spaces_left -gt 0 ]; then
        move_left=$dead_images
    elif [ $spaces_right -gt 0 ]; then
        move_right=$dead_images
    else
        echo No adjacent spaces to move dead images to - need more algorithm!
        exit
    fi
        
    echo dead_images=$dead_images move_left=$move_left move_right=$move_right

    echo Recurse into new livezones
    local erm=0
    if [ $move_left -gt 0 ]; then
        echo Left dist_images $((dead_start - 1)) $min_frame $((left_end_image + move_left)) $min_image
        step=""; dist_images $((dead_start - 1)) $min_frame $((left_end_image + move_left)) $min_image $net_zone_id
        if [ "$step" != "" ]; then
            erm=$(echo "($dead_start - 1 + $step + 0.5)/1" | bc)
            echo After Left dist_images step=$step erm=$erm
        else
            echo step was blank so erm stays zero
        fi
    else
        echo No left side to process
    fi
    if [ $images_right -gt 0 ]; then
        echo Processing right side
        if [ $erm -lt $((dead_end + 1)) ]; then
            if [ $erm -ne 0 ]; then
                echo "After left dist_images (frames $min_frame to $((dead_start - 1))) out of $min_frame to $max_frame. step=$step"
            fi
            erm=$((dead_end + 1))
        fi
        echo "Right dist_images: frames: $erm to $max_frame images: $right_start_image-$move_right to $max_image (within $min_frame to $max_frame run)"
        dist_images $erm $max_frame $((right_start_image - move_right)) $max_image
        if [ $move_left -eq 0 ] && [ $images_left -gt 0 ]; then
            echo "After right dist_images (frames $erm to $max_frame) out of $min_frame to $max_frame. step=$step"
            erm=$(echo "($dead_end + 1 - $step + 0.5)/1" | bc)
            if [ $erm -gt $((dead_start - 1)) ]; then
                erm=$((dead_start - 1))
            fi
            echo Left dist_images min_frame=$min_frame erm=$erm min_image=$min_image left_end_image=$left_end_image move_left=$move_left
            dist_images $erm $min_frame $((left_end_image + move_left)) $min_image
        fi
    else
        echo Apparently no need to call right dist_images. erm=$erm dead_end=$dead_end images_right=$images_right
    fi
    echo "For range final: $min_frame to $max_frame"
    echo "Selected frames: ${image[*]}"

    # TODO - create livezone objects for each livezone and then summarise the density of each one at the end
    # and test whether densities can be better equalised by moving images between zones
}

generate_montage() {
    output_file=$1
    start_frame=${2:-0}
    end_frame=${3:-$((TOTAL_FRAMES - 1))}
    range=$((end_frame - start_frame))
    inputs=()
    what="video"
    [ -n "$2" ] && what="selected range"
    [ -n "$RESIZE" ] && resizing=" and resizing"
    for i in "${!image[@]}"; do
        FRAME_NUM=${image[$i]}
        OUT_FRAME="$TEMP/frame_$i.png"
        PERCENT=$(echo "scale=2; ($FRAME_NUM - $start_frame) * 100 / $range" | bc)
        echo "Extracting frame $i ($PERCENT% of $what)$resizing"
        local filter="select=eq(n\,${FRAME_NUM})$RESIZE"
        if [ "$SHOW_NUMBERS" = true ] || [ "$SHOW_ZONES" = true ]; then
            local text=""
            [ "$SHOW_NUMBERS" = true ] && text="${FRAME_NUM}"
            [ "$SHOW_ZONES" = true ] && text="${text:+$text }Zone ${livezones[$i]:-Unknown}"
            filter+=",drawtext=fontfile=/path/to/font.ttf:fontsize=24:fontcolor=white:box=1:boxcolor=black@0.5:boxborderw=5:x=10:y=10:text='$text'"
        fi
        ffmpeg -loglevel error -y -i "$(convert_path "$VID")" -vf "$filter" -vsync vfr "$(convert_path "$OUT_FRAME")" >> "$LOG" 2>&1
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
dist_images
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
               image=()
               dist_images ;;
            2) read -p "Enter start and end frames: " start end
               dist_images -1
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
