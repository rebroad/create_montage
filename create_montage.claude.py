#!/bin/python

import os
import sys
import subprocess
import tempfile
import shutil
import math

def convert_path(path):
    if sys.platform == 'win32' or 'cygwin' in sys.platform:
        try:
            return subprocess.check_output(['cygpath', '-w', path]).strip().decode('utf-8')
        except subprocess.CalledProcessError:
            return path
    return path

def get_dimensions(file_path):
    cmd = [
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height", "-of", "csv=s=x:p=0", convert_path(file_path)
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    dimensions = result.stdout.strip()
    if not dimensions:
        print(f"Error: Unable to get dimensions for {file_path}")
        print(f"ffprobe output: {result.stderr}")
        sys.exit(1)
    return dimensions

def load_deadzones():
    global AVAILABLE_FRAMES, deadzones
    AVAILABLE_FRAMES = TOTAL_FRAMES
    deadzones = []
    if os.path.exists(DEADZONE_FILE):
        with open(DEADZONE_FILE, 'r') as f:
            for line in f:
                start, end = map(int, line.strip().split(':'))
                AVAILABLE_FRAMES -= (end - start + 1)
                deadzones.append((start, end))
    print(f"Total available frames (excluding deadzones): {AVAILABLE_FRAMES}")

def find_optimal_grid(target_rows=None, target_cols=None):
    global COLS, ROWS
    print(f"Searching for optimal grid for {WIDTH}:{HEIGHT} aspect ratio")
    MIN_RATIO_DIFF = float('inf')
    TARGET_RATIO = WIDTH / HEIGHT
    start_y, end_y = (target_rows, target_rows) if target_rows else (1, AVAILABLE_FRAMES)
    for y in range(start_y, end_y + 1):
        LAST_X_DIFF = float('inf')
        start_x = int((y * TARGET_RATIO * FRAME_HEIGHT) / FRAME_WIDTH)
        if start_x * y > AVAILABLE_FRAMES:
            break
        end_x = target_cols if target_cols else AVAILABLE_FRAMES // y
        for x in range(start_x, end_x + 1):
            GRID_RATIO = (x * FRAME_WIDTH) / (y * FRAME_HEIGHT)
            RATIO_DIFF = (GRID_RATIO - TARGET_RATIO) ** 2
            if RATIO_DIFF < MIN_RATIO_DIFF:
                MIN_RATIO_DIFF = RATIO_DIFF
                COLS, ROWS = x, y
                print("BEST! ", end="")
            elif LAST_X_DIFF < RATIO_DIFF:
                print(f"x={x} y={y} RATIO_DIFF={RATIO_DIFF:.10f} - XBreak")
                break
            print(f"x={x} y={y} RATIO_DIFF={RATIO_DIFF:.10f}")
            LAST_X_DIFF = RATIO_DIFF
    print(f"Optimal grid: {COLS}x{ROWS}")

def add_deadzone(start, end=None):
    global deadzones
    end = end or start
    deadzones.append((start, end))
    deadzones.sort()
    merged = []
    for start, end in deadzones:
        if not merged or start > merged[-1][1] + 1:
            merged.append([start, end])
        else:
            merged[-1][1] = max(merged[-1][1], end)
    with open(DEADZONE_FILE, 'w') as f:
        for start, end in merged:
            f.write(f"{start}:{end}\n")
    print("Added and merged deadzones. Current deadzones:")
    with open(DEADZONE_FILE, 'r') as f:
        print(f.read())
    load_deadzones()

def dist_images(start_frame=0, end_frame=None, start_image=0, end_image=None):
    global image, livezones, zone_id
    ignore_deadzones = start_frame == -1
    start_frame = max(0, start_frame)
    end_frame = end_frame or TOTAL_FRAMES - 1
    end_image = end_image or TOTAL_IMAGES - 1
    zone_id = 1 if start_frame == 0 and end_frame == TOTAL_FRAMES - 1 else zone_id + 1
    print(f"Entering dist_images: frames={start_frame}-{end_frame} images={start_image}-{end_image} zone={zone_id}")

    if start_image == end_image:
        frame = image[start_image]
        if 0 < frame < TOTAL_FRAMES - 1:
            image[start_image] = (start_frame + end_frame) // 2
            print(f"Placing image {start_frame} in center of {start_frame}:{end_frame} at frame={image[start_image]}")
        else:
            print(f"Keep image {start_image} at its current position ({image[start_image]}) as it's special.")
        direction = 0
    else:
        direction = 1 if end_image > start_image else -1
        step = (end_frame - start_frame) / (end_image - start_image)
        print(f"Distribute images {start_image}-{end_image} between frames {start_frame}-{end_frame} step={step:.6f}")

    for i in range(start_image, end_image + direction, direction):
        frame = int(start_frame + ((i - start_image) * step) + 0.5)
        print(f"image={i} frame: {image[i]} -> {frame}")
        if i in image and frame == image[i]:
            break
        image[i] = frame
        livezones[i] = zone_id
    print(f"After dist frames: {' '.join(map(str, image))}")

    if ignore_deadzones:
        print(f"Ignoring deadzones = {ignore_deadzones}")
        return

    print(f"Finding largest deadzone within frames {start_frame} to {end_frame}")
    min_frame, max_frame = min(start_frame, end_frame), max(start_frame, end_frame)
    center = (start_frame + end_frame) // 2
    best_deadzone = max(
        ((dead_start, dead_end) for dead_start, dead_end in deadzones if min_frame <= dead_end and dead_start <= max_frame),
        key=lambda x: (x[1] - x[0] + 1, -abs((x[0] + x[1]) // 2 - center)),
        default=None
    )

    if not best_deadzone:
        print(f"No deadzones within frames {min_frame} to {max_frame}")
        return

    best_dead_start, best_dead_end = best_deadzone
    print(f"Processing deadzone: {best_dead_start}:{best_dead_end}")

    dead_images = 0
    images_left = 0
    images_right = 0

    min_image = min(start_image, end_image)
    max_image = max(start_image, end_image)
    for i in range(min_image, max_image + 1):
        if image[i] < best_dead_start:
            images_left += 1
            left_end_image = i
        elif best_dead_start <= image[i] <= best_dead_end:
            dead_images += 1
            right_start_image = i + 1
        elif image[i] > best_dead_end:
            images_right += 1
    print(f"dead_images={dead_images} images_on_left={images_left} images_on_right={images_right}")
    if dead_images == 0:
        return

    print(f"livezones: left: {min_frame}:{best_dead_start - 1} right: {best_dead_end + 1}:{max_frame}")
    spaces_left = best_dead_start - min_frame
    spaces_right = max_frame - best_dead_end
    best_diff = float('inf')
    best_move_left = 0

    if spaces_left > 0 and spaces_right > 0:
        for move_left in range(dead_images + 1):
            move_right = dead_images - move_left
            left_density = (images_left + move_left) / spaces_left
            right_density = (images_right + move_right) / spaces_right
            diff = (left_density - right_density) ** 2
            if diff < best_diff:
                best_diff = diff
                best_move_left = move_left
        move_left = best_move_left
        move_right = dead_images - move_left
    elif spaces_left > 0:
        move_left, move_right = dead_images, 0
    elif spaces_right > 0:
        move_left, move_right = 0, dead_images
    else:
        print("No adjacent spaces to move dead images to - need more algorithm!")
        sys.exit(1)
        
    print(f"dead_images={dead_images} move_left={move_left} move_right={move_right}")

    print("Recurse into new livezones")
    erm = 0
    if move_left > 0:
        print(f"Left dist_images {best_dead_start - 1} {min_frame} {left_end_image + move_left} {min_image}")
        dist_images(best_dead_start - 1, min_frame, left_end_image + move_left, min_image)
        erm = best_dead_start - 1
    else:
        print("No left side to process")
    if images_right > 0:
        print("Processing right side")
        if erm < best_dead_end + 1:
            if erm != 0:
                print(f"After left dist_images (frames {min_frame} to {best_dead_start - 1}) out of {min_frame} to {max_frame}.")
            erm = best_dead_end + 1
        print(f"Right dist_images: frames: {erm} to {max_frame} images: {right_start_image - move_right} to {max_image} (within {min_frame} to {max_frame} run)")
        dist_images(erm, max_frame, right_start_image - move_right, max_image)
        if move_left == 0 and images_left > 0:
            print(f"After right dist_images (frames {erm} to {max_frame}) out of {min_frame} to {max_frame}.")
            erm = min(best_dead_start - 1, best_dead_end + 1)
            print(f"Left dist_images min_frame={min_frame} erm={erm} min_image={min_image} left_end_image={left_end_image} move_left={move_left}")
            dist_images(erm, min_frame, left_end_image + move_left, min_image)
    else:
        print(f"Apparently no need to call right dist_images. erm={erm} dead_end={best_dead_end} images_right={images_right}")
    print(f"For range final: {min_frame} to {max_frame}")
    print(f"Selected frames: {image}")

def which(program):
    path = shutil.which(program)
    if path:
        return path
    return None

def generate_montage(output_file, start_frame=0, end_frame=None):
    end_frame = end_frame or TOTAL_FRAMES - 1
    range_frames = end_frame - start_frame
    inputs = []
    what = "selected range" if start_frame != 0 or end_frame != TOTAL_FRAMES - 1 else "video"
    resizing = " and resizing" if RESIZE else ""

    ffmpeg_path = which('ffmpeg')
    if not ffmpeg_path:
        print("Error: ffmpeg not found in PATH. Please install ffmpeg or add it to your PATH.")
        sys.exit(1)

    print(f"Using ffmpeg from: {ffmpeg_path}")

    for row in range(ROWS):
        row_start = row * COLS
        row_end = row_start + COLS
        row_frames = image[row_start:row_end] if row % 2 == 0 else reversed(image[row_start:row_end])

        for i, frame_num in enumerate(row_frames, start=row_start):
            out_frame = os.path.join(TEMP, f"frame_{i}.png")
            percent = (frame_num - start_frame) * 100 / range_frames
            print(f"Extracting frame {i} ({percent:.2f}% of {what}){resizing}")
            filter = f"select=eq(n\\,{frame_num}){RESIZE}"
            if SHOW_NUMBERS or SHOW_ZONES:
                text = []
                if SHOW_NUMBERS:
                    text.append(str(frame_num))
                if SHOW_ZONES:
                    text.append(f"Zone {livezones[i]}")
                filter += f",drawtext=fontfile=/path/to/font.ttf:fontsize=24:fontcolor=white:box=1:boxcolor=black@0.5:boxborderw=5:x=10:y=10:text='{' '.join(text)}'"
            cmd = ["ffmpeg", "-loglevel", "error", "-y", "-i", convert_path(VID), "-vf", filter, "-vsync", "vfr", convert_path(out_frame)]
            subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
            if not os.path.exists(out_frame):
                print(f"Error: Failed to extract frame {i}. See {LOG}")
                sys.exit(1)
            inputs.extend(["-i", convert_path(out_frame)])

    filter = (
        "[" + ":v][".join(map(str, range(TOTAL_IMAGES))) + ":v]" +
        (f"hstack=inputs={TOTAL_IMAGES}" if ROWS == 1 else
         f"vstack=inputs={TOTAL_IMAGES}" if COLS == 1 else
         f"{''.join(f'[{r*COLS}:v]' + '[' + ']:v]['.join(map(str, range(r*COLS+1, (r+1)*COLS))) + f':v]hstack=inputs={COLS}[row{r}];' for r in range(ROWS))}[{''.join(f'row{r}' for r in range(ROWS))}]vstack=inputs={ROWS}")
    ) + "[v]"

    print("Creating montage...")
    print(f"Filter complex: {filter}")

    os.environ['FONTCONFIG_FILE'] = "/dev/null"

    cmd = ["ffmpeg", "-loglevel", "error", "-y"] + inputs + ["-filter_complex", filter, "-map", "[v]", convert_path(output_file)]
    result = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if result.returncode == 0 and os.path.exists(output_file):
        print(f"Montage saved as {output_file}")
    else:
        print(f"Error: Failed to create montage. See {LOG} for details.")
        with open(LOG, 'w') as f:
            f.write(result.stderr)
        print(result.stderr)
        sys.exit(1)

# Main execution
if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <video.mp4> [aspect_ratio] [NxN | Nx | xN] [before_image.png] [after_image.png] [-i] [-n] [-z]")
        sys.exit(1)

    VID = None
    ASPECT_RATIO = None
    GRID = None
    START_IMAGE = None
    END_IMAGE = None
    INTERACTIVE_MODE = False
    SHOW_NUMBERS = False
    SHOW_ZONES = False

    for arg in sys.argv[1:]:
        if arg.endswith('.mp4'):
            VID = arg
        elif ':' in arg:
            ASPECT_RATIO = arg
        elif 'x' in arg:
            GRID = arg
        elif arg == '-i':
            INTERACTIVE_MODE = True
        elif arg == '-n':
            SHOW_NUMBERS = True
        elif arg == '-z':
            SHOW_ZONES = True
        elif START_IMAGE is None:
            START_IMAGE = arg
        else:
            END_IMAGE = arg

    if VID is None:
        print("Error: Video file not specified.")
        sys.exit(1)
    if not os.path.isfile(VID):
        print(f"Error: Video file '{VID}' does not exist.")
        sys.exit(1)

    OUT = f"{os.path.splitext(VID)[0]}_montage.png"
    DEADZONE_FILE = f"{os.path.splitext(VID)[0]}_deadzones.txt"

    TEMP = tempfile.mkdtemp()
    LOG = os.path.join(TEMP, "ffmpeg_log.log")

    print(f"Determining video information for: {VID}")
    cmd = [
        "ffprobe", "-v", "error", "-count_frames", "-select_streams", "v:0",
        "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", convert_path(VID)
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Error running ffprobe. Return code: {result.returncode}")
        print(f"Error output: {result.stderr}")
        sys.exit(1)

    stdout = result.stdout.strip()
    if not stdout:
        print("Error: ffprobe didn't return any output.")
    else:
        try:
            TOTAL_FRAMES = int(stdout)
        except ValueError:
            print(f"Error: Unexpected output from ffprobe: '{stdout}'")
            print("Unable to determine frame count. Please check if the video file is valid.")
            sys.exit(1)

    print(f"Total frames determined: {TOTAL_FRAMES}")

    if START_IMAGE:
        DIM = get_dimensions(START_IMAGE)
        SW, SH = map(int, DIM.split('x'))
        RESIZE = f",scale={SW}:{SH}" if SW and SH else ""
        FRAME_WIDTH, FRAME_HEIGHT = SW, SH
    else:
        DIM, RESIZE = get_dimensions(VID), ""
        FRAME_WIDTH, FRAME_HEIGHT = map(int, DIM.split('x'))
    print(f"Frame dimensions: {FRAME_WIDTH} by {FRAME_HEIGHT}")

    if ASPECT_RATIO:
        WIDTH, HEIGHT = map(int, ASPECT_RATIO.split(':'))
    else:
        WIDTH, HEIGHT = 16, 9
    TARGET_RATIO = WIDTH / HEIGHT
    print(f"Target aspect ratio: {WIDTH}:{HEIGHT} ({TARGET_RATIO:.10f})")

    load_deadzones()

    if GRID:
        if GRID.endswith('x'):
            find_optimal_grid(target_cols=int(GRID[:-1]))
        elif GRID.startswith('x'):
            find_optimal_grid(target_rows=int(GRID[1:]))
        else:
            COLS, ROWS = map(int, GRID.split('x'))
    elif ASPECT_RATIO:
        find_optimal_grid()
    else:
        print("No grid or aspect ratio specified. Using default 2 row grid.")
        find_optimal_grid(target_rows=2)

    print(f"Using grid: {COLS}x{ROWS}")
    TOTAL_IMAGES = COLS * ROWS
    if TOTAL_IMAGES < 2:
        print("Error: The grid must allow for at least 2 images.")
        sys.exit(1)
    if TOTAL_IMAGES > TOTAL_FRAMES:
        print(f"Error: Grid ({COLS}x{ROWS}) requires more images ({TOTAL_IMAGES}) than video frames ({TOTAL_FRAMES}).")
        sys.exit(1)

    image = [-1] * TOTAL_IMAGES
    livezones = [0] * TOTAL_IMAGES
    zone_id = 0

    dist_images()
    if not INTERACTIVE_MODE:
        generate_montage(OUT)
    else:
        while True:
            print("1. Add deadzone  2. Show frames between points  3. Generate/Regenerate montage")
            print("4. Show current deadzones  5. Exit")
            choice = input("Enter your choice: ")
            if choice == '1':
                start, end = map(int, input("Enter start and end frames: ").split())
                add_deadzone(start, end)
                image = [-1] * TOTAL_IMAGES
                dist_images()
            elif choice == '2':
                start, end = map(int, input("Enter start and end frames: ").split())
                dist_images(-1)
                generate_montage(f"{os.path.splitext(OUT)[0]}_intermediate.png", start, end)
                print(f"Intermediate frames montage saved as {os.path.splitext(OUT)[0]}_intermediate.png")
            elif choice == '3':
                generate_montage(OUT)
            elif choice == '4':
                print("Current deadzones:")
                if os.path.exists(DEADZONE_FILE):
                    with open(DEADZONE_FILE, 'r') as f:
                        print(f.read())
                else:
                    print("No deadzones defined.")
            elif choice == '5':
                break
            else:
                print("Invalid choice")

    shutil.rmtree(TEMP)
    print(f"Temporary files deleted. Log file: {LOG}")
