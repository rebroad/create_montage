#!/bin/python

import tkinter as tk
import math

# Constants
WIDTH, HEIGHT = 800, 600
FPS = 60
NUM_FRAMES = 21
MAX_FORCE = 50.0
COLLISION_SLOWDOWN = 0.1
SPRING_STRENGTH = 5.0
DEADZONE_REPULSION = 1000.0

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
        self.collision_detected = False
        self.speed = 1.0
        self.gravity = 0.0
        self.floor_y = HEIGHT // 2
        
        # Create masses for frames
        for i in range(num_frames):
            x = i * (WIDTH / (num_frames - 1))
            fixed = (i == 0 or i == num_frames - 1)  # Fix first and last frames
            self.masses.append(Mass(x, self.floor_y, mass=0.1, fixed=fixed))
        
        # Create springs between adjacent masses
        for i in range(num_frames - 1):
            rest_length = self.masses[i+1].x - self.masses[i].x
            self.springs.append(Spring(self.masses[i], self.masses[i+1], rest_length))

        # Align deadzone centers
        max_radius = max(dz.radius for dz in self.deadzones)
        for dz in self.deadzones:
            dz.y = HEIGHT

    def update(self):
        # Move deadzones upward
        if all(dz.y > self.floor_y for dz in self.deadzones):
            for deadzone in self.deadzones:
                deadzone.y -= 0.5 * self.speed

        # Check for collisions
        self.collision_detected = self.check_collisions()

        # Adjust time step if collision is detected
        dt = self.dt * COLLISION_SLOWDOWN if self.collision_detected else self.dt
        dt *= self.speed  # Apply speed factor

        # Calculate forces
        for mass in self.masses:
            if not mass.fixed:
                mass.vx *= 0.99  # Damping
                mass.vy *= 0.99  # Damping
                
                # Apply gravity
                mass.vy += self.gravity * dt
                
                # Apply spring forces
                for spring in self.springs:
                    dx = spring.mass2.x - spring.mass1.x
                    dy = spring.mass2.y - spring.mass1.y
                    distance = math.sqrt(dx*dx + dy*dy)
                    force = spring.k * (distance - spring.rest_length)
                    force = max(min(force, MAX_FORCE), -MAX_FORCE)

                    if not spring.mass1.fixed:
                        spring.mass1.vx += force * dx / distance / spring.mass1.mass * dt
                        spring.mass1.vy += force * dy / distance / spring.mass1.mass * dt
                    if not spring.mass2.fixed:
                        spring.mass2.vx += force * dx / distance / spring.mass2.mass * dt
                        spring.mass2.vy += force * dy / distance / spring.mass2.mass * dt
                
                # Apply deadzone repulsion
                for deadzone in self.deadzones:
                    dx = mass.x - deadzone.center_x
                    dy = mass.y - deadzone.y
                    distance = math.sqrt(dx*dx + dy*dy)
                    if distance < deadzone.radius + 5:  # 5 is the mass radius
                        force = DEADZONE_REPULSION * (1 / distance - 1 / (deadzone.radius + 5))
                        mass.vx += force * dx / distance / mass.mass * dt
                        mass.vy += force * dy / distance / mass.mass * dt

        # Update positions
        for mass in self.masses:
            if not mass.fixed:
                mass.x += mass.vx * dt
                mass.y += mass.vy * dt
                
                # Keep masses within screen boundaries and above floor
                mass.x = max(0, min(mass.x, WIDTH))
                mass.y = min(mass.y, self.floor_y)  # Prevent going below floor

        # Final collision check and correction
        self.resolve_collisions()

    def check_collisions(self):
        for mass in self.masses:
            for deadzone in self.deadzones:
                dx = mass.x - deadzone.center_x
                dy = mass.y - deadzone.y
                if math.sqrt(dx*dx + dy*dy) < deadzone.radius + 5:  # 5 is the mass radius
                    return True
        return False

    def resolve_collisions(self):
        for mass in self.masses:
            if not mass.fixed:
                for deadzone in self.deadzones:
                    dx = mass.x - deadzone.center_x
                    dy = mass.y - deadzone.y
                    distance = math.sqrt(dx*dx + dy*dy)
                    if distance < deadzone.radius + 5:  # 5 is the mass radius
                        overlap = deadzone.radius + 5 - distance
                        mass.x += overlap * dx / distance
                        mass.y += overlap * dy / distance
                        mass.y = min(mass.y, self.floor_y)  # Ensure it doesn't go below floor

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
            self.sim.speed *= 1.1
        elif event.char == 's':
            self.sim.speed /= 1.1
        elif event.char == 'a':
            self.sim.gravity -= 0.1
        elif event.char == 'd':
            self.sim.gravity += 0.1

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
