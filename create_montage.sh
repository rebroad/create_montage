#!/bin/bash

# Ensure the script takes 1 to 4 arguments
if [ "$#" -lt 1 ] || [ "$#" -gt 4 ]; then
    echo "Usage: $0 <video.mp4> [NxN] [before_image.png] [after_image.png]"
    exit 1
fi

# Default grid dimension
GRID_DIMENSION="5x2"

# Parse arguments for grid dimension and file names
for arg in "$@"; do
    if [[ "$arg" =~ ^[0-9]+x[0-9]+$ ]]; then
        GRID_DIMENSION="$arg"
    elif [[ -z "$VIDEO_FILE" ]]; then
        VIDEO_FILE="$arg"
    elif [[ -z "$START_IMAGE" ]]; then
        START_IMAGE="$arg"
    elif [[ -z "$END_IMAGE" ]]; then
        END_IMAGE="$arg"
    fi
done

if [ -z "$VIDEO_FILE" ]; then
    echo "Error: Video file not specified."
    exit 1
fi

# Extract columns and rows from GRID_DIMENSION
COLS=$(echo "$GRID_DIMENSION" | cut -d'x' -f1)
ROWS=$(echo "$GRID_DIMENSION" | cut -d'x' -f2)
TOTAL_IMAGES=$((COLS * ROWS))

# Ensure that the total number of images is at least 2
if [ "$TOTAL_IMAGES" -lt 2 ]; then
    echo "Error: The grid must allow for at least 2 images."
    exit 1
fi

TEMP_DIR="/tmp/temp_frames_$$"
LOG_FILE="/tmp/ffmpeg_log_$$.log"
OUTPUT_IMAGE="${VIDEO_FILE%.*}_montage.png"

# Check ffmpeg version to determine if it's a Windows-native version
FFMPEG_VERSION=$(ffmpeg -version | grep -i "built with gcc")
if [[ "$FFMPEG_VERSION" == *"MSYS2"* ]]; then
    echo "Detected Windows-native ffmpeg."
fi

convert_path() {
    if [[ "$FFMPEG_VERSION" == *"MSYS2"* ]]; then
        cygpath -w "$1"
    else
        echo "$1"
    fi
}

# Create temporary directory for frame extraction
mkdir -p "$TEMP_DIR"
touch "$LOG_FILE" # Create the log file explicitly
echo "Temporary directory created: $TEMP_DIR"

# Get the total number of frames in the video
TOTAL_FRAMES=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$(convert_path "$VIDEO_FILE")")

# Show frame information to the user
if [ -z "$TOTAL_FRAMES" ]; then
    echo "Error: Could not determine total number of frames in the video."
    echo "See the log file for more details: $LOG_FILE"
    exit 1
fi
echo "Total frames determined: $TOTAL_FRAMES"

# Trim any whitespace or special characters from TOTAL_FRAMES
TOTAL_FRAMES=$(echo "$TOTAL_FRAMES" | tr -d '[:space:]')

# Ensure TOTAL_FRAMES is a valid number
if ! [[ "$TOTAL_FRAMES" =~ ^[0-9]+$ ]]; then
    echo "Error: TOTAL_FRAMES is not a valid number."
    echo "TOTAL_FRAMES: $TOTAL_FRAMES"
    exit 1
fi

# Check if the requested number of images exceeds the total frames in the video
if [ "$TOTAL_IMAGES" -gt "$TOTAL_FRAMES" ]; then
    echo "Error: The requested grid ($GRID_DIMENSION) requires more images ($TOTAL_IMAGES) than there are frames in the video ($TOTAL_FRAMES)."
    exit 1
fi

# Calculate the frame numbers using integer arithmetic
FRAME_NUMS=()
for i in $(seq 0 $((TOTAL_IMAGES - 1))); do
    FRAME_NUM=$(( i * (TOTAL_FRAMES - 1) / (TOTAL_IMAGES - 1) ))
    FRAME_NUMS+=($FRAME_NUM)
done

# Output calculated frames
echo "Calculated frame numbers: ${FRAME_NUMS[*]}"

# Initialize the resize variable
RESIZE_FILTER=""

# Get the width and height of the START_IMAGE if it was provided
if [ ! -z "$START_IMAGE" ]; then
    echo "Getting dimensions of the START_IMAGE..."
    START_IMAGE_DIMENSIONS=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$(convert_path "$START_IMAGE")")
    START_IMAGE_WIDTH=$(echo "$START_IMAGE_DIMENSIONS" | cut -d'x' -f1)
    START_IMAGE_HEIGHT=$(echo "$START_IMAGE_DIMENSIONS" | cut -d'x' -f2)

    # Show dimensions to the user for verification
    echo "START_IMAGE_WIDTH: $START_IMAGE_WIDTH"
    echo "START_IMAGE_HEIGHT: $START_IMAGE_HEIGHT"

    if [ -z "$START_IMAGE_WIDTH" ] || [ -z "$START_IMAGE_HEIGHT" ]; then
        echo "Error: Could not determine the dimensions of the START_IMAGE."
        echo "See the log file for more details: $LOG_FILE"
        exit 1
    else
        # Define the resize filter if dimensions are available
        RESIZE_FILTER=",scale=${START_IMAGE_WIDTH}:${START_IMAGE_HEIGHT}"
    fi
fi

# Extract and resize frames using ffmpeg, logging any errors
echo "Extracting frames..."
inputs=""
for i in "${!FRAME_NUMS[@]}"; do
    if [ "$i" -eq 0 ] && [ -n "$START_IMAGE" ]; then
        inputs+="-i $(convert_path "$START_IMAGE") "
        echo "Using START_IMAGE as frame 0."
    elif [ "$i" -eq $((TOTAL_IMAGES - 1)) ] && [ -n "$END_IMAGE" ]; then
        inputs+="-i $(convert_path "$END_IMAGE") "
        echo "Using END_IMAGE as the last frame."
    else
        FRAME_NUM=${FRAME_NUMS[$i]}
        OUTPUT_FRAME="$TEMP_DIR/frame_$i.png"
        echo "Extracting frame $i (frame number $FRAME_NUM) and resizing."
        ffmpeg -loglevel error -y -i "$(convert_path "$VIDEO_FILE")" -vf "select=eq(n\,${FRAME_NUM})${RESIZE_FILTER}" -vsync vfr "$(convert_path "$OUTPUT_FRAME")" >> "$LOG_FILE" 2>&1
        if [ ! -f "$OUTPUT_FRAME" ]; then
            echo "Error: Failed to extract and resize frame $i. See the log file for details: $LOG_FILE"
            exit 1
        fi
        inputs+="-i $(convert_path "$OUTPUT_FRAME") "
    fi
done

# Check if all frames exist before creating the montage
if ! ls "$TEMP_DIR"/frame_*.png &>/dev/null; then
    echo "Error: One or more frames are missing. Montage creation aborted."
    exit 1
fi

# Build filter_complex string for creating montage
FILTER_COMPLEX=""
if [ "$ROWS" -eq 1 ]; then
    # If there's only one row, stack images horizontally
    for (( col=0; col<COLS; col++ )); do
        FILTER_COMPLEX+="[$col:v]"
    done
    FILTER_COMPLEX+="hstack=inputs=$COLS[v]"
elif [ "$COLS" -eq 1 ]; then
    # If there's only one column, stack images vertically
    for (( row=0; row<ROWS; row++ )); do
        FILTER_COMPLEX+="[$row:v]"
    done
    FILTER_COMPLEX+="vstack=inputs=$ROWS[v]"
else
    # General case for grids with multiple rows and columns
    for (( row=0; row<ROWS; row++ )); do
        for (( col=0; col<COLS; col++ )); do
            FILTER_COMPLEX+="[$((row * COLS + col)):v]"
        done
        FILTER_COMPLEX+="hstack=inputs=$COLS[row$row]; "
    done

    # Stack all rows vertically to create the final montage
    for (( row=0; row<ROWS; row++ )); do
        FILTER_COMPLEX+="[row$row]"
    done
    FILTER_COMPLEX+="vstack=inputs=$ROWS[v]"
fi

echo "Creating montage..." | tee -a "$LOG_FILE"
# Create the montage with ffmpeg
ffmpeg -loglevel error -y $inputs -filter_complex "$FILTER_COMPLEX" -map "[v]" "$(convert_path "$OUTPUT_IMAGE")" >> "$LOG_FILE" 2>&1

# Verify if the output image is created successfully and log the result
if [ $? -eq 0 ] && [ -f "$OUTPUT_IMAGE" ]; then
    echo "Final image saved as $OUTPUT_IMAGE" | tee -a "$LOG_FILE"
else
    echo "Error: Failed to create montage." | tee -a "$LOG_FILE"
    exit 1
fi

# Clean up temporary files
echo "Cleaning up temporary files..."
rm -r "$TEMP_DIR"
echo "Temporary files deleted."

# Indicate where to find the log file
echo "Log file saved as: $LOG_FILE"

