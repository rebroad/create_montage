#!/bin/python

import tkinter as tk
import math

# Constants
WIDTH, HEIGHT = 800, 600
FPS = 60
NUM_FRAMES = 21
MAX_FORCE = 10.0  # Maximum force to prevent instability
COLLISION_SLOWDOWN = 0.1  # Factor to slow down simulation on collision

class Mass:
    def __init__(self, x, y, mass=1.0, fixed=False):
        self.x = x
        self.y = y
        self.old_x = x
        self.old_y = y
        self.mass = mass
        self.fixed = fixed

class Spring:
    def __init__(self, mass1, mass2, rest_length, k=1.0):
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
        self.collision_detected = False
        
        # Create masses for frames
        for i in range(num_frames):
            x = i * (WIDTH / (num_frames - 1))
            self.masses.append(Mass(x, HEIGHT // 2, mass=0.1))
        
        # Create springs between adjacent masses
        for i in range(num_frames - 1):
            rest_length = self.masses[i+1].x - self.masses[i].x
            self.springs.append(Spring(self.masses[i], self.masses[i+1], rest_length, k=0.5))

    def update(self):
        # Move deadzones upward
        for deadzone in self.deadzones:
            if deadzone.y > HEIGHT // 2:
                deadzone.y -= 0.5

        # Check for collisions
        self.collision_detected = False
        for mass in self.masses:
            for deadzone in self.deadzones:
                dx = mass.x - deadzone.center_x
                dy = mass.y - deadzone.y
                if math.sqrt(dx*dx + dy*dy) < deadzone.radius + 5:  # 5 is the mass radius
                    self.collision_detected = True
                    break
            if self.collision_detected:
                break

        # Adjust time step if collision is detected
        dt = self.dt * COLLISION_SLOWDOWN if self.collision_detected else self.dt

        # Verlet integration
        for mass in self.masses:
            if not mass.fixed:
                temp_x = mass.x
                temp_y = mass.y
                mass.x = 2 * mass.x - mass.old_x
                mass.y = 2 * mass.y - mass.old_y
                mass.old_x = temp_x
                mass.old_y = temp_y

        # Calculate forces and update positions
        for spring in self.springs:
            dx = spring.mass2.x - spring.mass1.x
            dy = spring.mass2.y - spring.mass1.y
            distance = math.sqrt(dx*dx + dy*dy)
            force = spring.k * (distance - spring.rest_length)
            
            # Limit the force to prevent instability
            force = max(min(force, MAX_FORCE), -MAX_FORCE)
            
            fx = force * dx / distance
            fy = force * dy / distance
            
            if not spring.mass1.fixed:
                spring.mass1.x += fx * dt * dt / spring.mass1.mass
                spring.mass1.y += fy * dt * dt / spring.mass1.mass
            if not spring.mass2.fixed:
                spring.mass2.x -= fx * dt * dt / spring.mass2.mass
                spring.mass2.y -= fy * dt * dt / spring.mass2.mass

        # Apply deadzone forces
        for mass in self.masses:
            for deadzone in self.deadzones:
                dx = mass.x - deadzone.center_x
                dy = mass.y - deadzone.y
                distance = math.sqrt(dx*dx + dy*dy)
                if distance < deadzone.radius + 5:  # 5 is the mass radius
                    force = 1.0 * (deadzone.radius + 5 - distance)
                    force = max(min(force, MAX_FORCE), -MAX_FORCE)
                    mass.x += force * dx / distance * dt * dt / mass.mass
                    mass.y += force * dy / distance * dt * dt / mass.mass

        # Keep masses within screen boundaries
        for mass in self.masses:
            mass.x = max(0, min(mass.x, WIDTH))
            mass.y = max(0, min(mass.y, HEIGHT))

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

        self.update_simulation()

    def update_simulation(self):
        self.sim.update()
        self.draw()
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
            self.canvas.create_oval(
                mass.x-3, mass.y-3, mass.x+3, mass.y+3,
                fill="white", outline="white"
            )

def main():
    app = Application()
    app.mainloop()

if __name__ == "__main__":
    main()
