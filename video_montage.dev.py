#!/bin/python

import os
import sys
import subprocess
import tempfile
import shutil

def convert_path(path):
    global use_cygpath
    if use_cygpath:
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
    width, height = map(int, dimensions.split('x'))
    return width, height

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
                print(f"DEBUG: Added deadzone {start}:{end}")
    print(f"Total available frames (excluding deadzones): {AVAILABLE_FRAMES}")

COLS, ROWS = 0, 0

def find_optimal_grid(available_frames=None, target_rows=None, target_cols=None):
    available_frames = available_frames or AVAILABLE_FRAMES
    if target_rows == None and target_cols == None:
        print(f"Searching for optimal grid for {WIDTH}:{HEIGHT} aspect ratio")
    best_diff = float('inf')
    TARGET_RATIO = WIDTH / HEIGHT
    start_y, end_y = (target_rows, target_rows) if target_rows else (1, available_frames)
    for y in range(start_y, end_y + 1):
        LAST_X_DIFF = float('inf')
        start_x = int((y * TARGET_RATIO * FRAME_HEIGHT) / FRAME_WIDTH)
        end_x = target_cols if target_cols else available_frames // y
        for x in range(start_x, end_x + 1):
            if x * y > available_frames:
                break
            grid_ratio = (x * FRAME_WIDTH) / (y * FRAME_HEIGHT)
            diff = (grid_ratio - TARGET_RATIO) ** 2
            if diff < best_diff:
                best_diff = diff
                best_grid = (x, y)
                logprint(2, "BEST! ", end="")
            elif LAST_X_DIFF < diff:
                logprint(2, f"x={x} y={y} diff={diff:.10f} - XBreak")
                break
            logprint(2, f"x={x} y={y} diff={diff:.10f}")
            LAST_X_DIFF = diff

    return best_grid

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

def count_available_frames(start, end):
    global deadzones
    available = end - start + 1
    for dz_start, dz_end in deadzones:
        if dz_end < start or dz_start > end:
            continue
        overlap_start = max(start, dz_start)
        overlap_end = min(end, dz_end)
        available -= (overlap_end - overlap_start + 1)
    return available

def logprint(level, *args, **kwargs):
    if DEBUG_LEVEL >= level:
        print(*args, **kwargs)

def dist_images(start_frame=0, end_frame=None, start_image=0, end_image=None):
    global image, iter
    if end_frame is None:
        end_frame = TOTAL_FRAMES - 1
    if end_image is None:
        end_image = TOTAL_IMAGES - 1
    iter = 1 if start_frame == 0 and end_frame == TOTAL_FRAMES - 1 else iter + 1
    if iter == 1:
        image = [TOTAL_FRAMES - 1] * TOTAL_IMAGES
    logprint(2, f"Entering dist_images: frames={start_frame}-{end_frame} images={start_image}-{end_image} iter={iter}")

    jump, step = 0, 0
    if start_image == end_image:
        frame, i = image[start_image], start_image
        if 0 < frame < TOTAL_FRAMES - 1:
            image[i] = (start_frame + end_frame) // 2
            jump = image[i] - frame
            logprint(2, f"image={i} frame: {frame} -> {image[i]} (center of {start_frame}:{end_frame})")
        else:
            logprint(2, f"Keep image {start_image} at its current position ({image[start_image]}) as it's special.")
    else:
        direction = 1 if end_image > start_image else -1
        step, skip = (end_frame - start_frame) / (end_image - start_image), 0
        logprint(2, f"Distribute images {start_image}-{end_image} between frames {start_frame}-{end_frame} step={step:.2f}")

        for i in range(start_image, end_image, direction):
            frame = int(start_frame + ((i - start_image) * step) + 0.5)
            if jump == 0:
                jump = frame - image[i]
            logprint(2, f"image={i} frame: {image[i]} -> {frame}")
            if image[i] == frame:
                skip = skip + 1
                if skip > 1:
                    logprint(2, "Skip the rest as numbers match.")
                    break
            else:
                skip = 0
            image[i] = frame

    logprint(2, f"Evenly dist frames: {' '.join(map(str, image))}")

    min_frame, max_frame = min(start_frame, end_frame), max(start_frame, end_frame)
    logprint(2, f"Finding largest deadzone within frames {min_frame} to {max_frame}")
    center = (start_frame + end_frame) // 2
    sorted_deadzones = sorted(
        ((dead_start, dead_end) for dead_start, dead_end in deadzones if min_frame <= dead_end and dead_start <= max_frame),
        key=lambda x: (x[1] - x[0] + 1, -abs((x[0] + x[1]) // 2 - center))
    )

    for dead_start, dead_end in sorted_deadzones:
        logprint(2, f"Checking deadzone: {dead_start}:{dead_end} for images")

        dead_images = 0
        images_left = 0
        images_right = 0

        min_image = min(start_image, end_image)
        max_image = max(start_image, end_image)
        for i in range(min_image, max_image + 1):
            if image[i] < dead_start:
                images_left += 1
                left_end_image = i
            elif dead_start <= image[i] <= dead_end:
                dead_images += 1
                right_start_image = i + 1
            elif image[i] > dead_end:
                images_right += 1
        logprint(1, f"dead_images={dead_images} images_on_left={images_left} images_on_right={images_right}")

        if dead_images > 0:
            break
    else:
        logprint(2, f"No images to relocate in any deadzone within {min_frame}:{max_frame}")
        return jump, step

    logprint(1, f"Rehoming images within deadzone: {dead_start}:{dead_end}")
    spaces_left = count_available_frames(min_frame, dead_start - 1)
    spaces_right = count_available_frames(dead_end + 1, max_frame)
    logprint(1, f"spaces_left: {spaces_left}, spaces_right: {spaces_right}")

    total_images = images_left + images_right + dead_images
    total_spaces = spaces_left + spaces_right
    ideal_step = total_spaces / (total_images - 1)
    logprint(1, f"Ideal step: {ideal_step:.2f}")

    if ALGORITHM == 1:
        move_left = min(dead_images, max(0, int((spaces_left / ideal_step) - images_left + 0.5)))
        move_right = dead_images - move_left
    elif ALGORITHM == 2:
        best_diff = float('inf')
        best_move_left = 0
        if spaces_left > 0 and spaces_right > 0:
            for move_left in range(dead_images + 1):
                move_right = dead_images - move_left
                left_step = spaces_left / (images_left + move_left - 1) if images_left + move_left > 1 else (spaces_left * 1.5)
                right_step = spaces_right / (images_right + move_right - 1) if images_right + move_right > 1 else (spaces_right * 1.5)
                diff = (left_step - right_step) ** 2
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
    else:
        print(f"Invalid algorithm choice: {ALGORITHM}")
        sys.exit(1)

    left_step = spaces_left / (images_left + move_left - 1) if images_left + move_left > 1 else 0
    right_step = spaces_right / (images_right + move_right - 1) if images_right + move_right > 1 else 0
    logprint(1, f"Algorithm {ALGORITHM}: dead_images={dead_images} move_left={move_left} move_right={move_right} left_step={left_step:.2f} right_step={right_step:.2f}")

    logprint(2, "Recurse into new livezones")
    sub_jump = 0
    if move_left > 0:
        logprint(2, f"Left dist_images {dead_start - 1} {min_frame} {left_end_image + move_left} {min_image}")
        sub_jump, sub_step = dist_images(dead_start - 1, min_frame, left_end_image + move_left, min_image)
    else:
        logprint(2, f"Nothing to move left... (within {min_frame}:{max_frame})")
    if move_right > 0 or (sub_jump != 0 and images_right > 0):
        logprint(2, "Processing right side")
        if sub_jump != 0:
            step_erm = dead_start - 1 + sub_step
            jump_erm = image[right_start_image - move_right] + sub_jump
            erm = max(dead_end + 1, int((step_erm + jump_erm) / 2 + 0.5))
            logprint(2, f"After left dist_images (frames {min_frame} to {dead_start - 1}) out of {min_frame} to {max_frame}. jump={sub_jump} step={sub_step:.2f}")
            logprint(2, f"    last_left={dead_start - 1} first_right={image[right_start_image - move_right]} erm={erm} jump_erm={jump_erm} step_erm={step_erm:.2f}")
            if int(step_erm + 0.5) != jump_erm:
                logprint(2, "DIFFERENT!")
        else:
            erm = dead_end + 1
        logprint(2, f"Right dist_images: frames: {erm}:{max_frame} (within {min_frame}:{max_frame}) images: {right_start_image - move_right}-{max_image}")
        sub_jump, sub_step = dist_images(erm, max_frame, right_start_image - move_right, max_image)
        logprint(2, f"After right dist_images ({min_frame}:{max_frame}). move_left={move_left} images_left={images_left}")
        if move_left == 0 and images_left > 0:
            step_erm = dead_end + 1 - sub_step
            jump_erm = image[left_end_image] + sub_jump
            erm = min(dead_start - 1, int((step_erm + jump_erm) / 2 + 0.5))
            logprint(2, f"After right dist_images (frames {erm} to {max_frame}) out of {min_frame} to {max_frame}. jump={sub_jump} step={sub_step:.2f}")
            logprint(2, f"    first_right={dead_end + 1} last_last={image[left_end_image]} erm={erm} jump_erm={jump_erm} step_erm={step_erm:.2f}")
            if int(step_erm + 0.5) != jump_erm:
                logprint(2, "DIFFERENT!")
            logprint(2, f"Left dist_images min_frame={min_frame} erm={erm} min_image={min_image} left_end_image={left_end_image} move_left={move_left}")
            dist_images(erm, min_frame, left_end_image + move_left, min_image)
    else:
        logprint(2, f"Apparently no need to call right dist_images. step={step:.2f} dead_end={dead_end} images_right={images_right}")

    logprint(2, f"Exiting dist_images for {min_frame}:{max_frame} this_jump={jump} this_step={step:.2f}")
    return jump, step

def generate_montage(output_file, start_frame=0, end_frame=None, cols=None, rows=None):
    end_frame = end_frame or TOTAL_FRAMES - 1
    cols = cols or COLS
    rows = rows or ROWS
    inputs = []
    what = "selected range" if start_frame != 0 or end_frame != TOTAL_FRAMES - 1 else "video"
    resizing = " and resizing" if RESIZE else ""

    for i, frame_num in enumerate(image):
        out_frame = os.path.join(TEMP, f"frame_{frame_num}.png")
        percent = (i / (len(image) - 1)) * 100
        print(f"Extracting frame {i} (frame {frame_num}, {percent:.2f}% of {what}){resizing}")
        filter = f"select=eq(n\\,{frame_num}){RESIZE}"
        if SHOW_NUMBERS:
            text = []
            text.append(str(frame_num)) # TODO - make the text size proportional to the size of the montage
            filter += f",drawtext=fontfile=/path/to/font.ttf:fontsize=24:fontcolor=white:box=1:boxcolor=black@0.5:boxborderw=5:x=10:y=10:text='{' '.join(text)}'"
        inputs.extend(["-i", convert_path(out_frame)])
        if os.path.exists(out_frame):
            continue
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", convert_path(VID), "-vf", filter, "-vsync", "vfr", convert_path(out_frame)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        if not os.path.exists(out_frame):
            print(f"Error: Failed to extract frame {i}. See {LOG}")
            sys.exit(1)

    if rows == 1:
        filter = f"{''.join(f'[{i}:v]' for i in range(cols))}hstack=inputs={cols}[v]"
    elif cols == 1:
        filter = f"{''.join(f'[{i}:v]' for i in range(rows))}vstack=inputs={rows}[v]"
    else:
        filter = ""
        for r in range(rows):
            row_inputs = ''.join(f'[{i}:v]' for i in range(r*cols, (r+1)*cols))
            if r % 2 == 0:
                filter += f"{row_inputs}hstack=inputs={cols}[row{r}];"
            else:
                filter += f"{row_inputs}hstack=inputs={cols},reverse[row{r}];"
        filter += f"{''.join(f'[row{r}]' for r in range(rows))}vstack=inputs={rows}[v]"

    print("Creating montage...")
    print(f"Filter complex: {filter}")

    os.environ['FONTCONFIG_FILE'] = "/dev/null"
    result = subprocess.run(["ffmpeg", "-loglevel", "error", "-y"] + inputs + ["-filter_complex", filter, "-map", "[v]", convert_path(output_file)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if result.returncode == 0 and os.path.exists(output_file):
        print(f"Montage saved as {output_file}")
    else:
        print(f"Error: Failed to create montage. See {LOG} for details.")
        with open(LOG, 'w') as f:
            f.write(result.stderr)
        print(result.stderr)
        sys.exit(1)

# Main execution
if len(sys.argv) < 2:
    print(f"Usage: {sys.argv[0]} <video.mp4> [aspect_ratio] [NxN | Nx | xN] [before_image.png] [after_image.png] [-i] [-n] [--debug N] [--algorithm N] [--algo-test]")
    sys.exit(1)

use_cygpath = False
result = subprocess.run(["ffmpeg", "-version"], capture_output=True, text=True)
if "MSYS2" in result.stdout:
    print("Detected Windows-native ffmpeg.")
    use_cygpath = True

VID = None
ASPECT_RATIO = None
GRID = None
START_IMAGE = None
END_IMAGE = None
INTERACTIVE_MODE = False
SHOW_NUMBERS = False
DEBUG_LEVEL = 0
ALGORITHM = 1
ALGO_TEST = False

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
    elif arg.startswith('--debug'):
        DEBUG_LEVEL = int(arg.split('=')[1])
    elif arg.startswith('--algorithm'):
        ALGORITHM = int(arg.split('=')[1])
    elif arg == '--algo-test':
        ALGO_TEST = True
    elif START_IMAGE is None:
        START_IMAGE = arg
    else:
        END_IMAGE = arg

if VID is None:
    print("Error: Video file not specified.")
    sys.exit(1)
VID = convert_path(VID)
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
    SW, SH = get_dimensions(START_IMAGE)
    RESIZE = f",scale={SW}:{SH}" if SW and SH else ""
    FRAME_WIDTH, FRAME_HEIGHT = SW, SH
else:
    FRAME_WIDTH, FRAME_HEIGHT = get_dimensions(VID)
    RESIZE = ""
print(f"Frame dimensions: {FRAME_WIDTH} by {FRAME_HEIGHT}")

if ASPECT_RATIO:
    WIDTH, HEIGHT = map(int, ASPECT_RATIO.split(':'))
else:
    WIDTH, HEIGHT = 16, 9
TARGET_RATIO = WIDTH / HEIGHT
print(f"Target aspect ratio: {WIDTH}:{HEIGHT} ({TARGET_RATIO:.10f})")

load_deadzones()

def set_grid(new_grid):
    global COLS, ROWS, TOTAL_IMAGES
    if new_grid.endswith('x'):
        COLS, ROWS = find_optimal_grid(target_cols=int(new_grid[:-1]))
    elif new_grid.startswith('x'):
        COLS, ROWS = find_optimal_grid(target_rows=int(new_grid[1:]))
    else:
        COLS, ROWS = map(int, new_grid.split('x'))
    TOTAL_IMAGES = COLS * ROWS

    if TOTAL_IMAGES < 2:
        print("Error: The grid must allow for at least 2 images.")
        return False
    if TOTAL_IMAGES > TOTAL_FRAMES:
        print(f"Error: Grid ({COLS}x{ROWS}) requires more images ({TOTAL_IMAGES}) than video frames ({TOTAL_FRAMES}).")
        return False
    print(f"Grid set to: {COLS}x{ROWS}")
    return True

def display_video_timeline(selected_frames):
    # Create the base timeline
    timeline = ['-'] * TOTAL_FRAMES
    
    # Mark deadzones
    for start, end in deadzones:
        for i in range(start, min(end + 1, TOTAL_FRAMES)):
            timeline[i] = '#'
    
    # Mark selected frames
    for frame in selected_frames:
        if 0 <= frame < TOTAL_FRAMES:
            if timeline[frame] != '-':
                timeline[frame] = 'X'
            else:
                timeline[frame] = 'x'
    
    # Convert timeline to string and add markers
    timeline_str = ''.join(timeline)
    marker_line = ''.join([str(i % 10) for i in range(TOTAL_FRAMES)])
    
    print(timeline_str)

if ALGO_TEST:
    wins = {1: 0, 2: 0, "tie": 0}
    results = []
    for num_images in range(21, 1, -1):
        TOTAL_IMAGES = num_images
        COLS, ROWS = num_images, 1
        algo_results = {}
        for ALGORITHM in [1, 2]:
            dist_images()
            gaps = [image[i+1] - image[i] - 1 for i in range(len(image)-1)]
            avg_gap = sum(gaps) / len(gaps)
            variance = sum((gap - avg_gap) ** 2 for gap in gaps) / len(gaps)
            algo_results[ALGORITHM] = {"image": image.copy(), "gaps": gaps, "variance": variance}

        if algo_results[1]["variance"] < algo_results[2]["variance"]:
            winner = 1
            wins[1] += 1
        elif algo_results[2]["variance"] < algo_results[1]["variance"]:
            winner = 2
            wins[2] += 1
        else:
            winner = "tie"
            wins["tie"] += 1

        results.append((num_images, winner, algo_results))

    print("\nAlgorithm Test Results:")
    print("=" * 50)
    for num_images, winner, algo_results in results:
        if winner == "tie" and algo_results[1]["gaps"] == algo_results[2]["gaps"]:
            display_video_timeline(algo_results[1]['image'])
            print(f"num_images={num_images} algo=1&2 variance={algo_results[1]['variance']:.4f} gaps:", " ".join(map(str, algo_results[1]["gaps"])))
        else:
            for algo in [1, 2]:
                display_video_timeline(algo_results[algo]['image'])
                print(f"num_images={num_images} algo={algo} variance={algo_results[algo]['variance']:.4f} gaps:", " ".join(map(str, algo_results[algo]["gaps"])))
    print(f"\nSummary: Algo1_wins={wins[1]} Algo2_wins={wins[2]} Ties={wins['tie']}")
else:
    if GRID:
        set_grid(GRID)
    elif ASPECT_RATIO:
        COLS, ROWS = find_optimal_grid()
    else:
        print("No grid or aspect ratio specified. Using default 2 row grid.")
        COLS, ROWS = find_optimal_grid(target_rows=2)

    dist_images()
    display_video_timeline(image)
    if INTERACTIVE_MODE:
        while True:
            print("1. Add deadzone  2. Show frames between points  3. Generate/Regenerate montage")
            print("4. Show current deadzones  5. Change grid  6. Exit")
            choice = input("Enter your choice: ")
            if choice == '1':
                start, end = map(int, input("Enter start and end frames: ").split())
                add_deadzone(start, end)
                dist_images()
                display_video_timeline(image)
            elif choice == '2':
                start, end = map(int, input("Enter start and end frames: ").split())
                cols, rows = find_optimal_grid(end - start + 1)
                step = (end - start) / ((cols * rows) - 1)
                image = [int(start + (i * step) + 0.5) for i in range(cols * rows)]
                generate_montage(f"{os.path.splitext(OUT)[0]}_intermediate.png", start, end, cols, rows)
                dist_images()
                display_video_timeline(image)
                print(f"Intermediate frames montage saved as {os.path.splitext(OUT)[0]}_intermediate.png")
            elif choice == '3':
                generate_montage(OUT)
            elif choice == '4':
                print("Current deadzones:")
                if os.path.exists(DEADZONE_FILE):
                    with open(DEADZONE_FILE, 'r') as f:
                        print(f.read())
            elif choice == '5':
                new_grid = input("Enter new grid (e.g., 4x3, x3, 4x): ")
                if set_grid(new_grid):
                    dist_images()
                    display_video_timeline(image)
            elif choice == '6':
                break
            else:
                print("Invalid choice")
    else:
        generate_montage(OUT)

shutil.rmtree(TEMP)
logprint(1, f"Temporary files deleted. Log file: {LOG}")
