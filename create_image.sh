#!/bin/bash

# Ensure that the script takes exactly 1 to 3 arguments
if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
    echo "Usage: $0 <video.mp4> [before_image.png] [after_image.png]"
    exit 1
fi

# Assign command line arguments to variables
VIDEO_FILE="$1"
START_IMAGE="$2"
END_IMAGE="$3"
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

# Create a unique temporary directory for the frames
mkdir -p "$TEMP_DIR"
touch "$LOG_FILE" # Create the log file explicitly
echo "Temporary directory created: $TEMP_DIR"

# Get the total number of frames in the video
echo "Running ffprobe to get total number of frames..."
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

# Calculate frame interval
echo "Debug: Arithmetic expression: $((TOTAL_FRAMES / 9))"
INTERVAL=$((TOTAL_FRAMES / 9))
echo "Frame interval calculated: $INTERVAL"

START_LOOP=1
END_LOOP=8
[ -z "$START_IMAGE" ] && START_LOOP=0 && START_IMAGE="$TEMP_DIR/frame_0.png"
[ -z "$END_IMAGE" ] && END_LOOP=9 && END_IMAGE="$TEMP_DIR/frame_9.png"

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

echo "Extracting frames..."
inputs=""
[ $START_LOOP -eq 1 ] && inputs="-i \"$(convert_path "$START_IMAGE")\" "

for i in $(seq $START_LOOP $END_LOOP); do
    FRAME_NUM=$((i * INTERVAL))
    [ $i -eq 9 ] && FRAME_NUM=$((TOTAL_FRAMES - 1))  # Ensure we get the last frame
    OUTPUT_FRAME="$TEMP_DIR/frame_$i.png"
    ffmpeg -loglevel error -y -i "$(convert_path "$VIDEO_FILE")" -vf "select=eq(n\,$FRAME_NUM)${RESIZE_FILTER}" -vsync vfr "$(convert_path "$OUTPUT_FRAME")" >> "$LOG_FILE" 2>&1
    if [ ! -f "$OUTPUT_FRAME" ]; then
        echo "Error: Failed to extract and resize frame $i. See the log file for details: $LOG_FILE"
        exit 1
    fi
    echo "Extracted and resized frame $i."
    inputs+="-i \"$(convert_path "$OUTPUT_FRAME")\" "
done

# Add END_IMAGE to inputs only if it wasn't processed in the loop
[ $END_LOOP -eq 8 ] && inputs="$inputs -i \"$(convert_path "$END_IMAGE")\""

# Check if all frames exist before creating the montage
if ! ls "$TEMP_DIR"/frame_*.png &>/dev/null; then
    echo "Error: One or more frames are missing. Montage creation aborted."
    exit 1
fi

echo "Creating montage..."
# Create a montage using ffmpeg (alternative to ImageMagick)
eval ffmpeg -loglevel error -y $inputs -filter_complex \
  "[0:v][1:v][2:v][3:v][4:v]hstack=inputs=5[top]; \
   [5:v][6:v][7:v][8:v][9:v]hstack=inputs=5[bottom]; \
   [top][bottom]vstack=inputs=2[v]" \
  -map "[v]" "$(convert_path "$OUTPUT_IMAGE")" >> "$LOG_FILE" 2>&1

if [ $? -eq 0 ]; then
    echo "Final image saved as $OUTPUT_IMAGE"
else
    echo "Error: Failed to create montage. See the log file for details: $LOG_FILE"
fi

# Clean up temporary files
echo "Cleaning up temporary files..."
rm -r "$TEMP_DIR"
echo "Temporary files deleted."

# Indicate where to find the log file
echo "Log file saved as: $LOG_FILE"

