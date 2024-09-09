#!/bin/python

import tkinter as tk
import math
import sys
import argparse
import os

# Constants
WIDTH, HEIGHT = 800, 600
FPS = 60
EPSILON = 1e-6
DEFAULT_NUM_FRAMES = 155
DEFAULT_NUM_IMAGES = 21
MASS_RADIUS = 3
INITIAL_SPRING_STRENGTH = 0.10

class Mass:
    def __init__(self, x, y, mass=1.0, fixed=False):
        self.x = x
        self.y = y
        self.vx = 0
        self.vy = 0
        self.mass = mass
        self.fixed = fixed

class Spring:
    def __init__(self, mass1, mass2, rest_length):
        self.mass1 = mass1
        self.mass2 = mass2
        self.rest_length = rest_length

class Deadzone:
    def __init__(self, start, end):
        self.start = start
        self.end = end
        self.y = HEIGHT  # Start below the screen
        self.height = 0  # Will be set in the Simulation class

class Simulation:
    def __init__(self, num_frames, num_images, deadzones):
        self.num_frames = num_frames
        self.num_images = num_images
        self.masses = []
        self.springs = []
        self.deadzones = deadzones
        self.dt = 1.0 / FPS
        self.speed = 1.0
        self.gravity = 0.0
        self.floor_y = HEIGHT // 2
        self.spring_strength = INITIAL_SPRING_STRENGTH

        # Find the first and last available frames
        self.first_available_frame = 0
        self.last_available_frame = num_frames - 1
        for deadzone in deadzones:
            if deadzone.start == 0:
                self.first_available_frame = deadzone.end + 1
            if deadzone.start < num_frames and deadzone.end >= num_frames:
                self.last_available_frame = deadzone.start - 1

        # Calculate the maximum deadzone height
        max_base_width = 0
        for deadzone in deadzones:
            start_x = self.frame_to_x(deadzone.start - 0.7)
            end_x = self.frame_to_x(deadzone.end + 0.7)
            base_width = end_x - start_x
            max_base_width = max(max_base_width, base_width)
        
        max_height = max_base_width * 0.75  # Adjust this factor to change the height of the shape

        # Set the height for all deadzones
        for deadzone in deadzones:
            deadzone.height = max_height
            deadzone.y = self.floor_y + max_height  # Start below the floor

        # Create masses for images
        for i in range(num_images):
            x = i * (WIDTH / (num_images - 1))
            fixed = (i == 0 or i == num_images - 1)  # Fix first and last images
            self.masses.append(Mass(x, self.floor_y, mass=0.1, fixed=fixed))

        # Create springs between adjacent masses
        for i in range(num_images - 1):
            rest_length = self.masses[i+1].x - self.masses[i].x
            self.springs.append(Spring(self.masses[i], self.masses[i+1], rest_length))

    def frame_to_x(self, frame):
        return (frame - self.first_available_frame) / (self.last_available_frame - self.first_available_frame) * WIDTH

    def x_to_frame(self, x):
        return self.first_available_frame + (x / WIDTH) * (self.last_available_frame - self.first_available_frame)

    def update(self):
        # Move deadzones upward
        all_at_floor = True
        for deadzone in self.deadzones:
            if deadzone.y > self.floor_y:
                deadzone.y -= 0.5 * self.speed
                all_at_floor = False
            else:
                deadzone.y = self.floor_y

        # Stop moving deadzones when all reach the floor
        if all_at_floor:
            for deadzone in self.deadzones:
                deadzone.y = self.floor_y

        dt = self.dt  # Use constant time step

        # Apply forces
        for mass in self.masses:
            if not mass.fixed:
                # Reset accelerations
                ax, ay = 0, 0

                # Apply gravity
                ay += self.gravity

                # Apply spring forces
                for spring in self.springs:
                    if spring.mass1 == mass or spring.mass2 == mass:
                        other = spring.mass2 if spring.mass1 == mass else spring.mass1
                        dx = other.x - mass.x
                        dy = other.y - mass.y
                        distance = math.sqrt(dx*dx + dy*dy + EPSILON)
                        force = self.spring_strength * (distance - spring.rest_length)
                        ax += force * dx / distance / mass.mass
                        ay += force * dy / distance / mass.mass

                # Update velocity
                mass.vx += ax * dt * self.speed
                mass.vy += ay * dt * self.speed

                # Apply damping
                mass.vx *= 0.99
                mass.vy *= 0.99

        # Update positions and handle collisions
        for mass in self.masses:
            if not mass.fixed:
                new_x = mass.x + mass.vx * dt * self.speed
                new_y = mass.y + mass.vy * dt * self.speed

                # Check for collisions with deadzones
                for deadzone in self.deadzones:
                    start_x = self.frame_to_x(deadzone.start - 0.7)
                    end_x = self.frame_to_x(deadzone.end + 0.7)
                    base_width = end_x - start_x
                    if start_x <= new_x <= end_x:
                        relative_x = (new_x - start_x) / base_width
                        # Custom shape function
                        shape_y = deadzone.y - deadzone.height * (1 - (2*relative_x-1)**2)
                        if new_y >= shape_y:
                            # Calculate normal vector of the surface
                            if relative_x < 0.1 or relative_x > 0.9:
                                normal_x = 0
                                normal_y = -1
                            else:
                                normal_x = -4 * (2*relative_x-1) / base_width
                                normal_y = -1
                                normal_length = math.sqrt(normal_x**2 + normal_y**2)
                                normal_x /= normal_length
                                normal_y /= normal_length

                            # Project velocity onto the surface
                            dot_product = mass.vx * normal_x + mass.vy * normal_y
                            mass.vx -= dot_product * normal_x
                            mass.vy -= dot_product * normal_y

                            # Move the mass to the surface of the shape
                            new_x = max(start_x, min(new_x, end_x))
                            new_y = shape_y - EPSILON

                # Keep masses within screen boundaries and above floor
                new_x = max(0, min(new_x, WIDTH))
                new_y = min(max(new_y, 0), self.floor_y)

                mass.x, mass.y = new_x, new_y

        # Check for instability and adjust speed if necessary
        if self.detect_instability():
            self.speed /= 2
            print(f"Instability detected. Speed reduced to {self.speed:.2f}")

    def detect_instability(self):
        max_safe_distance = WIDTH / 3  # 1/3rd of the window width
        for mass in self.masses:
            if (abs(mass.vx * self.dt) > max_safe_distance or
                abs(mass.vy * self.dt) > max_safe_distance):
                return True
        return False

    def adjust_spring_strength(self, delta):
        self.spring_strength += delta
        self.spring_strength = max(0.1, self.spring_strength)  # Ensure it doesn't go negative

class Application(tk.Tk):
    def __init__(self, simulation):
        super().__init__()
        self.title("Frame Distribution Simulation")
        self.geometry(f"{WIDTH}x{HEIGHT}")
        self.canvas = tk.Canvas(self, width=WIDTH, height=HEIGHT, bg="black")
        self.canvas.pack()
        self.sim = simulation
        self.bind('<Key>', self.on_key_press)
        self.update_simulation()

    def on_key_press(self, event):
        if event.char == 'w':
            self.sim.gravity -= 0.1
        elif event.char == 's':
            self.sim.gravity += 0.1
        elif event.char == 'a':
            self.sim.speed /= 1.1
        elif event.char == 'd':
            self.sim.speed *= 1.1
        elif event.char == 'q':
            self.sim.adjust_spring_strength(-0.01)
        elif event.char == 'e':
            self.sim.adjust_spring_strength(0.01)

    def update_simulation(self):
        self.sim.update()
        self.draw()
        self.after(int(1000/FPS), self.update_simulation)

    def draw(self):
        self.canvas.delete("all")

        # Draw deadzones
        for deadzone in self.sim.deadzones:
            start_x = self.sim.frame_to_x(deadzone.start - 0.7)
            end_x = self.sim.frame_to_x(deadzone.end + 0.7)
            base_width = end_x - start_x
            points = []
            for i in range(21):
                relative_x = i / 20
                x = start_x + relative_x * base_width
                y = deadzone.y - deadzone.height * (1 - (2*relative_x-1)**2)
                points.extend([x, y])
            points.extend([end_x, deadzone.y, start_x, deadzone.y])
            self.canvas.create_polygon(points, fill="red", outline="red")

        # Draw springs
        for spring in self.sim.springs:
            self.canvas.create_line(
                spring.mass1.x, spring.mass1.y,
                spring.mass2.x, spring.mass2.y,
                fill="white"
            )

        # Draw masses and frame numbers
        for mass in self.sim.masses:
            color = "yellow" if mass.fixed else "white"
            self.canvas.create_oval(
                mass.x - MASS_RADIUS, mass.y - MASS_RADIUS,
                mass.x + MASS_RADIUS, mass.y + MASS_RADIUS,
                fill=color, outline=color
            )
            frame_number = self.sim.x_to_frame(mass.x)
            self.canvas.create_text(
                mass.x, mass.y - 20,
                text=f"{frame_number:.1f}",
                fill="white"
            )

        # Draw floor line
        self.canvas.create_line(0, self.sim.floor_y, WIDTH, self.sim.floor_y, fill="gray")

        # Display speed, gravity, and spring strength
        self.canvas.create_text(10, HEIGHT-20, anchor="w", fill="white", 
                                text=f"Speed: {self.sim.speed:.2f}, Gravity: {self.sim.gravity:.2f}, Spring: {self.sim.spring_strength:.2f}")

def read_deadzones(filename):
    deadzones = []
    with open(filename, 'r') as f:
        for line in f:
            start, end = map(int, line.strip().split(':'))
            deadzones.append(Deadzone(start, end))
    return deadzones

def convert_path(path):
    try:
        import subprocess
        return subprocess.check_output(['cygpath', '-w', path]).strip().decode('utf-8')
    except:
        return path

def main():
    parser = argparse.ArgumentParser(description="Frame Distribution Simulation")
    parser.add_argument("deadzone_file", type=str, help="File containing deadzone information")
    parser.add_argument("--num_frames", type=int, default=DEFAULT_NUM_FRAMES, help="Total number of frames")
    parser.add_argument("--num_images", type=int, default=DEFAULT_NUM_IMAGES, help="Number of images to distribute")
    args = parser.parse_args()

    windows_path = convert_path(args.deadzone_file)
    deadzones = read_deadzones(windows_path)
    sim = Simulation(args.num_frames, args.num_images, deadzones)
    app = Application(sim)
    app.mainloop()

if __name__ == "__main__":
    main()
