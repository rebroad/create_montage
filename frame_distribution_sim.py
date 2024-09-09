#!/bin/python

import tkinter as tk
import math

# Constants
WIDTH, HEIGHT = 800, 600
FPS = 60
NUM_FRAMES = 21
SPRING_STRENGTH = 5.0
EPSILON = 1e-6

class Mass:
    def __init__(self, x, y, mass=1.0, fixed=False):
        self.x = x
        self.y = y
        self.vx = 0
        self.vy = 0
        self.mass = mass
        self.fixed = fixed

class Spring:
    def __init__(self, mass1, mass2, rest_length, k=SPRING_STRENGTH):
        self.mass1 = mass1
        self.mass2 = mass2
        self.rest_length = rest_length
        self.k = k

class Deadzone:
    def __init__(self, center_x, radius):
        self.center_x = center_x
        self.radius = radius
        self.y = HEIGHT + radius  # Start below the screen

class Simulation:
    def __init__(self, num_frames, deadzones):
        self.masses = []
        self.springs = []
        self.deadzones = deadzones
        self.dt = 1.0 / FPS
        self.speed = 1.0
        self.gravity = 0.0
        self.floor_y = HEIGHT // 2
        self.max_safe_velocity = 100  # Maximum "safe" velocity
        self.max_safe_position = WIDTH * 2  # Maximum "safe" position
        self.instability_detected = False
        
        # Create masses for frames
        for i in range(num_frames):
            x = i * (WIDTH / (num_frames - 1))
            fixed = (i == 0 or i == num_frames - 1)  # Fix first and last frames
            self.masses.append(Mass(x, self.floor_y, mass=0.1, fixed=fixed))
        
        # Create springs between adjacent masses
        for i in range(num_frames - 1):
            rest_length = self.masses[i+1].x - self.masses[i].x
            self.springs.append(Spring(self.masses[i], self.masses[i+1], rest_length))

    def detect_instability(self):
        for mass in self.masses:
            if (abs(mass.vx) > self.max_safe_velocity or
                abs(mass.vy) > self.max_safe_velocity or
                abs(mass.x) > self.max_safe_position or
                abs(mass.y) > self.max_safe_position or
                math.isnan(mass.x) or math.isnan(mass.y) or
                math.isnan(mass.vx) or math.isnan(mass.vy)):
                return True
        return False

    def update(self):
        # Move deadzones upward
        for deadzone in self.deadzones:
            if deadzone.y > self.floor_y:
                deadzone.y -= 0.5 * self.speed

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
                        force = spring.k * (distance - spring.rest_length)
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
                    dx = new_x - deadzone.center_x
                    dy = new_y - deadzone.y
                    distance = math.sqrt(dx*dx + dy*dy)
                    if distance < deadzone.radius + 5:  # 5 is the mass radius
                        # Project the position onto the surface of the deadzone
                        angle = math.atan2(dy, dx)
                        new_x = deadzone.center_x + (deadzone.radius + 5) * math.cos(angle)
                        new_y = deadzone.y + (deadzone.radius + 5) * math.sin(angle)

                        # Project velocity onto the tangent of the deadzone surface
                        tangent_x, tangent_y = -math.sin(angle), math.cos(angle)
                        dot_product = mass.vx * tangent_x + mass.vy * tangent_y
                        mass.vx = dot_product * tangent_x
                        mass.vy = dot_product * tangent_y

                # Keep masses within screen boundaries and above floor
                new_x = max(0, min(new_x, WIDTH))
                new_y = min(max(new_y, 0), self.floor_y)

                mass.x, mass.y = new_x, new_y

        # Check for instability and adjust speed if necessary
        if self.detect_instability():
            self.speed /= 2
            self.instability_detected = True
            print(f"Instability detected. Speed reduced to {self.speed:.2f}")
        else:
            self.instability_detected = False

class Application(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Frame Distribution Simulation")
        self.geometry(f"{WIDTH}x{HEIGHT}")
        
        self.canvas = tk.Canvas(self, width=WIDTH, height=HEIGHT, bg="black")
        self.canvas.pack()

        deadzones = [
            Deadzone(250, 100),
            Deadzone(550, 75)
        ]
        self.sim = Simulation(NUM_FRAMES, deadzones)

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

    def update_simulation(self):
        self.sim.update()
        self.draw()

        # If instability was detected, show a message
        if self.sim.instability_detected:
            self.canvas.create_text(WIDTH/2, 20, text="Instability detected. Speed reduced.",
                                    fill="red", font=("Arial", 14))

        self.after(int(1000/FPS), self.update_simulation)

    def draw(self):
        self.canvas.delete("all")

        # Draw deadzones
        for deadzone in self.sim.deadzones:
            self.canvas.create_oval(
                deadzone.center_x - deadzone.radius,
                deadzone.y - deadzone.radius,
                deadzone.center_x + deadzone.radius,
                deadzone.y + deadzone.radius,
                fill="red", outline="red"
            )

        # Draw springs
        for spring in self.sim.springs:
            self.canvas.create_line(
                spring.mass1.x, spring.mass1.y, 
                spring.mass2.x, spring.mass2.y,
                fill="white"
            )

        # Draw masses
        for mass in self.sim.masses:
            color = "yellow" if mass.fixed else "white"
            self.canvas.create_oval(
                mass.x-3, mass.y-3, mass.x+3, mass.y+3,
                fill=color, outline=color
            )

        # Draw floor line
        self.canvas.create_line(0, self.sim.floor_y, WIDTH, self.sim.floor_y, fill="gray")

        # Display speed and gravity
        self.canvas.create_text(10, HEIGHT-20, anchor="w", fill="white", 
                                text=f"Speed: {self.sim.speed:.2f}")
        self.canvas.create_text(WIDTH-10, HEIGHT-20, anchor="e", fill="white", 
                                text=f"Gravity: {self.sim.gravity:.2f}")

def main():
    app = Application()
    app.mainloop()

if __name__ == "__main__":
    main()
