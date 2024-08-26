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
TEMP_DIR="temp_frames"
NUM_FRAMES=8

# Generate output filename based on video filename
BASENAME=$(basename "$VIDEO_FILE" .mp4)
OUTPUT_IMAGE="${BASENAME}_montage.png"

# Create a temporary directory for the frames
mkdir -p "$TEMP_DIR"

# Get the total number of frames in the video
TOTAL_FRAMES=$(ffmpeg -i "$VIDEO_FILE" -vf "showinfo" -f null - 2>&1 | grep "frame=" | tail -1 | sed 's/.*frame=\([0-9]*\).*/\1/')
if [ -z "$TOTAL_FRAMES" ]; then
    echo "Error: Could not determine total number of frames in the video."
    exit 1
fi

# Calculate frame interval to get 8 evenly spaced frames, ignoring first and last frame
INTERVAL=$((TOTAL_FRAMES / (NUM_FRAMES + 1)))

echo "Extracting frames..."
# Extract 8 evenly spaced frames, skipping the first and last frames
for i in $(seq 1 $NUM_FRAMES); do
    FRAME_NUM=$((i * INTERVAL))
    OUTPUT_FRAME="$TEMP_DIR/frame_$i.png"
    ffmpeg -loglevel error -y -i "$VIDEO_FILE" -vf "select=eq(n\,$FRAME_NUM)" -vsync vfr "$OUTPUT_FRAME"
    if [ ! -f "$OUTPUT_FRAME" ]; then
        echo "Error: Failed to extract frame $i."
        exit 1
    fi
    echo "Extracted frame $i."
done

# Resize the extracted frames to match the size of the START_IMAGE
START_IMAGE_WIDTH=$(ffmpeg -v error -i "$START_IMAGE" -vf "showinfo" -f null - 2>&1 | grep "Stream #0:0" | grep -oP '\d{3,4}x\d{3,4}' | head -n 1 | cut -d'x' -f1)
START_IMAGE_HEIGHT=$(ffmpeg -v error -i "$START_IMAGE" -vf "showinfo" -f null - 2>&1 | grep "Stream #0:0" | grep -oP '\d{3,4}x\d{3,4}' | head -n 1 | cut -d'x' -f2)

echo "Resizing frames..."
for i in $(seq 1 $NUM_FRAMES); do
    OUTPUT_FRAME="$TEMP_DIR/frame_$i.png"
    ffmpeg -loglevel error -y -i "$OUTPUT_FRAME" -vf "scale=$START_IMAGE_WIDTH:$START_IMAGE_HEIGHT" "$OUTPUT_FRAME"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to resize frame $i."
        exit 1
    fi
    echo "Resized frame $i."
done

echo "Creating montage..."
# Create a montage using ffmpeg (alternative to ImageMagick)
ffmpeg -loglevel error -y \
  -i "$START_IMAGE" -i "$TEMP_DIR/frame_1.png" -i "$TEMP_DIR/frame_2.png" \
  -i "$TEMP_DIR/frame_3.png" -i "$TEMP_DIR/frame_4.png" -i "$TEMP_DIR/frame_5.png" \
  -i "$TEMP_DIR/frame_6.png" -i "$TEMP_DIR/frame_7.png" -i "$TEMP_DIR/frame_8.png" \
  -i "$END_IMAGE" -filter_complex \
  "[0:v][1:v][2:v][3:v][4:v]hstack=inputs=5[top]; \
   [5:v][6:v][7:v][8:v][9:v]hstack=inputs=5[bottom]; \
   [top][bottom]vstack=inputs=2[v]" \
  -map "[v]" "$OUTPUT_IMAGE"

if [ $? -eq 0 ]; then
    echo "Final image saved as $OUTPUT_IMAGE"
else
    echo "Error: Failed to create montage."
fi

# Clean up temporary files
rm -r "$TEMP_DIR"


