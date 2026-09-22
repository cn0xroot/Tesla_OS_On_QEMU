import socket, json, sys, time
SOCK="/tmp/tesla_v60_qmp.sock"
gx, gy = int(sys.argv[1]), int(sys.argv[2])   # guest pixel in 1280x800
ax = gx*32767//1280; ay = gy*32767//800
s=socket.socket(socket.AF_UNIX); s.connect(SOCK)
def rd():
    time.sleep(0.15); return s.recv(65536).decode(errors="ignore")
def cmd(o): s.sendall((json.dumps(o)+"\r\n").encode()); return rd()
rd()  # greeting
cmd({"execute":"qmp_capabilities"})
# tap: move abs + btn down, then btn up
ev=[{"type":"abs","data":{"axis":"x","value":ax}},
    {"type":"abs","data":{"axis":"y","value":ay}},
    {"type":"btn","data":{"button":"left","down":True}}]
print("down:", cmd({"execute":"input-send-event","arguments":{"events":ev}}).strip())
time.sleep(0.12)
up=[{"type":"btn","data":{"button":"left","down":False}}]
print("up:", cmd({"execute":"input-send-event","arguments":{"events":up}}).strip())
s.close()
print(f"injected tap at guest({gx},{gy}) -> abs({ax},{ay})")
