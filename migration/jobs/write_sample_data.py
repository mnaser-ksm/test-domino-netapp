import os

BASE_PATH = "/mnt/data/test_netapp/sample_load_python"

os.makedirs(BASE_PATH, exist_ok=True)

with open(os.path.join(BASE_PATH, "hello.txt"), "w") as f:
    f.write("Hello from a Domino Python job\n")

with open(os.path.join(BASE_PATH, "data.csv"), "w") as f:
    f.write("id,value\n")
    for i in range(1, 6):
        f.write(f"{i},{i*10}\n")

print("Files written to NetApp volume:")
print(os.listdir(BASE_PATH))
