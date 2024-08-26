#!/bin/bash

# Ensure that the script takes exactly 3 arguments
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <before_image.png> <after_image.png> <video.mp4>"
    exit 1
fi

# Assign command line arguments to variables
START_IMAGE="$1"
END_IMAGE="$2"
VIDEO_FILE="$3"
CYG_TEMP_DIR="/tmp/temp_frames_$$"  # Cygwin version of TEMP_DIR
LOG_FILE="/tmp/ffmpeg_log_$$.log"
NUM_FRAMES=8

# Check ffmpeg version to determine if it's a Windows-native version
FFMPEG_VERSION=$(ffmpeg -version | grep -i "built with gcc")
if [[ "$FFMPEG_VERSION" == *"MSYS2"* ]]; then
    # Convert Cygwin paths to Windows paths if it's the Windows-native version
    echo "Detected Windows-native ffmpeg."
    START_IMAGE=$(cygpath -w "$START_IMAGE")
    END_IMAGE=$(cygpath -w "$END_IMAGE")
    VIDEO_FILE=$(cygpath -w "$VIDEO_FILE")
    WIN_TEMP_DIR=$(cygpath -w "$CYG_TEMP_DIR")  # Windows version of TEMP_DIR
    OUTPUT_IMAGE=$(cygpath -w "${VIDEO_FILE%.*}_montage.png")
else
    WIN_TEMP_DIR="$CYG_TEMP_DIR"
    OUTPUT_IMAGE="${VIDEO_FILE%.*}_montage.png"
fi

# Create a unique temporary directory for the frames
mkdir -p "$CYG_TEMP_DIR"
echo "Temporary directory created: $CYG_TEMP_DIR"

# Get the width and height of the START_IMAGE before proceeding using ffprobe
echo "Getting dimensions of the START_IMAGE..."
ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$START_IMAGE" >> "$LOG_FILE" 2>&1
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

# Get the total number of frames in the video
echo "Running ffmpeg to get total number of frames..."
echo "Video file being used: $VIDEO_FILE" >> "$LOG_FILE"
ffmpeg -i "$VIDEO_FILE" -vf "showinfo" -f null - 2>> "$LOG_FILE" >> "$LOG_FILE"

# Now parse the log file to find the last "frame=" line
TOTAL_FRAMES=$(grep -oP 'frame=\s*\K\d+' "$LOG_FILE" | tail -1)

# Show frame information to the user
if [ -z "$TOTAL_FRAMES" ]; then
    echo "Error: Could not determine total number of frames in the video."
    echo "See the log file for more details: $LOG_FILE"
    exit 1
fi
echo "Total frames determined: $TOTAL_FRAMES"

# Calculate frame interval to get 8 evenly spaced frames, ignoring first and last frame
INTERVAL=$((TOTAL_FRAMES / (NUM_FRAMES + 1)))
echo "Frame interval calculated: $INTERVAL"

echo "Extracting frames..."
# Extract 8 evenly spaced frames, skipping the first and last frames
for i in $(seq 1 $NUM_FRAMES); do
    FRAME_NUM=$((i * INTERVAL))
    OUTPUT_FRAME="$CYG_TEMP_DIR/frame_$i.png"
    TEMP_FRAME="$CYG_TEMP_DIR/frame_${i}_resized.png"
    if [[ "$FFMPEG_VERSION" == *"MSYS2"* ]]; then
        OUTPUT_FRAME=$(cygpath -w "$OUTPUT_FRAME")
        TEMP_FRAME=$(cygpath -w "$TEMP_FRAME")
    fi
    ffmpeg -loglevel error -y -i "$VIDEO_FILE" -vf "select=eq(n\,$FRAME_NUM)" -vsync vfr "$OUTPUT_FRAME" >> "$LOG_FILE" 2>&1
    if [ ! -f "$OUTPUT_FRAME" ]; then
        echo "Error: Failed to extract frame $i. See the log file for details: $LOG_FILE"
        exit 1
    fi
    echo "Extracted frame $i."

    echo "Resizing frame $i..."
    ffmpeg -loglevel error -y -i "$OUTPUT_FRAME" -vf "scale=$START_IMAGE_WIDTH:$START_IMAGE_HEIGHT" "$TEMP_FRAME" >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        echo "Error: Failed to resize frame $i. See the log file for details: $LOG_FILE"
        exit 1
    fi
    mv "$TEMP_FRAME" "$OUTPUT_FRAME"  # Replace the original frame with the resized one
    echo "Resized frame $i."
done

# Check if all frames exist before creating the montage
for i in $(seq 1 $NUM_FRAMES); do
    OUTPUT_FRAME="$CYG_TEMP_DIR/frame_$i.png"
    if [[ ! -f "$OUTPUT_FRAME" ]]; then
        echo "Error: Frame $i does not exist. Montage creation aborted."
        exit 1
    fi
done

echo "Creating montage..."
# Create a montage using ffmpeg (alternative to ImageMagick)
ffmpeg -loglevel error -y \
  -i "$START_IMAGE" -i "$WIN_TEMP_DIR/frame_1.png" -i "$WIN_TEMP_DIR/frame_2.png" \
  -i "$WIN_TEMP_DIR/frame_3.png" -i "$WIN_TEMP_DIR/frame_4.png" -i "$WIN_TEMP_DIR/frame_5.png" \
  -i "$WIN_TEMP_DIR/frame_6.png" -i "$WIN_TEMP_DIR/frame_7.png" -i "$WIN_TEMP_DIR/frame_8.png" \
  -i "$END_IMAGE" -filter_complex \
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
rm -r "$CYG_TEMP_DIR"
echo "Temporary files deleted."

# Indicate where to find the log file
echo "Log file saved as: $LOG_FILE"

