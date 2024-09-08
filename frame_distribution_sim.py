import tkinter as tk
import math
import time

# Constants
WIDTH, HEIGHT = 800, 600
FPS = 60

class Mass:
    def __init__(self, x, y, mass=1.0, fixed=False):
        self.x = x
        self.y = y
        self.vx = 0
        self.vy = 0
        self.ax = 0
        self.ay = 0
        self.mass = mass
        self.fixed = fixed

class Spring:
    def __init__(self, mass1, mass2, rest_length, k=1.0):
        self.mass1 = mass1
        self.mass2 = mass2
        self.rest_length = rest_length
        self.k = k

class Deadzone:
    def __init__(self, start, end, height):
        self.start = start
        self.end = end
        self.height = height

class Simulation:
    def __init__(self, num_frames, deadzones):
        self.masses = []
        self.springs = []
        self.deadzones = deadzones
        
        # Create masses for frames
        for i in range(num_frames):
            x = i * (WIDTH / (num_frames - 1))
            self.masses.append(Mass(x, HEIGHT // 2, mass=0.1))
        
        # Create springs between adjacent masses
        for i in range(num_frames - 1):
            rest_length = self.masses[i+1].x - self.masses[i].x
            self.springs.append(Spring(self.masses[i], self.masses[i+1], rest_length))

    def update(self):
        # Apply spring forces
        for spring in self.springs:
            dx = spring.mass2.x - spring.mass1.x
            dy = spring.mass2.y - spring.mass1.y
            distance = math.sqrt(dx*dx + dy*dy)
            force = spring.k * (distance - spring.rest_length)
            
            fx = force * dx / distance
            fy = force * dy / distance
            
            if not spring.mass1.fixed:
                spring.mass1.ax += fx / spring.mass1.mass
                spring.mass1.ay += fy / spring.mass1.mass
            if not spring.mass2.fixed:
                spring.mass2.ax -= fx / spring.mass2.mass
                spring.mass2.ay -= fy / spring.mass2.mass

        # Apply deadzone forces
        for mass in self.masses:
            for deadzone in self.deadzones:
                if deadzone.start <= mass.x <= deadzone.end and mass.y > HEIGHT // 2 - deadzone.height:
                    mass.ay -= 0.1  # Push upwards if inside deadzone

        # Update positions
        for mass in self.masses:
            if not mass.fixed:
                mass.vx += mass.ax
                mass.vy += mass.ay
                mass.x += mass.vx
                mass.y += mass.vy
                
                # Apply damping
                mass.vx *= 0.99
                mass.vy *= 0.99
                
                # Reset accelerations
                mass.ax = 0
                mass.ay = 0

class Application(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Frame Distribution Simulation")
        self.geometry(f"{WIDTH}x{HEIGHT}")
        
        self.canvas = tk.Canvas(self, width=WIDTH, height=HEIGHT, bg="white")
        self.canvas.pack()

        deadzones = [
            Deadzone(200, 300, 100),
            Deadzone(500, 550, 150)
        ]
        self.sim = Simulation(20, deadzones)

        self.update_simulation()

    def update_simulation(self):
        self.sim.update()
        self.draw()
        self.after(int(1000/FPS), self.update_simulation)

    def draw(self):
        self.canvas.delete("all")

        # Draw deadzones
        for deadzone in self.sim.deadzones:
            self.canvas.create_rectangle(deadzone.start, HEIGHT // 2 - deadzone.height, 
                                         deadzone.end, HEIGHT // 2, fill="red")

        # Draw springs
        for spring in self.sim.springs:
            self.canvas.create_line(spring.mass1.x, spring.mass1.y, 
                                    spring.mass2.x, spring.mass2.y)

        # Draw masses
        for mass in self.sim.masses:
            self.canvas.create_oval(mass.x-5, mass.y-5, mass.x+5, mass.y+5, fill="blue")

def main():
    app = Application()
    app.mainloop()

if __name__ == "__main__":
    main()
