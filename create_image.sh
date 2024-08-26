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

# Check if ImageMagick is installed
if ! command -v convert &> /dev/null || ! command -v montage &> /dev/null; then
    echo "ImageMagick is not installed. Please install it using: apt-cyg install ImageMagick"
    exit 1
fi

# Create a temporary directory for the frames
mkdir -p $TEMP_DIR

# Get the total number of frames in the video
TOTAL_FRAMES=$(ffmpeg -i "$VIDEO_FILE" -vf "showinfo" -f null - 2>&1 | grep "frame=" | tail -1 | sed 's/.*frame=\([0-9]*\).*/\1/')

# Calculate frame interval to get 8 evenly spaced frames, ignoring first and last frame
INTERVAL=$((TOTAL_FRAMES / (NUM_FRAMES + 1)))

# Extract 8 evenly spaced frames, skipping the first and last frames
for i in $(seq 1 $NUM_FRAMES); do
    FRAME_NUM=$((i * INTERVAL))
    OUTPUT_FRAME="$TEMP_DIR/frame_$i.png"
    ffmpeg -i "$VIDEO_FILE" -vf "select=eq(n\,$FRAME_NUM)" -vsync vfr $OUTPUT_FRAME -hide_banner -loglevel error
done

# Resize the extracted frames to match the size of the START_IMAGE
for i in $(seq 1 $NUM_FRAMES); do
    OUTPUT_FRAME="$TEMP_DIR/frame_$i.png"
    convert $OUTPUT_FRAME -resize $(identify -format "%wx%h" "$START_IMAGE") $OUTPUT_FRAME
done

# Arrange the images into a 5x2 grid (START_IMAGE, 8 frames, END_IMAGE)
montage "$START_IMAGE" $(ls $TEMP_DIR/frame_*.png | sort -V) "$END_IMAGE" -tile 5x2 -geometry +0+0 "$OUTPUT_IMAGE"

# Clean up temporary files
rm -r $TEMP_DIR

echo "Final image saved as $OUTPUT_IMAGE"

