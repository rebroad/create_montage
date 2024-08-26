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
echo "Temporary directory created: $TEMP_DIR"

# Get the total number of frames in the video
echo "Running ffprobe to get total number of frames..."
TOTAL_FRAMES=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 $(convert_path "$VIDEO_FILE"))

# Show frame information to the user
if [ -z "$TOTAL_FRAMES" ]; then
    echo "Error: Could not determine total number of frames in the video."
    echo "See the log file for more details: $LOG_FILE"
    exit 1
fi
echo "Total frames determined: $TOTAL_FRAMES"

# Extract the first and last frames from the video if needed
if [ -z "$START_IMAGE" ]; then
    START_IMAGE="$TEMP_DIR/first_frame.png"
    ffmpeg -loglevel error -y -i $(convert_path "$VIDEO_FILE") -vf "select=eq(n\,0)" -vsync vfr $(convert_path "$START_IMAGE") >> "$LOG_FILE" 2>&1
    if [ ! -f "$START_IMAGE" ]; then
        echo "Error: Failed to extract the first frame. See the log file for details: $LOG_FILE"
        exit 1
    fi
    echo "Extracted first frame as START_IMAGE."
fi

if [ -z "$END_IMAGE" ]; then
    END_IMAGE="$TEMP_DIR/last_frame.png"
    LAST_FRAME_NUM=$((TOTAL_FRAMES - 1))
    ffmpeg -loglevel error -y -i $(convert_path "$VIDEO_FILE") -vf "select=eq(n\,$LAST_FRAME_NUM)" -vsync vfr $(convert_path "$END_IMAGE") >> "$LOG_FILE" 2>&1
    if [ ! -f "$END_IMAGE" ]; then
        echo "Error: Failed to extract the last frame. See the log file for details: $LOG_FILE"
        exit 1
    fi
    echo "Extracted last frame as END_IMAGE."
fi

# Get the width and height of the START_IMAGE before proceeding using ffprobe
echo "Getting dimensions of the START_IMAGE..."
ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 $(convert_path "$START_IMAGE") >> "$LOG_FILE" 2>&1
START_IMAGE_DIMENSIONS=$(grep -oP '^\d+x\d+' "$LOG_FILE" | head -n 1)
START_IMAGE_WIDTH=$(echo "$START_IMAGE_DIMENSIONS" | cut -d'x' -f1)
START_IMAGE_HEIGHT=$(echo "$START_IMAGE_DIMENSIONS" | cut -d'x' -f2)

# Show dimensions to the user for verification
echo "START_IMAGE_WIDTH: $START_IMAGE_WIDTH"
echo "START_IMAGE_HEIGHT: $START_IMAGE_HEIGHT"

if [ -z "$START_IMAGE_WIDTH" ] || [ -z "$START_IMAGE_HEIGHT" ]; then
    echo "Error: Could not determine the dimensions of the START_IMAGE."
    echo "See the log file for more details: $LOG_FILE"
    exit 1
fi

# Calculate frame interval to get 8 evenly spaced frames, ignoring first and last frame
INTERVAL=$((TOTAL_FRAMES / 9)) # correct?
echo "Frame interval calculated: $INTERVAL"

START_LOOP=1
END_LOOP=8
[ -z "$START_IMAGE" ] && START_LOOP=0 && START_IMAGE="$TEMP_DIR/frame_0.png"
[ -z "$END_IMAGE" ] && END_LOOP=9 && END_IMAGE="$TEMP_DIR/frame_9.png"

echo "Extracting frames..."
[ $START_LOOP -eq 1 ] && inputs="-i \"$(convert_path "$START_IMAGE")\" "
for i in $(seq $START_LOOP $END_LOOP); do
    FRAME_NUM=$((i * INTERVAL))
    OUTPUT_FRAME="$TEMP_DIR/frame_$i.png"
    ffmpeg -loglevel error -y -i $(convert_path "$VIDEO_FILE") -vf "select=eq(n\,$FRAME_NUM),scale=$START_IMAGE_WIDTH:$START_IMAGE_HEIGHT" -vsync vfr $(convert_path "$OUTPUT_FRAME") >> "$LOG_FILE" 2>&1
    if [ ! -f "$OUTPUT_FRAME" ]; then
        echo "Error: Failed to extract frame $i. See the log file for details: $LOG_FILE"
        exit 1
    fi
    echo "Extracted and resized frame $i."
    inputs+="-i \"$(convert_path "$OUTPUT_FRAME")\" "
done

# Check if all frames exist before creating the montage
if ! ls "$TEMP_DIR"/frame_*.png &>/dev/null; then
    echo "Error: One or more frames are missing. Montage creation aborted."
    exit 1
fi

[ $END_LOOP -eq 8 ] && inputs+="-i \"$(convert_path "$END_IMAGE")\""

echo "Creating montage..."
# Create a montage using ffmpeg (alternative to ImageMagick)
ffmpeg -loglevel error -y $inputs -filter_complex \
  "[0:v][1:v][2:v][3:v][4:v]hstack=inputs=5[top]; \
   [5:v][6:v][7:v][8:v][9:v]hstack=inputs=5[bottom]; \
   [top][bottom]vstack=inputs=2[v]" \
  -map "[v]" "$OUTPUT_IMAGE" >> "$LOG_FILE" 2>&1

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

